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
    }

    /// Grow a dense transition cache so `sid*nc + cls` is in range for
    /// every currently-interned `sid`; new rows start `UNKNOWN`.
    pub fn ensureTrans(self: *LazyMemo, list: *std.ArrayListUnmanaged(i32), n_states: usize, nc: usize) !void {
        const need = n_states * nc;
        if (list.items.len >= need) return;
        const old = list.items.len;
        try list.resize(self.allocator, need);
        @memset(list.items[old..], UNKNOWN);
    }

    pub fn intern(self: *LazyMemo, list: []const u16, acc: bool) !u32 {
        const key = std.mem.sliceAsBytes(list);
        if (self.map.get(key)) |id| return id;
        if (self.states.items.len >= self.cap) {
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
            self.gen +%= 1;
        }
        // All fallible allocations first, each guarded; the list appends
        // (which transfer `owned` ownership to `self.states`) go LAST and
        // each cancels a prior errdefer by shrinking the slice on failure
        // — so no path frees `owned`/`kc` twice or leaks them on OOM.
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
        return id;
    }

    pub fn rintern(self: *LazyMemo, list: []u16, has_start: bool) !u32 {
        // Canonical key: reverse reachability is order-independent — sort.
        std.mem.sort(u16, list, {}, std.sort.asc(u16));
        const key = std.mem.sliceAsBytes(list);
        if (self.rmap.get(key)) |id| return id;
        if (self.rstates.items.len >= self.cap) {
            for (self.rstates.items) |s| self.allocator.free(s);
            self.rstates.clearRetainingCapacity();
            self.rhas_start.clearRetainingCapacity();
            var it = self.rmap.iterator();
            while (it.next()) |e| self.allocator.free(e.key_ptr.*);
            self.rmap.clearRetainingCapacity();
            self.rtrans.clearRetainingCapacity();
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
        return id;
    }
};
