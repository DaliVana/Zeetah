# Advanced Features

This guide covers the parts of **Zeetah** beyond the everyday
`compile` → `find` loop: opt-in capture extraction, inline-flag scoping, the
fluent string-construction API (`Builder` / `Patterns`), the compile-time
`Pattern` type, the meta engine's routing and prefilters, and the ReDoS
step-budget contract.

Everything here uses the public surface exported from `@import("zeetah")`. The
engine internals — parser, planner, NFA/DFA construction, executors,
prefilters — are **deliberately not exported** and carry no stability
guarantee; the topics below describe how they *behave*, not an API you import.

> The supported public surface is `Regex`, `Match`, `Group`, `MatchIterator`,
> `RegexError`, `Pattern`, `PatternOptions`, `Builder`, `Patterns`, and
> `version`. See [API.md](API.md) for the full reference and
> [README.md](../README.md) for a quick start.

## Table of Contents

- [Opt-in captures](#opt-in-captures)
- [Inline flags: scoping & toggling](#inline-flags-scoping--toggling)
- [Building patterns: Builder & Patterns](#building-patterns-builder--patterns)
- [Compile-time patterns: `Pattern`](#compile-time-patterns-pattern)
- [The meta engine, briefly](#the-meta-engine-briefly)
- [The ReDoS step-budget contract](#the-redos-step-budget-contract)
- [Unicode `\p` scope](#unicode-p-scope)
- [Prefilters & performance machinery](#prefilters--performance-machinery)
- [No C ABI, no prebuilt WASM module](#no-c-abi-no-prebuilt-wasm-module)

## Opt-in captures

Zeetah's fast paths are **capture-free**. `find`, `isMatch`, and `findAll`
always report the correct whole-match span, but they never reconstruct
submatch slices — the returned `Match` has `groups.len == 0` even when the
pattern contains groups. This is what keeps the DFA path allocation-free.

When you actually need submatches, opt in with **`captures`**. It is the only
matching method that takes an allocator and produces an owned `groups` slice:

```zig
const std = @import("std");
const zeetah = @import("zeetah");

var re = try zeetah.Regex.compile(allocator, "(?<year>\\d{4})-(\\d{2})-(\\d{2})");
defer re.deinit();

if (try re.captures(allocator, "Date: 2024-03-15")) |m| {
    var mm = m;
    defer mm.deinit(allocator); // REQUIRED for captures results — frees groups

    // groups[0] is the WHOLE match; capture N is groups[N].
    std.debug.print("{s}\n", .{mm.slice});             // 2024-03-15 (== groups[0].slice)
    std.debug.print("{s}\n", .{mm.groups[1].?.slice}); // 2024
    std.debug.print("{s}\n", .{mm.groups[2].?.slice}); // 03
    std.debug.print("{s}\n", .{mm.groups[3].?.slice}); // 15
}
```

### Named groups & `groupByName`

Both `(?<name>…)` and the Python-style `(?P<name>…)` syntaxes are accepted.
After `captures`, look a group up by name instead of by index:

```zig
if (try re.captures(allocator, "Date: 2024-03-15")) |m| {
    var mm = m;
    defer mm.deinit(allocator);

    if (mm.groupByName("year")) |g| {
        std.debug.print("year = {s} @ [{d}..{d})\n", .{ g.slice, g.start, g.end });
    }
}
```

A duplicate group name is rejected at compile time with
`error.NotImplemented`.

### Optional & non-participating groups

`groups` is a `[]const ?Group`. A group that exists in the pattern but did not
participate in this particular match is a `null` slot — always check before
dereferencing:

```zig
var re = try zeetah.Regex.compile(allocator, "(a)|(b)");
defer re.deinit();

if (try re.captures(allocator, "b")) |m| {
    var mm = m;
    defer mm.deinit(allocator);
    std.debug.assert(mm.groups[1] == null); // (a) did not participate
    std.debug.assert(mm.groups[2] != null); // (b) did
}
```

### Lifetime & `deinit`

A `Match` is a **borrowed view**: `match.slice` and every `Group.slice` alias
the original `input`, valid only while that input and the source `Regex` stay
alive. Nothing is copied.

The ownership rule for `deinit` is simple and uniform:

- `Match.deinit(allocator)` frees `groups` **only** when it is non-empty
  (ownership is implicit in `groups.len`; there is no public flag).
- A `captures` result is the only one with a non-empty `groups`, so
  `defer m.deinit(allocator)` is **required** there.
- `find` / `findAll` / `iterator.next` results are groups-empty and not owned,
  so calling `deinit` on them is a harmless no-op.

`Group` carries `slice`, `start`, `end`, an optional `name`, and a `len()`
helper. Groups inside a lookaround are not reconstructed.

## Inline flags: scoping & toggling

Inline flags are the most flexible way to set matching modes, and the
recommended route when you want a mode to apply to only part of a pattern.
Four flags are honored: `(?i)` (ASCII case-insensitive), `(?s)` (dot-all —
`.` also matches `\n`), `(?x)` (extended / verbose), and `(?m)` (multiline —
`^`/`$` match at line boundaries).

Each flag works in two forms:

- **Toggle** — `(?i)` turns the mode on for the rest of the enclosing group.
- **Scoped** — `(?i:…)` turns the mode on only inside the parentheses.

```zig
// Scoped: only "HELLO" is matched case-insensitively; "World" is literal.
var re = try zeetah.Regex.compile(allocator, "(?i:hello) World");
defer re.deinit();
_ = try re.isMatch("HELLO World"); // true
_ = try re.isMatch("HELLO world"); // false — "World" is case-sensitive

// Toggle: everything after (?s) sees `.` as matching newlines.
var re2 = try zeetah.Regex.compile(allocator, "before(?s).*after");
defer re2.deinit();
```

The `CompileFlags` passed to `compileWithFlags` are exact peers of the inline
forms: `.case_insensitive` ≡ leading `(?i)`, `.dot_all` ≡ `(?s)`, `.extended`
≡ `(?x)`, and **`.multiline` ≡ a leading `(?m)`** (multiline is fully
supported as a compile flag — it routes `^`/`$` to line anchors):

```zig
var re = try zeetah.Regex.compileWithFlags(allocator, "^item", .{
    .case_insensitive = true,
    .multiline = true, // ^ matches at the start of every line
});
defer re.deinit();
```

The only rejected flag is `.unicode` (codepoint-aware mode), which returns
`error.NotImplemented`; there is no `(?u)` inline equivalent yet either.

## Building patterns: Builder & Patterns

`Builder`, `Patterns`, and the `Composer` helper all produce **pattern
strings**. Nothing matches until you compile the resulting string. This makes
them safe to combine, log, and store.

### Builder — fluent construction

`Builder.init(allocator)` returns a builder **by value** (no `try`). Each
fluent method returns `!*Builder`, so every link in a chain needs `try`; the
practical idiom is one `_ = try b.method();` per step:

```zig
const zeetah = @import("zeetah");

var b = zeetah.Builder.init(allocator);
defer b.deinit(); // frees the accumulated fragments

_ = try b.startOfLine();
_ = try b.digit();
_ = try b.repeatExact(3);
_ = try b.literal("-");      // metacharacters in the literal are escaped
_ = try b.digit();
_ = try b.repeatExact(4);
_ = try b.endOfLine();        // pattern so far: ^\d{3}\-\d{4}$

var re = try b.compile();     // builds the string internally + Regex.compile
defer re.deinit();

_ = try re.isMatch("555-1234"); // true
```

There are two terminals:

- `build()` returns the assembled pattern **string** (`![]const u8`); the
  caller **owns** it and must `allocator.free` it.
- `compile()` builds the string internally and returns a compiled `Regex`; the
  caller `deinit`s the `Regex`.

```zig
// Get the raw string instead of compiling:
const pattern = try b.build();
defer allocator.free(pattern);
std.debug.print("{s}\n", .{pattern});
```

#### Builder method reference

```zig
// Literals & character classes
.literal("text")        // escaped literal text (metachars escaped, except ] and })
.any()                  // .   any character
.digit()                // \d
.word()                 // \w
.whitespace()           // \s
.charClass("abc")       // [abc]   (chars inserted raw, unescaped)
.notCharClass("abc")    // [^abc]
.charRange('a', 'z')    // [a-z]

// Quantifiers (greedy)
.oneOrMore()            // +
.zeroOrMore()           // *
.optional()             // ?
.repeatExact(n)         // {n}
.repeatAtLeast(n)       // {n,}
.repeatRange(min, max)  // {min,max}

// Anchors & boundaries
.startOfLine()          // ^
.endOfLine()            // $
.wordBoundary()         // \b

// Groups & alternation
.startGroup()           // (
.endGroup()             // )           (closes capturing AND non-capturing groups)
.startNonCapturingGroup() // (?:
.or_()                  // |           (trailing underscore: `or` is a keyword)
```

> Note the asymmetry between `literal` (escapes regex metacharacters so the
> text is taken verbatim) and `charClass` / `notCharClass` (insert their
> argument **raw**, so you can pass class syntax like `a-z0-9`).

### Patterns — ready-made pattern strings

`Patterns` is a namespace of twelve factory functions. **Each returns an
allocator-owned pattern string** (`![]const u8`), *not* a `Regex` — you free
the string and compile it yourself:

```zig
const zeetah = @import("zeetah");

const pat = try zeetah.Patterns.email(allocator);
defer allocator.free(pat);

var email_re = try zeetah.Regex.compile(allocator, pat);
defer email_re.deinit();
_ = try email_re.isMatch("user@example.com"); // true
```

Available factories: `email`, `url`, `ipv4`, `phoneUS`, `dateISO`, `time24`,
`hexColor`, `creditCard`, `uuid`, `integer`, `decimal`, `identifier`. They are
**convenient approximations**, not strict validators — for example
`creditCard` matches the 4×4 digit shape but performs no Luhn check, and
`dateISO` matches `YYYY-MM-DD` without rejecting impossible calendar dates.

### Composer — combining strings

A `Composer` (also in the builder module) glues pattern strings together. It
exposes `add`, then `alternatives` (join with `|`), `sequence` (concatenate),
and `group` (concatenate and wrap in `(…)`), each returning an owned string.

```zig
// `Composer` lives in the builder source but is NOT exported from the
// package root, so it is reachable only when vendoring the source. Public
// callers can reproduce its behavior with Builder.or_/startGroup, or with
// plain string concatenation, before compiling.
```

> All three helpers stop at producing strings — you always finish by calling
> `Regex.compile` (or feeding the string into a comptime `Pattern`).

## Compile-time patterns: `Pattern`

For a pattern that is known at compile time, **`Pattern`** runs the *entire*
parse → HIR → NFA → DFA (+minimize) pipeline at **compile time** and bakes the
matcher into `.rodata`. Pure-literal patterns skip the DFA table and bake a
comptime Teddy scan instead. The result is a **type with static methods** — no
instance, no allocator, no `deinit`:

```zig
const zeetah = @import("zeetah");

const Phone = zeetah.Pattern("[0-9]{3}-[0-9]{4}", .{});

test "allocation-free comptime match" {
    try std.testing.expect(Phone.isMatch("call 555-1234"));

    if (Phone.find("call 555-1234")) |m| { // ?Match — NO error union
        try std.testing.expectEqualStrings("555-1234", m.slice);
    }

    try std.testing.expectEqual(@as(usize, 1), Phone.count("call 555-1234"));
}
```

### Static method surface

| Method | Signature | Allocates? |
|--------|-----------|------------|
| `isMatch` | `isMatch(input) bool` | no |
| `find` | `find(input) ?Match` (no error union) | no |
| `count` | `count(input) usize` | no |
| `findAll` | `findAll(allocator, input) ![]Match` | the result slice only |

The comptime `Pattern` path is **capture-free** — it has no `captures` method
(submatch extraction is a hard `@compileError`). Use the runtime `Regex.captures`
for groups.

`Pattern` also exposes `pub const has_dfa = true`.

### `PatternOptions`

```zig
pub const Options = struct {
    max_dfa_states: usize = 256,
    on_oversize: enum { compile_error, allow_oversized } = .compile_error,
    case_insensitive: bool = false,
};
```

- **`max_dfa_states`** — the soft DFA-state budget for this pattern. It is
  bounded by an internal `MAX_DFA = 256` ceiling and **does not raise it**; you
  can only request a smaller budget.
- **`on_oversize`** — what happens when the minimized DFA builds successfully
  but exceeds `max_dfa_states`. `.compile_error` (the default) fails the build
  with a `@compileError`; `.allow_oversized` **bakes the larger table anyway**
  (still bounded by the internal ceiling). Neither value rescues a pattern that
  blows the internal ceiling or uses an unsupported feature — those always
  `@compileError` (there is no comptime → runtime fallback; use the runtime
  `Regex.compile`).
- **`case_insensitive`** — ASCII case folding, equivalent to a leading `(?i)`.

```zig
const Strict = zeetah.Pattern("a|b|c", .{ .case_insensitive = true });
// Bake a larger table for a big regular pattern despite a small soft budget:
const Big = zeetah.Pattern("…", .{ .max_dfa_states = 64, .on_oversize = .allow_oversized });
```

### What `Pattern` rejects at compile time

`Pattern` supports the **regular, DFA-representable subset** — including `\p`
(its resolver is allocator-free). Anything outside that subset is a **hard
`@compileError` with no runtime fallback baked in**. The rejected set:

- captures with submatch extraction;
- lookaround (`(?=…)`, `(?!…)`, `(?<=…)`, `(?<!…)`);
- backreferences (`\1`, `\k<name>`);
- look-assertions — `\b`, `\B`, mid-pattern `^`/`$`, and `(?m)` anchors;
- `\p` under `(?i)`;
- lazy combined with an end-anchor (`a*?$`), which the runtime engine routes
  to the backtracker — a path that cannot be baked at comptime;
- any pattern that exceeds the DFA-state ceiling.

For any of those, use the runtime `Regex`, which handles all of them.

## The meta engine, briefly

Zeetah is a **meta engine**: `compile` analyzes the pattern (a pure pass over
the parsed HIR) and routes it to the cheapest correct executor — a substring
scan, a SIMD multi-literal locator, a compiled DFA, or a bounded backtracker
for features no finite automaton can express. You call one API; the engine
picks the machine.

Routing has two layers. The **runtime dispatcher** chooses among roughly a
dozen executors (literal scan, literal-prefix prefilter, reverse-suffix
fast-negative, eager DFA, dense single-pass DFA, lazy DFA, single-range class
span, `\b`-keyword Aho-Corasick, look-assertion backtracker, full lookaround /
backreference backtracker, mixed-branch split, and an adjacent-duplicate-word
linear scanner). The **planner** beneath it is a *pure function* over the
pattern's properties — it never reads the haystack, which is exactly why the
comptime `Pattern` path can make the same regular-tier decision at compile
time.

For the full executor taxonomy, the planner's `Strategy` variants, and the
parse → HIR → NFA → DFA pipeline, see
[ARCHITECTURE.md](ARCHITECTURE.md) and the routing table in
[README.md](../README.md#the-meta-engine).

## The ReDoS step-budget contract

Zeetah's linear-time guarantee is precise about *which* patterns receive it:

- **Regular patterns are linear by construction.** Matching is a DFA table
  walk, O(n) per scan. If the eager DFA would exceed its state ceiling, it
  falls back to the **bit-identical lazy DFA** (the same subset construction,
  built on demand) — **never** to backtracking. Classic "catastrophic" regular
  shapes such as `(a+)+$`, `(a*)*$`, and `(.*)*$` **compile and run
  linearly**; they are *not* rejected at compile time.

```zig
// Regular "catastrophic" pattern: compiles and runs as a linear DFA.
var re = try zeetah.Regex.compile(allocator, "(a+)+$");
defer re.deinit();
_ = try re.isMatch("aaaaaaaaaaaaaaaaX"); // fast, linear — no error, no hang
```

- **Non-regular patterns** — backreferences, lookaround, and lazy combined
  with an end-anchor — run on the **tree backtracker** under an explicit
  **step budget of `8000 + (len + 1) × 4000`**, plus a recursion-depth guard
  (`MAX_DEPTH = 16384`). Exceeding either returns a typed
  **`error.MatchBudgetExceeded` at match time** — the .NET-style runtime
  contract, never a hang. (Distinct from the compile-time `PatternTooComplex`.)

```zig
// Non-regular catastrophe (inside a lookahead): bounded at MATCH time.
var re2 = try zeetah.Regex.compile(allocator, "(?=(a+)+$)a");
defer re2.deinit();

const r = re2.isMatch("aaaaaaaaaaaaaaaaaaaaaaaaX");
_ = r catch |e| switch (e) {
    error.MatchBudgetExceeded => {}, // budget exceeded -> typed error
    else => return e,
};
```

- **Construction ceilings** (NFA states 256, NFA edges 2048, DFA states 256,
  HIR nodes 4096, capture groups 32) raise `error.PatternTooComplex` at
  **compile time** for patterns too large to build.
- The bounded-backtracking **capture path** is strictly O(n·m) — it uses a
  `(state, pos)` visited bitset, so it can never go exponential.

## Unicode `\p` scope

`\p{…}`, `\P{…}`, and the `\pL` shorthand are supported as the **Latin-1 byte
restriction of General_Category** — codepoints `0x00`–`0xFF` only. This
matches Rust/RE2 behavior with Unicode mode *off*, and is a direct consequence
of Zeetah being byte-oriented end-to-end (the DFA runs over a 256-symbol byte
alphabet; no matcher decodes UTF-8).

What works:

- one- and two-letter categories — `L`, `Lu`, `Ll`, `N`, `Nd`, … ;
- the `\pL` shorthand;
- negation via `\P{…}`, `\p{^…}`, or an enclosing `[^…]`;
- `\p` **inside** a character class (`[\p{L}0-9]`).

```zig
var re = try zeetah.Regex.compile(allocator, "\\p{L}+");
defer re.deinit();
_ = try re.isMatch("héllo"); // matches the Latin-1 letters
```

Rejected with `error.NotImplemented`:

- scripts (`\p{Greek}`) and script extensions;
- binary properties (`\p{White_Space}`);
- unknown property names;
- `\p` under `(?i)` (Unicode case folding is not implemented).

A full codepoint-aware mode — multibyte `\p`, scripts, binary properties,
codepoint-granular `.`/`\d`/`\w`/`\b`, and Unicode case folding — is the
documented `(?u)` follow-on and is **not yet implemented**. Until then the
`.unicode` compile flag returns `error.NotImplemented`.

## Prefilters & performance machinery

Before (or instead of) running an automaton, the meta engine tries to skip
work with a prefilter. These are internal — you do not configure them — but
knowing they exist explains why some patterns are dramatically faster than a
naïve scan:

- **Required byte** — a single byte that every accepting path must consume. If
  one `memchr` finds none in the haystack, the answer is "no match" in a single
  pass.
- **Required literal anywhere** — a rare mandatory literal plus a recipe to
  recover the match start; drives a `memchr` instead of a broad restart loop.
- **First-byte SIMD set** — a 256-bit start-byte set scanned with `@Vector`,
  specialized to single-byte / multi-equality / range / bitset shapes.
- **Teddy** — a SIMD multi-substring locator (≤ 8 needles, adaptive nibble
  masks) backing the literal, literal-prefix, and reverse-suffix executors.
- **Aho-Corasick** — a multi-keyword locator backing the `\b`-delimited
  keyword-alternation executor.
- **Seek** — a regular over-approximation that skips proven-dead prefixes for
  the backtracking tier.

To get the most out of them in practice:

- Prefer a **distinctive required literal or prefix** in your pattern — it
  hands the engine a fast negative.
- **Anchor** when you can (`^…`, `…$`): anchored patterns avoid scanning the
  whole haystack for a start position.
- A single contiguous **character-class run** (`[a-z]+`) takes a SIMD
  member-run scan with no automaton at all.
- For a pattern compiled once and matched many times, reach for the
  **compile-time [`Pattern`](#compile-time-patterns-pattern)** so the whole
  build happens at compile time and matching is allocation-free.

## No C ABI, no prebuilt WASM module

Zeetah is a **pure-Zig library**. There is **no C ABI** (no `zeetah_compile`,
no `ZeetahRegex` / `ZeetahMatch` types, no error enum, no shared object) and
**no prebuilt WebAssembly module**. Any documentation describing those is
describing something that does not exist in this codebase — they have been
removed from this guide.

To use Zeetah from WebAssembly, compile your own Zig program that
`@import`s `zeetah` to a `wasm32` target, or write a small Zig export shim that
exposes the calls you need. There is no provided C or WASM surface to link
against.

The internal engine modules (parser, planner, NFA/DFA builders, executors,
prefilters) are likewise **not exported** from the package root and carry no
stability guarantee — depend only on the ten names listed at the top of this
document.
