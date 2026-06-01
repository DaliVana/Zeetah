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
- **Compile-time patterns** — for a comptime-known pattern, the whole pipeline
  runs at compile time and bakes the matcher into `.rodata`: no allocator, no
  runtime compilation. Covers the **full feature surface** — a minimized DFA for
  regular patterns, the same bounded backtracker (with captures) for non-regular
  ones. See [`Pattern`](#compile-time-patterns).
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
git clone https://github.com/DaliVana/Zeetah.git
cd Zeetah
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

"Meta engine" means Zeetah has no *single* matcher: at `compile` time it analyzes
the pattern (a pure pass over the parsed HIR) and routes it to the cheapest
correct executor — a SIMD literal scan, a compiled DFA, or a bounded backtracker
for features no finite automaton can express. You call one API; the engine picks
the machine.

Routing happens in two layers: a runtime dispatcher that selects one of ~12
executors (literal / Teddy-prefix / eager- and lazy-DFA / class-span / keyword
Aho-Corasick / backtracker / …), driven by a **pure planner** `plan(properties,
flags)` that never reads the haystack — so for a comptime-known pattern the
routing decision runs entirely at compile time. A handful of prefilters (required
byte, first-byte SIMD set, Teddy, Aho-Corasick, seek) skip work before any
automaton runs.

The **ReDoS contract** is precise about which patterns get linear time:

- **Regular patterns are linear by construction** — a DFA table walk, O(n) per
  scan. Classic "catastrophic" shapes (`(a+)+$`, `(a*)*$`, `(.*)*$`) compile and
  run linearly; they are *not* rejected. If the eager DFA explodes it falls back
  to a bit-identical lazy DFA, never to backtracking.
- **Non-regular patterns** (backreferences, lookaround, atomic groups,
  lazy-with-end-anchor) run on a step-budgeted backtracker and return a typed
  **`error.MatchBudgetExceeded`** at match time — never a hang.
- **Construction ceilings** raise **`error.PatternTooComplex`** at compile time
  for patterns too large to build.

Full details — the executor table, the planner, the prefilters, and the
compile-time path — live in **[Architecture](docs/ARCHITECTURE.md)**.

## Feature support

| Feature | Syntax | Status |
|---------|--------|--------|
| Literals | `abc`, `123` | ✅ |
| Quantifiers | `*`, `+`, `?`, `{n}`, `{m,n}` | ✅ counts > 1000 → `NotImplemented`; very large in-budget counts → `PatternTooComplex` |
| Lazy quantifiers | `*?`, `+?`, `??`, `{m,n}?` | ✅ lazy **+ end-anchor** (`a*?$`) runs on the backtracker (match-budget bounded) |
| Possessive quantifiers | `*+`, `++`, `?+`, `{m,n}+` | ✅ lower to atomic groups; run on the backtracker (match-budget bounded)¹ |
| Alternation | `a\|b\|c` | ✅ |
| Predefined classes | `\d \w \s \D \W \S` | ✅ (including inside `[…]`) |
| Custom classes | `[abc]`, `[a-z]`, `[^0-9]`, `[[:alpha:]]` | ✅ unknown POSIX name → `NotImplemented` |
| Unicode properties | `\p{L}`, `\P{Nd}`, `\pL`, `[^\p{L}]` | ⚠️ **General_Category, Latin-1 bytes only**²; scripts/binary props/`\p` under `(?i)`/multibyte codepoints → `NotImplemented`⁵ |
| Inline flags | `(?i)`, `(?s)`, `(?x)`, `(?m)` and scoped `(?i:…)` | ✅ |
| Anchors | `^`, `$`, `\A`, `\z`, `\Z`, `\b`, `\B` | ✅ work at runtime **and** comptime³ |
| Wildcard | `.` | ✅ excludes `\n` unless `(?s)` |
| Capturing groups | `(...)` | ✅ slices via opt-in `captures()`⁴ |
| Named groups | `(?<name>...)`, `(?P<name>...)` | ✅ duplicate name → `InvalidPattern` |
| Non-capturing | `(?:...)` | ✅ |
| Lookahead | `(?=...)`, `(?!...)` | ✅ step-budgeted; runtime **and** comptime³ |
| Lookbehind | `(?<=...)`, `(?<!...)` | ⚠️ **fixed-width only**; variable-width → `MatchBudgetExceeded` at match |
| Backreferences | `\1`, `\k<name>` | ✅ step-budgeted; runtime **and** comptime; unset group matches empty string |
| Compile flags | `.case_insensitive`, `.dot_all`, `.extended`, `.multiline` | ✅ peers of `(?i)`/`(?s)`/`(?x)`/`(?m)` |
| Compile flags | `.unicode` (codepoint mode) | ❌ `NotImplemented`⁵ |
| Escaping | `\\`, `\.`, `\n`, `\t`, `\r` | ✅ |

> **¹ Possessive quantifiers** (`*+`/`++`/`?+`/`{m,n}+`) lower to **atomic
> groups** (`a*+` ≡ `(?>a*)`) with true atomic semantics — they commit and never
> give back, so `a*+a` does **not** match `"aaa"`. Like the other non-regular
> constructs they run on the bounded backtracker (match-budget bounded), not a
> DFA — at runtime **and** at comptime, where [`Pattern`](#compile-time-patterns)
> bakes that backtracker into `.rodata` (see that section).
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
> run on the bounded backtracker — at runtime **and** under the compile-time
> [`Pattern`](#compile-time-patterns), which bakes the same backtracker (and its
> seek prefilters) into `.rodata`. (Leading `^`/`\A` and trailing `$`/`\z` are not
> look-assertions at all — the prescan folds them into the anchored DFA fast path.)
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
// regular patterns bake a minimized DFA into .rodata; non-regular patterns
// (below) bake the tree-backtracker + its seek prefilters into .rodata.
const Phone = zeetah.Pattern("[0-9]{3}-[0-9]{4}", .{});

test "allocation-free comptime match" {
    try std.testing.expect(Phone.isMatch("call 555-1234"));
    if (Phone.find("call 555-1234")) |m| {        // ?Match, no error union
        try std.testing.expectEqualStrings("555-1234", m.slice);
    }
    try std.testing.expectEqual(@as(usize, 1), Phone.count("call 555-1234"));
}

// `find` returns the WHOLE match (`Match`); `captures` returns the SUBMATCHES
// (`Captures`). On the comptime path `captures` is **zero-allocation** — the
// group count + names are known at compile time, so groups live inline. `get(i)`
// is compile-time-indexed (a bad index is a compile error, not a runtime null);
// `getName` resolves the (?<name>) at compile time. Regular patterns (DFA arm) too.
const Date = zeetah.Pattern("(?<y>[0-9]{4})-([0-9]{2})-([0-9]{2})", .{});

test "zero-alloc comptime captures" {
    if (Date.captures("ts 2026-06-01!")) |c| {        // ?Captures — NO allocator
        try std.testing.expectEqualStrings("2026-06-01", c.slice());  // whole match
        try std.testing.expectEqualStrings("2026", c.get(1).?.slice);  // by index
        try std.testing.expectEqualStrings("2026", c.getName("y").?.slice); // by name
    }
}

// Non-regular features work at comptime too — backreferences, lookaround,
// atomic/possessive, word boundaries, (?m) line anchors. These bake the
// bounded backtracker into .rodata (no DFA); `captures` is still zero-alloc.
const Dup = zeetah.Pattern("(\\w+) \\1", .{});            // backreference

test "lazy, allocation-free verbs" {
    // iterator / splitIterator are lazy values — O(1) memory, free early-break:
    var it = zeetah.Pattern("[0-9]+", .{}).iterator("a12 b345 c6");
    while (it.next()) |m| { _ = m; }                  // no allocator, no slice

    try std.testing.expect(zeetah.Pattern("v[0-9]+", .{}).startsWith("v2.0"));
    _ = Dup; // (Dup used above)
}
```

**The mental model:** `find` → `Match` (the whole match); `captures` → `Captures`
(the submatches). On the comptime `Pattern`, **everything that returns one match is
allocation-free** — `isMatch` / `find` / `count` / `captures` (inline `Captures`) /
`iterator` / `capturesIterator` / `splitIterator` / `startsWith`. Only the **eager,
return-a-slice** verbs take an allocator: `findAll` → `[]Match`, `capturesAll` →
`[]Captures` (one slice; the per-match groups are still inline — no per-match heap,
unlike the runtime `Regex`). Options (`zeetah.PatternOptions`):

```zig
pub const Options = struct {
    max_dfa_states: usize = 256,                                  // soft budget; bounded by an internal ceiling
    on_oversize: enum { compile_error, allow_oversized } = .compile_error, // over-budget (but representable) DFA
    case_insensitive: bool = false,                              // peer of (?i)
    multiline: bool = false,                                     // peer of (?m): ^/$ match at line boundaries
};
```

**The comptime path now matches the runtime engine's full feature surface** — the
same `parser → HIR` front end feeds both. A regular pattern bakes a minimized DFA;
a non-regular one (backreference, lookaround, atomic group, possessive quantifier,
word boundary, `(?m)` line anchor, lazy-with-end-anchor) bakes the same bounded
tree-backtracker the runtime uses, with capture extraction (`captures` /
`capturesAll`, numbered **and** `(?<name>)` named) and the seek/over-approximation
prefilters, all into `.rodata`. There is **no runtime fallback** inside a `Pattern`,
so the few constructs that are genuinely unsupported anywhere in the engine (the
`.unicode` flag, `\p` scripts, an unknown POSIX class) are a **`@compileError`**
rather than a runtime `error.NotImplemented` — use the runtime `Regex` if you need
the error to be recoverable. The match-budget (ReDoS) bound applies identically;
since the comptime API is non-erroring, a budget exceedance surfaces as "no match"
rather than `error.MatchBudgetExceeded`.

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

- [GitHub Issues](https://github.com/DaliVana/Zeetah/issues)
