//! Per-feature: anchors `^`, `$`, `\A`, `\z`, `\Z` and their no-slide /
//! must-consume-to-end semantics.

const std = @import("std");
const regex = @import("zeetah");
const Regex = regex.Regex;

fn isM(a: std.mem.Allocator, pat: []const u8, in: []const u8) !bool {
    var rx = try Regex.compile(a, pat);
    defer rx.deinit();
    return rx.isMatch(in);
}

fn span(a: std.mem.Allocator, pat: []const u8, in: []const u8) !?struct { s: usize, e: usize } {
    var rx = try Regex.compile(a, pat);
    defer rx.deinit();
    var m = try rx.find(in);
    defer if (m) |*mm| mm.deinit(a);
    if (m) |mm| return .{ .s = mm.start, .e = mm.end };
    return null;
}

test "^: start anchor does not slide" {
    const a = std.testing.allocator;
    const m = (try span(a, "^abc", "abcdef")).?;
    try std.testing.expectEqual(@as(usize, 0), m.s);
    try std.testing.expectEqual(@as(usize, 3), m.e);
    try std.testing.expect(!try isM(a, "^abc", "xabc"));
    try std.testing.expect(!try isM(a, "^bc", "abc"));
}

test "$: end anchor must consume to end" {
    const a = std.testing.allocator;
    const m = (try span(a, "world$", "hello world")).?;
    try std.testing.expectEqual(@as(usize, 6), m.s);
    try std.testing.expectEqual(@as(usize, 11), m.e);
    try std.testing.expect(!try isM(a, "world$", "world peace"));
    try std.testing.expect(!try isM(a, "bc$", "abcd"));
}

test "^...$: both ends anchor the whole input" {
    const a = std.testing.allocator;
    try std.testing.expect(try isM(a, "^abc$", "abc"));
    try std.testing.expect(!try isM(a, "^abc$", "abcd"));
    try std.testing.expect(!try isM(a, "^abc$", "xabc"));
    try std.testing.expect(!try isM(a, "^abc$", " abc "));
}

test "anchors + quantifier: ^a+$" {
    const a = std.testing.allocator;
    try std.testing.expect(try isM(a, "^a+$", "aaaa"));
    try std.testing.expect(!try isM(a, "^a+$", "aaab"));
    try std.testing.expect(!try isM(a, "^a+$", ""));
    try std.testing.expect(try isM(a, "^a*$", ""));
}

test "\\A and \\z behave as absolute start / end anchors" {
    const a = std.testing.allocator;
    const m = (try span(a, "\\Aabc", "abcdef")).?;
    try std.testing.expectEqual(@as(usize, 0), m.s);
    try std.testing.expect(!try isM(a, "\\Aabc", "xabc"));

    try std.testing.expect(try isM(a, "abc\\z", "xxabc"));
    try std.testing.expect(!try isM(a, "abc\\z", "abcx"));

    try std.testing.expect(try isM(a, "\\Aabc\\z", "abc"));
    try std.testing.expect(!try isM(a, "\\Aabc\\z", "abcd"));
}

test "\\Z end anchor" {
    const a = std.testing.allocator;
    try std.testing.expect(try isM(a, "abc\\Z", "xxabc"));
    try std.testing.expect(!try isM(a, "abc\\Z", "abcx"));
}

test "anchors: comptime Pattern agrees with runtime Regex" {
    const a = std.testing.allocator;
    const P = regex.Pattern("^\\d+$", .{});
    const cases = [_][]const u8{ "", "123", "12a", "a12", " 12", "0" };
    var rx = try Regex.compile(a, "^\\d+$");
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
