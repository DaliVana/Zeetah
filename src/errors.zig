const std = @import("std");

/// The errors Zeetah actually returns — deliberately minimal for the alpha
/// freeze. Every variant here is a real, reachable outcome, so an exhaustive
/// `switch` over a `RegexError` value is meaningful (no dead arms). Narrowing
/// this set later would be breaking, so it starts at exactly the returnable
/// set; ADDING a variant later (if a future feature needs one) is non-breaking.
///
/// Compile time (`compile` / `compileWithFlags`):
///   - `EmptyPattern`      — the pattern string was empty.
///   - `InvalidPattern`    — malformed syntax: unbalanced/empty/duplicate
///                           groups, dangling/double/possessive quantifiers,
///                           malformed or inverted `{m,n}`, bad back-references.
///   - `NotImplemented`    — well-formed but unsupported: the `.unicode` flag,
///                           `\p` scripts/binary/`(?i)`, unknown POSIX class,
///                           counts > 1000, possessive quantifiers, unrecognised
///                           `(?…)` constructs.
///   - `PatternTooComplex` — a construction ceiling overflowed at compile time.
/// Match time (`find` / `isMatch` / `captures`):
///   - `MatchBudgetExceeded` — a backtracking pattern (backreference /
///                             lookaround) exceeded its per-haystack step
///                             budget. Distinct from `PatternTooComplex`.
/// Either:
///   - `OutOfMemory`       — an allocation failed.
pub const RegexError = error{
    EmptyPattern,
    InvalidPattern,
    NotImplemented,
    PatternTooComplex,
    MatchBudgetExceeded,
    OutOfMemory,
};

test "RegexError is exactly the returnable set (alpha-freeze guard)" {
    // The public error set must enumerate ONLY variants the engine returns, so
    // an exhaustive `switch` is writable without dead arms. Removing a variant
    // post-alpha is breaking; adding one is not. If you intentionally add one,
    // bump this count.
    const set = @typeInfo(RegexError).error_set.?;
    try std.testing.expectEqual(@as(usize, 6), set.len);
}
