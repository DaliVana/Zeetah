//! NFA bounded backtracker — **separate** from `exec/backtrack.zig` (the
//! meta-engine HIR tree-walker that serves lookaround/backreferences and has
//! its own ReDoS budget). This one runs over the unified Thompson NFA with a
//! per-(state,pos) *visited bitset*, so every configuration is explored at
//! most once: strictly O(n·m), never exponential. It is the capture-capable
//! engine `regex.zig`'s `captures()` uses for the regular tier (alongside the
//! one-pass fast path), and is differential-tested against the full DFA.

const std = @import("std");
const thompson = @import("../thompson.zig");
const hir = @import("../hir.zig");
const cc = @import("charclass.zig");

const MAX_NFA = thompson.MAX_NFA;
const MAX_EDGES = thompson.MAX_EDGES;

/// The search and capture-trace walks use **explicit heap worklists**, not
/// native recursion. The `(state,pos)` visited memo bounds *work* to O(n·m),
/// but a single greedy lineage (e.g. `\b\w+\b` over a long run) reaches a
/// recursion *depth* of one frame per consumed byte — which overflowed the
/// native call stack on large inputs (a crash). Driving the walk from a
/// heap-allocated, geometrically-grown worklist removes the call-stack ceiling
/// entirely: only the (already allocated) `BtScratch` memory bounds it.
const WorkItem = struct { state: u16, pos: usize };

/// One frame of the explicit capture-trace stack — emulates a `recCap`
/// activation: `(state,pos)` plus the edge cursor `ei`, and the slot this frame
/// was entered through (`rslot`/`rold`) so it can be restored when the frame is
/// popped as failed (the recursive code's "restore on backtrack").
const CapFrame = struct { state: u16, pos: usize, ei: usize, rslot: i32, rold: i32 };

/// Capture slots = 2 per group (start,end); group 0 = whole match.
pub const MAX_SLOTS: usize = 2 * (hir.MAX_GROUPS + 1);

pub const Span = struct { start: usize, end: usize };

/// Reusable `(state,pos)` visited scratch for the bounded backtracker. Split
/// out of `BoundedBt` so it can be **pooled and reused across a whole `findAll`
/// loop** (mirrors the lazy DFA's `LazyMemo` pool). Re-creating and re-zeroing
/// this buffer per match — and, inside one search, `@memset`-ing the whole
/// `O(n_states·input.len)` bitset at every start position — made unanchored
/// `.bt_look` search O(n²) (e.g. a multiline `^…$` ran at ~0.1 MB/s). With a
/// pooled scratch the buffer is zeroed once and each `matchAt` clears only the
/// words it actually touched (`dirty`), so a quick-pruning pattern runs in O(n).
///
/// Conforms to the `cache.Pool(T)` contract: `init(allocator)` / `deinit`.
pub const BtScratch = struct {
    /// Packed `(state,pos)` bitset (bit `state*n_pos1 + pos`); 1 bit/config so
    /// each configuration is explored at most once (the O(n·m) guarantee).
    visited: []u64 = &.{},
    /// Indices of the `visited` words dirtied since the last reset. Clearing
    /// only these is what turns the per-`matchAt` reset from
    /// O(n_states·input.len) into O(words-actually-touched). Capacity matches
    /// `visited` (worst case: every word dirtied once).
    dirty: []usize = &.{},
    n_dirty: usize = 0,
    cap_words: usize = 0,
    /// Explicit DFS worklist for the reachability search (`reach`), and the
    /// capture-trace stack (`recCap`). Both replace native recursion; they grow
    /// geometrically and are pooled/reused across a whole `findAll` loop. Live
    /// size is the search frontier / trace depth — typically tiny, far below the
    /// `visited` bitset.
    reach: []WorkItem = &.{},
    reach_cap: usize = 0,
    cap_stack: []CapFrame = &.{},
    cap_stack_cap: usize = 0,
    /// Per-state out-edge CSR over the NFA (counting-sort, priority-preserving):
    /// `edge_order[edge_off[s]..edge_off[s+1]]` are state `s`'s out-edge ids in
    /// original (= NFA emission = priority) order. Built once per (scratch, NFA)
    /// by `ensureIndex` and reused across a whole `findAll` loop, so `matchAt`/
    /// `recCap` iterate a state's *own* out-edges instead of rescanning all
    /// `n_edges` at every visited `(state,pos)` — the O(n_states·len·n_edges) →
    /// O(n_states·len) win on deep-alternation (`bt_look`) and capture patterns.
    /// Mirrors `onepass.EdgeIndex`; the priority order is preserved (stable sort)
    /// because `recCap`'s leftmost-first trace depends on it.
    edge_off: [MAX_NFA + 1]u16 = [_]u16{0} ** (MAX_NFA + 1),
    edge_order: [MAX_EDGES]u16 = undefined,
    /// The NFA `edge_off`/`edge_order` were built for (`null` ⇒ not yet built);
    /// `ensureIndex` skips the rebuild when the pointer is unchanged.
    idx_nfa: ?*const thompson.Nfa(null) = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BtScratch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BtScratch) void {
        if (self.cap_words != 0) {
            self.allocator.free(self.visited);
            self.allocator.free(self.dirty);
        }
        if (self.reach_cap != 0) self.allocator.free(self.reach);
        if (self.cap_stack_cap != 0) self.allocator.free(self.cap_stack);
    }

    /// Ensure capacity for `nwords` bitset words, growing + zeroing only when
    /// the current buffer is too small. A reused buffer is already clean: every
    /// `matchAt` clears exactly the words it dirtied (recorded in `dirty`), so
    /// no set bit ever survives un-recorded between resets.
    pub fn ensure(self: *BtScratch, nwords: usize) !void {
        if (nwords <= self.cap_words) return;
        // Commit-after-success: allocate both new buffers BEFORE freeing the old
        // ones. Freeing first (with `cap_words` still set) would, on an OOM from
        // either alloc, leave freed pointers behind a non-zero `cap_words` → a
        // double-free/UAF in `deinit`. `errdefer` frees the first buffer if the
        // second alloc fails. (Pooled scratch reused across `findAll`, so the
        // grow branch is reachable in normal use.)
        const v = try self.allocator.alloc(u64, nwords);
        errdefer self.allocator.free(v);
        const d = try self.allocator.alloc(usize, nwords);
        if (self.cap_words != 0) {
            self.allocator.free(self.visited);
            self.allocator.free(self.dirty);
        }
        self.visited = v;
        self.dirty = d;
        @memset(self.visited, 0);
        self.n_dirty = 0;
        self.cap_words = nwords;
    }

    /// Build the per-state out-edge CSR for `nfa` (idempotent: a no-op when the
    /// index is already built for this exact NFA, so the hot `findAll` loop pays
    /// one pointer compare per `BoundedBt` construction). Counting sort by
    /// `e_from`, iterated in edge order ⇒ each state's out-edges keep their
    /// original priority order (required by `recCap`). Allocation-free.
    pub fn ensureIndex(self: *BtScratch, nfa: *const thompson.Nfa(null)) void {
        if (self.idx_nfa) |p| {
            if (p == nfa) return;
        }
        @memset(self.edge_off[0 .. nfa.n_states + 1], 0);
        var ei: usize = 0;
        while (ei < nfa.n_edges) : (ei += 1) self.edge_off[nfa.e_from[ei] + 1] += 1;
        var s: usize = 0;
        while (s < nfa.n_states) : (s += 1) self.edge_off[s + 1] += self.edge_off[s];
        var next: [MAX_NFA]u16 = undefined;
        s = 0;
        while (s < nfa.n_states) : (s += 1) next[s] = self.edge_off[s];
        ei = 0;
        while (ei < nfa.n_edges) : (ei += 1) {
            const f = nfa.e_from[ei];
            self.edge_order[next[f]] = @intCast(ei);
            next[f] += 1;
        }
        self.idx_nfa = nfa;
    }
};

pub const BoundedBt = struct {
    nfa: *const thompson.Nfa(null),
    a_start: bool,
    a_end: bool,
    /// Borrowed visited scratch — pooled on the hot `findAll` path (`initWith`),
    /// or owned via `init` for standalone/test callers (`owned` then frees it).
    sc: *BtScratch,
    n_pos1: usize,
    owned: ?*BtScratch = null,

    inline fn seen(self: *BoundedBt, state: u16, pos: usize) bool {
        const idx = @as(usize, state) * self.n_pos1 + pos;
        const w = idx >> 6;
        const bit = @as(u64, 1) << @intCast(idx & 63);
        const cur = self.sc.visited[w];
        if (cur & bit != 0) return true;
        if (cur == 0) { // first bit set in this word since the last reset
            self.sc.dirty[self.sc.n_dirty] = w;
            self.sc.n_dirty += 1;
        }
        self.sc.visited[w] = cur | bit;
        return false;
    }

    /// Zero only the `visited` words touched since the last reset (replaces a
    /// full-bitset `@memset` that was O(n_states·input.len) *per start pos*).
    inline fn clearVisited(self: *BoundedBt) void {
        const sc = self.sc;
        for (sc.dirty[0..sc.n_dirty]) |w| sc.visited[w] = 0;
        sc.n_dirty = 0;
    }

    /// Borrow an externally-owned (pooled) scratch the caller has already
    /// `ensure`d for `n_pos1`. No allocation; cannot fail.
    pub fn initWith(
        nfa: *const thompson.Nfa(null),
        a_start: bool,
        a_end: bool,
        sc: *BtScratch,
        n_pos1: usize,
    ) BoundedBt {
        sc.ensureIndex(nfa); // build/refresh the per-state out-edge CSR (idempotent)
        return .{ .nfa = nfa, .a_start = a_start, .a_end = a_end, .sc = sc, .n_pos1 = n_pos1 };
    }

    /// Allocate and own a scratch sized to `max_input` (standalone/test path;
    /// the hot `findAll` path uses a pooled scratch via `initWith`).
    pub fn init(
        allocator: std.mem.Allocator,
        nfa: *const thompson.Nfa(null),
        a_start: bool,
        a_end: bool,
        max_input: usize,
    ) !BoundedBt {
        const sc = try allocator.create(BtScratch);
        errdefer allocator.destroy(sc);
        sc.* = BtScratch.init(allocator);
        const n_pos1 = max_input + 1;
        try sc.ensure((nfa.n_states * n_pos1 + 63) / 64);
        sc.ensureIndex(nfa); // build the per-state out-edge CSR
        return .{ .nfa = nfa, .a_start = a_start, .a_end = a_end, .sc = sc, .n_pos1 = n_pos1, .owned = sc };
    }

    pub fn deinit(self: *BoundedBt) void {
        if (self.owned) |sc| {
            sc.deinit();
            sc.allocator.destroy(sc);
        }
    }

    // `hasBit` / `isWord` / `lookHolds` now live in `charclass.zig` (`cc`).

    /// Push `(state,pos)` onto the reachability worklist iff not already visited
    /// (push-time `seen` ⇒ each configuration is enqueued at most once, so the
    /// worklist holds only the live frontier). Grows the pooled buffer
    /// geometrically; returns the new count.
    fn pushReach(self: *BoundedBt, n: usize, state: u16, pos: usize) std.mem.Allocator.Error!usize {
        if (self.seen(state, pos)) return n;
        const sc = self.sc;
        if (n == sc.reach_cap) {
            const new_cap = if (sc.reach_cap == 0) 256 else sc.reach_cap * 2;
            sc.reach = try sc.allocator.realloc(sc.reach, new_cap);
            sc.reach_cap = new_cap;
        }
        sc.reach[n] = .{ .state = state, .pos = pos };
        return n + 1;
    }

    /// Longest match starting exactly at `start` (greedy/lazy already encoded
    /// in NFA edge order; we take the deepest accept = leftmost-longest end
    /// for the surviving lineage, matching the DFA's `runFrom`). Reachability is
    /// order-independent, so an explicit LIFO worklist computes the same max
    /// accept as the former recursion without a call-stack depth limit.
    fn matchAt(self: *BoundedBt, input: []const u8, start: usize) std.mem.Allocator.Error!?usize {
        self.clearVisited();
        var best: ?usize = null;
        var n = try self.pushReach(0, @intCast(self.nfa.start), start);
        const nfa = self.nfa;
        while (n > 0) {
            n -= 1;
            const state = self.sc.reach[n].state;
            const pos = self.sc.reach[n].pos;
            if (state == @as(u16, @intCast(nfa.accept))) {
                if (best == null or pos > best.?) best = pos;
                // Don't stop: a longer accept may lie beyond (greedy).
            }
            // Only this state's own out-edges (CSR), in priority order — not a
            // rescan of all `n_edges` per visited config (see `BtScratch`).
            var c: usize = self.sc.edge_off[state];
            const c_end: usize = self.sc.edge_off[@as(usize, state) + 1];
            while (c < c_end) : (c += 1) {
                const ei: usize = self.sc.edge_order[c];
                const k = nfa.e_kind[ei];
                if (k == 0) {
                    n = try self.pushReach(n, nfa.e_to[ei], pos);
                } else if (k == 2) {
                    if (cc.lookHolds(nfa.e_look[ei], input, pos))
                        n = try self.pushReach(n, nfa.e_to[ei], pos); // zero-width
                } else if (pos < input.len and cc.hasBit(&nfa.sets[nfa.e_set[ei]], input[pos])) {
                    n = try self.pushReach(n, nfa.e_to[ei], pos + 1);
                }
            }
        }
        if (self.a_end) {
            if (best) |e| if (e == input.len) return e;
            return null;
        }
        return best;
    }

    pub fn findLeftmost(self: *BoundedBt, input: []const u8) std.mem.Allocator.Error!?Span {
        if (self.a_start) {
            if (try self.matchAt(input, 0)) |e| return .{ .start = 0, .end = e };
            return null;
        }
        var s: usize = 0;
        while (s <= input.len) : (s += 1) {
            if (try self.matchAt(input, s)) |e| return .{ .start = s, .end = e };
        }
        return null;
    }

    /// Leftmost match at/after absolute `from`, trying ONLY line-start
    /// positions (`from` itself iff it is a line start, then every byte after a
    /// `\n`). Sound only when every match must begin at a line start — i.e. the
    /// pattern is unconditionally prefixed by a multiline `^` (`start_line`),
    /// which `properties.analyzeBoundaries` proves (`bounds.start == .line`).
    /// `input` is the FULL
    /// haystack (absolute coordinates) so `lookHolds(.start_line)` sees the true
    /// preceding byte; the result span is absolute. Line starts ascend, so the
    /// first hit is the leftmost match.
    pub fn findLineStart(self: *BoundedBt, input: []const u8, from: usize, first: ?*const [32]u8) std.mem.Allocator.Error!?Span {
        var s = from;
        // Advance `from` to the first line start at/after it.
        if (!(s == 0 or (s <= input.len and s > 0 and input[s - 1] == '\n'))) {
            const nl = std.mem.indexOfScalarPos(u8, input, s, '\n') orelse return null;
            s = nl + 1;
        }
        while (s <= input.len) {
            // First-byte reject: a non-nullable body can only begin on a member
            // of `first`, so skip whole lines with one byte test instead of
            // entering the (dominant-cost) `matchAt`. `s == input.len` (trailing
            // empty line) has no byte to test, so fall through to `matchAt`.
            const skip = if (first) |set|
                (s < input.len and !cc.hasBit(set, input[s]))
            else
                false;
            if (!skip) {
                if (try self.matchAt(input, s)) |e| return .{ .start = s, .end = e };
            }
            const nl = std.mem.indexOfScalarPos(u8, input, s, '\n') orelse return null;
            s = nl + 1;
        }
        return null;
    }

    pub fn isMatch(self: *BoundedBt, input: []const u8) std.mem.Allocator.Error!bool {
        return (try self.findLeftmost(input)) != null;
    }

    /// Push a capture-trace frame; grows the pooled stack geometrically.
    fn pushCap(self: *BoundedBt, sp: usize, frame: CapFrame) std.mem.Allocator.Error!usize {
        const sc = self.sc;
        if (sp == sc.cap_stack_cap) {
            const new_cap = if (sc.cap_stack_cap == 0) 256 else sc.cap_stack_cap * 2;
            sc.cap_stack = try sc.allocator.realloc(sc.cap_stack, new_cap);
            sc.cap_stack_cap = new_cap;
        }
        sc.cap_stack[sp] = frame;
        return sp + 1;
    }

    /// Leftmost match span + capture slots. `slots` (caller-sized to
    /// `2*(n_groups+1)`, set to -1 = unset) is filled by a priority-ordered
    /// trace-reconstruction over `input[span.start..span.end]` — the proven
    /// boundary search picks the span, this records the leftmost-first slot
    /// assignment for it. `(state,pos)` memo keeps it O(n·m); slot writes are
    /// restored on backtrack so sibling edges see clean state.
    pub fn captures(self: *BoundedBt, input: []const u8, slots: []i32) std.mem.Allocator.Error!?Span {
        const span = (try self.findLeftmost(input)) orelse return null;
        @memset(slots, -1);
        self.clearVisited();
        slots[0] = @intCast(span.start);
        slots[1] = @intCast(span.end);
        _ = try self.recCap(@intCast(self.nfa.start), input, span.start, span.end, slots);
        return span;
    }

    /// Explicit-stack equivalent of the former recursive priority trace: find
    /// the first (edge-order/DFS-priority) path from `state0@start` to
    /// `accept@end`, writing capture slots along the way and restoring them when
    /// a frame is popped as failed — exactly the recursion's save/restore, but
    /// driven from a heap stack so a long lineage can't overflow the native
    /// stack. The `(state,pos)` memo keeps it O(n·m). Returns true once a
    /// complete trace is found (its slot writes are then left in `slots`).
    fn recCap(self: *BoundedBt, state0: u16, input: []const u8, start: usize, end: usize, slots: []i32) std.mem.Allocator.Error!bool {
        const nfa = self.nfa;
        const accept: u16 = @intCast(nfa.accept);
        // Mirror the recursive entry: seen-check then accept-check for the root.
        if (self.seen(state0, start)) return false;
        if (state0 == accept and start == end) return true;
        // `CapFrame.ei` is a cursor into this state's CSR run `edge_order[
        // edge_off[state] .. edge_off[state+1])` (priority order), not a global
        // edge index — so the frame walks only its own out-edges.
        var sp = try self.pushCap(0, .{ .state = state0, .pos = start, .ei = self.sc.edge_off[state0], .rslot = -1, .rold = -1 });
        while (sp > 0) {
            const cur = sp - 1; // index, not a pointer — `pushCap` may realloc
            const state = self.sc.cap_stack[cur].state;
            const pos = self.sc.cap_stack[cur].pos;
            var descended = false;
            while (self.sc.cap_stack[cur].ei < self.sc.edge_off[@as(usize, state) + 1]) {
                const ei: usize = self.sc.edge_order[self.sc.cap_stack[cur].ei];
                self.sc.cap_stack[cur].ei += 1;
                const k = nfa.e_kind[ei];
                if (k == 0) {
                    const slot = nfa.e_slot[ei];
                    var old: i32 = -1;
                    if (slot >= 0) {
                        old = slots[@intCast(slot)];
                        slots[@intCast(slot)] = @intCast(pos);
                    }
                    const to = nfa.e_to[ei];
                    if (self.seen(to, pos)) {
                        if (slot >= 0) slots[@intCast(slot)] = old; // child "returns false" at once
                        continue;
                    }
                    if (to == accept and pos == end) return true; // success: slot write kept
                    sp = try self.pushCap(sp, .{ .state = to, .pos = pos, .ei = self.sc.edge_off[to], .rslot = slot, .rold = old });
                    descended = true;
                    break;
                } else if (k == 2) {
                    if (cc.lookHolds(nfa.e_look[ei], input, pos)) {
                        const to = nfa.e_to[ei];
                        if (self.seen(to, pos)) continue;
                        if (to == accept and pos == end) return true;
                        sp = try self.pushCap(sp, .{ .state = to, .pos = pos, .ei = self.sc.edge_off[to], .rslot = -1, .rold = -1 });
                        descended = true;
                        break;
                    }
                } else if (pos < input.len and cc.hasBit(&nfa.sets[nfa.e_set[ei]], input[pos])) {
                    const to = nfa.e_to[ei];
                    if (self.seen(to, pos + 1)) continue;
                    if (to == accept and pos + 1 == end) return true;
                    sp = try self.pushCap(sp, .{ .state = to, .pos = pos + 1, .ei = self.sc.edge_off[to], .rslot = -1, .rold = -1 });
                    descended = true;
                    break;
                }
            }
            if (!descended) {
                // Frame exhausted ("return false"): pop it and have the parent
                // restore the slot it wrote to enter this frame.
                const popped = self.sc.cap_stack[sp - 1];
                sp -= 1;
                if (popped.rslot >= 0) slots[@intCast(popped.rslot)] = popped.rold;
            }
        }
        return false;
    }
};

test "bounded_bt: findLineStart equals per-position scan (leading line anchor)" {
    const parser = @import("../parser.zig");
    const a = std.testing.allocator;

    // Each pattern is unconditionally prefixed by `(?m)^`, so findLineStart
    // (line-start enumeration) must return the identical first match as the
    // per-position findLeftmost.
    const pats = [_][]const u8{ "(?m)^[0-9]+", "(?m)^[0-9]{4}-[0-9]{2}", "(?m)^foo.*$" };
    const ins = [_][]const u8{
        "",       "abc",        "123",          "\n123",
        "x\n123", "ab\n2025-06\ncd", "no\nmatch\nhere", "123\n",
        "\n\n42", "foo bar\nfoozz\n", "trailing\n", "foo",
    };
    for (pats) |p| {
        var h = hir.Hir(null).initRuntime();
        defer h.deinit(a);
        parser.parse(null, &h, a, p, .{}) catch continue;
        var nfa = try thompson.build(null, &h);
        for (ins) |in| {
            var bt1 = try BoundedBt.init(a, &nfa, h.anchored_start, h.anchored_end, in.len);
            defer bt1.deinit();
            const f = try bt1.findLeftmost(in);
            var bt2 = try BoundedBt.init(a, &nfa, h.anchored_start, h.anchored_end, in.len);
            defer bt2.deinit();
            const g = try bt2.findLineStart(in, 0, null);
            try std.testing.expectEqual(f == null, g == null);
            if (f) |fs| {
                try std.testing.expectEqual(fs.start, g.?.start);
                try std.testing.expectEqual(fs.end, g.?.end);
            }
        }
    }
}

test "bounded_bt: boundaries agree with the full DFA" {
    const parser = @import("../parser.zig");
    const full_dfa = @import("full_dfa.zig");
    const core = @import("core.zig");
    const a = std.testing.allocator;

    const pats = [_][]const u8{ "a.*c", "ab*c", "cat|dog", "[0-9]+", "^ab+$" };
    const ins = [_][]const u8{ "", "ac", "xxabbcyy", "dog", "12 34", "abbb", "abc" };

    for (pats) |p| {
        var h = hir.Hir(null).initRuntime();
        defer h.deinit(a);
        parser.parse(null, &h, a, p, .{}) catch continue;
        var nfa = try thompson.build(null, &h);
        const fd = full_dfa.compute(null, &nfa, h.anchored_start, h.anchored_end);
        if (fd.outcome != .ok) continue;

        for (ins) |in| {
            var bt = try BoundedBt.init(a, &nfa, h.anchored_start, h.anchored_end, in.len);
            defer bt.deinit();
            const f = core.findLeftmost(&fd, in);
            const b = try bt.findLeftmost(in);
            try std.testing.expectEqual(f == null, b == null);
            if (f) |fs| {
                try std.testing.expectEqual(fs.start, b.?.start);
                try std.testing.expectEqual(fs.end, b.?.end);
            }
        }
    }
}
