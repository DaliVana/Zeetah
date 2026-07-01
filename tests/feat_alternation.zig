//! Per-feature: alternation (`|`), grouped and factored alternatives, and
//! the planner's literal-alternation (Teddy) fast path staying correct.

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

test "alternation: binary a|b leftmost" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("b", (try slice(a, "a|b", "xxbxa")).?);
    try std.testing.expectEqualStrings("a", (try slice(a, "a|b", "zzazb")).?);
    var rx = try Regex.compile(a, "a|b");
    defer rx.deinit();
    try std.testing.expect(!try rx.isMatch("ccc"));
}

test "alternation: n-ary cat|dog|bird" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("dog", (try slice(a, "cat|dog|bird", "a dog ran")).?);
    try std.testing.expectEqualStrings("bird", (try slice(a, "cat|dog|bird", "the bird")).?);
}

test "alternation: large pure-literal set (NFA-overflow) routes to literal_alt" {
    const a = std.testing.allocator;
    // 60 distinct 6-byte literals: the naive Thompson NFA overflows MAX_NFA(256)
    // → the `.literal_alt` heap-trie engine. (Testing allocator ⇒ leak-checked.)
    var pat: std.ArrayList(u8) = .empty;
    defer pat.deinit(a);
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        if (i != 0) try pat.append(a, '|');
        var w: [6]u8 = undefined;
        _ = std.fmt.bufPrint(&w, "kw{d:0>4}", .{i}) catch unreachable;
        try pat.appendSlice(a, &w);
    }
    var rx = try Regex.compile(a, pat.items);
    defer rx.deinit();
    // count: 4 of the 5 tokens are in the set (kw9999 is not).
    try std.testing.expectEqual(@as(usize, 4), try rx.count("x kw0000 y kw0059 z kw0030 kw9999 kw0001"));
    try std.testing.expect(try rx.isMatch("zzz kw0042"));
    try std.testing.expect(!try rx.isMatch("nope nothing here"));
    try std.testing.expectEqualStrings("kw0007", (try slice(a, pat.items, "aa kw0007 bb")).?);
}

test "alternation: literal_alt is leftmost-first over prefixes/substrings" {
    const a = std.testing.allocator;
    // Pad with throwaway alternatives so the set overflows MAX_NFA and takes the
    // literal_alt path; the meaningful alternatives test source-order semantics.
    var pat: std.ArrayList(u8) = .empty;
    defer pat.deinit(a);
    try pat.appendSlice(a, "scatter|cat"); // substring "cat" must not pre-empt "scatter"
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        var w: [8]u8 = undefined;
        _ = std.fmt.bufPrint(&w, "|zz{d:0>4}", .{i}) catch unreachable;
        try pat.appendSlice(a, &w);
    }
    // Scanning "a scatter b": the whole word wins over the internal "cat".
    try std.testing.expectEqualStrings("scatter", (try slice(a, pat.items, "a scatter b")).?);
}

test "alternation: grouped (ab|cd)e" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("abe", (try slice(a, "(ab|cd)e", "zzabez")).?);
    try std.testing.expectEqualStrings("cde", (try slice(a, "(ab|cd)e", "xcdex")).?);
    var rx = try Regex.compile(a, "(ab|cd)e");
    defer rx.deinit();
    try std.testing.expect(!try rx.isMatch("abx cdx"));
}

test "alternation: factored foo|foobar is consistent with itself" {
    const a = std.testing.allocator;
    // Leftmost-first vs leftmost-longest is an engine policy; pin only that
    // it matches, the result is one of the alternatives, and the comptime
    // and runtime paths agree on it.
    const s = (try slice(a, "foo|foobar", "xx foobar yy")).?;
    try std.testing.expect(std.mem.eql(u8, s, "foo") or std.mem.eql(u8, s, "foobar"));

    const P = regex.Pattern("foo|foobar", .{});
    var rx = try Regex.compile(a, "foo|foobar");
    defer rx.deinit();
    const corpus = [_][]const u8{ "", "foo", "foobar", "a foobar b", "foofoo", "fo" };
    for (corpus) |in| {
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

test "alternation of literals: Teddy fast path findAll is correct" {
    const a = std.testing.allocator;
    var rx = try Regex.compile(a, "cat|dog|bird");
    defer rx.deinit();
    const ms = try rx.findAll(a, "a cat, a dog, a bird, a cat");
    defer a.free(ms);
    try std.testing.expectEqual(@as(usize, 4), ms.len);
    try std.testing.expectEqualStrings("cat", ms[0].slice);
    try std.testing.expectEqualStrings("dog", ms[1].slice);
    try std.testing.expectEqualStrings("bird", ms[2].slice);
    try std.testing.expectEqualStrings("cat", ms[3].slice);
}

test "alternation: literal fast path equals an independent recompile" {
    const a = std.testing.allocator;
    const pat = "red|green|blue";
    const corpus = [_][]const u8{
        "",                 "red",            "a green b",
        "blue and red",     "no colour here", "greenish bluefish",
    };
    var rx = try Regex.compile(a, pat);
    defer rx.deinit();
    for (corpus) |in| {
        var ref = try Regex.compile(a, pat);
        defer ref.deinit();
        var m = try rx.find(in);
        defer if (m) |*mm| mm.deinit(a);
        var rm = try ref.find(in);
        defer if (rm) |*mm| mm.deinit(a);
        try std.testing.expectEqual(rm == null, m == null);
        if (m) |mm| {
            try std.testing.expectEqual(rm.?.start, mm.start);
            try std.testing.expectEqual(rm.?.end, mm.end);
        }
    }
}
