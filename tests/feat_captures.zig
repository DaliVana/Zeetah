//! Per-feature: capture groups (Phase D). Captures are opt-in via
//! `Regex.captures`; `find`/`isMatch` stay on the DFA fast path and ignore
//! groups. `std.testing.allocator` is the leak oracle for the owned
//! `Match.groups` slice (every `captures` result is `defer m.deinit`'d).

const std = @import("std");
const regex = @import("zeetah");
const Regex = regex.Regex;

const G = struct { s: ?[]const u8 }; // expected group slice (null = absent)

fn expectCaps(
    a: std.mem.Allocator,
    pat: []const u8,
    in: []const u8,
    whole: ?[]const u8,
    groups: []const G,
) !void {
    var rx = try Regex.compile(a, pat);
    defer rx.deinit();
    var m = try rx.captures(a, in);
    defer if (m) |*mm| mm.deinit(a);
    if (whole == null) {
        try std.testing.expect(m == null);
        return;
    }
    try std.testing.expect(m != null);
    try std.testing.expectEqualStrings(whole.?, m.?.slice);
    try std.testing.expectEqualStrings(whole.?, m.?.groups[0].?.slice); // group 0
    for (groups, 1..) |g, gi| {
        const got = m.?.groups[gi];
        if (g.s) |want| {
            try std.testing.expect(got != null);
            try std.testing.expectEqualStrings(want, got.?.slice);
        } else {
            try std.testing.expect(got == null);
        }
    }
}

test "captures: sequential groups" {
    const a = std.testing.allocator;
    try expectCaps(a, "(a)(b)(c)", "zabcz", "abc", &.{ .{ .s = "a" }, .{ .s = "b" }, .{ .s = "c" } });
    try expectCaps(a, "(\\d+)-(\\d+)", "x12-345y", "12-345", &.{ .{ .s = "12" }, .{ .s = "345" } });
}

test "captures: optional / alternation groups can be absent" {
    const a = std.testing.allocator;
    try expectCaps(a, "a(bc)?d", "ad", "ad", &.{.{ .s = null }});
    try expectCaps(a, "a(bc)?d", "abcd", "abcd", &.{.{ .s = "bc" }});
    try expectCaps(a, "(x)|(y)", "y", "y", &.{ .{ .s = null }, .{ .s = "y" } });
}

test "captures: nesting numbered by opening paren" {
    const a = std.testing.allocator;
    try expectCaps(a, "((a)(b))", "ab", "ab", &.{ .{ .s = "ab" }, .{ .s = "a" }, .{ .s = "b" } });
}

test "captures: repetition keeps the last iteration" {
    const a = std.testing.allocator;
    try expectCaps(a, "(foo|bar)+", "foobarfoo", "foobarfoo", &.{.{ .s = "foo" }});
}

test "captures: anchored + non-capturing group" {
    const a = std.testing.allocator;
    try expectCaps(a, "^(a+)$", "aaa", "aaa", &.{.{ .s = "aaa" }});
    try expectCaps(a, "(?:nope)(grp)", "nopegrp", "nopegrp", &.{.{ .s = "grp" }});
    try expectCaps(a, "(a)b", "xx", null, &.{});
}

test "captures: named groups + groupByName" {
    const a = std.testing.allocator;
    var rx = try Regex.compile(a, "(?<yr>\\d{4})-(?P<mo>\\d{2})");
    defer rx.deinit();
    var m = (try rx.captures(a, "d 2024-09")).?;
    defer m.deinit(a);
    try std.testing.expectEqualStrings("2024-09", m.slice);
    try std.testing.expectEqualStrings("2024", m.groupByName("yr").?.slice);
    try std.testing.expectEqualStrings("09", m.groupByName("mo").?.slice);
    try std.testing.expect(m.groupByName("nope") == null);
    // positional access still works alongside names
    try std.testing.expectEqualStrings("2024", m.groups[1].?.slice);
    try std.testing.expectEqualStrings("09", m.groups[2].?.slice);
}

test "captures: find/isMatch ignore groups (fast path unchanged)" {
    const a = std.testing.allocator;
    var rx = try Regex.compile(a, "(ab)+c");
    defer rx.deinit();
    try std.testing.expect(try rx.isMatch("ababc"));
    var fm = (try rx.find("zababc")).?;
    defer fm.deinit(a);
    try std.testing.expectEqualStrings("ababc", fm.slice);
    try std.testing.expectEqual(@as(usize, 0), fm.groups.len); // no groups on find()
}

test "captures: duplicate group name is a typed error" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidPattern, Regex.compile(a, "(?<a>x)(?<a>y)"));
}
