//! Concat-internal **regular-island delegation** for the backtracker tier —
//! the general form of `split_alt.zig`'s fancy-regex-style trick (which only
//! covers a *top-level alternation*). Here a maximal regular subtree that is
//! the left child of a `concat` is compiled to an anchored `full_dfa`; the
//! tree-walker runs that island at DFA speed instead of one CPS frame per
//! node, and only the irregular glue (`backref`/`look_around`) stays in the
//! recursive matcher.
//!
//! Soundness (no semantic drift vs the pure tree-walker):
//!   * An island is delegated only if its subtree is `empty/set/concat` +
//!     **greedy** `star/plus/opt` — no `alt`, no lazy, no `cap`, no
//!     `backref`, no `look`, no `look_around`. With only greedy quantifiers
//!     and no alternation the parse is *unique*: the tree-walker's very first
//!     attempt for the island is its greedy-maximal match, which is exactly
//!     `full_dfa`'s leftmost-longest end. So if the continuation succeeds at
//!     that end, the overall result is byte-identical to pure tree-walk; if
//!     it fails, the caller falls back to the original `m(nd.a,…)` recursion
//!     (today's exact code, full enumeration). Worst case: one extra O(island)
//!     DFA probe. It can neither return a wrong answer nor change which match
//!     is found.
//!   * `cap`/`backref` are excluded, so the island writes no capture slots —
//!     the slot state the continuation sees is identical with or without
//!     delegation.
//!
//! Reach (a structural limit, not a soundness one): the parser builds
//! **left-leaning** `concat` chains, so a maximal regular run is a single
//! subtree only when it is a *prefix* (the `.a` spine) — e.g.
//! `[a-z]+[0-9]+(?=END)`. A regular run that *follows* an irregular atom
//! (capture / look-behind at the front, as in `(\w)\s+\d+(?=!)`) is split
//! across `.b` children and is not one subtree, so `build` simply finds
//! nothing and the pattern stays on the (correct) pure tree-walk. Catching
//! those would need instruction-stream (not subtree) delegation.

const std = @import("std");
const hir = @import("../hir.zig");
const thompson = @import("../thompson.zig");
const full_dfa = @import("full_dfa.zig");

const H = hir.Hir(null);
const NodeRef = hir.NodeRef;

/// Max delegated islands per pattern. Generous; exceeding it just leaves the
/// surplus islands on the (correct) tree-walk path.
const MAX_ISLANDS: usize = 32;

/// Is `ref`'s subtree a delegatable regular island? (See module soundness.)
/// `pub` + generic over the store cap so the comptime path (`pattern.zig`'s
/// baked-delegate builder) reuses the SAME classifier as the runtime — the
/// soundness argument above holds identically for both.
pub fn delegatable(comptime cap: ?usize, h: *const hir.Hir(cap), ref: NodeRef) bool {
    if (ref == hir.none) return false;
    const nd = h.node(ref);
    return switch (nd.tag) {
        .empty, .set => true,
        .concat => delegatable(cap, h, nd.a) and delegatable(cap, h, nd.b),
        .star, .plus, .opt => nd.greedy and delegatable(cap, h, nd.a),
        // alt (priority/longest mismatch), lazy (handled above via !greedy),
        // cap/backref/look/look_around (irregular or slot-writing), atomic
        // (non-regular cut) → no.
        .alt, .cap, .backref, .look, .look_around, .atomic => false,
    };
}

/// Does the (delegatable) subtree contain an *unbounded* repetition
/// (`star`/`plus`)? A fixed/bounded regular run (`abc`, `a?b`) is matched by
/// the tree-walker in tight O(len) already — compiling a minimized DFA for it
/// is pure compile-time cost for no runtime gain. Delegation only earns its
/// keep when a `*`/`+` makes the run length unbounded.
pub fn hasUnboundedRep(comptime cap: ?usize, h: *const hir.Hir(cap), ref: NodeRef) bool {
    const nd = h.node(ref);
    return switch (nd.tag) {
        .star, .plus => true,
        .opt => hasUnboundedRep(cap, h, nd.a),
        .concat => hasUnboundedRep(cap, h, nd.a) or hasUnboundedRep(cap, h, nd.b),
        else => false,
    };
}

/// Minimum match width of a delegatable subtree (only called on subtrees
/// `delegatable` already accepted, so the irregular tags never occur).
pub fn minLen(comptime cap: ?usize, h: *const hir.Hir(cap), ref: NodeRef) usize {
    const nd = h.node(ref);
    return switch (nd.tag) {
        .empty => 0,
        .set => 1,
        .concat => minLen(cap, h, nd.a) + minLen(cap, h, nd.b),
        .plus => minLen(cap, h, nd.a),
        .star, .opt => 0,
        else => 0,
    };
}

/// Faithful copy of a delegatable subtree (only `empty/set/concat/greedy
/// star|plus|opt` occur — the classifier guarantees it). Thin alias over
/// `hir.cloneSubtree(…, false)`.
inline fn copyReg(dst: *H, a: std.mem.Allocator, src: *const H, ref: NodeRef) hir.Error!NodeRef {
    return hir.cloneSubtree(null, null, dst, a, src, ref, false);
}

pub const Plan = struct {
    allocator: std.mem.Allocator,
    refs: [MAX_ISLANDS]NodeRef = [_]NodeRef{hir.none} ** MAX_ISLANDS,
    dfas: [MAX_ISLANDS]*full_dfa.Dfa256 = undefined,
    n: usize = 0,

    /// The compiled anchored DFA for island root `ref`, or null if `ref`
    /// is not a delegated island. Linear scan over a tiny table.
    pub fn dfaFor(self: *const Plan, ref: NodeRef) ?*const full_dfa.Dfa256 {
        var i: usize = 0;
        while (i < self.n) : (i += 1) if (self.refs[i] == ref) return self.dfas[i];
        return null;
    }

    pub fn deinit(self: *Plan) void {
        var i: usize = 0;
        while (i < self.n) : (i += 1) self.allocator.destroy(self.dfas[i]);
        self.allocator.destroy(self);
    }
};

/// Build the delegation plan for backtracker HIR `h`. Returns `null` (⇒ no
/// delegation, plain tree-walk) when nothing qualifies or on any
/// allocation/compile failure — never an error, never a wrong plan.
pub fn build(allocator: std.mem.Allocator, h: *const H) ?*Plan {
    if (h.root == hir.none) return null;
    const pl = allocator.create(Plan) catch return null;
    pl.* = .{ .allocator = allocator };

    var ref: NodeRef = 0;
    const n_nodes: NodeRef = @intCast(h.node_count);
    while (ref < n_nodes and pl.n < MAX_ISLANDS) : (ref += 1) {
        const nd = h.node(ref);
        if (nd.tag != .concat) continue;
        if (!delegatable(null, h, nd.a)) continue;
        if (minLen(null, h, nd.a) < 1) continue; // nullable ⇒ no work saved
        if (!hasUnboundedRep(null, h, nd.a)) continue; // fixed run ⇒ DFA not worth it

        // Extract the island into its own anchored DFA.
        var oh = H.initRuntime();
        defer oh.deinit(allocator);
        oh.root = copyReg(&oh, allocator, h, nd.a) catch continue;
        var nfa = thompson.build(null, &oh) catch continue;
        const d = full_dfa.compute(null, &nfa, true, false); // anchored start
        if (d.outcome != .ok) continue;
        const heap = allocator.create(full_dfa.Dfa256) catch continue;
        heap.* = d;
        pl.refs[pl.n] = nd.a;
        pl.dfas[pl.n] = heap;
        pl.n += 1;
    }

    if (pl.n == 0) {
        allocator.destroy(pl);
        return null;
    }
    return pl;
}

// ===========================================================================
// Tests — the soundness claim is "delegate-on ≡ delegate-off, byte-identical
// span + slots". Prove it differentially on patterns that actually fire the
// delegate (no suite workload does), across boundary-y inputs.
// ===========================================================================

const parser = @import("../parser.zig");
const backtrack = @import("backtrack.zig");

fn diffOnOff(a: std.mem.Allocator, p: []const u8, ins: []const []const u8, must_fire: bool) !void {
    var h = hir.Hir(null).initRuntime();
    defer h.deinit(a);
    parser.parse(null, &h, a, p, .{}) catch return;
    const plan = build(a, &h); // null ⇒ nothing delegatable ⇒ pure tree-walk
    defer if (plan) |pp| pp.deinit();
    if (must_fire) try std.testing.expect(plan != null);

    for (ins) |in| {
        var off = backtrack.Backtracker.init(&h, h.anchored_start, h.anchored_end, 8, null, null);
        var on = backtrack.Backtracker.init(&h, h.anchored_start, h.anchored_end, 8, null, plan);
        var so: [2 * (hir.MAX_GROUPS + 1)]i32 = undefined;
        var sn: [2 * (hir.MAX_GROUPS + 1)]i32 = undefined;
        const ro = off.run(in, so[0..18]) catch null;
        const rn = on.run(in, sn[0..18]) catch null;
        try std.testing.expectEqual(ro == null, rn == null);
        if (ro) |rspan| {
            try std.testing.expectEqual(rspan.start, rn.?.start);
            try std.testing.expectEqual(rspan.end, rn.?.end);
            try std.testing.expectEqualSlices(i32, so[0..18], sn[0..18]);
        }
    }
}

test "delegate: regular-prefix patterns actually fire, on ≡ off" {
    const a = std.testing.allocator;
    const ins = [_][]const u8{
        "",         "ab12END", "ab12ENDx",  "  AB12END  ",
        "zz9END q", "x000yyZ", "x000yyy q", "aaaa1111ENDED a1END",
        "nope",     "X12END",
    };
    // Regular *prefix* run (the `.a` spine) + irregular glue ⇒ delegatable
    // as a subtree. These MUST fire (else the path isn't exercised).
    for ([_][]const u8{
        "[a-z]+[0-9]+(?=END)", // island `[a-z]+[0-9]+`, glue (?=END)
        "[A-Za-z]+ (?=\\d)", // island `[A-Za-z]+ `, glue lookahead
        "x[0-9]*y+(?!Z)", // greedy star/plus island, negative lookahead
    }) |p| try diffOnOff(a, p, &ins, true);
}

test "delegate: irregular-prefix patterns stay sound (on ≡ off, may not fire)" {
    const a = std.testing.allocator;
    const ins = [_][]const u8{ "", "a  42!", "#deadbeef;", "#zz;", "x  9!" };
    // Regular run *after* an irregular prefix is split across `.b` children
    // (left-leaning concat) ⇒ not a single subtree ⇒ `build` yields null.
    // Pure tree-walk; equivalence must still hold trivially.
    for ([_][]const u8{
        "(\\w)\\s+[0-9]+(?=!)", // capture at front
        "(?<=#)[a-f0-9]+(?=;)", // lookbehind at front
    }) |p| try diffOnOff(a, p, &ins, false);
}
