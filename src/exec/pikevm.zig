//! PikeVM: breadth-first simulation of the Thompson NFA (RE2 / rust-regex
//! `pikevm` shape). Memory is O(n_states × n_slots) — independent of the input
//! length — so it is the fallback wherever the bounded backtracker's
//! `(state,pos)` visited bitset (`n_states × window` bits) would exceed its
//! budget (`bounded_bt.VISITED_BUDGET_BYTES`): huge NFAs over long haystacks.
//!
//! Semantics match the rest of the NFA tier exactly: **leftmost-first**. The
//! thread list is kept in priority order; the ε-closure explores a state's
//! out-edges in NFA emission (= priority) order with first-visit-wins per
//! position (the same rule as the DFA closure and the backtracker's memo); a
//! new start thread is injected at each position with the LOWEST priority
//! until a match is found; and on reaching `accept` every lower-priority
//! thread at that position is cut. Look-assertions are conditional
//! ε-transitions evaluated on the full input at the current position, so
//! `\b`/`^`/`$`/`(?m)` see the real neighbours (absolute coordinates). Capture
//! writes ride the closure with a restore-on-backtrack stack.
//!
//! O(n × (states + edges)) time. All buffers live in a poolable
//! `PikeScratch` sized to the actual NFA (no fixed `MAX_NFA` arrays); the
//! NFA's per-state out-edge index is the owner's shared `EdgeIndex`
//! (`exec/nfa_index.zig`), built once per NFA, not per scratch.

const std = @import("std");
const thompson = @import("../thompson.zig");
const cc = @import("charclass.zig");
const search = @import("search.zig");
const EdgeIndex = @import("nfa_index.zig").EdgeIndex;

pub const Span = search.Span;
const Nfa = thompson.Nfa(null);
const Slot = @import("../hir.zig").Slot;

/// A thread list: sparse set of NFA states in insertion (= priority) order,
/// plus one slot row per state.
const Threads = struct {
    dense: []u32 = &.{},
    sparse: []u32 = &.{},
    slots: []Slot = &.{},
    len: usize = 0,

    inline fn contains(self: *const Threads, s: u32) bool {
        const i = self.sparse[s];
        return i < self.len and self.dense[i] == s;
    }

    inline fn insert(self: *Threads, s: u32) void {
        self.sparse[s] = @intCast(self.len);
        self.dense[self.len] = s;
        self.len += 1;
    }

    inline fn row(self: *Threads, s: u32, nslots: usize) []Slot {
        return self.slots[@as(usize, s) * nslots ..][0..nslots];
    }
};

/// ε-closure work item: take one pending out-edge (`explore` its target), or
/// undo a capture write once the subtree entered through it is exhausted.
const Frame = union(enum) {
    edge: u32,
    restore: struct { slot: u32, old: Slot },
};

/// Poolable per-search scratch (`cache.Pool` contract: `init`/`deinit`),
/// sized to the largest `(n_states, nslots)` it has served. Not tied to an
/// NFA: the per-state edge index comes from the NFA's owner (`EdgeIndex`),
/// so a scratch can be reused across NFAs.
pub const PikeScratch = struct {
    allocator: std.mem.Allocator,
    clist: Threads = .{},
    nlist: Threads = .{},
    cap_states: usize = 0,
    cap_slots: usize = 0,
    cur: []Slot = &.{},
    stack: std.ArrayListUnmanaged(Frame) = .empty,

    pub fn init(allocator: std.mem.Allocator) PikeScratch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PikeScratch) void {
        self.freeLists();
        self.stack.deinit(self.allocator);
    }

    fn freeLists(self: *PikeScratch) void {
        inline for (.{ &self.clist, &self.nlist }) |t| {
            self.allocator.free(t.dense);
            self.allocator.free(t.sparse);
            self.allocator.free(t.slots);
            t.* = .{};
        }
        self.allocator.free(self.cur);
        self.cur = &.{};
        self.cap_states = 0;
        self.cap_slots = 0;
    }

    fn allocList(self: *PikeScratch, n: usize, nslots: usize) !Threads {
        const dense = try self.allocator.alloc(u32, n);
        errdefer self.allocator.free(dense);
        const sparse = try self.allocator.alloc(u32, n);
        errdefer self.allocator.free(sparse);
        const slots = try self.allocator.alloc(Slot, n * nslots);
        return .{ .dense = dense, .sparse = sparse, .slots = slots };
    }

    /// Size the thread lists for `n_states` × `nslots` (no-op once large enough).
    pub fn ensure(self: *PikeScratch, n_states: usize, nslots: usize) !void {
        if (n_states <= self.cap_states and nslots <= self.cap_slots) return;
        const ns = @max(n_states, self.cap_states);
        const nsl = @max(nslots, self.cap_slots);
        // Commit-after-success: every new buffer is allocated before the old
        // ones are freed, so an OOM leaves the scratch as it was.
        const c = try self.allocList(ns, nsl);
        errdefer {
            self.allocator.free(c.dense);
            self.allocator.free(c.sparse);
            self.allocator.free(c.slots);
        }
        const nl = try self.allocList(ns, nsl);
        errdefer {
            self.allocator.free(nl.dense);
            self.allocator.free(nl.sparse);
            self.allocator.free(nl.slots);
        }
        const cur = try self.allocator.alloc(Slot, nsl);
        self.freeLists();
        self.clist = c;
        self.nlist = nl;
        self.cur = cur;
        self.cap_states = ns;
        self.cap_slots = nsl;
    }
};

pub const PikeVm = struct {
    nfa: *const Nfa,
    /// The NFA's per-state out-edge index in priority order (built once by
    /// the NFA's owner).
    idx: EdgeIndex,
    a_start: bool,
    a_end: bool,
    sc: *PikeScratch,
    nslots: usize,

    /// `nslots` ≥ 2: slot 0/1 = the whole match; further slots receive the
    /// capture writes (writes to slots ≥ `nslots` are ignored, so a
    /// capture-free search uses `nslots = 2`).
    pub fn init(nfa: *const Nfa, idx: EdgeIndex, a_start: bool, a_end: bool, sc: *PikeScratch, nslots: usize) !PikeVm {
        std.debug.assert(nslots >= 2);
        try sc.ensure(nfa.n_states, nslots);
        return .{ .nfa = nfa, .idx = idx, .a_start = a_start, .a_end = a_end, .sc = sc, .nslots = nslots };
    }

    /// Take edge `ei` out of an ε-state at position `p`: follow an ε (recording
    /// its capture write, with an undo frame) or a look-assertion that holds.
    fn takeEdge(self: *PikeVm, ei: u32, p: usize, input: []const u8) !?u32 {
        const nfa = self.nfa;
        switch (nfa.e_kind[ei]) {
            .eps => {
                const slot = nfa.e_slot[ei];
                if (slot >= 0 and @as(usize, @intCast(slot)) < self.nslots) {
                    const su: u32 = @intCast(slot);
                    try self.sc.stack.append(self.sc.allocator, .{ .restore = .{ .slot = su, .old = self.sc.cur[su] } });
                    self.sc.cur[su] = @intCast(p);
                }
                return nfa.e_to[ei];
            },
            .look => return if (cc.lookHolds(nfa.e_look[ei], input, p)) nfa.e_to[ei] else null,
            .consume => unreachable, // consume states are threads, never expanded
        }
    }

    /// Follow ε-chains from `s0`, inserting every reached state (first visit
    /// wins); thread states (a byte edge, or `accept`) record the current slots.
    fn explore(self: *PikeVm, list: *Threads, s0: u32, p: usize, input: []const u8) !void {
        const sc = self.sc;
        const nfa = self.nfa;
        var s = s0;
        while (true) {
            if (list.contains(s)) return;
            list.insert(s);
            const lo = self.idx.off[s];
            const hi = self.idx.off[s + 1];
            if (s == nfa.accept or (hi > lo and nfa.e_kind[self.idx.order[lo]] == .consume)) {
                @memcpy(list.row(s, self.nslots), sc.cur[0..self.nslots]);
                return;
            }
            if (hi == lo) return;
            // Lower-priority siblings wait on the stack (pushed in reverse so
            // they pop in priority order after the first edge's subtree).
            var c = hi;
            while (c > lo + 1) {
                c -= 1;
                try sc.stack.append(sc.allocator, .{ .edge = self.idx.order[c] });
            }
            s = (try self.takeEdge(self.idx.order[lo], p, input)) orelse return;
        }
    }

    /// Priority-ordered ε-closure of `s0` at position `p` into `list`, starting
    /// from the slots in `sc.cur` (restored to their entry values on return).
    fn addThread(self: *PikeVm, list: *Threads, s0: u32, p: usize, input: []const u8) !void {
        const sc = self.sc;
        sc.stack.clearRetainingCapacity();
        try self.explore(list, s0, p, input);
        while (sc.stack.pop()) |f| switch (f) {
            .restore => |r| sc.cur[r.slot] = r.old,
            .edge => |ei| if (try self.takeEdge(ei, p, input)) |to| try self.explore(list, to, p, input),
        };
    }

    pub const Opts = struct {
        /// Only start a match exactly at `from`.
        anchored: bool = false,
        /// Stop at the first accept (existence only; not leftmost-first).
        earliest: bool = false,
        /// Accept only at this exact position (reconstructing the slots of a
        /// match a faster engine already found: the first priority path that
        /// ends there — the same path a direct search takes).
        want_end: ?usize = null,
    };

    /// Leftmost-first match at/after absolute `from`. On success
    /// `slots[0..nslots]` hold the match's slots (slot 0/1 = span).
    pub fn search(self: *PikeVm, input: []const u8, from: usize, opts: Opts, slots: []Slot) !?Span {
        std.debug.assert(slots.len >= self.nslots);
        const anchored = opts.anchored;
        const earliest = opts.earliest;
        const limit = opts.want_end orelse input.len;
        const sc = self.sc;
        const nfa = self.nfa;
        const nsl = self.nslots;
        const start: u32 = @intCast(nfa.start);
        const accept: u32 = @intCast(nfa.accept);
        var clist = &sc.clist;
        var nlist = &sc.nlist;
        clist.len = 0;
        var matched = false;
        var at = from;
        while (true) : (at += 1) {
            if (!matched) {
                const can_start = if (self.a_start) at == 0 else if (anchored) at == from else true;
                if (can_start) {
                    @memset(sc.cur[0..nsl], -1);
                    sc.cur[0] = @intCast(at);
                    try self.addThread(clist, start, at, input);
                }
            }
            if (clist.len == 0) {
                // No live thread: done once a match is in hand or no later
                // start is possible (anchored / `^` past its only position).
                if (matched or self.a_start or anchored) break;
            }
            nlist.len = 0;
            var i: usize = 0;
            while (i < clist.len) : (i += 1) {
                const s = clist.dense[i];
                if (s == accept) {
                    if (self.a_end and at != input.len) continue;
                    if (opts.want_end) |e| if (at != e) continue;
                    @memcpy(slots[0..nsl], clist.row(s, nsl));
                    slots[1] = @intCast(at);
                    matched = true;
                    if (earliest) return .{ .start = @intCast(slots[0]), .end = at };
                    break; // leftmost-first: cut every lower-priority thread
                }
                if (at >= limit) continue;
                // The list also holds the closure's pure ε-states (inserted for
                // first-visit dedupe); only byte-consuming threads advance.
                const lo = self.idx.off[s];
                if (lo == self.idx.off[s + 1]) continue;
                const ei = self.idx.order[lo];
                if (nfa.e_kind[ei] != .consume) continue;
                if (cc.hasBit(&nfa.sets[nfa.e_set[ei]], input[at])) {
                    @memcpy(sc.cur[0..nsl], clist.row(s, nsl));
                    try self.addThread(nlist, nfa.e_to[ei], at + 1, input);
                }
            }
            if (at >= limit) break;
            const t = clist;
            clist = nlist;
            nlist = t;
        }
        if (!matched) return null;
        return .{ .start = @intCast(slots[0]), .end = @intCast(slots[1]) };
    }

    pub fn find(self: *PikeVm, input: []const u8, from: usize) !?Span {
        var slots: [2]Slot = undefined;
        std.debug.assert(self.nslots == 2);
        return self.search(input, from, .{}, &slots);
    }
};

// --- tests -------------------------------------------------------------------

const hir = @import("../hir.zig");
const parser = @import("../parser.zig");
const bounded_bt = @import("bounded_bt.zig");

fn buildNfa(a: std.mem.Allocator, pat: []const u8, h: *hir.Hir(null)) !Nfa {
    try parser.parse(null, h, a, pat, .{});
    return thompson.buildAlloc(a, h);
}

test "pikevm: leftmost-first + looks + captures agree with the bounded backtracker" {
    const a = std.testing.allocator;
    const pats = [_][]const u8{
        "\\bfoo|foobar\\b", "\\ba|ab\\b",        "(a+?)(a*)",      "(\\w+)\\b",
        "(?m)^(x|xy)$",     "(a|ab)(c|bcd)(d*)", "\\B\\w",         "a*",
        "(?m)$",            "x*y|z",             "(\\bab)|(\\Bb)", "(?:(a)|b)+",
    };
    const ins = [_][]const u8{ "", "foobar", "ab ab", "aaa", "xy\nx", "abcd", "a b", "zxy", "abab bab" };
    // ONE scratch across every NFA (these stack NFAs reuse addresses): the
    // scratch carries no per-NFA index, so reuse across NFAs is safe.
    var sc = PikeScratch.init(a);
    defer sc.deinit();
    for (pats) |p| {
        var h = hir.Hir(null).initRuntime();
        defer h.deinit(a);
        var nfa = buildNfa(a, p, &h) catch continue;
        defer nfa.deinit(a);
        var idx = try EdgeIndex.build(a, &nfa);
        defer idx.deinit(a);
        const nsl: usize = 2 * 8;
        for (ins) |in| {
            var from: usize = 0;
            while (from <= in.len) : (from += 1) {
                var bt = try bounded_bt.BoundedBt.init(a, &nfa, h.anchored_start, h.anchored_end, in.len);
                defer bt.deinit();
                var want: [16]Slot = undefined;
                const ws = try bt.capturesFrom(in, from, &want);
                var vm = try PikeVm.init(&nfa, idx, h.anchored_start, h.anchored_end, &sc, nsl);
                var got: [16]Slot = undefined;
                const gs = try vm.search(in, from, .{}, &got);
                try std.testing.expectEqual(ws == null, gs == null);
                if (ws) |w| {
                    try std.testing.expectEqual(w.start, gs.?.start);
                    try std.testing.expectEqual(w.end, gs.?.end);
                    try std.testing.expectEqualSlices(Slot, want[0..nsl], got[0..nsl]);
                    // Known-span reconstruction reproduces the same slots.
                    var vm2 = try PikeVm.init(&nfa, idx, false, h.anchored_end, &sc, nsl);
                    var got2: [16]Slot = undefined;
                    const g2 = try vm2.search(in, w.start, .{ .anchored = true, .want_end = w.end }, &got2);
                    try std.testing.expectEqual(w.end, g2.?.end);
                    try std.testing.expectEqualSlices(Slot, want[0..nsl], got2[0..nsl]);
                }
            }
        }
    }
}
