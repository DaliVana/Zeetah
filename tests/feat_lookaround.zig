//! Per-feature: lookaround (Phase E, .NET-model tree backtracker).
//! `(?=…)` `(?!…)` lookahead, `(?<=…)` `(?<!…)` fixed-width lookbehind.
//! Variable-width lookbehind → typed MatchBudgetExceeded (documented limit).

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

test "lookaround: variable-width lookbehind is a typed error" {
    const a = std.testing.allocator;
    var r = try Regex.compile(a, "(?<=a+)b"); // a+ is not fixed width
    defer r.deinit();
    try std.testing.expectError(error.MatchBudgetExceeded, r.isMatch("aaab"));
}
