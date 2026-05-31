//! Per-feature: backreferences (Phase E, .NET-model tree backtracker).
//! `\1`..`\9` numeric and `\k<name>` named; an unset group backref matches
//! the empty string (lenient, .NET-style). ReDoS budget contract lives in
//! security.zig.

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

test "backref: numeric \\1 matches the captured text" {
    const a = std.testing.allocator;
    try std.testing.expect(try isM(a, "(ab)\\1", "abab"));
    try std.testing.expect(!try isM(a, "(ab)\\1", "abac"));
    try std.testing.expectEqualStrings("hh", (try slice(a, "(\\w)\\1", "aXhhb")).?); // doubled char
    try std.testing.expect(try isM(a, "(\\w+) \\1", "the the"));
    try std.testing.expect(!try isM(a, "(\\w+) \\1", "the cat"));
}

test "backref: multiple groups and \\2" {
    const a = std.testing.allocator;
    try std.testing.expect(try isM(a, "(a)(b)\\2\\1", "abba"));
    try std.testing.expect(!try isM(a, "(a)(b)\\2\\1", "abab"));
}

test "backref: named \\k<name>" {
    const a = std.testing.allocator;
    try std.testing.expect(try isM(a, "(?<q>['\"]).*?\\k<q>", "say \"hi\" ok"));
    try std.testing.expect(!try isM(a, "(?<q>['\"]).*?\\k<q>", "say \"hi' no"));
    var rx = try Regex.compile(a, "(?<w>\\w+)=\\k<w>");
    defer rx.deinit();
    try std.testing.expect(try rx.isMatch("x=x"));
    try std.testing.expect(!try rx.isMatch("x=y"));
}

test "backref: captures() still exposes the groups" {
    const a = std.testing.allocator;
    var rx = try Regex.compile(a, "(\\w+)-\\1");
    defer rx.deinit();
    var m = (try rx.captures(a, "ab-ab tail")).?;
    defer m.deinit(a);
    try std.testing.expectEqualStrings("ab-ab", m.slice);
    try std.testing.expectEqualStrings("ab", m.groups[1].?.slice);
}

test "backref: in-bounds short inputs match/return cleanly" {
    const a = std.testing.allocator;
    try std.testing.expect(try isM(a, "(.)(.)\\2\\1", "abba"));
    try std.testing.expect(!try isM(a, "(.+)\\1$", "abcdef")); // no even split → no match, terminates
}
