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
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BtScratch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BtScratch) void {
        if (self.cap_words != 0) {
            self.allocator.free(self.visited);
            self.allocator.free(self.dirty);
        }
    }

    /// Ensure capacity for `nwords` bitset words, growing + zeroing only when
    /// the current buffer is too small. A reused buffer is already clean: every
    /// `matchAt` clears exactly the words it dirtied (recorded in `dirty`), so
    /// no set bit ever survives un-recorded between resets.
    pub fn ensure(self: *BtScratch, nwords: usize) !void {
        if (nwords <= self.cap_words) return;
        if (self.cap_words != 0) {
            self.allocator.free(self.visited);
            self.allocator.free(self.dirty);
        }
        self.visited = try self.allocator.alloc(u64, nwords);
        self.dirty = try self.allocator.alloc(usize, nwords);
        @memset(self.visited, 0);
        self.n_dirty = 0;
        self.cap_words = nwords;
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
        return .{ .nfa = nfa, .a_start = a_start, .a_end = a_end, .sc = sc, .n_pos1 = n_pos1, .owned = sc };
    }

    pub fn deinit(self: *BoundedBt) void {
        if (self.owned) |sc| {
            sc.deinit();
            sc.allocator.destroy(sc);
        }
    }

    // `hasBit` / `isWord` / `lookHolds` now live in `charclass.zig` (`cc`).

    /// Longest match starting exactly at `start` (greedy/lazy already encoded
    /// in NFA edge order; we take the deepest accept = leftmost-longest end
    /// for the surviving lineage, matching the DFA's `runFrom`).
    fn matchAt(self: *BoundedBt, input: []const u8, start: usize) ?usize {
        self.clearVisited();
        var best: ?usize = null;
        self.dfs(@intCast(self.nfa.start), input, start, &best);
        if (self.a_end) {
            if (best) |e| if (e == input.len) return e;
            return null;
        }
        return best;
    }

    fn dfs(self: *BoundedBt, state: u16, input: []const u8, pos: usize, best: *?usize) void {
        if (self.seen(state, pos)) return;

        if (state == @as(u16, @intCast(self.nfa.accept))) {
            if (best.* == null or pos > best.*.?) best.* = pos;
            // Don't return: a longer accept may lie beyond (greedy).
        }
        const nfa = self.nfa;
        var ei: usize = 0;
        while (ei < nfa.n_edges) : (ei += 1) {
            if (nfa.e_from[ei] != state) continue;
            const k = nfa.e_kind[ei];
            if (k == 0) {
                self.dfs(nfa.e_to[ei], input, pos, best);
            } else if (k == 2) {
                if (cc.lookHolds(nfa.e_look[ei], input, pos))
                    self.dfs(nfa.e_to[ei], input, pos, best); // zero-width
            } else if (pos < input.len and cc.hasBit(&nfa.sets[nfa.e_set[ei]], input[pos])) {
                self.dfs(nfa.e_to[ei], input, pos + 1, best);
            }
        }
    }

    pub fn findLeftmost(self: *BoundedBt, input: []const u8) ?Span {
        if (self.a_start) {
            if (self.matchAt(input, 0)) |e| return .{ .start = 0, .end = e };
            return null;
        }
        var s: usize = 0;
        while (s <= input.len) : (s += 1) {
            if (self.matchAt(input, s)) |e| return .{ .start = s, .end = e };
        }
        return null;
    }

    /// Leftmost match at/after absolute `from`, trying ONLY line-start
    /// positions (`from` itself iff it is a line start, then every byte after a
    /// `\n`). Sound only when every match must begin at a line start — i.e. the
    /// pattern is unconditionally prefixed by a multiline `^` (`start_line`),
    /// which `properties.leading_line_anchor` proves. `input` is the FULL
    /// haystack (absolute coordinates) so `lookHolds(.start_line)` sees the true
    /// preceding byte; the result span is absolute. Line starts ascend, so the
    /// first hit is the leftmost match.
    pub fn findLineStart(self: *BoundedBt, input: []const u8, from: usize) ?Span {
        var s = from;
        // Advance `from` to the first line start at/after it.
        if (!(s == 0 or (s <= input.len and s > 0 and input[s - 1] == '\n'))) {
            const nl = std.mem.indexOfScalarPos(u8, input, s, '\n') orelse return null;
            s = nl + 1;
        }
        while (s <= input.len) {
            if (self.matchAt(input, s)) |e| return .{ .start = s, .end = e };
            const nl = std.mem.indexOfScalarPos(u8, input, s, '\n') orelse return null;
            s = nl + 1;
        }
        return null;
    }

    pub fn isMatch(self: *BoundedBt, input: []const u8) bool {
        return self.findLeftmost(input) != null;
    }

    /// Leftmost match span + capture slots. `slots` (caller-sized to
    /// `2*(n_groups+1)`, set to -1 = unset) is filled by a priority-ordered
    /// trace-reconstruction over `input[span.start..span.end]` — the proven
    /// boundary search picks the span, this records the leftmost-first slot
    /// assignment for it. `(state,pos)` memo keeps it O(n·m); slot writes are
    /// restored on backtrack so sibling edges see clean state.
    pub fn captures(self: *BoundedBt, input: []const u8, slots: []i32) ?Span {
        const span = self.findLeftmost(input) orelse return null;
        @memset(slots, -1);
        self.clearVisited();
        slots[0] = @intCast(span.start);
        slots[1] = @intCast(span.end);
        _ = self.recCap(@intCast(self.nfa.start), input, span.start, span.end, slots);
        return span;
    }

    fn recCap(self: *BoundedBt, state: u16, input: []const u8, pos: usize, end: usize, slots: []i32) bool {
        if (self.seen(state, pos)) return false;
        if (state == @as(u16, @intCast(self.nfa.accept)) and pos == end) return true;

        const nfa = self.nfa;
        var ei: usize = 0;
        while (ei < nfa.n_edges) : (ei += 1) {
            if (nfa.e_from[ei] != state) continue;
            const k = nfa.e_kind[ei];
            if (k == 0) {
                const slot = nfa.e_slot[ei];
                var old: i32 = -1;
                if (slot >= 0) {
                    old = slots[@intCast(slot)];
                    slots[@intCast(slot)] = @intCast(pos);
                }
                if (self.recCap(nfa.e_to[ei], input, pos, end, slots)) return true;
                if (slot >= 0) slots[@intCast(slot)] = old;
            } else if (k == 2) {
                if (cc.lookHolds(nfa.e_look[ei], input, pos) and
                    self.recCap(nfa.e_to[ei], input, pos, end, slots)) return true;
            } else if (pos < input.len and cc.hasBit(&nfa.sets[nfa.e_set[ei]], input[pos])) {
                if (self.recCap(nfa.e_to[ei], input, pos + 1, end, slots)) return true;
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
            const f = bt1.findLeftmost(in);
            var bt2 = try BoundedBt.init(a, &nfa, h.anchored_start, h.anchored_end, in.len);
            defer bt2.deinit();
            const g = bt2.findLineStart(in, 0);
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
            const b = bt.findLeftmost(in);
            try std.testing.expectEqual(f == null, b == null);
            if (f) |fs| {
                try std.testing.expectEqual(fs.start, b.?.start);
                try std.testing.expectEqual(fs.end, b.?.end);
            }
        }
    }
}
