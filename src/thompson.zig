//! One Thompson NFA builder over `Hir`: a flat NFA with deterministic state
//! numbering, epsilon edge insertion order (= thread priority) and byte-set
//! edges. A post-order walk of the (already brace-expanded) `Hir` yields
//! fixed fragment shapes, so the downstream subset construction in
//! `exec/full_dfa.zig` is reproducible. Shared by the comptime
//! (`pattern.zig`) and runtime (`regex.zig`) pipelines.

const std = @import("std");
const hir = @import("hir.zig");

const Error = hir.Error;
const NodeRef = hir.NodeRef;

// --- Construction ceilings --------------------------------------------------
// NOTE: a one-line MAX_NFA raise (256→1024) was tried to un-reject the benign
// `\b(?:break|case|…)\b` 40-keyword list and REVERTED — it traded a fast,
// *typed* `PatternTooComplex` (the documented .NET-model complexity contract,
// already gate-skipped in the bench) for an **hours-long hang**: such a
// pattern is regular but `\b` routes it to `.bt_look` (`bounded_bt`), whose
// `visited` array is `n_states × (input_len+1)` and is `@memset` *per match
// attempt* — ~500 MB/attempt for a ~480-state NFA over 1 MiB. The real fix
// is architectural (model `\b` in the DFA, or a `\b(regular)\b` →
// DenseSearch-locate + O(1) boundary-verify path), tracked as a finding —
// not a ceiling bump. See memory `deep-alternation-reject-is-architectural`.
pub const MAX_NFA: usize = 256;
// Every node lowers to exactly 2 fresh states except `concat` (0 states, 1 eps),
// and each emits ≤4 edges, so for `M` non-`concat` nodes: `n_states = 2M` and
// edges ≤ `4M + (#concat)`. In a binary tree `#concat ≤ M-1`, giving the bound
// `n_edges ≤ 2·n_states + n_states/2 = 2.5·n_states ≤ 640` at the `MAX_NFA`
// ceiling (the dense limit is ~2 edges/state, e.g. nested `(?:…a*…)*`). 1024 sits
// above that bound (never rejects a pattern `MAX_NFA` admits) while halving the
// per-edge arrays from ~24 KB to ~12 KB on every NFA and the lazy-DFA CSR scratch.
pub const MAX_EDGES: usize = 1024;
// Each `.set` node lowers to 2 fresh states (`addState` ×2 in `lower`), so with
// `MAX_NFA = 256` states an NFA can hold at most 128 set edges ⇒ `n_sets ≤ 128`:
// the 129th set node's `addState` trips the `MAX_NFA` ceiling first. So the set
// table never needs the full `MAX_EDGES` rows; 256 gives a 2× margin while
// shrinking `sets` from 64 KB (`[2048][32]u8`) to 8 KB — on every NFA, the
// transient build, the retained runtime heap copy, and the comptime `.rodata`
// bake alike. (Decoupled from `MAX_EDGES`, which still bounds edges/`e_set`.)
pub const MAX_SETS: usize = 256;

pub const Frag = struct { start: usize, accept: usize };

/// Per-edge classification in the flat NFA. `.eps` = ε-transition (`e_slot` may
/// carry a capture save); `.consume` = byte-set edge (`e_set` indexes `sets`);
/// `.look` = zero-width look-assertion (`e_look` holds the `hir.LookKind`). The
/// `enum(u8)` tags (0/1/2) match the historical bare-int protocol, so the baked
/// representation is byte-identical — the win is exhaustive, compiler-checked
/// switching instead of an `else`-catches-`.consume` arm.
pub const EdgeKind = enum(u8) { eps, consume, look };

/// Flat NFA. Field shapes mirror the old `Builder` so `full_dfa` can lift the
/// trusted subset/minimization code unchanged. `cap == N` -> comptime (fixed
/// arrays); `cap == null` -> runtime (heap arrays).
pub fn Nfa(comptime cap: ?usize) type {
    _ = cap; // Both modes use the same fixed ceilings; comptime evaluates the
    // arrays away, runtime stack/heap-allocates them once per compile.
    return struct {
        const Self = @This();

        n_states: usize = 0,
        // Per-edge kind (see `EdgeKind`): .eps | .consume (e_set valid) |
        // .look (conditional epsilon; e_look holds the `hir.LookKind`).
        e_from: [MAX_EDGES]u16 = undefined,
        e_to: [MAX_EDGES]u16 = undefined,
        e_kind: [MAX_EDGES]EdgeKind = undefined,
        e_set: [MAX_EDGES]u16 = undefined,
        e_look: [MAX_EDGES]u8 = undefined,
        // Capture save-slot for an .eps edge: -1 = ordinary epsilon,
        // >=0 = write the current position into slot `e_slot` (transparent
        // to the DFA, which only distinguishes .eps vs non-.eps).
        e_slot: [MAX_EDGES]i32 = undefined,
        n_edges: usize = 0,
        sets: [MAX_SETS][32]u8 = undefined,
        n_sets: usize = 0,
        start: usize = 0,
        accept: usize = 0,

        fn addState(b: *Self) Error!usize {
            if (b.n_states >= MAX_NFA) return Error.TooComplex;
            const id = b.n_states;
            b.n_states += 1;
            return id;
        }

        fn addEps(b: *Self, from: usize, to: usize) Error!void {
            if (b.n_edges >= MAX_EDGES) return Error.TooComplex;
            b.e_from[b.n_edges] = @intCast(from);
            b.e_to[b.n_edges] = @intCast(to);
            b.e_kind[b.n_edges] = .eps;
            b.e_set[b.n_edges] = 0;
            b.e_slot[b.n_edges] = -1;
            b.n_edges += 1;
        }

        /// An .eps epsilon that also records `pos` into capture slot `slot`.
        /// Transparent to the DFA (it treats every .eps edge as epsilon).
        fn addSaveEps(b: *Self, from: usize, to: usize, slot: i32) Error!void {
            if (b.n_edges >= MAX_EDGES) return Error.TooComplex;
            b.e_from[b.n_edges] = @intCast(from);
            b.e_to[b.n_edges] = @intCast(to);
            b.e_kind[b.n_edges] = .eps;
            b.e_set[b.n_edges] = 0;
            b.e_slot[b.n_edges] = slot;
            b.n_edges += 1;
        }

        fn addLookEdge(b: *Self, from: usize, to: usize, kind: u8) Error!void {
            if (b.n_edges >= MAX_EDGES) return Error.TooComplex;
            b.e_from[b.n_edges] = @intCast(from);
            b.e_to[b.n_edges] = @intCast(to);
            b.e_kind[b.n_edges] = .look;
            b.e_look[b.n_edges] = kind;
            b.e_set[b.n_edges] = 0;
            b.e_slot[b.n_edges] = -1;
            b.n_edges += 1;
        }

        fn addSetEdge(b: *Self, from: usize, to: usize, set: [32]u8) Error!void {
            if (b.n_edges >= MAX_EDGES or b.n_sets >= MAX_SETS) return Error.TooComplex;
            b.sets[b.n_sets] = set;
            b.e_from[b.n_edges] = @intCast(from);
            b.e_to[b.n_edges] = @intCast(to);
            b.e_kind[b.n_edges] = .consume;
            b.e_set[b.n_edges] = @intCast(b.n_sets);
            b.e_slot[b.n_edges] = -1;
            b.n_sets += 1;
            b.n_edges += 1;
        }

        fn lower(b: *Self, comptime hcap: ?usize, h: *const hir.Hir(hcap), ref: NodeRef) Error!Frag {
            const nd = h.node(ref);
            switch (nd.tag) {
                .empty => {
                    const s = try b.addState();
                    const a = try b.addState();
                    try b.addEps(s, a);
                    return .{ .start = s, .accept = a };
                },
                .set => {
                    const s = try b.addState();
                    const a = try b.addState();
                    try b.addSetEdge(s, a, h.setBitmap(nd.set_idx));
                    return .{ .start = s, .accept = a };
                },
                .look => {
                    const s = try b.addState();
                    const a = try b.addState();
                    try b.addLookEdge(s, a, @intCast(nd.set_idx));
                    return .{ .start = s, .accept = a };
                },
                // Non-regular: never lowered (regex.zig routes
                // requires_backtracking to the tree backtracker before
                // thompson, and the regular over-approximation drops `.atomic`
                // via cloneSubtree). Exhaustive-switch guard only.
                .backref, .look_around, .atomic => return Error.Unsupported,
                .cap => {
                    // group g uses slots [2g, 2g+1]; both are kind-0 epsilons
                    // (DFA-transparent) carrying the save id.
                    const g: i32 = @intCast(nd.set_idx);
                    const child = try b.lower(hcap, h, nd.a);
                    const s = try b.addState();
                    const a = try b.addState();
                    try b.addSaveEps(s, child.start, 2 * g);
                    try b.addSaveEps(child.accept, a, 2 * g + 1);
                    return .{ .start = s, .accept = a };
                },
                .concat => {
                    const fa = try b.lower(hcap, h, nd.a);
                    const fb = try b.lower(hcap, h, nd.b);
                    try b.addEps(fa.accept, fb.start);
                    return .{ .start = fa.start, .accept = fb.accept };
                },
                .alt => {
                    const fl = try b.lower(hcap, h, nd.a);
                    const fr = try b.lower(hcap, h, nd.b);
                    const s = try b.addState();
                    const a = try b.addState();
                    try b.addEps(s, fl.start);
                    try b.addEps(s, fr.start);
                    try b.addEps(fl.accept, a);
                    try b.addEps(fr.accept, a);
                    return .{ .start = s, .accept = a };
                },
                .star => {
                    const child = try b.lower(hcap, h, nd.a);
                    const s = try b.addState();
                    const a = try b.addState();
                    if (nd.greedy) {
                        try b.addEps(s, child.start); // enter (high prio)
                        try b.addEps(s, a); // skip
                        try b.addEps(child.accept, child.start); // loop (high prio)
                        try b.addEps(child.accept, a); // exit
                    } else {
                        try b.addEps(s, a); // skip (high prio)
                        try b.addEps(s, child.start); // enter
                        try b.addEps(child.accept, a); // exit (high prio)
                        try b.addEps(child.accept, child.start); // loop
                    }
                    return .{ .start = s, .accept = a };
                },
                .plus => {
                    const child = try b.lower(hcap, h, nd.a);
                    const s = try b.addState();
                    const a = try b.addState();
                    try b.addEps(s, child.start); // ≥1 required (unconditional)
                    if (nd.greedy) {
                        try b.addEps(child.accept, child.start); // loop (high prio)
                        try b.addEps(child.accept, a); // exit
                    } else {
                        try b.addEps(child.accept, a); // exit (high prio)
                        try b.addEps(child.accept, child.start); // loop
                    }
                    return .{ .start = s, .accept = a };
                },
                .opt => {
                    const child = try b.lower(hcap, h, nd.a);
                    const s = try b.addState();
                    const a = try b.addState();
                    if (nd.greedy) {
                        try b.addEps(s, child.start); // match (high prio)
                        try b.addEps(s, a); // skip
                    } else {
                        try b.addEps(s, a); // skip (high prio)
                        try b.addEps(s, child.start); // match
                    }
                    try b.addEps(child.accept, a); // unconditional
                    return .{ .start = s, .accept = a };
                },
            }
        }
    };
}

/// Build the NFA for `h.root`. Mirrors the old combined parser+builder's
/// state/edge emission order exactly (verified by parity tests).
pub fn build(comptime cap: ?usize, h: *const hir.Hir(cap)) Error!Nfa(cap) {
    var nfa = Nfa(cap){};
    const frag = try nfa.lower(cap, h, h.root);
    nfa.start = frag.start;
    nfa.accept = frag.accept;
    return nfa;
}

test "thompson: 'ab' yields 4 states, 2 set edges, 1 eps" {
    const parser = @import("parser.zig");
    const H = hir.Hir(64);
    var h = H.initComptime();
    try parser.parse(64, &h, undefined, "ab", .{});
    const nfa = try build(64, &h);
    try std.testing.expectEqual(@as(usize, 4), nfa.n_states);
    try std.testing.expectEqual(@as(usize, 3), nfa.n_edges); // setA, setB, eps
    try std.testing.expectEqual(@as(usize, 2), nfa.n_sets);
}
