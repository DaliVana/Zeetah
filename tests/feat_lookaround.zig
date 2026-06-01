//! Per-feature: lookaround (Phase E, .NET-model tree backtracker).
//! `(?=…)` `(?!…)` lookahead, `(?<=…)` `(?<!…)` lookbehind (fixed- AND
//! variable-width; the latter scans candidate start offsets, charged to the
//! same anti-ReDoS step budget — pathological cases surface as a typed
//! `MatchBudgetExceeded`, never a hang).

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

test "lookahead: positive (?=…) is zero-width" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("foo", (try slice(a, "foo(?=bar)", "foobar")).?);
    try std.testing.expect(!try isM(a, "foo(?=bar)", "foobaz"));
    // zero-width: the asserted text is not consumed
    try std.testing.expectEqualStrings("a", (try slice(a, "a(?=b)", "ab")).?);
}

test "lookahead: negative (?!…)" {
    const a = std.testing.allocator;
    try std.testing.expect(try isM(a, "foo(?!bar)", "foobaz"));
    try std.testing.expect(!try isM(a, "foo(?!bar)", "foobar"));
    try std.testing.expectEqualStrings("5", (try slice(a, "\\d(?!\\d)", "in 345 end")).?); // last digit of a run
}

test "lookbehind: fixed-width (?<=…) / (?<!…)" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("y", (try slice(a, "(?<=x)y", "zy xy")).?);
    try std.testing.expect(!try isM(a, "(?<=x)y", "zy"));
    try std.testing.expectEqualStrings("bar", (try slice(a, "(?<=foo)bar", "foobar")).?);
    // negative lookbehind
    try std.testing.expect(try isM(a, "(?<!a)b", "xb"));
    try std.testing.expect(!try isM(a, "(?<!a)b", "ab"));
}

test "lookaround: combined with quantifiers / anchors" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("100", (try slice(a, "\\d+(?= dollars)", "I owe 100 dollars")).?);
    try std.testing.expect(try isM(a, "^(?=.*a)(?=.*b).+$", "xayb"));
    try std.testing.expect(!try isM(a, "^(?=.*a)(?=.*b).+$", "xxyy"));
}

test "lookbehind: variable-width positive (?<=a+) / (?<=\\d+)" {
    const a = std.testing.allocator;
    // `a+` is variable width: reverse scan finds a span of `a`s ending at pos.
    try std.testing.expectEqualStrings("b", (try slice(a, "(?<=a+)b", "aaab")).?);
    try std.testing.expectEqualStrings("b", (try slice(a, "(?<=a+)b", "ab")).?);
    try std.testing.expect(!try isM(a, "(?<=a+)b", "b")); // nothing precedes index 0
    try std.testing.expectEqualStrings("x", (try slice(a, "(?<=\\d+)x", "12x")).?);
    try std.testing.expect(!try isM(a, "(?<=\\d+)x", "x"));
}

test "lookbehind: variable-width negative (?<!\\$\\d*) (ghostty $VAR case)" {
    const a = std.testing.allocator;
    // The exact construct from ghostty's URL regex bare-path branch.
    try std.testing.expectEqualStrings("5", (try slice(a, "(?<!\\$\\d*)\\d", "x5")).?);
    try std.testing.expect(!try isM(a, "(?<!\\$\\d*)\\d", "$5")); // 5 is preceded by $ (zero digits)
    // The standalone "5" (after the space) is NOT preceded by `$\d*`.
    try std.testing.expectEqualStrings("5", (try slice(a, "(?<!\\$\\d*)\\d", "$12 5")).?);
}

test "lookbehind: variable-width terminates on long input (anti-ReDoS)" {
    const a = std.testing.allocator;
    // ~2000-byte run forces the reverse scan to span many offsets; it must
    // terminate (match or typed MatchBudgetExceeded), never hang.
    const big = "a" ** 2000 ++ "b";
    const r = isM(a, "(?<=a+)b", big);
    if (r) |hit| {
        try std.testing.expect(hit);
    } else |e| {
        try std.testing.expectEqual(error.MatchBudgetExceeded, e);
    }
}
