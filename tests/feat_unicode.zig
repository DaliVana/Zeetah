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
        "",       "  abc 123",  "ab  123!cd", "7x9",
        "ABCdef", "\xC0\xB7z",  "Word42 ",    "ab 12!",
    };
    inline for (pats) |p| {
        const P = regex.Pattern(p, .{});
        comptime std.debug.assert(P.has_dfa); // baked, not rejected
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

// The `.unicode` compile flag selects codepoint-aware `(?u)` mode — full
// multibyte `\p`, scripts, binary properties and Unicode simple case-folding —
// the documented follow-on to this byte-oriented engine, not yet implemented.
// Its sibling struct flags (`.case_insensitive`/`.dot_all`/`.extended`/
// `.multiline`) all compile; only `.unicode` is rejected.
test "unicode: .unicode codepoint-mode compile flag rejected (the (?u) follow-on)" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.NotImplemented, Regex.compileWithFlags(a, "ab", .{ .unicode = true }));
}
