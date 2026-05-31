//! Replacement templates: `replace`/`replaceAll` expand `$`-references
//! ($1, ${name}, $0/$&, $$) against capture groups; `replaceLiteral`/
//! `replaceAllLiteral` insert the replacement verbatim. `std.testing.allocator`
//! is the leak oracle (every result slice is freed).

const std = @import("std");
const regex = @import("zeetah");
const Regex = regex.Regex;
const expectEqualStrings = std.testing.expectEqualStrings;

fn expectReplaceAll(a: std.mem.Allocator, pat: []const u8, in: []const u8, tmpl: []const u8, want: []const u8) !void {
    var rx = try Regex.compile(a, pat);
    defer rx.deinit();
    const got = try rx.replaceAll(a, in, tmpl);
    defer a.free(got);
    try expectEqualStrings(want, got);
}

fn expectReplace(a: std.mem.Allocator, pat: []const u8, in: []const u8, tmpl: []const u8, want: []const u8) !void {
    var rx = try Regex.compile(a, pat);
    defer rx.deinit();
    const got = try rx.replace(a, in, tmpl);
    defer a.free(got);
    try expectEqualStrings(want, got);
}

test "replace template: numbered groups reorder" {
    const a = std.testing.allocator;
    try expectReplaceAll(a, "(\\w+)@(\\w+)", "a@b c@d", "$2.$1", "b.a d.c");
    try expectReplace(a, "(\\d{4})-(\\d{2})-(\\d{2})", "d=2024-03-15", "$3/$2/$1", "d=15/03/2024");
}

test "replace template: named groups" {
    const a = std.testing.allocator;
    try expectReplaceAll(a, "(?<k>\\w+)=(?<v>\\d+)", "a=1 bb=22", "${v}:${k}", "1:a 22:bb");
    // all-digit ${N} is a numbered reference
    try expectReplaceAll(a, "(\\d)(\\d)", "ab 47", "${2}${1}", "ab 74");
}

test "replace template: $0 and $& are the whole match" {
    const a = std.testing.allocator;
    try expectReplaceAll(a, "\\d+", "a1 b22", "<$&>", "a<1> b<22>");
    try expectReplaceAll(a, "\\d+", "a1 b22", "<$0>", "a<1> b<22>");
    try expectReplaceAll(a, "\\d+", "a1 b22", "[${0}]", "a[1] b[22]");
}

test "replace template: $$ is a literal dollar" {
    const a = std.testing.allocator;
    try expectReplaceAll(a, "(\\d+)", "x 5 y", "$$$1", "x $5 y");
    try expectReplaceAll(a, "\\d+", "n7", "$$", "n$");
}

test "replace template: greedy digits vs ${n} disambiguation" {
    const a = std.testing.allocator;
    // one group: $12 = group 12 (out of range -> empty); ${1}2 = group 1 then '2'
    try expectReplace(a, "(\\d)", "5", "$12", "");
    try expectReplace(a, "(\\d)", "5", "${1}2", "52");
}

test "replace template: out-of-range and missing references expand to empty" {
    const a = std.testing.allocator;
    try expectReplace(a, "(\\d+)", "n=9", "[$9]", "n=[]"); // no group 9
    try expectReplace(a, "(?<x>\\d+)", "n=9", "[${nope}]", "n=[]"); // unknown name
}

test "replace template: non-participating group expands to empty" {
    const a = std.testing.allocator;
    try expectReplaceAll(a, "a(b)?(c)", "ac abc", "[$1$2]", "[c] [bc]");
}

test "replace template: no capture groups -> $N empty, $& whole" {
    const a = std.testing.allocator;
    try expectReplaceAll(a, "cat", "cat dog cat", "$1", " dog "); // $1 empty
    try expectReplaceAll(a, "cat", "cat dog", "$&!", "cat! dog");
}

test "replace template: '$' not starting a valid reference is literal" {
    const a = std.testing.allocator;
    try expectReplaceAll(a, "\\d", "5", "a$b", "a$b"); // '$b' has no group -> literal '$' + 'b'
    try expectReplaceAll(a, "\\d", "5", "end$", "end$"); // trailing '$'
}

test "replace template: zero-width match insertion" {
    const a = std.testing.allocator;
    // lookahead is zero-width; '$&' (whole match) is empty there
    try expectReplaceAll(a, "(?=b)", "abc", "[$&]", "a[]bc");
}

// --- the verbatim escape hatch and the no-'$' fast path

test "replaceLiteral: inserts replacement verbatim ($ is not special)" {
    const a = std.testing.allocator;
    var rx = try Regex.compile(a, "(\\d+)");
    defer rx.deinit();
    const got = try rx.replaceAllLiteral(a, "x 5 y", "$1");
    defer a.free(got);
    try expectEqualStrings("x $1 y", got); // literal "$1", no substitution
    const one = try rx.replaceLiteral(a, "x 5 y 6", "#");
    defer a.free(one);
    try expectEqualStrings("x # y 6", one);
}

test "replaceAll: no-'$' template equals replaceAllLiteral" {
    const a = std.testing.allocator;
    var rx = try Regex.compile(a, "\\d+");
    defer rx.deinit();
    const via_all = try rx.replaceAll(a, "a1 b22 c333", "#");
    defer a.free(via_all);
    const via_lit = try rx.replaceAllLiteral(a, "a1 b22 c333", "#");
    defer a.free(via_lit);
    try expectEqualStrings(via_lit, via_all);
    try expectEqualStrings("a# b# c#", via_all);
}

test "replace: no match returns input copy" {
    const a = std.testing.allocator;
    try expectReplace(a, "(\\d+)", "no digits", "$1", "no digits");
}
