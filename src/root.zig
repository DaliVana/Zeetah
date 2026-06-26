//! Zeetah — a fast, dependency-free regex meta engine for Zig.
//!
//! The public API is intentionally small. Compile a pattern with
//! `Regex.compile` (or `Regex.compileWithFlags`), then use `find`, `findAll`,
//! `captures`, `replace`/`replaceAll`, `split`, or `iterator`. Patterns known
//! at compile time can use the allocation-free `Pattern` path. Build patterns
//! programmatically with `Builder` / `Patterns`.
//!
//! Example:
//! ```zig
//! const Regex = @import("zeetah").Regex;
//! var re = try Regex.compile(allocator, "\\d+");
//! defer re.deinit();
//! if (try re.find("abc123")) |m| {
//!     std.debug.print("Found: {s}\n", .{m.slice});
//! }
//! ```
//!
//! `find`/`findAll`/`isMatch`/`iterator` are the capture-free fast path; pull
//! submatches with `captures`/`capturesAll`/`capturesIterator`.
//!
//! Semantics are **byte-oriented** (committed default): `.` matches one byte,
//! `\d`/`\w`/`\b` are ASCII, `\p` is Latin-1. Codepoint-aware mode is reserved
//! behind the `.unicode` flag / inline `(?u)` — currently `error.NotImplemented`,
//! and opt-in-only when added (so it will be additive, not a semantics change).
//!
//! Engine internals (parser, NFA/DFA compilers, planner, executors,
//! prefilters, profiling) are deliberately NOT exported here. They are
//! implementation detail and carry no stability guarantee; depend only on the
//! names below.

const std = @import("std");

/// A compiled regular expression. The primary entry point — see
/// `compile`, `find`, `findAll`, `replace`, `replaceAll`, `split`, `iterator`.
pub const Regex = @import("regex.zig").Regex;

/// Flags for `Regex.compileWithFlags` (struct peers of inline `(?i)`/`(?s)`/
/// `(?x)`/`(?m)`): `case_insensitive`, `dot_all`, `extended`, `multiline`.
/// `unicode` is reserved (see the Unicode note in the docs) and currently
/// returns `error.NotImplemented`.
pub const CompileFlags = @import("common.zig").CompileFlags;

/// The result of a successful match: the matched `slice` and its half-open
/// byte range `[start, end)`. `find`/`findAll`/`iterator` leave `groups` empty
/// (the capture-free fast path); `captures`/`capturesAll`/`capturesIterator`
/// populate submatches. `Match.deinit(allocator)` frees the owned groups slice
/// and is a no-op for non-capturing results.
pub const Match = @import("match.zig").Match;

/// A captured submatch: its `slice`, half-open byte range, and optional
/// `(?<name>…)` name. Populated only on the `captures` paths; empty on `find`.
pub const Group = @import("match.zig").Group;

/// Lazy iterator over successive whole-match spans (capture-free); obtain one
/// via `Regex.iterator`.
pub const MatchIterator = @import("regex.zig").Regex.MatchIterator;

/// Lazy iterator over successive capture-bearing matches; obtain one via
/// `Regex.capturesIterator`. Each yielded `Match` owns its `groups`.
pub const CapturesIterator = @import("regex.zig").Regex.CapturesIterator;

/// The error set returned by compilation and matching.
pub const RegexError = @import("errors.zig").RegexError;

/// Allocation-free regex over a comptime-known pattern: the meta planner runs
/// at compile time and emits only the chosen strategy (literal scan or baked
/// DFA). Replaces the former `ComptimeRegex`.
pub const Pattern = @import("pattern.zig").Pattern;

/// Options for `Pattern`.
pub const PatternOptions = @import("pattern.zig").Options;

/// Comptime predicate: does `Pattern(pattern, …)` compile, or would it hit one
/// of its `@compileError`s (unsupported feature / malformed / too complex)?
/// Lets callers (and tooling like the cross-engine benchmark) branch at compile
/// time over a pattern set instead of failing the build on the first pattern
/// the comptime path can't represent. `ci` matches `Options.case_insensitive`.
pub const compilesAtComptime = @import("pattern.zig").compilesAtComptime;

/// Type-safe fluent builder for constructing patterns programmatically.
pub const Builder = @import("builder.zig").Builder;

/// A collection of ready-made patterns (email, URL, IPv4, …).
pub const Patterns = @import("builder.zig").Patterns;

/// Library version. Kept in lockstep with `build.zig.zon`'s `.version` by the
/// `tests/version_sync.zig` guard (build.zig feeds the manifest version in).
pub const version = std.SemanticVersion{
    .major = 0,
    .minor = 16,
    .patch = 1,
};

test {
    // Run all tests from imported modules
    std.testing.refAllDecls(@This());
}
