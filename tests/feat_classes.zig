//! Per-feature: character classes and the built-in shorthand classes.

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

test "class: explicit set [abc]" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("b", (try slice(a, "[abc]", "xyzbq")).?);
    try std.testing.expect(!try isM(a, "[abc]", "xyz"));
}

test "class: range [a-z] and [0-9]" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("hello", (try slice(a, "[a-z]+", "12hello34")).?);
    try std.testing.expectEqualStrings("42", (try slice(a, "[0-9]+", "abc42def")).?);
    try std.testing.expect(!try isM(a, "[a-z]+", "12345"));
}

test "class: negated [^abc]" {
    const a = std.testing.allocator;
    // First byte not in {a,b,c}.
    try std.testing.expectEqualStrings("x", (try slice(a, "[^abc]", "aabxcc")).?);
    try std.testing.expect(!try isM(a, "[^abc]", "abcabc"));
    // Negated class still excludes nothing else — newline is included.
    try std.testing.expect(try isM(a, "[^a]", "\n"));
}

test "class: multi-range and mixed members [A-Za-z0-9_]" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("Ab9_", (try slice(a, "[A-Za-z0-9_]+", "  Ab9_ !!")).?);
}

test "class: escapes inside a set" {
    const a = std.testing.allocator;
    // A class that contains a literal ']' , '-' and '\n'.
    try std.testing.expect(try isM(a, "[\\]\\-\\n]", "]"));
    try std.testing.expect(try isM(a, "[\\]\\-\\n]", "-"));
    try std.testing.expect(try isM(a, "[\\]\\-\\n]", "\n"));
    try std.testing.expect(!try isM(a, "[\\]\\-\\n]", "x"));
}

test "shorthand: \\d \\D" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("2024", (try slice(a, "\\d+", "year 2024 ok")).?);
    try std.testing.expectEqualStrings("year ", (try slice(a, "\\D+", "year 2024")).?);
    try std.testing.expect(!try isM(a, "\\d", "no digits here"));
}

test "shorthand: \\w \\W" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("foo_bar9", (try slice(a, "\\w+", "  foo_bar9 ??")).?);
    try std.testing.expectEqualStrings(" -- ", (try slice(a, "\\W+", "ab -- cd")).?);
}

test "shorthand: \\s \\S" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("   ", (try slice(a, "\\s+", "ab   cd")).?);
    try std.testing.expectEqualStrings("\t\n", (try slice(a, "\\s+", "x\t\ny")).?);
    try std.testing.expectEqualStrings("ab", (try slice(a, "\\S+", "  ab cd")).?);
}

test "class: digit range and dot member [0-9.]" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("3.14", (try slice(a, "[0-9.]+", "pi=3.14!")).?);
}

// --- Phase A: shorthand-in-class, POSIX, (?s)/(?x) ------------------------

test "class: shorthand \\d \\w \\s inside [...]" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("123", (try slice(a, "[\\d]+", "x123y")).?);
    try std.testing.expectEqualStrings("a.b_c", (try slice(a, "[\\w.]+", " a.b_c! ")).?);
    try std.testing.expectEqualStrings("  ", (try slice(a, "[\\s]+", "ab  cd")).?);
    // mixed with literals/ranges and negated shorthand
    try std.testing.expectEqualStrings("cd12", (try slice(a, "[a-z\\d]+", "AB cd12 EF")).?);
    try std.testing.expectEqualStrings("ab", (try slice(a, "[^\\d]+", "12ab34")).?);
}

test "class: POSIX [[:name:]] and negated [[:^name:]]" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("abcXY", (try slice(a, "[[:alpha:]]+", "  abcXY9")).?);
    try std.testing.expectEqualStrings("42", (try slice(a, "[[:digit:]]+", "ab 42 cd")).?);
    try std.testing.expectEqualStrings("cd12", (try slice(a, "[a-z[:digit:]]+", "AB cd12 EF")).?);
    try std.testing.expectEqualStrings("ab", (try slice(a, "[[:^digit:]]+", "12ab34")).?);
    try std.testing.expectError(error.NotImplemented, Regex.compile(a, "[[:bogus:]]")); // unknown name → typed rejection
}

test "flags: (?s) dot_all makes . match newline; (?x) ignores whitespace/#" {
    const a = std.testing.allocator;
    try std.testing.expect(try isM(a, "(?s)a.b", "a\nb"));
    try std.testing.expect(!try isM(a, "a.b", "a\nb")); // default: dot excludes \n
    try std.testing.expect(try isM(a, "(?s:a.b)c", "a\nbc"));
    try std.testing.expectEqualStrings("abc", (try slice(a, "(?x) a b c", "zabc")).?);
    try std.testing.expectEqualStrings("ab", (try slice(a, "(?x)a # comment\n b", "xaby")).?);
}

test "class: comptime Pattern agrees with runtime Regex" {
    const a = std.testing.allocator;
    const P = regex.Pattern("[a-z]+", .{});
    const cases = [_][]const u8{ "", "abc", "12ab34", "ABC", "x" };
    var rx = try Regex.compile(a, "[a-z]+");
    defer rx.deinit();
    for (cases) |in| {
        try std.testing.expectEqual(try rx.isMatch(in), P.isMatch(in));
        const pm = P.find(in);
        var rm = try rx.find(in);
        defer if (rm) |*x| x.deinit(a);
        try std.testing.expectEqual(rm == null, pm == null);
        if (pm) |p| {
            try std.testing.expectEqual(p.start, rm.?.start);
            try std.testing.expectEqual(p.end, rm.?.end);
        }
    }
}
