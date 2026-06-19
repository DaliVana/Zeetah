//! Per-feature: zero-width assertions (Phase C) — `\b \B`, mid-pattern
//! `^ $`, `(?m)` line anchors, mid `\A \z \Z`. These route to the bounded
//! backtracker (the DFA does not fold look-assertions); the prescan
//! anchored-fast-path for a *leading* `^`/trailing `$` (no `(?m)`) is
//! unchanged and covered by feat_anchors.zig.

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

test "boundary: large \\b\\w+\\b run matches without a stack overflow" {
    const a = std.testing.allocator;
    // The bounded backtracker (engine for `\b…` patterns) drives its search from
    // an explicit heap worklist rather than native recursion, so a very long
    // matching run is matched in full instead of overflowing the call stack.
    const n = 200 * 1024;
    const buf = try a.alloc(u8, n);
    defer a.free(buf);
    @memset(buf, 'a');
    try std.testing.expectEqual(@as(usize, n), (try slice(a, "\\b\\w+\\b", buf)).?.len);
}

test "boundary: \\b word boundaries" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("cat", (try slice(a, "\\bcat\\b", "a cat scatter cat.")).?);
    try std.testing.expect(!try isM(a, "\\bcat\\b", "scatter"));
    try std.testing.expectEqualStrings("123", (try slice(a, "[0-9]+\\b", "x123 45")).?);
    try std.testing.expect(try isM(a, "\\bword\\b", "word"));
}

test "boundary: \\B non-word boundary" {
    const a = std.testing.allocator;
    // foo\B: 'foo' only where followed by a word char (foobar), not at EOS.
    try std.testing.expectEqualStrings("foo", (try slice(a, "foo\\B", "foobar foo")).?);
    try std.testing.expect(!try isM(a, "foo\\B", "a foo"));
    try std.testing.expect(try isM(a, "x\\Bx", "xx"));
}

test "boundary: (?m) line anchors ^ $" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("x", (try slice(a, "(?m)^x", "a\nx\nb")).?);
    try std.testing.expectEqualStrings("x", (try slice(a, "(?m)x$", "ax\nbx")).?);
    // empty line: ^$ matches the zero-width spot between the two newlines.
    try std.testing.expectEqualStrings("", (try slice(a, "(?m)^$", "a\n\nb")).?);
    // scoped (?m:...) restores outside the group.
    try std.testing.expect(try isM(a, "(?m:^b)", "a\nb"));
}

test "boundary: .multiline struct flag mirrors inline (?m)" {
    const a = std.testing.allocator;
    // The `.multiline` compile flag is the exact peer of inline `(?m)`: it
    // disables the anchored prescan and routes `^`/`$` to line assertions.
    const sliceM = struct {
        fn f(al: std.mem.Allocator, pat: []const u8, in: []const u8) !?[]const u8 {
            var rx = try Regex.compileWithFlags(al, pat, .{ .multiline = true });
            defer rx.deinit();
            var m = try rx.find(in);
            defer if (m) |*mm| mm.deinit(al);
            return if (m) |mm| mm.slice else null;
        }
    }.f;
    try std.testing.expectEqualStrings("x", (try sliceM(a, "^x", "a\nx\nb")).?);
    try std.testing.expectEqualStrings("x", (try sliceM(a, "x$", "ax\nbx")).?);
    try std.testing.expectEqualStrings("", (try sliceM(a, "^$", "a\n\nb")).?);
    // Real-world shape: each full log line that begins with an ISO date.
    try std.testing.expectEqualStrings(
        "2026-05-16 ERROR boom",
        (try sliceM(a, "^[0-9]{4}-[0-9]{2}-[0-9]{2}.*$", "noise\n2026-05-16 ERROR boom\ntail")).?,
    );
    // The flag is global, so a leading `^` is a line anchor (matches line 2),
    // unlike the no-flag prescan fast path (which would demand text start).
    var rx = try Regex.compileWithFlags(a, "^b", .{ .multiline = true });
    defer rx.deinit();
    try std.testing.expect(try rx.isMatch("a\nb"));
}

test "boundary: (?m)^body$ line-DFA fast path matches the NFA semantics" {
    const a = std.testing.allocator;
    const countM = struct {
        fn f(al: std.mem.Allocator, pat: []const u8, in: []const u8) !usize {
            var rx = try Regex.compileWithFlags(al, pat, .{ .multiline = true });
            defer rx.deinit();
            return rx.count(in);
        }
    }.f;
    const sliceM = struct {
        fn f(al: std.mem.Allocator, pat: []const u8, in: []const u8) !?[]const u8 {
            var rx = try Regex.compileWithFlags(al, pat, .{ .multiline = true });
            defer rx.deinit();
            var m = try rx.find(in);
            defer if (m) |*mm| mm.deinit(al);
            return if (m) |mm| mm.slice else null;
        }
    }.f;
    // Only whole-line matches count; a body that fills only part of a line is
    // rejected (the `$` must land on the line terminator).
    try std.testing.expectEqual(@as(usize, 2), try countM(a, "^\\d{3}$", "123\n12\n4567\n890\nx999"));
    // Alternation body: sound here (determinized DFA's longest accept, not the
    // priority cut that forces edge_look to reject `.alt`).
    try std.testing.expectEqual(@as(usize, 3), try countM(a, "^(?:ab|cd)$", "ab\ncd\nabc\nxy\ncd"));
    // `$` satisfied at EOF with no trailing newline.
    try std.testing.expectEqualStrings("99", (try sliceM(a, "^\\d+$", "ab\n99")).?);
    // Empty-line match (`^$`).
    try std.testing.expectEqual(@as(usize, 2), try countM(a, "^$", "a\n\nb\n"));
    // `\s` includes `\n`, so this body is NOT line-DFA-eligible (it could match
    // across a line break) — it must fall back to the NFA and still be correct.
    try std.testing.expectEqualStrings("a b", (try sliceM(a, "^\\w\\s\\w$", "xx\na b\ncc")).?);
}

test "boundary: (?m)^(cap)$ line-DFA locates span, captures reconstructed per line" {
    const a = std.testing.allocator;
    // Capture-bearing line pattern: the line-DFA finds the span fast and the
    // groups are filled over just that line — must match the NFA semantics.
    var rx = try Regex.compileWithFlags(a, "^(\\d{3})-(\\d{2})$", .{ .multiline = true });
    defer rx.deinit();
    // count (span-only) skips non-matching lines via the DFA.
    try std.testing.expectEqual(@as(usize, 2), try rx.count("123-45\nxx\n678-90\n12-3"));
    // captures: correct group spans on a matching line preceded by noise.
    var m = (try rx.captures(a, "noise\n123-45\ntail")).?;
    defer m.deinit(a);
    try std.testing.expectEqualStrings("123-45", m.slice);
    try std.testing.expectEqualStrings("123", m.groups[1].?.slice);
    try std.testing.expectEqualStrings("45", m.groups[2].?.slice);
}

test "boundary: non-multiline ^ $ are text anchors; mid is zero-width" {
    const a = std.testing.allocator;
    // $ without (?m) = end of text only (the [1] 'x' before \n is skipped).
    try std.testing.expectEqualStrings("x", (try slice(a, "x$", "ax\nbx")).?);
    // ^ mid-pattern after consuming a byte can never hold.
    try std.testing.expect(!try isM(a, "a^b", "ab"));
    // mid \A likewise.
    try std.testing.expect(!try isM(a, "a\\Ab", "aAb"));
    // \z / \Z end anchors mid-recognized.
    try std.testing.expect(try isM(a, "ab\\z", "ab"));
    try std.testing.expect(try isM(a, "ab\\Z", "ab\n"));
}

test "boundary: prescan anchored fast-path still works (no look node)" {
    const a = std.testing.allocator;
    // Leading ^ / trailing $ with no (?m): stays the DFA boolean fast path.
    try std.testing.expectEqualStrings("abc", (try slice(a, "^abc$", "abc")).?);
    try std.testing.expect(!try isM(a, "^abc$", "xabc"));
    try std.testing.expectEqualStrings("ab", (try slice(a, "\\Aab", "abc")).?);
}

test "boundary: comptime Pattern rejects look-assertions" {
    // Look patterns are runtime-only (bounded backtracker); the comptime DFA
    // path @compileErrors them — assert the runtime form instead.
    const a = std.testing.allocator;
    try std.testing.expect(try isM(a, "\\bhi\\b", "say hi now"));
}

// `\b(?:lit|lit|…)\b`: a big keyword list is *regular* but blows the naive
// NFA's MAX_NFA. The Aho-Corasick locate + O(1) `\b` verify engine accepts it
// and must stay leftmost-first / overlap-correct vs a brute-force reference.
test "boundary: \\b(keyword list)\\b engine — accepts + leftmost-correct" {
    const a = std.testing.allocator;

    // 40 keywords — over the old MAX_NFA reject ceiling. Must compile now.
    const kw =
        "\\b(?:break|case|catch|class|const|continue|debugger|default|delete|" ++
        "do|else|export|extends|finally|for|function|if|import|in|instanceof|" ++
        "new|return|super|switch|this|throw|try|typeof|var|void|while|with|" ++
        "yield|let|static|enum|await|async|null|true|false)\\b";
    var rx = try Regex.compile(a, kw);
    defer rx.deinit();
    const src = "if (x) { return new Foo(); } else for (;;) await null; classy notakeyword";
    // `class` must NOT match inside `classy` (\b after fails); `in`/`new` etc.
    try std.testing.expectEqualStrings("if", (try rx.find(src)).?.slice);
    // non-overlapping leftmost count == brute-force reference.
    const lits = [_][]const u8{
        "break", "case", "catch", "class", "const", "continue", "debugger", "default",
        "delete", "do", "else", "export", "extends", "finally", "for", "function", "if",
        "import", "in", "instanceof", "new", "return", "super", "switch", "this", "throw",
        "try", "typeof", "var", "void", "while", "with", "yield", "let", "static", "enum",
        "await", "async", "null", "true", "false",
    };
    try std.testing.expectEqual(refCount(&lits, src), try rx.count(src));

    // Exercises the rare-byte SIMD pre-skip: keywords whose rare byte is
    // *interior* (export→x, typeof/yield→y, instanceof→ interior), plus
    // non-keyword false positives that share a rare byte (xylophone, vex,
    // wxyz) so the prefilter→window→reject path is hit. Differential vs the
    // brute-force oracle, so acceleration must not change any outcome.
    const src2 =
        "export const x; typeof y; yield zz; a instanceof b; xylophone vex wxyz; " ++
        "while(true) try{}finally{} async await; do{}while(false); void 0; let q";
    try std.testing.expectEqual(refCount(&lits, src2), try rx.count(src2));
    try std.testing.expectEqualStrings("export", (try rx.find(src2)).?.slice);

    // Overlap / prefix-of-each-other: leftmost-first picks by *position*,
    // and `\b` resolves the prefix ambiguity (`\bin\b` fails inside `int`).
    var rx2 = try Regex.compile(a, "\\b(?:in|instanceof|int|i)\\b");
    defer rx2.deinit();
    inline for (.{
        .{ "x in y", @as(?[]const u8, "in") },
        .{ "int x", @as(?[]const u8, "int") }, // `\bin\b` fails in `int`, but `int` itself is an alt
        .{ "a instanceof b", @as(?[]const u8, "instanceof") },
        .{ "just i here", @as(?[]const u8, "i") },
        .{ "nothing", @as(?[]const u8, null) },
    }) |c| {
        const got = try rx2.find(c[0]);
        if (c[1]) |want| {
            try std.testing.expectEqualStrings(want, got.?.slice);
        } else try std.testing.expect(got == null);
    }
}

// Brute-force leftmost-first non-overlapping match count (oracle).
fn refCount(lits: []const []const u8, s: []const u8) usize {
    const wb = struct {
        fn isW(c: u8) bool {
            return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
                (c >= '0' and c <= '9') or c == '_';
        }
        fn f(in: []const u8, p: usize) bool {
            const before = p > 0 and isW(in[p - 1]);
            const after = p < in.len and isW(in[p]);
            return before != after;
        }
    }.f;
    var n: usize = 0;
    var p: usize = 0;
    while (p <= s.len) {
        var hit: ?usize = null;
        if (wb(s, p)) {
            for (lits) |L| {
                if (p + L.len <= s.len and std.mem.eql(u8, s[p .. p + L.len], L) and wb(s, p + L.len)) {
                    hit = L.len;
                    break;
                }
            }
        }
        if (hit) |len| {
            n += 1;
            p += len;
        } else p += 1;
    }
    return n;
}
