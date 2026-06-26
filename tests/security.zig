//! Security / robustness suite (rebuilt for the capture-free meta engine).
//!
//! The old AST/Pike-VM/backtracker is gone: there is no exponential engine to
//! step-bound. ReDoS-class patterns are either *rejected* cleanly or collapse
//! to a linear DFA — so the assertions are "rejected with a typed error **or**
//! accepted-and-linear", plus malformed-input memory-safety, clean teardown,
//! and a fuzz sweep. The timing-ratio checks are ported from the deleted
//! suite (monotonicNs) with generous bounds: a DFA is structurally O(n), so a
//! tight ratio is achievable; the slack only absorbs scheduler noise.

const std = @import("std");
const builtin = @import("builtin");
const regex = @import("zeetah");
const Regex = regex.Regex;

// Monotonic clock (Zig 0.16 std has no Timer; the test binary links libc).
// Coarse scaling-ratio use only.
fn monotonicNs() u64 {
    const clk: std.c.clockid_t = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => .UPTIME_RAW,
        else => .MONOTONIC,
    };
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.c.clock_gettime(clk, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

const contract = [_]anyerror{
    error.NotImplemented,
    error.PatternTooComplex,
    error.InvalidPattern,
    error.EmptyPattern,
};

fn isContractError(e: anyerror) bool {
    for (contract) |x| if (e == x) return true;
    return false;
}

fn timeIsMatch(a: std.mem.Allocator, rx: *const Regex, n: usize) !u64 {
    const buf = try a.alloc(u8, n);
    defer a.free(buf);
    @memset(buf, 'a');
    const t0 = monotonicNs();
    _ = try rx.isMatch(buf);
    return monotonicNs() - t0;
}

// Worst-case ReDoS trigger: a long run of the repeated member followed by a
// single terminal mismatch (`aaaa…!`). For a backtracking engine this is the
// pathological "explore every split then fail" case; for a DFA it stays O(n).
fn timeIsMatchTail(a: std.mem.Allocator, rx: *const Regex, n: usize) !u64 {
    const buf = try a.alloc(u8, n);
    defer a.free(buf);
    @memset(buf, 'a');
    buf[n - 1] = '!';
    const t0 = monotonicNs();
    _ = try rx.isMatch(buf);
    return monotonicNs() - t0;
}

// Time enumerating *all* matches via the allocation-free `count`. Guards the
// "find-all is O(n^2)" trap that hits even single-match-linear engines when a
// successive search restarts the scan instead of resuming from the cursor.
fn timeCount(a: std.mem.Allocator, rx: *const Regex, n: usize, fill: u8) !u64 {
    const buf = try a.alloc(u8, n);
    defer a.free(buf);
    @memset(buf, fill);
    const t0 = monotonicNs();
    _ = try rx.count(buf);
    return monotonicNs() - t0;
}

test "redos: classic nested-quantifier patterns collapse to a linear DFA" {
    const a = std.testing.allocator;
    // Textbook catastrophic-backtracking ReDoS shapes. The capture-free meta
    // engine has no backtracker: they compile to a DFA that collapses the
    // ambiguity, so adversarial input is strictly O(n). 4x input ⇒ ≈4x time;
    // the x8 ceiling + absolute floor only absorb scheduler noise and would
    // still trip hard on any super-linear regression.
    //
    // BLIND SPOT (see the "redos(polynomial): KNOWN-FAILING" test above):
    // `timeIsMatch` feeds all-`a` input, which MATCHES `(a+)+$`/`(a*)*$` at
    // offset 0 in a single scan — so this test stays green even though those
    // same patterns are O(n^2) on *non-matching* input (`aaaa…!`). This test
    // therefore certifies only the matching-input case; the worst-case
    // quadratic is tracked by the known-failing marker.
    const patterns = [_][]const u8{
        "(a+)+$",  "(a*)*$",        "((a+)+)+$",
        "(a|a)*$", "([a-zA-Z]+)*$", "(.*)*$",
        "(x|x|x|x)*y",
    };
    for (patterns) |p| {
        if (Regex.compile(a, p)) |r| {
            var rx = r;
            defer rx.deinit();
            const t1 = try timeIsMatch(a, &rx, 50_000);
            const t4 = try timeIsMatch(a, &rx, 200_000);
            try std.testing.expect(t4 < t1 * 8 + 50_000_000);
        } else |e| {
            try std.testing.expect(isContractError(e));
        }
    }
}

test "redos: unanchored required-literal patterns are linear (Phase-F fix)" {
    const a = std.testing.allocator;
    // Previously a KNOWN LIMITATION: for an unanchored pattern whose required
    // tail/inner literal never appears, `core.findLeftmost` re-ran the DFA
    // from every start offset → O(n^2) (~x16 per 4x input). Phase F adds a
    // necessary-condition memchr prefilter (`seq_extract.requiredByte` → a
    // byte every accepting path must consume, stored on the DFA): when that
    // byte is absent the search answers "no match" in a single O(n) scan.
    // These three shapes (no usable prefix/suffix → route to `.core`) are now
    // strictly linear: 4x input ⇒ ≈4x time, x8 ceiling + floor absorb only
    // scheduler noise. Measured: `(a|ab)*c` went ~6.4s→~20µs at n=50k.
    const patterns = [_][]const u8{
        "(a|ab)*c",
        "a.*a.*a.*a.*a.*a.*a.*X",
        ".*.*.*.*.*=.*",
    };
    for (patterns) |p| {
        if (Regex.compile(a, p)) |r| {
            var rx = r;
            defer rx.deinit();
            const t1 = try timeIsMatch(a, &rx, 50_000);
            const t4 = try timeIsMatch(a, &rx, 200_000); // 4x input
            try std.testing.expect(t4 < t1 * 8 + 50_000_000); // linear; trips on any super-linear regression
        } else |e| {
            try std.testing.expect(isContractError(e));
        }
    }
}

test "redos: [A-Z].*<long suffix> stays linear (no O(n^2)) — ex-meta_phase4" {
    const a = std.testing.allocator;
    var rx = try Regex.compile(a, "[A-Z].*bcdefghijklmnopq");
    defer rx.deinit();

    // Non-matching haystack (required suffix never appears) — the worst case
    // for a naive engine. Time at N and 2N; doubling must stay well under 5x.
    const base = 20000;
    const buf1 = try a.alloc(u8, base);
    defer a.free(buf1);
    @memset(buf1, 'A');
    const buf2 = try a.alloc(u8, base * 2);
    defer a.free(buf2);
    @memset(buf2, 'A');

    const a0 = monotonicNs();
    _ = try rx.isMatch(buf1);
    const t1 = monotonicNs() - a0;
    const b0 = monotonicNs();
    _ = try rx.isMatch(buf2);
    const t2 = monotonicNs() - b0;

    // Linear: 2x work ≈ 2x time. Slack absorbs noise / tiny absolute t.
    try std.testing.expect(t2 < t1 * 5 + 1_000_000);
}

test "redos: backref / lookaround compile and are step-budget bounded (.NET model)" {
    const a = std.testing.allocator;
    // Phase E: these compile and run on the tree backtracker (not rejected).
    {
        var r = try Regex.compile(a, "(\\w+)\\1");
        defer r.deinit();
        try std.testing.expect(try r.isMatch("abcabc"));
        try std.testing.expect(!try r.isMatch("abcabd"));
    }
    {
        var r = try Regex.compile(a, "a(?=b)");
        defer r.deinit();
        try std.testing.expect(try r.isMatch("ab"));
        try std.testing.expect(!try r.isMatch("ac"));
    }
    {
        var r = try Regex.compile(a, "(?<=x)y");
        defer r.deinit();
        try std.testing.expect(try r.isMatch("xy"));
        try std.testing.expect(!try r.isMatch("zy"));
    }
    // Backtracking is NOT ReDoS-proof by construction — the explicit step
    // budget is the guard: adversarial input on a catastrophic non-regular
    // pattern yields a *typed* MatchBudgetExceeded, never a hang.
    {
        // `(?=a)(a+)+$`: the only non-regular part is the benign `(?=a)`;
        // the catastrophic `(a+)+$` is *regular*. The Seek prefilter's
        // regular over-approximation (`(?=a)`→ε ⟹ `(a+)+$`) therefore
        // proves "no match" in one linear DFA pass on `aaaa…!` — the
        // correct answer is a clean `false`, defused without ever entering
        // the exponential tree-walk. (Pre-Seek this hit the step budget.)
        var r = try Regex.compile(a, "(?=a)(a+)+$");
        defer r.deinit();
        const buf = try a.alloc(u8, 31);
        defer a.free(buf);
        @memset(buf, 'a');
        buf[30] = '!';
        try std.testing.expect(!try r.isMatch(buf));
    }
    {
        // Contract preserved where Seek *cannot* short-circuit: the
        // catastrophe lives *inside* the lookahead, so the over-approx
        // (`(?=…)`→ε ⟹ `a`) stays permissive and matches — the tree
        // backtracker still runs and the explosive `(a+)+$` is cut off as
        // a *typed* MatchBudgetExceeded (never a hang). Backtracking is NOT
        // ReDoS-proof by construction; the explicit step budget is the guard.
        var r = try Regex.compile(a, "(?=(a+)+$)a");
        defer r.deinit();
        const buf = try a.alloc(u8, 31);
        defer a.free(buf);
        @memset(buf, 'a');
        buf[30] = '!';
        try std.testing.expectError(error.MatchBudgetExceeded, r.isMatch(buf));
    }
}

test "quantifier: overflowing / oversized counts rejected cleanly, no leak" {
    const a = std.testing.allocator;
    const bad = [_][]const u8{
        // Over the {m,n} expansion ceiling (1000). `a{n}` is unrolled into n
        // node copies (parser.expand), so the ceiling is the by-construction
        // ReDoS/memory bound — `a{1001}` is the first count past it. Raising it
        // substantially would need a counted-repetition NFA across every engine
        // tier and reintroduce a ReDoS surface, so the bound stays.
        "a{1001}",               "a{20000}",
        "a{100000}",             "(a{1000}){1000}",
        "(ab){50000}",
        // Integer overflow on the count, and inverted min > max: genuine
        // syntax errors that must always reject.
        "a{2147483648}",         "a{4294967296}",
        "a{99999999999999999999}", "a{3,2}",
    };
    for (bad) |p| {
        if (Regex.compile(a, p)) |r| {
            var rr = r;
            rr.deinit();
            return error.ExpectedRejection; // must not compile
        } else |e| {
            try std.testing.expect(isContractError(e));
        }
    }
}

test "nesting: deep groups hit a guard, never the stack" {
    const a = std.testing.allocator;
    inline for (.{ 64, 256, 512 }) |depth| {
        var buf: [2 * 512 + 2]u8 = undefined;
        var i: usize = 0;
        while (i < depth) : (i += 1) buf[i] = '(';
        buf[depth] = 'a';
        i = 0;
        while (i < depth) : (i += 1) buf[depth + 1 + i] = ')';
        const pat = buf[0 .. 2 * depth + 1];
        if (Regex.compile(a, pat)) |r| {
            var rr = r;
            rr.deinit();
        } else |e| {
            try std.testing.expect(isContractError(e));
        }
    }
}

test "nesting: deep non-capturing (?: groups hit the parse-depth guard, not the stack" {
    const a = std.testing.allocator;
    // `(?:` does NOT consume a MAX_GROUPS slot, so the `parseAlt` MAX_PARSE_DEPTH
    // guard is the only thing between a deep nest and a native stack overflow.
    // (The capturing-`(` case above is bounded earlier by MAX_GROUPS.)
    const deep = 2000; // > MAX_PARSE_DEPTH
    const dbuf = try a.alloc(u8, deep * 3 + 1 + deep);
    defer a.free(dbuf);
    var i: usize = 0;
    while (i < deep) : (i += 1) @memcpy(dbuf[i * 3 ..][0..3], "(?:");
    dbuf[deep * 3] = 'a';
    i = 0;
    while (i < deep) : (i += 1) dbuf[deep * 3 + 1 + i] = ')';
    try std.testing.expectError(error.PatternTooComplex, Regex.compile(a, dbuf));

    // A shallow non-capturing nest still compiles — no over-rejection.
    const shallow = 100;
    const sbuf = try a.alloc(u8, shallow * 3 + 1 + shallow);
    defer a.free(sbuf);
    i = 0;
    while (i < shallow) : (i += 1) @memcpy(sbuf[i * 3 ..][0..3], "(?:");
    sbuf[shallow * 3] = 'a';
    i = 0;
    while (i < shallow) : (i += 1) sbuf[shallow * 3 + 1 + i] = ')';
    var rx = try Regex.compile(a, sbuf);
    defer rx.deinit();
    try std.testing.expect(try rx.isMatch("a"));
}

test "utf8: malformed input bytes do not crash or over-read" {
    const a = std.testing.allocator;
    const patterns = [_][]const u8{ "a.b", ".*", "^.+$", "\\w+", "a.*c" };
    const inputs = [_][]const u8{
        "\xFF\xFE",         "\xC0\x80",        "\xED\xA0\x80",
        "\xF4\x90\x80\x80", "\x80\x80\x80",    "a\xFFb\x00c",
        "",
    };
    for (patterns) |p| {
        var rx = try Regex.compile(a, p);
        defer rx.deinit();
        for (inputs) |in| {
            _ = try rx.isMatch(in);
            var m = try rx.find(in);
            if (m) |*mm| mm.deinit(a);
        }
    }
}

test "casefold: boundary code points under -i stay memory-safe" {
    const a = std.testing.allocator;
    const patterns = [_][]const u8{ "[a-z]+", ".", "\\w", "(?i:abc)" };
    const inputs = [_][]const u8{
        "\xF4\x8F\xBF\xBF", // U+10FFFF
        "\xEF\xBF\xBF", // U+FFFF
        "\xC4\xB1", // 'ı' dotless i
        "\xC4\xB0", // 'İ' dotted I
        "AbCdEf",
    };
    for (patterns) |p| {
        var rx = try Regex.compileWithFlags(a, p, .{ .case_insensitive = true });
        defer rx.deinit();
        for (inputs) |in| {
            _ = try rx.isMatch(in);
        }
    }
}

// ============================================================================
// REGRESSION GUARD — this WAS a known O(n^2) ReDoS; it is now fixed and linear.
//
// The bug: an *unanchored* pattern with a trailing `$` and no required literal
// byte re-ran the matcher from O(n) start offsets (each O(n)) → quadratic on
// non-matching input. Bare `a+$` was the minimal reproducer (~244ms @10k →
// ~982ms @20k → ~3.87s @40k: textbook 4x-per-2x). This is the "neglected
// polynomial 90%" of ReDoS (Davis et al. ESEC/FSE'18; SoK arXiv 2406.11618) —
// quadratic/cubic, not exponential, is what took down Stack Overflow (quadratic)
// and Cloudflare (quartic). The pre-existing "classic nested-quantifier" test
// below MISSED it because it feeds matching all-`a` input (matches at offset 0
// in one scan); the `!`-terminal here is the true adversarial worst case.
//
// The fix (engine): the unanchored `$`-anchored bare-DFA class
// (`!^` + `$`, no usable literal prefilter) is routed to the lazy/dense
// single-pass engine, whose `$` path is a single O(n) **reverse-reachability**
// pass from `input.len` (`lazy_dfa.findAnchoredEndFrom` / `DenseSearch.findFrom`
// with `a_end`) — a match exists iff the reverse automaton reaches the forward
// start, with the leftmost such position as the start. (A forward `Σ*?` pass
// can't be used here: its leftmost-first accept-cut would drop a later-starting
// thread when an earlier one accepts mid-string — e.g. `ab$` on "ababab".)
// Keep this guard linear; do NOT let a future routing change reintroduce the
// per-position restart for this class. See docs/SECURITY_PROBLEMS.md.
// ============================================================================
test "redos(polynomial): unanchored $-patterns are linear (single-pass reverse fix)" {
    const a = std.testing.allocator;
    const patterns = [_][]const u8{
        "a*a*$",     "a*a*a*$",   "a*a*a*a*$", // degree 2/3/4 (Cloudflare-class)
        "a+a+$",     "a+a+a+$", // PTLS adjacent loops
        ".*a$",      "a+$", // SLQ / POLS single large quantifier
        "(a+)+$",    "(a*)*$", // the "linear" shapes the docs over-claimed
    };
    // Small sizes on purpose: at n=20k a quadratic pattern is already ~1s, so
    // the 16x signal is unmistakable while the whole marker runs in ~1-2s. (At
    // n=200k a single quadratic pattern takes ~96s — far too slow for CI.) We
    // accumulate *all* offending patterns into one diagnostic rather than
    // bailing on the first, then fail once at the end.
    var offenders: usize = 0;
    for (patterns) |p| {
        if (Regex.compile(a, p)) |r| {
            var rx = r;
            defer rx.deinit();
            const t1 = try timeIsMatchTail(a, &rx, 5_000);
            const t4 = try timeIsMatchTail(a, &rx, 20_000); // 4x input
            // Linear: 4x input ⇒ ≈4x time. A quadratic path is ~16x and blows
            // past this; x8 + floor absorbs only scheduler noise.
            if (t4 >= t1 * 8 + 20_000_000) {
                offenders += 1;
                std.debug.print(
                    "  REGRESSED to O(n^2) ReDoS: \"{s}\" — t(5k)={d}ns t(20k)={d}ns (ratio {d:.1}x for 4x input)\n",
                    .{ p, t1, t4, @as(f64, @floatFromInt(t4)) / @as(f64, @floatFromInt(t1 + 1)) },
                );
            }
        } else |e| {
            try std.testing.expect(isContractError(e));
        }
    }
    // Linear: every pattern must stay ≈4x for 4x input. A nonzero count means
    // the single-pass routing regressed back to the per-position restart.
    try std.testing.expectEqual(@as(usize, 0), offenders);
}

// ============================================================================
// REGRESSION GUARD — multiline `$` / `\Z` end anchors (audit group E).
//
// A trailing line `$` (`(?m)…$`) or `\Z` with an unanchored start routes to the
// look (`bt_look`) tier, which scans from every start offset → O(n^2) on a long
// non-matching line (the email shape `\w+@\w+` was ~3.5s @16k in the ReDoS
// audit). The fix (`properties.revEndAnchored` + `search.reverseLineEnd` /
// `reverseBeforeNl`): a regular `\n`-free body with a trailing `$`/`\Z` runs one
// O(n) reverse pass per end boundary — the multiline/`\Z` peer of the absolute
// `$` reverse-reachability fix above. Adversarial input is one long line of `a`
// with NO `@`, so the reverse automaton must traverse the whole line before
// reporting "no match": O(n) now, O(n^2) if the per-position restart returns.
// Keep this guard linear. See docs/SECURITY_PROBLEMS.md.
// ============================================================================
test "redos(polynomial): multiline $ and \\Z end anchors are linear (reverse end-anchored fix)" {
    const a = std.testing.allocator;
    const patterns = [_][]const u8{
        "(?m)[a-z]+@[a-z]+$", // multiline email (the audit group-E shape)
        "(?m)[a-z]+=[a-z]+$", // key=value line validator
        "[a-z]+@[a-z]+\\Z", // `\Z` email (before an optional final \n)
        "(?m)[a-z]+:[a-z]+$",
    };
    var offenders: usize = 0;
    for (patterns) |p| {
        if (Regex.compile(a, p)) |r| {
            var rx = r;
            defer rx.deinit();
            // All-`a` (no `@`/`=`/`:`): the reverse pass traverses the whole
            // single line and never matches — the true O(n) vs O(n^2) signal.
            const t1 = try timeIsMatch(a, &rx, 8_000);
            const t4 = try timeIsMatch(a, &rx, 32_000); // 4x input
            if (t4 >= t1 * 8 + 20_000_000) {
                offenders += 1;
                std.debug.print(
                    "  REGRESSED to O(n^2) ReDoS: \"{s}\" — t(8k)={d}ns t(32k)={d}ns (ratio {d:.1}x for 4x input)\n",
                    .{ p, t1, t4, @as(f64, @floatFromInt(t4)) / @as(f64, @floatFromInt(t1 + 1)) },
                );
            }
        } else |e| {
            try std.testing.expect(isContractError(e));
        }
    }
    try std.testing.expectEqual(@as(usize, 0), offenders);
}

test "redos(enumeration): find-all / count / iterator over many matches is O(n), not O(n^2)" {
    const a = std.testing.allocator;
    // Even engines with a single-match linear guarantee (RE2, Go, Rust, .NET
    // NonBacktracking) degrade to O(n^2) when enumerating ALL matches if each
    // successive search restarts the scan instead of resuming from the cursor.
    // Zeetah's enumeration APIs resume from `pos` (advanceEmpty guarantees +1
    // progress on empty matches), so all-matches enumeration stays linear.
    var rx = try Regex.compile(a, "a");
    defer rx.deinit();

    // `count` is allocation-free and drives the same nextSpanFrom loop as
    // findAll/iterator. Dense matches (every byte) is the heaviest case.
    const t1 = try timeCount(a, &rx, 100_000, 'a');
    const t4 = try timeCount(a, &rx, 400_000, 'a'); // 4x matches
    try std.testing.expect(t4 < t1 * 8 + 50_000_000); // linear in #matches

    // Correctness + clean teardown of the heap-materialising variant.
    {
        const ms = try rx.findAll(a, "aXaXaXa");
        defer a.free(ms);
        try std.testing.expectEqual(@as(usize, 4), ms.len);
    }
    // Iterator drains and terminates (no stall on empty/zero-width advance).
    {
        var it = rx.iterator("aaaa");
        defer it.deinit();
        var seen: usize = 0;
        while (try it.next(a)) |_| seen += 1;
        try std.testing.expectEqual(@as(usize, 4), seen);
    }
    // Empty-match pattern must still make forward progress, not loop forever.
    {
        var er = try Regex.compile(a, "a*");
        defer er.deinit();
        // n+1 zero/whole-width matches over an n-byte buffer; the point is it
        // TERMINATES in bounded time rather than spinning on a zero-width hit.
        const n = try er.count("aaabbbaaa");
        try std.testing.expect(n >= 1);
    }
}

test "anchors: strict `$` defeats newline-smuggling; \\A \\z \\Z behave per OpenSSF guidance" {
    const a = std.testing.allocator;
    const isM = struct {
        fn f(al: std.mem.Allocator, p: []const u8, in: []const u8) !bool {
            var rx = try Regex.compile(al, p);
            defer rx.deinit();
            return rx.isMatch(in);
        }
    }.f;

    // A `^value$` validator must NOT be bypassable by appending a trailing
    // newline (the classic permissive-`$` smuggling bypass in PCRE/Python/PHP/
    // .NET). Zeetah's `$` is strict end-of-text outside `(?m)`.
    try std.testing.expect(try isM(a, "^abc$", "abc"));
    try std.testing.expect(!try isM(a, "^abc$", "abc\n")); // smuggling defused
    try std.testing.expect(!try isM(a, "abc$", "abc\n"));

    // Absolute anchors `\A … \z` are strict on both ends — the recommended
    // pair for whole-input validation.
    try std.testing.expect(try isM(a, "\\Aabc\\z", "abc"));
    try std.testing.expect(!try isM(a, "\\Aabc\\z", "abc\n"));

    // `\Z` is the *explicit* before-final-newline form; you must opt into it.
    try std.testing.expect(try isM(a, "\\Aabc\\Z", "abc"));
    try std.testing.expect(try isM(a, "\\Aabc\\Z", "abc\n"));
    // …and the OpenSSF-suggested explicit `\n?\z` spelling is also available.
    try std.testing.expect(try isM(a, "abc\\n?\\z", "abc\n"));

    // Line-anchored matching is an explicit opt-in via `(?m)`, never silent.
    try std.testing.expect(try isM(a, "(?m)^b$", "a\nb\nc"));
    try std.testing.expect(!try isM(a, "^b$", "a\nb\nc"));
}

test "unicode(casefold): `(?i)` folds ASCII only — no Unicode case-fold collisions, no normalization" {
    const a = std.testing.allocator;
    const isMi = struct {
        fn f(al: std.mem.Allocator, p: []const u8, in: []const u8) !bool {
            var rx = try Regex.compileWithFlags(al, p, .{ .case_insensitive = true });
            defer rx.deinit();
            return rx.isMatch(in);
        }
    }.f;
    // Byte-oriented, ASCII-only folding is a deliberate security property: by
    // NOT doing Unicode case-fold expansion the engine structurally avoids the
    // Oniguruma case-fold OOB / integer-overflow CVE class (CVE-2017-9225,
    // CVE-2019-19012) AND the case-fold collision bypass class. The flip side
    // (a documented caller obligation): Unicode-aware folding/normalization
    // must be done by the caller before matching. These asserts pin the
    // contract so a future change can't silently widen the surface.
    try std.testing.expect(try isMi(a, "k", "K")); // ASCII pair folds
    try std.testing.expect(!try isMi(a, "k", "\xE2\x84\xAA")); // U+212A KELVIN ≠ k
    try std.testing.expect(!try isMi(a, "s", "\xC5\xBF")); // U+017F LONG S ≠ s
    try std.testing.expect(!try isMi(a, "i", "\xC4\xB1")); // U+0131 dotless ı ≠ i

    // No normalization: precomposed é (U+00E9) and decomposed e+combining-acute
    // are distinct byte sequences and must not match each other.
    try std.testing.expect(!try isMi(a, "\xC3\xA9", "e\xCC\x81"));

    // `(?i)` combined with a Unicode property class is refused outright rather
    // than half-implemented (the unsafe middle ground). The internal
    // `Error.Unsupported` surfaces as the public `error.NotImplemented`.
    try std.testing.expectError(error.NotImplemented, Regex.compileWithFlags(a, "(?i)\\p{L}", .{}));
}

test "injection: adversarial *patterns* are bounded at compile time, never unbounded" {
    const a = std.testing.allocator;
    // When the PATTERN itself is semi-trusted (a user search box, a filter
    // rule), a hostile pattern must not force unbounded compile/match work.
    // Every shape here either rejects with a typed error or compiles to a
    // bounded automaton that answers in linear time — the engine-level half of
    // the regex-injection defense (semantic injection remains an app-layer
    // whitelist obligation, per SEI CERT IDS08-J).
    const probe = "the quick brown fox jumps over the lazy dog 0123456789";
    const patterns = [_][]const u8{
        ".*)|(.*", // IDS08-J grouping-injection payload
        "(.*)*", "(.+)+", "(a|a|a|a|a)*", // alternation/loop blow-up attempts
        "(((((((((((x)))))))))))", // deep grouping
        "[a-z]{500}[A-Z]{500}", // large (but in-bounds) counted reps
        "(?:ab)*(?:cd)*(?:ef)*", // chained loops
    };
    for (patterns) |p| {
        if (Regex.compile(a, p)) |r| {
            var rx = r;
            defer rx.deinit();
            // Compiles ⇒ must answer in bounded time (typed error OK, hang not).
            if (rx.isMatch(probe)) |_| {} else |e| {
                try std.testing.expect(e == error.MatchBudgetExceeded or isContractError(e));
            }
        } else |e| {
            try std.testing.expect(isContractError(e));
        }
    }
}

test "teardown: error and success paths free memory exactly once" {
    const a = std.testing.allocator;
    const sweep = [_][]const u8{
        "",          "abc[",      "abc(",        "a)b",
        "*x",        "a{,}",      "a{2,1}",      "\\",
        "(?<d>a)(?<d>b)", "a{99999}", "((((a))))",  "[a-z]+",
        "\\d{1,3}\\.\\d{1,3}", "cat|dog|bird", "hello.*world",
    };
    for (sweep) |p| {
        if (Regex.compile(a, p)) |r| {
            var rr = r;
            rr.deinit();
        } else |e| {
            try std.testing.expect(isContractError(e));
        }
    }
}

test "fuzz: arbitrary short patterns never crash the compiler" {
    const a = std.testing.allocator;
    const alphabet = "abc()[]{}|*+?.^$\\-,0123456789<>=:!pP";
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rnd = prng.random();
    const probe = "abc123-XYZ_\xFF\x00";

    var iter: usize = 0;
    while (iter < 2000) : (iter += 1) {
        var buf: [24]u8 = undefined;
        const len = 1 + rnd.uintLessThan(usize, 24);
        for (buf[0..len]) |*b| b.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];
        const pat = buf[0..len];

        if (Regex.compile(a, pat)) |r| {
            var rx = r;
            defer rx.deinit();
            _ = try rx.isMatch(probe);
        } else |e| {
            // Any typed RegexError is acceptable; the point is no panic.
            std.mem.doNotOptimizeAway(e);
        }
    }
}
