//! Differential fuzz over every engine tier: random patterns × random inputs,
//! each checked against an independently implemented reference.
//!
//!   * Regular patterns — `bounded_bt` (priority-ordered DFS with a
//!     `(state,pos)` memo) is the reference for `pikevm` (breadth-first thread
//!     simulation), `lazy_dfa` (subset construction; look mode when the NFA has
//!     looks), the tree backtracker (the non-regular test's reference, pinned
//!     here on the regular subset) and `Regex` through its real engine routing.
//!   * Non-regular patterns (lookaround, backreferences, atomic / possessive) —
//!     the plain tree backtracker over the parsed HIR (no seek prefilter, no
//!     delegation, no peels) is the reference for `Regex`'s `backtrack`,
//!     `split_alt`, `dup_word` and `dfa_edge_look` engines.
//!   * Pure-literal alternations — a naive "earliest-listed literal at the
//!     leftmost position" scan is the reference for `LiteralAltScanner` and
//!     `Regex` (dictionaries too big for the NFA route to `literal_alt`).
//!
//! All must agree on leftmost-first spans at every checked start offset, on
//! non-overlapping iteration / `count` / `isMatch`, and on every capture slot.
//!
//! Coverage guard: each test tallies the `Regex` engine kind its patterns route
//! to and fails if a kind it owns drops below a floor, so a routing or
//! generator change cannot silently stop exercising an engine. Between them
//! the three tests own all fourteen kinds.
//!
//! Inputs are mostly short (every start offset checked), plus one medium
//! (≤ 200 B) per pattern and an occasional long one (1–4 KiB): token streams
//! with duplicated words and stray non-ASCII bytes, long enough for the SIMD /
//! prefilter chunk loops to run their main bodies. Deterministic seeds; sizes
//! kept small for the Debug suite.
//!
//! The generator (`Rng`, `generate`) is comptime-evaluable: the opt-in
//! comptime-vs-runtime fuzz (`tests/fuzz_comptime.zig`, `-Dfuzz-comptime`)
//! builds its pattern corpus with it.

const std = @import("std");
const hir = @import("../hir.zig");
const parser = @import("../parser.zig");
const properties = @import("../properties.zig");
const thompson = @import("../thompson.zig");
const prefilter = @import("../prefilter.zig");
const bounded_bt = @import("bounded_bt.zig");
const backtrack = @import("backtrack.zig");
const pikevm = @import("pikevm.zig");
const lazy_dfa = @import("lazy_dfa.zig");
const EdgeIndex = @import("nfa_index.zig").EdgeIndex;
const Regex = @import("../regex.zig").Regex;
const advanceEmpty = @import("../match.zig").advanceEmpty;

// ============================================================================
// Pattern + input generator (comptime-evaluable: no allocator, no
// `std.Random` interface).
// ============================================================================

/// splitmix64 — tiny, deterministic, and it runs at comptime.
pub const Rng = struct {
    s: u64,

    pub fn next(r: *Rng) u64 {
        r.s +%= 0x9E37_79B9_7F4A_7C15;
        var z = r.s;
        z = (z ^ (z >> 30)) *% 0xBF58_476D_1CE4_E5B9;
        z = (z ^ (z >> 27)) *% 0x94D0_49BB_1331_11EB;
        return z ^ (z >> 31);
    }

    /// Uniform-ish in `[0, n)` (the modulo bias is irrelevant here).
    pub fn below(r: *Rng, n: usize) usize {
        return @intCast(r.next() % n);
    }

    pub fn oneIn(r: *Rng, n: usize) bool {
        return r.below(n) == 0;
    }

    pub fn pick(r: *Rng, xs: []const []const u8) []const u8 {
        return xs[r.below(xs.len)];
    }
};

/// Top-level pattern shapes. `random` is the general tree; the others are
/// templates for the narrow engines a random tree almost never routes to.
pub const Shape = enum {
    /// Random regular tree (atoms, looks, alternation, groups, repetition).
    random,
    /// `w|w|…` — small pure-literal alternation (Teddy / DFA).
    literal_alt,
    /// `\b(?:w|w|…)\b` — `boundary_lits`.
    boundary_lits,
    /// 3+ byte literal, then a look-free random tail — `lit_prefix`.
    lit_prefix,
    /// Look-free random head, then a 3+ byte literal — `reverse_suffix`.
    reverse_suffix,
    /// `class+` / `class*` — `class_span`.
    class_span,
    /// Look-free random tree, then `$` — the unanchored end-anchored class
    /// the anti-ReDoS reroute sends to `dense_search`.
    end_anchored,
    /// Random tree with lookaround / backreferences / atomic / possessive.
    nonregular,
    /// `(\bC+\b)S\1` — `dup_word`.
    dup_word,
    /// Greedy alternation-free core + trailing width-1 lookaround — `dfa_edge_look`.
    edge_look,
    /// Capture-free top-level alternation mixing regular and lookaround
    /// branches — `split_alt`.
    split_alt,
};

pub const regular_shapes = [_]Shape{ .random, .random, .random, .random, .literal_alt, .boundary_lits, .lit_prefix, .reverse_suffix, .class_span, .end_anchored };
pub const nonregular_shapes = [_]Shape{ .nonregular, .nonregular, .dup_word, .edge_look, .split_alt };

pub fn pickShape(rng: *Rng, shapes: []const Shape) Shape {
    return shapes[rng.below(shapes.len)];
}

/// Most capture groups a generated pattern opens.
pub const MAX_GEN_GROUPS: usize = 6;
const MAX_SLOTS: usize = 2 * (MAX_GEN_GROUPS + 1);
/// Pattern buffer size; a pattern that outgrows it sets `overflow`.
pub const MAX_PAT: usize = 512;

const atoms = [_][]const u8{
    "a",  "b",  " ",   "[ab]", "\\w", "\\s",   ".", "[^a]",  "\\W",      "a",       "b",
    "ab", "ba", "aab", "A",    "\\d", "[0-9]", "1", "[a-c]", "\xC3\xA9", "(?i:ab)", "[^b\\n]",
};
const looks = [_][]const u8{ "\\b", "\\B", "^", "$", "\\A", "\\z", "\\Z" };
const reps = [_][]const u8{ "*", "+", "?", "{0,2}", "{1,3}", "{2}" };
const words = [_][]const u8{ "a", "b", "ab", "ba", "aab", "abb", "bab", "A", "Ab", "1", "12", "\xC3\xA9" };
const long_lits = [_][]const u8{ "aba", "abb", "bab", "aab", "ab a", "a1b", "baab" };
const span_classes = [_][]const u8{ "[a-c]", "\\d", "[0-9]", "a", "b", "[ab]", "[A-Z]" };
const dup_classes = [_][]const u8{ "[ab]", "\\w", "[a-z]", "[a-c0-9]", "[A-Za-z]" };
const dup_seps = [_][]const u8{ " ", "\\s", "[ ,]", "," };
const la_opens = [_][]const u8{ "(?=", "(?!", "(?<=", "(?<!" };
const la_sets = [_][]const u8{ "a", "b", "[ab]", "\\d", "\\s", " ", "[^a]", "\\w" };

pub const Gen = struct {
    rng: *Rng,
    buf: [MAX_PAT]u8 = undefined,
    len: usize = 0,
    /// The pattern outgrew `buf`; skip it.
    overflow: bool = false,
    groups: usize = 0,
    /// Bit `g` set once group `g` is closed (a valid backreference target).
    closed: u8 = 0,
    // Per-subtree switches.
    groups_ok: bool = true,
    alt_ok: bool = true,
    looks_ok: bool = true,
    lazy_ok: bool = true,
    /// Allow lookaround / backreferences / atomic groups / possessive quantifiers.
    nonregular: bool = false,
    /// Inside a lookaround body: no captures, no backreferences.
    in_look: bool = false,
    emitted_nonregular: bool = false,

    pub fn pattern(g: *const Gen) []const u8 {
        return g.buf[0..g.len];
    }

    fn put(g: *Gen, s: []const u8) void {
        if (g.len + s.len > MAX_PAT) {
            g.overflow = true;
            return;
        }
        @memcpy(g.buf[g.len..][0..s.len], s);
        g.len += s.len;
    }

    fn atom(g: *Gen) void {
        if (g.looks_ok and g.rng.oneIn(4)) return g.put(g.rng.pick(&looks));
        g.put(g.rng.pick(&atoms));
    }

    fn node(g: *Gen, depth: usize) void {
        const kinds: usize = if (g.nonregular) 9 else 7;
        const k = if (depth == 0) 0 else g.rng.below(kinds);
        switch (k) {
            0, 1 => g.atom(),
            2 => { // concat
                g.node(depth - 1);
                g.node(depth - 1);
            },
            3 => if (g.alt_ok) {
                g.put("(?:");
                g.node(depth - 1);
                g.put("|");
                g.node(depth - 1);
                g.put(")");
            } else g.node(depth - 1),
            4 => if (g.groups_ok and !g.in_look and g.groups < MAX_GEN_GROUPS) {
                g.groups += 1;
                const id = g.groups;
                g.put("(");
                g.node(depth - 1);
                g.put(")");
                g.closed |= @as(u8, 1) << @intCast(id);
            } else g.node(depth - 1),
            5, 6 => { // repetition: greedy, lazy, or (non-regular) possessive
                g.put("(?:");
                g.node(depth - 1);
                g.put(")");
                g.put(g.rng.pick(&reps));
                if (g.nonregular and g.rng.oneIn(5)) {
                    g.put("+");
                    g.emitted_nonregular = true;
                } else if (g.lazy_ok and g.rng.oneIn(2)) g.put("?");
            },
            7 => g.lookaround(depth - 1),
            else => g.backrefOrAtomic(depth - 1),
        }
    }

    fn lookaround(g: *Gen, depth: usize) void {
        g.put(g.rng.pick(&la_opens));
        const saved = g.in_look;
        g.in_look = true;
        g.node(depth);
        g.in_look = saved;
        g.put(")");
        g.emitted_nonregular = true;
    }

    fn backrefOrAtomic(g: *Gen, depth: usize) void {
        if (!g.in_look and g.closed != 0 and g.rng.oneIn(2)) {
            var ids: [MAX_GEN_GROUPS]u8 = undefined;
            var n: usize = 0;
            for (1..MAX_GEN_GROUPS + 1) |i| {
                if (g.closed & (@as(u8, 1) << @intCast(i)) != 0) {
                    ids[n] = @intCast(i);
                    n += 1;
                }
            }
            const br = [2]u8{ '\\', '0' + ids[g.rng.below(n)] };
            g.put(&br);
        } else {
            g.put("(?>");
            g.node(depth);
            g.put(")");
        }
        g.emitted_nonregular = true;
    }

    /// `w|w|…` over `words` (2–6 branches, duplicates allowed).
    fn wordAlt(g: *Gen) void {
        const n = 2 + g.rng.below(5);
        for (0..n) |i| {
            if (i > 0) g.put("|");
            g.put(g.rng.pick(&words));
        }
    }
};

/// One pattern of the given shape. Check `overflow` before using `pattern()`.
pub fn generate(rng: *Rng, shape: Shape) Gen {
    var g = Gen{ .rng = rng };
    switch (shape) {
        .random => {
            if (rng.oneIn(4)) g.put("(?m)");
            if (rng.oneIn(6)) g.put("(?i)");
            g.node(4);
        },
        .literal_alt => g.wordAlt(),
        .boundary_lits => {
            g.put("\\b(?:");
            g.wordAlt();
            g.put(")\\b");
        },
        .lit_prefix => {
            g.looks_ok = false;
            g.put(rng.pick(&long_lits));
            g.node(3);
        },
        .reverse_suffix => {
            g.looks_ok = false;
            g.node(3);
            g.put(rng.pick(&long_lits));
        },
        .class_span => {
            g.put(rng.pick(&span_classes));
            g.put(if (rng.oneIn(2)) "+" else "*");
        },
        .end_anchored => {
            g.looks_ok = false;
            g.node(3);
            g.put("$");
        },
        .nonregular => {
            if (rng.oneIn(5)) g.put("(?m)");
            if (rng.oneIn(6)) g.put("(?i)");
            g.nonregular = true;
            g.node(4);
            if (!g.emitted_nonregular) g.lookaround(1);
        },
        .dup_word => {
            if (rng.oneIn(4)) g.put("(?i)");
            g.put("(\\b");
            g.put(rng.pick(&dup_classes));
            g.put("+\\b)");
            g.put(rng.pick(&dup_seps));
            g.put("\\1");
            g.groups = 1;
        },
        .edge_look => {
            g.groups_ok = false;
            g.alt_ok = false;
            g.looks_ok = false;
            g.lazy_ok = false;
            // A folded start anchor: the walk may only try the origin.
            if (rng.oneIn(6)) g.put(if (rng.oneIn(2)) "^" else "\\A");
            g.node(3);
            g.put(rng.pick(&la_opens));
            g.put(rng.pick(&la_sets));
            g.put(")");
        },
        .split_alt => {
            g.groups_ok = false;
            const n = 2 + rng.below(3);
            // At least one regular (look-free, DFA-eligible) branch and one
            // lookaround branch; the rest are a coin flip.
            const la_at = rng.below(n);
            const re_at = (la_at + 1 + rng.below(n - 1)) % n;
            for (0..n) |i| {
                if (i > 0) g.put("|");
                const want_la = i == la_at or (i != re_at and rng.oneIn(2));
                g.nonregular = want_la;
                g.looks_ok = want_la;
                g.emitted_nonregular = false;
                g.node(2);
                if (want_la and !g.emitted_nonregular) g.lookaround(1);
            }
        },
    }
    return g;
}

pub const InputSize = enum { short, medium, long };
pub const MAX_INPUT: usize = 4096;
const MAX_SHORT: usize = 12;

const short_alpha = "aaabbb   \nA1,\xC3\xA9";
const in_words = [_][]const u8{ "a", "b", "ab", "ba", "aab", "abb", "bab", "A", "Ab", "AB", "1", "12", "the", "\xC3\xA9", "a\xC3\xA9" };
const in_seps = [_][]const u8{ " ", " ", " ", "\n", ",", "  ", ", " };

/// A random input: `short` (≤ 12 bytes over a small alphabet), or a `medium`
/// (13–200 B) / `long` (1–4 KiB) token stream with duplicated words and stray
/// non-ASCII bytes.
pub fn genInput(rng: *Rng, buf: *[MAX_INPUT]u8, size: InputSize) []const u8 {
    if (size == .short) {
        const n = rng.below(MAX_SHORT + 1);
        for (buf[0..n]) |*c| c.* = short_alpha[rng.below(short_alpha.len)];
        return buf[0..n];
    }
    const target = if (size == .medium) 13 + rng.below(188) else 1024 + rng.below(MAX_INPUT - 1024 + 1);
    const dst = buf[0..target];
    var n: usize = 0;
    var prev: []const u8 = in_words[0];
    while (n < target) {
        if (rng.oneIn(40)) {
            dst[n] = @intCast(0x80 + rng.below(0x80));
            n += 1;
            continue;
        }
        const w = if (rng.oneIn(5)) prev else rng.pick(&in_words);
        n = appendClamped(dst, n, w);
        n = appendClamped(dst, n, rng.pick(&in_seps));
        prev = w;
    }
    return dst;
}

fn appendClamped(dst: []u8, n: usize, s: []const u8) usize {
    const k = @min(s.len, dst.len - n);
    @memcpy(dst[n..][0..k], s[0..k]);
    return n + k;
}

/// Inputs per pattern: `N_SHORT` short ones, one medium, and a long one for
/// one pattern in `LONG_ONE_IN` on average.
const N_SHORT: usize = 5;
const LONG_ONE_IN: usize = 20;

fn inputSize(rng: *Rng, k: usize) ?InputSize {
    if (k < N_SHORT) return .short;
    if (k == N_SHORT) return .medium;
    return if (rng.oneIn(LONG_ONE_IN)) .long else null;
}

// ============================================================================
// Shared checking machinery
// ============================================================================

const Span = struct { start: usize, end: usize };

/// Any engine's optional span (they all carry `start` / `end`) as a `?Span`.
fn span(x: anytype) ?Span {
    const v = x orelse return null;
    return .{ .start = v.start, .end = v.end };
}

fn spanEq(x: ?Span, y: ?Span) bool {
    if (x == null or y == null) return x == null and y == null;
    return x.?.start == y.?.start and x.?.end == y.?.end;
}

const SpanFmt = struct {
    s: ?Span,
    pub fn format(self: SpanFmt, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.s) |s| try w.print("[{d},{d})", .{ s.start, s.end }) else try w.writeAll("none");
    }
};

fn expectSpan(what: []const u8, pat: []const u8, in: []const u8, from: usize, want: ?Span, got: ?Span) !void {
    if (spanEq(want, got)) return;
    std.debug.print("\nnfa_fuzz MISMATCH [{s}] pattern=\"{f}\" input=\"{f}\" from={d}: want={f} got={f}\n", .{
        what, std.zig.fmtString(pat), std.zig.fmtString(in), from, SpanFmt{ .s = want }, SpanFmt{ .s = got },
    });
    return error.TestUnexpectedResult;
}

fn expectSlots(what: []const u8, pat: []const u8, in: []const u8, from: usize, want: []const hir.Slot, got: []const hir.Slot) !void {
    if (std.mem.eql(hir.Slot, want, got)) return;
    std.debug.print("\nnfa_fuzz MISMATCH [{s} slots] pattern=\"{f}\" input=\"{f}\" from={d}: want={any} got={any}\n", .{
        what, std.zig.fmtString(pat), std.zig.fmtString(in), from, want, got,
    });
    return error.TestUnexpectedResult;
}

/// A reference engine: `find(in, from, slots)` is the leftmost-first match
/// at/after absolute `from` with its capture slots. `error.Budget` ⇒ the
/// reference gave up; the caller skips that comparison.
const RefError = error{ Budget, OutOfMemory };

const BoundedRef = struct {
    bt: *bounded_bt.BoundedBt,
    fn find(self: BoundedRef, in: []const u8, from: usize, slots: []hir.Slot) RefError!?Span {
        return span(try self.bt.capturesFrom(in, from, slots));
    }
};

/// The non-regular reference: the plain tree backtracker over the parsed HIR
/// (no seek prefilter, no delegation, no first-byte dispatch, none of the
/// `Regex` peels).
const TreeRef = struct {
    h: *const hir.Hir(null),
    ng: usize,
    fn find(self: TreeRef, in: []const u8, from: usize, slots: []hir.Slot) RefError!?Span {
        // A folded `^`/`\A` matches only at offset 0 (as in `Regex` and
        // `bounded_bt`); the tree walk alone would re-anchor at `from`.
        if (self.h.anchored_start and from > 0) return null;
        var bt = backtrack.Backtracker.init(self.h, self.h.anchored_start, self.h.anchored_end, self.ng, null, null);
        return span(try bt.runFrom(in, from, slots));
    }
};

/// The literal-alternation reference: at the leftmost position where any
/// needle occurs, the earliest-listed one (a map from needle to its first
/// index, probed at every length).
const NaiveAlt = struct {
    earliest: std.StringHashMapUnmanaged(u32) = .empty,
    max_len: usize = 0,

    fn init(a: std.mem.Allocator, needles: []const []const u8) !NaiveAlt {
        var self = NaiveAlt{};
        errdefer self.earliest.deinit(a);
        for (needles, 0..) |nd, i| {
            const gop = try self.earliest.getOrPut(a, nd);
            if (!gop.found_existing) gop.value_ptr.* = @intCast(i);
            self.max_len = @max(self.max_len, nd.len);
        }
        return self;
    }

    fn deinit(self: *NaiveAlt, a: std.mem.Allocator) void {
        self.earliest.deinit(a);
    }

    fn find(self: *const NaiveAlt, in: []const u8, from: usize, slots: []hir.Slot) RefError!?Span {
        _ = slots; // capture-free
        var p = from;
        while (p <= in.len) : (p += 1) {
            var best: ?u32 = null;
            var best_len: usize = 0;
            var l: usize = 1;
            while (l <= self.max_len and p + l <= in.len) : (l += 1) {
                if (self.earliest.get(in[p..][0..l])) |i| {
                    if (best == null or i < best.?) {
                        best = i;
                        best_len = l;
                    }
                }
            }
            if (best != null) return .{ .start = p, .end = p + best_len };
        }
        return null;
    }
};

/// `Regex.findFrom` + `Regex.capturesFrom` at absolute `from` must reproduce
/// the reference span `want` and every group slot of `want_slots`. A budget
/// exceed on the `Regex` side skips the comparison.
fn expectRegexAt(a: std.mem.Allocator, pat: []const u8, in: []const u8, from: usize, rx: *const Regex, ng: usize, want: ?Span, want_slots: []const hir.Slot) !void {
    const r = rx.findFrom(in, from) catch |e| switch (e) {
        error.MatchBudgetExceeded => return,
        else => return e,
    };
    try expectSpan("Regex.findFrom", pat, in, from, want, span(r));

    var m = rx.capturesFrom(a, in, from) catch |e| switch (e) {
        error.MatchBudgetExceeded => return,
        else => return e,
    };
    defer if (m) |*x| x.deinit(a);
    try expectSpan("Regex.capturesFrom", pat, in, from, want, span(m));
    const mm = m orelse return;
    if (ng == 0) return;
    if (mm.groups.len != ng + 1) {
        std.debug.print("\nnfa_fuzz MISMATCH [Regex.capturesFrom groups] pattern=\"{f}\" input=\"{f}\" from={d}: {d} groups, want {d} (kind {s})\n", .{
            std.zig.fmtString(pat), std.zig.fmtString(in), from, mm.groups.len, ng + 1, @tagName(rx.kind),
        });
        return error.TestUnexpectedResult;
    }
    // `Regex` reports a group as null unless both ends are set and ordered.
    var want_g: [MAX_SLOTS]hir.Slot = undefined;
    var got_g: [MAX_SLOTS]hir.Slot = undefined;
    for (1..ng + 1) |gi| {
        const s = want_slots[2 * gi];
        const e = want_slots[2 * gi + 1];
        const set = s >= 0 and e >= 0 and s <= e;
        want_g[2 * gi] = if (set) s else -1;
        want_g[2 * gi + 1] = if (set) e else -1;
        if (mm.groups[gi]) |grp| {
            got_g[2 * gi] = @intCast(grp.start);
            got_g[2 * gi + 1] = @intCast(grp.end);
        } else {
            got_g[2 * gi] = -1;
            got_g[2 * gi + 1] = -1;
        }
    }
    try expectSlots("Regex.capturesFrom", pat, in, from, want_g[2 .. 2 * (ng + 1)], got_g[2 .. 2 * (ng + 1)]);
}

/// Reference span + slots at `from`, then the `Regex` comparison. A reference
/// budget exceed skips it.
fn checkRegexAt(a: std.mem.Allocator, pat: []const u8, in: []const u8, from: usize, rx: *const Regex, ng: usize, ref: anytype) !void {
    var slots: [MAX_SLOTS]hir.Slot = undefined;
    const nsl = 2 * (ng + 1);
    const want = ref.find(in, from, slots[0..nsl]) catch |e| switch (e) {
        error.Budget => return,
        else => return e,
    };
    try expectRegexAt(a, pat, in, from, rx, ng, want, slots[0..nsl]);
}

/// Start offsets to check for one input: all of them for a short input; the
/// ends plus a few random ones for a medium input; none for a long one (its
/// iteration below already resumes at every match end).
fn checkOffsets(rng: *Rng, size: InputSize, in: []const u8, ctx: anytype) !void {
    switch (size) {
        .short => for (0..in.len + 1) |from| try ctx.checkAt(in, from),
        .medium => {
            try ctx.checkAt(in, 0);
            try ctx.checkAt(in, in.len);
            for (0..4) |_| try ctx.checkAt(in, rng.below(in.len + 1));
        },
        .long => {},
    }
}

/// Non-overlapping iteration (`findFrom` + `capturesFrom` at each resume
/// point), `count` and `isMatch` through `Regex`'s real routing, against the
/// reference. A budget exceed on either side skips the rest of this input.
fn checkIteration(a: std.mem.Allocator, pat: []const u8, in: []const u8, rx: *const Regex, ng: usize, ref: anytype) !void {
    var slots: [MAX_SLOTS]hir.Slot = undefined;
    const nsl = 2 * (ng + 1);
    var pos: usize = 0;
    var n: usize = 0;
    while (pos <= in.len) {
        const w_opt = ref.find(in, pos, slots[0..nsl]) catch |e| switch (e) {
            error.Budget => return,
            else => return e,
        };
        const w = w_opt orelse break;
        try expectRegexAt(a, pat, in, pos, rx, ng, w, slots[0..nsl]);
        n += 1;
        pos = advanceEmpty(w.start, w.end);
    }
    const rc = rx.count(in) catch |e| switch (e) {
        error.MatchBudgetExceeded => return,
        else => return e,
    };
    if (rc != n) {
        std.debug.print("\nnfa_fuzz MISMATCH [count] pattern=\"{f}\" input=\"{f}\" ref={d} Regex.count={d} kind={s}\n", .{
            std.zig.fmtString(pat), std.zig.fmtString(in), n, rc, @tagName(rx.kind),
        });
        return error.TestUnexpectedResult;
    }
    const im = rx.isMatch(in) catch |e| switch (e) {
        error.MatchBudgetExceeded => return,
        else => return e,
    };
    if (im != (n > 0)) {
        std.debug.print("\nnfa_fuzz MISMATCH [isMatch] pattern=\"{f}\" input=\"{f}\" ref={} Regex.isMatch={} kind={s}\n", .{
            std.zig.fmtString(pat), std.zig.fmtString(in), n > 0, im, @tagName(rx.kind),
        });
        return error.TestUnexpectedResult;
    }
}

const Kind = @FieldType(Regex, "kind");
const Tally = std.EnumArray(Kind, usize);

/// The coverage guard: every kind in `kinds` was routed to at least `floor`
/// times. On failure prints the whole tally.
fn expectKinds(tally: *const Tally, kinds: []const Kind, floor: usize) !void {
    var ok = true;
    for (kinds) |k| {
        if (tally.get(k) < floor) {
            std.debug.print("\nnfa_fuzz COVERAGE: engine kind .{s} was routed to {d}× (floor {d})\n", .{ @tagName(k), tally.get(k), floor });
            ok = false;
        }
    }
    if (ok) return;
    for (std.enums.values(Kind)) |k| std.debug.print("  .{s}: {d}\n", .{ @tagName(k), tally.get(k) });
    return error.TestUnexpectedResult;
}

/// Parse `pat` reporting its group count; null if it doesn't parse or opens
/// more groups than the slot arrays hold.
fn parseCounted(a: std.mem.Allocator, h: *hir.Hir(null), pat: []const u8) ?usize {
    var ng: usize = 0;
    var gnames: [hir.groupsCap(null) + 1]?[]const u8 = undefined;
    parser.parseCaptures(null, h, a, pat, .{}, &ng, &gnames) catch return null;
    return if (ng <= MAX_GEN_GROUPS) ng else null;
}

// ============================================================================
// Regular patterns: bounded_bt vs PikeVM / lazy DFA / tree backtracker / Regex
// ============================================================================

const RegularCase = struct {
    a: std.mem.Allocator,
    pat: []const u8,
    h: *const hir.Hir(null),
    nfa: *const thompson.Nfa(null),
    idx: EdgeIndex,
    ng: usize,
    rx: *const Regex,
    lz: ?*lazy_dfa.LazyProg,
    memo: *lazy_dfa.LazyMemo,
    psc: *pikevm.PikeScratch,
    bt: *bounded_bt.BoundedBt,
    has_look: bool,
    lazy_look_checks: *usize,

    fn checkAt(c: *const RegularCase, in: []const u8, from: usize) !void {
        const nsl = 2 * (c.ng + 1);
        var want_slots: [MAX_SLOTS]hir.Slot = undefined;
        const want = span(try c.bt.capturesFrom(in, from, want_slots[0..nsl]));

        // PikeVM: span + every slot.
        var vm = try pikevm.PikeVm.init(c.nfa, c.idx, c.h.anchored_start, c.h.anchored_end, c.psc, nsl);
        var got_slots: [MAX_SLOTS]hir.Slot = undefined;
        const got = span(try vm.search(in, from, .{}, got_slots[0..nsl]));
        try expectSpan("pikevm", c.pat, in, from, want, got);
        if (want != null) try expectSlots("pikevm", c.pat, in, from, want_slots[0..nsl], got_slots[0..nsl]);

        // Plain search must equal the capturing one.
        try expectSpan("bounded_bt.findLeftmostFrom", c.pat, in, from, want, span(try c.bt.findLeftmostFrom(in, from)));

        // Tree backtracker (the non-regular test's reference): span + slots.
        var tree_slots: [MAX_SLOTS]hir.Slot = undefined;
        const tree = TreeRef{ .h = c.h, .ng = c.ng };
        if (tree.find(in, from, tree_slots[0..nsl])) |tr| {
            try expectSpan("tree backtracker", c.pat, in, from, want, tr);
            if (want != null) try expectSlots("tree backtracker", c.pat, in, from, want_slots[0..nsl], tree_slots[0..nsl]);
        } else |e| switch (e) {
            error.Budget => {},
            else => return e,
        }

        // Lazy DFA (look mode when the NFA has looks); a thrash give-up is allowed.
        if (c.lz) |p| {
            if (p.findLeftmostFrom(c.memo, in, from)) |lg| {
                try expectSpan("lazy_dfa", c.pat, in, from, want, span(lg));
                if (c.has_look) c.lazy_look_checks.* += 1;
            } else |e| switch (e) {
                error.LazyGaveUp => {},
                else => return e,
            }
        }

        // Regex through its real routing, resumed at this absolute offset.
        try expectRegexAt(c.a, c.pat, in, from, c.rx, c.ng, want, want_slots[0..nsl]);
    }
};

fn checkRegular(a: std.mem.Allocator, rng: *Rng, pat: []const u8, tally: *Tally, lazy_look_checks: *usize) !void {
    var h = hir.Hir(null).initRuntime();
    defer h.deinit(a);
    const ng = parseCounted(a, &h, pat) orelse return;
    if (properties.analyze(null, &h).requires_backtracking) return;
    const nfa = try a.create(thompson.Nfa(null));
    defer a.destroy(nfa);
    nfa.* = thompson.buildAlloc(a, &h) catch return;
    defer nfa.deinit(a);
    var idx = try EdgeIndex.build(a, nfa);
    defer idx.deinit(a);

    var rx = Regex.compile(a, pat) catch return;
    defer rx.deinit();
    tally.getPtr(rx.kind).* += 1;

    const has_look = lazy_dfa.LazyProg.hasLookEdges(nfa);
    const lazy_ok = !has_look or lazy_dfa.LazyProg.lookSupported(nfa);
    var lz: ?lazy_dfa.LazyProg = if (lazy_ok) try lazy_dfa.LazyProg.init(a, nfa, h.anchored_start, h.anchored_end) else null;
    defer if (lz) |*p| p.deinit();
    var memo = lazy_dfa.LazyMemo.init(a);
    defer memo.deinit();
    var psc = pikevm.PikeScratch.init(a);
    defer psc.deinit();

    var buf: [MAX_INPUT]u8 = undefined;
    for (0..N_SHORT + 2) |k| {
        const size = inputSize(rng, k) orelse continue;
        const in = genInput(rng, &buf, size);
        var bt = try bounded_bt.BoundedBt.init(a, nfa, h.anchored_start, h.anchored_end, in.len);
        defer bt.deinit();
        const c = RegularCase{
            .a = a,
            .pat = pat,
            .h = &h,
            .nfa = nfa,
            .idx = idx,
            .ng = ng,
            .rx = &rx,
            .lz = if (lz) |*p| p else null,
            .memo = &memo,
            .psc = &psc,
            .bt = &bt,
            .has_look = has_look,
            .lazy_look_checks = lazy_look_checks,
        };
        try checkOffsets(rng, size, in, &c);

        if (lz) |*p| {
            const want0 = (try bt.findLeftmostFrom(in, 0)) != null;
            if (p.isMatchFast(&memo, in)) |im| {
                if (im != want0) {
                    std.debug.print("\nnfa_fuzz MISMATCH [lazy isMatch] pattern=\"{f}\" input=\"{f}\" ref={} lazy={}\n", .{ std.zig.fmtString(pat), std.zig.fmtString(in), want0, im });
                    return error.TestUnexpectedResult;
                }
            } else |e| switch (e) {
                error.LazyGaveUp => {},
                else => return e,
            }
        }
        try checkIteration(a, pat, in, &rx, ng, BoundedRef{ .bt = &bt });
    }
}

test "nfa_fuzz: regular patterns — backtracker, PikeVM, lazy DFA, tree backtracker and Regex agree" {
    const a = std.testing.allocator;
    var rng = Rng{ .s = 0x5eed_100c };
    var tally = Tally.initFill(0);
    var lazy_look_checks: usize = 0;
    for (0..1000) |_| {
        var g = generate(&rng, pickShape(&rng, &regular_shapes));
        if (g.overflow) continue;
        try checkRegular(a, &rng, g.pattern(), &tally, &lazy_look_checks);
    }
    // The generator must actually exercise the look-mode lazy DFA ...
    try std.testing.expect(lazy_look_checks > 1000);
    // ... and every regular-tier engine.
    // Floors are about half the counts this seed produces (the thinnest,
    // `bt_look`, gets ~27): enough slack for small generator tweaks, while an
    // engine that stops being reached fails loudly.
    try expectKinds(&tally, &.{ .literal, .dfa, .lit_prefix, .reverse_suffix, .bt_look, .lazy_dfa, .dense_search, .class_span, .boundary_lits }, 12);
}

// ============================================================================
// Non-regular patterns: plain tree backtracker vs Regex
// ============================================================================

const NonregularCase = struct {
    a: std.mem.Allocator,
    pat: []const u8,
    rx: *const Regex,
    ng: usize,
    ref: TreeRef,

    fn checkAt(c: *const NonregularCase, in: []const u8, from: usize) !void {
        try checkRegexAt(c.a, c.pat, in, from, c.rx, c.ng, c.ref);
    }
};

fn checkNonregular(a: std.mem.Allocator, rng: *Rng, pat: []const u8, tally: *Tally) !void {
    var h = hir.Hir(null).initRuntime();
    defer h.deinit(a);
    const ng = parseCounted(a, &h, pat) orelse return;
    if (!properties.analyze(null, &h).requires_backtracking) return;

    var rx = Regex.compile(a, pat) catch return;
    defer rx.deinit();
    tally.getPtr(rx.kind).* += 1;

    const c = NonregularCase{ .a = a, .pat = pat, .rx = &rx, .ng = ng, .ref = .{ .h = &h, .ng = ng } };
    var buf: [MAX_INPUT]u8 = undefined;
    for (0..N_SHORT + 2) |k| {
        const size = inputSize(rng, k) orelse continue;
        const in = genInput(rng, &buf, size);
        try checkOffsets(rng, size, in, &c);
        try checkIteration(a, pat, in, &rx, ng, c.ref);
    }
}

test "nfa_fuzz: non-regular patterns — Regex (backtrack, split_alt, dup_word, dfa_edge_look) agrees with the plain tree backtracker" {
    const a = std.testing.allocator;
    var rng = Rng{ .s = 0xbac7_7ac4 };
    var tally = Tally.initFill(0);
    for (0..700) |_| {
        var g = generate(&rng, pickShape(&rng, &nonregular_shapes));
        if (g.overflow) continue;
        try checkNonregular(a, &rng, g.pattern(), &tally);
    }
    try expectKinds(&tally, &.{ .backtrack, .split_alt, .dup_word, .dfa_edge_look }, 50);
}

// ============================================================================
// Pure-literal alternations: naive scan vs LiteralAltScanner / Regex
// ============================================================================

const ScannerCase = struct {
    a: std.mem.Allocator,
    pat: []const u8,
    rx: *const Regex,
    sc: *const prefilter.LiteralAltScanner,
    ref: *const NaiveAlt,

    fn checkAt(c: *const ScannerCase, in: []const u8, from: usize) !void {
        var slots: [2]hir.Slot = undefined;
        const want = try c.ref.find(in, from, &slots);
        try expectSpan("LiteralAltScanner.find", c.pat, in, from, want, span(c.sc.find(in, from)));
        try expectRegexAt(c.a, c.pat, in, from, c.rx, 0, want, &slots);
    }
};

/// Check one alternation (`needles` in source order, `pat` their `|`-join)
/// on `n_inputs` inputs from `input_fn`.
fn checkAlternation(a: std.mem.Allocator, rng: *Rng, needles: []const []const u8, pat: []const u8, tally: *Tally, input_fn: anytype, input_ctx: anytype) !void {
    var ref = try NaiveAlt.init(a, needles);
    defer ref.deinit(a);
    var sc = (try prefilter.LiteralAltScanner.build(a, needles)) orelse return error.TestUnexpectedResult;
    defer sc.deinit(a);
    var rx = try Regex.compile(a, pat);
    defer rx.deinit();
    tally.getPtr(rx.kind).* += 1;

    const c = ScannerCase{ .a = a, .pat = pat, .rx = &rx, .sc = &sc, .ref = &ref };
    var buf: [MAX_INPUT]u8 = undefined;
    for (0..N_SHORT + 2) |k| {
        const size = inputSize(rng, k) orelse continue;
        const in = input_fn(input_ctx, rng, &buf, size);
        try checkOffsets(rng, size, in, &c);
        var slots: [2]hir.Slot = undefined;
        const want0 = (try ref.find(in, 0, &slots)) != null;
        if (sc.isMatch(in) != want0) {
            std.debug.print("\nnfa_fuzz MISMATCH [LiteralAltScanner.isMatch] pattern=\"{f}\" input=\"{f}\" ref={}\n", .{ std.zig.fmtString(pat), std.zig.fmtString(in), want0 });
            return error.TestUnexpectedResult;
        }
        try checkIteration(a, pat, in, &rx, 0, &ref);
    }
}

fn plainInput(_: void, rng: *Rng, buf: *[MAX_INPUT]u8, size: InputSize) []const u8 {
    return genInput(rng, buf, size);
}

/// Dictionary input: dictionary words, random letter runs and separators.
fn dictInput(dict: []const []const u8, rng: *Rng, buf: *[MAX_INPUT]u8, size: InputSize) []const u8 {
    const target = switch (size) {
        .short => rng.below(MAX_SHORT + 1),
        .medium => 13 + rng.below(188),
        .long => 1024 + rng.below(MAX_INPUT - 1024 + 1),
    };
    const dst = buf[0..target];
    var n: usize = 0;
    while (n < target) {
        switch (rng.below(10)) {
            0...4 => n = appendClamped(dst, n, dict[rng.below(dict.len)]),
            5...7 => {
                const run = 1 + rng.below(4);
                for (0..run) |_| {
                    if (n == target) break;
                    dst[n] = dict_alpha[rng.below(dict_alpha.len)];
                    n += 1;
                }
            },
            8 => n = appendClamped(dst, n, if (rng.oneIn(4)) "\n" else " "),
            else => {
                dst[n] = @intCast(0x80 + rng.below(0x80));
                n += 1;
            },
        }
    }
    return dst;
}

const dict_alpha = "abcdefgh";
/// Enough words that the naive NFA overflows `thompson.MAX_NFA_RUNTIME`, so
/// `Regex` routes the dictionary to `literal_alt`.
const DICT_WORDS: usize = 3500;
const N_DICTS: usize = 3;

test "nfa_fuzz: literal alternations — LiteralAltScanner and Regex (incl. literal_alt dictionaries) agree with a naive scan" {
    const a = std.testing.allocator;
    var rng = Rng{ .s = 0x11_7e7a_17a1 };
    var tally = Tally.initFill(0);

    // Small sets: the scanner directly (a small alternation fits the NFA, so
    // `Regex` routes it to Teddy / a DFA — checked too).
    const small_alpha = "aabbA1c";
    for (0..200) |_| {
        var store: [12][6]u8 = undefined;
        var needles: [12][]const u8 = undefined;
        var pat_buf: [12 * 7]u8 = undefined;
        var plen: usize = 0;
        const k = 1 + rng.below(12);
        for (0..k) |i| {
            const len = 1 + rng.below(5);
            for (store[i][0..len]) |*ch| ch.* = small_alpha[rng.below(small_alpha.len)];
            needles[i] = store[i][0..len];
            if (i > 0) {
                pat_buf[plen] = '|';
                plen += 1;
            }
            @memcpy(pat_buf[plen..][0..len], needles[i]);
            plen += len;
        }
        try checkAlternation(a, &rng, needles[0..k], pat_buf[0..plen], &tally, plainInput, {});
    }

    // Dictionaries too big for the NFA: `Regex` must route them to `literal_alt`.
    var lit_alt_tally = Tally.initFill(0);
    for (0..N_DICTS) |_| {
        var backing: std.ArrayList(u8) = .empty;
        defer backing.deinit(a);
        var bounds: std.ArrayList([2]usize) = .empty;
        defer bounds.deinit(a);
        for (0..DICT_WORDS) |i| {
            if (i > 0) try backing.append(a, '|');
            const off = backing.items.len;
            const len = 1 + rng.below(10);
            for (0..len) |_| try backing.append(a, dict_alpha[rng.below(dict_alpha.len)]);
            try bounds.append(a, .{ off, len });
        }
        const dict = try a.alloc([]const u8, DICT_WORDS);
        defer a.free(dict);
        for (bounds.items, 0..) |b, i| dict[i] = backing.items[b[0]..][0..b[1]];
        try checkAlternation(a, &rng, dict, backing.items, &lit_alt_tally, dictInput, @as([]const []const u8, dict));
    }
    try expectKinds(&lit_alt_tally, &.{.literal_alt}, N_DICTS);
}
