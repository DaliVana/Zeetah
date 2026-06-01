# Usage Examples

Practical, compile-correct examples for **Zeetah**, a regular-expression *meta
engine* for Zig. Every snippet uses only the current public API
(`@import("zeetah")`, primary type `Regex`).

For the conceptual overview and the full feature matrix see the
[README](../README.md); for the type-by-type reference see the
[API Reference](API.md).

## Table of Contents

- [Setup](#setup)
- [Basic Matching](#basic-matching) — `find`, `isMatch`
- [Finding Many Matches](#finding-many-matches) — `findAll`, `iterator`, `count`
- [Replacing Text](#replacing-text) — `replace`, `replaceAll` ($-templates)
- [Splitting](#splitting) — `split`
- [Capture Groups](#capture-groups) — `captures`, `capturesAll`, `capturesIterator`, `groupByName`
- [Compile Flags](#compile-flags) — `compileWithFlags` and inline `(?i)`/`(?s)`/`(?x)`/`(?m)`
- [Compile-Time Patterns](#compile-time-patterns) — `Pattern`
- [Builder](#builder) — fluent pattern construction
- [Ready-Made Patterns](#ready-made-patterns) — `Patterns.*`
- [Worked Examples](#worked-examples)
- [Memory & Lifetime Rules](#memory--lifetime-rules)

---

## Setup

Zeetah is imported as a module and exposes the type `Regex`:

```zig
const std = @import("std");
const zeetah = @import("zeetah");
const Regex = zeetah.Regex;
```

A compiled `Regex` owns heap state, so it must be released with `deinit`. The
input you match against is *never copied* — a `Match.slice` (and every
`Group.slice`) borrows from the original input, so keep the input alive while
you use the results.

```zig
var re = try Regex.compile(allocator, "\\d+");
defer re.deinit();
```

> `Regex.compile` returns typed errors you can tell apart: `error.EmptyPattern`
> for `""`, **`error.InvalidPattern`** for malformed syntax (`abc(`, `a{3,2}`, a
> duplicate group name), `error.NotImplemented` for a valid-but-unsupported
> feature, and `error.PatternTooComplex` for a pattern too large to build. At
> match time, a backtracking pattern can also return `error.MatchBudgetExceeded`
> (its per-haystack step budget). See the [API reference](API.md#error-handling)
> for the full taxonomy.

---

## Basic Matching

### `find` — first match as a borrowed `?Match`

`find` returns the first (leftmost) match. The `Match` carries the matched
`slice` and its half-open byte range `[start, end)`. It is allocation-free and
its `groups` are always empty (no `deinit` needed for `find` results).

```zig
const std = @import("std");
const zeetah = @import("zeetah");
const Regex = zeetah.Regex;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var re = try Regex.compile(allocator, "\\d+");
    defer re.deinit();

    if (try re.find("Order #12345 shipped")) |m| {
        std.debug.print("matched {s} at [{d}..{d})\n", .{ m.slice, m.start, m.end });
        // matched 12345 at [7..12)
    }
}
```

> `find` takes the capture-free fast path: `m.groups.len == 0` even if the
> pattern contains groups. The whole-match span is always correct. To pull out
> submatch slices, use [`captures`](#capture-groups).

### `isMatch` — allocation-free boolean test

When you only need a yes/no answer, `isMatch` is the cheapest call (no
allocator, no `Match`).

```zig
var re = try Regex.compile(allocator, "^[a-zA-Z0-9_]{3,16}$");
defer re.deinit();

const ok = try re.isMatch("good_name");  // true
const bad = try re.isMatch("x");          // false (too short)
std.debug.print("{} {}\n", .{ ok, bad });
```

---

## Finding Many Matches

### `findAll` — every non-overlapping match in one slice

`findAll` allocates a `[]Match` that the caller owns. Each `Match` is
capture-free and owns nothing, so you free **only the outer slice**.

```zig
var re = try Regex.compile(allocator, "\\w+");
defer re.deinit();

const text = "Hello, world! This is Zeetah.";
const words = try re.findAll(allocator, text);
defer allocator.free(words); // each Match owns nothing; just free the slice

for (words, 0..) |w, i| {
    std.debug.print("word {d}: {s}\n", .{ i + 1, w.slice });
}
```

### `iterator` — lazy, no up-front slice

`iterator` yields matches one at a time without allocating a result slice. The
`allocator` argument to `next` is accepted for API parity but ignored (the
yielded `Match` is capture-free). `deinit` is a no-op but kept for symmetry.

```zig
var re = try Regex.compile(allocator, "\\d+");
defer re.deinit();

var it = re.iterator("a1 b22 c333");
defer it.deinit(); // no-op
while (try it.next(allocator)) |m| {
    std.debug.print("{s}\n", .{m.slice}); // 1, 22, 333
}
```

### `count` — allocation-free tally

```zig
var re = try Regex.compile(allocator, "\\d+");
defer re.deinit();

const n = try re.count("a1 b22 c333"); // 3
std.debug.print("{d}\n", .{n});
```

---

## Replacing Text

`replace` rewrites the **first** match; `replaceAll` rewrites **every** match.
Both return a freshly allocated `[]u8` the caller owns.

> **Templates:** the replacement is expanded against the match — `$0`/`$&` =
> whole match, `$1`..`$N` = numbered groups, `${name}` = named group, `$$` = a
> literal `$`. Unknown / non-participating refs expand to `""`; a `$` not
> starting a valid reference is emitted literally. If there is no match, the
> result is a copy of the input. For a byte-for-byte literal replacement (no
> `$`-handling), use `replaceLiteral` / `replaceAllLiteral`.

### Collapse runs of whitespace

```zig
var re = try Regex.compile(allocator, "\\s+");
defer re.deinit();

const result = try re.replaceAll(allocator, "This   has    extra   spaces", " ");
defer allocator.free(result);

std.debug.print("{s}\n", .{result}); // "This has extra spaces"
```

### Reformat with capture references

```zig
var re = try Regex.compile(allocator, "(\\w+)@(\\w+)");
defer re.deinit();

const result = try re.replaceAll(allocator, "a@b and c@d", "$2.$1");
defer allocator.free(result);

std.debug.print("{s}\n", .{result}); // "b.a and d.c"
```

### Replace only the first occurrence

```zig
var re = try Regex.compile(allocator, "cat");
defer re.deinit();

const out = try re.replace(allocator, "cat and cat", "dog");
defer allocator.free(out);

std.debug.print("{s}\n", .{out}); // "dog and cat"  (first match only)
```

### Strip characters by replacing with empty

```zig
var re = try Regex.compile(allocator, "[^a-zA-Z0-9]");
defer re.deinit();

const clean = try re.replaceAll(allocator, "Hello, World! @#$ 123", "");
defer allocator.free(clean);

std.debug.print("{s}\n", .{clean}); // "HelloWorld123"
```

---

## Splitting

`split` returns an allocator-owned `[][]const u8` of the segments between
matches of the pattern. The element slices **alias the input** (they are not
copied and not individually owned), so you free only the outer slice.

```zig
var comma = try Regex.compile(allocator, ",");
defer comma.deinit();

const fields = try comma.split(allocator, "John,Doe,30,Engineer");
defer allocator.free(fields); // element slices alias the input; do not free them

for (fields) |f| std.debug.print("[{s}]\n", .{f});
// [John] [Doe] [30] [Engineer]
```

### Boundary segments are kept; zero-width matches are skipped

If the input begins or ends with a match, the edge segment is the empty string
`""`. Matches that consume no bytes are skipped (they would otherwise produce
infinitely many empty segments).

```zig
var ws = try Regex.compile(allocator, "\\s+");
defer ws.deinit();

const parts = try ws.split(allocator, "  a  b  ");
defer allocator.free(parts);
// parts == { "", "a", "b", "" }  -- leading/trailing "" kept
```

---

## Capture Groups

`find` / `isMatch` / `findAll` take the fast path and leave `groups` empty.
To extract submatch slices you must opt in with **`captures`**, which
**allocates** the `groups` array — so the returned `Match` **must** be
`deinit`-ed.

- `groups[0]` is the **whole match** (same span as `Match.slice`).
- `groups[N]` is capture group N (1-based), or `null` if that group did not
  participate in the match.
- `groupByName(name)` looks up a named group.

```zig
const std = @import("std");
const zeetah = @import("zeetah");
const Regex = zeetah.Regex;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var re = try Regex.compile(allocator, "(?<year>\\d{4})-(\\d{2})-(\\d{2})");
    defer re.deinit();

    if (try re.captures(allocator, "Date: 2024-03-15.")) |m| {
        var mm = m;
        defer mm.deinit(allocator); // REQUIRED: frees the owned groups slice

        std.debug.print("whole: {s}\n", .{mm.slice});            // 2024-03-15
        std.debug.print("g0:    {s}\n", .{mm.groups[0].?.slice}); // 2024-03-15
        std.debug.print("year:  {s}\n", .{mm.groups[1].?.slice}); // 2024
        std.debug.print("month: {s}\n", .{mm.groups[2].?.slice}); // 03
        std.debug.print("day:   {s}\n", .{mm.groups[3].?.slice}); // 15

        if (mm.groupByName("year")) |g| {
            std.debug.print("named year: {s} [{d}..{d})\n", .{ g.slice, g.start, g.end });
        }
    }
}
```

> A group that did not participate (e.g. an optional branch that wasn't taken)
> is a `null` slot — always check before unwrapping. Named-group lookup via
> `groupByName` is only meaningful on a `captures()` result.

### Every match — `capturesAll` / `capturesIterator`

`captures` returns the **first** match's groups. For **every** match, use
`capturesAll` (an owned slice — each element owns its groups) or
`capturesIterator` (streaming, lower peak memory). Either way, each yielded
`Match` must be `deinit`-ed.

```zig
var kv = try Regex.compile(allocator, "(?<k>\\w+)=(?<v>\\d+)");
defer kv.deinit();

// Streaming — free each match as you go:
var it = kv.capturesIterator("a=1 bb=22");
defer it.deinit();
while (try it.next(allocator)) |mm| {
    var m = mm;
    defer m.deinit(allocator);
    std.debug.print("{s} -> {s}\n", .{ m.groupByName("k").?.slice, m.groupByName("v").?.slice });
}

// Or the whole slice at once — free each element's groups, then the slice:
const all = try kv.capturesAll(allocator, "a=1 bb=22");
defer {
    for (all) |*m| m.deinit(allocator);
    allocator.free(all);
}
```

---

## Compile Flags

`compileWithFlags` accepts a `CompileFlags` struct. Four flags are honored:

| Flag | Effect | Inline equivalent |
|------|--------|-------------------|
| `case_insensitive` | ASCII case folding | `(?i)` |
| `dot_all` | `.` also matches `\n` | `(?s)` |
| `extended` | verbose/whitespace-insensitive mode | `(?x)` |
| `multiline` | `^`/`$` match at line boundaries | `(?m)` |

```zig
var re = try Regex.compileWithFlags(allocator, "error", .{
    .case_insensitive = true,
});
defer re.deinit();

const samples = [_][]const u8{ "ERROR: down", "Error: 404", "no issue" };
for (samples) |s| {
    if (try re.find(s)) |m| std.debug.print("hit {s} in {s}\n", .{ m.slice, s });
}
```

> Only the `.unicode` flag is **not yet implemented** — passing
> `.unicode = true` returns `error.NotImplemented`. All other flags work.

### Multiline anchors

The `.multiline` flag routes `^`/`$` to line boundaries — an exact peer of a
leading `(?m)`:

```zig
var re = try Regex.compileWithFlags(allocator, "^\\w+", .{ .multiline = true });
defer re.deinit();

const text = "alpha\nbeta\ngamma";
const lines = try re.findAll(allocator, text);
defer allocator.free(lines);
// lines[0].slice == "alpha", lines[1].slice == "beta", lines[2].slice == "gamma"
```

### Inline flags

`(?i)`, `(?s)`, `(?x)`, and `(?m)` are honored in both toggle form (affecting
the rest of the pattern) and scoped form `(?i:…)`.

```zig
// Toggle form: case-insensitive for the whole pattern.
var re1 = try Regex.compile(allocator, "(?i)hello");
defer re1.deinit();
_ = try re1.isMatch("HELLO there"); // true

// Scoped form: only "abc" is case-insensitive.
var re2 = try Regex.compile(allocator, "(?i:abc)DEF");
defer re2.deinit();
_ = try re2.isMatch("ABCDEF"); // true ("DEF" stays case-sensitive)

// Dot-all inline: "." spans newlines.
var re3 = try Regex.compile(allocator, "(?s)a.b");
defer re3.deinit();
_ = try re3.isMatch("a\nb"); // true
```

---

## Compile-Time Patterns

For a pattern known at compile time, **`Pattern`** runs the whole
parse → NFA → DFA (+minimize) pipeline **at compile time** and bakes the matcher
into `.rodata`. The result is a **type** with **static** methods — there is no
instance, no allocator, and no `deinit`.

```zig
const std = @import("std");
const zeetah = @import("zeetah");

// Pure literals bake a comptime Teddy scan (no DFA table); everything else
// bakes a minimized DFA.
const Phone = zeetah.Pattern("[0-9]{3}-[0-9]{4}", .{});

test "allocation-free comptime match" {
    try std.testing.expect(Phone.isMatch("call 555-1234 now"));

    if (Phone.find("call 555-1234 now")) |m| { // ?Match -- no error union
        try std.testing.expectEqualStrings("555-1234", m.slice);
    }

    try std.testing.expectEqual(@as(usize, 1), Phone.count("call 555-1234 now"));
}
```

Static methods:

- `isMatch(input) bool` — allocation-free, no error union.
- `find(input) ?Match` — allocation-free, **no error union** (unlike runtime `find`).
- `count(input) usize` — allocation-free, no error union.
- `findAll(allocator, input) ![]Match` — allocates the result slice.
- `captures(allocator, input) !?Match` / `capturesAll(allocator, input) ![]Match`
  — submatch extraction (numbered + `(?<name>)` named), same as the runtime
  `Regex`; allocate the `Match.groups`.

Captures work at comptime too — `Pattern` is no longer capture-free.

### Options

```zig
// zeetah.PatternOptions:
//   max_dfa_states: usize = 256          (soft budget; bounded by an internal 256 ceiling, cannot raise it)
//   on_oversize: enum { compile_error, allow_oversized } = .compile_error
//   case_insensitive: bool = false       (peer of (?i))
//   multiline: bool = false              (peer of (?m): ^/$ as line anchors)

const Word = zeetah.Pattern("[a-z]+", .{ .case_insensitive = true });

test "case-insensitive comptime pattern" {
    try std.testing.expect(Word.isMatch("ZEETAH"));
}

// Non-regular features compile at comptime — they bake the bounded backtracker:
const Dup = zeetah.Pattern("(\\w+) \\1", .{});         // backreference + captures
const Logs = zeetah.Pattern("^ERROR", .{ .multiline = true }); // (?m) line anchor

test "non-regular comptime patterns" {
    try std.testing.expect(Dup.isMatch("the the"));
    try std.testing.expectEqual(@as(usize, 2), Logs.count("ERROR a\nok\nERROR b"));
}
```

The comptime path now covers the **same feature surface as the runtime `Regex`**:
regular patterns bake a minimized DFA, non-regular ones (captures, lookaround,
backreferences, atomic/possessive, `\b`, `(?m)`, lazy-plus-end-anchor) bake the
same bounded backtracker. The only `@compileError`s are the constructs genuinely
unsupported *anywhere* in the engine — the `.unicode` flag, `\p` scripts / `\p`
under `(?i)`, an unknown POSIX class, or a pattern past an internal construction
ceiling — since a `Pattern` has no runtime fallback. For those, use the runtime
`Regex`.

> `on_oversize = .allow_oversized` only bakes an over-budget but
> representable DFA for a large *regular* pattern; it does **not** make a
> `Pattern` accept an unsupported feature or one past the internal ceiling.

---

## Builder

`Builder` assembles a pattern **string** fluently. `init` returns by value (no
`try`); each fluent method returns `!*Builder`, so chain with `_ = try b.x();`.
Terminate with `build()` (returns the owned pattern string) or `compile()`
(builds the string and compiles it to a `Regex` in one step).

```zig
const std = @import("std");
const zeetah = @import("zeetah");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var b = zeetah.Builder.init(allocator); // no `try`
    defer b.deinit();

    _ = try b.literal("id-"); // literal escapes metacharacters
    _ = try b.digit();
    _ = try b.repeatExact(3); // pattern so far: id\-\d{3}

    var re = try b.compile(); // build internally + Regex.compile
    defer re.deinit();

    _ = try re.isMatch("id-007"); // true
}
```

### Getting the raw string instead of a `Regex`

```zig
var b = zeetah.Builder.init(allocator);
defer b.deinit();

_ = try b.startGroup();
_ = try b.word();
_ = try b.oneOrMore();
_ = try b.endGroup(); // pattern: (\w+)

const pattern = try b.build(); // caller OWNS the string
defer allocator.free(pattern);

std.debug.print("{s}\n", .{pattern}); // (\w+)
```

A representative slice of the fluent vocabulary: `literal`, `any`, `digit`,
`word`, `whitespace`, `startOfLine`, `endOfLine`, `wordBoundary`, `oneOrMore`,
`zeroOrMore`, `optional`, `repeatExact(n)`, `repeatAtLeast(n)`,
`repeatRange(min, max)`, `startGroup` / `endGroup`,
`startNonCapturingGroup` (emits `(?:`, close with `endGroup`), `or_` (trailing
underscore because `or` is a keyword), `charClass(chars)`,
`notCharClass(chars)`, and `charRange(start, end)`.

---

## Ready-Made Patterns

`Patterns` is a namespace of factory functions, each returning an
allocator-owned pattern **string** (not a `Regex`). You free the string and
compile it yourself.

```zig
const std = @import("std");
const zeetah = @import("zeetah");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const pat = try zeetah.Patterns.email(allocator);
    defer allocator.free(pat); // free the pattern STRING

    var re = try zeetah.Regex.compile(allocator, pat);
    defer re.deinit();

    _ = try re.isMatch("dev@example.com"); // true
}
```

Available factories: `email`, `url`, `ipv4`, `phoneUS`, `dateISO`, `time24`,
`hexColor`, `creditCard`, `uuid`, `integer`, `decimal`, `identifier`.

> These are simplified, convenient defaults — not strict validators. For
> example, `creditCard` does not perform a Luhn check.

---

## Worked Examples

### Extract emails from text

```zig
var re = try Regex.compile(
    allocator,
    "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}",
);
defer re.deinit();

const text = "Contact support@example.com or sales@example.org today.";
const emails = try re.findAll(allocator, text);
defer allocator.free(emails);

for (emails) |e| std.debug.print("email: {s}\n", .{e.slice});
```

### Extract URLs

```zig
var re = try Regex.compile(allocator, "https?://[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}");
defer re.deinit();

const text = "Visit https://example.com or http://test.org for details.";
const urls = try re.findAll(allocator, text);
defer allocator.free(urls);

for (urls) |u| std.debug.print("url: {s}\n", .{u.slice});
```

### Validate input with `isMatch`

```zig
pub fn isValidUsername(allocator: std.mem.Allocator, name: []const u8) !bool {
    var re = try Regex.compile(allocator, "^[a-zA-Z0-9_]{3,16}$");
    defer re.deinit();
    return re.isMatch(name);
}
```

### Pull a timestamp out of a log line

```zig
var re = try Regex.compile(allocator, "\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}");
defer re.deinit();

if (try re.find("[2025-01-26 14:30:45] user logged in")) |m| {
    std.debug.print("timestamp: {s}\n", .{m.slice}); // 2025-01-26 14:30:45
}
```

### Parse key=value pairs with named captures

```zig
var re = try Regex.compile(allocator, "(?<key>\\w+)=(?<val>\\w+)");
defer re.deinit();

if (try re.captures(allocator, "port=8080")) |m| {
    var mm = m;
    defer mm.deinit(allocator);

    const key = mm.groupByName("key").?;
    const val = mm.groupByName("val").?;
    std.debug.print("{s} -> {s}\n", .{ key.slice, val.slice }); // port -> 8080
}
```

### Iterate over every line-leading word (multiline)

```zig
var re = try Regex.compileWithFlags(allocator, "^\\w+", .{ .multiline = true });
defer re.deinit();

var it = re.iterator("alpha 1\nbeta 2\ngamma 3");
defer it.deinit();
while (try it.next(allocator)) |m| {
    std.debug.print("{s}\n", .{m.slice}); // alpha, beta, gamma
}
```

### Reuse a single compiled `Regex`

Compiling is the expensive step — compile once, match many times.

```zig
var re = try Regex.compile(allocator, "\\d+"); // compile once
defer re.deinit();

const inputs = [_][]const u8{ "a1", "b22", "c333" };
for (inputs) |s| {
    std.debug.print("{s}: {}\n", .{ s, try re.isMatch(s) });
}
```

---

## Memory & Lifetime Rules

A quick reference for who owns what:

| Result | Owns heap? | Cleanup |
|--------|-----------|---------|
| `find` / `iterator.next` `?Match` | no | none (`Match.deinit` is a harmless no-op) |
| `findAll` `[]Match` | the **slice** only | `allocator.free(slice)` |
| `captures` `?Match` | the `groups` array | `match.deinit(allocator)` — **required** |
| `capturesAll` `[]Match` | each `Match`'s `groups` **and** the slice | `for (s) \|*m\| m.deinit(allocator)` then `allocator.free(s)` |
| `capturesIterator.next` `?Match` | the yielded `Match`'s `groups` | `match.deinit(allocator)` per match — **required** |
| `split` `[][]const u8` | the **outer slice** only | `allocator.free(slice)` (elements alias the input) |
| `replace` / `replaceAll` `[]u8` | yes | `allocator.free(result)` |
| `Builder.build` `[]const u8` | yes | `allocator.free(pattern)` |
| `Patterns.*` `[]const u8` | yes | `allocator.free(pattern)` |
| `Regex` | yes | `regex.deinit()` |

Key points:

- A `Match.slice` and every `Group.slice` **alias the input** — valid only while
  both the input and the source `Regex` stay alive. Nothing is copied.
- Calling `match.deinit(allocator)` on a `find` / `findAll` / `iterator` result
  is safe but does nothing; it is **required** only after `captures` (those
  results carry an owned `groups` array).
- `split` element slices are views into the input — never free them
  individually; free only the outer slice.

---

**Last Updated:** 2026-05-30
**Version:** 0.16.0
