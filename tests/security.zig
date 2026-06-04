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

test "redos: classic nested-quantifier patterns collapse to a linear DFA" {
    const a = std.testing.allocator;
    // Textbook catastrophic-backtracking ReDoS shapes. The capture-free meta
    // engine has no backtracker: they compile to a DFA that collapses the
    // ambiguity, so adversarial input is strictly O(n). 4x input ⇒ ≈4x time;
    // the x8 ceiling + absolute floor only absorb scheduler noise and would
    // still trip hard on any super-linear regression.
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
