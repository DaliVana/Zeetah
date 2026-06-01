//! The meta-engine planner: a **pure** function from `(Properties, flags)` to
//! a `Strategy`. It never reads the haystack, so for a comptime-known pattern
//! the entire decision evaluates at compile time; for a runtime pattern it
//! runs once per `compile`.
//!
//! `plan` returns one of: `.literal` (pure substring/Teddy, no automaton),
//! `.prefix_prefilter` (selective literal/byte prefix → Teddy-locate +
//! anchored DFA verify, the `.lit_prefix` kind), `.reverse_suffix`
//! (selective trailing literal fast-negative + forward DFA), or `.core`
//! (the eager DFA). Non-regular patterns (lookaround / backreferences) are
//! detected by `properties.requires_backtracking` and handled by
//! `regex.zig` *before* `plan` is consulted — `.backtrack` is kept only as
//! the corresponding sentinel.

const std = @import("std");
const properties = @import("properties.zig");
const seq_extract = @import("exec/seq_extract.zig");

const Properties = properties.Properties;
const Seq = seq_extract.Seq;

/// What the executor should do. Ordered by the doc's §5 preference: cheapest
/// (no regex engine at all) first.
pub const Strategy = union(enum) {
    /// The whole pattern is one or more fixed literals — substring search
    /// only, no automaton (memmem / Teddy). `seq` is exact.
    literal: Seq,
    /// A selective literal/byte prefix exists — prefilter to candidate starts,
    /// then run the core engine there.
    prefix_prefilter: struct { seq: Seq, first_byte_set: ?[32]u8 },
    /// A selective trailing literal exists but no selective prefix: use it as
    /// a sound fast-negative (no occurrence => no match) before the forward
    /// DFA. `seq` is the necessary suffix.
    reverse_suffix: Seq,
    /// General case: the eager DFA.
    core,
    /// Sentinel for non-regular patterns (lookaround / backref). Handled by
    /// `regex.zig` before `plan` is consulted; never matched at dispatch.
    backtrack,
};

/// Flags that affect the decision (kept tiny + comptime-friendly).
pub const Flags = struct {
    case_insensitive: bool = false,
};

/// THE pure decision. No allocation, no haystack, comptime-evaluable.
pub fn plan(p: Properties, flags: Flags) Strategy {
    if (p.requires_backtracking) return .backtrack;

    // §5.1 — Pure literal(s): substring search wins, skip the engine entirely.
    // Case-insensitive letter literals need the engine's folding; but a
    // *case-invariant* literal (no ASCII letters — digits, punctuation, …)
    // folds to itself, so the exact substring search is already a correct
    // case-insensitive search and qualifies here too (`isCaseInvariant`).
    if (p.is_exact_literal and !p.prefix.isEmpty() and
        (!flags.case_insensitive or p.prefix.isCaseInvariant()))
    {
        return .{ .literal = p.prefix };
    }
    if (p.prefix.exact and p.prefix.n > 1 and
        !p.anchored_start and !p.anchored_end and
        (!flags.case_insensitive or p.prefix.isCaseInvariant()))
    {
        // Exact alternation of literals (`cat|dog|bird`) -> multi-substring.
        return .{ .literal = p.prefix };
    }

    // §5.4 — A selective trailing literal but no literal prefix: the suffix
    // is a sound fast-negative and drives the reverse DFA. Prefer it over a
    // broad first-byte prefilter.
    if (p.prefix.isEmpty() and
        !p.suffix.isEmpty() and p.suffix.minLen() >= 2 and
        !p.anchored_start and !p.anchored_end and
        (!flags.case_insensitive or p.suffix.isCaseInvariant()))
    {
        return .{ .reverse_suffix = p.suffix };
    }

    // §5.3 — A selective prefix (literal run or necessary first-byte set):
    // prefilter to candidates, then verify with the core engine.
    const has_prefix_lit = !p.prefix.isEmpty() and p.prefix.minLen() >= 2 and
        (!flags.case_insensitive or p.prefix.isCaseInvariant());
    if (has_prefix_lit or p.first_byte_set != null) {
        return .{ .prefix_prefilter = .{
            .seq = if (has_prefix_lit) p.prefix else Seq{},
            .first_byte_set = p.first_byte_set,
        } };
    }

    // §5.6 — Everything else: the merged core engine.
    return .core;
}

/// The concrete per-position search route the executor will run, after the
/// planner's abstract `Strategy` is resolved against anchoring and the
/// literal-prefix gate. This is the SINGLE source of truth shared by both
/// front-ends — the runtime `regex.zig` and the comptime `pattern.zig` — so the
/// `.lit_prefix` gate and the suffix/prefix `Seq` selection live in one place.
///
/// Whether the chosen literal can actually be Teddy-compiled is a
/// *materialization* concern, not a routing one: each front-end downgrades a
/// `.literal`/`.reverse_suffix`/`.lit_prefix` whose `Seq` fails `buildLiteral`
/// to a plain DFA itself.
pub const Route = union(enum) {
    /// Pure literal(s); no DFA table — Teddy only. `Seq` is exact.
    literal: Seq,
    /// Forward DFA gated by a trailing-literal fast-negative. `Seq` is the
    /// necessary suffix.
    reverse_suffix: Seq,
    /// Teddy-locate a leading literal prefix, then anchored-verify. `Seq` is the
    /// prefix (already cleared the ≥3-byte / unanchored gate).
    lit_prefix: Seq,
    /// Plain eager DFA: the planner's `.core`, or a `.prefix_prefilter` whose
    /// prefix did not clear the `.lit_prefix` gate.
    dfa,
    /// Sentinel for non-regular patterns. Never produced for a pattern that
    /// reaches `resolve` (both front-ends divert `requires_backtracking`
    /// upstream), kept only so the mapping is total.
    backtrack,
};

/// Resolve the planner's abstract `Strategy` to the concrete executor `Route`,
/// applying the shared `.lit_prefix` gate: a real ≥3-byte literal prefix that
/// is not `^`-anchored (the anchored verify path's `runFrom` ignores
/// `a_start`, so a leading-anchored prefix must stay on the plain DFA). Pure
/// and comptime-evaluable — same contract as `plan`.
pub fn resolve(strat: Strategy, anchored_start: bool) Route {
    return switch (strat) {
        .literal => |seq| .{ .literal = seq },
        .reverse_suffix => |sfx| .{ .reverse_suffix = sfx },
        .prefix_prefilter => |pp| if (!pp.seq.isEmpty() and pp.seq.minLen() >= 3 and !anchored_start)
            .{ .lit_prefix = pp.seq }
        else
            .dfa,
        .core => .dfa,
        .backtrack => .backtrack,
    };
}

// --- Tests -----------------------------------------------------------------

const hir = @import("hir.zig");
const parser = @import("parser.zig");

fn planFor(comptime src: []const u8) Strategy {
    @setEvalBranchQuota(1_000_000);
    const H = hir.Hir(256);
    var h = H.initComptime();
    parser.parse(256, &h, undefined, src, .{}) catch unreachable;
    const p = properties.analyze(256, &h);
    return plan(p, .{});
}

fn planForCi(comptime src: []const u8) Strategy {
    @setEvalBranchQuota(1_000_000);
    const H = hir.Hir(256);
    var h = H.initComptime();
    parser.parse(256, &h, undefined, src, .{ .ci = true }) catch unreachable;
    const p = properties.analyze(256, &h);
    return plan(p, .{ .case_insensitive = true });
}

// 3.3 — case-insensitive literal fast paths. Under `ci` a *case-invariant*
// literal (no ASCII letters) folds to itself, so the exact literal/prefix/
// suffix strategies are still sound and must be picked; a letter-bearing
// literal still falls to the folded first-byte-set DFA (`.core`/prefilter).

test "planner(ci): letter-free exact literal -> .literal" {
    const s = comptime planForCi("12345");
    try std.testing.expect(s == .literal);
    try std.testing.expectEqualStrings("12345", s.literal.alt(0));
}

test "planner(ci): letter-free alternation -> .literal multi" {
    const s = comptime planForCi("12|34|56");
    try std.testing.expect(s == .literal);
    try std.testing.expectEqual(@as(u8, 3), s.literal.n);
}

test "planner(ci): letter-free prefix -> .prefix_prefilter (lit_prefix)" {
    const s = comptime planForCi("1234.*5678");
    try std.testing.expect(s == .prefix_prefilter);
    try std.testing.expectEqualStrings("1234", s.prefix_prefilter.seq.alt(0));
    try std.testing.expect(comptime resolve(s, false) == .lit_prefix);
}

test "planner(ci): letter-free selective suffix -> .reverse_suffix" {
    const s = comptime planForCi("[A-Z].*9999");
    try std.testing.expect(s == .reverse_suffix);
    try std.testing.expectEqualStrings("9999", s.reverse_suffix.alt(0));
}

test "planner(ci): letter-bearing literal stays off the fast paths" {
    // `hello` folds to 2-bit sets ⇒ no Seq ⇒ folded first-byte-set prefilter.
    try std.testing.expect(comptime planForCi("hello") == .prefix_prefilter);
    try std.testing.expect(comptime resolve(planForCi("hello"), false) == .dfa);
    // selective letter suffix must NOT become a (case-sensitive) reverse_suffix
    try std.testing.expect(comptime planForCi("[A-Z].*foobar") == .prefix_prefilter);
}

test "planner: exact literal -> .literal" {
    const s = comptime planFor("hello");
    try std.testing.expect(s == .literal);
    try std.testing.expectEqualStrings("hello", s.literal.alt(0));
}

test "planner: alternation of literals -> .literal multi" {
    const s = comptime planFor("cat|dog|bird");
    try std.testing.expect(s == .literal);
    try std.testing.expectEqual(@as(u8, 3), s.literal.n);
}

test "planner: literal-prefixed -> .prefix_prefilter" {
    const s = comptime planFor("hello.*world");
    try std.testing.expect(s == .prefix_prefilter);
    try std.testing.expectEqualStrings("hello", s.prefix_prefilter.seq.alt(0));
}

test "planner: classy pattern -> prefilter via first_byte_set" {
    const s = comptime planFor("[a-z]+@[a-z]+");
    try std.testing.expect(s == .prefix_prefilter);
    try std.testing.expect(s.prefix_prefilter.first_byte_set != null);
}

test "planner: selective suffix, weak prefix -> .reverse_suffix" {
    const s = comptime planFor("[A-Z].*foobar");
    try std.testing.expect(s == .reverse_suffix);
    try std.testing.expectEqualStrings("foobar", s.reverse_suffix.alt(0));
}

test "planner: nullable pattern -> .core" {
    const s = comptime planFor("a*b*");
    try std.testing.expect(s == .core);
}

// `resolve` is the shared gate both front-ends route through; pin its
// classification directly so a divergence here is caught without a full
// comptime⇄runtime differential sweep.

test "resolve: exact literal -> .literal" {
    const r = comptime resolve(planFor("hello"), false);
    try std.testing.expect(r == .literal);
}

test "resolve: selective suffix -> .reverse_suffix" {
    const r = comptime resolve(planFor("[A-Z].*foobar"), false);
    try std.testing.expect(r == .reverse_suffix);
}

test "resolve: >=3-byte unanchored literal prefix -> .lit_prefix" {
    const r = comptime resolve(planFor("hello.*world"), false);
    try std.testing.expect(r == .lit_prefix);
    try std.testing.expectEqualStrings("hello", r.lit_prefix.alt(0));
}

test "resolve: a start-anchored literal prefix stays on the plain DFA" {
    // The same prefix-bearing strategy, but with `anchored_start = true`:
    // `runFrom` ignores `a_start`, so the gate must NOT pick `.lit_prefix`.
    const r = comptime resolve(planFor("hello.*world"), true);
    try std.testing.expect(r == .dfa);
}

test "resolve: a <3-byte prefix falls back to the plain DFA" {
    // `ab` is only a 2-byte prefix → below the `.lit_prefix` minimum.
    const r = comptime resolve(planFor("ab.*world"), false);
    try std.testing.expect(r == .dfa);
}

test "resolve: class-only prefilter (first_byte_set, no literal) -> .dfa" {
    const r = comptime resolve(planFor("[a-z]+@[a-z]+"), false);
    try std.testing.expect(r == .dfa);
}

test "resolve: nullable pattern -> .dfa" {
    const r = comptime resolve(planFor("a*b*"), false);
    try std.testing.expect(r == .dfa);
}
