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

/// Runtime-only NFA ceilings (`Nfa(null)`, heap slices sized to the pattern).
/// The comptime `Nfa(N)` and the eager `full_dfa` keep the small `MAX_*` above
/// (a fixed-size `.rodata` bake / fixed construction arrays); an over-`MAX_NFA`
/// runtime NFA is served by the lazy DFA, bounded backtracker and PikeVM,
/// whose scratch is sized per NFA. Bounds: state ids are `u16` and the lazy
/// DFA's look mode tags a state list with a trailer word ≥ 0x8000, so states
/// stay < 0x8000; edge and set ids are `u16`.
pub const MAX_NFA_RUNTIME: usize = 0x7FFF;
pub const MAX_EDGES_RUNTIME: usize = 0xFFFF;
pub const MAX_SETS_RUNTIME: usize = 0xFFFF;

/// Flat NFA. Field shapes mirror the old `Builder` so `full_dfa` can lift the
/// trusted subset/minimization code unchanged. `cap == N` -> comptime (fixed
/// arrays, `MAX_*` ceilings); `cap == null` -> runtime: exact-size heap slices
/// (built by `buildAlloc`, freed by `deinit`, deep-copied by `clone`) under the
/// `MAX_*_RUNTIME` ceilings. Indexing is identical for both (`nfa.e_to[ei]`,
/// `&nfa.sets[s]`), so the engines are written once.
pub fn Nfa(comptime cap: ?usize) type {
    const rt = cap == null;
    return struct {
        const Self = @This();
        /// Error set of the comptime builder methods below (see `lower`).
        pub const E = Error;

        n_states: usize = 0,
        // Per-edge kind (see `EdgeKind`): .eps | .consume (e_set valid) |
        // .look (conditional epsilon; e_look holds the `hir.LookKind`).
        e_from: if (rt) []u16 else [MAX_EDGES]u16 = if (rt) &.{} else undefined,
        e_to: if (rt) []u16 else [MAX_EDGES]u16 = if (rt) &.{} else undefined,
        e_kind: if (rt) []EdgeKind else [MAX_EDGES]EdgeKind = if (rt) &.{} else undefined,
        e_set: if (rt) []u16 else [MAX_EDGES]u16 = if (rt) &.{} else undefined,
        e_look: if (rt) []u8 else [MAX_EDGES]u8 = if (rt) &.{} else undefined,
        // Capture save-slot for an .eps edge: -1 = ordinary epsilon,
        // >=0 = write the current position into slot `e_slot` (transparent
        // to the DFA, which only distinguishes .eps vs non-.eps).
        e_slot: if (rt) []i32 else [MAX_EDGES]i32 = if (rt) &.{} else undefined,
        n_edges: usize = 0,
        sets: if (rt) [][32]u8 else [MAX_SETS][32]u8 = if (rt) &.{} else undefined,
        n_sets: usize = 0,
        start: usize = 0,
        accept: usize = 0,

        /// Runtime NFA only: free the heap slices.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            comptime std.debug.assert(rt);
            allocator.free(self.e_from);
            allocator.free(self.e_to);
            allocator.free(self.e_kind);
            allocator.free(self.e_set);
            allocator.free(self.e_look);
            allocator.free(self.e_slot);
            allocator.free(self.sets);
            self.* = .{};
        }

        /// Runtime NFA only: an independently owned deep copy.
        pub fn clone(self: *const Self, allocator: std.mem.Allocator) std.mem.Allocator.Error!Self {
            comptime std.debug.assert(rt);
            var out: Self = .{ .n_states = self.n_states, .n_edges = self.n_edges, .n_sets = self.n_sets, .start = self.start, .accept = self.accept };
            errdefer out.deinit(allocator);
            out.e_from = try allocator.dupe(u16, self.e_from);
            out.e_to = try allocator.dupe(u16, self.e_to);
            out.e_kind = try allocator.dupe(EdgeKind, self.e_kind);
            out.e_set = try allocator.dupe(u16, self.e_set);
            out.e_look = try allocator.dupe(u8, self.e_look);
            out.e_slot = try allocator.dupe(i32, self.e_slot);
            out.sets = try allocator.dupe([32]u8, self.sets);
            return out;
        }

        // --- comptime builder (fixed arrays; the runtime uses `RtBuilder`) ---

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
    };
}

/// Runtime NFA builder: growable lists under the `MAX_*_RUNTIME` ceilings,
/// finished into an exact-size `Nfa(null)`. Same method surface as the
/// comptime builder so one `lower` serves both.
const RtBuilder = struct {
    pub const E = Error || std.mem.Allocator.Error;

    a: std.mem.Allocator,
    n_states: usize = 0,
    e_from: std.ArrayListUnmanaged(u16) = .empty,
    e_to: std.ArrayListUnmanaged(u16) = .empty,
    e_kind: std.ArrayListUnmanaged(EdgeKind) = .empty,
    e_set: std.ArrayListUnmanaged(u16) = .empty,
    e_look: std.ArrayListUnmanaged(u8) = .empty,
    e_slot: std.ArrayListUnmanaged(i32) = .empty,
    sets: std.ArrayListUnmanaged([32]u8) = .empty,

    fn deinit(b: *RtBuilder) void {
        b.e_from.deinit(b.a);
        b.e_to.deinit(b.a);
        b.e_kind.deinit(b.a);
        b.e_set.deinit(b.a);
        b.e_look.deinit(b.a);
        b.e_slot.deinit(b.a);
        b.sets.deinit(b.a);
    }

    fn addState(b: *RtBuilder) E!usize {
        if (b.n_states >= MAX_NFA_RUNTIME) return Error.TooComplex;
        const id = b.n_states;
        b.n_states += 1;
        return id;
    }

    fn addEdge(b: *RtBuilder, from: usize, to: usize, kind: EdgeKind, set: u16, look: u8, slot: i32) E!void {
        if (b.e_from.items.len >= MAX_EDGES_RUNTIME) return Error.TooComplex;
        try b.e_from.append(b.a, @intCast(from));
        try b.e_to.append(b.a, @intCast(to));
        try b.e_kind.append(b.a, kind);
        try b.e_set.append(b.a, set);
        try b.e_look.append(b.a, look);
        try b.e_slot.append(b.a, slot);
    }

    fn addEps(b: *RtBuilder, from: usize, to: usize) E!void {
        return b.addEdge(from, to, .eps, 0, 0, -1);
    }

    fn addSaveEps(b: *RtBuilder, from: usize, to: usize, slot: i32) E!void {
        return b.addEdge(from, to, .eps, 0, 0, slot);
    }

    fn addLookEdge(b: *RtBuilder, from: usize, to: usize, kind: u8) E!void {
        return b.addEdge(from, to, .look, 0, kind, -1);
    }

    fn addSetEdge(b: *RtBuilder, from: usize, to: usize, set: [32]u8) E!void {
        if (b.sets.items.len >= MAX_SETS_RUNTIME) return Error.TooComplex;
        try b.addEdge(from, to, .consume, @intCast(b.sets.items.len), 0, -1);
        try b.sets.append(b.a, set);
    }

    /// Move the lists into an exact-size `Nfa(null)` (the builder is left empty).
    fn finish(b: *RtBuilder, frag: Frag) E!Nfa(null) {
        var out: Nfa(null) = .{ .n_states = b.n_states, .start = frag.start, .accept = frag.accept };
        errdefer out.deinit(b.a);
        out.n_edges = b.e_from.items.len;
        out.n_sets = b.sets.items.len;
        out.e_from = try b.e_from.toOwnedSlice(b.a);
        out.e_to = try b.e_to.toOwnedSlice(b.a);
        out.e_kind = try b.e_kind.toOwnedSlice(b.a);
        out.e_set = try b.e_set.toOwnedSlice(b.a);
        out.e_look = try b.e_look.toOwnedSlice(b.a);
        out.e_slot = try b.e_slot.toOwnedSlice(b.a);
        out.sets = try b.sets.toOwnedSlice(b.a);
        return out;
    }
};

/// Lower `ref` into builder `b` (comptime `Nfa(N)` or runtime `RtBuilder`).
/// Emission order is identical for both, so state numbering and edge priority
/// never depend on the front-end.
fn lower(b: anytype, comptime hcap: ?usize, h: *const hir.Hir(hcap), ref: NodeRef) @TypeOf(b.*).E!Frag {
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
            const child = try lower(b, hcap, h, nd.a);
            const s = try b.addState();
            const a = try b.addState();
            try b.addSaveEps(s, child.start, 2 * g);
            try b.addSaveEps(child.accept, a, 2 * g + 1);
            return .{ .start = s, .accept = a };
        },
        .concat => {
            const fa = try lower(b, hcap, h, nd.a);
            const fb = try lower(b, hcap, h, nd.b);
            try b.addEps(fa.accept, fb.start);
            return .{ .start = fa.start, .accept = fb.accept };
        },
        .alt => {
            const fl = try lower(b, hcap, h, nd.a);
            const fr = try lower(b, hcap, h, nd.b);
            const s = try b.addState();
            const a = try b.addState();
            try b.addEps(s, fl.start);
            try b.addEps(s, fr.start);
            try b.addEps(fl.accept, a);
            try b.addEps(fr.accept, a);
            return .{ .start = s, .accept = a };
        },
        .star => {
            const child = try lower(b, hcap, h, nd.a);
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
            const child = try lower(b, hcap, h, nd.a);
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
            const child = try lower(b, hcap, h, nd.a);
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

/// Build the comptime NFA for `h.root`. Mirrors the old combined parser+builder's
/// state/edge emission order exactly (verified by parity tests). The runtime
/// NFA is built with `buildAlloc`.
pub fn build(comptime cap: ?usize, h: *const hir.Hir(cap)) Error!Nfa(cap) {
    if (cap == null) @compileError("runtime NFA: use thompson.buildAlloc(allocator, h)");
    var nfa = Nfa(cap){};
    const frag = try lower(&nfa, cap, h, h.root);
    nfa.start = frag.start;
    nfa.accept = frag.accept;
    return nfa;
}

pub const BuildError = RtBuilder.E;

/// Build the runtime NFA for `h.root` into exact-size heap slices (caller owns;
/// `deinit` frees). `error.TooComplex` past the `MAX_*_RUNTIME` ceilings.
pub fn buildAlloc(allocator: std.mem.Allocator, h: *const hir.Hir(null)) BuildError!Nfa(null) {
    var b = RtBuilder{ .a = allocator };
    defer b.deinit(); // empty after a successful `finish`
    const frag = try lower(&b, null, h, h.root);
    return b.finish(frag);
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
