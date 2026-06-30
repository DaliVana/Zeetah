//! Linear single-pass recogniser for the **adjacent-duplicate-token**
//! backreference shape `(\b CLASS+ \b) SEP \1` (e.g. `(\b[A-Za-z]+\b) \1` —
//! the `backref_word` workload). The `\b…\b` brackets force the captured
//! token to a *unique* length per start position (no quantifier
//! backtracking is possible — `\b` only holds at the maximal class-run
//! boundary), so the whole pattern reduces to: find a maximal CLASS run that
//! is a word, immediately followed by one SEP byte and a byte-identical copy
//! of the run. That is one O(n) forward scan instead of the tree
//! backtracker's O(n·tokenlen) per-position restart.
//!
//! Only this exact shape is recognised; anything else returns `null` from
//! `build` and routes to the unchanged `.backtrack` engine (no regression,
//! no semantic risk). Leftmost-first + capture semantics are identical to the
//! tree-walker: scanning start positions upward and taking the first that
//! satisfies the (unique-length) match is exactly what the backtracker does
//! for this shape; group `g` = the first token's span.

const std = @import("std");
const hir = @import("../hir.zig");
const cc = @import("charclass.zig");
const search = @import("search.zig");

const H = hir.Hir(null);
const NodeRef = hir.NodeRef;

pub const Span = search.Span;

// `isWord` / set membership now come from `charclass.zig` (`cc`).

pub const DupWord = struct {
    class: [32]u8, // CLASS bitmap (the `+` body, e.g. [A-Za-z])
    sep: [32]u8, // separator bitmap (e.g. ' ')
    group: u32, // capturing group index (1-based) the backref names

    /// Leftmost match at/after absolute `from`, or null. Also reports the
    /// captured token span via `g_start`/`g_end` out-params (group `group`).
    pub fn findCap(self: *const DupWord, input: []const u8, from: usize, g_start: *usize, g_end: *usize) ?Span {
        const n = input.len;
        var s = from;
        while (s < n) : (s += 1) {
            // `\b` at s: s is a word start (BOF or prev non-word) and the
            // first byte is in CLASS (⇒ a word char for the classes this
            // shape uses; the trailing `\b` is what bounds the run).
            if (s != 0 and cc.isWord(input[s - 1])) continue;
            if (!cc.hasBit(&self.class, input[s])) continue;

            // Maximal CLASS run = the unique `\b CLASS+ \b` token.
            var e = s + 1;
            while (e < n and cc.hasBit(&self.class, input[e])) : (e += 1) {}
            // Trailing `\b` must hold at e: e==EOF or input[e] is non-word.
            // If input[e] is a word char outside CLASS, `\b` fails ⇒ skip.
            if (e < n and cc.isWord(input[e])) continue;

            // SEP byte, then a byte-identical second copy of the token.
            const w = e - s;
            if (e >= n or !cc.hasBit(&self.sep, input[e])) continue;
            const t = e + 1; // second token start
            if (t + w > n) continue;
            if (!std.mem.eql(u8, input[s..e], input[t .. t + w])) continue;

            g_start.* = s;
            g_end.* = e;
            return .{ .start = s, .end = t + w };
        }
        return null;
    }

    pub fn find(self: *const DupWord, input: []const u8, from: usize) ?Span {
        var gs: usize = 0;
        var ge: usize = 0;
        return self.findCap(input, from, &gs, &ge);
    }
};

/// Recognise the exact `(\b CLASS+ \b) SEP \1` HIR shape; else null.
/// Runtime alias over the heap HIR — every existing caller is unchanged.
pub fn build(h: *const H) ?DupWord {
    return buildAt(null, h);
}

/// `build`, generic over the HIR store cap, so the comptime `Pattern` path can
/// recognise the shape over its baked `Hir(N)` exactly as the runtime does over
/// `Hir(null)`. The body touches only `h.root`/`h.node`/`h.setBitmap` and the
/// pure `cc.*` predicates, all identical across stores, and returns a
/// HIR-free `DupWord` value (two bitmaps + a group id) — fully comptime-bakeable.
pub fn buildAt(comptime cap: ?usize, h: *const hir.Hir(cap)) ?DupWord {
    if (h.root == hir.none) return null;
    if (h.anchored_start or h.anchored_end) return null; // keep it simple/sound

    // root = concat( concat( cap_g(BODY), set(SEP) ), backref(g) )
    const root = h.node(h.root);
    if (root.tag != .concat) return null;
    const left = h.node(root.a);
    const br = h.node(root.b);
    if (br.tag != .backref) return null;
    const g = br.set_idx;
    if (left.tag != .concat) return null;
    const capn = h.node(left.a);
    const sepn = h.node(left.b);
    if (capn.tag != .cap or capn.set_idx != g) return null;
    if (sepn.tag != .set) return null;

    // BODY = concat( concat( look(\b), plus(set CLASS) ), look(\b) )
    const body = h.node(capn.a);
    if (body.tag != .concat) return null;
    const body_a = h.node(body.a); // concat( look\b, plus )
    const tb = h.node(body.b); // trailing look \b
    if (tb.tag != .look or tb.set_idx != @intFromEnum(hir.LookKind.word_boundary)) return null;
    if (body_a.tag != .concat) return null;
    const lb = h.node(body_a.a); // leading look \b
    const plusn = h.node(body_a.b);
    if (lb.tag != .look or lb.set_idx != @intFromEnum(hir.LookKind.word_boundary)) return null;
    if (plusn.tag != .plus) return null;
    const clsn = h.node(plusn.a);
    if (clsn.tag != .set) return null;

    var dw = DupWord{ .class = undefined, .sep = undefined, .group = g };
    dw.class = h.setBitmap(clsn.set_idx);
    // `findCap`'s `\b` handling assumes the CLASS run is made of word chars
    // ([A-Za-z0-9_]) — that is what makes the run length unique per start and
    // the leftmost-first reduction sound. A non-word or mixed class (e.g.
    // `(\b[.]+\b) \1`) makes the `\b` checks wrong in both directions, so accept
    // ONLY a word-subset class here and otherwise fall through to the correct
    // `.backtrack` engine.
    for (0..256) |c| {
        const b: u8 = @intCast(c);
        if (cc.hasBit(&dw.class, b) and !cc.isWord(b)) return null;
    }
    dw.sep = h.setBitmap(sepn.set_idx);
    return dw;
}

// ===========================================================================
// Tests — differential vs the tree backtracker (the engine this replaces).
// ===========================================================================

const parser = @import("../parser.zig");
const thompson = @import("../thompson.zig");
const backtrack = @import("backtrack.zig");

test "dupword: recognises the shape and matches the backtracker exactly" {
    const a = std.testing.allocator;
    const p = "(\\b[A-Za-z]+\\b) \\1";
    var h = hir.Hir(null).initRuntime();
    defer h.deinit(a);
    try parser.parse(null, &h, a, p, .{});

    const dw = build(&h) orelse return error.ShapeNotRecognised;

    const ins = [_][]const u8{
        "",
        "the the",
        "x the the y",
        "the cat cat sat",
        "no dups here at all",
        "ab ab",
        "ab abc", // sep ok, second token differs ⇒ no match
        "abc ab", // lengths differ ⇒ no match
        "  hello hello world",
        "a1 a1", // a1 is word chars but CLASS=[A-Za-z]: '1' breaks the run,
        //          so token="a", then '1' is a word char ⇒ trailing \b fails
        "go go go go",
        "trailing dup dup",
        "dupe dupe!",
    };

    for (ins) |in| {
        var gs: usize = 0;
        var ge: usize = 0;
        const got = dw.findCap(in, 0, &gs, &ge);

        var bt = backtrack.Backtracker.init(&h, h.anchored_start, h.anchored_end, 1, null, null);
        var slots: [4]i32 = undefined;
        const want = bt.run(in, slots[0..4]) catch null;

        try std.testing.expectEqual(want == null, got == null);
        if (want) |ws| {
            try std.testing.expectEqual(ws.start, got.?.start);
            try std.testing.expectEqual(ws.end, got.?.end);
            // group 1 span must match the backtracker's slots[2],slots[3]
            try std.testing.expectEqual(slots[2], @as(i32, @intCast(gs)));
            try std.testing.expectEqual(slots[3], @as(i32, @intCast(ge)));
        }
    }
}

test "dupword: build rejects non-matching shapes" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        "(\\w+) \\1", // no \b ⇒ token length not unique ⇒ not this shape
        "(\\b[A-Za-z]+\\b)\\1", // no separator
        "([A-Za-z]+) \\1", // no \b brackets
        "(\\b[A-Za-z]+\\b) (\\b[A-Za-z]+\\b)", // no backref
        "foo.*bar",
    }) |p| {
        var h = hir.Hir(null).initRuntime();
        defer h.deinit(a);
        parser.parse(null, &h, a, p, .{}) catch continue;
        try std.testing.expect(build(&h) == null);
    }
}
