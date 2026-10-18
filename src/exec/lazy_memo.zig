//! Mutable per-search scratch for the lazy DFA (`exec/lazy_dfa.zig`).
//!
//! Carved out of `lazy_dfa.zig` to make the thread-safety boundary a file
//! boundary: the immutable `LazyProg` (shared read-only across threads) lives
//! in `lazy_dfa.zig`; this `LazyMemo` is the mutable state memo + dense
//! transition caches, borrowed one-per-search from a pool so concurrent
//! searches over a shared `LazyProg` never race. Learned states persist
//! across reuse of the same pooled memo (same program ⇒ valid amortization,
//! RE2/rust-regex style).
//!
//! This module owns the encoding of a memoized transition-cache cell — the
//! `UNKNOWN`/`TDEAD` sentinels below — which `LazyProg` reads and writes
//! through the arrays here.

const std = @import("std");

/// Cap on simultaneously-cached DFA states. Hitting it flushes the memo
/// (states are rebuilt on demand — same answers, more work). RE2-style
/// flush-restart: the single-pass driver detects the flush via `gen` and
/// restarts the current scan from its origin (rare at this cap).
pub const DEFAULT_CACHE_STATES: usize = 8192;
/// Byte cap on the interned state lists (+ their map keys), per direction.
/// With large runtime NFAs one DFA state can hold thousands of NFA ids, so a
/// state count alone does not bound memory; hitting either cap flushes.
pub const DEFAULT_CACHE_BYTES: usize = 32 << 20;

/// Per-search working buffers for building transitions, sized to the NFA by
/// `LazyMemo.ensureScratch` and reused with the pooled memo — the lazy DFA's
/// closure/step functions keep no NFA-sized arrays on the native stack.
pub const Scratch = struct {
    src: []u16 = &.{}, // a state's list (+ trailer word), copied before interning
    buf: []u16 = &.{}, // closure output
    seeds: []u16 = &.{}, // consume targets (+ start injection + trailer)
    mark: []u32 = &.{}, // closure / dedupe visited set, epoch-stamped
    epoch: u32 = 0,
    stack: []u16 = &.{}, // closure DFS stack
    n_states: usize = 0,
    n_edges: usize = 0,

    /// Start a fresh visited set: `mark[s] == epoch` <=> visited. O(1) instead
    /// of clearing an `n_states` array per closure (10 K+ states on large
    /// runtime NFAs); the array is only re-zeroed when the epoch wraps.
    pub fn nextEpoch(sc: *Scratch) u32 {
        sc.epoch +%= 1;
        if (sc.epoch == 0) {
            @memset(sc.mark, 0);
            sc.epoch = 1;
        }
        return sc.epoch;
    }
};

/// "No cached start state" generation sentinel.
const NO_GEN: u64 = std.math.maxInt(u64);

/// Transition-cache cell sentinels (`LazyMemo.{atrans,utrans,rtrans}`):
pub const UNKNOWN: i32 = -1; // transition not yet computed
pub const TDEAD: i32 = -2; // computed: no byte successor (anchored only)

/// Mutable per-search scratch: state memo + dense transition caches.
/// Pool-compatible (`init(allocator)`/`deinit`). One memo is borrowed per
/// search so concurrent searches over a shared `LazyProg` never race; the
/// learned states persist across reuse of the same pooled memo (same
/// program ⇒ valid amortization, RE2/rust-regex style).
pub const LazyMemo = struct {
    allocator: std.mem.Allocator,

    states: std.ArrayListUnmanaged([]u16) = .empty,
    accept: std.ArrayListUnmanaged(bool) = .empty,
    map: std.StringHashMapUnmanaged(u32) = .empty,
    atrans: std.ArrayListUnmanaged(i32) = .empty,
    utrans: std.ArrayListUnmanaged(i32) = .empty,
    gen: u64 = 0,

    rstates: std.ArrayListUnmanaged([]u16) = .empty,
    rhas_start: std.ArrayListUnmanaged(bool) = .empty,
    rmap: std.StringHashMapUnmanaged(u32) = .empty,
    rtrans: std.ArrayListUnmanaged(i32) = .empty,
    rgen: u64 = 0,

    cap: usize = DEFAULT_CACHE_STATES,
    byte_cap: usize = DEFAULT_CACHE_BYTES,
    bytes: usize = 0,
    rbytes: usize = 0,
    sc: Scratch = .{},
    /// Start-state caches, valid while their generation matches `gen`/`rgen`
    /// (a flush invalidates them). Indexed by the look-mode byte context
    /// (classic mode uses slot 0). The start closure of a large NFA is costly
    /// and identical for every search — recomputing it per match dominated
    /// match-dense searches.
    fstart: [4]u32 = undefined,
    fstart_gen: [4]u64 = @splat(NO_GEN),
    rstart: [4]u32 = undefined,
    rstart_gen: [4]u64 = @splat(NO_GEN),

    pub fn init(allocator: std.mem.Allocator) LazyMemo {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *LazyMemo) void {
        for (self.states.items) |s| self.allocator.free(s);
        self.states.deinit(self.allocator);
        self.accept.deinit(self.allocator);
        var it = self.map.iterator();
        while (it.next()) |e| self.allocator.free(e.key_ptr.*);
        self.map.deinit(self.allocator);
        self.atrans.deinit(self.allocator);
        self.utrans.deinit(self.allocator);
        for (self.rstates.items) |s| self.allocator.free(s);
        self.rstates.deinit(self.allocator);
        self.rhas_start.deinit(self.allocator);
        var rit = self.rmap.iterator();
        while (rit.next()) |e| self.allocator.free(e.key_ptr.*);
        self.rmap.deinit(self.allocator);
        self.rtrans.deinit(self.allocator);
        self.allocator.free(self.sc.src);
        self.allocator.free(self.sc.buf);
        self.allocator.free(self.sc.seeds);
        self.allocator.free(self.sc.mark);
        self.allocator.free(self.sc.stack);
    }

    /// Size the transition-building scratch for an NFA of `n_states` states and
    /// `n_edges` edges (no-op once large enough).
    pub fn ensureScratch(self: *LazyMemo, n_states: usize, n_edges: usize) !void {
        if (n_states <= self.sc.n_states and n_edges <= self.sc.n_edges) return;
        const ns = @max(n_states, self.sc.n_states);
        const ne = @max(n_edges, self.sc.n_edges);
        const a = self.allocator;
        const src = try a.alloc(u16, ns + 1);
        errdefer a.free(src);
        const buf = try a.alloc(u16, ns);
        errdefer a.free(buf);
        const seeds = try a.alloc(u16, ne + 2);
        errdefer a.free(seeds);
        const mark = try a.alloc(u32, ns);
        errdefer a.free(mark);
        const stack = try a.alloc(u16, ne + ns + 2);
        a.free(self.sc.src);
        a.free(self.sc.buf);
        a.free(self.sc.seeds);
        a.free(self.sc.mark);
        a.free(self.sc.stack);
        @memset(mark, 0);
        self.sc = .{ .src = src, .buf = buf, .seeds = seeds, .mark = mark, .stack = stack, .n_states = ns, .n_edges = ne };
    }

    /// Grow a dense transition cache so `sid*nc + cls` is in range for
    /// every currently-interned `sid`; new rows start `UNKNOWN`. `inline`:
    /// this sits in the lazy DFA's per-transition miss path and the common
    /// case is the one-compare early return; left to the optimizer, LLVM 22
    /// (Zig 0.17) emitted it as an out-of-line call, costing 20-30% on the
    /// lazy-DFA tier (rebar capitals/noseyparker/long-english/aws-keys).
    pub inline fn ensureTrans(self: *LazyMemo, list: *std.ArrayListUnmanaged(i32), n_states: usize, nc: usize) !void {
        const need = n_states * nc;
        if (list.items.len >= need) return;
        const old = list.items.len;
        try list.resize(self.allocator, need);
        @memset(list.items[old..], UNKNOWN);
    }

    pub fn intern(self: *LazyMemo, list: []const u16, acc: bool) !u32 {
        const key = std.mem.sliceAsBytes(list);
        if (self.map.get(key)) |id| return id;
        const cost = 2 * key.len + 64; // list + map key + bookkeeping
        if (self.states.items.len >= self.cap or self.bytes + cost > self.byte_cap) {
            // Flush (same automaton; rebuilt on demand). The dense caches
            // hold ids from this generation — clear them and bump `gen`;
            // the driver restarts the current scan (RE2 flush-restart).
            for (self.states.items) |s| self.allocator.free(s);
            self.states.clearRetainingCapacity();
            self.accept.clearRetainingCapacity();
            var it = self.map.iterator();
            while (it.next()) |e| self.allocator.free(e.key_ptr.*);
            self.map.clearRetainingCapacity();
            self.atrans.clearRetainingCapacity();
            self.utrans.clearRetainingCapacity();
            self.bytes = 0;
            self.gen +%= 1;
        }
        // All fallible allocations first, each guarded; the list appends
        // (which transfer `owned` ownership to `self.states`) go LAST and
        // each cancels a prior errdefer by shrinking the slice on failure
        // — so no path frees `owned`/`kc` twice or leaks them on OOM. The
        // byte charge comes after the last `try`: an OOM must not leave a
        // phantom state in the accounting (spurious flushes / give-ups).
        const owned = try self.allocator.dupe(u16, list);
        errdefer self.allocator.free(owned);
        const kc = try self.allocator.dupe(u8, std.mem.sliceAsBytes(owned));
        errdefer self.allocator.free(kc);
        const id: u32 = @intCast(self.states.items.len);
        try self.states.append(self.allocator, owned);
        errdefer self.states.items.len -= 1;
        try self.accept.append(self.allocator, acc);
        errdefer self.accept.items.len -= 1;
        try self.map.put(self.allocator, kc, id); // last fallible op
        self.bytes += cost;
        return id;
    }

    pub fn rintern(self: *LazyMemo, list: []u16, has_start: bool) !u32 {
        // Canonical key: reverse reachability is order-independent — sort.
        std.mem.sort(u16, list, {}, std.sort.asc(u16));
        const key = std.mem.sliceAsBytes(list);
        if (self.rmap.get(key)) |id| return id;
        const cost = 2 * key.len + 64;
        if (self.rstates.items.len >= self.cap or self.rbytes + cost > self.byte_cap) {
            for (self.rstates.items) |s| self.allocator.free(s);
            self.rstates.clearRetainingCapacity();
            self.rhas_start.clearRetainingCapacity();
            var it = self.rmap.iterator();
            while (it.next()) |e| self.allocator.free(e.key_ptr.*);
            self.rmap.clearRetainingCapacity();
            self.rtrans.clearRetainingCapacity();
            self.rbytes = 0;
            self.rgen +%= 1;
        }
        const owned = try self.allocator.dupe(u16, list);
        errdefer self.allocator.free(owned);
        const kc = try self.allocator.dupe(u8, std.mem.sliceAsBytes(owned));
        errdefer self.allocator.free(kc);
        const id: u32 = @intCast(self.rstates.items.len);
        try self.rstates.append(self.allocator, owned);
        errdefer self.rstates.items.len -= 1;
        try self.rhas_start.append(self.allocator, has_start);
        errdefer self.rhas_start.items.len -= 1;
        try self.rmap.put(self.allocator, kc, id); // last fallible op
        self.rbytes += cost; // after the last `try` (see `intern`)
        return id;
    }
};
