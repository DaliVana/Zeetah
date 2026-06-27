//! Cross-check: `parser.scanGroups` (the standalone byte-scanner that the two
//! front-ends call to size capture vectors + report group names) must agree
//! with the parser's REAL capture numbering — i.e. the `.cap` nodes the grammar
//! actually emits into the HIR (`set_idx` = 1-based group index).
//!
//! `scanGroups` re-implements the paren/class/escape/lookaround grammar a second
//! time (see its doc comment). When the two drift, capture vectors are mis-sized
//! and group names land on the wrong index — the documented `(?=(a)b)(a)(b)`
//! phantom-slot bug. This test pins the invariant the doc claims:
//!   scanGroups(pattern) == count of `.cap` nodes in parser(pattern)'s HIR
//! over a corpus that deliberately exercises the divergence-prone shapes
//! (captures inside look-ahead/behind, named groups, nesting, alternation,
//! non-capturing/atomic groups, backrefs, classes containing `(`).
//!
//! Captures inside a lookaround are parsed non-capturing (no `.cap` node), so
//! they must NOT be counted or named — the part of the grammar `scanGroups`
//! is most likely to get wrong.

const std = @import("std");
const zeetah = @import("zeetah");
const parser = zeetah.parser;
const hir = zeetah.hir;

/// The parser's authoritative capture numbering, read back from the HIR it
/// produced: every capturing group emits exactly one `.cap` node whose
/// `set_idx` is its 1-based number; non-capturing / atomic / in-lookaround
/// groups emit none. Returns the count and whether the indices form the
/// contiguous set {1..count} (a phantom/gap would break contiguity).
const CapInfo = struct { count: usize, max: usize, contiguous: bool };

fn parserCapInfo(pattern: []const u8) !CapInfo {
    var h = hir.Hir(null).initRuntime();
    defer h.deinit(std.testing.allocator);
    parser.parse(null, &h, std.testing.allocator, pattern, .{}) catch return error.ParseFailed;

    var seen = [_]bool{false} ** (hir.MAX_GROUPS + 1);
    var count: usize = 0;
    var maxi: usize = 0;
    for (h.nodes.items) |nd| {
        if (nd.tag != .cap) continue;
        const g: usize = nd.set_idx; // 1-based group index
        count += 1;
        if (g > maxi) maxi = g;
        if (g <= hir.MAX_GROUPS) seen[g] = true;
    }
    var contiguous = true;
    var k: usize = 1;
    while (k <= maxi) : (k += 1) {
        if (!seen[k]) contiguous = false;
    }
    return .{ .count = count, .max = maxi, .contiguous = contiguous };
}

test "scanGroups count agrees with the parser's HIR capture numbering" {
    const patterns = [_][]const u8{
        // plain / nested / alternation
        "(a)(b)(c)",
        "((a)(b))(c)",
        "(a)|(b)",
        "(a(b(c)))",
        // non-capturing & atomic groups create no `.cap` node
        "(?:ab)+(x)(y)",
        "(?>ab)(x)",
        "(?:(?:a)(b))(c)",
        // named groups
        "(?<year>\\d{4})-(?<month>\\d{2})-(?<day>\\d{2})",
        "(?P<user>\\w+)@(?P<host>[\\w.]+)",
        // backrefs (the `\1` is an escape, not a group open)
        "(a)\\1",
        "(?<w>\\w+)\\k<w>",
        // classes containing `(` / `)` must not be miscounted
        "([(])(x)",
        "(a)[)(]+(b)",
        // THE regression: a capture inside a look-ahead must not be counted,
        // and must not shift the following groups' numbers (phantom slot).
        "(?=(a)b)(a)(b)",
        "(?!(z))(a)(b)",
        "(?<=(a))(b)",
        "(?<!(z))(b)",
        // named capture inside a lookaround: not counted, not named
        "(?=(?<inner>a))(?<outer>b)",
        // realistic bench-style shapes
        "(\\d{4})-(\\d{2})-(\\d{2})",
        "(\\w+)\\s+(\\w+)",
        "(https?)://([^/]+)(/.*)?",
    };

    for (patterns) |pat| {
        var names = [_]?[]const u8{null} ** (hir.MAX_GROUPS + 1);
        const sg = parser.scanGroups(pat, &names);
        const info = try parserCapInfo(pat);
        // The whole point: the two grammars report the same group count.
        std.testing.expectEqual(info.count, sg) catch |e| {
            std.debug.print("pattern {s}: scanGroups={d} but HIR has {d} .cap nodes\n", .{ pat, sg, info.count });
            return e;
        };
        // The parser numbers groups 1..n contiguously; max index must equal the
        // count and have no gap (a phantom slot would violate this).
        try std.testing.expectEqual(info.count, info.max);
        try std.testing.expect(info.contiguous);
    }
}

test "scanGroups places names at the right indices (and skips in-lookaround names)" {
    // Named groups land on their 1-based index.
    {
        var names = [_]?[]const u8{null} ** (hir.MAX_GROUPS + 1);
        const n = parser.scanGroups("(?<year>\\d{4})-(?<month>\\d{2})", &names);
        try std.testing.expectEqual(@as(usize, 2), n);
        try std.testing.expectEqualStrings("year", names[1].?);
        try std.testing.expectEqualStrings("month", names[2].?);
    }
    // A named capture INSIDE a lookahead is not counted, so the following named
    // group keeps index 1 and the inner name never appears.
    {
        var names = [_]?[]const u8{null} ** (hir.MAX_GROUPS + 1);
        const n = parser.scanGroups("(?=(?<inner>a))(?<outer>b)", &names);
        try std.testing.expectEqual(@as(usize, 1), n);
        try std.testing.expectEqualStrings("outer", names[1].?);
        try std.testing.expect(names[2] == null);
    }
    // Unnamed groups leave a null name at their index.
    {
        var names = [_]?[]const u8{null} ** (hir.MAX_GROUPS + 1);
        const n = parser.scanGroups("(a)(?<b>x)(c)", &names);
        try std.testing.expectEqual(@as(usize, 3), n);
        try std.testing.expect(names[1] == null);
        try std.testing.expectEqualStrings("b", names[2].?);
        try std.testing.expect(names[3] == null);
    }
}
