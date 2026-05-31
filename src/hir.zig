//! Index-based value IR shared by the comptime and runtime pipelines.
//!
//! `Hir(cap)` is a flat node store: no pointers, no allocator *in its shape*.
//! `cap == N` (comptime) backs it with fixed arrays so the whole IR is
//! comptime-evaluable; `cap == null` (runtime) backs it with growable
//! `ArrayListUnmanaged`s. `parser.zig` writes it; `thompson.zig` reads it.
//!
//! The IR is deliberately *post-lowering*: `{m,n}` repetition is already
//! expanded by the parser into `concat`/`opt`/`star`/`plus` subtrees (one
//! freshly-parsed atom copy per repetition), so a straightforward post-order
//! Thompson walk produces fixed NFA fragment shapes.

const std = @import("std");

pub const NodeRef = u32;

/// Sentinel "no child". Real refs are indices `< node_count`.
pub const none: NodeRef = std.math.maxInt(NodeRef);

pub const Tag = enum(u8) {
    /// Matches the empty string (two states + one epsilon).
    empty,
    /// Consumes one byte from `set_idx`'s 256-bit bitmap.
    set,
    /// `a` then `b` (left-leaning chains model n-ary concat).
    concat,
    /// `a` or `b` (left-leaning chains model n-ary alternation).
    alt,
    /// `a*` — `greedy` selects the epsilon priority order.
    star,
    /// `a+`.
    plus,
    /// `a?`.
    opt,
    /// Zero-width assertion; `set_idx` holds the `LookKind`. Conditional
    /// epsilon in the NFA — evaluated against (prev,next) byte context by the
    /// bounded-backtracker (look-bearing patterns route there, not the DFA).
    look,
    /// Capture group: `a` is the inner expression, `set_idx` is the 1-based
    /// group index. Lowers to two plain (kind-0) epsilons carrying a save-slot
    /// id, so it is fully transparent to the DFA (find/isMatch unchanged); the
    /// bounded-backtracker reconstructs slots only for the `captures()` path.
    cap,
    /// Backreference to a prior group: `set_idx` = referenced group index.
    /// Non-regular → handled only by the tree backtracker (Phase E).
    backref,
    /// Lookaround: `a` = sub-expression; `set_idx` bit0 = lookbehind,
    /// bit1 = negative. Non-regular → tree backtracker (Phase E).
    look_around,
    /// Atomic group `(?>a)` — match `a` to its single highest-priority end
    /// and commit (no backtracking back into it). Possessive quantifiers
    /// `a*+`/`a++`/`a?+`/`a{m,n}+` are lowered by the parser to `atomic` around
    /// the greedy quantifier (`(?>a*)` etc.) — semantically identical. Changes
    /// the matched language vs the non-atomic form (`(?>a*)a` ≠ `a*a`), so it
    /// is non-regular → tree backtracker only (the DFA cannot fold the cut).
    atomic,
};

/// `look_around.set_idx` bit flags.
pub const LA_BEHIND: u32 = 1;
pub const LA_NEGATIVE: u32 = 2;

/// Max capturing groups (group 0 = whole match). Slots = 2*(MAX_GROUPS+1).
pub const MAX_GROUPS: usize = 32;

/// Zero-width assertion kinds (Rust `nfa::thompson::Look` shape).
pub const LookKind = enum(u8) {
    word_boundary, // \b
    non_word_boundary, // \B
    start_text, // \A  (and ^ without (?m))
    end_text, // \z  (and $ without (?m))
    end_text_before_nl, // \Z
    start_line, // ^ under (?m)
    end_line, // $ under (?m)
};

pub const HNode = struct {
    tag: Tag,
    /// First child (or `none`). For leaves: unused.
    a: NodeRef = none,
    /// Second child (or `none`). Only `concat`/`alt`.
    b: NodeRef = none,
    /// Index into the set table for `tag == .set`.
    set_idx: u32 = 0,
    /// Epsilon priority for `star`/`plus`/`opt`: greedy vs lazy.
    greedy: bool = true,
};

/// Overflow / unsupported / invalid signalling for the parser → HIR stage.
/// `Invalid` = malformed syntax (→ `RegexError.InvalidPattern`); `Unsupported`
/// = well-formed but not-yet-implemented (→ `NotImplemented`); `TooComplex` =
/// construction-ceiling overflow (→ `PatternTooComplex`).
pub const Error = error{ Unsupported, TooComplex, Invalid };

/// Construction ceilings. Exceeding them yields `Error.TooComplex` so the
/// caller can route to the runtime fallback (never a wrong answer), exactly
/// like the old fixed `MAX_*` sentinels.
pub const MAX_NODES: usize = 4096;
pub const MAX_SETS: usize = 4096;

/// `cap == null` -> runtime store (allocator-backed); `cap == N` -> comptime
/// store (fixed arrays, no allocator). Both expose the same method surface so
/// `parser`/`thompson` are written once, generic over the store.
pub fn Hir(comptime cap: ?usize) type {
    return struct {
        const Self = @This();
        pub const is_comptime = cap != null;

        nodes: if (cap) |c| [c]HNode else std.ArrayListUnmanaged(HNode),
        node_count: usize,
        sets: if (cap) |c| [c][32]u8 else std.ArrayListUnmanaged([32]u8),
        set_count: usize,
        /// Root node ref, set by the parser when it finishes.
        root: NodeRef,
        /// Prescan results (see `parser.prescan`).
        anchored_start: bool,
        anchored_end: bool,
        /// Set when any lazy quantifier fragment is produced (drives the
        /// `anchored_end && saw_lazy` fallback the old `computeDfa` applies).
        saw_lazy: bool,

        /// Comptime store initializer (no allocator).
        pub fn initComptime() Self {
            comptime std.debug.assert(cap != null);
            return .{
                .nodes = undefined,
                .node_count = 0,
                .sets = undefined,
                .set_count = 0,
                .root = none,
                .anchored_start = false,
                .anchored_end = false,
                .saw_lazy = false,
            };
        }

        /// Runtime store initializer.
        pub fn initRuntime() Self {
            comptime std.debug.assert(cap == null);
            return .{
                .nodes = .empty,
                .node_count = 0,
                .sets = .empty,
                .set_count = 0,
                .root = none,
                .anchored_start = false,
                .anchored_end = false,
                .saw_lazy = false,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (cap == null) {
                self.nodes.deinit(allocator);
                self.sets.deinit(allocator);
            }
        }

        /// Append a node, returning its ref. `allocator` is unused (and may be
        /// `undefined`) for the comptime store.
        pub fn addNode(self: *Self, allocator: std.mem.Allocator, n: HNode) Error!NodeRef {
            if (cap) |c| {
                if (self.node_count >= c or self.node_count >= MAX_NODES) return Error.TooComplex;
                self.nodes[self.node_count] = n;
            } else {
                if (self.node_count >= MAX_NODES) return Error.TooComplex;
                self.nodes.append(allocator, n) catch return Error.TooComplex;
            }
            const id: NodeRef = @intCast(self.node_count);
            self.node_count += 1;
            return id;
        }

        /// Append a 256-bit byte set, returning its index.
        pub fn addSet(self: *Self, allocator: std.mem.Allocator, bitmap: [32]u8) Error!u32 {
            if (cap) |c| {
                if (self.set_count >= c or self.set_count >= MAX_SETS) return Error.TooComplex;
                self.sets[self.set_count] = bitmap;
            } else {
                if (self.set_count >= MAX_SETS) return Error.TooComplex;
                self.sets.append(allocator, bitmap) catch return Error.TooComplex;
            }
            const id: u32 = @intCast(self.set_count);
            self.set_count += 1;
            return id;
        }

        pub fn node(self: *const Self, ref: NodeRef) HNode {
            if (cap != null) return self.nodes[ref];
            return self.nodes.items[ref];
        }

        pub fn setBitmap(self: *const Self, idx: u32) [32]u8 {
            if (cap != null) return self.sets[idx];
            return self.sets.items[idx];
        }
    };
}

/// Deep-copy subtree `ref` from `src` into `dst` (runtime HIR), re-interning
/// set bitmaps so `dst` is self-contained. `relax_irregular` (comptime):
///   * `false` — faithful clone of every tag (the old `split_alt.cloneExact`
///     / `delegate.copyReg`).
///   * `true`  — `look`/`look_around`/`backref` collapse to `empty` and
///     `atomic` drops its cut (keeping the inner subtree), a sound
///     *language-enlarging* relaxation (the old `seek.lowerApprox`): used to
///     derive a regular over-approximation.
/// One definition replaces three near-identical recursive copies.
pub fn cloneSubtree(
    dst: *Hir(null),
    a: std.mem.Allocator,
    src: *const Hir(null),
    ref: NodeRef,
    comptime relax_irregular: bool,
) Error!NodeRef {
    const nd = src.node(ref);
    switch (nd.tag) {
        .look, .look_around, .backref => {
            if (relax_irregular) return dst.addNode(a, .{ .tag = .empty });
            return switch (nd.tag) {
                // look / backref are leaves (set_idx = LookKind / group).
                .look, .backref => dst.addNode(a, .{ .tag = nd.tag, .set_idx = nd.set_idx }),
                // look_around carries a sub-expression.
                else => dst.addNode(a, .{
                    .tag = .look_around,
                    .a = try cloneSubtree(dst, a, src, nd.a, relax_irregular),
                    .set_idx = nd.set_idx,
                }),
            };
        },
        .empty => return dst.addNode(a, .{ .tag = .empty }),
        .set => {
            const idx = try dst.addSet(a, src.setBitmap(nd.set_idx));
            return dst.addNode(a, .{ .tag = .set, .set_idx = idx });
        },
        .concat, .alt => {
            const la = try cloneSubtree(dst, a, src, nd.a, relax_irregular);
            const lb = try cloneSubtree(dst, a, src, nd.b, relax_irregular);
            return dst.addNode(a, .{ .tag = nd.tag, .a = la, .b = lb });
        },
        .star, .plus, .opt => {
            const la = try cloneSubtree(dst, a, src, nd.a, relax_irregular);
            return dst.addNode(a, .{ .tag = nd.tag, .a = la, .greedy = nd.greedy });
        },
        .cap => {
            const la = try cloneSubtree(dst, a, src, nd.a, relax_irregular);
            return dst.addNode(a, .{ .tag = .cap, .a = la, .set_idx = nd.set_idx });
        },
        .atomic => {
            // Relaxed over-approximation: drop the cut (`(?>R)` matches a
            // subset of `R`, so plain `R` is a sound language-enlarging
            // superset). Faithful clone: keep the atomic wrapper.
            const la = try cloneSubtree(dst, a, src, nd.a, relax_irregular);
            if (relax_irregular) return la;
            return dst.addNode(a, .{ .tag = .atomic, .a = la });
        },
    }
}

test "hir comptime store basic shape" {
    const H = Hir(64);
    var h = H.initComptime();
    const s = try h.addSet(undefined, [_]u8{0} ** 32);
    const leaf = try h.addNode(undefined, .{ .tag = .set, .set_idx = s });
    const star = try h.addNode(undefined, .{ .tag = .star, .a = leaf, .greedy = true });
    try std.testing.expectEqual(@as(usize, 2), h.node_count);
    try std.testing.expectEqual(Tag.star, h.node(star).tag);
    try std.testing.expectEqual(Tag.set, h.node(h.node(star).a).tag);
}
