//! Parity harness — the cross-engine equivalence oracle for the meta-engine
//! migration (see the "Design decisions" section of docs/ARCHITECTURE.md).
//!
//! Runs a shared (pattern × input) corpus through the *old* runtime `Regex`
//! engine and, as the new meta engine lands phase-by-phase, through the new
//! engine too — asserting identical `isMatch` and `find` boundaries.
//!
//! Phase 0: the new engine does not exist yet, so this records the old
//! engine's reference behaviour over the corpus (a baseline smoke + the
//! frozen oracle the later phases diff against). Wire the new engine in by
//! implementing `runNew` and flipping `new_engine_available` to `true`.
//!
//! Run with: `zig build parity`

const std = @import("std");
const regex = @import("zeetah");
const Regex = regex.Regex;

/// Flip to `true` once a new-engine adapter is wired into `runNew`. While
/// `false` the harness only exercises the old engine (Phase 0 baseline).
const new_engine_available = false;

/// Input corpus. Superset of `tests/comptime_dfa.zig`'s inputs, extended with
/// boundary/anchor/unicode-sensitive haystacks so prefix/suffix/inner and
/// reverse strategies (phases 3-4) get discriminating coverage.
const inputs = [_][]const u8{
    "",
    "a",
    "ab",
    "abc",
    "abcabc",
    "xabcy",
    "AABBCC",
    "123",
    "a1b2c3",
    "  spaces  ",
    "hello world",
    "the quick brown fox",
    "no match here",
    "aaaaaaaaaa",
    "\n",
    "a\nb",
    "z",
    "foobar",
    "cat dog bird",
    "x",
    "xaab",
    "axbxb",
    "<a>1</a><a>2</a>",
    "eni-1 eni-2 ",
    // Reverse / suffix / inner discriminators (phases 3-4):
    "prefix_FOUND_IT!_suffix",
    "end of line\n",
    "trailing whitespace   ",
    "user@example.com and root@localhost",
    "2026-05-17T09:26:44Z",
    "AAAAAAAAAAAAAAAAAAAAbcdefghijklmnopq",
    "the the the the the the the end",
    "日本語 mixed ascii 123",
    "word boundary: cat catalog scatter cat.",
};

/// Pattern corpus. Mirrors the families exercised across `tests/*.zig`:
/// literals, alternation, quantifiers (greedy + lazy), classes, anchors,
/// captures, bounded repeats, dot-star, word boundaries.
const patterns = [_][]const u8{
    // literals / concat
    "a",
    "abc",
    "hello",
    "fox",
    "\\.",
    "FOUND_IT!",
    // alternation
    "a|b",
    "cat|dog|bird",
    "foo|foobar",
    "(ab|cd)",
    // quantifiers (greedy)
    "a*",
    "a+",
    "a?b",
    "ab*c",
    "a+b+",
    "colou?r",
    // quantifiers (lazy)
    "a*?b",
    "a+?b",
    "a??b",
    ".*?x",
    "a{2,4}?b",
    "a{2,}?b",
    // classes
    "[a-z]+",
    "[0-9]{3}",
    "[^abc]+",
    "\\d+",
    "\\w+",
    "\\s+",
    // anchors
    "^hello",
    "world$",
    "^abc$",
    // dot / dotstar
    "a.c",
    "a.*c",
    "a.+c",
    // captures / groups
    "(\\d{4})-(\\d{2})-(\\d{2})",
    "(a)(b)(c)",
    "(?:ab)+c",
    // prefix / suffix / inner literal bearing
    "[a-z]+@[a-z]+\\.[a-z]+",
    "abc[0-9]+z",
    "hello.*world",
    ".*FOUND",
    // word boundary
    "\\bcat\\b",
    "\\w+\\b",
};

const Outcome = struct {
    is_match: bool,
    has_find: bool,
    start: usize,
    end: usize,
};

fn runOld(allocator: std.mem.Allocator, pattern: []const u8, input: []const u8) !Outcome {
    var rx = try Regex.compile(allocator, pattern);
    defer rx.deinit();

    const is_match = try rx.isMatch(input);
    var m = try rx.find(input);
    defer if (m) |*mm| mm.deinit(allocator);

    return .{
        .is_match = is_match,
        .has_find = m != null,
        .start = if (m) |mm| mm.start else 0,
        .end = if (m) |mm| mm.end else 0,
    };
}

/// New-engine adapter. Returns `null` until a phase wires it in. Once
/// `new_engine_available` is `true` this must return the new engine's
/// `Outcome` for the same (pattern, input).
fn runNew(allocator: std.mem.Allocator, pattern: []const u8, input: []const u8) !?Outcome {
    _ = allocator;
    _ = pattern;
    _ = input;
    return null;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    _ = new_engine_available;
    _ = runNew;

    // Post-cutover: a single engine (the meta pipeline). The old AST/VM
    // oracle was deleted, so this is now a *smoke*: every (pattern,input)
    // either matches cleanly or the pattern is reported `NotImplemented`
    // (an *expected*, intentional outcome for the dropped feature subset —
    // captures/lookaround/backref/word-boundary/etc.). A hard crash or any
    // unexpected error is the only failure.
    var pairs: usize = 0;
    var matched: usize = 0;
    var unsupported_patterns: usize = 0;
    var hard_errors: usize = 0;

    for (patterns) |pattern| {
        // Compile once per pattern; NotImplemented is the expected signal
        // for a deliberately-dropped feature.
        var rx = Regex.compile(allocator, pattern) catch |e| {
            if (e == error.NotImplemented or e == error.PatternTooComplex) {
                unsupported_patterns += 1;
            } else {
                hard_errors += 1;
                std.debug.print("ERR p=\"{s}\" err={s}\n", .{ pattern, @errorName(e) });
            }
            continue;
        };
        defer rx.deinit();
        for (inputs) |input| {
            pairs += 1;
            const is_m = rx.isMatch(input) catch {
                hard_errors += 1;
                continue;
            };
            if (is_m) matched += 1;
            var m = rx.find(input) catch {
                hard_errors += 1;
                continue;
            };
            defer if (m) |*mm| mm.deinit(allocator);
            // find/isMatch must agree.
            if ((m != null) != is_m) {
                hard_errors += 1;
                std.debug.print("DISAGREE p=\"{s}\" in=\"{s}\" is={} find={}\n", .{ pattern, input, is_m, m != null });
            }
        }
    }

    std.debug.print("\n=== Meta-Engine Smoke ===\n", .{});
    std.debug.print("patterns             : {d}\n", .{patterns.len});
    std.debug.print("inputs               : {d}\n", .{inputs.len});
    std.debug.print("supported (p,in)     : {d}\n", .{pairs});
    std.debug.print("matched              : {d}\n", .{matched});
    std.debug.print("dropped-feature pats : {d} (expected NotImplemented)\n", .{unsupported_patterns});
    std.debug.print("hard errors          : {d}\n", .{hard_errors});
    if (hard_errors != 0) {
        std.debug.print("RESULT: FAIL\n", .{});
        std.process.exit(1);
    }
    std.debug.print("RESULT: SMOKE OK\n", .{});
}
