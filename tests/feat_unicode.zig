//! Per-feature: Unicode General_Category `\p{…}` / `\P{…}` (Phase B).
//!
//! The engine is byte-oriented, so `\p` is the **Latin-1 byte restriction**
//! of the property (codepoints 0..0xFF ∩ category) — exactly Rust/RE2 with
//! Unicode-mode off. Codepoint-aware multibyte `\p` is the documented `(?u)`
//! follow-on. The resolver is allocator-free, so comptime `Pattern` bakes
//! `\p` exactly like `[a-z]`; only `\p` under `(?i)` (and unknown/unsupported
//! names) stays a typed error.

const std = @import("std");
const regex = @import("zeetah");
const Regex = regex.Regex;

fn slice(a: std.mem.Allocator, pat: []const u8, in: []const u8) !?[]const u8 {
    var rx = try Regex.compile(a, pat);
    defer rx.deinit();
    var m = try rx.find(in);
    defer if (m) |*mm| mm.deinit(a);
    if (m) |mm| return mm.slice;
    return null;
}

fn isM(a: std.mem.Allocator, pat: []const u8, in: []const u8) !bool {
    var rx = try Regex.compile(a, pat);
    defer rx.deinit();
    return rx.isMatch(in);
}

test "unicode: \\p{L} / \\pL letters, \\P{L} non-letters" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("abc", (try slice(a, "\\p{L}+", "  abc 123")).?);
    try std.testing.expectEqualStrings("x", (try slice(a, "\\pL", "7x9")).?);
    try std.testing.expectEqualStrings("  123!", (try slice(a, "\\P{L}+", "ab  123!cd")).?);
    try std.testing.expect(!try isM(a, "\\p{L}", "123 456"));
}

test "unicode: case sub-categories Lu / Ll" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("C", (try slice(a, "\\p{Lu}", "abCdef")).?);
    try std.testing.expectEqualStrings("ab", (try slice(a, "\\p{Ll}+", "abCD")).?);
    try std.testing.expectEqualStrings("ABC", (try slice(a, "\\p{Lu}+", "ABCdef")).?);
}

test "unicode: \\p{N} / \\p{Nd} numbers (ASCII subset in byte mode)" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("123", (try slice(a, "\\p{N}+", "abc123def")).?);
    try std.testing.expectEqualStrings("42", (try slice(a, "\\p{Nd}+", "x42y")).?);
}

test "unicode: \\P{N} double-negation and \\p{^L} internal negation" {
    const a = std.testing.allocator;
    // \p{^L} == \P{L}
    try std.testing.expectEqualStrings(
        (try slice(a, "\\P{L}+", "ab 12!")).?,
        (try slice(a, "\\p{^L}+", "ab 12!")).?,
    );
    // \P{N}+ skips the digit run
    try std.testing.expectEqualStrings("abc", (try slice(a, "\\P{N}+", "abc12")).?);
}

test "unicode: Latin-1 high bytes are letters byte-wise" {
    const a = std.testing.allocator;
    // 0xC0 = 'À' (U+00C0, Lu) in Latin-1 / codepoint space → a member byte.
    try std.testing.expect(try isM(a, "\\p{L}", "\xC0"));
    // 0xB7 = '·' (U+00B7, Po) — not a letter.
    try std.testing.expect(!try isM(a, "\\p{L}", "\xB7"));
}

test "unicode: \\p concatenated and quantified in a larger pattern" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("aXc", (try slice(a, "a\\p{L}c", "zaXc!")).?);
    try std.testing.expectEqualStrings("Word42", (try slice(a, "\\p{L}+\\p{N}+", " Word42 ")).?);
}

test "unicode: \\p{…} inside a character class (positive + negated)" {
    const a = std.testing.allocator;
    // In-class `\p` ORs the property's Latin-1 byte set into the class;
    // `\P` ORs its complement; an outer `[^…]` still inverts the whole set.
    // Semantics are byte-identical to the standalone-`\p` path.
    try std.testing.expectEqualStrings("abc123", (try slice(a, "[\\p{L}\\p{N}]+", "  abc123!!")).?);
    try std.testing.expectEqualStrings("  ..", (try slice(a, "[^\\p{L}\\p{N}]+", "abc  ..def")).?);
    try std.testing.expectEqualStrings("123", (try slice(a, "[\\P{L}]+", "ab123cd")).?);
    try std.testing.expectEqualStrings("  .;", (try slice(a, "[^\\r\\n\\p{L}\\p{N}]+", "ab12  .;cd")).?);
    try std.testing.expectEqualStrings("AB12", (try slice(a, "[\\p{Lu}\\d]+", "abAB12cd")).?);
    // `[\p{L}]` ≡ `\p{L}` (same byte set, mixed with literals/ranges OK).
    try std.testing.expectEqualStrings(
        (try slice(a, "\\p{L}+", "  abc 9")).?,
        (try slice(a, "[\\p{L}]+", "  abc 9")).?,
    );
}

test "unicode: comptime Pattern bakes \\p and agrees with runtime Regex" {
    const a = std.testing.allocator;
    // \p is a regular Latin-1 byte set — the allocator-free resolver lets the
    // comptime pipeline bake it exactly like [a-z]. Pin comptime⇄runtime
    // agreement across category, sub-category, negation, in-class, and the
    // \p{^L}==\P{L} internal-negation identity.
    const pats = .{ "\\p{L}+", "\\P{N}+", "\\pL", "\\p{Lu}+", "[\\p{L}\\p{N}]+", "\\p{^L}+" };
    const ins = [_][]const u8{
        "",       "  abc 123", "ab  123!cd", "7x9",
        "ABCdef", "\xC0\xB7z", "Word42 ",    "ab 12!",
    };
    inline for (pats) |p| {
        const P = regex.Pattern(p, .{});
        // baked, not rejected (a DFA, or the DFA-free `.class_span` arm for `\p{L}+`)
        comptime std.debug.assert(P.has_dfa or @hasDecl(P, "class_span_mode"));
        var rx = try Regex.compile(a, p);
        defer rx.deinit();
        for (ins) |in| {
            try std.testing.expectEqual(P.isMatch(in), try rx.isMatch(in));
            const pm = P.find(in);
            var rm = try rx.find(in);
            defer if (rm) |*x| x.deinit(a);
            try std.testing.expectEqual(pm == null, rm == null);
            if (pm) |pmm| {
                try std.testing.expectEqual(pmm.start, rm.?.start);
                try std.testing.expectEqual(pmm.end, rm.?.end);
            }
        }
    }
}

test "unicode: unsupported / unknown / (?i) stay typed errors" {
    const a = std.testing.allocator;
    // Scripts and binary properties live outside the Latin-1 byte window the
    // engine models, so they are recognised-but-unsupported; unknown names and
    // `\p` under (?i) (full simple-fold is the (?u) follow-on) reject likewise.
    try std.testing.expectError(error.NotImplemented, Regex.compile(a, "\\p{Greek}")); // script
    try std.testing.expectError(error.NotImplemented, Regex.compile(a, "\\p{White_Space}")); // binary prop
    try std.testing.expectError(error.NotImplemented, Regex.compile(a, "\\p{Frobnicate}")); // unknown name
    try std.testing.expectError(error.NotImplemented, Regex.compile(a, "(?i)\\p{L}"));
    // `\p` inside a class also obeys the `(?i)` follow-on restriction.
    try std.testing.expectError(error.NotImplemented, Regex.compile(a, "(?i)[\\p{L}]"));
}

// ───────────────────────────── codepoint mode `(?u)` ─────────────────────────
//
// Everything below is opt-in: the `.unicode` compile flag, `PatternOptions.unicode`
// or an inline `(?u)`. The byte-mode tests above are the frozen contract and must
// keep passing verbatim.

const U: regex.CompileFlags = .{ .unicode = true };

fn compileU(a: std.mem.Allocator, pat: []const u8) !Regex {
    return Regex.compileWithFlags(a, pat, U);
}

/// All non-overlapping match slices of `pat` (compiled with `flags`) in `in`.
fn allU(a: std.mem.Allocator, pat: []const u8, flags: regex.CompileFlags, in: []const u8, expected: []const []const u8) !void {
    var rx = try Regex.compileWithFlags(a, pat, flags);
    defer rx.deinit();
    const ms = try rx.findAll(a, in);
    defer a.free(ms);
    std.testing.expectEqual(expected.len, ms.len) catch |e| {
        std.debug.print("pattern {s}: got {d} matches:", .{ pat, ms.len });
        for (ms) |m| std.debug.print(" [{s}]", .{m.slice});
        std.debug.print("\n", .{});
        return e;
    };
    for (expected, ms) |want, got| try std.testing.expectEqualStrings(want, got.slice);
}

fn sliceU(a: std.mem.Allocator, pat: []const u8, in: []const u8) !?[]const u8 {
    var rx = try compileU(a, pat);
    defer rx.deinit();
    var m = try rx.find(in);
    defer if (m) |*mm| mm.deinit(a);
    if (m) |mm| return mm.slice;
    return null;
}

fn isMU(a: std.mem.Allocator, pat: []const u8, in: []const u8) !bool {
    var rx = try compileU(a, pat);
    defer rx.deinit();
    return rx.isMatch(in);
}

test "(?u): the .unicode flag and inline (?u) are accepted and equivalent" {
    const a = std.testing.allocator;
    var f = try Regex.compileWithFlags(a, ".", U);
    defer f.deinit();
    var i = try Regex.compile(a, "(?u).");
    defer i.deinit();
    const in = "aé中😀";
    try std.testing.expectEqual(@as(usize, 4), try f.count(in));
    try std.testing.expectEqual(@as(usize, 4), try i.count(in));
    // Byte mode is unchanged: one match per byte.
    var b = try Regex.compile(a, ".");
    defer b.deinit();
    try std.testing.expectEqual(@as(usize, in.len), try b.count(in));
}

test "(?u): `.` and `\\N` are one scalar; (?s) adds \\n; invalid bytes never match" {
    const a = std.testing.allocator;
    try allU(a, ".", U, "é", &.{"é"});
    try allU(a, "a.b", U, "aéb a中b a😀b a\nb", &.{ "aéb", "a中b", "a😀b" });
    try allU(a, "(?s)a.b", U, "a\nb", &.{"a\nb"});
    try allU(a, "\\N", U, "é\n", &.{"é"});
    // An invalid byte is not a scalar: `.` skips it (RE2 / Rust behaviour).
    try allU(a, ".", U, "a\xFFb", &.{ "a", "b" });
    try allU(a, ".", U, "\xC3", &.{}); // truncated sequence
    try allU(a, ".", U, "\xED\xA0\x80", &.{}); // encoded surrogate
    try allU(a, ".", U, "\xC0\xAF", &.{}); // overlong '/'
    // `.{3}` counts scalars, not bytes.
    try allU(a, "^.{3}$", U, "é中😀", &.{"é中😀"});
    try std.testing.expect(!try isMU(a, "^.{3}$", "éé"));
}

test "(?u): \\d \\w \\s take the UTS #18 Annex C definitions" {
    const a = std.testing.allocator;
    try allU(a, "\\w+", U, "café 中文 ١٢٣ e\u{301} ab_c", &.{ "café", "中文", "١٢٣", "e\u{301}", "ab_c" });
    try allU(a, "\\d+", U, "١٢٣ 456 Ⅻ", &.{ "١٢٣", "456" }); // Ⅻ is Nl, not Nd
    try allU(a, "\\s", U, " \u{85}\u{2028}\u{A0}\u{200B}\u{3000}", &.{ " ", "\u{85}", "\u{2028}", "\u{A0}", "\u{3000}" }); // ZWSP is not White_Space
    try allU(a, "\\W+", U, "ab—cd", &.{"—"});
    try allU(a, "\\D+", U, "١a٢", &.{"a"});
    try allU(a, "\\S+", U, "é\u{3000}中", &.{ "é", "中" });
    // Byte mode is unchanged.
    try allU(a, "\\w+", .{}, "café", &.{"caf"});
}

test "(?u): \\b / \\B are Unicode word boundaries" {
    const a = std.testing.allocator;
    try allU(a, "\\b\\w+\\b", U, "naïve café", &.{ "naïve", "café" });
    try allU(a, "\\bca", U, "éca ca", &.{"ca"}); // é is a word char: no boundary before "ca"
    try allU(a, "\\B.", U, "aé", &.{"é"});
    // An undecodable neighbour is a non-word character.
    try allU(a, "\\bab\\b", U, "\xFFab\xFF", &.{"ab"});
    // Mixed with regular text / captures / anchors.
    try allU(a, "\\b(\\p{L}+)\\b", U, "日本語 text", &.{ "日本語", "text" });
    // Byte mode is unchanged.
    try allU(a, "\\b\\w+\\b", .{}, "café", &.{"caf"});
}

test "(?u): \\p — general categories, scripts, script extensions, binary properties, aliases" {
    const a = std.testing.allocator;
    try allU(a, "\\p{L}+", U, "abc 中文 ١٢٣ αβγ", &.{ "abc", "中文", "αβγ" });
    try allU(a, "\\p{Letter}+", U, "abc1", &.{"abc"});
    try allU(a, "\\pL+", U, "abc1", &.{"abc"});
    try allU(a, "\\p{Greek}+", U, "abc αβγ", &.{"αβγ"});
    try allU(a, "\\p{sc=Grek}+", U, "abc αβγ", &.{"αβγ"});
    try allU(a, "\\p{Script:Han}+", U, "日本語 かな", &.{"日本語"});
    try allU(a, "\\p{IsCyrillic}+", U, "Привет мир", &.{ "Привет", "мир" });
    // U+30FC is Common but has scx = {Hiragana, Katakana}.
    try allU(a, "\\p{Hiragana}+", U, "か\u{30FC}な", &.{ "か", "な" });
    try allU(a, "\\p{scx=Hira}+", U, "か\u{30FC}な", &.{"か\u{30FC}な"});
    try allU(a, "\\p{Alphabetic}+", U, "ab ١ 中", &.{ "ab", "中" });
    try allU(a, "\\p{alpha}+", U, "ab ١ 中", &.{ "ab", "中" });
    try allU(a, "\\p{White_Space}", U, "a b", &.{" "});
    try allU(a, "\\p{Emoji_Presentation}+", U, "hi 😀🎉 x", &.{"😀🎉"});
    try allU(a, "\\p{Nd}+", U, "x١٢٣y", &.{"١٢٣"});
    try allU(a, "\\p{Lu}", U, "aBcΣ", &.{ "B", "Σ" });
    try allU(a, "\\p{Any}", U, "a😀", &.{ "a", "😀" });
    try allU(a, "\\p{ASCII}+", U, "abcé", &.{"abc"});
    try allU(a, "\\p{Assigned}", U, "a\u{378}", &.{"a"}); // U+0378 is unassigned
}

test "(?u): \\P, \\p{^…}, != and =No negations agree" {
    const a = std.testing.allocator;
    const in = "ab 12 中 — ١";
    try allU(a, "\\P{L}+", U, in, &.{ " 12 ", " — ١" });
    try allU(a, "\\p{^L}+", U, in, &.{ " 12 ", " — ١" });
    try allU(a, "\\p{gc!=L}+", U, in, &.{ " 12 ", " — ١" });
    try allU(a, "\\p{Alphabetic=No}+", U, in, &.{ " 12 ", " — ١" });
    try allU(a, "\\P{Alphabetic=No}+", U, in, &.{ "ab", "中" });
    // Surrogates never match even in a negated class.
    try allU(a, "\\P{L}", U, "\xED\xA0\x80", &.{});
}

test "(?u): classes — codepoint members/ranges, escapes, shorthand, nesting, set operations" {
    const a = std.testing.allocator;
    try allU(a, "[é中]+", U, "aé中b", &.{"é中"});
    try allU(a, "[à-ÿ]+", U, "aàéÿb", &.{"àéÿ"});
    try allU(a, "[^a]", U, "aéa", &.{"é"}); // the whole scalar, not a stray byte
    try allU(a, "[\\x{1F600}-\\x{1F64F}]+", U, "x😀😃y", &.{"😀😃"});
    try allU(a, "[\\p{L}\\p{N}_]+", U, "ab_中1 ٣ -", &.{ "ab_中1", "٣" });
    try allU(a, "[^\\s\\p{L}\\p{N}]+", U, "ab, 中!! ١", &.{ ",", "!!" });
    try allU(a, "[\\d\\-]+", U, "١٢-3", &.{"١٢-3"});
    try allU(a, "[a-]+", U, "a-b", &.{"a-"});
    try allU(a, "[-a]+", U, "-ab", &.{"-a"});
    // Set operations and nesting (Rust precedence: lhs = everything so far).
    try allU(a, "[\\p{L}--\\p{Lu}]+", U, "abCDef", &.{ "ab", "ef" });
    try allU(a, "[[a-z]&&[^aeiou]]+", U, "hello world", &.{ "h", "ll", "w", "rld" });
    try allU(a, "[a-z&&[^aeiou]]+", U, "hello", &.{ "h", "ll" });
    try allU(a, "[\\w~~\\d]+", U, "ab12_ ٣", &.{ "ab", "_" }); // word chars that are not digits
    try allU(a, "[[\\p{L}--[a-z]]--\\p{Lu}]+", U, "abCD中é", &.{"中é"});
    try allU(a, "[^\\p{L}--\\p{Lu}]+", U, "abCD12", &.{"CD12"}); // negation applies to the whole class
    // POSIX classes stay ASCII in codepoint mode (UTS #18 RL1.2a, like Rust);
    // their negation covers the whole scalar universe.
    try allU(a, "[[:alpha:]]+", U, "ab é 中", &.{"ab"});
    try allU(a, "[[:^alpha:]]+", U, "ab é 中", &.{" é 中"});
    // Empty class never matches.
    try allU(a, "[a--a]", U, "a", &.{});
}

test "(?u): escapes denote scalars — \\xHH, \\x{…}, \\o{…}, \\N{U+…}; bad values are InvalidPattern" {
    const a = std.testing.allocator;
    try allU(a, "\\xE9", U, "é\xE9", &.{"é"});
    try allU(a, "\\x{E9}", U, "é", &.{"é"});
    try allU(a, "\\x{1F600}", U, "a😀", &.{"😀"});
    try allU(a, "\\o{351}", U, "é", &.{"é"});
    try allU(a, "\\N{U+1F600}+", U, "😀😀", &.{"😀😀"});
    try allU(a, "[\\N{U+E9}\\x{E8}]+", U, "éè", &.{"éè"});
    try allU(a, "\\x{E9}{2}", U, "éé", &.{"éé"});
    try std.testing.expectError(error.InvalidPattern, compileU(a, "\\x{110000}"));
    try std.testing.expectError(error.InvalidPattern, compileU(a, "\\x{D800}"));
    try std.testing.expectError(error.InvalidPattern, compileU(a, "\\x{}"));
    try std.testing.expectError(error.NotImplemented, compileU(a, "\\N{LATIN SMALL LETTER A}"));
    // Malformed UTF-8 in the pattern itself is a syntax error in codepoint mode.
    try std.testing.expectError(error.InvalidPattern, compileU(a, "a\xFFb"));
    try std.testing.expectError(error.InvalidPattern, compileU(a, "[\xC3]"));
    // Byte mode keeps its reserved rejections.
    try std.testing.expectError(error.NotImplemented, Regex.compile(a, "\\x{100}"));
}

test "(?u): \\h \\v \\R use the Unicode lists" {
    const a = std.testing.allocator;
    try allU(a, "\\h", U, "a\u{3000}b\u{A0}c\u{2003}", &.{ "\u{3000}", "\u{A0}", "\u{2003}" });
    try allU(a, "\\v", U, "a\u{2028}b\u{85}c\x0B", &.{ "\u{2028}", "\u{85}", "\x0B" });
    try allU(a, "\\R", U, "a\r\nb\u{2028}c\u{85}d\u{2029}", &.{ "\r\n", "\u{2028}", "\u{85}", "\u{2029}" });
    try allU(a, "\\H+", U, "é\u{3000}中", &.{ "é", "中" });
    try allU(a, "[\\h]", U, "\u{2003}", &.{"\u{2003}"});
    // Byte mode: PCRE 8-bit sets only.
    try allU(a, "\\h", .{}, "\u{3000}", &.{});
}

test "(?iu): simple case folding — orbits, Kelvin/long-s, folded properties, no full folding" {
    const a = std.testing.allocator;
    const IU: regex.CompileFlags = .{ .unicode = true, .case_insensitive = true };
    try allU(a, "σ", IU, "Σσς", &.{ "Σ", "σ", "ς" });
    try allU(a, "k", IU, "kK\u{212A}", &.{ "k", "K", "\u{212A}" });
    try allU(a, "s", IU, "sS\u{17F}", &.{ "s", "S", "\u{17F}" });
    try allU(a, "straße", IU, "STRASSE straße STRAẞE", &.{ "straße", "STRAẞE" }); // ẞ folds to ß; "ss" does not
    try allU(a, "strasse", IU, "STRASSE straße", &.{"STRASSE"});
    try allU(a, "é", IU, "éÉ", &.{ "é", "É" });
    try allU(a, "\\p{Lu}", IU, "aB1", &.{ "a", "B" }); // the property is folded too
    try allU(a, "[^k]", IU, "K\u{212A}x", &.{"x"}); // fold BEFORE negation
    try allU(a, "[a-c]+", IU, "ABCabc", &.{"ABCabc"});
    try allU(a, "(?i:σ)σ", U, "Σσ σσ", &.{ "Σσ", "σσ" }); // scoped (?i) inside (?u)
    try allU(a, "\\x{3C3}", IU, "Σ", &.{"Σ"});
    // Byte mode folds ASCII only.
    try allU(a, "k", .{ .case_insensitive = true }, "kK\u{212A}", &.{ "k", "K" });
    try allU(a, "σ", .{ .case_insensitive = true }, "Σσ", &.{"σ"});
}

test "(?iu): backreferences compare under simple folding, with differing byte lengths" {
    const a = std.testing.allocator;
    const IU: regex.CompileFlags = .{ .unicode = true, .case_insensitive = true };
    try allU(a, "(\\w+) \\1", IU, "Straße STRAẞE", &.{"Straße STRAẞE"});
    try allU(a, "(k)\\1", IU, "k\u{212A}", &.{"k\u{212A}"}); // 1-byte group, 3-byte match
    try allU(a, "(\u{212A})\\1", IU, "\u{212A}k", &.{"\u{212A}k"});
    try allU(a, "(σ)\\1", IU, "ΣςX", &.{"Σς"});
    try allU(a, "(ab)\\1", IU, "abAB abac", &.{"abAB"});
    // Case-sensitive (?u) backrefs are exact.
    try allU(a, "(k)\\1", U, "k\u{212A} kk", &.{"kk"});
}

test "(?u): scoped toggles mix codepoint and byte mode in one pattern" {
    const a = std.testing.allocator;
    try allU(a, "a(?u:.)b", .{}, "aéb", &.{"aéb"});
    try allU(a, "x(?-u:.)", U, "x\xC3\xA9", &.{"x\xC3"});
    try allU(a, "(?u)\\w+(?-u)!\\w", .{}, "café!x", &.{"café!x"});
}

test "(?u): captures, count, findAll and replace work over scalars" {
    const a = std.testing.allocator;
    var rx = try compileU(a, "(?<w>\\p{L}+) (\\d+)");
    defer rx.deinit();
    if (try rx.captures(a, "x héllo ١٢ y")) |m| {
        var mm = m;
        defer mm.deinit(a);
        try std.testing.expectEqualStrings("héllo ١٢", mm.slice);
        try std.testing.expectEqualStrings("héllo", mm.groupByName("w").?.slice);
        try std.testing.expectEqualStrings("١٢", mm.groups[2].?.slice);
    } else return error.TestUnexpectedResult;
    var w = try compileU(a, "\\w+");
    defer w.deinit();
    try std.testing.expectEqual(@as(usize, 3), try w.count("日本語 ελληνικά café"));
    const out = try w.replaceAll(a, "日本語 café", "<$0>");
    defer a.free(out);
    try std.testing.expectEqualStrings("<日本語> <café>", out);
}

test "(?u): the verbatim GPT-4 cl100k pre-tokenizer regex segments multibyte text" {
    const a = std.testing.allocator;
    // Possessive `?+` / `++` and full-Unicode `\p` exactly as tiktoken ships it.
    const cl100k = "'(?i:[sdmt]|ll|ve|re)|[^\\r\\n\\p{L}\\p{N}]?+\\p{L}+|\\p{N}{1,3}| ?[^\\s\\p{L}\\p{N}]++[\\r\\n]*|\\s*[\\r\\n]|\\s+(?!\\S)|\\s+";
    try allU(a, cl100k, U, "Hello 世界, ça va!", &.{ "Hello", " 世界", ",", " ça", " va", "!" });
    try allU(a, cl100k, U, "١٢٣٤ don't", &.{ "١٢٣", "٤", " don", "'t" });
    try allU(a, cl100k, U, "日本語のテキスト。", &.{ "日本語のテキスト", "。" });
}

test "(?u): Unicode \\b on an input past the bounded backtracker's budget (PikeVM path)" {
    // ~300 KB × ~330 NFA states exceeds `bounded_bt.VISITED_BUDGET_BYTES`, so the
    // look search runs on the PikeVM, whose thread step must follow EVERY byte
    // edge of a UTF-8 class state (a state has one edge per lead-byte range).
    const a = std.testing.allocator;
    const chunk = "Ainput52gq\n985-11 aaaa café 中文 ";
    const reps = 300_000 / chunk.len;
    const in = try a.alloc(u8, chunk.len * reps);
    defer a.free(in);
    for (0..reps) |i| @memcpy(in[i * chunk.len ..][0..chunk.len], chunk);
    var ru = try compileU(a, "\\b\\w+\\b");
    defer ru.deinit();
    try std.testing.expectEqual(@as(usize, 6 * reps), try ru.count(in)); // 6 words per chunk
    var first = (try ru.find(in)).?;
    defer first.deinit(a);
    try std.testing.expectEqualStrings("Ainput52gq", first.slice);
    // Captures past the budget (PikeVM slot reconstruction) too.
    var rc = try compileU(a, "(\\p{L}+) (\\p{Han}+)");
    defer rc.deinit();
    if (try rc.captures(a, in)) |m| {
        var mm = m;
        defer mm.deinit(a);
        try std.testing.expectEqualStrings("café", mm.groups[1].?.slice);
        try std.testing.expectEqualStrings("中文", mm.groups[2].?.slice);
    } else return error.TestUnexpectedResult;
}

test "(?u): greedy class loops give back one scalar at a time (interpreter + compiled)" {
    const a = std.testing.allocator;
    // `\p{L}+é` must give back the trailing `é` of the run to let the literal match.
    try allU(a, "\\p{L}+é", U, "caféé x", &.{"caféé"});
    try allU(a, "\\p{L}*中", U, "日本中 中", &.{ "日本中", "中" });
    try allU(a, "(?=\\p{L}+é)\\p{L}+", U, "caféé x", &.{"caféé"}); // backtracker tier (lookahead)
    try allU(a, "(\\p{L}+)\\1", U, "ééé xx", &.{ "éé", "xx" });
    const P = regex.Pattern("(?=\\p{L}+é)\\p{L}+", .{ .unicode = true });
    try std.testing.expectEqualStrings("caféé", P.find("caféé x").?.slice);
    const Q = regex.Pattern("\\p{L}*中", .{ .unicode = true });
    try std.testing.expectEqual(@as(usize, 2), Q.count("日本中 中"));
}

test "(?u): comptime Pattern(.unicode) agrees with the runtime Regex" {
    const a = std.testing.allocator;
    const pats = .{
        ".",           "\\p{L}+",            "\\w+",                "\\b\\w+\\b",
        "[à-ÿ]+",
        "[é中]",
        "\\p{Greek}+", "[\\p{L}--\\p{Lu}]+",
        "(?i)σ",
        "(?i)k",       "\\x{1F600}",         "\\d+",                "(\\p{L}+) (\\d+)",
        "\\P{L}+",     "a.b",                "[^\\s\\p{L}\\p{N}]+", "'(?i:[sdmt]|ll|ve|re)|[^\\r\\n\\p{L}\\p{N}]?+\\p{L}+|\\p{N}{1,3}| ?[^\\s\\p{L}\\p{N}]++[\\r\\n]*|\\s*[\\r\\n]|\\s+(?!\\S)|\\s+",
    };
    const ins = [_][]const u8{
        "",       "abc",
        "café 中文 ١٢٣",
        "aéb a中b a😀b",
        "Σσς kK\u{212A}",
        "héllo ١٢ y",
        "naïve café",
        "Hello 世界, ça va!",
        "a\xFFb", "\xC3",
        "日本語のテキスト。",
        "ab, 中!! ١",
    };
    inline for (pats) |p| {
        const P = regex.Pattern(p, .{ .unicode = true });
        var rx = try compileU(a, p);
        defer rx.deinit();
        for (ins) |in| {
            try std.testing.expectEqual(try rx.isMatch(in), P.isMatch(in));
            try std.testing.expectEqual(try rx.count(in), P.count(in));
            const pm = P.find(in);
            var rm = try rx.find(in);
            defer if (rm) |*x| x.deinit(a);
            try std.testing.expectEqual(rm == null, pm == null);
            if (pm) |pmm| {
                try std.testing.expectEqual(rm.?.start, pmm.start);
                try std.testing.expectEqual(rm.?.end, pmm.end);
            }
        }
    }
}

test "(?u): comptime Pattern — small classes bake a DFA, wide ones the compiled backtracker" {
    // `[é中]` is a handful of UTF-8 sequences: fits the comptime NFA ⇒ DFA arm.
    const Small = regex.Pattern("[é中]+", .{ .unicode = true });
    comptime std.debug.assert(Small.has_dfa);
    try std.testing.expectEqualStrings("é中", Small.find("aé中b").?.slice);
    // `\p{L}` is a few hundred NFA states: over `MAX_NFA` ⇒ compiled backtracker, not a compile error.
    const Wide = regex.Pattern("\\p{L}+", .{ .unicode = true });
    comptime std.debug.assert(!Wide.has_dfa);
    try std.testing.expectEqualStrings("日本語", Wide.find("12 日本語 x").?.slice);
    try std.testing.expectEqual(@as(usize, 2), Wide.count("12 日本語 x"));
    // `compilesWith` reports the same build-ability without instantiating.
    comptime std.debug.assert(regex.compilesWith("\\p{Greek}+", .{ .unicode = true }));
    comptime std.debug.assert(!regex.compilesWith("\\p{Greek}+", .{})); // byte mode: still rejected
}
