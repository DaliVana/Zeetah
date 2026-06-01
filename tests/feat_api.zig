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
    "",             "a",           "ab",           "abc",
    "abcabc",       "xabcy",       "AABBCC",       "123",
    "a1b2c3",       "hello world", "the fox",      "no match",
    "aaaaaaaaaa",   "foobar",      "cat dog bird", "x",
    "user@host.io", "2026-05-17",  "Zfoobar end",  "  spaces  ",
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

// Non-regular tier differential: backref / lookaround / atomic / possessive /
// lazy-anchored patterns route to the comptime-baked tree backtracker
// (`has_dfa == false`, no DFA table — Steps 1-3 of the comptime-backtracker
// work). This is the ONLY coverage that *instantiates* that `Pattern` arm —
// every other test pattern is regular, so the arm is comptime-eliminated and a
// green build says nothing about it. Calling `isMatch`/`find` here forces full
// analysis of the baked `Hir(node_count)` + the generic `BacktrackerG(node_count)`,
// so this file compiling at all is the primary proof those pieces type-check;
// the value checks then confirm the comptime matcher agrees with the runtime
// `Regex` engine. Inputs are short (well under `backtrack.run`'s O(n) step
// budget) so neither side hits the budget cut — comptime degrades it to `null`
// (the no-error API), runtime maps it to `MatchBudgetExceeded` — keeping the two
// directly comparable.
fn btAgree(comptime p: []const u8, in: []const u8) !void {
    const a = std.testing.allocator;
    const P = regex.Pattern(p, .{});
    comptime std.debug.assert(!P.has_dfa); // took the .backtrack arm, not the DFA/literal
    var rx = try Regex.compile(a, p);
    defer rx.deinit();

    try std.testing.expectEqual(try rx.isMatch(in), P.isMatch(in));
    const pm = P.find(in);
    var rm = try rx.find(in);
    defer if (rm) |*x| x.deinit(a);
    try std.testing.expectEqual(rm == null, pm == null);
    if (pm) |pmm| {
        try std.testing.expectEqual(rm.?.start, pmm.start);
        try std.testing.expectEqual(rm.?.end, pmm.end);
    }
}

test "comptime Pattern <-> runtime Regex agree: non-regular (tree backtracker) tier" {
    // backreferences (numeric + named)
    try btAgree("(ab)\\1", "abab"); // match
    try btAgree("(ab)\\1", "abac"); // no match
    try btAgree("(\\w)\\1", "aXhhb"); // doubled char mid-string
    try btAgree("(\\w+) \\1", "the the quick"); // adjacent dup word
    try btAgree("(\\w+) \\1", "the cat sat"); // no dup
    try btAgree("(a)(b)\\2\\1", "abba"); // multi-group \2\1
    try btAgree("(?<w>\\w+)=\\k<w>", "x=x"); // named backref, match
    try btAgree("(?<w>\\w+)=\\k<w>", "x=y"); // named backref, no match
    // lookahead
    try btAgree("foo(?=bar)", "foobar"); // positive, match
    try btAgree("foo(?=bar)", "foobaz"); // positive, no match
    try btAgree("foo(?!bar)", "foobaz"); // negative, match
    // (`a(?=b)` — a width-1 trailing lookahead — now routes to the edge-look
    // DFA peel, not the backtracker; covered in tests/feat_lookaround.zig.)
    // fixed-width lookbehind
    try btAgree("(?<=x)y", "xy"); // positive
    try btAgree("(?<=x)y", "zy"); // positive, no match
    try btAgree("(?<!x)y", "zy"); // negative, match
    try btAgree("(?<!x)y", "xy"); // negative, no match
    // atomic group / possessive quantifier (language-changing cut)
    try btAgree("(?>a+)b", "xaaab"); // atomic, match
    try btAgree("(?>a+)a", "aaa"); // cut starves trailing `a` -> no match
    try btAgree("(?>[A-Za-z0-9_]+)@", "say foo@bar"); // atomic_token shape
    try btAgree("a*+b", "aaab"); // possessive, match
    try btAgree("a*+a", "aaa"); // possessive, no match
    try btAgree("a{2,3}+a", "aaa"); // bounded possessive starves trailing `a`
    // lazy + end-anchor: regular language, but `saw_lazy && anchored_end`
    // routes to the tree backtracker (the DFA accept-cut can't model it).
    try btAgree("a*?$", "aaa");
    try btAgree(".*?b$", "aabxb");
}

test "comptime backtracker inherits the ReDoS step budget over a longer input" {
    // The comptime tree backtracker reuses `backtrack.run`, so it inherits the
    // O(n) step budget — a backref pattern over a longer input terminates (no
    // hang) and agrees with the runtime. The test completing is the termination
    // proof; the value check confirms agreement well under the budget.
    const a = std.testing.allocator;
    const P = regex.Pattern("(\\w+)\\1", .{});
    comptime std.debug.assert(!P.has_dfa);
    var rx = try Regex.compile(a, "(\\w+)\\1");
    defer rx.deinit();
    const in = "the the quick fox fox jumps over the lazy dog dog again";
    const pm = P.find(in);
    var rm = try rx.find(in);
    defer if (rm) |*x| x.deinit(a);
    try std.testing.expectEqual(rm == null, pm == null);
    if (pm) |pmm| {
        try std.testing.expectEqual(rm.?.start, pmm.start);
        try std.testing.expectEqual(rm.?.end, pmm.end);
    }
}

test "comptime backtracker findAll/count parity with runtime Regex" {
    // Non-overlapping iteration on the `.backtrack` arm must use the same
    // span-shift + empty-advance convention as the runtime engine.
    const a = std.testing.allocator;
    const P = regex.Pattern("(\\w+)\\1", .{});
    comptime std.debug.assert(!P.has_dfa);
    var rx = try Regex.compile(a, "(\\w+)\\1");
    defer rx.deinit();
    const in = "abcabc x yzyz tutu end";

    try std.testing.expectEqual(try rx.count(in), P.count(in));

    const rms = try rx.findAll(a, in);
    defer a.free(rms);
    const pms = try P.findAll(a, in);
    defer a.free(pms);
    try std.testing.expectEqual(rms.len, pms.len);
    for (rms, pms) |r, q| {
        try std.testing.expectEqual(r.start, q.start);
        try std.testing.expectEqual(r.end, q.end);
    }
}

test "comptime backtracker bakes a trimmed HIR (rodata size sanity)" {
    // Step 2: the baked HIR is trimmed to the pattern's exact node count, not
    // the `HIR_CAP` = 2048 build ceiling — so a tiny non-regular pattern emits a
    // tiny `.rodata` table rather than ~98 KB. `(ab)\1` is ~6 HIR nodes.
    const P = regex.Pattern("(ab)\\1", .{});
    comptime std.debug.assert(!P.has_dfa);
    comptime std.debug.assert(P.bt_node_count > 0 and P.bt_node_count < 32);
}

// Over-approximation seek prefilter: the baked `Dfa256` (atomic/possessive
// shapes with no leading look-behind) and the `lb_byte` memchr (leading
// `(?<=X)`) only change WHERE the backtracker starts scanning — never which
// match it finds. The short-input `btAgree` cases above can't catch a seek that
// wrongly skips a valid start; this drives `findAll`/`count` over a longer,
// multi-match input with dead gaps between matches (where the seek actually
// fires repeatedly) and pins comptime == runtime span-for-span. A seek that
// skipped a real start would drop or shift a match here.
fn seekParity(comptime p: []const u8, in: []const u8) !void {
    const a = std.testing.allocator;
    const P = regex.Pattern(p, .{});
    comptime std.debug.assert(!P.has_dfa);
    var rx = try Regex.compile(a, p);
    defer rx.deinit();

    try std.testing.expectEqual(try rx.count(in), P.count(in));
    const rms = try rx.findAll(a, in);
    defer a.free(rms);
    const pms = try P.findAll(a, in);
    defer a.free(pms);
    try std.testing.expectEqual(rms.len, pms.len);
    for (rms, pms) |r, q| {
        try std.testing.expectEqual(r.start, q.start);
        try std.testing.expectEqual(r.end, q.end);
        try std.testing.expectEqualStrings(r.slice, q.slice);
    }
}

test "comptime backtracker over-approx seek: findAll/count parity over dead gaps" {
    // atomic_token: over-approx DFA seek (no leading look-behind). Long input
    // with non-token filler between `…@` hits — the seek skips each gap.
    try seekParity("(?>[A-Za-z0-9_]+)@",
        \\  ... foo@bar ... ###### nothing here ###### baz@qux ... !!!!!!! end@now
    );
    // lookbehind_amount: lb_byte memchr seek skips to each `$`.
    try seekParity("(?<=\\$)[0-9]+(?:\\.[0-9]{2})?",
        \\price $12.50 then a long stretch of no dollars at all then $99 and $0.01 done
    );
    // possessive (lowers to atomic) with trailing literal — same seek shape.
    try seekParity("[A-Za-z]++;", "aa; ....... bb; ....... ccc; xyz");
}

test "comptime backtracker delegate: regular-island DFA == tree-walk (parity vs runtime)" {
    // Concat-internal regular-island delegation, baked at comptime: a greedy
    // regular PREFIX of a concat (the `.a` spine) runs at DFA speed via
    // `core.matchEndFrom`, the irregular glue (lookahead) stays in the
    // tree-walker. These patterns FIRE the baked delegate (verified: islands>0);
    // the delegate is sound only if delegate-on == delegate-off, so comptime
    // findAll/count must match the runtime engine span-for-span. Multi-match
    // inputs with both hits and near-misses (the continuation fails ⇒ fall back
    // to full `m(nd.a,…)` recursion) exercise both branches of the delegation.
    try seekParity("[a-z]+[0-9]+(?=END)", "ab12END zz9END q aaaa1111ENDED a1END x000");
    // NOTE: `[A-Za-z]+ (?=\d)` and `x[0-9]*y+(?!Z)` used to live here (backtracker
    // + seek). They are now `concat(regular_core, trailing_width1_look)`, so they
    // route to the edge-look DFA peel (has_dfa = true) and are covered — comptime
    // == runtime, incl. multi-match findAll/count — in tests/feat_lookaround.zig.
}

test "comptime backtracker look-assertions: \\b / \\A\\z\\Z / (?m) anchors vs runtime" {
    // Look-assertions (`cc.lookHolds`) now evaluate at comptime — the comptime
    // `Pattern` has no `.bt_look` engine, so `has_look` routes them to the same
    // baked tree-backtracker (`pattern.zig buildAll`'s `or props.has_look`). The
    // parser no longer rejects `.look` at `cap != null`. These previously
    // `@compileError`'d; assert comptime span/count == runtime.
    //   \b word boundary (the `backref_word`/`deep_alternation` blocker):
    try btAgree("\\bword\\b", "a word here, wording, sword, word.");
    try btAgree("(\\w+)\\1", "hello hellohello x"); // bare backref still fine
    try seekParity("\\b[a-z]+\\b", "  foo bar1 baz  qux  ");
    //   deep-alternation `\b(?:kw|kw|…)\b` — routes to the tree-walker, bypassing
    //   the MAX_NFA ceiling that rejects it on the DFA path:
    try seekParity("\\b(?:break|case|catch|class|const|continue|return|if|else|for|while)\\b", "if x then break; for y return; classify const cases while continue");
    //   `\Z` (end-before-optional-final-`\n`) is a real look ⇒ backtrack arm.
    //   (`\A`/`\z` are NOT here: the prescan folds them into the anchored-DFA
    //   fast path — `has_dfa == true` — so they never needed the backtracker and
    //   are covered by the anchored-DFA tests instead.)
    try btAgree("baz\\Z", "foobaz\n");
    try btAgree("baz\\Z", "foobaz");
    //   inline (?m) line anchors (the `multiline_log` shape):
    try seekParity("(?m)^[0-9]{4}-[0-9]{2}-[0-9]{2}.*$", "2024-01-02 hi\njunk\n2025-12-31 yo\n2026-06-01 z\n");
    try seekParity("(?m)^#", "a\n#one\nb\n#two\n##three");
}

// Capture-submatch parity on the `.backtrack` arm: the comptime **zero-alloc**
// `captures()` (→ `Captures`) must agree with the runtime `Regex.captures` (→
// allocator-owned `Match`) on the whole-match span AND every numbered/named
// group (slice, start, end, participation), since both derive numbering + names
// from the same `parser.scanGroups`. Compares group-by-group, comptime `Captures`
// vs runtime `Match`.
fn btCapAgree(comptime p: []const u8, in: []const u8, comptime ng: usize) !void {
    const a = std.testing.allocator;
    const P = regex.Pattern(p, .{});
    comptime std.debug.assert(!P.has_dfa);
    var rx = try Regex.compile(a, p);
    defer rx.deinit();

    const pc = P.captures(in); // ?Captures — no allocator
    var rm = try rx.captures(a, in); // !?Match — allocates groups
    defer if (rm) |*x| x.deinit(a);

    try std.testing.expectEqual(rm == null, pc == null);
    if (rm == null) return;
    const caps = pc.?;
    const rmm = rm.?;
    try std.testing.expectEqualStrings(rmm.slice, caps.slice());
    try std.testing.expectEqual(rmm.start, caps.get(0).?.start);
    inline for (1..ng + 1) |g| {
        const rg = rmm.groups[g];
        const cg = caps.get(g);
        try std.testing.expectEqual(rg == null, cg == null);
        if (rg) |rgg| {
            try std.testing.expectEqual(rgg.start, cg.?.start);
            try std.testing.expectEqual(rgg.end, cg.?.end);
            try std.testing.expectEqualStrings(rgg.slice, cg.?.slice);
        }
    }
}

test "comptime backtracker captures(): numbered group parity with runtime Regex" {
    try btCapAgree("(\\w+)-\\1", "ab-ab tail", 1); // group 1 = "ab"
    try btCapAgree("(a)(b)\\2\\1", "abba", 2); // two groups, both participate
    try btCapAgree("(\\w+) \\1", "the the quick", 1); // group 1 = "the"
    try btCapAgree("(\\w+) \\1", "no repeat here", 1); // whole pattern no-match
    try btCapAgree("(ab)\\1", "abab", 1); // group 1 across a backref
    // A group that does not participate must be reported absent on both sides.
    try btCapAgree("(x)|(y)\\2", "y", 2); // 2nd-branch backref; group 1 absent
}

test "comptime backtracker captures(): named-group parity (getName/groupByName)" {
    // Differential on slices/spans first (zero-alloc Captures vs runtime Match).
    try btCapAgree("(?<w>\\w+)=\\k<w>", "foo=foo rest", 1);
    try btCapAgree("(?<q>['\"]).*?\\k<q>", "say \"hi\" ok", 1);

    // Then assert the name resolves on the comptime path, matching the runtime —
    // full named-capture parity. `getName` is compile-time-resolved; `groupByName`
    // is its runtime peer.
    const a = std.testing.allocator;
    const P = regex.Pattern("(?<w>\\w+)=\\k<w>", .{});
    comptime std.debug.assert(!P.has_dfa);
    var rx = try Regex.compile(a, "(?<w>\\w+)=\\k<w>");
    defer rx.deinit();

    const caps = P.captures("foo=foo rest").?; // no allocator
    var rm = (try rx.captures(a, "foo=foo rest")).?;
    defer rm.deinit(a);

    const rg = rm.groupByName("w").?;
    try std.testing.expectEqualStrings("foo", caps.getName("w").?.slice);
    try std.testing.expectEqualStrings(rg.slice, caps.getName("w").?.slice);
    try std.testing.expectEqualStrings("foo", caps.groupByName("w").?.slice); // runtime-named peer
    try std.testing.expectEqual(rg.start, caps.getName("w").?.start);
}

test "comptime backtracker capturesAll(): non-overlapping captures parity" {
    const a = std.testing.allocator;
    const P = regex.Pattern("(\\w)\\1", .{}); // doubled char, group 1 = the char
    comptime std.debug.assert(!P.has_dfa);
    var rx = try Regex.compile(a, "(\\w)\\1");
    defer rx.deinit();
    const in = "aabbXccd eez";

    const rms = try rx.capturesAll(a, in); // []Match, each owns groups
    defer {
        for (rms) |*mt| mt.deinit(a);
        a.free(rms);
    }
    const pcs = try P.capturesAll(a, in); // []Captures — ONE slice alloc, inline groups
    defer a.free(pcs); // no per-element deinit (groups are inline)
    try std.testing.expectEqual(rms.len, pcs.len);
    for (rms, pcs) |r, c| {
        try std.testing.expectEqual(r.start, c.get(0).?.start);
        try std.testing.expectEqual(r.end, c.get(0).?.end);
        try std.testing.expectEqualStrings(r.slice, c.slice());
        try std.testing.expectEqualStrings(r.groups[1].?.slice, c.get(1).?.slice);
    }
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

// ───────────────────────────────────────────────────────────────────────────
// Zero-alloc comptime captures + lazy verbs (Pattern.captures / get /
// getName / iterator / splitIterator / startsWith). These are the comptime,
// allocation-free peers of the runtime Regex.captures / iterator / split. Each
// test asserts comptime == runtime so the new surface can't drift.
// ───────────────────────────────────────────────────────────────────────────

// captures() parity: the inline `Captures` must agree with the runtime
// `Regex.captures` on the whole match AND every group (slice/start/end/
// participation), for both the DFA arm (regular-with-captures, e.g. date
// fields) and the backtrack arm (backreference). Also exercises the
// compile-time-indexed `get(i)`.
fn capAgree(comptime p: []const u8, in: []const u8, comptime ng: usize) !void {
    const a = std.testing.allocator;
    const P = regex.Pattern(p, .{});
    const pc = P.captures(in);
    var rx = try Regex.compile(a, p);
    defer rx.deinit();
    var rm = try rx.captures(a, in);
    defer if (rm) |*m| m.deinit(a);

    try std.testing.expectEqual(rm == null, pc == null);
    if (rm == null) return;
    const caps = pc.?;
    const rmm = rm.?;
    try std.testing.expectEqualStrings(rmm.slice, caps.slice());
    // group 0 == whole match
    try std.testing.expectEqual(rmm.start, caps.get(0).?.start);
    // every group 1..ng agrees (compile-time-indexed get)
    inline for (1..ng + 1) |g| {
        const rg = rmm.groups[g];
        const cg = caps.get(g);
        try std.testing.expectEqual(rg == null, cg == null);
        if (rg) |rgg| {
            try std.testing.expectEqualStrings(rgg.slice, cg.?.slice);
            try std.testing.expectEqual(rgg.start, cg.?.start);
            try std.testing.expectEqual(rgg.end, cg.?.end);
        }
    }
}

test "comptime Pattern.captures: zero-alloc captures parity (DFA + backtrack arms)" {
    // DFA arm — regular pattern with groups (the flagship date-fields case):
    try capAgree("([0-9]{4})-([0-9]{2})-([0-9]{2})", "log 2026-06-01 end", 3);
    try capAgree("([0-9]{4})-([0-9]{2})-([0-9]{2})", "no date here", 3); // no match
    try capAgree("(\\w+)@(\\w+)\\.(\\w+)", "x user@host.io y", 3); // email-ish
    // Backtrack arm — backreference with a captured group:
    try capAgree("(\\w+) \\1", "the the quick", 1);
    try capAgree("(\\w+)-\\1", "ab-ab tail", 1);
    // A group that doesn't participate (alternation) must read null on both:
    try capAgree("(a)|(b)", "b", 2);
}

test "comptime Pattern.get / getName: compile-time-indexed, zero allocation" {
    // Named groups resolve at compile time; get/getName fold to array reads.
    const Date = regex.Pattern("(?<y>[0-9]{4})-(?<m>[0-9]{2})-(?<d>[0-9]{2})", .{});
    const c = Date.captures("ts=2026-06-01!").?;
    try std.testing.expectEqualStrings("2026", c.get(1).?.slice);
    try std.testing.expectEqualStrings("2026", c.getName("y").?.slice);
    try std.testing.expectEqualStrings("06", c.getName("m").?.slice);
    try std.testing.expectEqualStrings("01", c.getName("d").?.slice);
    try std.testing.expectEqualStrings("2026-06-01", c.slice());
    // runtime-indexed / runtime-named peers agree:
    try std.testing.expectEqualStrings("06", c.group(2).?.slice);
    try std.testing.expectEqualStrings("01", c.groupByName("d").?.slice);
    try std.testing.expect(c.group(9) == null); // out-of-range runtime index ⇒ null
    // captures() works with NO allocator at all — prove it under the
    // `failing` allocator (any allocation would error):
    const F = regex.Pattern("([0-9]+)", .{});
    const fc = F.captures("abc123def").?; // must not touch the allocator
    try std.testing.expectEqualStrings("123", fc.get(1).?.slice);
}

test "comptime Pattern.iterator: lazy whole-match, parity with runtime iterator" {
    const a = std.testing.allocator;
    const P = regex.Pattern("[0-9]+", .{});
    var rx = try Regex.compile(a, "[0-9]+");
    defer rx.deinit();
    const in = "a12 b345 c6 d";

    // comptime lazy iterator vs runtime findAll spans
    const rms = try rx.findAll(a, in);
    defer a.free(rms);
    var it = P.iterator(in);
    var i: usize = 0;
    while (it.next()) |m| : (i += 1) {
        try std.testing.expectEqual(rms[i].start, m.start);
        try std.testing.expectEqual(rms[i].end, m.end);
    }
    try std.testing.expectEqual(rms.len, i);

    // early-break costs nothing and is well-defined:
    var it2 = P.iterator(in);
    try std.testing.expectEqualStrings("12", it2.next().?.slice);
    // empty input ⇒ no matches
    var it3 = P.iterator("");
    try std.testing.expect(it3.next() == null);
}

test "comptime Pattern.capturesIterator: lazy zero-alloc captures stream" {
    const a = std.testing.allocator;
    const P = regex.Pattern("(\\w)(\\w)", .{}); // pairs of word chars
    var rx = try Regex.compile(a, "(\\w)(\\w)");
    defer rx.deinit();
    const in = "ab cd ef";
    const rms = try rx.capturesAll(a, in);
    defer {
        for (rms) |*m| m.deinit(a);
        a.free(rms);
    }
    var it = P.capturesIterator(in);
    var i: usize = 0;
    while (it.next()) |c| : (i += 1) {
        try std.testing.expectEqualStrings(rms[i].groups[1].?.slice, c.get(1).?.slice);
        try std.testing.expectEqualStrings(rms[i].groups[2].?.slice, c.get(2).?.slice);
    }
    try std.testing.expectEqual(rms.len, i);
}

test "comptime Pattern.splitIterator: parity with runtime split" {
    const a = std.testing.allocator;
    inline for (.{ ",", "\\s+", "::" }) |p| {
        const P = regex.Pattern(p, .{});
        var rx = try Regex.compile(a, p);
        defer rx.deinit();
        inline for (.{ "a,bb,,c", "one  two   three", "x::y::z", "nodelim", "" }) |in| {
            const parts = try rx.split(a, in);
            defer a.free(parts);
            var it = P.splitIterator(in);
            var i: usize = 0;
            while (it.next()) |field| : (i += 1) {
                if (i < parts.len) try std.testing.expectEqualStrings(parts[i], field);
            }
            try std.testing.expectEqual(parts.len, i);
        }
    }
}

test "comptime Pattern.startsWith: anchored-prefix test" {
    const Ver = regex.Pattern("v[0-9]+", .{});
    try std.testing.expect(Ver.startsWith("v12.x"));
    try std.testing.expect(!Ver.startsWith(" v12")); // match exists but not at 0
    try std.testing.expect(!Ver.startsWith("abc"));
    // routing/prefix engine (lit_prefix) still answers startsWith correctly:
    const Hello = regex.Pattern("hello.*world", .{});
    try std.testing.expect(Hello.startsWith("hello big world"));
    try std.testing.expect(!Hello.startsWith("say hello world"));
}
