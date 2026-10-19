//! One Thompson NFA builder over `Hir`: a flat NFA with deterministic state
//! numbering, epsilon edge insertion order (= thread priority) and byte-set
//! edges. A post-order walk of the (already brace-expanded) `Hir` yields
//! fixed fragment shapes, so the downstream subset construction in
//! `exec/full_dfa.zig` is reproducible. Shared by the comptime
//! (`pattern.zig`) and runtime (`regex.zig`) pipelines.

const std = @import("std");
const hir = @import("hir.zig");
const utf8 = @import("utf8.zig");
const common = @import("common.zig");

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

        // Edge accessors for the UTF-8 compiler's state-dedup verification.
        fn edgeCount(b: *const Self) usize {
            return b.n_edges;
        }
        fn edgeTo(b: *const Self, ei: usize) usize {
            return b.e_to[ei];
        }
        fn edgeSet(b: *const Self, ei: usize) *const [32]u8 {
            return &b.sets[b.e_set[ei]];
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

    fn edgeCount(b: *const RtBuilder) usize {
        return b.e_from.items.len;
    }
    fn edgeTo(b: *const RtBuilder, ei: usize) usize {
        return b.e_to.items[ei];
    }
    fn edgeSet(b: *const RtBuilder, ei: usize) *const [32]u8 {
        return &b.sets.items[b.e_set.items[ei]];
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

// --- UTF-8 class compiler ----------------------------------------------------
//
// A `.uclass` is lowered to a byte automaton over the UTF-8 encodings of its
// members. The naive lowering (one alternation branch per byte-range sequence,
// each a fresh chain of states) is ~3 000 states for `\p{L}`; this is a port
// of regex-automata's `Utf8Compiler`: the sorted sequences (`utf8.SeqIter`
// over a normalized set emits them in lexicographic order, with ranges at each
// position either equal or disjoint) are fed into Daciuk's incremental
// minimal-acyclic-automaton construction. A trie node is frozen into an NFA
// state as soon as the next sequence leaves it, and a frozen node whose
// transition list equals an already-compiled state's reuses that state
// (bounded hash map, verified against the builder's own edges — the map holds
// only `{hash, state, first_edge, n}`). Suffixes like `[80-BF][80-BF]` are thus
// shared: `\p{L}` compiles to a few hundred states, `(?u).` to the classic
// nine-sequence / ~15-state automaton. One edge per transition, each with a
// range bitmap; disjoint ranges make the branch order irrelevant for
// leftmost-first.

const Utf8Trans = struct { lo: u8, hi: u8, next: u16 };
const Utf8Last = struct { lo: u8, hi: u8 };

/// Distinct transitions one trie level can hold: ≤ 128 ASCII ranges + ≤ 51
/// lead-byte ranges at the root, ≤ 64 continuation ranges below.
const UTF8_MAX_TRANS = 256;
const Utf8Node = struct {
    trans: [UTF8_MAX_TRANS]Utf8Trans = undefined,
    n: usize = 0,
    /// The pending transition whose target is still being built.
    last: ?Utf8Last = null,

    fn setLast(self: *Utf8Node, next: usize) void {
        if (self.last) |l| {
            std.debug.assert(self.n < UTF8_MAX_TRANS);
            self.trans[self.n] = .{ .lo = l.lo, .hi = l.hi, .next = @intCast(next) };
            self.n += 1;
            self.last = null;
        }
    }
};

const UTF8_MAP_SIZE = 1024;
const Utf8MapEntry = struct { hash: u64 = 0, state: u16 = 0, first_edge: u32 = 0, n: u16 = 0, used: bool = false };

fn rangeSet(lo: u8, hi: u8) [32]u8 {
    var s: [32]u8 = @splat(0);
    var c: usize = lo;
    while (c <= hi) : (c += 1) common.setBit(&s, @intCast(c));
    return s;
}

fn Utf8Compiler(comptime B: type) type {
    return struct {
        const Self = @This();

        b: *B,
        /// The single accept state every sequence ends in.
        target: usize,
        /// Uncompiled trie path: root + at most one node per encoded byte.
        uncompiled: [5]Utf8Node = undefined,
        depth: usize = 0,
        map: [UTF8_MAP_SIZE]Utf8MapEntry = @splat(.{}),

        fn init(b: *B, target: usize) Self {
            var self = Self{ .b = b, .target = target };
            self.uncompiled[0] = .{};
            self.depth = 1;
            return self;
        }

        /// Add the next (lexicographically larger) byte-range sequence.
        fn add(self: *Self, seq: []const utf8.ByteRange) B.E!void {
            var prefix_len: usize = 0;
            while (prefix_len < seq.len and prefix_len < self.depth) : (prefix_len += 1) {
                const l = self.uncompiled[prefix_len].last orelse break;
                if (l.lo != seq[prefix_len].lo or l.hi != seq[prefix_len].hi) break;
            }
            std.debug.assert(prefix_len < seq.len);
            try self.compileFrom(prefix_len);
            self.addSuffix(seq[prefix_len..]);
        }

        /// Freeze (compile) every node deeper than `from`, linking each into its
        /// parent's pending transition; the node at `from` keeps its transition
        /// list open but gets its pending target resolved.
        fn compileFrom(self: *Self, from: usize) B.E!void {
            var next = self.target;
            while (from + 1 < self.depth) {
                self.depth -= 1;
                const node = &self.uncompiled[self.depth];
                node.setLast(next);
                next = try self.compile(node.trans[0..node.n]);
            }
            self.uncompiled[from].setLast(next);
        }

        /// One NFA state for a frozen transition list, reusing an identical
        /// already-compiled state when the bounded map still remembers it.
        fn compile(self: *Self, trans: []const Utf8Trans) B.E!usize {
            var h: u64 = 0xcbf29ce484222325; // FNV-1a over (lo, hi, next)
            for (trans) |t| {
                inline for (.{ t.lo, t.hi, @as(u8, @truncate(t.next)), @as(u8, @truncate(t.next >> 8)) }) |byte| {
                    h ^= byte;
                    h *%= 0x100000001b3;
                }
            }
            const slot: usize = @intCast(h % UTF8_MAP_SIZE);
            const e = &self.map[slot];
            if (e.used and e.hash == h and e.n == trans.len and self.verify(e.*, trans)) return e.state;
            const s = try self.b.addState();
            const first = self.b.edgeCount();
            for (trans) |t| try self.b.addSetEdge(s, t.next, rangeSet(t.lo, t.hi));
            e.* = .{ .hash = h, .state = @intCast(s), .first_edge = @intCast(first), .n = @intCast(trans.len), .used = true };
            return s;
        }

        fn verify(self: *const Self, e: Utf8MapEntry, trans: []const Utf8Trans) bool {
            for (trans, 0..) |t, i| {
                const ei = e.first_edge + i;
                if (self.b.edgeTo(ei) != t.next) return false;
                if (!std.mem.eql(u8, self.b.edgeSet(ei), &rangeSet(t.lo, t.hi))) return false;
            }
            return true;
        }

        fn addSuffix(self: *Self, seq: []const utf8.ByteRange) void {
            std.debug.assert(seq.len > 0);
            const top = &self.uncompiled[self.depth - 1];
            std.debug.assert(top.last == null);
            top.last = .{ .lo = seq[0].lo, .hi = seq[0].hi };
            for (seq[1..]) |r| {
                std.debug.assert(self.depth < self.uncompiled.len);
                self.uncompiled[self.depth] = .{ .last = .{ .lo = r.lo, .hi = r.hi } };
                self.depth += 1;
            }
        }

        /// Compile the remaining path and the root; returns the start state.
        fn finish(self: *Self) B.E!usize {
            try self.compileFrom(0);
            std.debug.assert(self.depth == 1);
            const root = &self.uncompiled[0];
            std.debug.assert(root.last == null);
            self.depth = 0;
            return self.compile(root.trans[0..root.n]);
        }
    };
}

/// Lower a `.uclass` member set into a UTF-8 byte automaton fragment.
fn lowerUClass(b: anytype, ranges: []const hir.CodepointRange) @TypeOf(b.*).E!Frag {
    const accept = try b.addState();
    var uc = Utf8Compiler(@TypeOf(b.*)).init(b, accept);
    for (ranges) |r| {
        var it = utf8.SeqIter.init(r.lo, r.hi);
        while (it.next()) |seq| try uc.add(seq.slice());
    }
    const start = try uc.finish();
    return .{ .start = start, .accept = accept };
}

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
        .uclass => return lowerUClass(b, h.uclassRanges(nd.set_idx)),
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
