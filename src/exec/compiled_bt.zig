//! Compiled backtracker for the comptime `Pattern` path.
//!
//! The tree backtracker (`backtrack.zig`) *interprets* a baked HIR: every node
//! visit is a call to `m`, a switch on the node tag, a `Cont` frame on the stack
//! and a `cont` switch to resume. On the comptime path the HIR is known at
//! compile time, so here each node becomes its own Zig type with a
//! `run(ctx, pos)` function and every continuation is resolved at compile time
//! as a type — continuation-passing through types, the CTRE model.
//! `concat(a, b)` is `Node(a, Node(b, K))`, a class test is an inline range
//! compare, and a greedy class loop is a scan plus give-back. LLVM then inlines
//! the chain, so the per-node dispatch the interpreter pays disappears.
//!
//! Semantics are the interpreter's, exactly:
//!   * leftmost-first priority order, node by node;
//!   * the same ε-cycle rule (`backtrack.seenIn` over the same loop-state keys).
//!     It is applied only to loops that can sit on an ε-cycle — the loop's own
//!     body or an enclosing loop body can match empty — because no other loop
//!     can revisit its own state at the same position on one path;
//!   * the same step budget (`backtrack.BUDGET_*`) and stack guard, surfaced as
//!     `error.Budget`. Steps are charged at choice points rather than per node,
//!     so the same budget admits at least as much real work;
//!   * the same capture-slot, atomic-group and lookaround behaviour, the same
//!     variable-width lookbehind scan;
//!   * the same scan loop: seek prefilter, line-start enumeration and the
//!     first-byte dispatch of a top-level alternation.
//!
//! One deliberate structural change: the parser expands `x{m,n}` into flat
//! copies (`x x x? x?`). A run of identical copies of a loop-free `x` is matched
//! here as ONE counted repeat (`Repeat`) — a bounded scan for a single byte
//! class, else "one more copy, or stop". The flat form also tries the
//! skip-then-take orderings, which re-reach the same position with the same
//! continuation, so they can only repeat work already done (exponential on a
//! failing tail: `.{0,200}x`). See `headRun` for when this is exact.
//!
//! The runtime `Regex` keeps the interpreter (it has no compile-time HIR).

const std = @import("std");
const hir = @import("../hir.zig");
const backtrack = @import("backtrack.zig");
const seek_mod = @import("seek.zig");
const cc = @import("charclass.zig");
const class_span = @import("class_span.zig");
const search = @import("search.zig");
const line_dfa = @import("line_dfa.zig");

const NodeRef = hir.NodeRef;
const Seen = backtrack.Seen;
const seenIn = backtrack.seenIn;
const entryKey = backtrack.entryKey;
const bodyKey = backtrack.bodyKey;
const loopKey = backtrack.loopKey;

pub const Span = search.Span;
pub const Error = backtrack.Error;

/// Master switch for the counted-repeat fusion of flat `{m,n}` expansions
/// (`headRun`). Flip to `false` to match every expanded copy node by node.
const FUSE_REPEATS = true;

/// One bit per top-level alternation branch in the first-byte dispatch table;
/// its width caps the dispatched branch count.
pub const AltMask = u64;

pub const Opts = struct {
    /// Capture-group count; `slots[0 .. 2*(n_groups+1)]` are live.
    n_groups: usize,
    /// Fill every capture slot (the `captures` path). `false` for whole-match
    /// search: slots are then written only if a backreference reads them.
    captures: bool,
    /// First-byte dispatch for a top-level alternation: the source-ordered
    /// branch roots and, per leading byte, the mask of branches that can begin
    /// a match there (from each branch's FIRST-set; a nullable branch is a
    /// candidate for every byte). Empty ⇒ the root is matched whole.
    alt_branches: []const NodeRef = &.{},
    alt_table: [256]AltMask = @splat(0),
};

/// Per-search state, one per `runFrom`. Node functions take it by pointer.
const Ctx = struct {
    input: []const u8,
    budget: u64,
    steps: u64 = 0,
    depth: u32 = 0,
    stack_base: usize = 0,
    /// Loop states visited on the current path (see `backtrack.Seen`).
    seen: ?*const Seen = null,
    /// End of the top-level match (`TopAccept`).
    match_end: usize = 0,
    /// End of the innermost atomic body that just matched (`AtomicAccept`).
    atomic_end: usize = 0,
    /// Required end of the active lookbehind body (`BehindAccept`).
    behind_at: usize = 0,
    slots: [2 * (hir.MAX_GROUPS + 1)]hir.Slot = undefined,
};

inline fn tick(c: *Ctx) Error!void {
    c.steps += 1;
    if (c.steps > c.budget) return error.Budget;
}

/// Cap on nested general-loop iterations on one path. Only a loop whose body
/// is not a single byte class nests native frames per iteration (class loops
/// scan iteratively), so this counts those iterations — one per loop split,
/// where the interpreter counts every `m`/`cont` frame. The stack-byte bound
/// (`backtrack.MAX_STACK_BYTES`) is the one that protects the thread.
const MAX_DEPTH: u32 = 16_384;
comptime {
    std.debug.assert(MAX_DEPTH % backtrack.STACK_CHECK_EVERY == 0);
}

inline fn enter(c: *Ctx) Error!void {
    if (c.depth % backtrack.STACK_CHECK_EVERY == 0) {
        @branchHint(.unlikely);
        try checkStack(c);
    }
    c.depth += 1;
}

/// Refuse past `MAX_DEPTH`, or past `MAX_STACK_BYTES` of stack below the
/// frame that entered at depth 0. Not at comptime (no frame addresses).
noinline fn checkStack(c: *Ctx) Error!void {
    if (c.depth >= MAX_DEPTH) return error.Budget;
    if (@inComptime()) return;
    const here = @frameAddress();
    if (c.depth == 0) {
        c.stack_base = here;
        return;
    }
    const used = if (c.stack_base >= here) c.stack_base - here else here - c.stack_base;
    if (used > backtrack.MAX_STACK_BYTES) return error.Budget;
}

// ── Byte classes ────────────────────────────────────────────────────────────

const MAX_INLINE_RANGES = 4;
const RangeList = struct {
    lo: [MAX_INLINE_RANGES]u8 = undefined,
    hi: [MAX_INLINE_RANGES]u8 = undefined,
    n: usize = 0,
    /// More than `MAX_INLINE_RANGES` runs: test the bitmap instead.
    wide: bool = false,
};

fn rangesOf(bm: [32]u8) RangeList {
    @setEvalBranchQuota(100_000);
    var r: RangeList = .{};
    var b: usize = 0;
    while (b < 256) {
        if (!cc.hasBit(&bm, @intCast(b))) {
            b += 1;
            continue;
        }
        const lo = b;
        while (b < 256 and cc.hasBit(&bm, @intCast(b))) b += 1;
        if (r.n == MAX_INLINE_RANGES) return .{ .wide = true };
        r.lo[r.n] = @intCast(lo);
        r.hi[r.n] = @intCast(b - 1);
        r.n += 1;
    }
    return r;
}

/// Membership in a comptime class: up to `MAX_INLINE_RANGES` unsigned range
/// compares, else one bitmap probe.
inline fn inSet(comptime bm: [32]u8, b: u8) bool {
    const r = comptime rangesOf(bm);
    if (r.wide) return cc.hasBit(&bm, b);
    inline for (0..r.n) |i| {
        if (b -% r.lo[i] <= r.hi[i] - r.lo[i]) return true;
    }
    return false;
}

/// Bytes probed one at a time before a class run switches to the SIMD scan:
/// most runs (words, numbers) end within it, and those don't pay vector setup.
const RUN_PROBE = 16;

/// End of the maximal run of `bm` members starting at `pos`.
inline fn runEnd(comptime bm: [32]u8, input: []const u8, pos: usize) usize {
    var i = pos;
    const probe_end = @min(input.len, pos + RUN_PROBE);
    while (i < probe_end) : (i += 1) {
        if (!inSet(bm, input[i])) return i;
    }
    if (i == input.len) return i;
    const ranges = comptime class_span.Ranges.fromBitmap(bm);
    if (ranges) |r| return r.runEnd(input, i);
    while (i < input.len and inSet(bm, input[i])) i += 1;
    return i;
}

// ── HIR analysis (comptime) ─────────────────────────────────────────────────

const WidthBounds = struct { min: usize, max: usize, bounded: bool };

fn Info(comptime n: usize) type {
    return struct {
        /// Byte-width bounds of each node (as `BacktrackerG.widthBounds`).
        wb: [n]WidthBounds,
        /// Subtree contains a backreference (so slots must be written).
        backref: [n]bool,
        /// Subtree contains a `*`/`+` loop (anywhere, lookaround bodies included).
        loops: [n]bool,
        /// Subtree contains a capture group.
        caps: [n]bool,
    };
}

/// One pass in node order: the parser creates children before their parent.
fn analyze(comptime cap: usize, comptime h: hir.Hir(cap)) Info(h.node_count) {
    @setEvalBranchQuota(10_000_000);
    const n = h.node_count;
    var r: Info(n) = undefined;
    for (0..n) |i| {
        const nd = h.nodes[i];
        if (nd.a != hir.none and nd.a >= i) @compileError("compiled_bt: HIR child after parent");
        if (nd.b != hir.none and nd.b >= i) @compileError("compiled_bt: HIR child after parent");
        const a = nd.a;
        const b = nd.b;
        r.wb[i] = switch (nd.tag) {
            .empty, .look, .look_around => .{ .min = 0, .max = 0, .bounded = true },
            .set => .{ .min = 1, .max = 1, .bounded = true },
            .concat => .{ .min = r.wb[a].min + r.wb[b].min, .max = r.wb[a].max + r.wb[b].max, .bounded = r.wb[a].bounded and r.wb[b].bounded },
            .alt => .{ .min = @min(r.wb[a].min, r.wb[b].min), .max = @max(r.wb[a].max, r.wb[b].max), .bounded = r.wb[a].bounded and r.wb[b].bounded },
            .opt => .{ .min = 0, .max = r.wb[a].max, .bounded = r.wb[a].bounded },
            .cap, .atomic => r.wb[a],
            .star => .{ .min = 0, .max = 0, .bounded = false },
            .plus => .{ .min = r.wb[a].min, .max = 0, .bounded = false },
            .backref => .{ .min = 0, .max = 0, .bounded = false },
        };
        const ca = a != hir.none;
        const cb = b != hir.none;
        r.backref[i] = nd.tag == .backref or (ca and r.backref[a]) or (cb and r.backref[b]);
        r.loops[i] = nd.tag == .star or nd.tag == .plus or (ca and r.loops[a]) or (cb and r.loops[b]);
        r.caps[i] = nd.tag == .cap or (ca and r.caps[a]) or (cb and r.caps[b]);
    }
    return r;
}

/// Structural equality of two subtrees (classes compared by content). The
/// `{m,n}` expansion parses a fresh copy of the atom per repetition, so equal
/// copies have different node refs.
fn same(comptime G: type, x: NodeRef, y: NodeRef) bool {
    if (x == y) return true;
    if (x == hir.none or y == hir.none) return false;
    const a = G.hh.nodes[x];
    const b = G.hh.nodes[y];
    if (a.tag != b.tag or a.greedy != b.greedy or a.fold != b.fold) return false;
    return switch (a.tag) {
        .set => std.mem.eql(u8, &G.hh.sets[a.set_idx], &G.hh.sets[b.set_idx]),
        .empty => true,
        .look, .backref => a.set_idx == b.set_idx,
        .concat, .alt => same(G, a.a, b.a) and same(G, a.b, b.b),
        .cap, .look_around => a.set_idx == b.set_idx and same(G, a.a, b.a),
        .star, .plus, .opt, .atomic => same(G, a.a, b.a),
    };
}

fn chainLen(comptime G: type, comptime tag: hir.Tag, ref: NodeRef) usize {
    const nd = G.hh.nodes[ref];
    return if (nd.tag == tag) chainLen(G, tag, nd.a) + chainLen(G, tag, nd.b) else 1;
}

/// The operands of a `concat` / `alt` chain in source order (both are
/// associative, so nesting on either side flattens).
fn flatten(comptime G: type, comptime tag: hir.Tag, comptime ref: NodeRef) [chainLen(G, tag, ref)]NodeRef {
    @setEvalBranchQuota(10_000_000);
    var out: [chainLen(G, tag, ref)]NodeRef = undefined;
    var n: usize = 0;
    fill(G, tag, ref, &out, &n);
    return out;
}

fn fill(comptime G: type, comptime tag: hir.Tag, ref: NodeRef, out: []NodeRef, n: *usize) void {
    const nd = G.hh.nodes[ref];
    if (nd.tag == tag) {
        fill(G, tag, nd.a, out, n);
        fill(G, tag, nd.b, out, n);
    } else {
        out[n.*] = ref;
        n.* += 1;
    }
}

// ── Continuations that end a sub-match ──────────────────────────────────────

const TopAccept = struct {
    fn run(c: *Ctx, pos: usize) Error!bool {
        c.match_end = pos;
        return true;
    }
};
const TopAcceptEnd = struct {
    fn run(c: *Ctx, pos: usize) Error!bool {
        return pos == c.input.len;
    }
};
const AtomicAccept = struct {
    fn run(c: *Ctx, pos: usize) Error!bool {
        c.atomic_end = pos;
        return true;
    }
};
const AheadAccept = struct {
    fn run(_: *Ctx, _: usize) Error!bool {
        return true;
    }
};
const BehindAccept = struct {
    fn run(c: *Ctx, pos: usize) Error!bool {
        return pos == c.behind_at;
    }
};
const Fail = struct {
    fn run(_: *Ctx, _: usize) Error!bool {
        return false;
    }
};

// ── Node code generation ────────────────────────────────────────────────────
//
// `Node(G, ref, K, cyc)` is the matcher for node `ref` followed by
// continuation `K`. `G` is the per-pattern namespace (`Compiled`'s `G`): every
// generated type that reads the HIR references `G`, so Zig keys the type on it
// — a function-local type is identified by its declaration site and the values
// it captures, and one that read the HIR without capturing `G` could be shared
// between two patterns. `cyc` is true inside the body of a loop that can match
// empty (lookaround and atomic bodies reset it): only there can a path come
// back to a loop state at the same position, so only there is the ε-cycle rule
// applied.

fn Node(comptime G: type, comptime ref: NodeRef, comptime K: type, comptime cyc: bool) type {
    const nd = G.hh.nodes[ref];
    switch (nd.tag) {
        .empty => return K,
        .set => return SetNode(G.hh.sets[nd.set_idx], K),
        .look => return LookNode(@intCast(nd.set_idx), K),
        .concat => {
            const items = flatten(G, .concat, ref);
            return Seq(G, &items, K, cyc);
        },
        .alt => {
            const branches = flatten(G, .alt, ref);
            return AltNode(G, &branches, K, cyc);
        },
        .opt => return OptNode(G, nd.a, nd.greedy, K, cyc),
        .star, .plus => return LoopNode(G, ref, K, cyc),
        .cap => return CapNode(G, ref, K, cyc),
        .backref => return BackrefNode(nd.set_idx, nd.fold, K),
        .atomic => return AtomicNode(G, nd.a, K),
        .look_around => return LookAroundNode(G, ref, K),
    }
}

fn SetNode(comptime bm: [32]u8, comptime K: type) type {
    return struct {
        fn run(c: *Ctx, pos: usize) Error!bool {
            if (pos < c.input.len and inSet(bm, c.input[pos])) return K.run(c, pos + 1);
            return false;
        }
    };
}

fn LookNode(comptime kind: u8, comptime K: type) type {
    return struct {
        fn run(c: *Ctx, pos: usize) Error!bool {
            if (cc.lookHolds(kind, c.input, pos)) return K.run(c, pos);
            return false;
        }
    };
}

fn AltNode(comptime G: type, comptime branches: []const NodeRef, comptime K: type, comptime cyc: bool) type {
    return struct {
        fn run(c: *Ctx, pos: usize) Error!bool {
            inline for (branches, 0..) |br, i| {
                if (i > 0) try tick(c);
                if (try Node(G, br, K, cyc).run(c, pos)) return true;
            }
            return false;
        }
    };
}

fn OptNode(comptime G: type, comptime body: NodeRef, comptime greedy: bool, comptime K: type, comptime cyc: bool) type {
    return struct {
        const Body = Node(G, body, K, cyc);
        fn run(c: *Ctx, pos: usize) Error!bool {
            if (greedy) {
                if (try Body.run(c, pos)) return true;
                try tick(c);
                return K.run(c, pos);
            }
            if (try K.run(c, pos)) return true;
            try tick(c);
            return Body.run(c, pos);
        }
    };
}

fn LoopNode(comptime G: type, comptime ref: NodeRef, comptime K: type, comptime cyc: bool) type {
    const nd = G.hh.nodes[ref];
    const body = nd.a;
    const min: usize = if (nd.tag == .plus) 1 else 0;
    // A path can revisit this loop's states at one position only through an
    // empty iteration — of this loop, or of an enclosing one (`cyc`).
    const track = cyc or G.info.wb[body].min == 0;
    const bn = G.hh.nodes[body];
    if (bn.tag == .set) {
        const bm = G.hh.sets[bn.set_idx];
        return if (nd.greedy) GreedySetLoop(bm, body, min, track, K) else LazySetLoop(bm, body, min, track, K);
    }
    const L = Loop(G, body, nd.greedy, track, K);
    return if (min == 0) L.Star else L.Plus;
}

/// Greedy `C*` / `C+` over one byte class: scan the maximal run, then hand the
/// continuation each end from longest to shortest — the interpreter's
/// `greedySetRun`, including the loop states it records for the ε-cycle rule.
fn GreedySetLoop(comptime bm: [32]u8, comptime body: NodeRef, comptime min: usize, comptime track: bool, comptime K: type) type {
    return struct {
        fn run(c: *Ctx, pos: usize) Error!bool {
            if (track and seenIn(c.seen, if (min == 0) entryKey(body) else bodyKey(body), pos)) return false;
            const e = runEnd(bm, c.input, pos);
            if (e - pos < min) return false;
            const saved = c.seen;
            defer c.seen = saved;
            var p = e;
            while (true) : (p -= 1) {
                try tick(c);
                var here: Seen = undefined;
                if (track) {
                    here = .{ .key = if (p == pos) entryKey(body) else loopKey(body), .pos = p, .prev = saved };
                    c.seen = &here;
                }
                if (try K.run(c, p)) return true;
                if (p == pos + min) break;
            }
            return false;
        }
    };
}

/// Lazy `C*?` / `C+?` over one byte class, iteratively: try the continuation,
/// else consume one more member. Records the same loop states as the
/// interpreter's split/body recursion; at positions past `pos` none of the
/// checks can fire (every recorded state on the path is at or before `pos`).
fn LazySetLoop(comptime bm: [32]u8, comptime body: NodeRef, comptime min: usize, comptime track: bool, comptime K: type) type {
    return struct {
        fn run(c: *Ctx, pos: usize) Error!bool {
            const in = c.input;
            if (track and seenIn(c.seen, if (min == 0) entryKey(body) else bodyKey(body), pos)) return false;
            const saved = c.seen;
            defer c.seen = saved;
            var p = pos;
            if (min == 1) {
                if (p >= in.len or !inSet(bm, in[p])) return false;
                p += 1;
            }
            while (true) {
                try tick(c);
                var here: Seen = undefined;
                if (track) {
                    here = .{ .key = if (p == pos) entryKey(body) else loopKey(body), .pos = p, .prev = saved };
                    c.seen = &here;
                }
                if (try K.run(c, p)) return true;
                if (p >= in.len or !inSet(bm, in[p])) return false;
                // A `*` entering its body at its start: the body state there.
                if (track and min == 0 and p == pos and seenIn(c.seen, bodyKey(body), p)) return false;
                p += 1;
            }
        }
    };
}

/// A `*` / `+` whose body is not a single byte class: the interpreter's
/// `loopSplit` / `enterBody` pair, with the iteration's end continuing at the
/// loop-back split (`Back`).
fn Loop(comptime G: type, comptime body: NodeRef, comptime greedy: bool, comptime track: bool, comptime K: type) type {
    return struct {
        const Self = @This();

        const Back = struct {
            fn run(c: *Ctx, pos: usize) Error!bool {
                return Self.split(c, pos, loopKey(body));
            }
        };
        const Body = Node(G, body, Back, track);

        /// Iterate again or exit, in greedy / lazy order.
        fn split(c: *Ctx, pos: usize, comptime key: u32) Error!bool {
            try enter(c);
            defer c.depth -= 1;
            try tick(c);
            const saved = c.seen;
            defer c.seen = saved;
            var here: Seen = undefined;
            if (track) {
                if (seenIn(c.seen, key, pos)) return false;
                here = .{ .key = key, .pos = pos, .prev = saved };
                c.seen = &here;
            }
            if (greedy) {
                if (try enterBody(c, pos)) return true;
                return K.run(c, pos);
            }
            if (try K.run(c, pos)) return true;
            return enterBody(c, pos);
        }

        inline fn enterBody(c: *Ctx, pos: usize) Error!bool {
            const saved = c.seen;
            defer c.seen = saved;
            var here: Seen = undefined;
            if (track) {
                if (seenIn(c.seen, bodyKey(body), pos)) return false;
                here = .{ .key = bodyKey(body), .pos = pos, .prev = saved };
                c.seen = &here;
            }
            return Body.run(c, pos);
        }

        /// `*` starts at its entry split.
        pub const Star = struct {
            fn run(c: *Ctx, pos: usize) Error!bool {
                return Self.split(c, pos, entryKey(body));
            }
        };
        /// `+` (≡ `x x*`) enters the body directly.
        pub const Plus = struct {
            fn run(c: *Ctx, pos: usize) Error!bool {
                return Self.enterBody(c, pos);
            }
        };
    };
}

fn CapNode(comptime G: type, comptime ref: NodeRef, comptime K: type, comptime cyc: bool) type {
    const nd = G.hh.nodes[ref];
    const g: usize = nd.set_idx;
    if (g > hir.MAX_GROUPS) return Fail;
    if (!G.slots) return Node(G, nd.a, K, cyc);
    return struct {
        const Close = struct {
            fn run(c: *Ctx, pos: usize) Error!bool {
                const old = c.slots[2 * g + 1];
                c.slots[2 * g + 1] = @intCast(pos);
                if (try K.run(c, pos)) return true;
                c.slots[2 * g + 1] = old;
                return false;
            }
        };
        const Inner = Node(G, nd.a, Close, cyc);
        fn run(c: *Ctx, pos: usize) Error!bool {
            const old = c.slots[2 * g];
            c.slots[2 * g] = @intCast(pos);
            if (try Inner.run(c, pos)) return true;
            c.slots[2 * g] = old; // restore on backtrack
            return false;
        }
    };
}

fn BackrefNode(comptime group: u32, comptime fold: bool, comptime K: type) type {
    // Same guard as `CapNode`: `Ctx.slots` is sized to `MAX_GROUPS`, and a
    // backref past it must fail softly, not index out of bounds.
    if (group > hir.MAX_GROUPS) return Fail;
    return struct {
        fn run(c: *Ctx, pos: usize) Error!bool {
            const s = c.slots[2 * group];
            const e = c.slots[2 * group + 1];
            if (s < 0 or e < 0 or e < s) return K.run(c, pos); // unset → empty
            const su: usize = @intCast(s);
            const w: usize = @as(usize, @intCast(e)) - su;
            if (pos + w > c.input.len) return false;
            const a = c.input[pos .. pos + w];
            const b = c.input[su .. su + w];
            const eq = if (fold) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
            if (!eq) return false;
            return K.run(c, pos + w);
        }
    };
}

/// `(?>body)`: match the body to its first (highest-priority) end and commit —
/// a failing continuation fails the group; capture slots the body wrote are
/// undone then.
fn AtomicNode(comptime G: type, comptime body: NodeRef, comptime K: type) type {
    return struct {
        const Inner = Node(G, body, AtomicAccept, false);
        const live = 2 * (G.n_groups + 1);
        fn run(c: *Ctx, pos: usize) Error!bool {
            if (!G.slots) {
                if (try Inner.run(c, pos)) return K.run(c, c.atomic_end);
                return false;
            }
            var snap: [live]hir.Slot = undefined;
            @memcpy(&snap, c.slots[0..live]);
            if (try Inner.run(c, pos)) {
                if (try K.run(c, c.atomic_end)) return true;
            }
            @memcpy(c.slots[0..live], &snap);
            return false;
        }
    };
}

/// Lookaround: an independent zero-width sub-match (fresh ε-cycle list). A
/// lookbehind tries body widths shortest-first, each required to end at `pos`.
fn LookAroundNode(comptime G: type, comptime ref: NodeRef, comptime K: type) type {
    const nd = G.hh.nodes[ref];
    const neg = (nd.set_idx & hir.LA_NEGATIVE) != 0;
    const behind = (nd.set_idx & hir.LA_BEHIND) != 0;
    if (!behind) return struct {
        const Inner = Node(G, nd.a, AheadAccept, false);
        fn run(c: *Ctx, pos: usize) Error!bool {
            try tick(c);
            const saved = c.seen;
            c.seen = null;
            const ok = try Inner.run(c, pos);
            c.seen = saved;
            if (ok != neg) return K.run(c, pos);
            return false;
        }
    };
    const wb = G.info.wb[nd.a];
    return struct {
        const Inner = Node(G, nd.a, BehindAccept, false);
        fn run(c: *Ctx, pos: usize) Error!bool {
            try tick(c);
            // Typed `usize`: with `wb` comptime, `@min` would narrow to the
            // comptime operand's type (`u1` for width 1) and `w += 1` would wrap.
            const hi: usize = if (wb.bounded) @min(wb.max, pos) else pos;
            const lo: usize = @min(wb.min, pos);
            const saved_seen = c.seen;
            const saved_at = c.behind_at;
            c.seen = null;
            c.behind_at = pos;
            var ok = false;
            var w: usize = lo;
            while (w <= hi) : (w += 1) {
                if (try Inner.run(c, pos - w)) {
                    ok = true;
                    break;
                }
            }
            c.seen = saved_seen;
            c.behind_at = saved_at;
            if (ok != neg) return K.run(c, pos);
            return false;
        }
    };
}

// ── Sequences and counted repeats ───────────────────────────────────────────

const Run = struct { x: NodeRef, min: usize, max: usize, greedy: bool, len: usize };

/// The `{m,n}` expansion at the head of a concat: `m` copies of `x` then
/// `n - m ≥ 1` optional copies `x?`, all structurally equal. Fused only when
/// that is exact for this engine:
///   * `x` has no loop, so no ε-cycle state is ever recorded inside it (the
///     fused form reuses one copy's node refs for every iteration);
///   * `x` cannot match empty;
///   * `x` has no capture group when slots are live;
///   * greedy, or every copy is fixed-width. A greedy flat expansion tries,
///     per prefix of taken copies, "one more" before "stop"; its extra
///     skip-then-take orderings reach a position already handed to the same
///     continuation, so they only repeat failed work. A lazy flat expansion
///     instead orders shorter totals first, which matches "stop before one
///     more" only when every copy has the same width.
fn headRun(comptime G: type, comptime items: []const NodeRef) ?Run {
    if (!FUSE_REPEATS) return null;
    const first = G.hh.nodes[items[0]];
    const x = if (first.tag == .opt) first.a else items[0];
    const info = G.info;
    if (info.loops[x] or info.wb[x].min == 0) return null;
    if (G.slots and info.caps[x]) return null;
    var i: usize = 0;
    var mandatory: usize = 0;
    while (i < items.len and same(G, items[i], x)) : (i += 1) mandatory += 1;
    var optional: usize = 0;
    var greedy = true;
    while (i < items.len) : (i += 1) {
        const nd = G.hh.nodes[items[i]];
        if (nd.tag != .opt or !same(G, nd.a, x)) break;
        if (optional > 0 and nd.greedy != greedy) break;
        greedy = nd.greedy;
        optional += 1;
    }
    if (optional == 0 or mandatory + optional < 2) return null;
    const fixed = info.wb[x].bounded and info.wb[x].min == info.wb[x].max;
    if (!greedy and !fixed) return null;
    return .{ .x = x, .min = mandatory, .max = mandatory + optional, .greedy = greedy, .len = i };
}

fn Seq(comptime G: type, comptime items: []const NodeRef, comptime K: type, comptime cyc: bool) type {
    @setEvalBranchQuota(10_000_000);
    if (items.len == 0) return K;
    if (headRun(G, items)) |r| return Repeat(G, r, Seq(G, items[r.len..], K, cyc));
    return Node(G, items[0], Seq(G, items[1..], K, cyc), cyc);
}

fn Repeat(comptime G: type, comptime r: Run, comptime K: type) type {
    const xn = G.hh.nodes[r.x];
    if (xn.tag == .set) return SetRepeat(G.hh.sets[xn.set_idx], r.min, r.max, r.greedy, K);
    return Iter(G, r, K, 0);
}

/// `C{min,max}` over one byte class: a bounded scan with give-back.
fn SetRepeat(comptime bm: [32]u8, comptime min: usize, comptime max: usize, comptime greedy: bool, comptime K: type) type {
    return struct {
        fn run(c: *Ctx, pos: usize) Error!bool {
            const in = c.input;
            const lim: usize = @min(in.len, pos + max);
            if (greedy) {
                var e: usize = pos;
                while (e < lim and inSet(bm, in[e])) e += 1;
                if (e - pos < min) return false;
                var p: usize = e;
                while (true) : (p -= 1) {
                    if (try K.run(c, p)) return true;
                    if (p == pos + min) return false;
                    try tick(c);
                }
            }
            var p: usize = pos;
            while (p < pos + min) : (p += 1) {
                if (p >= in.len or !inSet(bm, in[p])) return false;
            }
            while (true) {
                if (try K.run(c, p)) return true;
                if (p >= lim or !inSet(bm, in[p])) return false;
                p += 1;
                try tick(c);
            }
        }
    };
}

/// `x{min,max}` for a general loop-free `x`: `min` copies, then per further
/// copy "one more, or stop" (greedy) / "stop, or one more" (lazy).
fn Iter(comptime G: type, comptime r: Run, comptime K: type, comptime i: usize) type {
    if (i < r.min) return Node(G, r.x, Iter(G, r, K, i + 1), false);
    if (i == r.max) return K;
    return struct {
        const Body = Node(G, r.x, Iter(G, r, K, i + 1), false);
        fn run(c: *Ctx, pos: usize) Error!bool {
            try tick(c);
            if (r.greedy) {
                if (try Body.run(c, pos)) return true;
                return K.run(c, pos);
            }
            if (try K.run(c, pos)) return true;
            return Body.run(c, pos);
        }
    };
}

// ── The matcher ─────────────────────────────────────────────────────────────

/// The compiled matcher for the baked HIR `h` (`cap == h.node_count`). Same
/// scan loop and `runFrom` contract as `backtrack.BacktrackerG`: leftmost match
/// at/after absolute `from` over the full input, slots in `slots_out`.
pub fn Compiled(comptime cap: usize, comptime h: hir.Hir(cap), comptime opts: Opts) type {
    @setEvalBranchQuota(10_000_000);
    const G = struct {
        pub const hh = h;
        pub const info = analyze(cap, h);
        pub const n_groups = opts.n_groups;
        /// Capture slots are written: the captures path, or a backreference
        /// reads them.
        pub const slots = opts.captures or info.backref[h.root];
    };
    const Top = if (h.anchored_end) TopAcceptEnd else TopAccept;
    return struct {
        const Self = @This();
        const live = 2 * (opts.n_groups + 1);
        const a_start = h.anchored_start;
        const a_end = h.anchored_end;
        const Root = Node(G, h.root, Top, false);
        const alt_branches = opts.alt_branches;
        const alt_table = opts.alt_table;

        /// Optional seek prefilter (see `seek.zig`), as `BacktrackerG.seek`.
        seek: ?*const seek_mod.Seek = null,
        /// Line-start enumeration for a `(?m)^…` pattern (every match begins at
        /// a line start), with `line_first` its one-byte line filter.
        line_anchor: bool = false,
        line_first: ?[32]u8 = null,

        pub fn init(seek: ?*const seek_mod.Seek) Self {
            return .{ .seek = seek };
        }

        /// A match attempt anchored at `start`. With a dispatch table only the
        /// branches that can begin at `input[start]` are tried, in source
        /// order — the same first match as walking the whole alternation,
        /// since a skipped branch provably cannot begin one there.
        inline fn tryAt(c: *Ctx, start: usize) Error!bool {
            if (alt_branches.len > 0 and start < c.input.len) {
                const bits = alt_table[c.input[start]];
                inline for (alt_branches, 0..) |br, i| {
                    if (bits & (@as(AltMask, 1) << @as(u6, @intCast(i))) != 0) {
                        if (try Node(G, br, Top, false).run(c, start)) return true;
                    }
                }
                return false;
            }
            return Root.run(c, start);
        }

        inline fn attempt(c: *Ctx, start: usize, slots_out: []hir.Slot) Error!?Span {
            if (G.slots) {
                @memset(c.slots[0..live], -1);
                c.slots[0] = @intCast(start);
            }
            if (!try tryAt(c, start)) return null;
            const end = if (a_end) c.input.len else c.match_end;
            if (slots_out.len >= live) {
                if (G.slots) {
                    c.slots[1] = @intCast(end);
                    @memcpy(slots_out[0..live], c.slots[0..live]);
                } else {
                    @memset(slots_out[0..live], -1);
                    slots_out[0] = @intCast(start);
                    slots_out[1] = @intCast(end);
                }
            }
            return .{ .start = start, .end = end };
        }

        /// Leftmost match at/after absolute `from`, scanning the full `input`
        /// so look-assertions see the true context (see
        /// `BacktrackerG.runFrom`). `error.Budget` past the step/stack bound.
        pub fn runFrom(self: *const Self, input: []const u8, from: usize, slots_out: []hir.Slot) Error!?Span {
            var c: Ctx = .{ .input = input, .budget = backtrack.BUDGET_BASE + @as(u64, input.len + 1) * backtrack.BUDGET_PER_BYTE };
            // `$`-anchored fast negative over the regular over-approximation.
            if (self.seek) |sd| {
                if (sd.rejectsAnchoredEnd(input, from)) return null;
            }
            if (self.line_anchor) return self.lineStartScan(&c, from, slots_out);
            var start: usize = from;
            while (start <= input.len) : (start += 1) {
                if (self.seek) |sd| {
                    const next = sd.locate(input, start) orelse return null;
                    // A folded `^`/`\A` allows `from` only.
                    if (a_start and next != start) return null;
                    start = next;
                    if (start > input.len) return null;
                }
                if (try attempt(&c, start, slots_out)) |sp| return sp;
                if (a_start) return null;
            }
            return null;
        }

        /// `(?m)^…`: try line starts only, rejecting a line on its first byte
        /// via `line_first` — the shared `line_dfa.scanLineStarts` enumeration
        /// with `attempt` per line (the runtime peer is
        /// `bounded_bt.findLineStart`).
        fn lineStartScan(self: *const Self, c: *Ctx, from: usize, slots_out: []hir.Slot) Error!?Span {
            const Line = struct {
                c: *Ctx,
                slots_out: []hir.Slot,

                pub fn attempt(self_: @This(), s: usize, _: usize) Error!?Span {
                    return Self.attempt(self_.c, s, self_.slots_out);
                }
            };
            const first: ?*const [32]u8 = if (self.line_first) |*set| set else null;
            return line_dfa.scanLineStarts(c.input, from, first, Line{ .c = c, .slots_out = slots_out });
        }
    };
}

// ── Tests: compiled == interpreter, slot for slot ───────────────────────────
//
// Both engines run over the same baked HIR from every start offset; the span
// and every capture slot must agree (the `captures` instantiation), and the
// whole-match instantiation must agree on the span. The compiled matcher
// charges a step only where the interpreter charges at least one, and counts
// fewer frames, so it may only fail with `error.Budget` where the interpreter
// does too.

const testing = std.testing;
const parser = @import("../parser.zig");
const nfa_fuzz = @import("nfa_fuzz.zig");

const TEST_HIR_CAP = 2048;
const Parsed = struct { h: hir.Hir(TEST_HIR_CAP), ng: usize, ok: bool };

fn parseForTest(comptime pattern: []const u8) Parsed {
    @setEvalBranchQuota(100_000_000);
    var h = hir.Hir(TEST_HIR_CAP).initComptime();
    var ng: usize = 0;
    var names: [hir.MAX_GROUPS + 1]?[]const u8 = @splat(null);
    parser.parseCaptures(TEST_HIR_CAP, &h, undefined, pattern, .{}, &ng, &names) catch
        return .{ .h = h, .ng = 0, .ok = false };
    return .{ .h = h, .ng = ng, .ok = true };
}

/// The HIR trimmed to its node count, as `Pattern` bakes it.
fn trimForTest(comptime src: hir.Hir(TEST_HIR_CAP)) hir.Hir(src.node_count) {
    @setEvalBranchQuota(100_000_000);
    const n = src.node_count;
    var t = hir.Hir(n).initComptime();
    t.node_count = n;
    t.set_count = src.set_count;
    t.root = src.root;
    t.anchored_start = src.anchored_start;
    t.anchored_end = src.anchored_end;
    t.saw_lazy = src.saw_lazy;
    for (0..n) |i| t.nodes[i] = src.nodes[i];
    for (0..src.set_count) |s| t.sets[s] = src.sets[s];
    for (src.set_count..n) |s| t.sets[s] = @splat(0);
    return t;
}

fn Pair(comptime pattern: []const u8) type {
    const parsed = parseForTest(pattern);
    if (!parsed.ok) @compileError("test pattern does not parse: " ++ pattern);
    const n = parsed.h.node_count;
    const baked_h = trimForTest(parsed.h);
    return struct {
        const baked = baked_h;
        const ng = parsed.ng;
        const live = 2 * (ng + 1);
        const Interp = backtrack.BacktrackerG(n);
        const WithSlots = Compiled(n, baked, .{ .n_groups = ng, .captures = true });
        const WholeMatch = Compiled(n, baked, .{ .n_groups = ng, .captures = false });

        fn check(input: []const u8, from: usize) !void {
            var want: [2 * (hir.MAX_GROUPS + 1)]hir.Slot = undefined;
            var bt = Interp.init(&baked, baked.anchored_start, baked.anchored_end, ng, null, null);
            const expect = bt.runFrom(input, from, want[0..live]) catch return;

            var got: [2 * (hir.MAX_GROUPS + 1)]hir.Slot = undefined;
            const with_slots = WithSlots.init(null);
            const a = try with_slots.runFrom(input, from, got[0..live]);
            const whole = WholeMatch.init(null);
            const b = try whole.runFrom(input, from, got[live..][0..live]);
            errdefer std.debug.print("\ncompiled_bt MISMATCH pattern=\"{f}\" input=\"{f}\" from={d}\n", .{
                std.zig.fmtString(pattern), std.zig.fmtString(input), from,
            });
            try testing.expectEqual(expect, a);
            try testing.expectEqual(expect, b);
            if (expect != null) try testing.expectEqualSlices(hir.Slot, want[0..live], got[0..live]);
        }

        fn checkAll(input: []const u8) !void {
            for (0..input.len + 1) |from| try check(input, from);
        }
    };
}

fn agree(comptime pattern: []const u8, inputs: []const []const u8) !void {
    const P = Pair(pattern);
    for (inputs) |in| try P.checkAll(in);
}

test "compiled_bt: ε-cycles — loops whose body can match empty" {
    const in = [_][]const u8{ "", "a", "aa", "aab", "ab", "ba", "aaa b", "bab" };
    try agree("(?:a*?)*", &in);
    try agree("(?:a*)*b", &in);
    try agree("(a|)*", &in);
    try agree("(a|)+b", &in);
    try agree("(?:a?)*?b", &in);
    try agree("(a*)+", &in);
    try agree("(a*)*?b", &in);
    try agree("(?:(a)|b)*", &in);
    try agree("(?:a?b?)*", &in);
    try agree("(?:x?a*?)*b", &in);
    // A loop whose own body cannot match empty still sits on an ε-cycle when
    // an enclosing body can: iteration 2 re-enters `c*?` at the position
    // iteration 1 left it, and that path must die (interpreter: [0,1)).
    try agree("(?:x?c*?)*", &.{ "xcc", "xc", "xxcc", "cxc" });
    try agree("(?:x?(?:c|d)*?)*", &.{ "xcd", "xdc", "dxc" });
    try agree("(?:(?:a*)*)*b", &in);
    try agree("(?:\\b|a)*b", &in);
    try agree("(?:(?=a)|b)*", &in);
    try agree("(?>a*)*b", &in);
    try agree("(?:a|(?>b*))+?$", &in);
}

test "compiled_bt: captures, backrefs, atomic, lookaround" {
    const in = [_][]const u8{ "", "ab", "abab", "aXbAB", "the the cat", "abcabc", "xyz$12.50", "aab abb" };
    try agree("(a)|(b)", &in);
    try agree("((a)|b)+", &in);
    try agree("(a+)+\\1", &in);
    try agree("(?i)(ab)\\1", &in);
    try agree("(\\w+) \\1", &in);
    try agree("(?<n>a)(?<m>b)?\\k<n>", &in);
    try agree("(?>(a)+)b", &in);
    try agree("(?>(ab)|a)b", &in);
    // The atomic body set group 1, its continuation failed, the next branch
    // matches: the group must be unset again.
    try agree("(?:(?>(a))x|ab)", &in);
    try agree("(?:(?>(a)b?)c|a(b))", &in);
    try agree("a*+a", &in);
    try agree("(?:ab)++", &in);
    try agree("(?=(?:ab)+)\\w", &in);
    try agree("(?!a)\\w+", &in);
    try agree("(?<=a|bc)\\w", &in);
    try agree("(?<!ab*)b", &in);
    try agree("(?<=\\$)[0-9]+(?:\\.[0-9]{2})?", &in);
    try agree("(?<=(?<!b)a)b", &in);
    try agree("\\b\\w+\\b", &in);
    try agree("(?m)^(?:a|ab)(?:c|bcd)?$", &in);
    try agree("^(?:a|ab)b", &in);
    try agree("a.*?b$", &in);
}

test "compiled_bt: counted repeats (fused {m,n} expansions) and lazy loops" {
    const in = [_][]const u8{ "", "1", "12345678", "a1b22c333", "abcbcd", "aaaa", "ab ab ab", "aaab" };
    try agree("[0-9]{1,5}", &in);
    try agree("[0-9]{2,4}?[0-9]", &in);
    try agree("(?:ab|c){0,3}d?", &in);
    try agree("(?:a|bc){1,3}?d?", &in); // lazy, variable width: not fused
    try agree("(?:ab|c){1,3}?b", &in); // lazy, variable width: not fused
    try agree("(?:ab|ba){1,3}?b", &in); // lazy, fixed width: fused
    // Lazy + variable width is NOT fused: the flat expansion reaches end 3
    // (`aaa`) before end 2 (`a`,`a`), "stop before one more" the reverse.
    try agree("(?:a|aaa){0,3}?(?<=aa)", &.{ "aaab", "aaaa", "aaaaaa" });
    try agree("(?:a|aaa){0,3}(?<=aa)", &.{ "aaab", "aaaa", "aaaaaa" }); // greedy: fused, exact
    try agree("(x|a){0,3}a", &in);
    try agree("(?:a{1,3}){2}b", &in);
    try agree("a{2,}", &in);
    try agree("\\w{0,3}?b", &in);
    try agree("[a-c]+?b", &in);
    try agree("[a-c]*?$", &in);
    try agree("(?:\\d|ab){0,2}(?<=b)", &in);
    try agree(".{0,6}b", &in);
}

/// Generated patterns from the `nfa_fuzz` grammar, regular and non-regular,
/// kept when they parse on the comptime HIR store.
const FUZZ_PATTERNS = 160;
const fuzz_corpus: [FUZZ_PATTERNS][]const u8 = blk: {
    @setEvalBranchQuota(1_000_000_000);
    const shapes = [_]nfa_fuzz.Shape{ .random, .random, .nonregular, .nonregular, .nonregular, .dup_word, .split_alt, .edge_look };
    var rng = nfa_fuzz.Rng{ .s = 0xb7_c0de };
    var list: [FUZZ_PATTERNS][]const u8 = undefined;
    var n: usize = 0;
    while (n < FUZZ_PATTERNS) {
        const g = nfa_fuzz.generate(&rng, nfa_fuzz.pickShape(&rng, &shapes));
        if (g.overflow) continue;
        const pat: [g.len]u8 = g.buf[0..g.len].*;
        if (!parseForTest(&pat).ok) continue;
        list[n] = &pat;
        n += 1;
    }
    break :blk list;
};

test "compiled_bt: generated patterns agree with the interpreter" {
    var rng = nfa_fuzz.Rng{ .s = 0x51_07 };
    var buf: [nfa_fuzz.MAX_INPUT]u8 = undefined;
    inline for (fuzz_corpus) |pat| {
        const P = Pair(pat);
        for (0..6) |_| try P.checkAll(nfa_fuzz.genInput(&rng, &buf, .short));
        const med = nfa_fuzz.genInput(&rng, &buf, .medium);
        var from: usize = 0;
        while (from <= med.len) : (from += 7) try P.check(med, from);
    }
}
