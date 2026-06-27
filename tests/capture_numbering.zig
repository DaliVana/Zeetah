//! Guard for the unified capture-numbering recognizer.
//!
//! `parser.parseCaptures` is the SINGLE source of truth for capture-group
//! numbering + `(?<name>)` names. (The old standalone `scanGroups` byte-scanner
//! — a second copy of the paren/class/escape/lookaround grammar that could drift
//! from the real parse, as the `(?=(a)b)(a)(b)` phantom-slot bug once showed —
//! was deleted; both front-ends now read the numbering the parser emits.)
//!
//! This test pins the recognizer's internal consistency: the group count it
//! REPORTS (`out_ng`) must equal the number of `.cap` nodes it actually emits
//! into the HIR, with contiguous 1..N indices (no phantom/gap), over a corpus
//! that exercises the divergence-prone shapes — captures inside look-ahead/behind
//! (which must NOT be counted or named), named groups, nesting, alternation,
//! non-capturing/atomic groups, backrefs, and classes containing `(`.

const std = @import("std");
const zeetah = @import("zeetah");
const parser = zeetah.parser;
const hir = zeetah.hir;

const CapCheck = struct {
    /// `parseCaptures` reported group count.
    reported: usize,
    /// Count of `.cap` nodes the parser baked into the HIR.
    cap_nodes: usize,
    /// Highest `.cap` `set_idx` seen.
    max_idx: usize,
    /// The `.cap` indices form the contiguous set {1..cap_nodes} (no phantom/gap).
    contiguous: bool,
    /// `parseCaptures` reported names, by 1-based group index.
    names: [hir.MAX_GROUPS + 1]?[]const u8,
};

fn check(pattern: []const u8) !CapCheck {
    var h = hir.Hir(null).initRuntime();
    defer h.deinit(std.testing.allocator);
    var names = [_]?[]const u8{null} ** (hir.MAX_GROUPS + 1);
    var ng: usize = 0;
    parser.parseCaptures(null, &h, std.testing.allocator, pattern, .{}, &ng, &names) catch return error.ParseFailed;

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
    return .{ .reported = ng, .cap_nodes = count, .max_idx = maxi, .contiguous = contiguous, .names = names };
}

test "parseCaptures count matches the .cap nodes the parser emits" {
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
        // a capture inside a look-ahead/behind must NOT be counted, and must not
        // shift the following groups' numbers (the phantom-slot bug class).
        "(?=(a)b)(a)(b)",
        "(?!(z))(a)(b)",
        "(?<=(a))(b)",
        "(?<!(z))(b)",
        "(?=(?<inner>a))(?<outer>b)",
        // realistic bench-style shapes
        "(\\d{4})-(\\d{2})-(\\d{2})",
        "(\\w+)\\s+(\\w+)",
        "(https?)://([^/]+)(/.*)?",
    };

    for (patterns) |pat| {
        const c = check(pat) catch |e| {
            std.debug.print("pattern {s}: parse failed\n", .{pat});
            return e;
        };
        // The crux: the reported group count equals the `.cap` nodes baked.
        std.testing.expectEqual(c.cap_nodes, c.reported) catch |e| {
            std.debug.print("pattern {s}: parseCaptures reported {d} but HIR has {d} .cap nodes\n", .{ pat, c.reported, c.cap_nodes });
            return e;
        };
        // Numbered 1..N contiguously (a phantom/gap would break this).
        try std.testing.expectEqual(c.cap_nodes, c.max_idx);
        try std.testing.expect(c.contiguous);
    }
}

test "parseCaptures places names at the right indices (and skips in-lookaround names)" {
    // Named groups land on their 1-based index.
    {
        const c = try check("(?<year>\\d{4})-(?<month>\\d{2})");
        try std.testing.expectEqual(@as(usize, 2), c.reported);
        try std.testing.expectEqualStrings("year", c.names[1].?);
        try std.testing.expectEqualStrings("month", c.names[2].?);
    }
    // A named capture INSIDE a lookahead is not counted, so the following named
    // group keeps index 1 and the inner name never appears.
    {
        const c = try check("(?=(?<inner>a))(?<outer>b)");
        try std.testing.expectEqual(@as(usize, 1), c.reported);
        try std.testing.expectEqualStrings("outer", c.names[1].?);
        try std.testing.expect(c.names[2] == null);
    }
    // Unnamed groups leave a null name at their index.
    {
        const c = try check("(a)(?<b>x)(c)");
        try std.testing.expectEqual(@as(usize, 3), c.reported);
        try std.testing.expect(c.names[1] == null);
        try std.testing.expectEqualStrings("b", c.names[2].?);
        try std.testing.expect(c.names[3] == null);
    }
}
