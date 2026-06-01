//! THE planner linchpin: a plain-data summary of a pattern plus a pure,
//! comptime-evaluable `analyze` over the `Hir` IR. Absorbs the old
//! `optimizer.zig` (anchors, min/max length, necessary first-byte set) and
//! adds the literal `Seq`s the planner uses to pick a search strategy.
//!
//! Everything here is a *necessary condition* or an exact structural fact —
//! never a guess that could change which text matches. Pure: no allocator in
//! its shape, no haystack access, so `planner.plan(properties, flags)` is a
//! pure function the comptime path evaluates at compile time.

const std = @import("std");
const hir = @import("hir.zig");
const seq_extract = @import("exec/seq_extract.zig");

const NodeRef = hir.NodeRef;
pub const Seq = seq_extract.Seq;

pub const Properties = struct {
    /// Pattern is `^`/`\A`-anchored (prescan flag).
    anchored_start: bool = false,
    /// Pattern is `$`/`\z`/`\Z`-anchored (prescan flag).
    anchored_end: bool = false,
    /// Min / max match length in bytes (`max_len == null` => unbounded).
    min_len: usize = 0,
    max_len: ?usize = null,
    /// Necessary set of bytes a non-empty match may start with, or null when
    /// not computable / not selective. Ported from `optimizer.firstBytes`.
    first_byte_set: ?[32]u8 = null,
    /// Leading literal sequence (exact => whole pattern is the literal(s)).
    prefix: Seq = .{},
    /// Trailing literal sequence.
    suffix: Seq = .{},
    /// The whole pattern is exactly one fixed literal string.
    is_exact_literal: bool = false,
    /// A lazy quantifier was used (carried from the parser).
    saw_lazy: bool = false,
    /// Hir-representable patterns never need the AST backtracker (lookaround /
    /// backreferences route to `Error.Unsupported` in `parser`). Kept
    /// explicit so the planner can branch on it uniformly.
    requires_backtracking: bool = false,
    /// Captures are not modelled in `Hir` (the boundary engines are
    /// capture-free); the planner treats capture needs separately.
    needs_captures: bool = false,
    /// Pattern contains a zero-width look-assertion (`\b \B`, mid `^ $`,
    /// `(?m)` line anchors, mid `\A \z \Z`). Routes to the bounded
    /// backtracker (the DFA does not fold look-assertions yet).
    has_look: bool = false,
    /// Every match is unconditionally prefixed by a multiline `^` (`start_line`)
    /// look, so a match can only begin at a line start. Lets the `.bt_look`
    /// engine enumerate line starts (via a `\n` memchr) instead of every
    /// position — the difference between O(n) and O(n·lines) start attempts.
    leading_line_anchor: bool = false,
};

fn containsLook(comptime cap: ?usize, h: *const hir.Hir(cap), ref: NodeRef) bool {
    const nd = h.node(ref);
    return switch (nd.tag) {
        .look => true,
        .empty, .set, .backref, .look_around => false,
        .concat, .alt => containsLook(cap, h, nd.a) or containsLook(cap, h, nd.b),
        .star, .plus, .opt, .cap, .atomic => containsLook(cap, h, nd.a),
    };
}

/// The leftmost *meaningful* factor of `ref`: `concat`/`cap` are descended
/// (left first), zero-width `.empty` noise is skipped (an inline `(?m)` flag
/// group lowers to an `.empty` leaf, so `(?m)^…` is `concat(empty, ^…)`), and
/// anything else (look/set/star/alt/…) is returned as-is. `null` ⇒ the subtree
/// is purely empty.
fn firstFactor(comptime cap: ?usize, h: *const hir.Hir(cap), ref: NodeRef) ?NodeRef {
    const nd = h.node(ref);
    return switch (nd.tag) {
        .cap => firstFactor(cap, h, nd.a), // transparent
        .concat => firstFactor(cap, h, nd.a) orelse firstFactor(cap, h, nd.b),
        .empty => null, // zero-width; skip to the next factor
        else => ref,
    };
}

/// True iff every match must begin at a line start: the leftmost meaningful
/// factor of the HIR root is a `start_line` (`(?m)^`) look. Conservative — an
/// `.alt` root (e.g. `(?m)^a|b`, `(?m)(^a|b)`) returns the alt as the first
/// factor (not a look) ⇒ false, so a pattern with a non-line-anchored branch
/// never qualifies. (`spineFactors` can't be reused: a long pattern like
/// `(?m)^\d{4}-…` overflows its fixed buffer — but we only need factor 0.)
fn leadingLineAnchor(comptime cap: ?usize, h: *const hir.Hir(cap)) bool {
    if (h.root == hir.none) return false;
    const f = firstFactor(cap, h, h.root) orelse return false;
    const nd = h.node(f);
    return nd.tag == .look and nd.set_idx == @intFromEnum(hir.LookKind.start_line);
}

fn containsCap(comptime cap: ?usize, h: *const hir.Hir(cap), ref: NodeRef) bool {
    const nd = h.node(ref);
    return switch (nd.tag) {
        .cap => true,
        .empty, .set, .look, .backref, .look_around => false,
        .concat, .alt => containsCap(cap, h, nd.a) or containsCap(cap, h, nd.b),
        .star, .plus, .opt, .atomic => containsCap(cap, h, nd.a),
    };
}

fn containsBacktrack(comptime cap: ?usize, h: *const hir.Hir(cap), ref: NodeRef) bool {
    const nd = h.node(ref);
    return switch (nd.tag) {
        // `.atomic` (atomic group / possessive) changes the matched language
        // and the DFA cannot fold it → it must run on the tree backtracker.
        .backref, .look_around, .atomic => true,
        .empty, .set, .look => false,
        .concat, .alt => containsBacktrack(cap, h, nd.a) or containsBacktrack(cap, h, nd.b),
        .star, .plus, .opt, .cap => containsBacktrack(cap, h, nd.a),
    };
}

inline fn hasBit(set: *const [32]u8, c: u8) bool {
    return (set[c >> 3] & (@as(u8, 1) << @as(u3, @intCast(c & 7)))) != 0;
}

fn minLen(comptime cap: ?usize, h: *const hir.Hir(cap), ref: NodeRef) usize {
    const nd = h.node(ref);
    return switch (nd.tag) {
        .empty => 0,
        .set => 1,
        .concat => minLen(cap, h, nd.a) + minLen(cap, h, nd.b),
        .alt => @min(minLen(cap, h, nd.a), minLen(cap, h, nd.b)),
        .star, .opt => 0,
        .plus => minLen(cap, h, nd.a),
        .cap, .atomic => minLen(cap, h, nd.a),
        .look, .look_around => 0, // zero-width
        .backref => 0, // referenced group may be empty / absent
    };
}

fn maxLen(comptime cap: ?usize, h: *const hir.Hir(cap), ref: NodeRef) ?usize {
    const nd = h.node(ref);
    switch (nd.tag) {
        .empty => return 0,
        .set => return 1,
        .concat => {
            const l = maxLen(cap, h, nd.a) orelse return null;
            const r = maxLen(cap, h, nd.b) orelse return null;
            return l + r;
        },
        .alt => {
            const l = maxLen(cap, h, nd.a) orelse return null;
            const r = maxLen(cap, h, nd.b) orelse return null;
            return @max(l, r);
        },
        .star, .plus => return null,
        .opt => return maxLen(cap, h, nd.a),
        .cap, .atomic => return maxLen(cap, h, nd.a),
        .look, .look_around => return 0, // zero-width
        .backref => return null, // length depends on captured text
    }
}

const FirstResult = struct { ok: bool, nullable: bool };

/// OR into `set` the bytes a match of `ref` may begin with (necessary
/// condition). Ported from `optimizer.firstBytes` onto `Hir` tags.
fn firstBytes(comptime cap: ?usize, h: *const hir.Hir(cap), ref: NodeRef, set: *[32]u8) FirstResult {
    const nd = h.node(ref);
    switch (nd.tag) {
        .empty => return .{ .ok = true, .nullable = true },
        .set => {
            const bm = h.setBitmap(nd.set_idx);
            for (set, 0..) |*b, i| b.* |= bm[i];
            return .{ .ok = true, .nullable = false };
        },
        .concat => {
            const l = firstBytes(cap, h, nd.a, set);
            if (!l.ok) return .{ .ok = false, .nullable = false };
            if (!l.nullable) return .{ .ok = true, .nullable = false };
            const r = firstBytes(cap, h, nd.b, set);
            if (!r.ok) return .{ .ok = false, .nullable = false };
            return .{ .ok = true, .nullable = r.nullable };
        },
        .alt => {
            const l = firstBytes(cap, h, nd.a, set);
            if (!l.ok) return .{ .ok = false, .nullable = false };
            const r = firstBytes(cap, h, nd.b, set);
            if (!r.ok) return .{ .ok = false, .nullable = false };
            return .{ .ok = true, .nullable = l.nullable or r.nullable };
        },
        .star, .opt => {
            const c = firstBytes(cap, h, nd.a, set);
            return .{ .ok = c.ok, .nullable = true };
        },
        .plus => {
            const c = firstBytes(cap, h, nd.a, set);
            return .{ .ok = c.ok, .nullable = c.nullable };
        },
        .cap, .atomic => return firstBytes(cap, h, nd.a, set),
        .look, .look_around => return .{ .ok = true, .nullable = true }, // zero-width
        .backref => return .{ .ok = false, .nullable = false }, // backtrack-only
    }
}

/// Pure analysis of `h`. Comptime-evaluable; never reads a haystack.
pub fn analyze(comptime cap: ?usize, h: *const hir.Hir(cap)) Properties {
    @setEvalBranchQuota(1_000_000);
    var p = Properties{};
    p.anchored_start = h.anchored_start;
    p.anchored_end = h.anchored_end;
    p.saw_lazy = h.saw_lazy;
    p.min_len = minLen(cap, h, h.root);
    p.max_len = maxLen(cap, h, h.root);

    if (p.min_len >= 1) {
        var set = std.mem.zeroes([32]u8);
        const r = firstBytes(cap, h, h.root, &set);
        if (r.ok and !r.nullable) {
            var bits: usize = 0;
            for (set) |b| bits += @popCount(b);
            if (bits > 0 and bits < 256) p.first_byte_set = set;
        }
    }

    // `saw_lazy && anchored_end` (`a*?$`) is regular but the DFA accept-cut
    // can't model lazy-against-`$`, so route it to the tree backtracker too.
    // NOTE: `has_look` is deliberately NOT folded in here — the runtime keeps it
    // a separate flag so a look pattern routes to its `.bt_look` engine (NFA +
    // visited-bitset, with the line-anchor `\n`-memchr fast path), not the HIR
    // `.backtrack` tree-walker. The comptime `Pattern` (which has no `.bt_look`)
    // treats `has_look` as backtracking in `pattern.zig buildAll` instead, so
    // the change stays comptime-only and the runtime routing is untouched.
    p.requires_backtracking = containsBacktrack(cap, h, h.root) or
        (p.saw_lazy and p.anchored_end);
    p.needs_captures = containsCap(cap, h, h.root);
    p.has_look = containsLook(cap, h, h.root);
    if (p.has_look) {
        // Look-bearing patterns route to the bounded backtracker; the
        // literal/prefilter strategies (and their Seqs) don't apply.
        p.leading_line_anchor = leadingLineAnchor(cap, h);
        p.first_byte_set = null;
        return p;
    }

    p.prefix = seq_extract.prefix(cap, h);
    p.suffix = seq_extract.suffix(cap, h);
    p.is_exact_literal = p.prefix.n == 1 and p.prefix.exact and
        !p.anchored_start and !p.anchored_end;

    return p;
}

// --- Tests: port of optimizer.zig's coverage onto the Hir pipeline ----------

const parser = @import("parser.zig");

fn analyzePattern(comptime src: []const u8) Properties {
    const H = hir.Hir(256);
    var h = H.initComptime();
    parser.parse(256, &h, undefined, src, .{}) catch unreachable;
    return analyze(256, &h);
}

test "properties: literal prefix extraction (hello.*world)" {
    const p = comptime analyzePattern("hello.*world");
    try std.testing.expectEqualStrings("hello", p.prefix.alt(0));
    try std.testing.expect(!p.prefix.exact);
}

test "properties: anchored detection (^hello$)" {
    const p = comptime analyzePattern("^hello$");
    try std.testing.expect(p.anchored_start);
    try std.testing.expect(p.anchored_end);
}

test "properties: min/max length" {
    const p1 = comptime analyzePattern("hello");
    try std.testing.expectEqual(@as(usize, 5), p1.min_len);
    try std.testing.expectEqual(@as(?usize, 5), p1.max_len);
    try std.testing.expect(p1.is_exact_literal);

    const p2 = comptime analyzePattern("a+");
    try std.testing.expectEqual(@as(usize, 1), p2.min_len);
    try std.testing.expectEqual(@as(?usize, null), p2.max_len);
    try std.testing.expect(!p2.is_exact_literal);
}

fn analyzePatternRt(src: []const u8) Properties {
    const a = std.testing.allocator;
    var h = hir.Hir(null).initRuntime();
    defer h.deinit(a);
    parser.parse(null, &h, a, src, .{}) catch unreachable;
    return analyze(null, &h);
}

test "properties: leading_line_anchor recognizer" {
    // Fully line-anchored: every match must begin at a line start.
    try std.testing.expect(analyzePatternRt("(?m)^[0-9]{4}-[0-9]{2}-[0-9]{2}.*$").leading_line_anchor);
    try std.testing.expect(analyzePatternRt("(?m)^foo").leading_line_anchor);
    try std.testing.expect(analyzePatternRt("(?m)^(a|b)").leading_line_anchor); // anchor is the prefix of the whole pattern
    // NOT fully anchored — the recogniser must reject these.
    try std.testing.expect(!analyzePatternRt("(?m)^a|b").leading_line_anchor); // alt root; `b` matches anywhere
    try std.testing.expect(!analyzePatternRt("(?m)(^a|b)").leading_line_anchor); // alt under a group
    try std.testing.expect(!analyzePatternRt("(?m)foo$").leading_line_anchor); // trailing `$` only
    try std.testing.expect(!analyzePatternRt("^abc").leading_line_anchor); // start_text, not start_line
}

test "properties: first_byte_set for alternation of literals" {
    const p = comptime analyzePattern("cat|dog|bird|fish");
    try std.testing.expect(p.first_byte_set != null);
    const s = p.first_byte_set.?;
    try std.testing.expect(hasBit(&s, 'c'));
    try std.testing.expect(hasBit(&s, 'd'));
    try std.testing.expect(hasBit(&s, 'b'));
    try std.testing.expect(hasBit(&s, 'f'));
    try std.testing.expect(!hasBit(&s, 'z'));
}
