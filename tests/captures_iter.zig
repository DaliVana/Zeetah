//! Capture-bearing iteration: `capturesFrom` (offset primitive),
//! `capturesAll` (owned slice) and `CapturesIterator` (streaming). These are
//! the capture analogues of `nextSpanFrom`/`findAll`/`iterator` — same
//! non-overlapping advance rule, but each match carries its owned `groups`.
//! `std.testing.allocator` is the leak oracle: every owned `Match` is
//! `deinit`'d and every owned slice freed.

const std = @import("std");
const regex = @import("zeetah");
const Regex = regex.Regex;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

// --- capturesFrom: leftmost match at/after an absolute offset, absolute coords.

test "capturesFrom: returns the match at/after pos, in absolute coordinates" {
    const a = std.testing.allocator;
    var rx = try Regex.compile(a, "(\\d+)");
    defer rx.deinit();
    const in = "aa 12 bb 345"; // "12" @ [3..5], "345" @ [9..12]

    // pos before the first match -> first match.
    {
        var m = (try rx.capturesFrom(a, in, 0)).?;
        defer m.deinit(a);
        try expectEqualStrings("12", m.slice);
        try expectEqual(@as(usize, 3), m.start);
        try expectEqual(@as(usize, 5), m.end);
        try expectEqualStrings("12", m.groups[1].?.slice);
        try expectEqual(@as(usize, 3), m.groups[1].?.start);
        try expectEqual(@as(usize, 5), m.groups[1].?.end);
    }
    // pos past the first match -> second match, still absolute.
    {
        var m = (try rx.capturesFrom(a, in, 6)).?;
        defer m.deinit(a);
        try expectEqualStrings("345", m.slice);
        try expectEqual(@as(usize, 9), m.start);
        try expectEqual(@as(usize, 12), m.end);
        try expectEqualStrings("345", m.groups[1].?.slice);
        try expectEqual(@as(usize, 9), m.groups[1].?.start);
    }
    // pos at end -> no match.
    {
        const m = try rx.capturesFrom(a, in, in.len);
        try expect(m == null);
    }
}

// The slot-shift path: an engine that routes to the backtracker (lookahead)
// must still report group spans in absolute coordinates when pos > 0.
test "capturesFrom: backtracker engine shifts group slots to absolute coords" {
    const a = std.testing.allocator;
    var rx = try Regex.compile(a, "(\\d+)(?=px)");
    defer rx.deinit();
    const in = "w 10px h 200px"; // "10" @ [2..4], "200" @ [9..12]
    var m = (try rx.capturesFrom(a, in, 5)).?;
    defer m.deinit(a);
    try expectEqualStrings("200", m.slice);
    try expectEqual(@as(usize, 9), m.start);
    try expectEqual(@as(usize, 12), m.end);
    try expectEqualStrings("200", m.groups[1].?.slice);
    try expectEqual(@as(usize, 9), m.groups[1].?.start);
    try expectEqual(@as(usize, 12), m.groups[1].?.end);
}

// --- capturesAll

test "capturesAll: count matches findAll; groups populated per match" {
    const a = std.testing.allocator;
    var rx = try Regex.compile(a, "(\\d+)-(\\d+)");
    defer rx.deinit();
    const in = "a 1-2 b 33-44 c 5-6";

    const fa = try rx.findAll(a, in);
    defer a.free(fa);

    const ms = try rx.capturesAll(a, in);
    defer {
        for (ms) |*m| m.deinit(a);
        a.free(ms);
    }
    try expectEqual(fa.len, ms.len);
    try expectEqual(@as(usize, 3), ms.len);
    try expectEqualStrings("1-2", ms[0].slice);
    try expectEqualStrings("1", ms[0].groups[1].?.slice);
    try expectEqualStrings("2", ms[0].groups[2].?.slice);
    try expectEqualStrings("33-44", ms[1].slice);
    try expectEqualStrings("33", ms[1].groups[1].?.slice);
    try expectEqualStrings("44", ms[1].groups[2].?.slice);
    try expectEqualStrings("5", ms[2].groups[1].?.slice);
    try expectEqualStrings("6", ms[2].groups[2].?.slice);
}

test "capturesAll: named groups resolve on every match" {
    const a = std.testing.allocator;
    var rx = try Regex.compile(a, "(?<k>\\w+)=(?<v>\\d+)");
    defer rx.deinit();
    const ms = try rx.capturesAll(a, "a=1 bb=22 ccc=333");
    defer {
        for (ms) |*m| m.deinit(a);
        a.free(ms);
    }
    try expectEqual(@as(usize, 3), ms.len);
    try expectEqualStrings("a", ms[0].groupByName("k").?.slice);
    try expectEqualStrings("1", ms[0].groupByName("v").?.slice);
    try expectEqualStrings("bb", ms[1].groupByName("k").?.slice);
    try expectEqualStrings("333", ms[2].groupByName("v").?.slice);
}

test "capturesAll: non-participating group is null on the matches that skip it" {
    const a = std.testing.allocator;
    var rx = try Regex.compile(a, "a(b)?(c)");
    defer rx.deinit();
    const ms = try rx.capturesAll(a, "ac abc");
    defer {
        for (ms) |*m| m.deinit(a);
        a.free(ms);
    }
    try expectEqual(@as(usize, 2), ms.len);
    try expect(ms[0].groups[1] == null); // "ac": no b
    try expectEqualStrings("c", ms[0].groups[2].?.slice);
    try expectEqualStrings("b", ms[1].groups[1].?.slice); // "abc": b present
}

test "capturesAll: no-group pattern yields whole-match-only entries" {
    const a = std.testing.allocator;
    var rx = try Regex.compile(a, "cat");
    defer rx.deinit();
    const ms = try rx.capturesAll(a, "cat dog cat");
    defer {
        for (ms) |*m| m.deinit(a);
        a.free(ms);
    }
    try expectEqual(@as(usize, 2), ms.len);
    try expectEqualStrings("cat", ms[0].slice);
    try expectEqualStrings("cat", ms[1].slice);
}

test "capturesAll: no match / empty input" {
    const a = std.testing.allocator;
    var rx = try Regex.compile(a, "(\\d+)");
    defer rx.deinit();
    const none = try rx.capturesAll(a, "no digits here");
    defer a.free(none); // no matches -> nothing to deinit
    try expectEqual(@as(usize, 0), none.len);
    const empty = try rx.capturesAll(a, "");
    defer a.free(empty);
    try expectEqual(@as(usize, 0), empty.len);
}

// --- CapturesIterator: same match set, streaming, caller frees each Match.

test "capturesIterator: yields the same matches as capturesAll" {
    const a = std.testing.allocator;
    var rx = try Regex.compile(a, "(\\d+)-(\\d+)");
    defer rx.deinit();
    const in = "a 1-2 b 33-44 c 5-6";

    var it = rx.capturesIterator(in);
    defer it.deinit();
    var n: usize = 0;
    while (try it.next(a)) |mm| {
        var m = mm;
        defer m.deinit(a);
        switch (n) {
            0 => try expectEqualStrings("1", m.groups[1].?.slice),
            1 => try expectEqualStrings("33", m.groups[1].?.slice),
            2 => try expectEqualStrings("6", m.groups[2].?.slice),
            else => unreachable,
        }
        n += 1;
    }
    try expectEqual(@as(usize, 3), n);
}

// Zero-width matches must advance by one (no infinite loop) and produce the
// same number of matches as findAll on the same pattern.
test "capturesIterator: zero-width matches advance and match findAll count" {
    const a = std.testing.allocator;
    var rx = try Regex.compile(a, "(\\d*)"); // matches empty everywhere
    defer rx.deinit();
    const in = "a1b22";

    const fa = try rx.findAll(a, in);
    defer a.free(fa);

    var it = rx.capturesIterator(in);
    defer it.deinit();
    var n: usize = 0;
    while (try it.next(a)) |mm| {
        var m = mm;
        m.deinit(a);
        n += 1;
    }
    try expectEqual(fa.len, n);
}
