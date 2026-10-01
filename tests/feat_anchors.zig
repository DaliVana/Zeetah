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

test "^: a folded start anchor never re-anchors past offset 0" {
    const a = std.testing.allocator;
    // Found by `nfa_fuzz`: the backtracker's seek prefilter jumped the first
    // attempt past offset 0, and the comptime backtrack arm re-anchored at
    // every resume point of an iteration.
    try std.testing.expect(!(try isM(a, "^(?<=b)", ",aa aA\nbaAa")));
    var rx = try Regex.compile(a, "^(?!x)");
    defer rx.deinit();
    try std.testing.expectEqual(@as(usize, 1), try rx.count("ab"));
    const P = regex.Pattern("^(?!x)", .{});
    try std.testing.expectEqual(@as(usize, 1), P.count("ab"));
    try std.testing.expect(P.capturesFrom("ab", 1) == null);
    const Q = regex.Pattern("^(?<=b)", .{});
    try std.testing.expect(!Q.isMatch(",aa aA\nbaAa"));
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

test "anchors over a top-level alternation bind to a single branch" {
    const a = std.testing.allocator;
    // `^a|b` ≡ `(^a)|b` — the `b` branch is NOT anchored, so it matches anywhere.
    // (Regression: the prescan must not fold the anchor across a top-level `|`.)
    try std.testing.expect(try isM(a, "^a|b", "xxxb"));
    try std.testing.expectEqual(@as(usize, 3), (try span(a, "^a|b", "xxxb")).?.s);
    try std.testing.expect(try isM(a, "a|b$", "axx")); // `a` branch unanchored
    try std.testing.expectEqual(@as(usize, 0), (try span(a, "a|b$", "axx")).?.s);
    try std.testing.expect(try isM(a, "\\Aa|b", "xxb"));
    try std.testing.expect(try isM(a, "^foo|bar", "x bar"));
    // A whole-pattern anchor (no top-level `|`) still anchors, and a grouped
    // alternation under anchors is unaffected.
    try std.testing.expect(!try isM(a, "^abc", "xabc"));
    try std.testing.expect(try isM(a, "^(?:a|b)$", "a"));
    try std.testing.expect(!try isM(a, "^(?:a|b)$", "ax"));
}

test "reverse end-anchored fast path: (?m)<body>$ leftmost spans and counts" {
    const a = std.testing.allocator;
    // Multiline trailing `$`, unanchored start, regular `\n`-free body → the
    // `.rev_end` reverse driver (one O(n) pass per line end). Verify the leftmost
    // span, no-match, and per-line counting are exactly right.
    {
        // Line 1 "abc" has no trailing digit run; "345" ends line 2.
        const m = (try span(a, "(?m)[0-9]+$", "abc\ncd345")).?;
        try std.testing.expectEqual(@as(usize, 6), m.s); // "345" on the 2nd line
        try std.testing.expectEqual(@as(usize, 9), m.e);
    }
    {
        // Mid-line digits NOT at a line end don't match; the line-end run does.
        const m = (try span(a, "(?m)[0-9]+$", "12ab\n99")).?;
        try std.testing.expectEqual(@as(usize, 5), m.s); // "99", not "12"
        try std.testing.expectEqual(@as(usize, 7), m.e);
    }
    // Alternation body is sound here (the reverse pass is no-cut, unlike the
    // forward line-DFA which would reject alt+$).
    try std.testing.expect(try isM(a, "(?m)(?:a|bb)+$", "x\nbba"));
    try std.testing.expect(!try isM(a, "(?m)[0-9]+$", "abc\ndef"));
    {
        var rx = try Regex.compile(a, "(?m)[a-z]+$");
        defer rx.deinit();
        // "foo" (line-end), "baz" (line-end), "qux" (EOF) — "bar " not at end.
        try std.testing.expectEqual(@as(usize, 3), try rx.count("foo\nbar baz\nqux"));
    }
    // `\s` matches `\n`, so `(?m)\s+$` stays on the backtracker (body may cross
    // lines) — must still be correct.
    try std.testing.expect(try isM(a, "(?m)\\s+$", "abc   \ndef"));
}

test "reverse end-anchored fast path: <body>\\Z before optional final newline" {
    const a = std.testing.allocator;
    // `\Z` end-boundary set is {len} ∪ {len-1 if trailing \n}: the reverse driver
    // seeds both. `[a-z]+\Z` matches the trailing run with or without a final \n.
    {
        const m = (try span(a, "[a-z]+\\Z", "  hello")).?;
        try std.testing.expectEqual(@as(usize, 2), m.s);
        try std.testing.expectEqual(@as(usize, 7), m.e);
    }
    {
        const m = (try span(a, "[a-z]+\\Z", "  hello\n")).?; // before the final \n
        try std.testing.expectEqual(@as(usize, 2), m.s);
        try std.testing.expectEqual(@as(usize, 7), m.e);
    }
    try std.testing.expect(try isM(a, "abc\\Z", "xxabc"));
    try std.testing.expect(try isM(a, "abc\\Z", "xxabc\n"));
    try std.testing.expect(!try isM(a, "abc\\Z", "abcx")); // not at (before) the end
    try std.testing.expect(!try isM(a, "abc\\Z", "abc\nx")); // \n is not the FINAL byte
    // Two `\n`s at the end: `\Z` only skips ONE trailing newline.
    try std.testing.expect(!try isM(a, "abc\\Z", "abc\n\n"));
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

/// `^…$` / `\A…\z` (both anchors folded): the match, if any, is the whole
/// input. `want` is hand-checked; runtime `Regex` and comptime `Pattern` must
/// both return it (`find`, `isMatch`, `count`).
fn bothAnchored(comptime pat: []const u8, in: []const u8, want: ?[2]usize) !void {
    const a = std.testing.allocator;
    var rx = try Regex.compile(a, pat);
    defer rx.deinit();
    const P = regex.Pattern(pat, .{});
    var rm = try rx.find(in);
    defer if (rm) |*x| x.deinit(a);
    const pm = P.find(in);
    errdefer std.debug.print("\nbothAnchored {s} on \"{s}\": want {any} runtime {any} comptime {any}\n", .{ pat, in, want, if (rm) |m| [2]usize{ m.start, m.end } else null, if (pm) |m| [2]usize{ m.start, m.end } else null });
    try std.testing.expectEqual(want == null, rm == null);
    try std.testing.expectEqual(want == null, pm == null);
    if (want) |w| {
        try std.testing.expectEqual(w[0], rm.?.start);
        try std.testing.expectEqual(w[1], rm.?.end);
        try std.testing.expectEqual(w[0], pm.?.start);
        try std.testing.expectEqual(w[1], pm.?.end);
    }
    try std.testing.expectEqual(want != null, try rx.isMatch(in));
    try std.testing.expectEqual(want != null, P.isMatch(in));
    try std.testing.expectEqual(@as(usize, @intFromBool(want != null)), try rx.count(in));
    try std.testing.expectEqual(@as(usize, @intFromBool(want != null)), P.count(in));
}

test "anchors: ^(alt)$ — a later, longer alternative still reaches $" {
    // The end-anchored DFA used to apply the leftmost-first accept cut: once an
    // earlier alternative accepted mid-input, the later one that reaches `$`
    // was dropped, so all of these were wrongly rejected.
    try bothAnchored("^(?:a|aa)$", "aa", .{ 0, 2 });
    try bothAnchored("^(?:a|aa)$", "a", .{ 0, 1 });
    try bothAnchored("^(?:a|aa)$", "aaa", null);
    try bothAnchored("\\A(?:a|aa)\\z", "aa", .{ 0, 2 });
    try bothAnchored("^(?:a|ab)$", "ab", .{ 0, 2 });
    try bothAnchored("^(?:a|ab)$", "ac", null);
    try bothAnchored("^(?:cat|category)$", "category", .{ 0, 8 });
    try bothAnchored("^(?:cat|category)$", "cat", .{ 0, 3 });
    try bothAnchored("^(?:cat|category)$", "categ", null);
    try bothAnchored("^(?:a|.*)$", "abc", .{ 0, 3 });
    try bothAnchored("^(?:a|.*)$", "", .{ 0, 0 });
    try bothAnchored("^(?:ab|a)(?:c|bc)$", "abc", .{ 0, 3 });
    try bothAnchored("^(?:ab|a)(?:c|bc)$", "abbc", .{ 0, 4 });
    try bothAnchored("^(?:ab|a)(?:c|bc)$", "ac", .{ 0, 2 });
    try bothAnchored("^(?:x|xy)*$", "xyx", .{ 0, 3 });
    try bothAnchored("^(?:x|xy)*$", "yx", null);
    try bothAnchored("^(?:a|aa)b*$", "aab", .{ 0, 3 });
    try bothAnchored("^(?:[^a]|ba)$", "ba", .{ 0, 2 });
    try bothAnchored("(?i)^(?:a|aa)$", "AA", .{ 0, 2 });
    // isbn without `(?m)`: a 13-digit input is the second alternative.
    try bothAnchored("^(?:\\d{9}[\\dXx]|\\d{13})$", "1234567890123", .{ 0, 13 });
    try bothAnchored("^(?:\\d{9}[\\dXx]|\\d{13})$", "123456789X", .{ 0, 10 });
    try bothAnchored("^(?:\\d{9}[\\dXx]|\\d{13})$", "12345678901234", null);
}

test "anchors: ^(alt)$ captures and the lazy-DFA route" {
    const a = std.testing.allocator;
    // Captures: leftmost-first priority still decides the groups of the
    // (unique) whole-input match.
    {
        var rx = try Regex.compile(a, "^(a|ab)(c|bcd)$");
        defer rx.deinit();
        const P = regex.Pattern("^(a|ab)(c|bcd)$", .{});
        inline for (.{ .{ "abcd", 0, 1, 1, 4 }, .{ "abc", 0, 2, 2, 3 } }) |c| {
            var m = (try rx.captures(a, c[0])).?;
            defer m.deinit(a);
            const pc = P.captures(c[0]).?;
            try std.testing.expectEqual(@as(usize, c[1]), m.groups[1].?.start);
            try std.testing.expectEqual(@as(usize, c[2]), m.groups[1].?.end);
            try std.testing.expectEqual(@as(usize, c[3]), m.groups[2].?.start);
            try std.testing.expectEqual(@as(usize, c[4]), m.groups[2].?.end);
            try std.testing.expectEqual(@as(usize, c[1]), pc.get(1).?.start);
            try std.testing.expectEqual(@as(usize, c[4]), pc.get(2).?.end);
        }
    }
    // A pattern too big for the eager DFA runs on the lazy DFA (runtime only:
    // the comptime NFA ceiling rejects it).
    {
        var rx = try Regex.compile(a, "^(?:a|aa)[a-z]{0,200}$");
        defer rx.deinit();
        try std.testing.expect(rx.kind == .lazy_dfa);
        var m = (try rx.find("aa")).?;
        defer m.deinit(a);
        try std.testing.expectEqual(@as(usize, 2), m.end);
        try std.testing.expect(try rx.isMatch("aab"));
        try std.testing.expect(!try rx.isMatch("b"));
    }
}
