# Performance & Benchmarks

How Zeetah is built for speed, what shapes are fast (and which are not), and how
the cross-engine comparison harness measures it.

> This document describes performance **characteristics** and the comparison
> **methodology**. No specific throughput or latency figures are committed to
> the repository, so none are quoted here — run the harness (below) on your own
> hardware to get numbers you can trust.

## Table of Contents

- [Overview](#overview)
- [Why Zeetah is fast](#why-zeetah-is-fast)
- [Performance characteristics](#performance-characteristics)
- [Pattern-shape guide](#pattern-shape-guide)
- [Optimization tips](#optimization-tips)
- [Memory & lifetime](#memory--lifetime)
- [The comparison harness](#the-comparison-harness)
- [Profiling Zeetah](#profiling-zeetah)
- [Reporting performance issues](#reporting-performance-issues)

---

## Overview

Zeetah is a **meta engine**: at `compile` time it analyzes the pattern (a pure
pass over the parsed HIR) and routes it to the cheapest executor that is still
correct. There is no single "VM" doing all the work — a plain literal becomes a
SIMD substring scan, a regular pattern becomes a compiled DFA table walk, and
only the genuinely non-regular features (lookaround, backreferences) fall to a
bounded backtracker. The performance profile is therefore **per-shape**, not
one curve.

The two design commitments that shape every number:

- **Regular patterns are linear by construction.** They run as a deterministic
  automaton (`Dfa256`), O(n) per scan in the input length — independent of the
  pattern's structure. Classic "catastrophic" *regular* shapes (`(a+)+$`,
  `(a*)*$`, `(.*)*$`) compile and run linearly; they are **not** rejected, and
  they do **not** backtrack.
- **Non-regular patterns are bounded, never unbounded.** Backreferences,
  lookaround, and lazy-with-end-anchor run on a tree backtracker under an
  explicit step budget (`8000 + (len+1)·4000`) plus a recursion-depth guard
  (`MAX_DEPTH = 16384`). Exceeding the budget returns a typed
  `error.MatchBudgetExceeded` at match time — the .NET-style runtime contract,
  never a hang.

`findAll`, `count`, and the lazy `iterator` make a single linear pass over the
input — there is no per-match restart of the engine.

---

## Why Zeetah is fast

Speed comes from picking the right machine for the pattern and skipping work
before the automaton ever runs. The two layers below correspond to the two
routing layers of the meta engine.

### Specialized executors (Layer 1 dispatch)

For many common shapes, Zeetah avoids stepping an automaton entirely:

| Executor | Chosen for | Why it's fast |
|----------|-----------|---------------|
| **literal** | a single literal or an exact literal alternation (`cat\|dog\|bird`) | SIMD substring / Teddy multi-literal scan — no automaton at all |
| **lit_prefix** | a literal prefix ≥ 3 bytes, unanchored (`hello.*world`) | Teddy-locate the prefix, then verify with an anchored DFA only at candidates |
| **reverse_suffix** | a selective trailing literal, weak prefix | the suffix is a sound fast-negative; the forward DFA runs only where the suffix occurs |
| **dfa** | the general regular case | eager DFA table walk (`Dfa256`): one table lookup per byte |
| **dense_search** | a bare unanchored DFA of narrow shape (`min_len ≥ 4`, ≤ 16 start bytes, no required literal, not lazy) | a frozen dense single-pass unanchored DFA — no restart loop |
| **lazy_dfa** | when the eager DFA would exceed its state ceiling | the same subset construction, built on demand and **bit-identical** — never a fallback to backtracking |
| **class_span** | one greedy single contiguous-range `class+` / `class*` | a SIMD member-run scan, no automaton |
| **boundary_lits** | `\b(?:kw1\|kw2\|…)\b` keyword alternations | Aho-Corasick locate + O(1) `\b` verification |
| **bt_look** | plain look-assertions (`\b`, `\B`, mid-pattern `^`/`$`, `(?m)`) | bounded backtracker (the DFA does not fold look-assertions) |
| **backtrack** | lookaround / backreferences | HIR tree backtracker with a `seek` prefilter + concat-internal regular "island" delegation |
| **split_alt** | a top-level alternation mixing regular and non-regular branches | regular branches → anchored DFAs, the rest → the tree backtracker |
| **dup_word** | the adjacent-duplicate-word shape `(\b\w+\b)\s+\1` | a single O(n) linear scan, no backtracking |

### Prefilters — skipping work before the automaton

Before (or instead of) running an automaton, Zeetah tries to prove large
regions of the input cannot contain a match:

- **Required byte** — a single byte every accepting path must consume. If a
  `memchr` finds none, the answer is "no match" in one pass.
- **Required literal anywhere** — a rare mandatory literal plus a recipe to
  recover the match start; drives a `memchr` instead of a broad restart loop.
- **First-byte SIMD set** — a 256-bit start-byte set scanned with `@Vector`
  (specialized to single-byte / multi-equality / range / bitset forms).
- **Teddy** — a SIMD multi-substring locator (≤ 8 needles, adaptive nibble
  masks) backing the `literal` / `lit_prefix` / `reverse_suffix` executors.
- **Aho-Corasick** — a multi-keyword locator backing the `boundary_lits`
  executor.
- **Seek** — a regular over-approximation that skips proven-dead prefixes for
  the backtracking tier.

These are portable `@Vector` kernels: NEON on Apple Silicon / ARM, SSE2/AVX2 on
x86, with a scalar fallback — no per-target branches in the source.

### Comptime-baked patterns (`Pattern`)

For a pattern known at compile time, [`Pattern`](../README.md#compile-time-patterns)
runs the *entire* parse → NFA → DFA (+minimize) pipeline at **compile time** and
bakes the matcher into `.rodata`. There is no allocator, no runtime compilation,
and no instance — just static methods on a type. Pure-literal patterns bake a
comptime Teddy scan instead of a DFA table. This moves all construction cost out
of the run and is the reason the planner is a pure, haystack-free function (see
Layer 2 below).

### The capture-free fast path

`find`, `isMatch`, and `findAll` return only the whole-match span
(`slice` / `start` / `end`); `match.groups.len == 0` even when the pattern has
groups. Skipping submatch reconstruction keeps these on the automaton fast path
with no allocation. Submatch slices are **opt-in** via `captures(allocator, …)`,
which uses the bounded-backtracking capture path (`bounded_bt`) — itself
strictly O(n·m) via a `(state, pos)` visited bitset, never exponential.

### Layer 2 — the planner

The regular-tier routing decision is a pure function
`plan(properties, flags) → Strategy` that never reads the haystack. Because it
is haystack-free it is comptime-evaluable, which is what lets `Pattern` make the
same routing decision at compile time. It returns one of five strategies
(`.literal`, `.prefix_prefilter`, `.reverse_suffix`, `.core`, and a `.backtrack`
sentinel for non-regular patterns, which Layer 1 has already intercepted).

---

## Performance characteristics

### Time

- **Regular patterns**: linear in the input length per scan, O(n). The DFA
  table walk is one lookup per input byte and is independent of the pattern's
  structural complexity once compiled. Prefilters can make the practical cost
  *sublinear* when most of the input is skippable (e.g. a rare required byte).
- **`findAll` / `count` / `iterator`**: a single linear pass — input ×k scales
  the time ≈ ×k, not ×k² (no per-match restart).
- **Non-regular patterns** (backreferences / lookaround / lazy-with-end-anchor):
  run on the backtracker bounded by the step budget above; worst case is capped
  by that budget rather than the input size, and is reported as
  `error.MatchBudgetExceeded` rather than as a hang.

### Space

- **Compiled `Regex`**: the chosen executor's tables (a DFA, a Teddy/AC table,
  or a literal set) plus the parsed program; persistent for the life of the
  `Regex`.
- **Construction ceilings** bound how large a pattern can be built: NFA states
  256, NFA edges 2048, DFA states 256, HIR nodes 4096, capture groups 32.
  Overflowing any of these raises `error.PatternTooComplex` at **compile** time.
- **Match results**: a `Match` is a borrowed view — `slice` aliases the input,
  nothing is copied. `find` / `findAll` / `iterator` results carry no owned
  groups (their `deinit` is a no-op). Only `captures` allocates a `groups`
  slice, and only `findAll` / `split` allocate a result slice.

### Greedy / leftmost-first semantics

Matching is leftmost-first (Perl / RE2 / Rust order). Greedy quantifiers still
match maximally:

```zig
// Pattern: a*  over input "aaa"  ->  matches all three 'a's (not 0, 1, or 2).
```

Lazy quantifiers (`*?`, `+?`, `??`, `{m,n}?`) build a regular automaton like
their greedy peers — laziness is just the ε-priority order the subset
construction preserves. The single exception is **lazy combined with an
end-anchor** (`a*?$`), which routes to the tree backtracker (still
leftmost-first) and cannot be baked by the comptime `Pattern` path.

---

## Pattern-shape guide

A rough mental model of where each shape lands. The exact executor is chosen by
the meta engine; this is a guide to expectations, not a contract.

### Fastest — no automaton

- **Plain literals** (`hello`, `error:`): SIMD substring / Teddy scan.
- **Exact literal alternations** (`cat|dog|bird`): one Teddy multi-literal scan.
- **`\b`-delimited keyword alternations** (`\b(?:GET|POST|PUT)\b`):
  Aho-Corasick locate + O(1) boundary check.
- **A single contiguous class repeat** (`[0-9]+`, `[a-z]*`): SIMD member-run
  scan via `class_span`.
- **Patterns with a rare required byte or literal**: a `memchr`-driven prefilter
  skips most of the input before any matching.

### Fast — compiled DFA, one lookup per byte

- **General regular patterns** (`\d{3}-\d{4}`, `[A-Z][a-z]+`, anchored shapes):
  the `dfa` / `dense_search` executors.
- **Literal-prefixed unanchored patterns** (`hello.*world`): `lit_prefix`
  locates the prefix, then verifies only there.
- **Comptime-known patterns**: the DFA is already baked into `.rodata`; only the
  search runs.

### Bounded — the backtracker (linear-time *not* guaranteed by construction)

- **Lookahead / lookbehind** (`(?=…)`, `(?<=…)`): step-budgeted; runs on the
  backtracker (at runtime, and baked into `.rodata` under the comptime `Pattern`).
- **Backreferences** (`\1`, `\k<name>`): step-budgeted (runtime + comptime); the
  `dup_word` recognizer handles the adjacent-duplicate-word special case in a
  single linear scan instead.
- **Lazy with an end-anchor** (`a*?$`): routes to the backtracker.

These return `error.MatchBudgetExceeded` if they exceed the step/depth budget,
so their worst case is a typed error, not a runaway.

> **Note:** "nested quantifiers" like `(a+)+$` are *regular* and compile to a
> linear DFA — they are **not** a slow or rejected shape in Zeetah, unlike in
> classic backtracking engines.

---

## Optimization tips

### 1. Compile once, reuse many times

```zig
// Good: compile once, then match many inputs.
var re = try Regex.compile(allocator, pattern);
defer re.deinit();
for (inputs) |input| {
    _ = try re.isMatch(input);
}
```

Compilation (parse → NFA → DFA) is far more expensive than a single match, so a
hot loop should reuse a compiled `Regex`. For a comptime-known pattern, prefer
[`Pattern`](../README.md#compile-time-patterns) — compilation then happens at
build time and the run pays nothing for it.

### 2. Use `isMatch` for boolean checks

```zig
if (try re.isMatch(input)) {
    // ...
}
```

`isMatch` can stop at the first accepting position and never reconstructs a
match span or allocates.

### 3. Don't reach for `captures` unless you need submatches

`find` / `isMatch` / `findAll` take the capture-free fast path. Only call
`captures` when you actually need group slices — it uses the bounded-backtracking
capture path and allocates a `groups` slice you must `deinit`.

### 4. Anchor when the pattern is truly anchored

```zig
// Anchored: the engine does not retry every start position.
var re = try Regex.compile(allocator, "^\\d+$");
```

An anchored pattern lets the engine reject non-matching starts immediately
instead of scanning every offset.

### 5. Prefer character classes to single-character alternation

```zig
// Prefer:  a single class test
var re = try Regex.compile(allocator, "[abc]");
// over:    an alternation of single characters
// var re = try Regex.compile(allocator, "a|b|c");
```

A class is an O(1) bitmap membership test per byte; the engine also recognizes a
single contiguous class repeat as the SIMD `class_span` fast path.

---

## Memory & lifetime

A `Match` is a borrowed view, not an owned copy:

- `match.slice` (and every `Group.slice`) aliases the original `input` — valid
  only while that input *and* the source `Regex` are alive. Nothing is copied.
- `find` / `findAll` / `iterator.next` results have an empty, non-owned
  `groups`, so `match.deinit(allocator)` is a **no-op** (harmless to call).
- A **`captures`** result owns its `groups`, so `defer match.deinit(allocator)`
  is **required** to avoid a leak.
- `findAll` returns an allocator-owned `[]Match`; free the slice with
  `allocator.free`. `split` returns an allocator-owned `[][]const u8` whose
  element slices alias the input — free the outer slice only.

Every heap allocation goes through the allocator you pass; for batch work an
arena allocator amortizes the per-call cost of `captures` / `findAll` / `split`.

---

## The comparison harness

A local cross-engine harness lives under
[`benchmarks/comparison/`](../benchmarks/comparison/). **It is not committed to
the repository** (the directory and its generated outputs are git-ignored), and
there is **no `zig build bench` step** — the only build steps are `test` and
`parity`. To run it you reproduce it locally:

```bash
./benchmarks/comparison/run_all.sh
```

The driver is idempotent: it ensures the toolchains/sources it needs (RE2 via
Homebrew, a pinned vendored mvzr, a local git-ignored Python `.venv` with the
PyPI `regex` module), generates a deterministic 1 MiB corpus, builds and runs
each engine's harness, then aggregates the results.

### Engines compared

| Engine | What it is |
|--------|-----------|
| **Zeetah** | this library — runtime meta engine and the comptime DFA path |
| **[mvzr](https://github.com/mnemnion/mvzr)** | a small zero-allocation Zig regex VM |
| **RE2** (Google) | a linear-time DFA/automata engine |
| **Rust `regex`** | the Rust standard regex crate (finite-automata, linear) |
| **[fancy-regex](https://github.com/fancy-regex/fancy-regex)** | the Rust look-around/backreference engine used by OpenAI's `tiktoken` and BPE trainers |
| **.NET `Regex`** | `System.Text.RegularExpressions`, the default backtracking engine |
| **Python stdlib `re`** | CPython's built-in regex module |
| **PyPI `regex`** | Python's de-facto Unicode-aware regex module (what tokenizer/BPE code actually uses) |

### Methodology

- **Same operation, byte-identical input.** Every engine runs the *same*
  workload — count all leftmost, non-overlapping matches — over identical bytes
  from the deterministic corpus.
- **Compile and search are timed separately**, in their own loops, so
  construction cost is not conflated with match cost.
- **Reported value is a median** of a loop sized to run for at least ~50 ms
  (roughly 5–500 iterations depending on the workload). Zeetah's harness uses
  libc for timing/IO because Zig 0.16 reworked `std.Io` / `std.time`.
- **Input sizes** scale corpus slices up to 1 MiB, which is where the linear
  single-pass behavior of `findAll` / `count` is visible (×k input ≈ ×k time).
- **A correctness gate runs before any timing is trusted.** The aggregator fails
  the run if match counts disagree across engines for any non-pathological
  workload — so the timings only ever compare engines that produce identical
  results.

### Workload set

The harness spans a wide spread of real and synthetic shapes:

- **Fundamentals:** literal, quantifier, digits, `\w+`, alternation.
- **Typical real-world:** email, URI, IPv4, HTML title/href/tag, price, NLTK,
  SSN, ModSecurity SQLi, AWS ENI, Apache POST, k8s/Fluentd log line, ISO date,
  24-hour time, US phone, hex color, UUID, MAC address, semver, credit-card
  group, log level, hashtag.
- **Edge but real:** scientific float, JSON string, base64, unix path, deep
  keyword alternation, and a `foo.*bar.*baz` wildcard-gap shape.
- **Feature-heavy edge:** a backreference duplicate-word `(\b[A-Za-z]+\b) \1`, a
  `(?<=\$)` look-behind amount, a `\p{L}` Unicode-property class, and an
  atomic-group shape. Engines that cannot express a feature emit `REJECTED`
  rather than a fabricated number — for instance the base Rust `regex` crate,
  RE2, mvzr, and Python's stdlib `re` reject the look-around / `\p{}` workloads,
  which is exactly the point of including them.
- **Motivating:** a real GPT-4 `cl100k_base` tokenizer pre-tokenizer regex
  (inline `(?i:)`, `\p{…}`, and a `(?!\S)` look-around), plus a `(a+)+b`
  pathological case.

### GPT-4 tokenizer workload

The tiktoken `cl100k_base` pre-tokenizer regex uses possessive quantifiers
(`?+`/`++`), which Zeetah rejects (possessive ≠ greedy in general — see the
feature table). For this regex the possessive operators are **provably
equivalent to plain greedy**, because each possessive class is disjoint from
whatever follows it (so the engine never backtracks into it):

- `[^\r\n\p{L}\p{N}]?+\p{L}+` — the optional class excludes letters, `\p{L}+`
  requires them.
- `[^\s\p{L}\p{N}]++[\r\n]*` — the `+` class excludes whitespace, `[\r\n]*` is
  whitespace.

So Zeetah runs a **greedy-rewritten variant** that yields the identical
segmentation. It is a committed, self-contained workload (no external engines
needed):

```bash
zig build bench-tokenizer   # throughput over an embedded corpus
zig build test              # correctness gate: pre-token boundaries
```

The correctness gate (`tools/bench_tokenizer.zig`) asserts the exact pre-token
boundaries for every alternation branch (contractions, words, numbers,
punctuation runs, the two-space rule), so the segmentation can't silently drift.
(Zeetah's `\p` is the Latin-1 byte restriction, so the boundaries match the
reference cl100k exactly on ASCII/Latin-1 text; multibyte UTF-8 is matched
per-byte — see the README Unicode note.)

---

## Profiling Zeetah

To profile a build of your own program that imports `zeetah`, compile in a
release mode and attach your platform's profiler:

```bash
zig build -Doptimize=ReleaseFast   # build your importing program

# macOS
instruments -t "Time Profiler" ./zig-out/bin/<your-exe>

# Linux
perf record ./zig-out/bin/<your-exe>
perf report
```

There is no Zeetah-provided profiling binary; the engine's internal profiling
hooks are not part of the public API.

---

## Reporting performance issues

If a pattern is unexpectedly slow:

1. **Identify the shape.** Is it a regular pattern (DFA tier) or a non-regular
   one (backtracker tier — lookaround / backreference / lazy-with-end-anchor)?
   The two tiers have very different cost models.
2. **Simplify.** Does a reduced version still reproduce the slowness?
3. **Separate compile from match.** Time `compile` and the match loop
   independently — a one-off compile cost is not a match-throughput problem.
4. **Check input size and shape.** Linear-time still scales with input; a
   pathological *input* (one enormous matching run) stresses different code than
   a pathological pattern.
5. **Open an issue** with a minimal reproduction at
   [GitHub Issues](https://github.com/zig-utils/zig-regex/issues).

---

**Library:** Zeetah · **Zig:** 0.16+ · See also the
[README](../README.md), [Architecture](ARCHITECTURE.md), and
[API Reference](API.md).
