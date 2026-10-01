//! Per-state out-edge index over a runtime Thompson NFA, shared by the NFA
//! engines that walk a state's *own* out-edges in priority order — the
//! bounded backtracker (`exec/bounded_bt.zig`) and the PikeVM
//! (`exec/pikevm.zig`). Built ONCE per retained NFA (the `Regex` owns it next
//! to the NFA) rather than once per pooled scratch: one counting sort and one
//! copy per compiled pattern instead of one per thread, and no address-keyed
//! "is this still the same NFA?" check that a reallocated NFA could fool.
//!
//! `order[off[s]..off[s+1]]` are state `s`'s out-edge ids in NFA emission
//! (= priority) order, which the leftmost-first walks rely on. The lazy DFA
//! keeps its own CSRs (`lazy_dfa.LazyProg.buildCsr`): it needs ε and byte
//! edges in separate arrays with look tags plus a reverse adjacency — a
//! different shape from this unified one.

const std = @import("std");
const thompson = @import("../thompson.zig");

const Nfa = thompson.Nfa(null);

pub const EdgeIndex = struct {
    off: []const u32,
    order: []const u32,

    /// Counting sort by `e_from`, iterated in edge order ⇒ each state's
    /// out-edges keep their original priority order.
    pub fn build(allocator: std.mem.Allocator, nfa: *const Nfa) std.mem.Allocator.Error!EdgeIndex {
        const n = nfa.n_states;
        const off = try allocator.alloc(u32, n + 1);
        errdefer allocator.free(off);
        const order = try allocator.alloc(u32, nfa.n_edges);
        @memset(off, 0);
        var ei: usize = 0;
        while (ei < nfa.n_edges) : (ei += 1) off[nfa.e_from[ei] + 1] += 1;
        var s: usize = 0;
        while (s < n) : (s += 1) off[s + 1] += off[s];
        // Place each edge at its state's fill cursor (`off[s]` advances to
        // `off[s+1]` as state `s`'s edges are placed), then shift the offsets
        // back down.
        ei = 0;
        while (ei < nfa.n_edges) : (ei += 1) {
            const f = nfa.e_from[ei];
            order[off[f]] = @intCast(ei);
            off[f] += 1;
        }
        s = n;
        while (s > 0) : (s -= 1) off[s] = off[s - 1];
        off[0] = 0;
        return .{ .off = off, .order = order };
    }

    pub fn deinit(self: *EdgeIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.off);
        allocator.free(self.order);
        self.* = .{ .off = &.{}, .order = &.{} };
    }

    /// State `s`'s out-edge ids in priority order.
    pub inline fn outEdges(self: EdgeIndex, s: usize) []const u32 {
        return self.order[self.off[s]..self.off[s + 1]];
    }
};

test "nfa_index: every state's out-edges, in emission order, partition the edge set" {
    const hir = @import("../hir.zig");
    const parser = @import("../parser.zig");
    const a = std.testing.allocator;
    const pats = [_][]const u8{ "a", "(a|ab)(c|bcd)(d*)", "\\bfoo|foobar\\b", "(?:(a)|b)+", "[a-z]+@[a-z]+" };
    for (pats) |p| {
        var h = hir.Hir(null).initRuntime();
        defer h.deinit(a);
        try parser.parse(null, &h, a, p, .{});
        var nfa = try thompson.buildAlloc(a, &h);
        defer nfa.deinit(a);
        var idx = try EdgeIndex.build(a, &nfa);
        defer idx.deinit(a);
        try std.testing.expectEqual(@as(u32, 0), idx.off[0]);
        try std.testing.expectEqual(nfa.n_edges, idx.off[nfa.n_states]);
        const seen = try a.alloc(bool, nfa.n_edges);
        defer a.free(seen);
        @memset(seen, false);
        var s: usize = 0;
        while (s < nfa.n_states) : (s += 1) {
            var prev: ?u32 = null;
            for (idx.outEdges(s)) |ei| {
                try std.testing.expectEqual(s, nfa.e_from[ei]);
                if (prev) |pv| try std.testing.expect(ei > pv); // emission order kept
                prev = ei;
                try std.testing.expect(!seen[ei]);
                seen[ei] = true;
            }
        }
        for (seen) |x| try std.testing.expect(x);
    }
}
