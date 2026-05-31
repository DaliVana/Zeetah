//! Doc-test: compile-and-run mirror of the runnable snippets in README.md and
//! docs/EXAMPLES.md. CI runs this (via `zig build test` and `zig build
//! doctest`), so a documented example that stops compiling — e.g. an stdlib
//! rename like `GeneralPurposeAllocator` → `DebugAllocator` on a new Zig, or an
//! API signature change — fails the build instead of silently rotting in the
//! docs.
//!
//! If you change an example in README.md / docs/EXAMPLES.md, change it here too
//! (and vice-versa). Behavioural tests use `std.testing.allocator` as a leak
//! oracle; one test deliberately constructs the allocator exactly as the
//! README Quick Start shows, to guard that idiom against stdlib churn.

const std = @import("std");
const zeetah = @import("zeetah");
const Regex = zeetah.Regex;
const a = std.testing.allocator;
const eqs = std.testing.expectEqualStrings;
const eq = std.testing.expectEqual;

test "README Quick Start — DebugAllocator idiom (guards the doc allocator setup)" {
    // This mirrors the README/EXAMPLES `pub fn main` allocator preamble exactly,
    // so the documented idiom can never compile in the docs but not in reality.
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var re = try Regex.compile(allocator, "\\d{3}-\\d{4}");
    defer re.deinit();
    const m = (try re.find("call 555-1234 now")).?;
    try eqs("555-1234", m.slice);
    try eq(@as(usize, 5), m.start);
    try eq(@as(usize, 13), m.end);
    try std.testing.expect(!try re.isMatch("nope"));
}

test "find / isMatch" {
    var re = try Regex.compile(a, "\\d+");
    defer re.deinit();
    try eqs("12345", (try re.find("Order #12345 shipped")).?.slice);
    var anchored = try Regex.compile(a, "^[a-zA-Z0-9_]{3,16}$");
    defer anchored.deinit();
    try std.testing.expect(try anchored.isMatch("good_name"));
    try std.testing.expect(!try anchored.isMatch("x"));
}

test "findAll / iterator / count" {
    var re = try Regex.compile(a, "\\d+");
    defer re.deinit();
    const all = try re.findAll(a, "a1 b22 c333");
    defer a.free(all);
    try eq(@as(usize, 3), all.len);
    try eqs("333", all[2].slice);

    var it = re.iterator("a1 b22 c333");
    defer it.deinit();
    var n: usize = 0;
    while (try it.next(a)) |_| n += 1;
    try eq(@as(usize, 3), n);
    try eq(@as(usize, 3), try re.count("a1 b22 c333"));
}

test "replace template + replaceLiteral + split" {
    var digits = try Regex.compile(a, "\\d+");
    defer digits.deinit();
    const hashed = try digits.replaceAll(a, "a1 b22 c333", "#");
    defer a.free(hashed);
    try eqs("a# b# c#", hashed);

    var date = try Regex.compile(a, "(\\d{4})-(\\d{2})-(\\d{2})");
    defer date.deinit();
    const iso = try date.replaceAll(a, "2024-03-15", "$3/$2/$1");
    defer a.free(iso);
    try eqs("15/03/2024", iso);

    const lit = try digits.replaceAllLiteral(a, "a1 b22", "$1");
    defer a.free(lit);
    try eqs("a$1 b$1", lit);

    var ws = try Regex.compile(a, "\\s+");
    defer ws.deinit();
    const parts = try ws.split(a, "one two  three");
    defer a.free(parts);
    try eq(@as(usize, 3), parts.len);
    try eqs("three", parts[2]);
}

test "captures (first) + capturesAll + capturesIterator" {
    var re = try Regex.compile(a, "(?<year>\\d{4})-(\\d{2})-(\\d{2})");
    defer re.deinit();
    // find ignores groups
    try eq(@as(usize, 0), (try re.find("Date: 2024-03-15")).?.groups.len);
    // captures opts in
    var m = (try re.captures(a, "Date: 2024-03-15")).?;
    defer m.deinit(a);
    try eqs("2024-03-15", m.groups[0].?.slice);
    try eqs("2024", m.groups[1].?.slice);
    try eqs("2024", m.groupByName("year").?.slice);

    var kv = try Regex.compile(a, "(?<k>\\w+)=(?<v>\\d+)");
    defer kv.deinit();
    const all = try kv.capturesAll(a, "a=1 bb=22");
    defer {
        for (all) |*cm| cm.deinit(a);
        a.free(all);
    }
    try eq(@as(usize, 2), all.len);
    try eqs("bb", all[1].groupByName("k").?.slice);

    var it = kv.capturesIterator("a=1 bb=22");
    defer it.deinit();
    var count: usize = 0;
    while (try it.next(a)) |mm| {
        var cm = mm;
        cm.deinit(a);
        count += 1;
    }
    try eq(@as(usize, 2), count);
}

test "flags: case_insensitive / dot_all / multiline + inline flags" {
    var ci = try Regex.compileWithFlags(a, "a.b", .{ .case_insensitive = true, .dot_all = true });
    defer ci.deinit();
    try std.testing.expect(try ci.isMatch("A\nB"));

    var ml = try Regex.compileWithFlags(a, "^\\w+", .{ .multiline = true });
    defer ml.deinit();
    const lines = try ml.findAll(a, "alpha\nbeta\ngamma");
    defer a.free(lines);
    try eq(@as(usize, 3), lines.len);
    try eqs("gamma", lines[2].slice);

    // unicode flag is the one rejected flag
    try std.testing.expectError(error.NotImplemented, Regex.compileWithFlags(a, "x", .{ .unicode = true }));

    inline for (.{ "(?i)hello", "(?i:ab)c", "(?s)a.b", "(?x) a b c", "(?m)^x" }) |p| {
        var r = try Regex.compile(a, p);
        r.deinit();
    }
}

test "comptime Pattern: allocation-free static methods" {
    const Phone = zeetah.Pattern("[0-9]{3}-[0-9]{4}", .{});
    try std.testing.expect(Phone.isMatch("call 555-1234 now"));
    try eqs("555-1234", Phone.find("call 555-1234 now").?.slice);
    try eq(@as(usize, 1), Phone.count("call 555-1234 now"));

    const Word = zeetah.Pattern("[a-z]+", .{ .case_insensitive = true });
    try std.testing.expect(Word.isMatch("ZEETAH"));
}

test "Builder fluent build/compile + Patterns string factories" {
    var b = zeetah.Builder.init(a);
    defer b.deinit();
    _ = try b.literal("id-");
    _ = try b.digit();
    _ = try b.repeatExact(3);
    var re = try b.compile();
    defer re.deinit();
    try std.testing.expect(try re.isMatch("id-007"));

    var b2 = zeetah.Builder.init(a);
    defer b2.deinit();
    _ = try b2.startGroup();
    _ = try b2.word();
    _ = try b2.oneOrMore();
    _ = try b2.endGroup();
    const pattern = try b2.build();
    defer a.free(pattern);
    try eqs("(\\w+)", pattern);

    const pat = try zeetah.Patterns.email(a);
    defer a.free(pat);
    var email_re = try Regex.compile(a, pat);
    defer email_re.deinit();
    try std.testing.expect(try email_re.isMatch("dev@example.com"));
}
