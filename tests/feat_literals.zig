//! Per-feature: literals, concatenation, escapes, dot, case-insensitivity.
//!
//! Asserts the *current* capture-free meta engine's behaviour (leftmost,
//! DFA-exact). Where a comptime `Pattern` and runtime `Regex` both apply the
//! same case is cross-checked so a divergence in either path is caught.

const std = @import("std");
const regex = @import("zeetah");
const Regex = regex.Regex;

fn find1(a: std.mem.Allocator, pat: []const u8, in: []const u8) !?struct { s: usize, e: usize, slice: []const u8 } {
    var rx = try Regex.compile(a, pat);
    defer rx.deinit();
    var m = try rx.find(in);
    defer if (m) |*mm| mm.deinit(a);
    if (m) |mm| return .{ .s = mm.start, .e = mm.end, .slice = mm.slice };
    return null;
}

test "literal: exact byte sequence, leftmost" {
    const a = std.testing.allocator;
    const m = (try find1(a, "abc", "xx abc yy abc")).?;
    try std.testing.expectEqual(@as(usize, 3), m.s);
    try std.testing.expectEqual(@as(usize, 6), m.e);
    try std.testing.expectEqualStrings("abc", m.slice);

    try std.testing.expect((try find1(a, "abc", "ab ac a b c")) == null);
}

test "literal: single char and empty-ish haystack" {
    const a = std.testing.allocator;
    const m = (try find1(a, "z", "z")).?;
    try std.testing.expectEqual(@as(usize, 0), m.s);
    try std.testing.expectEqual(@as(usize, 1), m.e);
    try std.testing.expect((try find1(a, "z", "")) == null);
}

test "concat: multi-atom sequence" {
    const a = std.testing.allocator;
    const m = (try find1(a, "hello", "well hello there")).?;
    try std.testing.expectEqualStrings("hello", m.slice);
    try std.testing.expectEqual(@as(usize, 5), m.s);
}

test "escapes: metacharacters are literal when escaped" {
    const a = std.testing.allocator;

    // \. matches a literal dot only.
    try std.testing.expect((try find1(a, "a\\.b", "a.b")) != null);
    try std.testing.expect((try find1(a, "a\\.b", "axb")) == null);

    // The other metacharacter escapes.
    try std.testing.expectEqualStrings("(x)", (try find1(a, "\\(x\\)", "y(x)z")).?.slice);
    try std.testing.expectEqualStrings("a*b", (try find1(a, "a\\*b", "za*bz")).?.slice);
    try std.testing.expectEqualStrings("a+b", (try find1(a, "a\\+b", "a+b")).?.slice);
    try std.testing.expectEqualStrings("a?b", (try find1(a, "a\\?b", "a?b")).?.slice);
    try std.testing.expectEqualStrings("a|b", (try find1(a, "a\\|b", "a|b")).?.slice);
    try std.testing.expectEqualStrings("[x]", (try find1(a, "\\[x\\]", "q[x]q")).?.slice);
    try std.testing.expectEqualStrings("{2}", (try find1(a, "\\{2\\}", "a{2}b")).?.slice);
    try std.testing.expectEqualStrings("^$", (try find1(a, "\\^\\$", "a^$b")).?.slice);

    // Escaped backslash: regex `a\\b` matches the bytes  a \ b .
    try std.testing.expectEqualStrings("a\\b", (try find1(a, "a\\\\b", "p a\\b q")).?.slice);
}

test "escapes: any ASCII punctuation is literal (Rust/RE2 rule, incl. \\/)" {
    const a = std.testing.allocator;

    // `\/` is the headline case (ghostty's URL regex uses it heavily). Plus a
    // spread of other punctuation escapes that have no special meaning.
    try std.testing.expectEqualStrings("a/b", (try find1(a, "a\\/b", "a/b")).?.slice);
    try std.testing.expectEqualStrings("a-b", (try find1(a, "a\\-b", "a-b")).?.slice);
    try std.testing.expectEqualStrings("x@y", (try find1(a, "x\\@y", "x@y")).?.slice);
    try std.testing.expectEqualStrings("c:d", (try find1(a, "c\\:d", "c:d")).?.slice);
    try std.testing.expectEqualStrings("e#f", (try find1(a, "e\\#f", "e#f")).?.slice);
    try std.testing.expectEqualStrings("g%h", (try find1(a, "g\\%h", "g%h")).?.slice);
    try std.testing.expectEqualStrings("i&j", (try find1(a, "i\\&j", "i&j")).?.slice);

    // Inside a character class too: `[\w\/]+` matches a slash-containing run.
    try std.testing.expectEqualStrings("a/b/c", (try find1(a, "[\\w\\/]+", " a/b/c ")).?.slice);

    // Alphabetic non-escapes are still rejected (not silently literal) — Rust
    // parity: the carve-out is punctuation only.
    try std.testing.expectError(error.NotImplemented, Regex.compile(a, "a\\yb"));
}

test "escapes: \\n \\t \\r control bytes" {
    const a = std.testing.allocator;
    try std.testing.expect((try find1(a, "a\\nb", "a\nb")) != null);
    try std.testing.expect((try find1(a, "a\\tb", "a\tb")) != null);
    try std.testing.expect((try find1(a, "a\\rb", "a\rb")) != null);
    try std.testing.expect((try find1(a, "a\\nb", "a b")) == null);
}

test "dot: any byte except newline" {
    const a = std.testing.allocator;
    const m = (try find1(a, "a.c", "zzabcanc a.c")).?;
    try std.testing.expectEqualStrings("abc", m.slice);
    try std.testing.expectEqual(@as(usize, 2), m.s);

    // '.' must NOT cross a newline.
    try std.testing.expect((try find1(a, "a.b", "a\nb")) == null);
    try std.testing.expect((try find1(a, "a.b", "axb")) != null);
}

test "case-insensitive: compile flag" {
    const a = std.testing.allocator;
    var rx = try Regex.compileWithFlags(a, "abc", .{ .case_insensitive = true });
    defer rx.deinit();
    try std.testing.expect(try rx.isMatch("xx ABC yy"));
    try std.testing.expect(try rx.isMatch("AbC"));
    try std.testing.expect(!try rx.isMatch("abx"));

    var cs = try Regex.compile(a, "abc");
    defer cs.deinit();
    try std.testing.expect(!try cs.isMatch("ABC"));
}

test "case-insensitive: letter-free literal fast paths (3.3) match correctly" {
    const a = std.testing.allocator;
    // Under ci, a letter-free literal folds to itself, so the
    // literal / lit_prefix / reverse_suffix fast paths are now taken and must
    // still produce the exact same matches as the case-sensitive engine.
    const Case = struct { pat: []const u8, in: []const u8, s: ?usize, e: ?usize };
    const cases = [_]Case{
        .{ .pat = "12345", .in = "xx 12345 yy", .s = 3, .e = 8 }, // .literal
        .{ .pat = "12|34|56", .in = "aa 34 bb", .s = 3, .e = 5 }, // .literal multi
        .{ .pat = "1234.*5678", .in = "p 1234xx5678 q", .s = 2, .e = 12 }, // lit_prefix
        .{ .pat = "[A-Z].*9999", .in = "Order 9999", .s = 0, .e = 10 }, // reverse_suffix
        .{ .pat = "12345", .in = "no digits here", .s = null, .e = null },
    };
    for (cases) |c| {
        var rx = try Regex.compileWithFlags(a, c.pat, .{ .case_insensitive = true });
        defer rx.deinit();
        var m = try rx.find(c.in);
        defer if (m) |*mm| mm.deinit(a);
        try std.testing.expectEqual(c.s == null, m == null);
        if (c.s) |s| {
            try std.testing.expectEqual(s, m.?.start);
            try std.testing.expectEqual(c.e.?, m.?.end);
        }
        // Must agree byte-for-byte with the case-sensitive engine (the literal
        // has no letters, so ci changes nothing).
        var cs = try Regex.compile(a, c.pat);
        defer cs.deinit();
        var cm = try cs.find(c.in);
        defer if (cm) |*mm| mm.deinit(a);
        try std.testing.expectEqual(cm == null, m == null);
        if (cm) |x| {
            try std.testing.expectEqual(x.start, m.?.start);
            try std.testing.expectEqual(x.end, m.?.end);
        }
    }
}

test "case-insensitive: inline (?i) and scoped (?i:...)/(?-i:...)" {
    const a = std.testing.allocator;

    // (?i) for the whole remainder.
    try std.testing.expect((try find1(a, "(?i)abc", "zzABCzz")) != null);

    // (?i:ab)c — only ab is folded; the trailing c stays case-sensitive.
    try std.testing.expect((try find1(a, "(?i:ab)c", "ABc")) != null);
    try std.testing.expect((try find1(a, "(?i:ab)c", "ABC")) == null);

    // (?-i:ab)c under the global ci flag — ab case-sensitive again.
    var rx = try Regex.compileWithFlags(a, "(?-i:ab)c", .{ .case_insensitive = true });
    defer rx.deinit();
    try std.testing.expect(try rx.isMatch("abC"));
    try std.testing.expect(!try rx.isMatch("ABc"));
}

test "literal: comptime Pattern agrees with runtime Regex" {
    const a = std.testing.allocator;
    const P = regex.Pattern("hello", .{});
    const cases = [_][]const u8{ "", "hello", "say hello!", "hell", "HELLO" };
    var rx = try Regex.compile(a, "hello");
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
