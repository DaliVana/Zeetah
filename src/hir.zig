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
const common = @import("common.zig");
const uset = @import("unicode_set.zig");

pub const NodeRef = u32;

/// An inclusive codepoint range (`.uclass` member storage).
pub const CodepointRange = common.CodepointRange;

/// A `.uclass` descriptor: `len` ranges starting at `off` in the store's
/// `uranges` pool (normalized, surrogate-free, negation folded in), plus the
/// set's 128-bit ASCII membership map (`unicode_set.asciiBits`) — the
/// per-scalar fast path of the backtracking tier.
pub const UClass = struct { off: u32, len: u32, ascii: [16]u8 = @splat(0) };

/// Sentinel "no child". Real refs are indices `< node_count`.
pub const none: NodeRef = std.math.maxInt(NodeRef);

pub const Tag = enum(u8) {
    /// Matches the empty string (two states + one epsilon).
    empty,
    /// Consumes one byte from `set_idx`'s 256-bit bitmap.
    set,
    /// Consumes one UTF-8-encoded Unicode scalar value from the codepoint set
    /// `uclasses[set_idx]` (codepoint mode `(?u)` only). An ASCII-only set is
    /// emitted as a plain `.set` by the parser, so every byte-class fast path
    /// keeps applying; this node is reserved for sets with members ≥ U+0080.
    /// `thompson` lowers it to a suffix-shared UTF-8 byte automaton; the tree
    /// and compiled backtrackers decode one scalar and test membership. An
    /// invalid UTF-8 sequence in the haystack never matches.
    uclass,
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
/// The comptime `Pattern` and the tree backtracker (`exec/backtrack.zig`, whose
/// per-atomic slot snapshot lives on the stack) are sized to this.
pub const MAX_GROUPS: usize = 32;
/// Runtime capture-group ceiling for the NFA engines (lazy DFA, bounded
/// backtracker, PikeVM, one-pass), whose slot buffers are sized per pattern.
/// A runtime pattern that needs the tree backtracker still takes `MAX_GROUPS`.
pub const MAX_GROUPS_RUNTIME: usize = 255;

/// Group ceiling for a store: the runtime heap store (`cap == null`) gets
/// `MAX_GROUPS_RUNTIME`, the comptime store `MAX_GROUPS`.
pub fn groupsCap(comptime cap: ?usize) usize {
    return if (cap == null) MAX_GROUPS_RUNTIME else MAX_GROUPS;
}

/// A capture-slot VALUE: a byte offset into the haystack, or -1 = unset.
/// Pointer-width so every offset of an in-memory haystack is representable —
/// an `i32` truncated positions past 2 GiB (a panic on safe builds; in
/// ReleaseFast a negative value that became a huge `usize` slice index). Slot
/// INDICES (`e_slot`, "which slot does this ε write") stay small `i32`s.
pub const Slot = isize;
comptime {
    std.debug.assert(@bitSizeOf(Slot) == @bitSizeOf(usize)); // every offset fits
}

/// Zero-width assertion kinds (Rust `nfa::thompson::Look` shape).
pub const LookKind = enum(u8) {
    word_boundary, // \b
    non_word_boundary, // \B
    start_text, // \A  (and ^ without (?m))
    end_text, // \z  (and $ without (?m))
    end_text_before_nl, // \Z
    start_line, // ^ under (?m)
    end_line, // $ under (?m)
    /// `\b` under `(?u)`: Unicode word boundary — the neighbours are decoded
    /// scalars tested against the UTS #18 Annex C `\w` (`utf8.isWordCp`); an
    /// undecodable neighbour counts as non-word. Not foldable into the byte-
    /// context lazy DFA (it needs up to 4 bytes of context each side), so
    /// look patterns with it run on the bounded backtracker / PikeVM.
    word_boundary_unicode,
    /// `\B` under `(?u)`.
    non_word_boundary_unicode,
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
    /// `backref` only: compare ASCII-case-insensitively — the reference was
    /// parsed under `(?i)`, so `(?i)(ab)\1` must match "abAB" (the group's
    /// text in any case, like the literals/classes `(?i)` already folds).
    fold: bool = false,
    /// `backref` only: the reference was parsed under `(?iu)` — compare
    /// scalar-by-scalar under Unicode simple case folding (`utf8.eqlFold`;
    /// the matched byte length may differ from the group's: `K` vs `K`).
    ufold: bool = false,
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
/// Runtime (heap `Hir(null)`) ceilings: enough for machine-generated patterns
/// (a ~100-alternative secret scanner is ~22 K nodes / ~9 K sets) while still
/// bounding memory (≤ 2 MiB nodes + 2 MiB sets) and `{m,n}` expansion. Sets
/// stay ≤ 65535 so the NFA's `u16` set ids never overflow.
pub const MAX_NODES_RUNTIME: usize = 1 << 17;
pub const MAX_SETS_RUNTIME: usize = 65535;
/// `.uclass` storage ceilings. Comptime: a fixed pool (`\P{L}` is ~700 ranges;
/// identical classes are interned once, so the cl100k tokenizer's seven
/// property classes need ~2 000). Runtime: generous heap ceilings.
pub const URANGE_CAP: usize = 8192;
pub const MAX_UCLASSES: usize = 256;
pub const MAX_URANGES_RUNTIME: usize = 1 << 20;
pub const MAX_UCLASSES_RUNTIME: usize = 65535;
/// Runtime HIR depth ceiling. The analyses, the NFA lowering and the cloner
/// walk the tree recursively; the old 4096-node ceiling bounded their depth
/// implicitly, and this keeps that bound now that the node ceiling is larger
/// (a wide pattern stays fine, a 20 000-deep `a{20000}` chain is rejected).
pub const MAX_DEPTH_RUNTIME: usize = 4096;

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
        /// `.uclass` codepoint-range pool + descriptors (see `UClass`).
        uranges: if (cap != null) [URANGE_CAP]CodepointRange else std.ArrayListUnmanaged(CodepointRange),
        urange_count: usize,
        uclasses: if (cap != null) [MAX_UCLASSES]UClass else std.ArrayListUnmanaged(UClass),
        uclass_count: usize,
        /// Root node ref, set by the parser when it finishes.
        root: NodeRef,
        /// Prescan results (see `parser.prescan`).
        anchored_start: bool,
        anchored_end: bool,
        /// Set when any lazy quantifier fragment is produced (gates the
        /// literal prefilters that must not see `.*?`-bearing shapes).
        saw_lazy: bool,

        /// Comptime store initializer (no allocator).
        pub fn initComptime() Self {
            comptime std.debug.assert(cap != null);
            return .{
                .nodes = undefined,
                .node_count = 0,
                .sets = undefined,
                .set_count = 0,
                .uranges = undefined,
                .urange_count = 0,
                .uclasses = undefined,
                .uclass_count = 0,
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
                .uranges = .empty,
                .urange_count = 0,
                .uclasses = .empty,
                .uclass_count = 0,
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
                self.uranges.deinit(allocator);
                self.uclasses.deinit(allocator);
            }
        }

        /// Whether any node lies deeper than `limit` (runtime store). Children
        /// are always created before their parent, so one pass in index order
        /// computes every node's height — no recursion, so the check itself is
        /// stack-safe on exactly the trees it exists to reject.
        pub fn tooDeep(self: *const Self, allocator: std.mem.Allocator, limit: usize) Error!bool {
            const height = allocator.alloc(u32, self.node_count) catch return Error.TooComplex;
            defer allocator.free(height);
            for (0..self.node_count) |i| {
                const nd = self.node(@intCast(i));
                var d: u32 = 0;
                if (nd.a != none) {
                    std.debug.assert(nd.a < i);
                    d = height[nd.a];
                }
                if (nd.b != none) {
                    std.debug.assert(nd.b < i);
                    d = @max(d, height[nd.b]);
                }
                height[i] = d + 1;
                if (height[i] > limit) return true;
            }
            return false;
        }

        /// Append a node, returning its ref. `allocator` is unused (and may be
        /// `undefined`) for the comptime store.
        pub fn addNode(self: *Self, allocator: std.mem.Allocator, n: HNode) Error!NodeRef {
            if (cap) |c| {
                if (self.node_count >= c or self.node_count >= MAX_NODES) return Error.TooComplex;
                self.nodes[self.node_count] = n;
            } else {
                if (self.node_count >= MAX_NODES_RUNTIME) return Error.TooComplex;
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
                if (self.set_count >= MAX_SETS_RUNTIME) return Error.TooComplex;
                self.sets.append(allocator, bitmap) catch return Error.TooComplex;
            }
            const id: u32 = @intCast(self.set_count);
            self.set_count += 1;
            return id;
        }

        /// Intern a normalized codepoint set as a `.uclass` member set and
        /// return its index. Identical sets (same ranges) share one entry, so
        /// a property class used several times costs one copy of its ranges.
        pub fn addUClass(self: *Self, allocator: std.mem.Allocator, ranges: []const CodepointRange) Error!u32 {
            // Dedup: compare against every existing class of equal length.
            var k: usize = 0;
            while (k < self.uclass_count) : (k += 1) {
                const ex = self.uclassRanges(@intCast(k));
                if (ex.len != ranges.len) continue;
                var same = true;
                for (ex, ranges) |x, y| {
                    if (x.lo != y.lo or x.hi != y.hi) {
                        same = false;
                        break;
                    }
                }
                if (same) return @intCast(k);
            }
            const off = self.urange_count;
            const desc: UClass = .{ .off = @intCast(off), .len = @intCast(ranges.len), .ascii = uset.asciiBits(ranges) };
            if (cap != null) {
                if (self.uclass_count >= MAX_UCLASSES or off + ranges.len > URANGE_CAP) return Error.TooComplex;
                for (ranges, 0..) |r, i| self.uranges[off + i] = r;
                self.uclasses[self.uclass_count] = desc;
            } else {
                if (self.uclass_count >= MAX_UCLASSES_RUNTIME or off + ranges.len > MAX_URANGES_RUNTIME) return Error.TooComplex;
                self.uranges.appendSlice(allocator, ranges) catch return Error.TooComplex;
                self.uclasses.append(allocator, desc) catch return Error.TooComplex;
            }
            self.urange_count += ranges.len;
            const id: u32 = @intCast(self.uclass_count);
            self.uclass_count += 1;
            return id;
        }

        /// The member ranges of `.uclass` index `idx`.
        pub fn uclassRanges(self: *const Self, idx: u32) []const CodepointRange {
            const d = if (cap != null) self.uclasses[idx] else self.uclasses.items[idx];
            const pool: []const CodepointRange = if (cap != null) self.uranges[0..self.urange_count] else self.uranges.items;
            return pool[d.off .. d.off + d.len];
        }

        /// The descriptor of `.uclass` index `idx` (ranges window + ASCII map).
        pub fn uclassDesc(self: *const Self, idx: u32) *const UClass {
            return if (cap != null) &self.uclasses[idx] else &self.uclasses.items[idx];
        }

        /// `cp` ∈ `.uclass` `idx`: one bit test for ASCII, else a binary search.
        pub inline fn uclassContains(self: *const Self, idx: u32, cp: u21) bool {
            return uset.containsFast(self.uclassRanges(idx), &self.uclassDesc(idx).ascii, cp);
        }

        /// Copy the `.uclass` tables of `src` wholesale (a trimmed/baked copy of
        /// a comptime store; node refs and `set_idx` values stay valid). Pads
        /// the unused comptime pool so the value is fully defined.
        pub fn copyUClasses(self: *Self, src: anytype) void {
            comptime std.debug.assert(cap != null);
            self.urange_count = src.urange_count;
            self.uclass_count = src.uclass_count;
            // Bulk ops (one comptime step each) — a per-element loop over the
            // 8192-slot pool would blow the default eval branch quota.
            @memcpy(self.uranges[0..src.urange_count], src.uranges[0..src.urange_count]);
            @memset(self.uranges[src.urange_count..], .{ .lo = 0, .hi = 0 });
            @memcpy(self.uclasses[0..src.uclass_count], src.uclasses[0..src.uclass_count]);
            @memset(self.uclasses[src.uclass_count..], .{ .off = 0, .len = 0, .ascii = @splat(0) });
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

/// Deep-copy subtree `ref` from `src` into `dst`, re-interning set bitmaps so
/// `dst` is self-contained. Generic over BOTH stores' caps (`dcap`/`scap`): the
/// runtime callers use `null→null`; the comptime seek (`pattern.zig`) uses
/// `HIR_CAP→HIR_CAP` to derive a regular over-approximation entirely at compile
/// time. The comptime store ignores `a`, so passing `undefined` is fine there.
/// `relax_irregular` (comptime):
///   * `false` — faithful clone of every tag (the old `split_alt.cloneExact`
///     / `delegate.copyReg`).
///   * `true`  — the zero-width `look`/`look_around` collapse to `empty`, a
///     `backref` to `[\x00-\xFF]*`, and `atomic` drops its cut (keeping the
///     inner subtree): a sound *language-enlarging* relaxation (the old
///     `seek.lowerApprox`) used to derive a regular over-approximation. A
///     backref CONSUMES the referenced group's text, so `empty` would shrink
///     the language (`(b)\1d` would approximate to `bd` and the seek would
///     skip the real start of `bbd`); any-byte-string is the sound stand-in.
/// One definition replaces three near-identical recursive copies.
pub fn cloneSubtree(
    comptime dcap: ?usize,
    comptime scap: ?usize,
    dst: *Hir(dcap),
    a: std.mem.Allocator,
    src: *const Hir(scap),
    ref: NodeRef,
    comptime relax_irregular: bool,
) Error!NodeRef {
    const nd = src.node(ref);
    switch (nd.tag) {
        .look, .look_around, .backref => {
            if (relax_irregular) {
                if (nd.tag != .backref) return dst.addNode(a, .{ .tag = .empty });
                const any = try dst.addSet(a, @splat(0xFF));
                const byte = try dst.addNode(a, .{ .tag = .set, .set_idx = any });
                return dst.addNode(a, .{ .tag = .star, .a = byte, .greedy = true });
            }
            return switch (nd.tag) {
                // look / backref are leaves (set_idx = LookKind / group).
                .look, .backref => dst.addNode(a, .{ .tag = nd.tag, .set_idx = nd.set_idx, .fold = nd.fold, .ufold = nd.ufold }),
                // look_around carries a sub-expression.
                else => dst.addNode(a, .{
                    .tag = .look_around,
                    .a = try cloneSubtree(dcap, scap, dst, a, src, nd.a, relax_irregular),
                    .set_idx = nd.set_idx,
                }),
            };
        },
        .empty => return dst.addNode(a, .{ .tag = .empty }),
        .set => {
            const idx = try dst.addSet(a, src.setBitmap(nd.set_idx));
            return dst.addNode(a, .{ .tag = .set, .set_idx = idx });
        },
        .uclass => {
            const idx = try dst.addUClass(a, src.uclassRanges(nd.set_idx));
            return dst.addNode(a, .{ .tag = .uclass, .set_idx = idx });
        },
        .concat, .alt => {
            const la = try cloneSubtree(dcap, scap, dst, a, src, nd.a, relax_irregular);
            const lb = try cloneSubtree(dcap, scap, dst, a, src, nd.b, relax_irregular);
            return dst.addNode(a, .{ .tag = nd.tag, .a = la, .b = lb });
        },
        .star, .plus, .opt => {
            const la = try cloneSubtree(dcap, scap, dst, a, src, nd.a, relax_irregular);
            return dst.addNode(a, .{ .tag = nd.tag, .a = la, .greedy = nd.greedy });
        },
        .cap => {
            const la = try cloneSubtree(dcap, scap, dst, a, src, nd.a, relax_irregular);
            return dst.addNode(a, .{ .tag = .cap, .a = la, .set_idx = nd.set_idx });
        },
        .atomic => {
            // Relaxed over-approximation: drop the cut (`(?>R)` matches a
            // subset of `R`, so plain `R` is a sound language-enlarging
            // superset). Faithful clone: keep the atomic wrapper.
            const la = try cloneSubtree(dcap, scap, dst, a, src, nd.a, relax_irregular);
            if (relax_irregular) return la;
            return dst.addNode(a, .{ .tag = .atomic, .a = la });
        },
    }
}

test "hir comptime store basic shape" {
    const H = Hir(64);
    var h = H.initComptime();
    const s = try h.addSet(undefined, @splat(0));
    const leaf = try h.addNode(undefined, .{ .tag = .set, .set_idx = s });
    const star = try h.addNode(undefined, .{ .tag = .star, .a = leaf, .greedy = true });
    try std.testing.expectEqual(@as(usize, 2), h.node_count);
    try std.testing.expectEqual(Tag.star, h.node(star).tag);
    try std.testing.expectEqual(Tag.set, h.node(h.node(star).a).tag);
}
