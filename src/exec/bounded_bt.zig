//! NFA bounded backtracker — **separate** from `exec/backtrack.zig` (the
//! meta-engine HIR tree-walker that serves lookaround/backreferences and has
//! its own ReDoS budget). This one runs over the unified Thompson NFA with a
//! per-(state,pos) *visited bitset*, so every configuration is explored at
//! most once: strictly O(n·m), never exponential. It is the capture-capable
//! engine `regex.zig`'s `captures()` uses for the regular tier (alongside the
//! one-pass fast path), and is differential-tested against the full DFA.
//!
//! Semantics: **leftmost-first** (Perl/PCRE/RE2/Rust). The walk is a
//! priority-ordered depth-first search — each state's out-edges in NFA
//! emission (= priority) order — that returns at the FIRST accept it reaches.
//! With the `(state,pos)` memo that is exactly the highest-priority match from
//! a start position (a configuration that already failed fails again; one that
//! succeeded would already have returned). Searches run over the FULL input in
//! absolute coordinates, so a look-behind (`\b`, `^`, `(?m)^`) at a resume
//! position sees the real preceding byte, never a synthetic start-of-text.
//!
//! The visited bitset covers only the searched window `[base, base+n_pos1)`,
//! so resuming late in a haystack (or reconstructing captures over one match
//! span) needs `n_states × window` bits, not `n_states × input.len`.

const std = @import("std");
const thompson = @import("../thompson.zig");
const hir = @import("../hir.zig");
const cc = @import("charclass.zig");
const search = @import("search.zig");
const EdgeIndex = @import("nfa_index.zig").EdgeIndex;

const MAX_NFA = thompson.MAX_NFA;
const MAX_EDGES = thompson.MAX_EDGES;

/// One frame of the explicit DFS stack: `(state,pos)` plus the cursor `ei` into
/// this state's CSR out-edge run, and the capture slot this frame was entered
/// through (`rslot`/`rold`) so it can be restored when the frame is popped as
/// failed (the recursive formulation's "restore on backtrack"). A heap stack —
/// not native recursion — because one greedy lineage (`\b\w+\b` over a long
/// run) is one frame per consumed byte, which overflowed the call stack.
const Frame = struct { state: u16, pos: usize, ei: usize, rslot: i32, rold: hir.Slot };

/// Capture slots = 2 per group (start,end); group 0 = whole match. Sized to the
/// runtime group ceiling (callers pass `2*(n_groups+1)`-long slices).
pub const MAX_SLOTS: usize = 2 * (hir.MAX_GROUPS_RUNTIME + 1);

/// Bytes of per-window scratch the backtracker may use for one search before
/// the caller should switch to the PikeVM (`exec/pikevm.zig`), whose memory is
/// O(states) regardless of input length. Counts BOTH buffers `ensure`
/// allocates for the window: the `(state,pos)` visited bitset (1 bit per
/// configuration) and its dirty-word list (one `u32` per bitset word, i.e.
/// ½ bit per configuration). `n_states × window` configurations whose scratch
/// exceeds this ⇒ `fits` is false.
pub const VISITED_BUDGET_BYTES: usize = 8 << 20;

/// Whether an `n_states × window_len` search fits the scratch budget —
/// exactly the bytes `ensureWindow(n_states, window_len + 1)` would allocate.
pub fn fits(n_states: usize, window_len: usize) bool {
    const bits = std.math.mul(usize, n_states, window_len + 1) catch return false;
    return scratchBytes(bitsetWords(bits)) <= VISITED_BUDGET_BYTES;
}

/// `u64` words holding `bits` configurations.
inline fn bitsetWords(bits: usize) usize {
    return bits / 64 + @intFromBool(bits % 64 != 0);
}

/// Bytes `ensure(nwords)` allocates: the visited words + a `u32` dirty index
/// per word.
inline fn scratchBytes(nwords: usize) usize {
    return nwords * (@sizeOf(u64) + @sizeOf(u32));
}

pub const Span = search.Span;

/// Reusable `(state,pos)` visited scratch for the bounded backtracker. Split
/// out of `BoundedBt` so it can be **pooled and reused across a whole `findAll`
/// loop** (mirrors the lazy DFA's `LazyMemo` pool). Re-creating and re-zeroing
/// this buffer per match — and, inside one search, `@memset`-ing the whole
/// `O(n_states·input.len)` bitset at every start position — made unanchored
/// `.bt_look` search O(n²). With a pooled scratch the buffer is zeroed once and
/// each start attempt clears only the words it actually touched (`dirty`).
///
/// Conforms to the `cache.Pool(T)` contract: `init(allocator)` / `deinit`.
pub const BtScratch = struct {
    /// Packed `(state,pos)` bitset (bit `state*n_pos1 + (pos-base)`); 1
    /// bit/config so each configuration is explored at most once (O(n·m)).
    visited: []u64 = &.{},
    /// Indices of the `visited` words dirtied since the last reset. Clearing
    /// only these turns the per-attempt reset from O(n_states·window) into
    /// O(words-actually-touched). Capacity matches `visited`; `u32` (a word
    /// index under the budget is far below 2³²) so this list costs half the
    /// bitset, not the same again — `fits` counts both.
    dirty: []u32 = &.{},
    n_dirty: usize = 0,
    cap_words: usize = 0,
    /// Explicit DFS stack; grows geometrically, pooled across a `findAll`.
    stack: []Frame = &.{},
    stack_cap: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BtScratch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BtScratch) void {
        if (self.cap_words != 0) {
            self.allocator.free(self.visited);
            self.allocator.free(self.dirty);
        }
        if (self.stack_cap != 0) self.allocator.free(self.stack);
    }

    /// Ensure capacity for `nwords` bitset words, growing + zeroing only when
    /// the current buffer is too small. A reused buffer is already clean: every
    /// attempt clears exactly the words it dirtied, so no set bit ever survives
    /// un-recorded between resets.
    pub fn ensure(self: *BtScratch, nwords: usize) !void {
        if (nwords <= self.cap_words) return;
        // Commit-after-success: allocate both new buffers BEFORE freeing the old
        // ones, so an OOM never leaves freed pointers behind a non-zero
        // `cap_words` (double-free in `deinit`).
        const v = try self.allocator.alloc(u64, nwords);
        errdefer self.allocator.free(v);
        const d = try self.allocator.alloc(u32, nwords);
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

    /// Ensure the bitset covers `n_states × n_pos1` configurations.
    pub fn ensureWindow(self: *BtScratch, n_states: usize, n_pos1: usize) !void {
        try self.ensure(bitsetWords(n_states * n_pos1));
    }
};

pub const BoundedBt = struct {
    nfa: *const thompson.Nfa(null),
    /// The NFA's per-state out-edge index (priority order), so the walk
    /// iterates a state's *own* out-edges instead of rescanning all `n_edges`
    /// at every visited `(state,pos)`. Borrowed from the `Regex` that owns the
    /// NFA (`initWith`), or built and owned here (`init`/`initRange`).
    idx: EdgeIndex,
    a_start: bool,
    a_end: bool,
    /// Borrowed visited scratch — pooled on the hot `findAll` path (`initWith`),
    /// or owned via `init` for standalone/test callers (`owned` then frees it).
    sc: *BtScratch,
    /// The bitset window: positions `[base, base + n_pos1)` (absolute).
    base: usize,
    n_pos1: usize,
    owned: ?*BtScratch = null,
    /// `idx` was built by `init`/`initRange` (freed with `owned`'s allocator).
    owns_idx: bool = false,

    inline fn seen(self: *BoundedBt, state: u16, pos: usize) bool {
        std.debug.assert(pos >= self.base and pos - self.base < self.n_pos1);
        const idx = @as(usize, state) * self.n_pos1 + (pos - self.base);
        const w = idx >> 6;
        const bit = @as(u64, 1) << @intCast(idx & 63);
        const cur = self.sc.visited[w];
        if (cur & bit != 0) return true;
        if (cur == 0) { // first bit set in this word since the last reset
            self.sc.dirty[self.sc.n_dirty] = @intCast(w);
            self.sc.n_dirty += 1;
        }
        self.sc.visited[w] = cur | bit;
        return false;
    }

    /// Zero only the `visited` words touched since the last reset.
    inline fn clearVisited(self: *BoundedBt) void {
        const sc = self.sc;
        for (sc.dirty[0..sc.n_dirty]) |w| sc.visited[w] = 0;
        sc.n_dirty = 0;
    }

    /// Borrow an externally-owned (pooled) scratch the caller has already
    /// `ensureWindow`ed for `(n_states, n_pos1)`, and the NFA's edge index
    /// (`idx`, built once by the NFA's owner). The window starts at absolute
    /// position `base`. No allocation; cannot fail.
    pub fn initWith(
        nfa: *const thompson.Nfa(null),
        idx: EdgeIndex,
        a_start: bool,
        a_end: bool,
        sc: *BtScratch,
        base: usize,
        n_pos1: usize,
    ) BoundedBt {
        return .{ .nfa = nfa, .idx = idx, .a_start = a_start, .a_end = a_end, .sc = sc, .base = base, .n_pos1 = n_pos1 };
    }

    /// Allocate and own a scratch whose window is `[0, max_input]`
    /// (standalone/test path; the hot paths use a pooled scratch).
    pub fn init(
        allocator: std.mem.Allocator,
        nfa: *const thompson.Nfa(null),
        a_start: bool,
        a_end: bool,
        max_input: usize,
    ) !BoundedBt {
        return initRange(allocator, nfa, a_start, a_end, 0, max_input);
    }

    /// Allocate and own a scratch whose window is `[base, base + len]`.
    pub fn initRange(
        allocator: std.mem.Allocator,
        nfa: *const thompson.Nfa(null),
        a_start: bool,
        a_end: bool,
        base: usize,
        len: usize,
    ) !BoundedBt {
        const sc = try allocator.create(BtScratch);
        errdefer allocator.destroy(sc);
        sc.* = BtScratch.init(allocator);
        errdefer sc.deinit();
        try sc.ensureWindow(nfa.n_states, len + 1);
        const idx = try EdgeIndex.build(allocator, nfa);
        return .{ .nfa = nfa, .idx = idx, .a_start = a_start, .a_end = a_end, .sc = sc, .base = base, .n_pos1 = len + 1, .owned = sc, .owns_idx = true };
    }

    pub fn deinit(self: *BoundedBt) void {
        if (self.owned) |sc| {
            if (self.owns_idx) self.idx.deinit(sc.allocator);
            sc.deinit();
            sc.allocator.destroy(sc);
        }
    }

    fn push(self: *BoundedBt, sp: usize, frame: Frame) std.mem.Allocator.Error!usize {
        const sc = self.sc;
        if (sp == sc.stack_cap) {
            const new_cap = if (sc.stack_cap == 0) 256 else sc.stack_cap * 2;
            sc.stack = try sc.allocator.realloc(sc.stack, new_cap);
            sc.stack_cap = new_cap;
        }
        sc.stack[sp] = frame;
        return sp + 1;
    }

    /// Accept condition at `pos`: an exact end when reconstructing a known
    /// span (`want_end`), otherwise `$`/`\z` folding (`a_end`) or anywhere.
    inline fn acceptsAt(self: *const BoundedBt, input: []const u8, pos: usize, want_end: ?usize) bool {
        if (want_end) |e| return pos == e;
        return !self.a_end or pos == input.len;
    }

    /// THE walk: priority-ordered DFS from `(nfa.start, start)` returning the
    /// end of the first (= highest-priority, leftmost-first) path to accept, or
    /// null. `slots` (optional, pre-set by the caller) receives the capture
    /// writes of that path; writes on failed branches are restored on the way
    /// back. `(state,pos)` memo ⇒ O(n_states × window).
    fn dfs(self: *BoundedBt, input: []const u8, start: usize, want_end: ?usize, slots: ?[]hir.Slot) std.mem.Allocator.Error!?usize {
        self.clearVisited();
        const nfa = self.nfa;
        const accept: u16 = @intCast(nfa.accept);
        const root: u16 = @intCast(nfa.start);
        _ = self.seen(root, start);
        if (root == accept) return if (self.acceptsAt(input, start, want_end)) start else null;
        const idx = self.idx;
        var sp = try self.push(0, .{ .state = root, .pos = start, .ei = idx.off[root], .rslot = -1, .rold = -1 });
        while (sp > 0) {
            const cur = sp - 1; // index, not a pointer — `push` may realloc
            const state = self.sc.stack[cur].state;
            const pos = self.sc.stack[cur].pos;
            const e_end = idx.off[@as(usize, state) + 1];
            var descended = false;
            while (self.sc.stack[cur].ei < e_end) {
                const ei: usize = idx.order[self.sc.stack[cur].ei];
                self.sc.stack[cur].ei += 1;
                var npos = pos;
                var slot: i32 = -1;
                switch (nfa.e_kind[ei]) {
                    .eps => slot = nfa.e_slot[ei],
                    .look => if (!cc.lookHolds(nfa.e_look[ei], input, pos)) continue,
                    .consume => {
                        if (pos >= input.len or !cc.hasBit(&nfa.sets[nfa.e_set[ei]], input[pos])) continue;
                        npos = pos + 1;
                    },
                }
                if (want_end) |e| if (npos > e) continue; // never walk past a known span
                const to = nfa.e_to[ei];
                if (self.seen(to, npos)) continue;
                var old: hir.Slot = -1;
                if (slots) |sl| if (slot >= 0) {
                    old = sl[@intCast(slot)];
                    sl[@intCast(slot)] = @intCast(npos);
                };
                if (to == accept) {
                    if (self.acceptsAt(input, npos, want_end)) return npos; // slot writes kept
                    if (slots) |sl| if (slot >= 0) {
                        sl[@intCast(slot)] = old;
                    };
                    continue; // `accept` has no out-edges
                }
                const child: Frame = .{ .state = to, .pos = npos, .ei = idx.off[to], .rslot = slot, .rold = old };
                if (slots == null and self.sc.stack[cur].ei == e_end) {
                    // Last edge of this state and no capture write to undo: the
                    // exhausted frame has nothing left to retry — replace it
                    // (tail step) instead of growing the stack.
                    self.sc.stack[cur] = child;
                } else {
                    sp = try self.push(sp, child);
                }
                descended = true;
                break;
            }
            if (!descended) {
                // Frame exhausted: pop it and restore the slot written to enter it.
                const popped = self.sc.stack[sp - 1];
                sp -= 1;
                if (slots) |sl| if (popped.rslot >= 0) {
                    sl[@intCast(popped.rslot)] = popped.rold;
                };
            }
        }
        return null;
    }

    /// Leftmost-first match end for a match starting exactly at `start`.
    fn matchAt(self: *BoundedBt, input: []const u8, start: usize) std.mem.Allocator.Error!?usize {
        return self.dfs(input, start, null, null);
    }

    pub fn findLeftmost(self: *BoundedBt, input: []const u8) std.mem.Allocator.Error!?Span {
        return self.findLeftmostFrom(input, 0);
    }

    /// Leftmost-first match starting at/after absolute `from` (the window must
    /// cover `[from, input.len]`). Looks see the full input.
    pub fn findLeftmostFrom(self: *BoundedBt, input: []const u8, from: usize) std.mem.Allocator.Error!?Span {
        if (self.a_start) {
            if (from != 0) return null;
            if (try self.matchAt(input, 0)) |e| return .{ .start = 0, .end = e };
            return null;
        }
        var s: usize = from;
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
    /// Absolute coordinates; line starts ascend, so the first hit is leftmost.
    pub fn findLineStart(self: *BoundedBt, input: []const u8, from: usize, first: ?*const [32]u8) std.mem.Allocator.Error!?Span {
        var s = from;
        // Advance `from` to the first line start at/after it.
        if (!(s == 0 or (s <= input.len and s > 0 and input[s - 1] == '\n'))) {
            const nl = std.mem.indexOfScalarPos(u8, input, s, '\n') orelse return null;
            s = nl + 1;
        }
        while (s <= input.len) {
            // First-byte reject: a non-nullable body can only begin on a member
            // of `first`. `s == input.len` (trailing empty line) has no byte to
            // test, so fall through to `matchAt`.
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

    /// Leftmost match span + capture slots (search from 0). `slots` is
    /// caller-sized to `2*(n_groups+1)`.
    pub fn captures(self: *BoundedBt, input: []const u8, slots: []hir.Slot) std.mem.Allocator.Error!?Span {
        return self.capturesFrom(input, 0, slots);
    }

    /// Leftmost-first match at/after absolute `from` with its capture slots,
    /// in ONE walk per start position (the slot writes ride the same priority
    /// DFS that picks the span).
    pub fn capturesFrom(self: *BoundedBt, input: []const u8, from: usize, slots: []hir.Slot) std.mem.Allocator.Error!?Span {
        var s: usize = from;
        const last: usize = if (self.a_start) 0 else input.len;
        if (self.a_start and from != 0) return null;
        while (s <= last) : (s += 1) {
            @memset(slots, -1);
            if (try self.dfs(input, s, null, slots)) |e| {
                slots[0] = @intCast(s);
                slots[1] = @intCast(e);
                return .{ .start = s, .end = e };
            }
        }
        return null;
    }

    /// Capture slots for a KNOWN leftmost-first match `[start, end)` (found by
    /// a faster engine): the first priority path from `start` that accepts
    /// exactly at `end` — identical to the path a direct search would take.
    /// The window must cover `[start, end]`. Returns false iff no such path
    /// exists (a caller bug: the span was not a match).
    pub fn spanCaptures(self: *BoundedBt, input: []const u8, start: usize, end: usize, slots: []hir.Slot) std.mem.Allocator.Error!bool {
        @memset(slots, -1);
        const e = (try self.dfs(input, start, end, slots)) orelse return false;
        std.debug.assert(e == end);
        slots[0] = @intCast(start);
        slots[1] = @intCast(end);
        return true;
    }
};

test "bounded_bt: `fits` counts exactly what `ensureWindow` allocates (visited + dirty)" {
    // The PikeVM switch-over point must describe the real allocation: both
    // per-window buffers, not just the bitset (the old accounting was off 2×).
    const a = std.testing.allocator;
    const n_states: usize = 1000;
    // Largest window that fits, then one past it.
    var lo: usize = 0;
    var hi: usize = VISITED_BUDGET_BYTES; // certainly too big for 1000 states
    while (lo + 1 < hi) {
        const mid = lo + (hi - lo) / 2;
        if (fits(n_states, mid)) lo = mid else hi = mid;
    }
    try std.testing.expect(fits(n_states, lo));
    try std.testing.expect(!fits(n_states, lo + 1));
    var sc = BtScratch.init(a);
    defer sc.deinit();
    try sc.ensureWindow(n_states, lo + 1);
    const bytes = sc.visited.len * @sizeOf(u64) + sc.dirty.len * @sizeOf(u32);
    try std.testing.expect(bytes <= VISITED_BUDGET_BYTES);
    // One more position ⇒ `n_states` more bits ⇒ the allocation crosses the cap.
    var sc2 = BtScratch.init(a);
    defer sc2.deinit();
    try sc2.ensureWindow(n_states, lo + 2);
    const bytes2 = sc2.visited.len * @sizeOf(u64) + sc2.dirty.len * @sizeOf(u32);
    try std.testing.expect(bytes2 > VISITED_BUDGET_BYTES);
}

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
        var nfa = try thompson.buildAlloc(a, &h);
        defer nfa.deinit(a);
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
        var nfa = try thompson.buildAlloc(a, &h);
        defer nfa.deinit(a);
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
