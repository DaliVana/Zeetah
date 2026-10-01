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

test "captures: a group inside a lookaround does not shift outer numbering or add a phantom" {
    const a = std.testing.allocator;
    // In-lookaround captures are not reported (Phase-E limitation), but they must
    // NOT be counted: counting them shifts every following group's number and
    // leaves a phantom unset slot. `(?=(a)b)(a)(b)` on "ab" => exactly the two
    // real groups g1=(a), g2=(b) — no phantom g3.
    var rx = try Regex.compile(a, "(?=(a)b)(a)(b)");
    defer rx.deinit();
    var m = (try rx.captures(a, "ab")).?;
    defer m.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), m.groups.len); // g0 + 2 real groups
    try std.testing.expectEqualStrings("ab", m.groups[0].?.slice);
    try std.testing.expectEqualStrings("a", m.groups[1].?.slice);
    try std.testing.expectEqualStrings("b", m.groups[2].?.slice);
}

test "captures: large boundary-capturing run (explicit-stack recCap, no overflow)" {
    const a = std.testing.allocator;
    // `\b(\w+)\b` routes to the bounded backtracker's capture trace, whose
    // recursion was replaced by an explicit heap stack. A long run must produce
    // the correct group without overflowing the native stack.
    const n = 100 * 1024;
    const buf = try a.alloc(u8, n);
    defer a.free(buf);
    @memset(buf, 'x');
    var rx = try Regex.compile(a, "\\b(\\w+)\\b");
    defer rx.deinit();
    var m = (try rx.captures(a, buf)).?;
    defer m.deinit(a);
    try std.testing.expectEqual(n, m.groups[1].?.slice.len);
}

test "captures: repetition keeps the last iteration" {
    const a = std.testing.allocator;
    try expectCaps(a, "(foo|bar)+", "foobarfoo", "foobarfoo", &.{.{ .s = "foo" }});
}

test "captures: a group under a counted repetition reports its last iteration" {
    const a = std.testing.allocator;
    // Found by `nfa_fuzz`: the `{m,n}` expansion's copies used to drop the
    // group (a lone group came back with no `groups` at all).
    var rx = try Regex.compile(a, "(ab){2}");
    defer rx.deinit();
    var m = (try rx.captures(a, "abab")).?;
    defer m.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), m.groups.len);
    try std.testing.expectEqual(@as(usize, 2), m.groups[1].?.start);
    try expectCaps(a, "(x)?(ab){2}", "abab", "abab", &.{ .{ .s = null }, .{ .s = "ab" } });
    try expectCaps(a, "(a|b){1,3}", "ab", "ab", &.{.{ .s = "b" }});
    // An iteration that skips the group keeps the earlier iteration's span.
    try expectCaps(a, "(?:(a)|b){2}", "ab", "ab", &.{.{ .s = "a" }});
    try expectCaps(a, "(?<y>\\d\\d){2}-", "2024-", "2024-", &.{.{ .s = "24" }});
    // A named backreference inside the repeated atom resolves too.
    try expectCaps(a, "(?<x>a)\\k<x>{2}", "aaa", "aaa", &.{.{ .s = "a" }});
    const P = regex.Pattern("(ab){2}", .{});
    try std.testing.expectEqual(@as(usize, 2), P.captures("abab").?.groups[1].?.start);
}

test "captures: a counted repetition with no copies keeps its group, null" {
    const a = std.testing.allocator;
    // `{0}` leaves no `.cap` node (the engine needs no captures), but the
    // group still exists: `groups` is whole match + one null group.
    for ([_][]const u8{ "(a){0}b", "(a){0}", "(a){0,0}b" }) |p| {
        var rx = try Regex.compile(a, p);
        defer rx.deinit();
        var m = (try rx.captures(a, "ab")).?;
        defer m.deinit(a);
        try std.testing.expectEqual(@as(usize, 2), m.groups.len);
        try std.testing.expect(m.groups[0] != null);
        try std.testing.expect(m.groups[1] == null);
    }
    const P = regex.Pattern("(a){0}b", .{});
    try std.testing.expect(P.captures("ab").?.groups[1] == null);
}

test "captures: mandatory {m,n} copies before the last carry no groups" {
    const a = std.testing.allocator;
    // The last mandatory copy overwrites every slot of a group that always
    // participates, so the earlier copies drop it — `(a){100}` stays within
    // the comptime NFA ceiling, as it did before groups were replayed.
    try std.testing.expect(regex.compilesAtComptime("(a){100}", false, false));
    const P = regex.Pattern("(a){100}", .{});
    const in: [100]u8 = @splat('a');
    try std.testing.expectEqual(@as(usize, 99), P.captures(&in).?.groups[1].?.start);
    try expectCaps(a, "(a){3}", "aaaa", "aaa", &.{.{ .s = "a" }});
    try expectCaps(a, "((a)(b)){2}", "abab", "abab", &.{ .{ .s = "ab" }, .{ .s = "a" }, .{ .s = "b" } });
    try expectCaps(a, "((a){2}){3}", "aaaaaa", "aaaaaa", &.{ .{ .s = "aa" }, .{ .s = "a" } });
    // Not elided: a group an iteration can skip keeps the earlier iteration's
    // span, and a backreference reads its own copy's group.
    try expectCaps(a, "((a)|b){2}", "ab", "ab", &.{ .{ .s = "b" }, .{ .s = "a" } });
    var rx = try Regex.compile(a, "((a)\\2){2}");
    defer rx.deinit();
    var m = (try rx.captures(a, "aaaa")).?;
    defer m.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), m.groups[1].?.start);
    try std.testing.expectEqual(@as(usize, 2), m.groups[2].?.start);
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
