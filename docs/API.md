# API Reference

The precise public API reference for **Zeetah**, a fast, dependency-free regex
meta engine for Zig.

> **Public API surface.** The `zeetah` module exports exactly these twelve names:
>
> `Regex` · `CompileFlags` · `Match` · `Group` · `MatchIterator` ·
> `CapturesIterator` · `RegexError` · `Pattern` · `PatternOptions` · `Builder` ·
> `Patterns` · `version`
>
> Everything else — the parser, the NFA/DFA compilers, the planner, the
> prefilters, the backtracker — is engine internal, not exported, and carries
> no stability guarantee. Import the package as `@import("zeetah")`.

```zig
const zeetah = @import("zeetah");
const Regex = zeetah.Regex;
```

## Table of Contents

- [Core Types](#core-types)
- [Compilation](#compilation)
- [Matching](#matching)
- [Searching](#searching)
- [Captures](#captures)
- [Iteration](#iteration)
- [Replacement](#replacement)
- [Splitting](#splitting)
- [Counting](#counting)
- [Flags](#flags)
- [Compile-Time Patterns](#compile-time-patterns)
- [Builder & Ready-Made Patterns](#builder--ready-made-patterns)
- [Error Handling](#error-handling)
- [Memory & Lifetime](#memory--lifetime)
- [Version](#version)

---

## Core Types

### `Regex`

A compiled regular expression — the library's primary entry point. Compile
once, reuse for many inputs, and free with `deinit`. The struct's fields are
implementation detail; treat it as opaque and use its methods.

```zig
const Regex = @import("zeetah").Regex;

var re = try Regex.compile(allocator, "\\d+");
defer re.deinit();
```

The matching methods (`isMatch`, `find`, `findFrom`, `captures`, `capturesFrom`,
`capturesAll`, `capturesIterator`, `findAll`, `count`, `replace`, `replaceAll`,
`replaceLiteral`, `replaceAllLiteral`, `split`, `iterator`) all take
`*const Regex`, so a single compiled instance is safe to share across
concurrent readers.

### `Match`

The result of a successful match.

```zig
pub const Match = struct {
    /// The whole match (aliases the input; not owned).
    slice: []const u8,
    /// Start byte index of the whole match in the input.
    start: usize,
    /// End byte index of the whole match in the input (exclusive).
    end: usize,
    /// Submatches by group index. EMPTY for `find`/`isMatch`/`findAll`/
    /// `iterator` (captures are opt-in via `Regex.captures`). When produced
    /// by `captures`, `groups[0]` is the whole match and `groups[N]` is
    /// capture N (or `null` if it did not participate). A non-empty `groups`
    /// is always allocator-owned; an empty one never is (ownership is implicit
    /// — there is no separate flag).
    groups: []const ?Group = &.{},

    pub fn groupByName(self: *const Match, name: []const u8) ?Group;
    pub fn deinit(self: *Match, allocator: std.mem.Allocator) void;
};
```

The match span is a half-open byte range `[start, end)`. `slice` aliases the
original input — it is **not** copied — so the input string (and the source
`Regex`) must outlive the `Match`.

**Methods:**

- `groupByName(name)` — the `(?<name>…)` group for `name`, or `null` if the
  name is undefined or that group did not participate. Only meaningful on a
  `captures()` result, since `find`/`findAll`/`iterator` leave `groups` empty.
- `deinit(allocator)` — frees the `groups` slice **iff** it is allocator-owned
  (i.e. non-empty). It is a genuine no-op for `find` / `findAll` / `iterator`
  results, and **required** for `captures` results. Pass the same allocator
  that produced the match; `deinit` never touches the input.

### `Group`

A single matched capture group. Groups are populated only by
[`captures()`](#captures).

```zig
pub const Group = struct {
    /// The captured substring (aliases the input; not owned).
    slice: []const u8,
    /// Start byte index of the group in the input.
    start: usize,
    /// End byte index of the group in the input (exclusive).
    end: usize,
    /// The group's name for `(?<name>...)` groups, else `null`.
    name: ?[]const u8 = null,

    pub fn len(self: Group) usize; // span length in bytes (end - start)
};
```

### `MatchIterator`

Lazily yields successive non-overlapping **whole-match spans** (capture-free);
obtained from [`Regex.iterator`](#iteration). `next` takes an allocator for
signature parity with [`CapturesIterator`](#capturesiterator) but **ignores it**
(the capture-free path allocates nothing). See [Iteration](#iteration).

### `CapturesIterator`

Like `MatchIterator` but each yielded `Match` carries its capture `groups`
(allocator-owned — `deinit` each); obtained from `Regex.capturesIterator`.
`next(allocator)` uses the allocator. See [Iteration](#iteration).

### `RegexError`

The error set returned by compilation and matching. See
[Error Handling](#error-handling) for the variants `compile` actually surfaces.

### `Pattern` / `PatternOptions`

The compile-time path: a comptime-known pattern is compiled into a type whose
static methods match with zero allocation. See
[Compile-Time Patterns](#compile-time-patterns).

### `Builder` / `Patterns`

Programmatic pattern construction. Both produce pattern **strings** that you
then compile yourself. See
[Builder & Ready-Made Patterns](#builder--ready-made-patterns).

---

## Compilation

### `compile()`

Compile a regex pattern with default flags.

```zig
pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) !Regex
```

**Parameters:**

- `allocator` — backs the regex and its internal structures.
- `pattern` — the regex pattern string. An empty pattern returns
  `error.EmptyPattern`.

**Returns:** a compiled `Regex` (caller owns; call `deinit`), or an error.

**Example:**

```zig
const allocator = std.heap.page_allocator;
var regex = try Regex.compile(allocator, "\\d{3}-\\d{4}");
defer regex.deinit();
```

### `compileWithFlags()`

Compile a regex pattern with explicit flags.

```zig
pub fn compileWithFlags(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    flags: CompileFlags,
) !Regex
```

You never spell the `CompileFlags` type out: pass an anonymous struct literal
and set only the fields you want. See [Flags](#flags).

**Example:**

```zig
var regex = try Regex.compileWithFlags(
    allocator,
    "hello",
    .{ .case_insensitive = true },
);
defer regex.deinit();
```

### `deinit()`

Free all resources associated with the regex.

```zig
pub fn deinit(self: *Regex) void
```

```zig
var regex = try Regex.compile(allocator, "pattern");
defer regex.deinit(); // always call when done
```

---

## Matching

### `isMatch()`

Report whether the pattern matches anywhere in the input. Allocation-free; no
allocator argument.

```zig
pub fn isMatch(self: *const Regex, input: []const u8) !bool
```

**Returns:** `true` if a match exists, `false` otherwise.

```zig
var regex = try Regex.compile(allocator, "\\d+");
defer regex.deinit();

if (try regex.isMatch("abc123")) {
    std.debug.print("Found digits!\n", .{});
}
```

---

## Searching

### `find()`

Find the first (leftmost) match. **Capture-free** and allocation-free: the
returned `Match` carries only `slice` / `start` / `end`; `groups.len == 0`
even when the pattern has `(...)` groups. No allocator argument.

```zig
pub fn find(self: *const Regex, input: []const u8) !?Match
```

**Returns:** a `Match` if found, `null` otherwise. The match needs no cleanup
(`deinit` is a no-op), but `deinit` is always safe to call.

```zig
var regex = try Regex.compile(allocator, "\\d+");
defer regex.deinit();

if (try regex.find("Price: $123")) |m| {
    std.debug.print("Found: {s}\n", .{m.slice});       // "123"
    std.debug.print("At: {d}-{d}\n", .{ m.start, m.end });
}
```

> To extract submatches from a pattern with groups, use
> [`captures()`](#captures) — `find` deliberately ignores groups for speed.

### `findFrom()`

The positional-resume peer of `find`: the leftmost (capture-free) match at or
after absolute byte offset `pos`. `find(input)` is exactly `findFrom(input, 0)`.
Mirrors [`capturesFrom()`](#captures) on the capture-bearing side. `pos` must be
`<= input.len`; the returned span is in absolute `input` coordinates.

```zig
pub fn findFrom(self: *const Regex, input: []const u8, pos: usize) !?Match
```

As with `findAll`, a leading `^` / `\b` / look-behind on the slice-based
engines treats `pos` as start-of-text.

### `findAll()`

Find all non-overlapping matches.

```zig
pub fn findAll(
    self: *const Regex,
    allocator: std.mem.Allocator,
    input: []const u8,
) ![]Match
```

**Parameters:**

- `allocator` — backs the result slice.
- `input` — the haystack.

**Returns:** a slice of `Match`. Each match is **capture-free**
(`groups.len == 0`); free the outer slice with `allocator.free`. Because the
individual matches own nothing, no per-element `deinit` is needed.

```zig
var regex = try Regex.compile(allocator, "\\d+");
defer regex.deinit();

const matches = try regex.findAll(allocator, "Call 555-1234 or 555-5678");
defer allocator.free(matches);

for (matches) |m| {
    std.debug.print("Found: {s}\n", .{m.slice});
}
// Found: 555
// Found: 1234
// Found: 555
// Found: 5678
```

---

## Captures

### `captures()`

The **opt-in** submatch method. Unlike `find`, it allocates a `groups` array
and fills in each capture group.

```zig
pub fn captures(
    self: *const Regex,
    allocator: std.mem.Allocator,
    input: []const u8,
) !?Match
```

**Parameters:**

- `allocator` — backs the `groups` array on the returned match.
- `input` — the haystack.

**Returns:** a `Match` whose `groups` is allocator-owned, or `null` if there is
no match. The caller **must** free it: `defer m.deinit(allocator)`.

**Group layout:** `groups[0]` is the whole match; `groups[N]` is capture group
`N`, or `null` if that group did not participate in the match. Look groups up
by name with `Match.groupByName`.

```zig
var re = try Regex.compile(allocator, "(?<year>\\d{4})-(?<mon>\\d{2})");
defer re.deinit();

if (try re.captures(allocator, "2026-05")) |m| {
    var mm = m;
    defer mm.deinit(allocator); // REQUIRED — groups is owned

    const whole = m.groups[0].?.slice;        // "2026-05"
    const year  = m.groupByName("year").?.slice; // "2026"
    const mon   = m.groupByName("mon").?.slice;  // "05"
    _ = .{ whole, year, mon };
}
```

> Groups nested inside a lookaround are not reconstructed. Capture groups are
> bounded at 32 per pattern (a construction ceiling).

### `capturesAll()`

The capture-bearing peer of `findAll`: an allocator-owned `[]Match` for **every**
non-overlapping match, where **each element owns its `groups`**.

```zig
pub fn capturesAll(self: *const Regex, allocator: std.mem.Allocator, input: []const u8) ![]Match
```

Free **both** each match's groups and the outer slice:

```zig
var re = try Regex.compile(allocator, "(?<k>\\w+)=(?<v>\\d+)");
defer re.deinit();

const all = try re.capturesAll(allocator, "a=1 bb=22");
defer {
    for (all) |*m| m.deinit(allocator); // each Match's groups
    allocator.free(all);                // then the slice
}
// all[0].groupByName("k").?.slice == "a"
```

`capturesFrom(allocator, input, pos)` is the positional-resume primitive (the
capture peer of `findFrom`) that both `capturesAll` and `capturesIterator` build
on: the leftmost capture-bearing match at or after byte offset `pos`.

---

## Iteration

### `iterator()`

Create a `MatchIterator` that yields non-overlapping matches lazily, without
allocating a full result slice up front. Returned by value.

```zig
pub fn iterator(self: *const Regex, input: []const u8) MatchIterator
```

The iterator borrows `self` and `input`; both must outlive it.

**Methods:**

```zig
pub fn next(self: *MatchIterator, allocator: std.mem.Allocator) !?Match
pub fn deinit(self: *MatchIterator) void
```

- `next(allocator)` — the next match, or `null` when exhausted. Each returned
  `Match` is capture-free (`groups.len == 0`). The `allocator` argument is
  accepted for signature symmetry but is **ignored** on this path; the matches
  own nothing.
- `deinit()` — a no-op kept for symmetry.

```zig
var re = try Regex.compile(allocator, "\\d+");
defer re.deinit();

var it = re.iterator("a1 b22 c333");
defer it.deinit();
while (try it.next(allocator)) |m| {
    std.debug.print("{s}\n", .{m.slice}); // 1, 22, 333
}
```

### `capturesIterator()`

The capture-bearing peer of `iterator`: a `CapturesIterator` yielding successive
non-overlapping matches lazily, **each owning its `groups`** — lower peak memory
than `capturesAll`, which materializes the whole slice. Returned by value.

```zig
pub fn capturesIterator(self: *const Regex, input: []const u8) CapturesIterator
```

**Methods:**

```zig
pub fn next(self: *CapturesIterator, allocator: std.mem.Allocator) !?Match
pub fn deinit(self: *CapturesIterator) void
```

Unlike `MatchIterator.next`, **`next(allocator)` allocates** the yielded match's
`groups` — `deinit` each match as you go. `deinit()` on the iterator is a no-op.

```zig
var re = try Regex.compile(allocator, "(?<k>\\w+)=(?<v>\\d+)");
defer re.deinit();

var it = re.capturesIterator("a=1 bb=22");
defer it.deinit();
while (try it.next(allocator)) |mm| {
    var m = mm;
    defer m.deinit(allocator); // each yielded Match owns its groups
    std.debug.print("{s} -> {s}\n", .{ m.groupByName("k").?.slice, m.groupByName("v").?.slice });
}
```

---

## Replacement

### `replace()`

Replace the **first** match, expanding capture references in `template`.

```zig
pub fn replace(
    self: *const Regex,
    allocator: std.mem.Allocator,
    input: []const u8,
    template: []const u8,
) ![]u8
```

> **Template substitution.** `template` is expanded against the match:
> `$0` / `$&` = the whole match, `$1`..`$N` = numbered groups, `${name}` =
> named group, `$$` = a literal `$`. A `$` that does not start a valid
> reference is emitted literally; unknown, out-of-range, or non-participating
> references expand to the empty string. Digits are greedy (`$12` is group 12)
> — write `${1}2` for "group 1 then a literal 2". If there is no match, the
> result is a fresh duplicate of `input`. For a byte-for-byte literal
> replacement (no `$`-handling) use [`replaceLiteral`](#replaceliteral).

**Returns:** a newly allocated string (caller owns; `allocator.free`).

```zig
var regex = try Regex.compile(allocator, "(\\d{4})-(\\d{2})-(\\d{2})");
defer regex.deinit();

const result = try regex.replace(allocator, "on 2024-03-15.", "$3/$2/$1");
defer allocator.free(result);

std.debug.print("{s}\n", .{result}); // "on 15/03/2024."
```

### `replaceAll()`

Replace **every** match, expanding capture references in `template` (same
syntax as [`replace`](#replace)).

```zig
pub fn replaceAll(
    self: *const Regex,
    allocator: std.mem.Allocator,
    input: []const u8,
    template: []const u8,
) ![]u8
```

**Returns:** a newly allocated string (caller owns; `allocator.free`).

```zig
var regex = try Regex.compile(allocator, "\\d+");
defer regex.deinit();

const result = try regex.replaceAll(allocator, "Call 555-1234 or 555-5678", "XXX");
defer allocator.free(result);

std.debug.print("{s}\n", .{result}); // "Call XXX-XXX or XXX-XXX"
```

### `replaceLiteral()` / `replaceAllLiteral()`

Replace the first / every match with `replacement` inserted **verbatim** — no
`$`-substitution. Use these when the replacement contains `$` that should not
be treated as a capture reference.

```zig
pub fn replaceLiteral(
    self: *const Regex,
    allocator: std.mem.Allocator,
    input: []const u8,
    replacement: []const u8,
) ![]u8
pub fn replaceAllLiteral(
    self: *const Regex,
    allocator: std.mem.Allocator,
    input: []const u8,
    replacement: []const u8,
) ![]u8
```

```zig
var regex = try Regex.compile(allocator, "\\d+");
defer regex.deinit();

const result = try regex.replaceAllLiteral(allocator, "a1 b2", "$1");
defer allocator.free(result);

std.debug.print("{s}\n", .{result}); // "a$1 b$1"  (literal "$1")
```

---

## Splitting

### `split()`

Split the input by the pattern.

```zig
pub fn split(
    self: *const Regex,
    allocator: std.mem.Allocator,
    input: []const u8,
) ![][]const u8
```

**Returns:** a slice of segment slices. Each element **aliases** the input (it
is not owned); free only the outer slice with `allocator.free`.

Behavior:

- **Boundary segments are kept.** If `input` starts or ends with a match, a
  leading or trailing `""` segment is produced.
- **Zero-width matches are skipped** (they do not create empty segments).

```zig
var regex = try Regex.compile(allocator, ",");
defer regex.deinit();

const parts = try regex.split(allocator, "a,b,c");
defer allocator.free(parts);

for (parts) |part| {
    std.debug.print("Part: {s}\n", .{part});
}
// Part: a
// Part: b
// Part: c
```

---

## Counting

### `count()`

Count non-overlapping matches. Allocation-free; no allocator argument.

```zig
pub fn count(self: *const Regex, input: []const u8) !usize
```

```zig
var regex = try Regex.compile(allocator, "\\d+");
defer regex.deinit();

const n = try regex.count("a1 b22 c333"); // 3
std.debug.print("{d}\n", .{n});
```

---

## Flags

### `CompileFlags`

Flags passed to [`compileWithFlags`](#compilewithflags). You never name the
type: pass an anonymous struct literal and set only the fields you need. All
fields default to `false`.

```zig
.{
    .case_insensitive = false, // ASCII-fold case-insensitive matching
    .multiline        = false, // `^`/`$` also match at line boundaries
    .dot_all          = false, // `.` also matches `\n`
    .extended         = false, // verbose mode: ignore unescaped whitespace
    .unicode          = false, // NOT IMPLEMENTED — see below
}
```

| Field | Effect | Status |
| --- | --- | --- |
| `case_insensitive` | ASCII case folding. Equivalent to inline `(?i)`. | Works |
| `multiline` | Routes `^` / `$` to line anchors — an exact peer of inline `(?m)`. | Works |
| `dot_all` | `.` also matches newline. Equivalent to inline `(?s)`. | Works |
| `extended` | Verbose / `x` mode: unescaped whitespace in the pattern is ignored. Equivalent to inline `(?x)`. | Works |
| `unicode` | Codepoint-aware mode — **reserved** (see below). | **`error.NotImplemented`** |

> `unicode` is the **only** rejected flag — passing `.unicode = true` (or inline
> `(?u)`) returns `error.NotImplemented`. `multiline` **works**; it is not
> rejected. The inline forms `(?i)`, `(?s)`, `(?x)`, `(?m)` are all honored too,
> in both scoped (`(?i:…)`) and toggle (`(?i)`) styles.
>
> **Reserved-semantics contract (alpha):** matching is **byte-oriented** by
> default — `.` matches one byte, `\d`/`\w`/`\b` are ASCII, `\p` is Latin-1.
> That default is committed and will not change. `.unicode` / `(?u)` is the
> reserved opt-in for codepoint-aware mode; when implemented it will *add* that
> behaviour only when set, never alter the byte default — so the future Unicode
> phase is additive and non-breaking, not a silent semantics shift.

```zig
var regex = try Regex.compileWithFlags(
    allocator,
    "hello",
    .{ .case_insensitive = true },
);
defer regex.deinit();

try std.testing.expect(try regex.isMatch("HELLO")); // true
try std.testing.expect(try regex.isMatch("Hello")); // true
try std.testing.expect(try regex.isMatch("hello")); // true
```

---

## Compile-Time Patterns

### `Pattern()`

Build a matcher from a comptime-known pattern. `Pattern` runs the **whole**
parse → NFA → DFA (+ minimize) pipeline at compile time and bakes the matcher
into `.rodata`; pure-literal patterns bake a comptime Teddy scan with no DFA
table. The result is a **type** with **static** methods — there is no instance,
no allocator for matching, and no `deinit`.

```zig
pub fn Pattern(comptime pattern: []const u8, comptime opts: PatternOptions) type
```

**Static members of the returned type:**

```zig
// `has_dfa == true`  for a baked DFA / literal (the regular tier);
// `has_dfa == false` for the baked tree-backtracker (the non-regular tier).
pub const has_dfa: bool;

// Mental model: `find` → `Match` (whole match); `captures` → `Captures`
// (submatches). On the comptime path, every ONE-MATCH verb is allocation-free —
// `Captures` holds groups INLINE (count + names comptime-known).
// ── Allocation-free (return one match) ──
pub fn isMatch(input: []const u8) bool;
pub fn find(input: []const u8) ?Match;                  // whole match; NO error union, NO allocator
pub fn count(input: []const u8) usize;
pub fn startsWith(input: []const u8) bool;              // anchored-prefix test
pub fn captures(input: []const u8) ?Captures(ng, gnames);            // submatches, inline — NO allocator
pub fn capturesFrom(input: []const u8, from: usize) ?Captures(ng, gnames);
// Lazy iterators — values you drive with `while (it.next()) |m|`; O(1) memory,
// free early-break, no allocator:
pub fn iterator(input: []const u8) Iterator;            // whole-match
pub fn capturesIterator(input: []const u8) CapturesIterator; // submatches
pub fn splitIterator(input: []const u8) SplitIterator;  // fields between matches
// ── Eager (allocate ONE result slice; elements are still inline) ──
pub fn findAll(allocator: std.mem.Allocator, input: []const u8) ![]Match;
pub fn capturesAll(allocator: std.mem.Allocator, input: []const u8) ![]Captures(ng, gnames);
```

> Note the comptime `captures` takes **no allocator** and returns `?Captures` —
> distinct from the runtime `Regex.captures(allocator, …) !?Match`, which
> heap-allocates `Match.groups`. The comptime path knows the group count at compile
> time, so it never needs the heap; there is **no allocating `captures` on
> `Pattern`** (one obvious, zero-alloc way). `capturesAll` allocates only the outer
> `[]Captures` slice (free with a single `allocator.free` — no per-element
> `deinit`, since each `Captures`'s groups are inline).

The inline `Captures` value (zero-allocation) exposes:

```zig
pub fn slice(self) []const u8;                 // whole match
pub fn get(self, comptime i: usize) ?Group;    // compile-time-INDEXED (bad index = compile error)
pub fn getName(self, comptime name: []const u8) ?Group; // compile-time name → group (unknown = compile error)
pub fn group(self, i: usize) ?Group;           // runtime index (out-of-range ⇒ null)
pub fn groupByName(self, name: []const u8) ?Group;      // runtime name lookup
```

- It runs **with no allocator at all** — even fully at `comptime`. This is the win
  over the runtime `Regex.captures` (which heap-allocates `Match.groups`): in a hot
  loop or a no-allocator (WASM / freestanding) build, `captures` + `get(i)` extract
  submatches with zero heap traffic. `get`/`getName` are bounds-/name-checked **at
  compile time**.

```zig
const Pattern = @import("zeetah").Pattern;

// Regular pattern with named groups — DFA arm, captures still zero-alloc:
const Date = Pattern("(?<y>\\d{4})-(\\d{2})-(\\d{2})", .{});
comptime std.debug.assert(Date.has_dfa);        // regular ⇒ baked DFA

if (Date.captures("Date: 2024-03-15")) |c| {         // no allocator
    std.debug.print("{s} {s}\n", .{ c.getName("y").?.slice, c.get(2).?.slice }); // "2024" "03"
}

// Non-regular ⇒ baked tree-backtracker (has_dfa == false), captures the same way:
const Dup = Pattern("(\\w+) \\1", .{});
comptime std.debug.assert(!Dup.has_dfa);
```

**Supported subset.** `Pattern` now covers the **same feature surface as the runtime
`Regex`** — the two share the `parser → HIR` front end. Regular patterns bake a
minimized DFA (or a comptime Teddy literal); non-regular patterns bake the same
bounded tree-backtracker the runtime uses, including **captures** (numbered + named),
**lookaround**, **backreferences**, **atomic/possessive** quantifiers, **word
boundaries** (`\b`/`\B`), **`(?m)` line anchors**, and **lazy-with-end-anchor**
(`a*?$`). `\p{…}` is supported (allocator-free resolver).

Because a `Pattern` bakes a single matcher with **no runtime fallback**, the
constructs that are genuinely unsupported *anywhere* in the engine are a hard
`@compileError` (rather than a recoverable runtime `error.NotImplemented`):

- the `.unicode` (codepoint-mode) flag,
- `\p` scripts / binary properties / `\p` under `(?i)`,
- an unknown POSIX class name,
- a pattern that overflows an internal construction ceiling (e.g. `>1000`-count
  repetition, or a DFA that blows the 256-state ceiling — note a *large keyword
  alternation* like `\b(?:kw|…)\b` that would blow `MAX_NFA` instead routes to the
  backtracker and compiles, just slower than the runtime's Aho-Corasick engine).

For any of those, or if you need the rejection to be a recoverable error, use the
runtime `Regex`. (The match-budget ReDoS bound applies identically at comptime; the
non-erroring comptime API surfaces an exceedance as "no match" rather than
`error.MatchBudgetExceeded`.)

### `PatternOptions`

```zig
pub const PatternOptions = struct {
    /// Soft budget on the minimized DFA state count baked into `.rodata`.
    /// Bounded by a fixed internal ceiling of 256 — values above 256 have no
    /// effect (this option does not raise that ceiling).
    max_dfa_states: usize = 256,
    /// What happens when the DFA builds successfully but exceeds
    /// `max_dfa_states`: `.compile_error` (default) fails the build;
    /// `.allow_oversized` bakes the larger table anyway (still bounded by the
    /// internal ceiling). Neither value rescues a pattern that blows the
    /// internal ceiling or uses an unsupported feature — those always
    /// `@compileError` (the comptime path has no runtime fallback; use the
    /// runtime `Regex.compile` instead).
    on_oversize: enum { compile_error, allow_oversized } = .compile_error,
    /// ASCII case-insensitive matching (peer of `(?i)`).
    case_insensitive: bool = false,
    /// Multiline mode (peer of `(?m)`): `^`/`$` match at line boundaries.
    /// Such a pattern routes to the comptime backtracker (looks aren't
    /// DFA-foldable), exactly as a leading inline `(?m)` would.
    multiline: bool = false,
};
```

---

## Builder & Ready-Made Patterns

The `Builder` and `Patterns` modules produce pattern **strings**. Nothing
matches until you compile the string with `Regex.compile` (or, for `Builder`,
its `compile()` terminal).

### `Builder`

A fluent builder that assembles a pattern fragment by fragment.

```zig
pub fn init(allocator: std.mem.Allocator) Builder // returns BY VALUE — no `try`
pub fn deinit(self: *Builder) void                // frees fragments
```

Each fluent method returns `!*Builder`, so a chained call needs `try` on every
link — the practical form is `_ = try b.method(...);`.

| Method | Effect |
| --- | --- |
| `literal(text)` | Append literal text (escapes metacharacters except `]` and `}`). |
| `any()` | `.` |
| `digit()` | `\d` |
| `word()` | `\w` |
| `whitespace()` | `\s` |
| `startOfLine()` | `^` |
| `endOfLine()` | `$` |
| `wordBoundary()` | `\b` |
| `oneOrMore()` | `+` on the previous fragment |
| `zeroOrMore()` | `*` |
| `optional()` | `?` |
| `repeatExact(n)` | `{n}` |
| `repeatAtLeast(n)` | `{n,}` |
| `repeatRange(min, max)` | `{min,max}` |
| `startGroup()` | `(` |
| `endGroup()` | `)` |
| `startNonCapturingGroup()` | `(?:` — close with `endGroup()` |
| `or_()` | `|` (trailing underscore because `or` is a keyword) |
| `charClass(chars)` | `[chars]` (raw, unescaped) |
| `notCharClass(chars)` | `[^chars]` |
| `charRange(start, end)` | `[start-end]` |

**Terminals:**

```zig
pub fn build(self: *const Builder) ![]const u8 // caller OWNS the string; must free
pub fn compile(self: *const Builder) !Regex    // builds internally + Regex.compile; caller deinits the Regex
```

```zig
const Builder = @import("zeetah").Builder;

var b = Builder.init(allocator);
defer b.deinit();

_ = try b.literal("id-");
_ = try b.digit();
_ = try b.oneOrMore();

const pattern = try b.build();   // "id\\-\\d+" — caller owns
defer allocator.free(pattern);

var re = try Regex.compile(allocator, pattern);
defer re.deinit();
```

### `Patterns`

A namespace of 12 factory functions. **Each returns an allocator-owned pattern
string** (`![]const u8`) — **not** a `Regex`. The caller frees the string and
compiles it.

```zig
pub fn email(allocator) ![]const u8
pub fn url(allocator) ![]const u8
pub fn ipv4(allocator) ![]const u8
pub fn phoneUS(allocator) ![]const u8
pub fn dateISO(allocator) ![]const u8
pub fn time24(allocator) ![]const u8
pub fn hexColor(allocator) ![]const u8
pub fn creditCard(allocator) ![]const u8
pub fn uuid(allocator) ![]const u8
pub fn integer(allocator) ![]const u8
pub fn decimal(allocator) ![]const u8
pub fn identifier(allocator) ![]const u8
```

These patterns are simplified/approximate (for example, `creditCard` carries no
Luhn check).

```zig
const Patterns = @import("zeetah").Patterns;

const pat = try Patterns.email(allocator);
defer allocator.free(pat);

var re = try Regex.compile(allocator, pat);
defer re.deinit();

const ok = try re.isMatch("user@example.com"); // true
_ = ok;
```

---

## Error Handling

All errors live in the `RegexError` set. Compilation and matching collapse the
many internal parser errors into a small, stable surface — depend on these
names rather than fine-grained parser variants.

### What `compile` / `compileWithFlags` surface

- **`error.EmptyPattern`** — the pattern string is empty.
- **`error.InvalidPattern`** — **malformed syntax**: a dangling quantifier
  (`*abc`), a double quantifier (`a**`), an unbalanced group (`abc(`, `a)b`),
  an unclosed or ill-terminated inline-flag group (`(?m`), an unclosed class
  (`abc[`), a malformed or inverted `{m,n}` (`a{,2}`, `a{3,2}`), an empty or
  duplicate group name, or an invalid back-reference (`\0`, `\k<undefined>`).
- **`error.NotImplemented`** — **well-formed but not-yet-supported features**:
  the `.unicode` flag; `\p` scripts / binary properties / unknown names / `\p`
  under `(?i)`; an unknown POSIX class name; repetition counts greater than
  1000; an unrecognised `(?…)` group construct (e.g. atomic groups); an
  unsupported escape.
- **`error.PatternTooComplex`** — a construction ceiling overflowed **at
  compile time** (NFA states 256, edges 2048, DFA states 256, HIR nodes 4096,
  capture groups 32). Distinct from the match-time budget error below.

> `compile` collapses the parser's internal signals into these few names; it
> does **not** return fine-grained variants such as `UnsupportedInlineFlag` or
> `UnsupportedUnicodeProperty`. The split that matters for untrusted input:
> `InvalidPattern` = "this regex is broken", `NotImplemented` = "valid regex,
> unsupported here".

### Match-time safety (the ReDoS contract)

- **Regular patterns are linear by construction** — they run as a DFA table
  walk, O(n) per scan. If the eager DFA explodes it falls back to a
  bit-identical lazy DFA, never to backtracking. Classic "catastrophic"
  regular shapes (`(a+)+$`, `(a*)*$`, `(.*)*$`) **compile and run linearly** —
  they are **not** rejected at compile time.
- **Non-regular patterns** (backreferences, lookaround, lazy + end-anchor) run
  on a tree backtracker under an explicit step budget
  (`8000 + (len + 1) * 4000`) plus a recursion-depth guard (16384). Exceeding
  it returns a typed **`error.MatchBudgetExceeded`** **at match time** — never a
  hang. (Distinct from the compile-time `PatternTooComplex`, so a caller can
  tell "pattern too big to build" from "this haystack blew the budget".)
- The bounded capture path is O(n·m) via a `(state, pos)` visited bitset —
  never exponential.

**Example:**

```zig
const regex = Regex.compile(allocator, "abc(") catch |err| switch (err) {
    error.EmptyPattern => return err, // pattern string was empty
    error.InvalidPattern => return err, // malformed syntax (this case: unclosed group)
    error.NotImplemented => return err, // valid regex, unsupported feature
    error.PatternTooComplex => return err, // too large to build (compile-time ceiling)
    else => return err,
};
// At match time, a backtracking pattern can additionally return
// error.MatchBudgetExceeded (the per-haystack step budget), e.g.:
//   _ = re.isMatch(adversarial) catch |e| switch (e) {
//       error.MatchBudgetExceeded => {}, // pattern + input too expensive
//       else => return e,
//   };
```

---

## Memory & Lifetime

**Ownership rules:**

1. **Regex** — the caller owns the `Regex` from `compile` / `compileWithFlags`
   (and `Builder.compile`); call `deinit`.
2. **Matches** — `find` / `findAll` / `iterator` matches own nothing
   (`deinit` is a no-op). Only `captures` matches are owned and **must** be
   freed with `m.deinit(allocator)`.
3. **Strings** — the caller owns strings from `replace`, `replaceAll`,
   `Builder.build`, and every `Patterns` factory; free with `allocator.free`.
4. **Slices** — the caller owns the outer slice from `findAll` and `split`;
   free it with `allocator.free`. `split` elements **alias** the input, so do
   not free them individually.

```zig
// Compile once, reuse, free with defer.
var regex = try Regex.compile(allocator, pattern);
defer regex.deinit();

// find: nothing to clean up.
if (try regex.find(input)) |m| {
    // use m.slice ...
}

// captures: free the owned groups.
if (try regex.captures(allocator, input)) |m| {
    var mm = m;
    defer mm.deinit(allocator);
    // use mm.groups ...
}

// findAll / split: free the outer slice only.
const matches = try regex.findAll(allocator, input);
defer allocator.free(matches);
```

---

## Version

```zig
pub const version: std.SemanticVersion; // 0.16.0 (matches build.zig.zon)
```

```zig
const v = @import("zeetah").version;
std.debug.print("{d}.{d}.{d}\n", .{ v.major, v.minor, v.patch });
```

---

## See Also

- [Architecture](ARCHITECTURE.md) — the meta engine, the planner, prefilters.
- [Examples](EXAMPLES.md) — worked end-to-end examples.
- [Advanced Features](ADVANCED_FEATURES.md) — `Builder` / `Patterns` in depth.

---

**Requirements:** Zig 0.16+, zero external dependencies.
