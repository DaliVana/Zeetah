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

test "lookbehind: multi-byte class seek (?<=[?&]) — lb_set prefilter" {
    const a = std.testing.allocator;
    // Only tokens immediately after `?` or `&` qualify; the seek scans for the
    // class members and starts one byte past each (the dropped constraint).
    try std.testing.expectEqualStrings("foo", (try slice(a, "(?<=[?&])\\w+", "x?foo&bar zfoo")).?);
    try std.testing.expect(!try isM(a, "(?<=[?&])\\w+", "nofoo here"));
    var rx = try Regex.compile(a, "(?<=[?&])[a-z]+");
    defer rx.deinit();
    // `?aa &bb #cc &dd` → aa, bb, dd (cc follows `#`, not `?`/`&`).
    try std.testing.expectEqual(@as(usize, 3), try rx.count("?aa&bb#cc&dd"));
    // comptime Pattern bakes the same lb_set seek; must agree byte-for-byte.
    const P = regex.Pattern("(?<=[?&])[a-z]+", .{});
    try std.testing.expectEqual(@as(usize, 3), P.count("?aa&bb#cc&dd"));
    try std.testing.expectEqualStrings("foo", P.find("x?foo&bar").?.slice);
}

test "lookaround: combined with quantifiers / anchors" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("100", (try slice(a, "\\d+(?= dollars)", "I owe 100 dollars")).?);
    try std.testing.expect(try isM(a, "^(?=.*a)(?=.*b).+$", "xayb"));
    try std.testing.expect(!try isM(a, "^(?=.*a)(?=.*b).+$", "xxyy"));
}

test "edge-look: trailing width-1 look peeled onto the DFA (scheme-branch shape)" {
    const a = std.testing.allocator;
    // `concat(regular_core, trailing (?<![,.]))` — the ghostty URL scheme
    // branch shape. Runs `core` on the DFA + an O(1) edge verify, and the
    // verify must pick the longest end whose last byte ∉ {,.} (i.e. trim a
    // trailing '.'/',' that the greedy core would otherwise include).
    const P = "(?:https?:\\/\\/|ftp:\\/\\/)[\\w\\-.~:\\/?#@!$&*+,;=%]+(?<![,.])";
    try std.testing.expectEqualStrings("https://example.com", (try slice(a, P, "see https://example.com. more")).?);
    try std.testing.expectEqualStrings("https://a.com", (try slice(a, P, "x https://a.com, y")).?);
    try std.testing.expectEqualStrings("https://a.com/p?q=1", (try slice(a, P, "go https://a.com/p?q=1 ok")).?);
    // The (a+)+ -shaped input that used to trip the backtracker budget — now a
    // linear DFA walk.
    try std.testing.expectEqualStrings("http://example.com", (try slice(a, P, "dot.http://example.com")).?);
    try std.testing.expect(!try isM(a, P, "no url here just text"));

    // Trailing negative lookahead at the end is the same shape (e.g. last digit
    // of a run): `\d(?!\d)` and `\w+(?!\w)`.
    try std.testing.expectEqualStrings("5", (try slice(a, "\\d(?!\\d)", "in 345 end")).?);
    try std.testing.expectEqualStrings("foo", (try slice(a, "foo(?!bar)", "foobaz")).?);
}

test "edge-look: comptime Pattern engages the DFA path and matches runtime" {
    // A lookaround pattern with `has_dfa == true` can ONLY be the edge-look
    // peel (the regular DFA path can't model lookaround, and the comptime
    // backtracker sets has_dfa = false) — so this asserts engagement. The core
    // must be alternation-free (see the `.alt` exclusion below).
    const P = regex.Pattern("(?:https?:\\/\\/)[\\w\\-.~:\\/?#@!$&*+,;=%]+(?<![,.])", .{});
    try std.testing.expect(P.has_dfa);
    try std.testing.expectEqualStrings("https://example.com", P.find("see https://example.com. more").?.slice);
    try std.testing.expectEqualStrings("https://a.com", P.find("x https://a.com, y").?.slice);
    try std.testing.expectEqualStrings("http://example.com", P.find("dot.http://example.com").?.slice);
    try std.testing.expect(P.find("no url here just text") == null);

    // Trailing single-char lookahead too: last digit of a run.
    const D = regex.Pattern("\\d(?!\\d)", .{});
    try std.testing.expect(D.has_dfa);
    try std.testing.expectEqualStrings("5", D.find("in 345 end").?.slice);

    // An ALTERNATION core is NOT peeled onto edge-look: the priority-cut core
    // DFA exposes only the highest-priority accept per start, so a lower-priority
    // branch's look-passing accept could be dropped (e.g. `(?:.|..)(?=x)`). Such
    // a pattern routes to the comptime tree backtracker (`has_dfa == false`) and
    // must still match correctly. (See `edge_look.regularGreedy`.)
    const Palt = regex.Pattern("(?:https?:\\/\\/|ftp:\\/\\/)[\\w\\-.~:\\/?#@!$&*+,;=%]+(?<![,.])", .{});
    try std.testing.expect(!Palt.has_dfa);
    try std.testing.expectEqualStrings("ftp://a.com", Palt.find("x ftp://a.com, y").?.slice);
    try std.testing.expectEqualStrings("https://example.com", Palt.find("see https://example.com. more").?.slice);
}

test "edge-look: alternation core is not peeled onto the priority-cut DFA" {
    const a = std.testing.allocator;
    // Regression: an alternation in the core must NOT be peeled onto edge-look.
    // The priority-cut core DFA exposes only the highest-priority accept per
    // start, so when that branch's accept fails the trailing look a lower-
    // priority branch's *passing* accept would be dropped — wrong span / spurious
    // no-match. These route to the (correct) tree backtracker instead.
    try std.testing.expectEqualStrings("ab", (try slice(a, "(?:.|..)(?=x)", "abx")).?);
    try std.testing.expectEqualStrings("foobar", (try slice(a, "(?:foo|foobar)(?=X)", "foobarX")).?);
    try std.testing.expectEqualStrings("abc", (try slice(a, "(?:ab|abc)(?!c)", "abc")).?);
    // Comptime peer agrees and likewise does not engage the DFA peel.
    const P = regex.Pattern("(?:.|..)(?=x)", .{});
    try std.testing.expect(!P.has_dfa);
    try std.testing.expectEqualStrings("ab", P.find("abx").?.slice);
}

test "edge-look: comptime == runtime over multi-match inputs (findAll/count)" {
    const a = std.testing.allocator;
    // Patterns that moved off the backtracker+seek onto the edge-look peel;
    // pin comptime span-for-span equal to runtime over multi-match inputs.
    const cases = .{
        .{ "[A-Za-z]+ (?=\\d)", "foo 42 bar baz 9 qux  10 zzz" },
        .{ "x[0-9]*y+(?!Z)", "x12yyy x0yZ xy xyyyZ x99y end" },
        .{ "(?:https?:\\/\\/)[\\w\\-.~:\\/?#@!$&*+,;=%]+(?<![,.])", "a https://x.com, b http://y.io. c https://z.dev/p done" },
    };
    inline for (cases) |c| {
        const P = regex.Pattern(c[0], .{});
        try std.testing.expect(P.has_dfa); // edge-look engaged
        var rx = try Regex.compile(a, c[0]);
        defer rx.deinit();
        try std.testing.expectEqual(try rx.count(c[1]), P.count(c[1]));
        const rms = try rx.findAll(a, c[1]);
        defer a.free(rms);
        const cms = try P.findAll(a, c[1]);
        defer a.free(cms);
        try std.testing.expectEqual(rms.len, cms.len);
        for (rms, cms) |rm, cm| try std.testing.expectEqualStrings(rm.slice, cm.slice);
    }
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
