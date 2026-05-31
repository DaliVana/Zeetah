//! Per-feature: the public API surface — isMatch / find / findAll / count /
//! replace / replaceAll / split / iterator, the capture-free Match contract,
//! and comptime⇄runtime agreement.

const std = @import("std");
const regex = @import("zeetah");
const Regex = regex.Regex;

test "public surface: types reachable through signatures are nameable" {
    // Regression guard for the alpha export rule: every type that appears in a
    // public method signature must be exportable by name (not only usable via
    // anonymous literal / inferred binding).
    const a = std.testing.allocator;
    const flags: regex.CompileFlags = .{ .case_insensitive = true };
    var rx = try Regex.compileWithFlags(a, "\\w+", flags);
    defer rx.deinit();
    var it: regex.CapturesIterator = rx.capturesIterator("a b");
    defer it.deinit();
    while (try it.next(a)) |mm| {
        var m = mm;
        m.deinit(a);
    }
    var mit: regex.MatchIterator = rx.iterator("a b");
    defer mit.deinit();
}

test "isMatch / find boundaries" {
    const a = std.testing.allocator;
    var rx = try Regex.compile(a, "\\d+");
    defer rx.deinit();
    try std.testing.expect(try rx.isMatch("abc123"));
    try std.testing.expect(!try rx.isMatch("abcdef"));
    var m = (try rx.find("abc123def")).?;
    defer m.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), m.start);
    try std.testing.expectEqual(@as(usize, 6), m.end);
    try std.testing.expectEqualStrings("123", m.slice);
}

test "findFrom: positional resume in absolute coordinates; find == findFrom(.,0)" {
    const a = std.testing.allocator;
    var rx = try Regex.compile(a, "\\d+");
    defer rx.deinit();
    const in = "a12 b345 c6";

    // `find` is exactly the pos-0 convenience for `findFrom`.
    var m0 = (try rx.find(in)).?;
    defer m0.deinit(a);
    var f0 = (try rx.findFrom(in, 0)).?;
    defer f0.deinit(a);
    try std.testing.expectEqual(m0.start, f0.start);
    try std.testing.expectEqual(m0.end, f0.end);
    try std.testing.expectEqualStrings("12", f0.slice);

    // Resuming past the first match yields the next, in absolute coordinates.
    var m1 = (try rx.findFrom(in, 3)).?;
    defer m1.deinit(a);
    try std.testing.expectEqual(@as(usize, 5), m1.start);
    try std.testing.expectEqual(@as(usize, 8), m1.end);
    try std.testing.expectEqualStrings("345", m1.slice);

    // pos == input.len is in-range and simply finds nothing (not an error).
    try std.testing.expect((try rx.findFrom(in, in.len)) == null);
}

test "Pattern on_oversize = .allow_oversized bakes a DFA over the soft budget" {
    // `\d\dx` needs several DFA states, so a `max_dfa_states` of 1 puts it over
    // the soft budget. `.compile_error` would reject it at compile time (and so
    // cannot be exercised from a normal test); `.allow_oversized` bakes the
    // larger table anyway — this file compiling at all is the proof, and the
    // match below confirms the baked table is correct.
    const P = regex.Pattern("\\d\\dx", .{ .max_dfa_states = 1, .on_oversize = .allow_oversized });
    comptime std.debug.assert(P.has_dfa);
    try std.testing.expect(P.isMatch("..42x.."));
    const m = P.find("ab12x").?;
    try std.testing.expectEqual(@as(usize, 2), m.start);
    try std.testing.expectEqual(@as(usize, 5), m.end);
    try std.testing.expectEqualStrings("12x", m.slice);
}

test "Match is capture-free: groups empty, groupByName null, deinit no-op" {
    const a = std.testing.allocator;
    var rx = try Regex.compile(a, "(ab)+c");
    defer rx.deinit();
    var m = (try rx.find("xababcx")).?;
    try std.testing.expectEqual(@as(usize, 0), m.groups.len);
    try std.testing.expect(m.groupByName("any") == null);
    try std.testing.expectEqualStrings("ababc", m.slice);
    m.deinit(a); // safe no-op, must not crash / double-free
    m.deinit(a);
}

test "findAll: non-overlapping, zero-width advances" {
    const a = std.testing.allocator;
    var rx = try Regex.compile(a, "a");
    defer rx.deinit();
    const ms = try rx.findAll(a, "banana");
    defer a.free(ms);
    try std.testing.expectEqual(@as(usize, 3), ms.len);
    try std.testing.expectEqual(@as(usize, 1), ms[0].start);
    try std.testing.expectEqual(@as(usize, 5), ms[2].start);

    var none = try Regex.compile(a, "zzz");
    defer none.deinit();
    const e = try none.findAll(a, "abc");
    defer a.free(e);
    try std.testing.expectEqual(@as(usize, 0), e.len);
}

test "count matches findAll length" {
    const a = std.testing.allocator;
    const P = regex.Pattern("\\d+", .{});
    var rx = try Regex.compile(a, "\\d+");
    defer rx.deinit();
    const in = "a1 b22 c333 d";
    const ms = try rx.findAll(a, in);
    defer a.free(ms);
    try std.testing.expectEqual(@as(usize, 3), ms.len);
    try std.testing.expectEqual(ms.len, P.count(in));
}

test "replace / replaceAll" {
    const a = std.testing.allocator;
    var rx = try Regex.compile(a, "\\d+");
    defer rx.deinit();

    const one = try rx.replace(a, "x1y22z333", "#");
    defer a.free(one);
    try std.testing.expectEqualStrings("x#y22z333", one);

    const all = try rx.replaceAll(a, "x1y22z333", "#");
    defer a.free(all);
    try std.testing.expectEqualStrings("x#y#z#", all);

    // No match → copy of input.
    const none = try rx.replace(a, "no digits", "#");
    defer a.free(none);
    try std.testing.expectEqualStrings("no digits", none);
}

test "split around matches" {
    const a = std.testing.allocator;
    var rx = try Regex.compile(a, ",");
    defer rx.deinit();
    const parts = try rx.split(a, "a,bb,,c");
    defer a.free(parts);
    try std.testing.expectEqual(@as(usize, 4), parts.len);
    try std.testing.expectEqualStrings("a", parts[0]);
    try std.testing.expectEqualStrings("bb", parts[1]);
    try std.testing.expectEqualStrings("", parts[2]);
    try std.testing.expectEqualStrings("c", parts[3]);
}

test "iterator: streaming and empty input" {
    const a = std.testing.allocator;
    var rx = try Regex.compile(a, "\\w+");
    defer rx.deinit();

    var it = rx.iterator("foo bar  baz");
    defer it.deinit();
    var seen: usize = 0;
    var last: []const u8 = "";
    while (try it.next(a)) |mm| {
        seen += 1;
        last = mm.slice;
    }
    try std.testing.expectEqual(@as(usize, 3), seen);
    try std.testing.expectEqualStrings("baz", last);

    var it2 = rx.iterator("");
    defer it2.deinit();
    try std.testing.expect((try it2.next(a)) == null);

    // A fresh iterator restarts from the beginning ("reset").
    var it3 = rx.iterator("one two");
    defer it3.deinit();
    try std.testing.expectEqualStrings("one", (try it3.next(a)).?.slice);
}

// ── Migrated from the retired tests/meta_phase4.zig gate ──────────────────
// The reverse-suffix strategy must be output-identical to a plain compile of
// the same pattern (it only adds a sound fast-negative + drives the reverse
// DFA), so find/isMatch agree with each other and with an independent recompile.
const rsuffix_corpus = [_][]const u8{
    "",
    "foobar",
    "Xfoobar",
    "  Zabcdefghijklmnopq  ",
    "no suffix here at all",
    "AAAAAAAAAAAAAAAAAAAAbcdefghijklmnopq",
    "Quick brown fox jumps over foobar end",
    "prefix Z then later foobar and foobar again",
    "UPPER then nothing matching",
    "z" ** 200 ++ "foobar",
};

test "reverse_suffix: find/isMatch consistent with an independent recompile" {
    const a = std.testing.allocator;
    const patterns = [_][]const u8{ "[A-Z].*foobar", "[A-Z]+.*abcdefghijklmnopq", "[a-z].*foobar" };
    inline for (patterns) |p| {
        var rx = try Regex.compile(a, p);
        defer rx.deinit();
        for (rsuffix_corpus) |in| {
            const is = try rx.isMatch(in);
            var m = try rx.find(in);
            defer if (m) |*mm| mm.deinit(a);
            try std.testing.expectEqual(is, m != null);
            if (m) |mm| try std.testing.expect(mm.end <= in.len and mm.start <= mm.end);

            var ref = try Regex.compile(a, p);
            defer ref.deinit();
            var rm = try ref.find(in);
            defer if (rm) |*mm| mm.deinit(a);
            try std.testing.expectEqual(m != null, rm != null);
            if (m) |mm| {
                try std.testing.expectEqual(mm.start, rm.?.start);
                try std.testing.expectEqual(mm.end, rm.?.end);
            }
        }
    }
}

// ── Migrated from the retired tests/meta_phase6.zig gate ──────────────────
// The comptime `Pattern` and the runtime `Regex` (both the unified pipeline)
// must agree on isMatch/find boundaries across the supported subset.
const cr_inputs = [_][]const u8{
    "",            "a",            "ab",          "abc",
    "abcabc",      "xabcy",        "AABBCC",      "123",
    "a1b2c3",      "hello world",  "the fox",     "no match",
    "aaaaaaaaaa",  "foobar",       "cat dog bird","x",
    "user@host.io","2026-05-17",   "Zfoobar end", "  spaces  ",
};

fn crAgree(comptime p: []const u8) !void {
    const a = std.testing.allocator;
    const P = regex.Pattern(p, .{});
    comptime std.debug.assert(P.has_dfa);
    var rx = try Regex.compile(a, p);
    defer rx.deinit();
    for (cr_inputs) |in| {
        try std.testing.expectEqual(P.isMatch(in), try rx.isMatch(in));
        const pm = P.find(in);
        var rm = try rx.find(in);
        defer if (rm) |*x| x.deinit(a);
        try std.testing.expectEqual(pm == null, rm == null);
        if (pm) |pmm| {
            try std.testing.expectEqual(pmm.start, rm.?.start);
            try std.testing.expectEqual(pmm.end, rm.?.end);
        }
    }
}

test "comptime Pattern <-> runtime Regex agree across the supported subset" {
    try crAgree("a");
    try crAgree("abc");
    try crAgree("hello");
    try crAgree("a|b");
    try crAgree("cat|dog|bird");
    try crAgree("foo|foobar");
    try crAgree("a*");
    try crAgree("a+b+");
    try crAgree("colou?r");
    try crAgree("a*?b");
    try crAgree("a{2,4}?b");
    try crAgree("[a-z]+");
    try crAgree("\\d+");
    try crAgree("a.c");
    try crAgree(".*x");
    try crAgree("^abc");
    try crAgree("abc$");
    try crAgree("^\\d+$");
    try crAgree("[a-z]+@[a-z]+\\.[a-z]+");
    try crAgree("abc[0-9]+z");
    try crAgree("hello.*world");
    try crAgree("[A-Z].*foobar");
}

test "comptime Pattern findAll/count parity with runtime Regex" {
    const a = std.testing.allocator;
    const P = regex.Pattern("ab+", .{});
    var rx = try Regex.compile(a, "ab+");
    defer rx.deinit();
    const in = "abbb ab a abxab abbbb";

    const rms = try rx.findAll(a, in);
    defer a.free(rms);
    const pms = try P.findAll(a, in);
    defer a.free(pms);
    try std.testing.expectEqual(rms.len, pms.len);
    for (rms, pms) |r, p| {
        try std.testing.expectEqual(r.start, p.start);
        try std.testing.expectEqual(r.end, p.end);
    }
}

// findAll + count parity for the comptime strategy arms that bake a literal
// prefilter around the DFA: `.lit_prefix` (leading literal Teddy-locate),
// `.reverse_suffix` (trailing literal fast-negative), and the `.dfa` arm with
// the `required` / `req_lit` necessary-condition prefilters from (a). These
// drive the shared `nextSpan` loop in each mode, so any drift from the runtime
// `Regex` (which uses the same `search.*` helpers) is caught here.
fn crAgreeMulti(comptime p: []const u8, in: []const u8) !void {
    const a = std.testing.allocator;
    const P = regex.Pattern(p, .{});
    comptime std.debug.assert(P.has_dfa);
    var rx = try Regex.compile(a, p);
    defer rx.deinit();

    try std.testing.expectEqual(try rx.count(in), P.count(in));

    const rms = try rx.findAll(a, in);
    defer a.free(rms);
    const pms = try P.findAll(a, in);
    defer a.free(pms);
    try std.testing.expectEqual(rms.len, pms.len);
    for (rms, pms) |r, pm| {
        try std.testing.expectEqual(r.start, pm.start);
        try std.testing.expectEqual(r.end, pm.end);
    }
}

test "comptime Pattern strategy arms (lit_prefix / reverse_suffix / req_lit) parity" {
    // lit_prefix: leading literal "hello", multiple hits + a near-miss.
    try crAgreeMulti("hello.*world", "hello world; hellish; hello big world; hello");
    // reverse_suffix: trailing literal "foobar" as a fast-negative gate.
    try crAgreeMulti("[A-Z].*foobar", "Xfoobar Yfoobar nope Zfoobarbaz");
    // req_lit: rare mandatory '@' recovers the start; adversarial input with
    // many leading first-byte candidates but no '@' must stay correct (and is
    // now linear, not the per-position O(n²) restart).
    try crAgreeMulti("[a-z]+@[a-z]+", "aaaaaaaaaaaaaaaaaaaa user@host more@x");
    // required byte: 'X' mandatory and absent on the long run, present later.
    try crAgreeMulti("a.*X", "aaaaaaaaaaaaaaaaaaaa then aXb and abcXd");
}
