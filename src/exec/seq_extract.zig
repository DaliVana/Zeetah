//! Pure literal-sequence (`Seq`) extraction over the `Hir` IR.
//!
//! A `Seq` is a small set of literal alternatives that a match's prefix /
//! suffix / a required inner span must equal. It is a *necessary condition*
//! used to pick a prefilter or a reverse strategy — the engine always
//! re-verifies, so an over-approximation is safe (never a wrong match).
//!
//! `Hir` is post-lowering: `{m,n}` is already expanded and a literal byte is
//! a `.set` node whose bitmap has exactly one bit. This module reads it
//! without allocating and is fully comptime-evaluable.

const std = @import("std");
const hir = @import("../hir.zig");
const pf = @import("../prefilter.zig");

const NodeRef = hir.NodeRef;

pub const MAX_ALTS: usize = 8;
pub const MAX_LIT: usize = 64;

/// Up to `MAX_ALTS` literal alternatives, each up to `MAX_LIT` bytes.
pub const Seq = struct {
    lits: [MAX_ALTS][MAX_LIT]u8 = [_][MAX_LIT]u8{[_]u8{0} ** MAX_LIT} ** MAX_ALTS,
    lens: [MAX_ALTS]u8 = [_]u8{0} ** MAX_ALTS,
    /// Number of populated alternatives. `0` => no sequence.
    n: u8 = 0,
    /// True when matching one of these alternatives is *sufficient* (the Seq
    /// is the whole thing it describes — e.g. the entire pattern is the
    /// literal). False => it is only a leading/trailing necessary prefix.
    exact: bool = false,

    pub fn isEmpty(s: *const Seq) bool {
        return s.n == 0;
    }

    /// The shortest alternative length — a crude selectivity proxy (longer is
    /// rarer hence better). `0` when empty.
    pub fn minLen(s: *const Seq) usize {
        if (s.n == 0) return 0;
        var m: usize = std.math.maxInt(usize);
        for (0..s.n) |i| m = @min(m, s.lens[i]);
        return m;
    }

    pub fn alt(s: *const Seq, i: usize) []const u8 {
        return s.lits[i][0..s.lens[i]];
    }
};

inline fn hasBit(set: *const [32]u8, c: u8) bool {
    return (set[c >> 3] & (@as(u8, 1) << @as(u3, @intCast(c & 7)))) != 0;
}

/// If `set_idx`'s bitmap has exactly one member, return that byte.
fn singleByte(comptime cap: ?usize, h: *const hir.Hir(cap), set_idx: u32) ?u8 {
    const bm = h.setBitmap(set_idx);
    var found: ?u8 = null;
    var c: usize = 0;
    while (c < 256) : (c += 1) {
        if (hasBit(&bm, @intCast(c))) {
            if (found != null) return null; // >1 member
            found = @intCast(c);
        }
    }
    return found;
}

/// Append the *complete* literal string of `ref` to `buf` if and only if the
/// entire subtree is a fixed single-byte-set concat chain (no alternation,
/// quantifier, multi-byte class). Returns the new length, or null if not a
/// pure literal (or it would overflow `MAX_LIT`).
fn wholeLiteral(comptime cap: ?usize, h: *const hir.Hir(cap), ref: NodeRef, buf: *[MAX_LIT]u8, len: usize) ?usize {
    const nd = h.node(ref);
    switch (nd.tag) {
        .empty => return len,
        .set => {
            const b = singleByte(cap, h, nd.set_idx) orelse return null;
            if (len >= MAX_LIT) return null;
            buf[len] = b;
            return len + 1;
        },
        .concat => {
            const l = wholeLiteral(cap, h, nd.a, buf, len) orelse return null;
            return wholeLiteral(cap, h, nd.b, buf, l);
        },
        .cap, .atomic => return wholeLiteral(cap, h, nd.a, buf, len), // transparent
        .alt, .star, .plus, .opt, .look, .backref, .look_around => return null,
    }
}

/// Leading run of literal bytes (a *necessary* prefix). Stops at the first
/// non-literal element; `exact` reports whether the whole pattern was that
/// literal.
fn leadingRun(comptime cap: ?usize, h: *const hir.Hir(cap), ref: NodeRef, buf: *[MAX_LIT]u8, len: usize, exact: *bool) usize {
    const nd = h.node(ref);
    switch (nd.tag) {
        .empty => return len,
        .set => {
            const b = singleByte(cap, h, nd.set_idx) orelse {
                exact.* = false;
                return len;
            };
            if (len >= MAX_LIT) {
                exact.* = false;
                return len;
            }
            buf[len] = b;
            return len + 1;
        },
        .concat => {
            // Walk left chain first; only continue right if the left was a
            // *complete* literal (otherwise the run ends inside the left).
            var lit_only = true;
            const before = len;
            const l = leadingRun(cap, h, nd.a, buf, len, &lit_only);
            if (!lit_only or l == before) {
                exact.* = false;
                return l;
            }
            return leadingRun(cap, h, nd.b, buf, l, exact);
        },
        .cap, .atomic => return leadingRun(cap, h, nd.a, buf, len, exact), // transparent
        .alt, .star, .plus, .opt, .look, .backref, .look_around => {
            exact.* = false;
            return len;
        },
    }
}

fn trailingRun(comptime cap: ?usize, h: *const hir.Hir(cap), ref: NodeRef, buf: *[MAX_LIT]u8, len: usize, exact: *bool) usize {
    const nd = h.node(ref);
    switch (nd.tag) {
        .empty => return len,
        .set => {
            const b = singleByte(cap, h, nd.set_idx) orelse {
                exact.* = false;
                return len;
            };
            if (len >= MAX_LIT) {
                exact.* = false;
                return len;
            }
            buf[MAX_LIT - 1 - len] = b; // fill from the right
            return len + 1;
        },
        .concat => {
            var lit_only = true;
            const before = len;
            const r = trailingRun(cap, h, nd.b, buf, len, &lit_only);
            if (!lit_only or r == before) {
                exact.* = false;
                return r;
            }
            return trailingRun(cap, h, nd.a, buf, r, exact);
        },
        .cap, .atomic => return trailingRun(cap, h, nd.a, buf, len, exact), // transparent
        .alt, .star, .plus, .opt, .look, .backref, .look_around => {
            exact.* = false;
            return len;
        },
    }
}

/// Flatten a (possibly nested left-leaning) `alt` tree into branch refs.
fn collectAlts(comptime cap: ?usize, h: *const hir.Hir(cap), ref: NodeRef, out: *[MAX_ALTS]NodeRef, n: *usize) bool {
    const nd = h.node(ref);
    if (nd.tag == .alt) {
        if (!collectAlts(cap, h, nd.a, out, n)) return false;
        return collectAlts(cap, h, nd.b, out, n);
    }
    if (n.* >= MAX_ALTS) return false;
    out[n.*] = ref;
    n.* += 1;
    return true;
}

/// Prefix `Seq`: an alternation whose every branch is a whole literal yields
/// an *exact* multi-literal Seq (e.g. `cat|dog|bird`); otherwise the single
/// leading literal run (exact iff it is the whole pattern).
pub fn prefix(comptime cap: ?usize, h: *const hir.Hir(cap)) Seq {
    @setEvalBranchQuota(1_000_000);
    var s = Seq{};
    const root = h.node(h.root);

    if (root.tag == .alt) {
        var refs: [MAX_ALTS]NodeRef = undefined;
        var nn: usize = 0;
        if (collectAlts(cap, h, h.root, &refs, &nn)) {
            var ok = true;
            for (0..nn) |i| {
                var buf: [MAX_LIT]u8 = undefined;
                const ln = wholeLiteral(cap, h, refs[i], &buf, 0);
                if (ln == null or ln.? == 0) {
                    ok = false;
                    break;
                }
                s.lits[i] = buf;
                s.lens[i] = @intCast(ln.?);
            }
            if (ok) {
                s.n = @intCast(nn);
                s.exact = true;
                return s;
            }
            s = Seq{};
        }
    }

    var buf: [MAX_LIT]u8 = undefined;
    var exact = true;
    const ln = leadingRun(cap, h, h.root, &buf, 0, &exact);
    if (ln == 0) return Seq{};
    s.lits[0] = buf;
    s.lens[0] = @intCast(ln);
    s.n = 1;
    s.exact = exact;
    return s;
}

/// Trailing literal run (a necessary suffix; exact iff whole pattern).
pub fn suffix(comptime cap: ?usize, h: *const hir.Hir(cap)) Seq {
    @setEvalBranchQuota(1_000_000);
    var s = Seq{};
    var buf: [MAX_LIT]u8 = undefined;
    var exact = true;
    const ln = trailingRun(cap, h, h.root, &buf, 0, &exact);
    if (ln == 0) return Seq{};
    // trailingRun filled from the right edge; left-align it.
    var out: [MAX_LIT]u8 = [_]u8{0} ** MAX_LIT;
    for (0..ln) |i| out[i] = buf[MAX_LIT - ln + i];
    s.lits[0] = out;
    s.lens[0] = @intCast(ln);
    s.n = 1;
    s.exact = exact;
    return s;
}

/// Walk only through nodes every accepting path must traverse (`.concat`
/// children, and a `.plus` body which runs ≥1 time), collecting mandatory
/// single-byte `.set` leaves; keep the statistically rarest (best prefilter
/// selectivity). `.star/.opt/.alt` subtrees are optional/alternative so their
/// bytes are *not* guaranteed and are skipped — keeping the result a sound
/// necessary condition.
fn scanRequired(comptime cap: ?usize, h: *const hir.Hir(cap), ref: NodeRef, best: *?u8, bestf: *u16) void {
    const nd = h.node(ref);
    switch (nd.tag) {
        .set => {
            if (singleByte(cap, h, nd.set_idx)) |b| {
                if (best.* == null or pf.FREQ[b] < bestf.*) {
                    best.* = b;
                    bestf.* = pf.FREQ[b];
                }
            }
        },
        .concat => {
            scanRequired(cap, h, nd.a, best, bestf);
            scanRequired(cap, h, nd.b, best, bestf);
        },
        .plus => scanRequired(cap, h, nd.a, best, bestf),
        .cap, .atomic => scanRequired(cap, h, nd.a, best, bestf), // transparent
        .star, .opt, .alt, .empty, .look, .backref, .look_around => {},
    }
}

/// A rare mandatory byte `R` plus a recipe to recover the match *start* from
/// `R`'s position, so the search can `memchr` to candidate regions instead
/// of restarting the DFA at every position (the broad-first-byte O(n²) case
/// — e.g. `…@…`, `…://…`, `\d{3}-\d{2}-\d{4}`). Necessary condition only;
/// the engine always re-verifies, so this never changes an outcome.
pub const ReqLit = struct {
    byte: u8,
    back: union(enum) {
        /// Match start is exactly `R_pos - k` (fixed-width mandatory prefix).
        fixed: usize,
        /// Match start = walk back from `R` over bytes in this set (the
        /// pattern opens with a single `set`+/`set`* run, `R ∉ set`).
        class: [32]u8,
    },
};

const MAXI = 64;
const SpItem = struct {
    kind: enum { lit1, cls1, run, stop },
    byte: u8 = 0,
    set: [32]u8 = [_]u8{0} ** 32,
};

fn flatten(comptime cap: ?usize, h: *const hir.Hir(cap), ref: NodeRef, out: *[MAXI]SpItem, n: *usize) void {
    if (n.* >= MAXI) return;
    const nd = h.node(ref);
    switch (nd.tag) {
        .concat => {
            flatten(cap, h, nd.a, out, n);
            flatten(cap, h, nd.b, out, n);
        },
        .cap => flatten(cap, h, nd.a, out, n),
        .set => {
            if (singleByte(cap, h, nd.set_idx)) |b| {
                out[n.*] = .{ .kind = .lit1, .byte = b };
            } else {
                out[n.*] = .{ .kind = .cls1, .set = h.setBitmap(nd.set_idx) };
            }
            n.* += 1;
        },
        .plus, .star => {
            const c = h.node(nd.a);
            if (c.tag == .set) {
                out[n.*] = .{ .kind = .run, .set = h.setBitmap(c.set_idx) };
            } else out[n.*] = .{ .kind = .stop };
            n.* += 1;
        },
        else => {
            out[n.*] = .{ .kind = .stop };
            n.* += 1;
        },
    }
}

/// Pick the rarest mandatory single byte whose match-start is recoverable
/// (fixed-width prefix, or a leading single `set`-run), or null. Sound for
/// *leftmost* search: `R` cannot occur inside its own preceding prefix, so
/// `R`-occurrence order equals match-start order.
pub fn requiredLiteralBack(comptime cap: ?usize, h: *const hir.Hir(cap)) ?ReqLit {
    @setEvalBranchQuota(1_000_000);
    var items: [MAXI]SpItem = undefined;
    var n: usize = 0;
    flatten(cap, h, h.root, &items, &n);

    var best: ?ReqLit = null;
    var bestf: u16 = std.math.maxInt(u16);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (items[i].kind != .lit1) continue;
        const r = items[i].byte;
        if (pf.FREQ[r] >= bestf) continue;

        // fixed: every item before `i` is a fixed-width-1 element that
        // cannot itself match `r` (so `R`-order == start-order).
        var all_fixed = true;
        var j: usize = 0;
        while (j < i) : (j += 1) {
            const it = items[j];
            if (it.kind == .lit1 and it.byte != r) continue;
            if (it.kind == .cls1 and !hasBit(&it.set, r)) continue;
            all_fixed = false;
            break;
        }
        if (all_fixed) {
            best = .{ .byte = r, .back = .{ .fixed = i } };
            bestf = pf.FREQ[r];
            continue;
        }
        // class: pattern opens with one `set`-run immediately before `r`.
        if (i == 1 and items[0].kind == .run and !hasBit(&items[0].set, r)) {
            best = .{ .byte = r, .back = .{ .class = items[0].set } };
            bestf = pf.FREQ[r];
        }
    }
    return best;
}

/// If the pattern's leading mandatory element is a **positive single-byte
/// lookbehind** `(?<=X)`, return `X`: every match is then immediately
/// preceded by `X`, so the match start is exactly `X_pos + 1`. A sound
/// *necessary* condition (the real candidate starts are a subset), so a
/// prefilter using it can never drop a match — it just turns a
/// near-everywhere candidate scan (`lookbehind_amount` over-approx =
/// `[0-9]+…`) into a `memchr` for a rare byte. Only the leading spine is
/// walked (`concat` left, `cap` through); negative / multi-byte /
/// non-leading look-behinds and all look-aheads return `null`.
fn leadingLookbehind(comptime cap: ?usize, h: *const hir.Hir(cap), ref: NodeRef) ?u8 {
    const nd = h.node(ref);
    return switch (nd.tag) {
        .concat => leadingLookbehind(cap, h, nd.a), // leftmost on the spine
        .cap => leadingLookbehind(cap, h, nd.a), // capture is transparent
        .look_around => blk: {
            if (nd.set_idx & hir.LA_BEHIND == 0) break :blk null; // look-ahead
            if (nd.set_idx & hir.LA_NEGATIVE != 0) break :blk null; // negative
            const sub = h.node(nd.a);
            if (sub.tag != .set) break :blk null; // not a single fixed byte
            break :blk singleByte(cap, h, sub.set_idx);
        },
        else => null,
    };
}

pub fn requiredLeadingLookbehindByte(comptime cap: ?usize, h: *const hir.Hir(cap)) ?u8 {
    if (h.root == hir.none) return null;
    return leadingLookbehind(cap, h, h.root);
}

// --- `\b(lit|lit|…)\b` recogniser -------------------------------------------
//
// A word-boundary-bracketed pure literal alternation (`\b(?:break|case|…)\b`).
// It is *regular* but a naive Thompson NFA of N keywords is ~12·N states, so a
// large keyword list (e.g. 40) blows `MAX_NFA` ⇒ a typed `PatternTooComplex`
// even though the language is trivial. This recogniser pulls the literal set
// out of the HIR so the engine can run it as Aho-Corasick locate + an O(1)
// word-boundary verify at each candidate span edge — no NFA, no backtracker,
// no `bt_look` `visited` array. See memory
// `deep-alternation-reject-is-architectural`.

pub const MAX_BL: usize = 128;

pub const BoundaryLits = struct {
    lits: [MAX_BL][MAX_LIT]u8 = [_][MAX_LIT]u8{[_]u8{0} ** MAX_LIT} ** MAX_BL,
    lens: [MAX_BL]u8 = [_]u8{0} ** MAX_BL,
    n: u16 = 0,
    /// Longest alternative — the window width the search must brute-scan
    /// around an Aho-Corasick hit to stay leftmost-correct.
    maxlen: u8 = 0,

    pub fn alt(s: *const BoundaryLits, i: usize) []const u8 {
        return s.lits[i][0..s.lens[i]];
    }
};

/// Flatten the concat/cap spine into ordered factor refs (≤ `cap_n`, else
/// fail). `.cap` is transparent (a capturing group is rejected later via
/// `n_groups`, but a non-capturing `(?:…)` produces no `.cap` node at all).
fn spineFactors(comptime cap: ?usize, h: *const hir.Hir(cap), ref: NodeRef, out: []NodeRef, n: *usize) bool {
    const nd = h.node(ref);
    switch (nd.tag) {
        .concat => {
            if (!spineFactors(cap, h, nd.a, out, n)) return false;
            return spineFactors(cap, h, nd.b, out, n);
        },
        .cap => return spineFactors(cap, h, nd.a, out, n),
        else => {
            if (n.* >= out.len) return false;
            out[n.*] = ref;
            n.* += 1;
            return true;
        },
    }
}

/// Collect every branch of a (possibly nested) `alt` as a whole literal.
/// Returns false on any non-literal branch, an empty branch, or > `MAX_BL`.
fn collectLitAlts(comptime cap: ?usize, h: *const hir.Hir(cap), ref: NodeRef, bl: *BoundaryLits) bool {
    const nd = h.node(ref);
    if (nd.tag == .alt) {
        return collectLitAlts(cap, h, nd.a, bl) and collectLitAlts(cap, h, nd.b, bl);
    }
    if (nd.tag == .cap) return collectLitAlts(cap, h, nd.a, bl); // transparent
    if (bl.n >= MAX_BL) return false;
    var buf: [MAX_LIT]u8 = undefined;
    const ln = wholeLiteral(cap, h, ref, &buf, 0) orelse return false;
    if (ln == 0) return false;
    bl.lits[bl.n] = buf;
    bl.lens[bl.n] = @intCast(ln);
    bl.n += 1;
    return true;
}

/// If the whole pattern is exactly `\b <pure-literal-alternation> \b`, return
/// its literal set (source order preserved for leftmost-first tie-break).
/// Tight by design: any other shape returns `null` and the caller falls
/// through to the existing path unchanged (so this can never regress).
pub fn boundaryLiterals(comptime cap: ?usize, h: *const hir.Hir(cap)) ?BoundaryLits {
    @setEvalBranchQuota(1_000_000);
    if (h.root == hir.none) return null;
    var fac: [4]NodeRef = undefined;
    var nf: usize = 0;
    if (!spineFactors(cap, h, h.root, &fac, &nf)) return null;
    if (nf != 3) return null;
    const wb: u32 = @intFromEnum(hir.LookKind.word_boundary);
    const f0 = h.node(fac[0]);
    const f2 = h.node(fac[2]);
    if (f0.tag != .look or f0.set_idx != wb) return null;
    if (f2.tag != .look or f2.set_idx != wb) return null;
    var bl = BoundaryLits{};
    if (!collectLitAlts(cap, h, fac[1], &bl)) return null;
    if (bl.n == 0) return null;
    var mx: u8 = 0;
    for (0..bl.n) |i| mx = @max(mx, bl.lens[i]);
    bl.maxlen = mx;
    return bl;
}

/// A byte that *every* match must contain (rarest mandatory single-byte set
/// on the root spine), or null. Necessary condition only — used purely as a
/// `memchr` short-circuit, so it never changes a match outcome, only avoids
/// the unanchored DFA-restart O(n²) when the byte is absent.
pub fn requiredByte(comptime cap: ?usize, h: *const hir.Hir(cap)) ?u8 {
    @setEvalBranchQuota(1_000_000);
    var best: ?u8 = null;
    var bestf: u16 = std.math.maxInt(u16);
    scanRequired(cap, h, h.root, &best, &bestf);
    return best;
}

test "seq_extract: requiredByte picks rarest mandatory spine literal" {
    const parser = @import("../parser.zig");
    const H = hir.Hir(256);
    inline for (.{
        .{ "a.*a.*a.*a.*a.*a.*a.*X", @as(?u8, 'X') },
        .{ ".*.*.*.*.*=.*", @as(?u8, '=') },
        .{ "(a|ab)*c", @as(?u8, 'c') },
        .{ "abc", @as(?u8, 'b') }, // rarest of a,b,c by FREQ (b=15 < c=28 < a=82)
        .{ "a*", @as(?u8, null) }, // nothing mandatory
        .{ "(a|b)+", @as(?u8, null) }, // alt body → not guaranteed
    }) |case| {
        var h = H.initComptime();
        try parser.parse(256, &h, undefined, case[0], .{});
        try std.testing.expectEqual(case[1], requiredByte(256, &h));
    }
}

test "seq_extract: whole-literal prefix is exact" {
    const parser = @import("../parser.zig");
    const H = hir.Hir(128);
    var h = H.initComptime();
    try parser.parse(128, &h, undefined, "hello", .{});
    const p = prefix(128, &h);
    try std.testing.expectEqual(@as(u8, 1), p.n);
    try std.testing.expect(p.exact);
    try std.testing.expectEqualStrings("hello", p.alt(0));
}

test "seq_extract: leading literal of hello.*world is inexact 'hello'" {
    const parser = @import("../parser.zig");
    const H = hir.Hir(128);
    var h = H.initComptime();
    try parser.parse(128, &h, undefined, "hello.*world", .{});
    const p = prefix(128, &h);
    try std.testing.expectEqualStrings("hello", p.alt(0));
    try std.testing.expect(!p.exact);
    const sfx = suffix(128, &h);
    try std.testing.expectEqualStrings("world", sfx.alt(0));
}

test "seq_extract: \\b(lit|lit|lit)\\b recognised; other shapes rejected" {
    // `\b` is comptime-rejected by the parser (look-assertions are
    // runtime-only), so this recogniser is exercised on the runtime HIR.
    const parser = @import("../parser.zig");
    const a = std.testing.allocator;
    {
        var h = hir.Hir(null).initRuntime();
        defer h.deinit(a);
        try parser.parse(null, &h, a, "\\b(?:break|case|continue)\\b", .{});
        const bl = boundaryLiterals(null, &h).?;
        try std.testing.expectEqual(@as(u16, 3), bl.n);
        try std.testing.expectEqualStrings("break", bl.alt(0));
        try std.testing.expectEqualStrings("case", bl.alt(1));
        try std.testing.expectEqualStrings("continue", bl.alt(2));
        try std.testing.expectEqual(@as(u8, 8), bl.maxlen);
    }
    // Not bracketed by \b on both sides, or extra factor → not recognised.
    inline for (.{ "\\b(?:a|b)", "(?:a|b)\\b", "\\b(?:a|b)c\\b", "\\b(?:a|b+)\\b", "\\B(?:a|b)\\B" }) |p| {
        var h = hir.Hir(null).initRuntime();
        defer h.deinit(a);
        try parser.parse(null, &h, a, p, .{});
        try std.testing.expect(boundaryLiterals(null, &h) == null);
    }
}

test "seq_extract: alternation of literals -> exact multi Seq" {
    const parser = @import("../parser.zig");
    const H = hir.Hir(128);
    var h = H.initComptime();
    try parser.parse(128, &h, undefined, "cat|dog|bird", .{});
    const p = prefix(128, &h);
    try std.testing.expectEqual(@as(u8, 3), p.n);
    try std.testing.expect(p.exact);
    try std.testing.expectEqualStrings("cat", p.alt(0));
    try std.testing.expectEqualStrings("dog", p.alt(1));
    try std.testing.expectEqualStrings("bird", p.alt(2));
}
