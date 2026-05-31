//! Per-feature: lazy (non-greedy) quantifiers `*?`, `+?`, `??`, `{m,n}?`.
//!
//! The meta engine is a DFA: lazy means the *earliest* accepting end is
//! taken (minimal match) at the leftmost start, vs greedy's latest end.
//! Lazy *combined with an end-anchor* (`a*?$`) is the one shape the DFA
//! accept-cut cannot model, so it routes to the tree backtracker instead
//! (still leftmost-first); covered in the end-anchor test below.

const std = @import("std");
const regex = @import("zeetah");
const Regex = regex.Regex;

fn span(a: std.mem.Allocator, pat: []const u8, in: []const u8) !?struct { s: usize, e: usize, slice: []const u8 } {
    var rx = try Regex.compile(a, pat);
    defer rx.deinit();
    var m = try rx.find(in);
    defer if (m) |*mm| mm.deinit(a);
    if (m) |mm| return .{ .s = mm.start, .e = mm.end, .slice = mm.slice };
    return null;
}

test "lazy *?: minimal vs greedy maximal" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("ab", (try span(a, ".*?b", "abcb")).?.slice);
    try std.testing.expectEqualStrings("abcb", (try span(a, ".*b", "abcb")).?.slice);

    try std.testing.expectEqualStrings("abx", (try span(a, ".*?x", "abxcx")).?.slice);
    try std.testing.expectEqualStrings("abxcx", (try span(a, ".*x", "abxcx")).?.slice);
}

test "lazy *?: stops at the first delimiter, leftmost start" {
    const a = std.testing.allocator;
    const m = (try span(a, "a.*?c", "za1c2c")).?;
    try std.testing.expectEqual(@as(usize, 1), m.s);
    try std.testing.expectEqualStrings("a1c", m.slice);
}

test "lazy +?: at least one, then minimal" {
    const a = std.testing.allocator;
    const m = (try span(a, "a+?b", "xaaabz")).?;
    try std.testing.expectEqual(@as(usize, 1), m.s);
    try std.testing.expectEqualStrings("aaab", m.slice); // only one 'b' to stop at
}

test "lazy ??: optional prefers absent" {
    const a = std.testing.allocator;
    // Language equals a?b; the single match per start makes lazy/greedy
    // coincide here — assert the boundary is still correct.
    try std.testing.expectEqualStrings("ab", (try span(a, "a??b", "xabx")).?.slice);
    try std.testing.expectEqualStrings("b", (try span(a, "a??b", "xbx")).?.slice);
}

test "lazy {m,n}?: minimal count within bounds" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("aa", (try span(a, "a{2,4}?", "aaaaa")).?.slice);
    try std.testing.expectEqualStrings("aaaa", (try span(a, "a{2,4}", "aaaaa")).?.slice);
    // Must still satisfy the minimum.
    var rx = try Regex.compile(a, "a{2,4}?");
    defer rx.deinit();
    try std.testing.expect(!try rx.isMatch("a"));
}

test "lazy {2,}?: open-ended, minimal" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("aa", (try span(a, "a{2,}?", "aaaaa")).?.slice);
}

test "lazy + end-anchor: routed to the backtracker, leftmost-first" {
    const a = std.testing.allocator;
    // The DFA accept-cut can't model lazy against `$`, so these route to the
    // tree backtracker. Leftmost-first still holds: at the leftmost viable
    // start, `$` forces `a*?`/`a+?` to consume to end-of-text. (Differential-
    // tested against Python `re`.)
    {
        const m = (try span(a, "a*?$", "aaa")).?;
        try std.testing.expectEqual(@as(usize, 0), m.s);
        try std.testing.expectEqualStrings("aaa", m.slice);
    }
    try std.testing.expectEqualStrings("abc", (try span(a, ".*?$", "abc")).?.slice);
    {
        // Leftmost start is 1 (not the shortest suffix "a" at 3) — the case
        // the seek-prefilter soundness fix corrected.
        const m = (try span(a, "a+?$", "baaa")).?;
        try std.testing.expectEqual(@as(usize, 1), m.s);
        try std.testing.expectEqualStrings("aaa", m.slice);
    }
    // `a*?` is nullable: it matches empty only where `$` already holds.
    try std.testing.expectEqualStrings("", (try span(a, "a*?$", "")).?.slice);
}

test "lazy: comptime Pattern agrees with runtime Regex" {
    const a = std.testing.allocator;
    const P = regex.Pattern("a.*?b", .{});
    const cases = [_][]const u8{ "", "ab", "axbxb", "aXXb", "ba", "a__b__b" };
    var rx = try Regex.compile(a, "a.*?b");
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
