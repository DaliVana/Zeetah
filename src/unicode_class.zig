//! Resolution of Unicode property classes (`\p{...}` / `\P{...}` / `\pX`).
//!
//! Two front doors, one spec grammar (`parseSpec`):
//!   * **codepoint mode** (`(?u)`): `resolveInto` — General_Category (all
//!     UAX #44 aliases and the super-categories, `L&`), `Script`,
//!     `Script_Extensions`, every binary property in the generated tables,
//!     and the specials `Any` / `ASCII` / `Assigned`; `prop=value`,
//!     `prop:value`, `prop!=value`, a leading `^`, `\P`; UAX44-LM3 loose name
//!     matching with an optional `Is` prefix. Bare names resolve special →
//!     General_Category → binary property → Script (Rust `regex-syntax`
//!     order, which keeps `\p{Sc}` = Currency_Symbol and `\p{Cf}` = Format).
//!   * **byte mode**: `resolveLatin1Bitmap` — the frozen contract: only
//!     General_Category / specials, restricted to codepoints ≤ 0xFF; scripts,
//!     binary properties and script extensions are recognised but rejected
//!     with `error.UnsupportedUnicodeProperty` (→ `NotImplemented`).
//!
//! Results are normalized, surrogate-free `CodepointRange` sets with negation
//! folded in (`unicode_set`). The parser turns them into `.uclass` HIR nodes,
//! the NFA compiler into UTF-8 byte automata, the backtrackers test them per
//! decoded codepoint.

const std = @import("std");
const common = @import("common.zig");
const tables = @import("unicode_tables.zig");
const uset = @import("unicode_set.zig");

pub const CodepointRange = common.CodepointRange;
pub const unicode_version = tables.unicode_version;

const Cat = tables.Category;

/// Property-resolution errors. Global errors, not part of the public
/// `RegexError`: the parser remaps both to `error.NotImplemented`.
pub const ParseError = error{ UnknownUnicodeProperty, UnsupportedUnicodeProperty };

// --- Loose name matching (UAX #44-LM3) -------------------------------------

/// Normalize a property or value name: lowercase, drop spaces / `_` / `-`.
/// A leading "is" is handled by the lookups (tried with and without).
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

const GcResult = union(enum) {
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
fn lookupGc(norm: []const u8) ?GcResult {
    const eq = std.mem.eql;
    const Entry = struct { []const u8, GcResult };
    const table = [_]Entry{
        // Super-categories
        .{ "l", .{ .cats = L } },                           .{ "letter", .{ .cats = L } },
        .{ "lc", .{ .cats = LC } },                         .{ "casedletter", .{ .cats = LC } },
        .{ "l&", .{ .cats = LC } },                         .{ "m", .{ .cats = M } },
        .{ "mark", .{ .cats = M } },                        .{ "combiningmark", .{ .cats = M } },
        .{ "n", .{ .cats = N } },                           .{ "number", .{ .cats = N } },
        .{ "p", .{ .cats = P } },                           .{ "punctuation", .{ .cats = P } },
        .{ "punct", .{ .cats = P } },                       .{ "s", .{ .cats = S } },
        .{ "symbol", .{ .cats = S } },                      .{ "z", .{ .cats = Z } },
        .{ "separator", .{ .cats = Z } },                   .{ "c", .{ .cats = C } },
        .{ "other", .{ .cats = C } },
        // Letters
        .{ "lu", .{ .cats = one(.Lu) } },                   .{ "uppercaseletter", .{ .cats = one(.Lu) } },
        .{ "ll", .{ .cats = one(.Ll) } },                   .{ "lowercaseletter", .{ .cats = one(.Ll) } },
        .{ "lt", .{ .cats = one(.Lt) } },                   .{ "titlecaseletter", .{ .cats = one(.Lt) } },
        .{ "lm", .{ .cats = one(.Lm) } },                   .{ "modifierletter", .{ .cats = one(.Lm) } },
        .{ "lo", .{ .cats = one(.Lo) } },                   .{ "otherletter", .{ .cats = one(.Lo) } },
        // Marks
        .{ "mn", .{ .cats = one(.Mn) } },                   .{ "nonspacingmark", .{ .cats = one(.Mn) } },
        .{ "mc", .{ .cats = one(.Mc) } },                   .{ "spacingmark", .{ .cats = one(.Mc) } },
        .{ "me", .{ .cats = one(.Me) } },                   .{ "enclosingmark", .{ .cats = one(.Me) } },
        // Numbers
        .{ "nd", .{ .cats = one(.Nd) } },                   .{ "decimalnumber", .{ .cats = one(.Nd) } },
        .{ "digit", .{ .cats = one(.Nd) } },                .{ "nl", .{ .cats = one(.Nl) } },
        .{ "letternumber", .{ .cats = one(.Nl) } },         .{ "no", .{ .cats = one(.No) } },
        .{ "othernumber", .{ .cats = one(.No) } },
        // Punctuation
        .{ "pc", .{ .cats = one(.Pc) } },                   .{ "connectorpunctuation", .{ .cats = one(.Pc) } },
        .{ "pd", .{ .cats = one(.Pd) } },                   .{ "dashpunctuation", .{ .cats = one(.Pd) } },
        .{ "ps", .{ .cats = one(.Ps) } },                   .{ "openpunctuation", .{ .cats = one(.Ps) } },
        .{ "pe", .{ .cats = one(.Pe) } },                   .{ "closepunctuation", .{ .cats = one(.Pe) } },
        .{ "pi", .{ .cats = one(.Pi) } },                   .{ "initialpunctuation", .{ .cats = one(.Pi) } },
        .{ "pf", .{ .cats = one(.Pf) } },                   .{ "finalpunctuation", .{ .cats = one(.Pf) } },
        .{ "po", .{ .cats = one(.Po) } },                   .{ "otherpunctuation", .{ .cats = one(.Po) } },
        // Symbols
        .{ "sm", .{ .cats = one(.Sm) } },                   .{ "mathsymbol", .{ .cats = one(.Sm) } },
        .{ "sc", .{ .cats = one(.Sc) } },                   .{ "currencysymbol", .{ .cats = one(.Sc) } },
        .{ "sk", .{ .cats = one(.Sk) } },                   .{ "modifiersymbol", .{ .cats = one(.Sk) } },
        .{ "so", .{ .cats = one(.So) } },                   .{ "othersymbol", .{ .cats = one(.So) } },
        // Separators
        .{ "zs", .{ .cats = one(.Zs) } },                   .{ "spaceseparator", .{ .cats = one(.Zs) } },
        .{ "zl", .{ .cats = one(.Zl) } },                   .{ "lineseparator", .{ .cats = one(.Zl) } },
        .{ "zp", .{ .cats = one(.Zp) } },                   .{ "paragraphseparator", .{ .cats = one(.Zp) } },
        // Other
        .{ "cc", .{ .cats = one(.Cc) } },                   .{ "control", .{ .cats = one(.Cc) } },
        .{ "cntrl", .{ .cats = one(.Cc) } },                .{ "cf", .{ .cats = one(.Cf) } },
        .{ "format", .{ .cats = one(.Cf) } },               .{ "cs", .{ .cats = one(.Cs) } },
        .{ "surrogate", .{ .cats = one(.Cs) } },            .{ "co", .{ .cats = one(.Co) } },
        .{ "privateuse", .{ .cats = one(.Co) } },           .{ "cn", .{ .cats = one(.Cn) } },
        .{ "unassigned", .{ .cats = one(.Cn) } },
        // Special values
        .{ "any", .{ .special = .any } },                   .{ "ascii", .{ .special = .ascii } },
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

/// Binary search a generated, name-sorted alias table.
fn lookupNamed(comptime Entry: type, table: []const Entry, norm: []const u8) ?@FieldType(Entry, "id") {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, table[mid].name, norm)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return table[mid].id,
        }
    }
    return null;
}

fn lookupScript(norm: []const u8) ?tables.Script {
    if (lookupNamed(tables.ScriptName, &tables.script_names, norm)) |s| return s;
    if (norm.len > 2 and std.mem.startsWith(u8, norm, "is"))
        return lookupNamed(tables.ScriptName, &tables.script_names, norm[2..]);
    return null;
}

fn lookupBinary(norm: []const u8) ?tables.BinaryProp {
    if (lookupNamed(tables.BinaryName, &tables.binary_names, norm)) |p| return p;
    if (norm.len > 2 and std.mem.startsWith(u8, norm, "is"))
        return lookupNamed(tables.BinaryName, &tables.binary_names, norm[2..]);
    return null;
}

// --- Spec grammar ----------------------------------------------------------

/// A resolved property query.
pub const Query = union(enum) {
    cats: []const Cat,
    special: Special,
    script: tables.Script,
    scx: tables.Script,
    binary: tables.BinaryProp,
};

/// Parsed `\p{...}` spec: the query and whether the overall set is negated
/// (folding `\P`, a leading `^`, `!=`, a binary `=No`, and an enclosing `[^]`).
pub const Parsed = struct { query: Query, negated: bool };

/// Parse the text inside `\p{...}` (or a single letter for `\pX`). Full
/// codepoint-mode grammar (see the module doc). Non-allocating (stack scratch
/// only), so it runs inside the comptime `Pattern` bake.
pub fn parseSpec(spec: []const u8, outer_negated: bool) ParseError!Parsed {
    var s = std.mem.trim(u8, spec, " \t");
    if (s.len == 0) return error.UnknownUnicodeProperty;

    var negated = outer_negated;
    if (s[0] == '^') {
        negated = !negated;
        s = std.mem.trim(u8, s[1..], " \t");
        if (s.len == 0) return error.UnknownUnicodeProperty;
    }

    var nbuf: [64]u8 = undefined;
    var vbuf: [64]u8 = undefined;

    // `property=value` / `property:value` / `property!=value`.
    if (std.mem.indexOfAny(u8, s, "=:")) |eq_idx| {
        var prop_end = eq_idx;
        if (s[eq_idx] == '=' and eq_idx > 0 and s[eq_idx - 1] == '!') {
            negated = !negated;
            prop_end -= 1;
        }
        const prop = normalize(&nbuf, s[0..prop_end]);
        const value = normalize(&vbuf, std.mem.trim(u8, s[eq_idx + 1 ..], " \t"));
        if (value.len == 0) return error.UnknownUnicodeProperty;
        const eq = std.mem.eql;
        if (eq(u8, prop, "gc") or eq(u8, prop, "generalcategory")) {
            const g = lookupGc(value) orelse return error.UnknownUnicodeProperty;
            return .{ .query = switch (g) {
                .cats => |c| .{ .cats = c },
                .special => |sp| .{ .special = sp },
            }, .negated = negated };
        }
        if (eq(u8, prop, "sc") or eq(u8, prop, "script")) {
            const sc = lookupScript(value) orelse return error.UnknownUnicodeProperty;
            return .{ .query = .{ .script = sc }, .negated = negated };
        }
        if (eq(u8, prop, "scx") or eq(u8, prop, "scriptextensions")) {
            const sc = lookupScript(value) orelse return error.UnknownUnicodeProperty;
            return .{ .query = .{ .scx = sc }, .negated = negated };
        }
        if (lookupBinary(prop)) |bp| {
            // `Alphabetic=Yes` / `=No` (and the y/n/t/f/true/false spellings).
            const yes = eq(u8, value, "y") or eq(u8, value, "yes") or eq(u8, value, "t") or eq(u8, value, "true");
            const no = eq(u8, value, "n") or eq(u8, value, "no") or eq(u8, value, "f") or eq(u8, value, "false");
            if (!yes and !no) return error.UnknownUnicodeProperty;
            return .{ .query = .{ .binary = bp }, .negated = if (no) !negated else negated };
        }
        return error.UnknownUnicodeProperty;
    }

    // Bare value: special / gc → binary property → script.
    const norm = normalize(&vbuf, s);
    if (lookupGc(norm)) |g| {
        return .{ .query = switch (g) {
            .cats => |c| .{ .cats = c },
            .special => |sp| .{ .special = sp },
        }, .negated = negated };
    }
    if (lookupBinary(norm)) |bp| return .{ .query = .{ .binary = bp }, .negated = negated };
    if (lookupScript(norm)) |sc| return .{ .query = .{ .script = sc }, .negated = negated };
    return error.UnknownUnicodeProperty;
}

/// Byte-mode spec parser: the same grammar, but anything outside
/// General_Category / the specials is `UnsupportedUnicodeProperty` (the frozen
/// byte-mode contract — scripts and binary properties are "valid but not
/// available without `(?u)`").
fn parseSpecLatin1(spec: []const u8, outer_negated: bool) ParseError!Parsed {
    const p = try parseSpec(spec, outer_negated);
    return switch (p.query) {
        .cats, .special => p,
        .script, .scx, .binary => error.UnsupportedUnicodeProperty,
    };
}

// --- Range-set construction ------------------------------------------------

/// Append the raw (unnormalized) ranges of `q` to `buf`. `.assigned` is
/// appended as `Cn` — the caller flips negation (assigned = ¬Cn).
fn appendQuery(buf: anytype, q: Query) uset.Error!void {
    switch (q) {
        .cats => |cats| for (cats) |c| try buf.appendTable(tables.rangesFor(c)),
        .special => |sp| switch (sp) {
            .any => try buf.append(.{ .lo = 0, .hi = common.MAX_CODEPOINT }),
            .ascii => try buf.append(.{ .lo = 0, .hi = 0x7F }),
            .assigned => try buf.appendTable(tables.rangesFor(.Cn)),
        },
        .script => |sc| try buf.appendTable(tables.scriptRanges(sc)),
        .scx => |sc| try buf.appendTable(tables.scxRanges(sc)),
        .binary => |bp| try buf.appendTable(tables.binaryRanges(bp)),
    }
}

/// Resolve `parsed` into `out` (cleared first): a normalized, surrogate-free
/// set with the negation folded in. `scratch` is a second `RangeBuf` the
/// complement step clobbers. Both are `unicode_set.RangeBuf(…)` values.
pub fn resolveInto(out: anytype, scratch: anytype, parsed: Parsed) uset.Error!void {
    out.clear();
    var negated = parsed.negated;
    if (parsed.query == .special and parsed.query.special == .assigned) negated = !negated;
    try appendQuery(out, parsed.query);
    try uset.normalize(out);
    if (negated) {
        try uset.complement(out.items(), scratch);
        try out.setFrom(scratch.items());
    }
}

/// Allocating convenience over `parseSpec` + `resolveInto` (full Unicode).
/// Caller owns the returned slice.
pub fn resolve(
    a: std.mem.Allocator,
    spec: []const u8,
    outer_negated: bool,
) ![]CodepointRange {
    const parsed = try parseSpec(spec, outer_negated);
    var out = uset.RangeBuf(null).init(a);
    defer out.deinit();
    var scratch = uset.RangeBuf(null).init(a);
    defer scratch.deinit();
    resolveInto(&out, &scratch, parsed) catch return error.OutOfMemory;
    return a.dupe(CodepointRange, out.items());
}

/// Allocator-free byte-mode resolution of `\p{spec}` straight to its
/// **Latin-1 byte set** (codepoints 0..0xFF ∩ property) — the engine's
/// byte-oriented `\p` semantics, byte-identical to `resolve(...)` clipped to
/// ≤0xFF and rasterised. Never touches an allocator, so the comptime
/// `Pattern` pipeline bakes `\p` exactly like `[a-z]`. Only
/// General_Category / specials are available here (see `parseSpecLatin1`).
pub fn resolveLatin1Bitmap(spec: []const u8, outer_negated: bool) ParseError![32]u8 {
    const parsed = try parseSpecLatin1(spec, outer_negated);

    var bm: [32]u8 = @splat(0);
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
    switch (parsed.query) {
        .cats => |cats| for (cats) |c| B.cat(&bm, c),
        .special => |sp| switch (sp) {
            .any => @memset(&bm, 0xFF),
            .ascii => B.setRange(&bm, 0, 0x7F),
            .assigned => { // assigned = ¬Cn
                B.cat(&bm, .Cn);
                B.invert(&bm);
            },
        },
        .script, .scx, .binary => unreachable, // rejected by parseSpecLatin1
    }
    if (parsed.negated) B.invert(&bm);
    return bm;
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

fn has(r: []const CodepointRange, cp: u21) bool {
    return uset.contains(r, cp);
}

test "resolve general category Lu" {
    const r = try resolve(testing.allocator, "Lu", false);
    defer testing.allocator.free(r);
    try testing.expect(has(r, 'A'));
    try testing.expect(has(r, 0x0391)); // GREEK CAPITAL ALPHA
    try testing.expect(!has(r, 'a'));
    try testing.expect(!has(r, '0'));
}

test "resolve loose names and aliases" {
    inline for (.{ "Letter", "letter", "general_category=L", "gc=Letter", "  L  ", "IsLetter", "gc:L" }) |spec| {
        const r = try resolve(testing.allocator, spec, false);
        defer testing.allocator.free(r);
        try testing.expect(has(r, 'Q'));
        try testing.expect(has(r, 0x4E2D)); // CJK 中
        try testing.expect(!has(r, '5'));
    }
    const lc = try resolve(testing.allocator, "L&", false);
    defer testing.allocator.free(lc);
    try testing.expect(has(lc, 'a') and has(lc, 'A') and !has(lc, 0x4E2D));
}

test "negation forms agree" {
    const a = testing.allocator;
    const p = try resolve(a, "L", true); // \P{L}
    defer a.free(p);
    const c = try resolve(a, "^L", false); // \p{^L}
    defer a.free(c);
    const ne = try resolve(a, "gc!=L", false); // \p{gc!=L}
    defer a.free(ne);
    for ([_]u21{ 'a', 'Z', '0', ' ', 0x4E2D, 0x1F600 }) |cp| {
        try testing.expectEqual(has(p, cp), has(c, cp));
        try testing.expectEqual(has(p, cp), has(ne, cp));
    }
    try testing.expect(has(p, '0'));
    try testing.expect(!has(p, 'a'));
    try testing.expect(!has(p, 0xD800)); // surrogates never match
}

test "scripts, script extensions, binary properties" {
    const a = testing.allocator;
    const greek = try resolve(a, "Greek", false);
    defer a.free(greek);
    try testing.expect(has(greek, 0x3B1) and !has(greek, 'a'));
    const grek = try resolve(a, "sc=Grek", false);
    defer a.free(grek);
    try testing.expectEqual(greek.len, grek.len);
    const han = try resolve(a, "Script:Han", false);
    defer a.free(han);
    try testing.expect(has(han, 0x4E2D));
    // U+30FC KATAKANA-HIRAGANA PROLONGED SOUND MARK: sc=Common, scx={Hira, Kana}.
    const hira = try resolve(a, "Hiragana", false);
    defer a.free(hira);
    const hira_x = try resolve(a, "scx=Hira", false);
    defer a.free(hira_x);
    try testing.expect(!has(hira, 0x30FC));
    try testing.expect(has(hira_x, 0x30FC));
    try testing.expect(has(hira_x, 0x3042)); // あ
    const ws = try resolve(a, "White_Space", false);
    defer a.free(ws);
    try testing.expect(has(ws, ' ') and has(ws, 0x2028) and has(ws, 0x85) and !has(ws, 'a'));
    const alpha = try resolve(a, "alpha", false); // alias of Alphabetic
    defer a.free(alpha);
    try testing.expect(has(alpha, 'a') and has(alpha, 0x4E2D) and !has(alpha, '1'));
    const not_alpha = try resolve(a, "Alphabetic=No", false);
    defer a.free(not_alpha);
    try testing.expect(!has(not_alpha, 'a') and has(not_alpha, '1'));
    const emoji = try resolve(a, "Emoji_Presentation", false);
    defer a.free(emoji);
    try testing.expect(has(emoji, 0x1F600));
    const unk = try resolve(a, "Unknown", false);
    defer a.free(unk);
    try testing.expect(has(unk, 0x0378)); // unassigned Greek slot
    try testing.expect(!has(unk, 'a'));
}

test "specials: Any / ASCII / Assigned" {
    const a = testing.allocator;
    const any = try resolve(a, "Any", false);
    defer a.free(any);
    try testing.expectEqual(@as(u32, 0x110000 - 0x800), uset.count(any));
    const asc = try resolve(a, "ASCII", false);
    defer a.free(asc);
    try testing.expectEqual(@as(u32, 128), uset.count(asc));
    const assigned = try resolve(a, "Assigned", false);
    defer a.free(assigned);
    try testing.expect(has(assigned, 'a') and !has(assigned, 0x0378));
    const unassigned = try resolve(a, "Assigned", true);
    defer a.free(unassigned);
    try testing.expect(!has(unassigned, 'a') and has(unassigned, 0x0378));
}

test "ambiguous short names resolve to general categories" {
    const a = testing.allocator;
    const sc = try resolve(a, "Sc", false); // Currency_Symbol, not Script
    defer a.free(sc);
    try testing.expect(has(sc, '$') and !has(sc, 'a'));
    const cf = try resolve(a, "Cf", false); // Format
    defer a.free(cf);
    try testing.expect(has(cf, 0x200D));
}

test "unknown property" {
    try testing.expectError(error.UnknownUnicodeProperty, resolve(testing.allocator, "Frobnicate", false));
    try testing.expectError(error.UnknownUnicodeProperty, resolve(testing.allocator, "sc=Frob", false));
    try testing.expectError(error.UnknownUnicodeProperty, resolve(testing.allocator, "Alphabetic=maybe", false));
    try testing.expectError(error.UnknownUnicodeProperty, resolve(testing.allocator, "", false));
}

test "byte-mode Latin-1 bitmap: gc only, scripts/binary unsupported" {
    const bm = try resolveLatin1Bitmap("L", false);
    try testing.expect(common.hasBit(&bm, 'a'));
    try testing.expect(common.hasBit(&bm, 0xC0)); // À
    try testing.expect(!common.hasBit(&bm, 0xB7)); // ·
    const nl = try resolveLatin1Bitmap("L", true);
    try testing.expect(!common.hasBit(&nl, 'a'));
    try testing.expect(common.hasBit(&nl, 0xB7));
    try testing.expectError(error.UnsupportedUnicodeProperty, resolveLatin1Bitmap("Greek", false));
    try testing.expectError(error.UnsupportedUnicodeProperty, resolveLatin1Bitmap("Script=Han", false));
    try testing.expectError(error.UnsupportedUnicodeProperty, resolveLatin1Bitmap("White_Space", false));
    try testing.expectError(error.UnknownUnicodeProperty, resolveLatin1Bitmap("Frobnicate", false));
    // Equivalent to the full resolution clipped to ≤0xFF.
    const full = try resolve(testing.allocator, "N", false);
    defer testing.allocator.free(full);
    const nb = try resolveLatin1Bitmap("N", false);
    var c: u32 = 0;
    while (c < 256) : (c += 1) try testing.expectEqual(has(full, @intCast(c)), common.hasBit(&nb, @intCast(c)));
}

test "comptime resolution into fixed buffers" {
    const r = comptime blk: {
        @setEvalBranchQuota(200_000);
        var out = uset.RangeBuf(1024).init(undefined);
        var scratch = uset.RangeBuf(1024).init(undefined);
        const parsed = parseSpec("Greek", false) catch unreachable;
        resolveInto(&out, &scratch, parsed) catch unreachable;
        break :blk .{ .n = out.len(), .alpha = uset.contains(out.items(), 0x3B1), .a = uset.contains(out.items(), 'a') };
    };
    try testing.expect(r.n > 0 and r.alpha and !r.a);
}
