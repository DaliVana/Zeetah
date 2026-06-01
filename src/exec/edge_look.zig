//! Edge-look peel: a pattern that is `concat(regular_core, trailing_look)`,
//! where the trailing look-around is a **width-1 single class** (e.g.
//! `…(?<![,.])`, `…(?!\d)`), is matched by running the regular `core` on the
//! linear DFA and verifying the look as an O(1) byte check on the match edge —
//! instead of demoting the whole pattern to the tree backtracker.
//!
//! This moves a fixed-width edge look-around out of the `requires_backtracking`
//! tier into the same "regular core + cheap assertion" class zeetah already
//! uses for `\b` (`bt_look`/`boundary_lits`). It is the lookaround analogue of
//! those engines and is shared verbatim by the runtime (`regex.zig`) and the
//! comptime (`pattern.zig`) front-ends — both build a `full_dfa.Dfa256` for the
//! core and drive `nextFrom` here, so they agree by construction.
//!
//! Scope (deliberately narrow, so correctness is obvious):
//!  * the look is the LAST factor of a top-level `concat` (trailing only);
//!  * its sub-expression is a single `.set` (width 1);
//!  * the core is fully regular AND all-greedy.
//! The greedy restriction is what makes "longest end that satisfies the look"
//! equal the backtracker's leftmost-first result (greedy ⇒ longest-first
//! priority), so the DFA walk needs no priority-ordered accept enumeration.
//! Anything outside this shape returns `null` from `recognize` and the caller
//! keeps its existing path (no regression).

const std = @import("std");
const hir = @import("../hir.zig");
const full_dfa = @import("full_dfa.zig");
const core = @import("core.zig");

pub const Span = core.Span;

/// Verify spec for a width-1 trailing look-assertion peeled off a regular core.
pub const Spec = struct {
    set: [32]u8, // the single-byte class inside the look
    behind: bool, // (?<=)/(?<!) vs (?=)/(?!)
    neg: bool, // negative vs positive
};

inline fn bitsetHas(set: *const [32]u8, c: u8) bool {
    return (set[c >> 3] & (@as(u8, 1) << @as(u3, @intCast(c & 7)))) != 0;
}

/// Does the trailing look-assertion hold for a match ending at `end`?
/// Lookbehind inspects `input[end-1]`; lookahead inspects `input[end]`; a
/// missing neighbour (`end==0` / `end==len`) counts as "class absent".
pub inline fn holds(spec: *const Spec, input: []const u8, end: usize) bool {
    const present = if (spec.behind)
        (end >= 1 and bitsetHas(&spec.set, input[end - 1]))
    else
        (end < input.len and bitsetHas(&spec.set, input[end]));
    return if (spec.neg) !present else present;
}

/// Regular AND all-greedy? (`.look`/`.look_around`/`.backref`/`.atomic` or any
/// lazy quantifier ⇒ false.) Generic over `cap` so runtime and comptime share it.
fn regularGreedy(comptime cap: ?usize, h: *const hir.Hir(cap), ref: hir.NodeRef) bool {
    const nd = h.node(ref);
    return switch (nd.tag) {
        .backref, .look_around, .look, .atomic => false,
        .empty, .set => true,
        .star, .plus, .opt => nd.greedy and regularGreedy(cap, h, nd.a),
        .cap => regularGreedy(cap, h, nd.a),
        .concat, .alt => regularGreedy(cap, h, nd.a) and regularGreedy(cap, h, nd.b),
    };
}

pub const Recognized = struct { core: hir.NodeRef, spec: Spec };

/// Recognize `concat(regular_greedy_core, trailing_width1_look)`. Returns the
/// core node to DFA-compile and the verify spec, or null if the shape/scope
/// does not apply. Generic over `cap` (runtime: null, comptime: NN).
pub fn recognize(comptime cap: ?usize, h: *const hir.Hir(cap)) ?Recognized {
    if (h.root == hir.none) return null;
    const root = h.node(h.root);
    if (root.tag != .concat) return null; // parseConcat is left-leaning ⇒ root.b is the last factor
    const look = h.node(root.b);
    if (look.tag != .look_around) return null;
    const sub = h.node(look.a);
    if (sub.tag != .set) return null; // width-1 single class only
    if (!regularGreedy(cap, h, root.a)) return null;
    return .{
        .core = root.a,
        .spec = .{
            .set = h.setBitmap(sub.set_idx),
            .behind = (look.set_idx & hir.LA_BEHIND) != 0,
            .neg = (look.set_idx & hir.LA_NEGATIVE) != 0,
        },
    };
}

/// Leftmost match span at/after `from`, or null. Scans candidate starts over
/// the core DFA (skipping bytes that cannot begin a core match), and at each
/// start returns the longest end where the trailing look holds. Linear in the
/// scanned span per start — no backtracking, so no catastrophic blow-up.
pub fn nextFrom(dfa: *const full_dfa.Dfa256, spec: *const Spec, input: []const u8, from: usize) ?Span {
    // Whole-input fast negative: a byte every core match must consume that is
    // absent ⇒ no match anywhere.
    if (dfa.required) |rb| {
        if (std.mem.indexOfScalarPos(u8, input, from, rb) == null) return null;
    }
    const nullable = dfa.accepting[dfa.start];
    var s: usize = from;
    while (s <= input.len) : (s += 1) {
        // First-byte skip: a non-nullable core cannot begin where the byte
        // can't leave the start state.
        if (!nullable and (s == input.len or !bitsetHas(&dfa.start_byte_set, input[s]))) continue;
        var state: u16 = @intCast(dfa.start);
        var best: ?usize = null;
        if (dfa.accepting[state] and holds(spec, input, s)) best = s;
        var i: usize = s;
        while (i < input.len) : (i += 1) {
            const cls = dfa.class_of[input[i]];
            state = dfa.trans[state][cls];
            if (state == 0) break; // DEAD sink
            if (dfa.accepting[state] and holds(spec, input, i + 1)) best = i + 1;
        }
        if (best) |e| return .{ .start = s, .end = e };
    }
    return null;
}
