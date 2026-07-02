//! Per-feature: greedy / bounded / possessive quantifiers.
//!
//! Lazy quantifiers live in feat_lazy.zig. The dropped over-ceiling and
//! malformed cases here pin the contract error mapping.

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

fn isMq(a: std.mem.Allocator, pat: []const u8, in: []const u8) !bool {
    var rx = try Regex.compile(a, pat);
    defer rx.deinit();
    return rx.isMatch(in);
}

fn span(a: std.mem.Allocator, pat: []const u8, in: []const u8) !?struct { s: usize, e: usize } {
    var rx = try Regex.compile(a, pat);
    defer rx.deinit();
    var m = try rx.find(in);
    defer if (m) |*mm| mm.deinit(a);
    if (m) |mm| return .{ .s = mm.start, .e = mm.end };
    return null;
}

test "greedy class-run SIMD fast path (backtracker tier)" {
    // These all carry a non-regular feature (lookaround / backref) so the
    // whole pattern routes to the tree backtracker, where the greedy `set*` /
    // `set+` loop is consumed by the `class_span` SIMD fast path. The asserts
    // pin the give-back semantics that path must reproduce byte-for-byte.
    const a = std.testing.allocator;

    // `+` greedy give-back: `[a-z]+` grabs "abc", then yields one char so the
    // trailing literal `c` can match. (`(?=.)` only forces the backtracker.)
    try std.testing.expectEqualStrings("abc", (try slice(a, "(?=.)[a-z]+c", "abc")).?);
    // `+` needs ≥1 member: no lowercase at start ⇒ no match.
    try std.testing.expect(!try isMq(a, "(?=.)[a-z]+", "123"));
    // `*` matches zero members (empty greedy run) yet the pattern still holds.
    try std.testing.expectEqualStrings("", (try slice(a, "(?=1)[a-z]*", "123")).?);
    // `.*` (dot is a single set) give-back to land the backref repeat.
    try std.testing.expectEqualStrings("abab", (try slice(a, "(.+)\\1", "abab")).?);
    try std.testing.expectEqualStrings("aa", (try slice(a, "(.+)\\1", "aaa")).?);
    // Run that spans the 16-byte SIMD chunk boundary, then give-back: `[a-z]+`
    // grabs all 20 'a's, fails the trailing `a`, yields one, matches at 19.
    try std.testing.expectEqualStrings(
        "aaaaaaaaaaaaaaaaaaaa",
        (try slice(a, "(?=.)[a-z]+a", "aaaaaaaaaaaaaaaaaaaa1")).?,
    );
    // Backref repeat of a >16-byte captured run (exercises the SIMD path on
    // both the capture's `+` and the equality of the repeated span).
    try std.testing.expectEqualStrings(
        "abcabcabcabcabcabcabcabcabcabc" ++ "abcabcabcabcabcabcabcabcabcabc",
        (try slice(a, "([a-c]+)\\1", "abcabcabcabcabcabcabcabcabcabc" ++ "abcabcabcabcabcabcabcabcabcabc")).?,
    );
}

test "greedy *: zero-or-more is maximal, matches empty" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("aaa", (try slice(a, "a*", "aaabbb")).?);
    // Leftmost zero-width match when nothing consumable at position 0.
    const z = (try span(a, "a*", "bbb")).?;
    try std.testing.expectEqual(@as(usize, 0), z.s);
    try std.testing.expectEqual(@as(usize, 0), z.e);
}

test "greedy +: one-or-more requires at least one" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("aaaa", (try slice(a, "a+", "xaaaax")).?);
    var rx = try Regex.compile(a, "a+");
    defer rx.deinit();
    try std.testing.expect(!try rx.isMatch("bbb"));
}

test "greedy ?: optional element" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("color", (try slice(a, "colou?r", "the color red")).?);
    try std.testing.expectEqualStrings("colour", (try slice(a, "colou?r", "the colour red")).?);
}

test "greedy: ab*c spans variable middle" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("ac", (try slice(a, "ab*c", "zacz")).?);
    try std.testing.expectEqualStrings("abbbc", (try slice(a, "ab*c", "abbbc")).?);
}

test "bounded {m}: exact count" {
    const a = std.testing.allocator;
    const m = (try span(a, "a{3}", "aaaaa")).?;
    try std.testing.expectEqual(@as(usize, 0), m.s);
    try std.testing.expectEqual(@as(usize, 3), m.e);
    var rx = try Regex.compile(a, "a{3}");
    defer rx.deinit();
    try std.testing.expect(!try rx.isMatch("aa"));
}

test "bounded {m,n}: greedy within bounds" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("aaaa", (try slice(a, "a{2,4}", "aaaaaaa")).?);
    try std.testing.expectEqualStrings("aa", (try slice(a, "a{2,4}", "baab")).?);
    var rx = try Regex.compile(a, "a{2,4}");
    defer rx.deinit();
    try std.testing.expect(!try rx.isMatch("a"));
}

test "bounded {m,}: open-ended" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("aaaaa", (try slice(a, "a{2,}", "aaaaa")).?);
    var rx = try Regex.compile(a, "a{2,}");
    defer rx.deinit();
    try std.testing.expect(!try rx.isMatch("a"));
}

test "bounded: parser ceiling raised 64 -> 1000; layered guards" {
    const a = std.testing.allocator;
    // Phase A raised the *parser* MAX_REPEAT 64 -> 1000, so {65} (rejected
    // before) now compiles. Two more layered guards remain, both typed (never a
    // crash): over-parser-ceiling is NotImplemented; an NFA past the *runtime*
    // construction ceiling (MAX_NFA_RUNTIME) is PatternTooComplex.
    for ([_][]const u8{ "a{64}", "a{65}" }) |p| {
        var ok = try Regex.compile(a, p);
        ok.deinit();
    }
    // Over the parser ceiling: specifically NotImplemented.
    try std.testing.expectError(error.NotImplemented, Regex.compile(a, "a{1001}"));
    try std.testing.expectError(error.NotImplemented, Regex.compile(a, "a{0,1001}"));
    // `a{300}` (~600 NFA states) once tripped the eager 256-state guard; the
    // runtime now hands over-256 regular NFAs to the heap lazy DFA, so it
    // compiles AND matches. (The comptime `Pattern` path still rejects it — its
    // baked DFA stays at the small ceiling.)
    {
        var rx = try Regex.compile(a, "a{300}");
        defer rx.deinit();
        const long = "a" ** 300;
        try std.testing.expect(try rx.isMatch(long));
        try std.testing.expect(!try rx.isMatch("a" ** 299));
    }
    // Still past the *runtime* size guard (~2048 states): typed, not a crash.
    // `[ab]{1000}[cd]{1000}` ≈ 4000 NFA states.
    try std.testing.expectError(error.PatternTooComplex, Regex.compile(a, "[ab]{1000}[cd]{1000}"));
}

// Migrated from the retired tests/meta_phase6.zig "known boundaries" gate.
test "bounded: \\d{3}-\\d{4} known boundary is exact" {
    const a = std.testing.allocator;
    var rx = try Regex.compile(a, "\\d{3}-\\d{4}");
    defer rx.deinit();
    const m = (try rx.find("call 555-1234 now")).?;
    try std.testing.expectEqualStrings("555-1234", m.slice);
}

test "bounded: inverted range {3,2} is rejected" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidPattern, Regex.compile(a, "a{3,2}"));
}

test "possessive: *+ ++ ?+ {m,n}+ have true atomic semantics (not silent greedy)" {
    const a = std.testing.allocator;
    // Possessive `a*+`/`a++` ≡ atomic `(?>a*)`/`(?>a+)`: it eats all the a's
    // and never gives one back, so `a*+a` / `a++a` cannot match "aaa" (the
    // trailing `a` is starved) — the key behavioural difference from greedy
    // `a*a`, which DOES match.
    try std.testing.expectEqual(@as(?[]const u8, null), try slice(a, "a*+a", "aaa"));
    try std.testing.expectEqual(@as(?[]const u8, null), try slice(a, "a++a", "aaa"));
    try std.testing.expectEqualStrings("aaa", (try slice(a, "a*a", "aaa")).?); // greedy gives one back
    // But they still match when the suffix is satisfiable.
    try std.testing.expectEqualStrings("aaab", (try slice(a, "a*+b", "aaab")).?);
    try std.testing.expectEqualStrings("aaab", (try slice(a, "a++b", "aaab")).?);
    // `?+` and `{m,n}+` parse and run.
    try std.testing.expectEqualStrings("ab", (try slice(a, "a?+b", "ab")).?);
    try std.testing.expectEqualStrings("aaab", (try slice(a, "a{2,3}+b", "aaab")).?);
    // `a{2,3}+a` starves the trailing `a` on "aaa" (atomic ate 3).
    try std.testing.expectEqual(@as(?[]const u8, null), try slice(a, "a{2,3}+a", "aaa"));
}

test "atomic group (?>...) commits and never backtracks" {
    const a = std.testing.allocator;
    // `(?>a+)b` matches "aaab"; `(?>a+)a` cannot match "aaa" (cut starves the
    // trailing `a`) while the non-atomic `(a+)a` does.
    try std.testing.expectEqualStrings("aaab", (try slice(a, "(?>a+)b", "xaaab")).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try slice(a, "(?>a+)a", "aaa"));
    try std.testing.expectEqualStrings("aaa", (try slice(a, "(a+)a", "aaa")).?);
    // The benchmark's `atomic_token` shape: identifier then `@`.
    try std.testing.expectEqualStrings("foo@", (try slice(a, "(?>[A-Za-z0-9_]+)@", "say foo@bar")).?);
}

test "quantifier on a class and on a group" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("123", (try slice(a, "[0-9]{3}", "ab12345")).?);
    try std.testing.expectEqualStrings("abab", (try slice(a, "(ab)+", "xababy")).?);
    try std.testing.expectEqualStrings("abcabc", (try slice(a, "(?:abc){2}", "abcabcabc")).?);
}

test "bounded {m,n}: re-parsed atom inherits (?s)/(?x) modes" {
    const a = std.testing.allocator;
    // The `{m,n}` expansion re-parses the atom source in a sub-parser; it must
    // inherit dot_all/extended/multiline, not just case-insensitivity.
    // `(?s)` makes `.` match `\n`:
    try std.testing.expectEqual(@as(usize, 2), (try slice(a, "(?s).{2}", "a\nb")).?.len);
    try std.testing.expect((try slice(a, "(?s)a.{1,3}b", "a\n\nb")) != null);
    // `(?x)` extended mode: the space is ignorable, not a literal.
    try std.testing.expect((try slice(a, "(?x)(a b){2}", "abab")) != null);
    // Sanity: without (?s), `.{2}` does not cross a newline.
    try std.testing.expect((try slice(a, ".{2}", "a\nb")) == null);
}

test "quantifier: comptime Pattern agrees with runtime Regex" {
    const a = std.testing.allocator;
    const P = regex.Pattern("a{2,4}b", .{});
    const cases = [_][]const u8{ "", "ab", "aab", "aaaab", "aaaaab", "b", "xaaabx" };
    var rx = try Regex.compile(a, "a{2,4}b");
    defer rx.deinit();
    for (cases) |in| {
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
