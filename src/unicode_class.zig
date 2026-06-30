//! Resolution and lowering of Unicode property classes (`\p{...}` / `\P{...}`).
//!
//! Scope (UTS #18 RL1.2 — General_Category only):
//!   * one- and two-letter general categories (`\p{L}`, `\p{Lu}`, `\p{Nd}`, …)
//!     and the super-categories `L M N P S Z C`,
//!   * long names and value aliases, matched loosely per UAX #44-LM3,
//!   * negation via `\P{...}`, `\p{^...}`, or an enclosing `[^...]`,
//!   * the `gc=` / `General_Category=` property-name prefix,
//!   * the special values `Any`, `ASCII`, `Assigned`.
//!
//! Scripts, script extensions and binary properties are recognised but rejected
//! with `error.UnsupportedUnicodeProperty` so callers can surface a clear,
//! actionable message rather than silently mis-tokenising.
//!
//! The result is always a sorted, non-overlapping, surrogate-free set of
//! codepoint ranges with negation already folded in. The NFA compiler expands
//! that into a UTF-8 byte automaton; the backtracker tests it per codepoint.

const std = @import("std");
const common = @import("common.zig");
const tables = @import("unicode_tables.zig");
// Property-resolution errors (`error.UnknownUnicodeProperty` /
// `error.UnsupportedUnicodeProperty` / `error.OutOfMemory`) are global errors,
// not part of the public `RegexError`: the parser catches them and remaps to
// `error.NotImplemented` before they can escape `compile`.

pub const CodepointRange = common.CodepointRange;
pub const unicode_version = tables.unicode_version;

const Cat = tables.Category;

/// Surrogate code points — never valid Unicode scalar values, so always
/// excluded from both positive and negated property sets.
const SURR_LO: common.Codepoint = 0xD800;
const SURR_HI: common.Codepoint = 0xDFFF;

// --- Loose name matching (UAX #44-LM3) -------------------------------------

/// Normalize a property or value name: lowercase, drop spaces / `_` / `-`.
/// A leading "is" is handled by the lookup (tried with and without).
fn normalize(buf: []u8, name: []const u8) []const u8 {
    var n: usize = 0;
    for (name) |c| {
        switch (c) {
            ' ', '\t', '_', '-' => {},
            else => {
                if (n >= buf.len) break;
                buf[n] = std.ascii.toLower(c);
                n += 1;
            },
        }
    }
    return buf[0..n];
}

const Special = enum { any, ascii, assigned };

const NameResult = union(enum) {
    cats: []const Cat,
    special: Special,
};

const L = &[_]Cat{ .Lu, .Ll, .Lt, .Lm, .Lo };
const LC = &[_]Cat{ .Lu, .Ll, .Lt };
const M = &[_]Cat{ .Mn, .Mc, .Me };
const N = &[_]Cat{ .Nd, .Nl, .No };
const P = &[_]Cat{ .Pc, .Pd, .Ps, .Pe, .Pi, .Pf, .Po };
const S = &[_]Cat{ .Sm, .Sc, .Sk, .So };
const Z = &[_]Cat{ .Zs, .Zl, .Zp };
const C = &[_]Cat{ .Cc, .Cf, .Cs, .Co, .Cn };

fn one(comptime c: Cat) []const Cat {
    return &[_]Cat{c};
}

/// Map an already-normalized general-category value name to its categories.
fn lookupGc(norm: []const u8) ?NameResult {
    const eq = std.mem.eql;
    const Entry = struct { []const u8, NameResult };
    const table = [_]Entry{
        // Super-categories
        .{ "l", .{ .cats = L } },          .{ "letter", .{ .cats = L } },
        .{ "lc", .{ .cats = LC } },        .{ "casedletter", .{ .cats = LC } },
        .{ "m", .{ .cats = M } },          .{ "mark", .{ .cats = M } },
        .{ "combiningmark", .{ .cats = M } },
        .{ "n", .{ .cats = N } },          .{ "number", .{ .cats = N } },
        .{ "p", .{ .cats = P } },          .{ "punctuation", .{ .cats = P } },
        .{ "punct", .{ .cats = P } },
        .{ "s", .{ .cats = S } },          .{ "symbol", .{ .cats = S } },
        .{ "z", .{ .cats = Z } },          .{ "separator", .{ .cats = Z } },
        .{ "c", .{ .cats = C } },          .{ "other", .{ .cats = C } },
        // Letters
        .{ "lu", .{ .cats = one(.Lu) } }, .{ "uppercaseletter", .{ .cats = one(.Lu) } },
        .{ "ll", .{ .cats = one(.Ll) } }, .{ "lowercaseletter", .{ .cats = one(.Ll) } },
        .{ "lt", .{ .cats = one(.Lt) } }, .{ "titlecaseletter", .{ .cats = one(.Lt) } },
        .{ "lm", .{ .cats = one(.Lm) } }, .{ "modifierletter", .{ .cats = one(.Lm) } },
        .{ "lo", .{ .cats = one(.Lo) } }, .{ "otherletter", .{ .cats = one(.Lo) } },
        // Marks
        .{ "mn", .{ .cats = one(.Mn) } }, .{ "nonspacingmark", .{ .cats = one(.Mn) } },
        .{ "mc", .{ .cats = one(.Mc) } }, .{ "spacingmark", .{ .cats = one(.Mc) } },
        .{ "me", .{ .cats = one(.Me) } }, .{ "enclosingmark", .{ .cats = one(.Me) } },
        // Numbers
        .{ "nd", .{ .cats = one(.Nd) } }, .{ "decimalnumber", .{ .cats = one(.Nd) } },
        .{ "digit", .{ .cats = one(.Nd) } },
        .{ "nl", .{ .cats = one(.Nl) } }, .{ "letternumber", .{ .cats = one(.Nl) } },
        .{ "no", .{ .cats = one(.No) } }, .{ "othernumber", .{ .cats = one(.No) } },
        // Punctuation
        .{ "pc", .{ .cats = one(.Pc) } }, .{ "connectorpunctuation", .{ .cats = one(.Pc) } },
        .{ "pd", .{ .cats = one(.Pd) } }, .{ "dashpunctuation", .{ .cats = one(.Pd) } },
        .{ "ps", .{ .cats = one(.Ps) } }, .{ "openpunctuation", .{ .cats = one(.Ps) } },
        .{ "pe", .{ .cats = one(.Pe) } }, .{ "closepunctuation", .{ .cats = one(.Pe) } },
        .{ "pi", .{ .cats = one(.Pi) } }, .{ "initialpunctuation", .{ .cats = one(.Pi) } },
        .{ "pf", .{ .cats = one(.Pf) } }, .{ "finalpunctuation", .{ .cats = one(.Pf) } },
        .{ "po", .{ .cats = one(.Po) } }, .{ "otherpunctuation", .{ .cats = one(.Po) } },
        // Symbols
        .{ "sm", .{ .cats = one(.Sm) } }, .{ "mathsymbol", .{ .cats = one(.Sm) } },
        .{ "sc", .{ .cats = one(.Sc) } }, .{ "currencysymbol", .{ .cats = one(.Sc) } },
        .{ "sk", .{ .cats = one(.Sk) } }, .{ "modifiersymbol", .{ .cats = one(.Sk) } },
        .{ "so", .{ .cats = one(.So) } }, .{ "othersymbol", .{ .cats = one(.So) } },
        // Separators
        .{ "zs", .{ .cats = one(.Zs) } }, .{ "spaceseparator", .{ .cats = one(.Zs) } },
        .{ "zl", .{ .cats = one(.Zl) } }, .{ "lineseparator", .{ .cats = one(.Zl) } },
        .{ "zp", .{ .cats = one(.Zp) } }, .{ "paragraphseparator", .{ .cats = one(.Zp) } },
        // Other
        .{ "cc", .{ .cats = one(.Cc) } }, .{ "control", .{ .cats = one(.Cc) } },
        .{ "cntrl", .{ .cats = one(.Cc) } },
        .{ "cf", .{ .cats = one(.Cf) } }, .{ "format", .{ .cats = one(.Cf) } },
        .{ "cs", .{ .cats = one(.Cs) } }, .{ "surrogate", .{ .cats = one(.Cs) } },
        .{ "co", .{ .cats = one(.Co) } }, .{ "privateuse", .{ .cats = one(.Co) } },
        .{ "cn", .{ .cats = one(.Cn) } }, .{ "unassigned", .{ .cats = one(.Cn) } },
        // Special values
        .{ "any", .{ .special = .any } },
        .{ "ascii", .{ .special = .ascii } },
        .{ "assigned", .{ .special = .assigned } },
    };
    for (table) |e| {
        if (eq(u8, e[0], norm)) return e[1];
    }
    if (norm.len > 2 and std.mem.startsWith(u8, norm, "is")) {
        for (table) |e| {
            if (eq(u8, e[0], norm[2..])) return e[1];
        }
    }
    return null;
}

/// Names that are valid Unicode properties/values but outside current scope
/// (scripts, script extensions, blocks, binary properties). Recognising them
/// lets us return the actionable `UnsupportedUnicodeProperty` instead of the
/// generic `UnknownUnicodeProperty` for, e.g., `\p{Greek}` or `\p{White_Space}`.
fn isUnsupportedProperty(norm: []const u8) bool {
    const known = [_][]const u8{
        // property names
        "script",          "sc",  "scriptextensions", "scx",
        "block",           "blk", "age",
        // common binary properties
        "whitespace",      "alphabetic", "uppercase", "lowercase",
        "emoji",           "emojipresentation",       "emojimodifier",
        "noncharactercodepoint",   "math",
        "hexdigit",        "asciihexdigit",           "dash",
        "diacritic",       "extender",                "ideographic",
        "joincontrol",     "quotationmark",           "softdotted",
        "defaultignorablecodepoint",                  "whitespacelm3",
        // common script value names (bare `\p{Greek}` shorthand)
        "common",          "latin",      "greek",     "cyrillic",
        "armenian",        "hebrew",     "arabic",    "syriac",
        "thaana",          "devanagari", "bengali",   "gurmukhi",
        "gujarati",        "oriya",      "tamil",     "telugu",
        "kannada",         "malayalam",  "sinhala",   "thai",
        "lao",             "tibetan",    "myanmar",   "georgian",
        "hangul",          "ethiopic",   "cherokee",  "mongolian",
        "hiragana",        "katakana",   "bopomofo",  "han",
        "yi",              "coptic",     "inherited", "runic",
        "ogham",           "khmer",      "braille",
    };
    for (known) |k| {
        if (std.mem.eql(u8, k, norm)) return true;
    }
    return false;
}

// --- Range-set construction ------------------------------------------------

const RangeList = std.ArrayList(CodepointRange);

fn appendCat(list: *RangeList, a: std.mem.Allocator, cat: Cat) !void {
    for (tables.rangesFor(cat)) |r| {
        try list.append(a, .{ .lo = r.lo, .hi = r.hi });
    }
}

fn lessThan(_: void, x: CodepointRange, y: CodepointRange) bool {
    return x.lo < y.lo;
}

/// Sort, merge adjacent/overlapping ranges, and remove the surrogate hole.
/// Result is written back into `list`.
fn normalizeRanges(list: *RangeList, a: std.mem.Allocator) !void {
    std.mem.sort(CodepointRange, list.items, {}, lessThan);

    var merged: RangeList = .empty;
    defer merged.deinit(a);
    for (list.items) |r| {
        if (merged.items.len > 0) {
            const last = &merged.items[merged.items.len - 1];
            if (r.lo <= @as(u32, last.hi) + 1) {
                if (r.hi > last.hi) last.hi = r.hi;
                continue;
            }
        }
        try merged.append(a, r);
    }

    // Subtract the surrogate range [D800, DFFF].
    list.clearRetainingCapacity();
    for (merged.items) |r| {
        if (r.hi < SURR_LO or r.lo > SURR_HI) {
            try list.append(a, r);
            continue;
        }
        if (r.lo < SURR_LO) try list.append(a, .{ .lo = r.lo, .hi = SURR_LO - 1 });
        if (r.hi > SURR_HI) try list.append(a, .{ .lo = SURR_HI + 1, .hi = r.hi });
    }
}

/// Complement `list` within the valid scalar universe
/// [0, 0x10FFFF] \ [D800, DFFF]. `list` must already be normalized.
fn complement(list: *RangeList, a: std.mem.Allocator) !void {
    var out: RangeList = .empty;
    defer out.deinit(a);

    var expected: u32 = 0;
    for (list.items) |r| {
        if (r.lo > expected) {
            try out.append(a, .{ .lo = @intCast(expected), .hi = @intCast(r.lo - 1) });
        }
        expected = @as(u32, r.hi) + 1;
    }
    if (expected <= common.MAX_CODEPOINT) {
        try out.append(a, .{ .lo = @intCast(expected), .hi = common.MAX_CODEPOINT });
    }

    list.clearRetainingCapacity();
    try list.appendSlice(a, out.items);
    try normalizeRanges(list, a); // re-clip the surrogate hole
}

/// Parsed `\p{...}` spec: the resolved general-category lookup and whether the
/// overall set is negated (folding `\P`, a leading `^`, and an enclosing `[^]`).
const ParsedSpec = struct { found: NameResult, negated: bool };

/// Parse the text inside `\p{...}` (or a single letter for `\pX`) down to its
/// general-category lookup and negation flag — the prologue shared by `resolve`
/// (allocating, full-Unicode) and `resolveLatin1Bitmap` (alloc-free, Latin-1),
/// so the two stay membership- and error-identical by construction rather than
/// by hand-kept verbatim copies.
///
/// Handles, in order: surrounding whitespace, a leading `^` negation, an
/// optional `gc=` / `General_Category:` (`=` or `:`) property prefix that must
/// name general-category, then the loose value-name lookup. The
/// unsupported-vs-unknown error distinction lives here. Non-allocating (only
/// stack scratch), so it is usable from the comptime `Pattern` bake path.
fn parseSpec(spec: []const u8, outer_negated: bool) error{
    UnknownUnicodeProperty,
    UnsupportedUnicodeProperty,
}!ParsedSpec {
    var s = std.mem.trim(u8, spec, " \t");
    if (s.len == 0) return error.UnknownUnicodeProperty;

    var negated = outer_negated;
    if (s[0] == '^') {
        negated = !negated;
        s = std.mem.trim(u8, s[1..], " \t");
        if (s.len == 0) return error.UnknownUnicodeProperty;
    }

    // Optional `property=value` (or `property:value`) prefix.
    var value = s;
    var nbuf: [64]u8 = undefined;
    if (std.mem.indexOfAny(u8, s, "=:")) |eq_idx| {
        const prop = normalize(&nbuf, s[0..eq_idx]);
        const is_gc = std.mem.eql(u8, prop, "gc") or
            std.mem.eql(u8, prop, "generalcategory");
        if (!is_gc) {
            return if (isUnsupportedProperty(prop))
                error.UnsupportedUnicodeProperty
            else
                error.UnknownUnicodeProperty;
        }
        value = std.mem.trim(u8, s[eq_idx + 1 ..], " \t");
    }

    var vbuf: [64]u8 = undefined;
    const norm = normalize(&vbuf, value);
    const found = lookupGc(norm) orelse {
        return if (isUnsupportedProperty(norm))
            error.UnsupportedUnicodeProperty
        else
            error.UnknownUnicodeProperty;
    };

    return .{ .found = found, .negated = negated };
}

/// Resolve `spec` (the text inside `\p{...}`, or a single letter for `\pX`).
/// `outer_negated` is true for `\P`. Caller owns the returned slice.
pub fn resolve(
    a: std.mem.Allocator,
    spec: []const u8,
    outer_negated: bool,
) ![]CodepointRange {
    const parsed = try parseSpec(spec, outer_negated);

    var list: RangeList = .empty;
    errdefer list.deinit(a);

    switch (parsed.found) {
        .cats => |cats| {
            for (cats) |c| try appendCat(&list, a, c);
            try normalizeRanges(&list, a);
        },
        .special => |sp| switch (sp) {
            .any => try list.append(a, .{ .lo = 0, .hi = common.MAX_CODEPOINT }),
            .ascii => try list.append(a, .{ .lo = 0, .hi = 0x7F }),
            .assigned => {
                try appendCat(&list, a, .Cn);
                try normalizeRanges(&list, a);
                try complement(&list, a); // assigned = ¬Cn
            },
        },
    }
    if (parsed.found == .special and parsed.found.special == .any) try normalizeRanges(&list, a);

    if (parsed.negated) try complement(&list, a);

    return list.toOwnedSlice(a) catch error.OutOfMemory;
}

/// Allocator-free resolution of `\p{spec}` straight to its **Latin-1 byte
/// set** (codepoints 0..0xFF ∩ property), the engine's byte-oriented `\p`
/// semantics. Result is byte-identical to `resolve(...)` followed by clipping
/// every range to ≤0xFF and rasterising into a 256-bit map — but it never
/// touches an allocator, so the comptime `Pattern` pipeline can bake `\p`
/// exactly like `[a-z]` (the runtime parser uses it too: no alloc/free, no
/// full-Unicode normalisation just to discard everything >0xFF).
///
/// Equivalence argument: surrogates (0xD800+) and every codepoint a
/// normalise/merge step touches are >0xFF, so for the Latin-1 window the
/// sort/merge/surrogate-removal in `resolve` are membership-preserving
/// no-ops, and a universe complement restricted to [0,0xFF] is exactly a
/// 256-bit inversion. The spec parsing (trim, leading `^`, `gc=`/`:` prefix,
/// loose-name lookup, unsupported-vs-unknown) is shared with `resolve` through
/// `parseSpec`, so the error contract is identical by construction.
pub fn resolveLatin1Bitmap(spec: []const u8, outer_negated: bool) ![32]u8 {
    const parsed = try parseSpec(spec, outer_negated);

    var bm = [_]u8{0} ** 32;
    const B = struct {
        fn setRange(m: *[32]u8, lo: u32, hi: u32) void {
            if (lo > 0xFF) return;
            var x: usize = lo;
            const top: usize = @min(@as(usize, hi), 0xFF);
            while (x <= top) : (x += 1) m[x >> 3] |= (@as(u8, 1) << @as(u3, @intCast(x & 7)));
        }
        fn invert(m: *[32]u8) void {
            for (m) |*b| b.* = ~b.*;
        }
        fn cat(m: *[32]u8, c: Cat) void {
            for (tables.rangesFor(c)) |r| setRange(m, r.lo, r.hi);
        }
    };
    switch (parsed.found) {
        .cats => |cats| for (cats) |c| B.cat(&bm, c),
        .special => |sp| switch (sp) {
            .any => @memset(&bm, 0xFF),
            .ascii => B.setRange(&bm, 0, 0x7F),
            .assigned => { // assigned = ¬Cn
                B.cat(&bm, .Cn);
                B.invert(&bm);
            },
        },
    }
    if (parsed.negated) B.invert(&bm);
    return bm;
}

/// Combine an arbitrary (unsorted, possibly overlapping) set of codepoint
/// ranges into a normalized, surrogate-free set, optionally complemented.
/// Used by the character-class parser when a `[...]` mixes literal ranges,
/// predefined escapes, and `\p{...}` and/or carries an enclosing `[^...]`.
/// Caller owns the returned slice.
pub fn buildSet(
    a: std.mem.Allocator,
    input: []const CodepointRange,
    negated: bool,
) ![]CodepointRange {
    var list: RangeList = .empty;
    errdefer list.deinit(a);
    list.appendSlice(a, input) catch return error.OutOfMemory;
    normalizeRanges(&list, a) catch return error.OutOfMemory;
    if (negated) complement(&list, a) catch return error.OutOfMemory;
    return list.toOwnedSlice(a) catch error.OutOfMemory;
}

// --- UTF-8 sub-automaton lowering ------------------------------------------

/// A single inclusive byte range within a UTF-8 sequence step.
pub const Utf8Range = struct { lo: u8, hi: u8 };

/// One UTF-8 byte-range sequence (1–4 steps) covering a scalar sub-range.
pub const Utf8Sequence = struct {
    parts: [4]Utf8Range = undefined,
    len: u8 = 0,
};

fn maxScalar(nbytes: u3) u32 {
    return switch (nbytes) {
        1 => 0x7F,
        2 => 0x7FF,
        3 => 0xFFFF,
        else => 0x10FFFF,
    };
}

fn encodeLen(cp: u21) u3 {
    return std.unicode.utf8CodepointSequenceLength(cp) catch unreachable;
}

/// Produce the UTF-8 byte-range sequences covering scalar range [start, end]
/// (assumed surrogate-free). Port of the well-known utf8-ranges algorithm.
fn pushRange(out: *std.ArrayList(Utf8Sequence), a: std.mem.Allocator, start: u32, end: u32) !void {
    std.debug.assert(start <= end);

    // Split across UTF-8 length boundaries.
    var i: u3 = 1;
    while (i < 4) : (i += 1) {
        const m = maxScalar(i);
        if (start <= m and m < end) {
            try pushRange(out, a, start, m);
            try pushRange(out, a, m + 1, end);
            return;
        }
    }

    // Split so that each continuation-byte position spans a clean range.
    i = 1;
    while (i < 4) : (i += 1) {
        const mask: u32 = (@as(u32, 1) << (6 * @as(u5, i))) - 1;
        if ((start & ~mask) != (end & ~mask)) {
            if ((start & mask) != 0) {
                try pushRange(out, a, start, start | mask);
                try pushRange(out, a, (start | mask) + 1, end);
                return;
            }
            if ((end & mask) != mask) {
                try pushRange(out, a, start, (end & ~mask) - 1);
                try pushRange(out, a, end & ~mask, end);
                return;
            }
        }
    }

    // [start, end] now forms a single sequence of independent byte ranges.
    var sb: [4]u8 = undefined;
    var eb: [4]u8 = undefined;
    const n = encodeLen(@intCast(end));
    _ = std.unicode.utf8Encode(@intCast(start), &sb) catch unreachable;
    _ = std.unicode.utf8Encode(@intCast(end), &eb) catch unreachable;

    var seq: Utf8Sequence = .{};
    seq.len = n;
    var j: usize = 0;
    while (j < n) : (j += 1) {
        seq.parts[j] = .{ .lo = sb[j], .hi = eb[j] };
    }
    try out.append(a, seq);
}

/// Lower a normalized codepoint range set into UTF-8 byte-range sequences.
/// Caller owns the returned slice.
pub fn toUtf8Sequences(
    a: std.mem.Allocator,
    ranges: []const CodepointRange,
) ![]Utf8Sequence {
    var out: std.ArrayList(Utf8Sequence) = .empty;
    errdefer out.deinit(a);
    for (ranges) |r| {
        try pushRange(&out, a, r.lo, r.hi);
    }
    return out.toOwnedSlice(a);
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "resolve general category Lu" {
    const r = try resolve(testing.allocator, "Lu", false);
    defer testing.allocator.free(r);
    const uc = common.UnicodeClass{ .ranges = r };
    try testing.expect(uc.matches('A'));
    try testing.expect(uc.matches(0x0391)); // GREEK CAPITAL ALPHA
    try testing.expect(!uc.matches('a'));
    try testing.expect(!uc.matches('0'));
}

test "resolve loose names and aliases" {
    inline for (.{ "Letter", "letter", "general_category=L", "gc=Letter", "  L  " }) |spec| {
        const r = try resolve(testing.allocator, spec, false);
        defer testing.allocator.free(r);
        const uc = common.UnicodeClass{ .ranges = r };
        try testing.expect(uc.matches('Q'));
        try testing.expect(uc.matches(0x4E2D)); // CJK 中
        try testing.expect(!uc.matches('5'));
    }
}

test "negation forms agree" {
    const a = testing.allocator;
    const p = try resolve(a, "L", true); // \P{L}
    defer a.free(p);
    const c = try resolve(a, "^L", false); // \p{^L}
    defer a.free(c);
    const up = common.UnicodeClass{ .ranges = p };
    const uc = common.UnicodeClass{ .ranges = c };
    for ([_]u21{ 'a', 'Z', '0', ' ', 0x4E2D, 0x1F600 }) |cp| {
        try testing.expectEqual(up.matches(cp), uc.matches(cp));
    }
    try testing.expect(up.matches('0'));
    try testing.expect(!up.matches('a'));
    try testing.expect(!up.matches(0xD800)); // surrogates never match
}

test "unsupported vs unknown property" {
    try testing.expectError(error.UnsupportedUnicodeProperty, resolve(testing.allocator, "Greek", false));
    try testing.expectError(error.UnsupportedUnicodeProperty, resolve(testing.allocator, "Script=Han", false));
    try testing.expectError(error.UnknownUnicodeProperty, resolve(testing.allocator, "Frobnicate", false));
}

test "utf8 sequence lowering round-trips membership" {
    const a = testing.allocator;
    const r = try resolve(a, "N", false);
    defer a.free(r);
    const seqs = try toUtf8Sequences(a, r);
    defer a.free(seqs);
    // ASCII '7' encodes to a single 1-byte sequence that some branch accepts.
    var buf: [4]u8 = undefined;
    const n = try std.unicode.utf8Encode(0x0668, &buf); // ARABIC-INDIC DIGIT EIGHT
    var ok = false;
    for (seqs) |s| {
        if (s.len != n) continue;
        var all = true;
        for (0..s.len) |k| {
            if (buf[k] < s.parts[k].lo or buf[k] > s.parts[k].hi) {
                all = false;
                break;
            }
        }
        if (all) {
            ok = true;
            break;
        }
    }
    try testing.expect(ok);
}
