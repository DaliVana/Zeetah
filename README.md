<div align="center">

<img src="docs/zeetah.png" alt="Zeetah" width="480">

**Zig fast regex meta engine**

[![Zig](https://img.shields.io/badge/Zig-0.16+-orange.svg)](https://ziglang.org)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[Overview](#overview) · [Install](#installation) · [Quick Start](#quick-start) · [The meta engine](#the-meta-engine) · [Features](#feature-support) · [API](#public-api) · [Docs](#documentation)

</div>

---

## Overview

**Zeetah** is a regular-expression engine for Zig. Instead of running every pattern
on a single matcher, it is a **meta engine**: at `compile` time it analyzes the
pattern and *routes* it to the cheapest strategy that is still correct — a plain
substring scan, a SIMD multi-literal locator, a compiled DFA, or a bounded
backtracker for features no finite automaton can express (lookaround,
backreferences). You call one API; the engine picks the machine.

- **Zero dependencies** — Zig standard library only.
- **Linear-time core** — regular patterns run as a compiled DFA, O(n) per scan.
  Even classic "catastrophic" shapes like `(a+)+$` collapse to a linear DFA.
- **Bounded by design** — patterns that *require* backtracking
  (backreferences, lookaround) run under an explicit step budget and return a
  typed `error.MatchBudgetExceeded` instead of hanging.
- **Compile-time patterns** — for a comptime-known pattern, the whole
  parse → NFA → DFA pipeline runs at compile time and bakes the matcher into
  `.rodata`: no allocator, no runtime compilation. See [`Pattern`](#compile-time-patterns).
- **Capture-free fast path, opt-in captures** — `find` / `isMatch` / `findAll`
  return whole-match spans with no allocation; submatches are available on
  demand via [`captures`](#capture-groups).
- **Allocator-controlled** — every heap allocation goes through the allocator
  you pass; nothing is hidden.

Zeetah grew out of two earlier Zig projects and owes them a direct debt — see
[Acknowledgments](#acknowledgments).

## Installation

Requires **Zig 0.16+**. Zeetah has no external dependencies.

### As a package

Add the dependency to your `build.zig.zon` (replace the URL/hash with a
published release once available):

```zig
.dependencies = .{
    .zeetah = .{
        .url = "TBD", // e.g. a release tarball; `zig fetch --save <url>` fills the hash
        .hash = "...",
    },
},
```

Then wire the module in `build.zig`:

```zig
const zeetah = b.dependency("zeetah", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zeetah", zeetah.module("zeetah"));
```

The published module is named **`zeetah`** and is imported as `@import("zeetah")`.

### From source

```bash
git clone https://github.com/zig-utils/zig-regex.git
cd zig-regex
zig build test     # build + run the full test suite
```

## Quick Start

```zig
const std = @import("std");
const zeetah = @import("zeetah");
const Regex = zeetah.Regex;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var re = try Regex.compile(allocator, "\\d{3}-\\d{4}");
    defer re.deinit();

    // find -> ?Match. The Match borrows from the input (no copy).
    if (try re.find("call 555-1234 now")) |m| {
        std.debug.print("{s} @ [{d}..{d})\n", .{ m.slice, m.start, m.end }); // 555-1234 @ [5..13)
    }

    // boolean test, allocation-free
    std.debug.print("{}\n", .{try re.isMatch("nope")}); // false
}
```

### Find all / iterate / count

```zig
var re = try Regex.compile(allocator, "\\d+");
defer re.deinit();

// Allocator-owned slice of matches:
const all = try re.findAll(allocator, "a1 b22 c333");
defer allocator.free(all); // each Match has no owned groups; only the slice is owned
// all[0].slice == "1", all[1].slice == "22", all[2].slice == "333"

// Lazy iterator (no result slice allocated up front):
var it = re.iterator("a1 b22 c333");
defer it.deinit(); // no-op
while (try it.next(allocator)) |m| { // allocator accepted for API parity; ignored here
    std.debug.print("{s}\n", .{m.slice});
}

// Allocation-free count of non-overlapping matches:
const n = try re.count("a1 b22 c333"); // 3
```

### Replace and split

```zig
var digits = try Regex.compile(allocator, "\\d+");
defer digits.deinit();

// replace = first match, replaceAll = every match.
const out = try digits.replaceAll(allocator, "a1 b22 c333", "#");
defer allocator.free(out); // "a# b# c#"

// The replacement is a TEMPLATE: $0/$& = whole match, $1..$N = numbered
// groups, ${name} = named group, $$ = a literal '$'. Unknown/non-participating
// refs expand to "". Use `${1}2` (not `$12`) for "group 1 then a literal 2".
var date = try Regex.compile(allocator, "(\\d{4})-(\\d{2})-(\\d{2})");
defer date.deinit();
const iso = try date.replaceAll(allocator, "2024-03-15", "$3/$2/$1");
defer allocator.free(iso); // "15/03/2024"

// For a byte-for-byte literal replacement (no $-substitution), use
// `replaceLiteral` / `replaceAllLiteral`:
const lit = try digits.replaceAllLiteral(allocator, "a1 b22", "$1");
defer allocator.free(lit); // "a$1 b$1"  ($ is not special here)

// split around matches of a separator pattern; element slices alias the input.
var ws = try Regex.compile(allocator, "\\s+");
defer ws.deinit();
const parts = try ws.split(allocator, "one two  three");
defer allocator.free(parts); // { "one", "two", "three" }
```

> Note: `split` keeps boundary segments — if the input begins or ends with a
> match, the corresponding edge element is the empty string `""`.

### Capture groups

`find` / `isMatch` / `findAll` take the DFA fast path and **ignore** group
slices (`match.groups.len == 0`) — but the whole-match boundary is always
correct. To extract submatches, opt in with **`captures`**, which allocates and
must be freed:

```zig
var re = try Regex.compile(allocator, "(?<year>\\d{4})-(\\d{2})-(\\d{2})");
defer re.deinit();

if (try re.captures(allocator, "Date: 2024-03-15")) |m| {
    var mm = m;
    defer mm.deinit(allocator); // frees the owned groups slice (required after captures)

    // groups[0] is the WHOLE match; capture N is groups[N].
    std.debug.print("{s}\n", .{mm.slice});               // 2024-03-15  (== groups[0])
    std.debug.print("{s}\n", .{mm.groups[1].?.slice});   // 2024
    std.debug.print("{s}\n", .{mm.groups[2].?.slice});   // 03
    std.debug.print("{s}\n", .{mm.groupByName("year").?.slice}); // 2024
}
```

A group that did not participate in the match is a `null` slot.

To get submatches for **every** match (not just the first), use
**`capturesAll`** (an owned slice) or **`capturesIterator`** (streaming, lower
peak memory). Each yielded `Match` owns its `groups` and must be freed:

```zig
var kv = try Regex.compile(allocator, "(?<k>\\w+)=(?<v>\\d+)");
defer kv.deinit();

// Streaming: free each Match as you go.
var it = kv.capturesIterator("a=1 bb=22");
defer it.deinit();
while (try it.next(allocator)) |mm| {
    var m = mm;
    defer m.deinit(allocator);
    std.debug.print("{s} -> {s}\n", .{ m.groupByName("k").?.slice, m.groupByName("v").?.slice });
}

// Or the whole slice at once (each element owns its groups):
const all = try kv.capturesAll(allocator, "a=1 bb=22");
defer { for (all) |*m| m.deinit(allocator); allocator.free(all); }
```

`capturesFrom(allocator, input, pos)` is the low-level primitive both build on:
the leftmost capture-bearing match at/after byte offset `pos`. Its capture-free
peer is `findFrom(input, pos)` — the positional-resume version of `find`.

### Flags

```zig
// case_insensitive, dot_all, extended, and multiline are honored compile flags.
var re = try Regex.compileWithFlags(allocator, "a.b", .{
    .case_insensitive = true, // ASCII case folding
    .dot_all = true,          // `.` also matches '\n'
    .multiline = true,        // `^`/`$` match at line boundaries
});
defer re.deinit();
```

> **Inline flags** are the more general route: `(?i)`, `(?s)` (dot-all),
> `(?x)` (extended/verbose), and `(?m)` (multiline line anchors) are all
> honored, in both scoped `(?i:…)` and toggle `(?i)` forms. The matching struct
> flags are exact peers — `.multiline` behaves like a leading `(?m)`.
>
> Only the `.unicode` **compile flag** (codepoint-aware mode) is **not yet
> implemented** and returns `error.NotImplemented` — see
> [Feature support](#feature-support) for what that mode would add.

## The meta engine

"Meta engine" means Zeetah does not have *one* matcher — `compile` analyzes the
pattern (a pure pass over the parsed HIR) and dispatches it to the cheapest
correct executor. There are two layers of routing.

### Layer 1 — the runtime dispatcher

`Regex.compile` selects one of roughly a dozen executors. The most important:

| Executor | Chosen for | How it runs |
|----------|-----------|-------------|
| **literal** | a single literal, or an exact literal alternation (`cat\|dog\|bird`) | SIMD substring / Teddy multi-literal scan — **no automaton** |
| **lit_prefix** | a literal prefix ≥ 3 bytes, unanchored (`hello.*world`) | Teddy-locate the prefix, then verify with an anchored DFA |
| **reverse_suffix** | a selective trailing literal, weak prefix (`[A-Z].*foobar`) | use the suffix as a sound fast-negative, then a forward DFA |
| **dfa** | the general regular case | eager DFA table walk (`Dfa256`) |
| **dense_search** | bare unanchored DFA, narrow shape | frozen dense single-pass unanchored DFA |
| **lazy_dfa** | when the eager DFA exceeds its state ceiling | the same subset construction, evaluated on demand |
| **class_span** | one greedy single-range `class+`/`class*` | SIMD member-run scan, no automaton |
| **boundary_lits** | `\b(?:kw1\|kw2\|…)\b` keyword alternations | Aho-Corasick locate + O(1) `\b` verify |
| **bt_look** | plain look-assertions (`\b`, `\B`, mid `^`/`$`, `(?m)`) | bounded backtracker (the DFA does not fold look-assertions) |
| **backtrack** | lookaround / backreferences | HIR tree backtracker with a `seek` prefilter + regular-island delegation |
| **split_alt** | top-level alternation mixing regular and non-regular branches | regular branches → anchored DFAs, the rest → tree backtracker |
| **dup_word** | the adjacent-duplicate-word shape `(\b\w+\b)\s+\1` | a single O(n) linear scan |

### Layer 2 — the planner

The regular-tier decision is a **pure function** `plan(properties, flags) → Strategy`
that never reads the haystack — so for a comptime-known pattern the whole
routing decision evaluates *at compile time*. It returns one of five strategies
(`.literal`, `.prefix_prefilter`, `.reverse_suffix`, `.core`, and a `.backtrack`
sentinel for non-regular patterns, which Layer 1 has already intercepted).

### Prefilters

Before (or instead of) running an automaton, Zeetah tries to skip work:

- **Required byte** — a single byte every accepting path must consume; if a
  `memchr` finds none, the answer is "no match" in one pass.
- **Required literal anywhere** — a rare mandatory literal plus a recipe to
  recover the match start; drives a `memchr` instead of a broad restart loop.
- **First-byte SIMD set** — a 256-bit start-byte set scanned with `@Vector`
  (specialized to single-byte / multi-equality / range / bitset).
- **Teddy** — SIMD multi-substring locator (≤ 8 needles, adaptive nibble masks)
  backing the literal / prefix / suffix executors.
- **Aho-Corasick** — multi-keyword locator for the `boundary_lits` executor.
- **Seek** — a regular over-approximation that skips proven-dead prefixes for
  the backtracking tier.

### Safety & the ReDoS contract

Zeetah's linear-time guarantee is precise about *which* patterns get it:

- **Regular patterns are linear by construction.** Matching is a DFA table
  walk, O(n) per scan. If the eager DFA would explode, it falls back to the
  **lazy DFA** — the bit-identical subset construction built incrementally —
  never to backtracking. Classic catastrophic shapes (`(a+)+$`, `(a*)*$`,
  `(.*)*$`) **compile and run linearly**; they are *not* rejected.
- **Non-regular patterns** (backreferences, lookaround) run on a backtracker
  under an explicit **step budget** (`8000 + (len+1)·4000`) plus a recursion-depth
  guard. Exceeding it returns a typed **`error.MatchBudgetExceeded`** at match
  time — the .NET-style runtime contract, never a hang.
- **Construction ceilings** (NFA states, edges, DFA states, HIR nodes, capture
  groups) raise `error.PatternTooComplex` at compile time for patterns that are
  simply too large to build. (Distinct from the match-time budget error above.)

```zig
// Regular "catastrophic" pattern: compiles and runs as a linear DFA.
var re = try Regex.compile(allocator, "(a+)+$");
defer re.deinit();
_ = try re.isMatch("aaaaaaaaaaaaaaaaX"); // fast, linear — no error

// Non-regular catastrophe (inside a lookahead): bounded at match time.
var re2 = try Regex.compile(allocator, "(?=(a+)+$)a");
defer re2.deinit();
const r = re2.isMatch("aaaaaaaaaaaaaaaaaaaaaaaaX");
_ = r catch |e| switch (e) {
    error.MatchBudgetExceeded => {}, // budget exceeded -> typed error, not a hang
    else => return e,
};
```

## Feature support

| Feature | Syntax | Status |
|---------|--------|--------|
| Literals | `abc`, `123` | ✅ |
| Quantifiers | `*`, `+`, `?`, `{n}`, `{m,n}` | ✅ counts > 1000 → `NotImplemented`; very large in-budget counts → `PatternTooComplex` |
| Lazy quantifiers | `*?`, `+?`, `??`, `{m,n}?` | ✅ lazy **+ end-anchor** (`a*?$`) runs on the backtracker (match-budget bounded) |
| Possessive quantifiers | `*+`, `++`, `?+`, `{m,n}+` | ❌ rejected with `error.NotImplemented`¹ |
| Alternation | `a\|b\|c` | ✅ |
| Predefined classes | `\d \w \s \D \W \S` | ✅ (including inside `[…]`) |
| Custom classes | `[abc]`, `[a-z]`, `[^0-9]`, `[[:alpha:]]` | ✅ unknown POSIX name → `NotImplemented` |
| Unicode properties | `\p{L}`, `\P{Nd}`, `\pL`, `[^\p{L}]` | ⚠️ **General_Category, Latin-1 bytes only**²; scripts/binary props/`\p` under `(?i)`/multibyte codepoints → `NotImplemented`⁵ |
| Inline flags | `(?i)`, `(?s)`, `(?x)`, `(?m)` and scoped `(?i:…)` | ✅ |
| Anchors | `^`, `$`, `\A`, `\z`, `\Z`, `\b`, `\B` | ✅ look-assertions are **runtime-only**³ |
| Wildcard | `.` | ✅ excludes `\n` unless `(?s)` |
| Capturing groups | `(...)` | ✅ slices via opt-in `captures()`⁴ |
| Named groups | `(?<name>...)`, `(?P<name>...)` | ✅ duplicate name → `InvalidPattern` |
| Non-capturing | `(?:...)` | ✅ |
| Lookahead | `(?=...)`, `(?!...)` | ✅ runtime-only, step-budgeted³ |
| Lookbehind | `(?<=...)`, `(?<!...)` | ⚠️ **fixed-width only**; variable-width → `MatchBudgetExceeded` at match |
| Backreferences | `\1`, `\k<name>` | ⚠️ runtime-only, step-budgeted; unset group matches empty string |
| Compile flags | `.case_insensitive`, `.dot_all`, `.extended`, `.multiline` | ✅ peers of `(?i)`/`(?s)`/`(?x)`/`(?m)` |
| Compile flags | `.unicode` (codepoint mode) | ❌ `NotImplemented`⁵ |
| Escaping | `\\`, `\.`, `\n`, `\t`, `\r` | ✅ |

> **¹ Possessive quantifiers** (`*+`/`++`/`?+`/`{m,n}+`) are **rejected** with
> `error.NotImplemented` rather than silently treated as greedy — silent greedy
> would give wrong results versus an atomic-aware engine (e.g. `a*+a` must not
> match `"aaa"`). True possessive/atomic semantics may be added later; rejecting
> now keeps that addition non-breaking.
>
> **² Unicode `\p`** currently covers **General_Category** for codepoints in the
> Latin-1 range (bytes `0x00`–`0xFF`): one/two-letter categories (`L`, `Lu`,
> `Ll`, `N`, `Nd`, …), the `\pL` shorthand, negation (`\P{…}`, `\p{^…}`, or an
> enclosing `[^…]`), and `\p` inside a `[…]` class. Scripts, script extensions,
> binary properties, unknown names, and `\p` under `(?i)` are rejected with
> `error.NotImplemented`.
>
> **⁵ Byte-oriented matching is a stable, reserved contract.** Zeetah is
> **byte-oriented** end-to-end — the DFA runs over a 256-symbol (byte) alphabet
> and no matcher decodes UTF-8 — so `.` matches one byte, `\d`/`\w`/`\b` are
> ASCII, and `\p` resolves to the Latin-1 byte restriction of the property
> (exactly Rust/RE2 with Unicode-mode *off*). **This byte default is the
> committed semantics and will not change.** Codepoint-aware Unicode is
> **reserved** behind the `.unicode` flag / inline `(?u)`: both currently return
> `error.NotImplemented`, and when implemented they will *add* codepoint mode
> (multibyte `\p`, scripts, binary properties, codepoint-granular
> `.`/`\d`/`\w`/`\b`, `(?i)\p{…}` folding) **only when opted in** — never
> altering the byte-mode default. So a future Unicode phase is an additive,
> non-breaking change, not a silent semantics shift. Tracked, not scheduled.
>
> **³ Look-assertions** (`\b`, `\B`, mid-pattern `^`/`$`, lookahead, lookbehind)
> run on the bounded backtracker and are **runtime-only** — the compile-time
> [`Pattern`](#compile-time-patterns) path rejects them with a `@compileError`.
>
> **⁴ Captures.** `find` / `isMatch` / `findAll` return the correct whole-match
> span but leave `groups` empty. Use [`captures`](#capture-groups) to extract
> submatch slices (it allocates; the returned `Match` must be `deinit`-ed).

### What `compile` returns on rejection

The matcher surfaces a few distinct, typed errors so a caller handling untrusted
patterns can tell them apart:

- **`error.InvalidPattern`** — malformed syntax (`abc(`, `*abc`, `a{3,2}`, a
  duplicate group name, a bad back-reference). "This regex is broken."
- **`error.NotImplemented`** — a well-formed but not-yet-supported feature (the
  `.unicode` flag, `\p` scripts, an unknown POSIX class, counts > 1000…).
  "Valid regex, unsupported here."
- **`error.PatternTooComplex`** — a construction ceiling overflowed at compile
  time (too large to build).
- **`error.EmptyPattern`** — the pattern was `""`.

At *match* time, a backtracking pattern (backref / lookaround) can additionally
return **`error.MatchBudgetExceeded`** when its per-haystack step budget is hit
— distinct from the compile-time `PatternTooComplex`. The full set lives in
`RegexError` (`zeetah.RegexError`).

## Compile-time patterns

For a pattern known at compile time, **`Pattern`** runs the entire
parse → NFA → DFA (+minimize) pipeline at compile time and bakes the matcher
into the binary. The result is a **type** with **static** methods — no instance,
no allocator, no `deinit`:

```zig
const zeetah = @import("zeetah");

// Pure-literal patterns bake a comptime Teddy scan (no DFA table);
// everything else bakes a minimized DFA into .rodata.
const Phone = zeetah.Pattern("[0-9]{3}-[0-9]{4}", .{});

test "allocation-free comptime match" {
    try std.testing.expect(Phone.isMatch("call 555-1234"));
    if (Phone.find("call 555-1234")) |m| {        // ?Match, no error union
        try std.testing.expectEqualStrings("555-1234", m.slice);
    }
    try std.testing.expectEqual(@as(usize, 1), Phone.count("call 555-1234"));
}
```

`isMatch` / `find` / `count` are fully allocation-free; only `findAll(allocator, …)`
allocates (just the result slice). Options (`zeetah.PatternOptions`):

```zig
pub const Options = struct {
    max_dfa_states: usize = 256,                                  // soft budget; bounded by an internal ceiling
    on_oversize: enum { compile_error, allow_oversized } = .compile_error, // over-budget (but representable) DFA
    case_insensitive: bool = false,
};
```

The comptime path is **capture-free** and supports only the regular,
DFA-representable subset. Captures-with-submatches, lookaround, backreferences,
and look-assertions are a **hard `@compileError`** — there is **no runtime
fallback** baked into a `Pattern`. For those, use the runtime `Regex`.

## Builder & ready-made patterns

`Builder` assembles a pattern string fluently; `Patterns` is a collection of
ready-made pattern **strings** you then compile:

```zig
const zeetah = @import("zeetah");

// Builder: each step returns !*Builder; init() does NOT return an error union.
var b = zeetah.Builder.init(allocator);
defer b.deinit();
_ = try b.literal("id-"); // metacharacters escaped
_ = try b.digit();
_ = try b.repeatExact(3); // pattern so far: id\-\d{3}

var re = try b.compile(); // build the string internally + compile
defer re.deinit();

// Or get the raw pattern string (caller owns it):
// const pattern = try b.build();
// defer allocator.free(pattern);
```

```zig
// Patterns.* return an allocator-owned pattern STRING, not a Regex:
const pat = try zeetah.Patterns.email(allocator);
defer allocator.free(pat);

var email_re = try zeetah.Regex.compile(allocator, pat);
defer email_re.deinit();
```

Available ready-made patterns: `email`, `url`, `ipv4`, `phoneUS`, `dateISO`,
`time24`, `hexColor`, `creditCard`, `uuid`, `integer`, `decimal`, `identifier`.
They are convenience defaults (e.g. `creditCard` has no Luhn check), not strict
validators.

## Memory & lifetime

A `Match` is a **borrowed view**, not an owned copy:

- `match.slice` (and every `Group.slice`) aliases the original `input` — valid
  only while that input *and* the source `Regex` are alive; nothing is copied.
- For `find` / `findAll` / `iterator.next` results, `match.groups` is an empty,
  non-owned slice, so `match.deinit(allocator)` is a **no-op** (calling it is
  harmless).
- For a **`captures`** result, `match.groups` is allocator-owned, so
  `defer match.deinit(allocator)` is **required** to avoid a leak.
- `findAll` returns an allocator-owned `[]Match`; free the slice with
  `allocator.free`. `split` returns an allocator-owned `[][]const u8` whose
  element slices alias the input.

## Public API

The package exports a small, stable surface from `@import("zeetah")`:

`Regex` · `CompileFlags` · `Match` · `Group` · `MatchIterator` · `CapturesIterator` · `RegexError` · `Pattern` · `PatternOptions` · `Builder` · `Patterns` · `version`

`Regex` methods: `compile`, `compileWithFlags`, `isMatch`, `find`, `findFrom`,
`captures`, `capturesFrom`, `capturesAll`, `capturesIterator`, `findAll`,
`count`, `replace`, `replaceAll`, `replaceLiteral`, `replaceAllLiteral`,
`split`, `iterator`, `deinit`.

Engine internals (parser, planner, NFA/DFA construction, executors, prefilters,
profiling) are deliberately **not** exported and carry no stability guarantee.

## CLI

A small command-line front-end lives in [`src/main.zig`](src/main.zig). It is
**not part of the default build** (only the library module and the parity
harness are built); to use it, add it to your `build.zig` as an executable that
imports the `zeetah` module. Once built, it supports:

```bash
zeetah '\d+' 'hello 123 world'        # first match            -> 123
zeetah -g '\d+' 'a 1 b 2'             # -g: all matches        -> 1\n2
zeetah -i 'hello' 'HELLO world'       # -i: case-insensitive
zeetah -r '#' '\d+' 'a 1 b 2'         # -r <repl>: replace     -> a # b #
echo 'a 1 b 2' | zeetah '\d+'         # input from stdin
zeetah -v                             # version  (-h for help)
```

(The `-m`/multiline flag makes `^`/`$` match at line boundaries, via the
`.multiline` compile flag — equivalent to a leading inline `(?m)`.)

## Building

```bash
zig build          # build the library module + parity harness (zig-out/bin/parity_harness)
zig build test     # run the full unit + feature/security test suite
zig build parity   # run the meta-engine smoke harness
```

## Documentation

- [API Reference](docs/API.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Examples](docs/EXAMPLES.md)
- [Advanced Features](docs/ADVANCED_FEATURES.md)
- [Performance Guide](docs/BENCHMARKS.md)

## Requirements

- Zig 0.16 or later
- No external dependencies

## Acknowledgments

Zeetah stands on the shoulders of earlier Zig regex work, and credits the
foundational ideas it builds on:

- **[zig-regex](https://github.com/tiehuis/zig-regex)** by Jimmi Holst
  Christensen (tiehuis) — the original regular-expression library for Zig
  (Thompson NFA / Pike VM). It established the approach Zeetah's core engine
  started from.
- **[mvzr](https://github.com/mnemnion/mvzr)** by mnemnion — a minimal,
  comptime-friendly Zig regex. It inspired Zeetah's allocation-free,
  compile-time [`Pattern`](#compile-time-patterns) path, and is one of the
  engines in Zeetah's benchmark comparison suite.
- **Ken Thompson's** NFA construction algorithm, **RE2** (Google), and **Rust's
  `regex` crate** — for the finite-automaton / linear-time-by-construction
  philosophy and the literal/prefilter routing that the meta engine generalizes.

## License

MIT — see [LICENSE](LICENSE).

## Support

- [GitHub Issues](https://github.com/zig-utils/zig-regex/issues)
