# Architecture

Zeetah is not a single regular-expression matcher with a few optimizations
bolted on. It is a **meta engine**: at `compile` time it analyzes the pattern
and *routes* it to the cheapest executor that is still correct. A pure literal
becomes a SIMD substring scan; a general regular pattern becomes a compiled DFA
table walk that runs in **O(n)** per scan; only patterns that no finite
automaton can express — lookaround and backreferences — fall back to a bounded
backtracker. You call one API; the engine picks the machine.

This document describes that engine: its pipeline, the two layers of routing,
the prefilters, the safety contract, and the split between compile-time and
runtime use.

> **Note on terminology.** Zeetah builds a Thompson NFA as an *intermediate
> construction step* on the way to a DFA. It does **not** match by simulating
> the NFA with a thread pool / Pike VM. Regular patterns match by walking a
> compiled deterministic-finite-automaton transition table, one table lookup
> per input byte. Earlier revisions of this document described a thread-based
> NFA simulation with `O(n·m)` matching; that is no longer how the engine works.

## Design goals

1. **Linear-time core.** Every regular pattern matches in time linear in the
   input. Classic "catastrophic" *regular* shapes such as `(a+)+$`, `(a*)*$`,
   and `(.*)*$` compile and run linearly — they are not rejected.
2. **Bounded by design.** Patterns that genuinely require backtracking
   (backreferences, lookaround, lazy-with-end-anchor) run under an explicit
   step budget and return a typed `error.MatchBudgetExceeded` rather than hanging.
3. **Pay for what you use.** `find` / `isMatch` / `findAll` return whole-match
   spans with no allocation; capture-group slices are opt-in via `captures`.
4. **Compile-time when possible.** The routing decision for the regular tier is
   a pure function of the pattern, so for a comptime-known pattern the entire
   parse → NFA → DFA pipeline can run at compile time and bake the matcher into
   `.rodata`.
5. **Zero dependencies, explicit allocation.** Only the Zig standard library;
   every heap allocation goes through the allocator the caller passes.

## The pipeline

```
  pattern string
        │
        ▼
  ┌───────────────┐
  │   parser     │  recursive-descent parser; emits HIR directly.
  │ (parser.zig) │  NO separate lexer, NO AST stage.
  └───────┬───────┘
          │ HIR
          ▼
  ┌───────────────┐
  │      HIR      │  flat, indexed high-level IR (hir.zig). The single
  │   (hir.zig)   │  shared representation analyzed by properties.zig.
  └───────┬───────┘
          │
          ├──────────────► properties.analyze(HIR)  ──► Properties
          │                (pure pass: prefix/suffix literals, anchoring,
          │                 required byte, regular-vs-not, …)
          ▼
  ┌───────────────┐
  │ Thompson NFA  │  thompson.build(HIR) → NFA fragments wired with
  │ (thompson.zig)│  ε-transitions. An INTERMEDIATE step only.
  └───────┬───────┘
          │ NFA
          ▼
  ┌───────────────┐
  │  DFA / execs  │  subset construction + minimization → Dfa256 table,
  │   (src/exec)  │  or a non-DFA executor selected by the dispatcher.
  └───────┬───────┘
          │
          ▼
  ┌───────────────┐
  │   regex.zig   │  runtime façade: compile, find, isMatch, captures, …
  │  pattern.zig  │  comptime façade: Pattern(...) baked into .rodata
  └───────────────┘
```

Key points:

- **There is no AST.** The parser (`parser.zig`) produces **HIR** (`hir.zig`)
  directly — a flat, index-addressed high-level IR. Everything downstream
  (analysis, NFA construction, the planner) reads HIR.
- **The NFA is a construction artifact.** `thompson.zig` lowers HIR to a
  Thompson NFA with ε-transitions. That NFA is then turned into a DFA by subset
  construction (in `src/exec/`); it is *not* simulated thread-by-thread at match
  time.
- **`properties.analyze` is a pure pass over HIR.** It extracts everything the
  routing decision needs — leading/trailing literal sequences, anchoring, a
  required byte, whether the pattern is regular at all — without ever touching a
  haystack. This is what makes comptime routing possible.

## Two layers of routing

`compile` makes its decision in two layers. Layer 1 is the runtime dispatcher
that picks among ~12 concrete executors; Layer 2 is the pure planner that makes
the regular-tier sub-decision shared with the compile-time path.

### Layer 1 — the runtime dispatcher (`regex.zig`)

`Regex.compileWithFlags` classifies the analyzed pattern and selects one of
twelve executors, tracked by the private enum `MetaKind`:

```zig
const MetaKind = enum {
    literal, dfa, lit_prefix, reverse_suffix, bt_look, backtrack,
    split_alt, lazy_dfa, dense_search, class_span, boundary_lits, dup_word,
};
```

| `MetaKind` | Chosen when | How it runs | Backing code |
|------------|-------------|-------------|--------------|
| `literal` | a single literal, or an exact literal alternation (`cat\|dog\|bird`) | SIMD substring / Teddy multi-literal scan — **no automaton** | `prefilter.zig` |
| `lit_prefix` | a literal prefix ≥ 3 bytes, unanchored (`hello.*world`) | Teddy-locate the prefix, then verify with an anchored DFA | `exec/delegate.zig`, `exec/dfa.zig` |
| `reverse_suffix` | a selective trailing literal but a weak prefix | use the suffix as a sound fast-negative (no occurrence ⇒ no match), then a forward DFA | `exec/dfa.zig` |
| `dfa` | the general regular case | eager DFA table walk (`Dfa256`) | `exec/dfa.zig`, `exec/full_dfa.zig` |
| `dense_search` | a bare unanchored DFA of narrow shape (`min_len ≥ 4`, ≤ 16 start bytes, no required literal, not lazy) | a *frozen* dense single-pass unanchored DFA (one sweep, no per-position restart) | `exec/dfa.zig` |
| `lazy_dfa` | the eager DFA would exceed its state ceiling | the **same** subset construction, evaluated on demand and memoized — bit-identical results | `exec/lazy_dfa.zig` |
| `class_span` | one greedy single contiguous-range `class+` / `class*` | SIMD member-run scan, no automaton | `exec/class_span.zig` |
| `boundary_lits` | `\b(?:kw1\|kw2\|…)\b` keyword alternations | Aho-Corasick locate + O(1) `\b` verify | `exec/seq_extract.zig`, `prefilter.zig` |
| `bt_look` | plain look-assertions (`\b`, `\B`, mid-pattern `^`/`$`, `(?m)` anchors) | bounded backtracker (the DFA does not fold look-assertions) | `exec/bounded_bt.zig` |
| `backtrack` | lookaround / backreferences | HIR-tree backtracker, with a `seek` over-approximation prefilter and concat-internal regular "island" delegation | `exec/backtrack.zig`, `exec/seek.zig`, `exec/delegate.zig` |
| `split_alt` | a top-level alternation mixing regular and non-regular branches | regular branches → anchored DFAs, the rest → tree backtracker | `exec/split_alt.zig` |
| `dup_word` | the adjacent-duplicate-word shape `(\b\w+\b)\s+\1` | a single O(n) linear scan | `exec/dupword.zig` |

The first eight rows are the regular tier — they are pure finite automata or
literal scans, and every one of them is linear in the input. The last four
(`bt_look`, `backtrack`, `split_alt`, `dup_word`) are the non-regular and
hybrid tiers; `split_alt` and `dup_word` are linear by construction, while
`bt_look` and `backtrack` are governed by the step budget described below.

### Layer 2 — the planner (`planner.zig`)

The regular-tier sub-decision is a **pure function** that never reads the
haystack:

```zig
pub fn plan(p: Properties, flags: Flags) Strategy { ... }
```

Because `plan` consumes only the `Properties` derived from the pattern (and the
`case_insensitive` flag), it is fully comptime-evaluable — this is exactly why
the compile-time `Pattern` path can reuse it. It returns a five-variant
`Strategy` union:

```zig
pub const Strategy = union(enum) {
    literal: Seq,                                          // pure literal(s)
    prefix_prefilter: struct { seq: Seq, first_byte_set: ?[32]u8 },
    reverse_suffix: Seq,                                   // necessary suffix
    core,                                                  // the eager DFA
    backtrack,                                             // sentinel only
};
```

`Strategy` is the regular-tier vocabulary; the twelve-variant `MetaKind` is the
real, full taxonomy that `regex.zig` works in. The `.backtrack` variant is a
sentinel: non-regular patterns are intercepted by `regex.zig` *before* `plan` is
ever consulted, so `plan` returning `.backtrack` never reaches the dispatch hot
path. The `.literal`, `.prefix_prefilter`, `.reverse_suffix`, and `.core`
variants map onto the corresponding `MetaKind` executors; the dispatcher refines
`.core` further (into `dfa`, `dense_search`, `lazy_dfa`, `class_span`, etc.)
using runtime-only information such as the eager DFA's actual state count.

## Prefilters

Before — or instead of — running an automaton, Zeetah tries to skip work. The
prefilters live in `prefilter.zig` (plus the seek/locate helpers in `src/exec`):

- **Required byte.** A single byte that *every* accepting path must consume. If
  one `memchr` over the input finds none, the answer is "no match" in a single
  pass with no automaton step.
- **Required literal anywhere.** A rare mandatory literal plus a start-recovery
  recipe; this drives a `memchr` to candidate positions instead of a broad
  per-position restart loop. (Look-aware variants exist for a leading
  fixed-width lookbehind, e.g. `(?<=X)…`.)
- **First-byte SIMD set.** A 256-bit set of possible start bytes, scanned with
  `@Vector`, specialized to single-byte / multi-equality / contiguous-range /
  full-bitset shapes.
- **Teddy.** A SIMD multi-substring locator (≤ 8 needles, adaptive nibble
  masks). It backs the `literal`, `lit_prefix`, and `reverse_suffix` executors.
- **Aho-Corasick.** A multi-keyword locator that backs the `boundary_lits`
  executor (`\b`-fenced keyword alternations).
- **Seek.** A *regular over-approximation* of a non-regular pattern that skips
  proven-dead prefixes; it is the prefilter for the backtracking tier.

Prefilters are sound by construction: they may admit false positives (which the
real executor then rejects) but never false negatives, so they can only narrow
the search, never change the match result.

## Safety and the ReDoS contract

Zeetah's linear-time guarantee is precise about *which* patterns receive it.
There are three distinct regimes.

### Regular patterns — linear by construction

A regular pattern matches by a DFA table walk: **O(n) per scan**, one transition
lookup per input byte, no backtracking and no thread fan-out. If the *eager* DFA
would exceed its state ceiling during construction, the engine falls back to the
**lazy DFA** (`exec/lazy_dfa.zig`) — the identical subset construction, built
incrementally and memoized so that results are bit-identical to the eager table.
The fallback is *never* to a backtracker.

Consequently the classic "catastrophic" *regular* shapes are not catastrophic
here. `(a+)+$`, `(a*)*$`, and `(.*)*$` **compile and run linearly**; they are
**not** rejected at compile time.

```zig
// A "catastrophic" REGULAR pattern: compiles and runs as a linear DFA.
var re = try zeetah.Regex.compile(allocator, "(a+)+$");
defer re.deinit();
_ = try re.isMatch("aaaaaaaaaaaaaaaaX"); // fast, linear — no error, no hang
```

### Non-regular patterns — bounded step budget

Patterns that no finite automaton can express — backreferences, lookaround, and
lazy combined with an end-anchor (`a*?$`) — run on the HIR-tree backtracker
(`exec/backtrack.zig`). The backtracker is governed by an explicit **step
budget** scaled to the input plus a **recursion-depth guard**:

```zig
self.budget = 8000 + @as(u64, input.len + 1) * 4000; // O(n) work bound
const MAX_DEPTH: u32 = 16_384;                         // CPS recursion guard
```

When either bound is exceeded the matcher returns a typed
`error.MatchBudgetExceeded` at **match time** — the .NET-style runtime contract.
It never spins indefinitely. (This is distinct from the compile-time
`error.PatternTooComplex` below.)

```zig
// Non-regular catastrophe (the loop is inside a lookahead): bounded at match time.
var re = try zeetah.Regex.compile(allocator, "(?=(a+)+$)a");
defer re.deinit();
_ = re.isMatch("aaaaaaaaaaaaaaaaaaaaaaaaX") catch |e| switch (e) {
    error.MatchBudgetExceeded => {}, // budget exceeded -> typed error, not a hang
    else => return e,
};
```

The bounded-backtracking **capture path** (`exec/bounded_bt.zig`) is stricter
still: it tracks a `(state, position)` visited bitset, making it strictly
`O(n·m)` — never exponential.

### Construction ceilings — bounded at compile

To keep construction itself bounded, the engine enforces fixed ceilings while
building a pattern. A pattern too large to build raises `error.PatternTooComplex`
at **compile time** (not match time):

| Ceiling | Value | Source |
|---------|-------|--------|
| NFA states | 256 | `thompson.MAX_NFA` |
| NFA edges | 2048 | `thompson.MAX_EDGES` |
| DFA states | 256 | internal `MAX_DFA` |
| HIR nodes | 4096 | `hir.MAX_NODES` |
| Capture groups | 32 | `hir.MAX_GROUPS` |

These are deliberate, conservative limits rather than dynamic budgets; raising
them is an engine-design decision, not a per-call option.

## Compile-time vs. runtime

The same pipeline drives two front ends.

### Runtime — `regex.zig` / `zeetah.Regex`

`Regex.compile` (and `compileWithFlags`) run the full
parse → HIR → analyze → NFA → DFA/executor pipeline at run time, heap-allocating
the chosen executor through the caller's allocator. This is the general path:
it supports the entire feature set, including the non-regular tiers (lookaround,
backreferences, lazy-with-end-anchor) that route to the backtracker.

### Compile-time — `pattern.zig` / `zeetah.Pattern`

```zig
const Phone = zeetah.Pattern("[0-9]{3}-[0-9]{4}", .{});
// Phone.isMatch(...), Phone.find(...) -> static methods, no allocator, no deinit
```

`Pattern(comptime pattern, comptime opts)` runs the **whole**
parse → NFA → DFA (+ minimize) pipeline *at compile time* and bakes the matcher
into `.rodata`. A pure-literal pattern bakes a comptime Teddy scan instead of a
DFA table. The result is a **type** with **static** methods — no instance, no
allocator, no `deinit`. This is possible precisely because `planner.plan` and
`properties.analyze` never read a haystack.

`PatternOptions` controls the comptime build:

```zig
pub const Options = struct {
    max_dfa_states: usize = 256, // soft budget; bounded by the internal MAX_DFA ceiling
    on_oversize: enum { compile_error, allow_oversized } = .compile_error,
    case_insensitive: bool = false,
};
```

`on_oversize = .allow_oversized` bakes a DFA that exceeds `max_dfa_states` but is
still within the internal ceiling; it does **not** rescue a pattern that blows
the ceiling or uses an unsupported feature (no comptime → runtime fallback).

The comptime path is **capture-free** and covers only the regular,
DFA-representable subset (including Latin-1 `\p`, whose resolver is
allocator-free). The following are a **hard `@compileError`** — there is no
runtime fallback baked into a `Pattern`:

- captures with submatch extraction,
- lookaround,
- backreferences,
- look-assertions (`\b`, `\B`, mid-pattern `^`/`$`, `(?m)` anchors),
- `\p` under `(?i)`,
- lazy combined with an end-anchor (`a*?$` — it now routes to the backtracker,
  which is unavailable at comptime),
- patterns exceeding the DFA ceiling.

For any of those, use the runtime `Regex`.

## Module map

| Module | Role |
|--------|------|
| `parser.zig` | recursive-descent parser; emits HIR (no lexer, no AST) |
| `hir.zig` | flat indexed high-level IR; construction ceilings (`MAX_NODES`, `MAX_GROUPS`) |
| `properties.zig` | pure analysis pass over HIR → `Properties` |
| `planner.zig` | pure `plan(properties, flags) → Strategy` (comptime-evaluable) |
| `thompson.zig` | HIR → Thompson NFA (intermediate); NFA ceilings (`MAX_NFA`, `MAX_EDGES`) |
| `regex.zig` | runtime façade + Layer-1 dispatcher (`MetaKind`) |
| `pattern.zig` | comptime façade (`Pattern`, `PatternOptions`) |
| `prefilter.zig` | required-byte / required-literal / first-byte-SIMD / Teddy / Aho-Corasick |
| `exec/dfa.zig`, `exec/full_dfa.zig`, `exec/dfa_build.zig` | eager DFA construction + table walk (`Dfa256`) |
| `exec/lazy_dfa.zig` | on-demand subset construction (DFA-ceiling fallback) |
| `exec/class_span.zig` | SIMD single-range `class+`/`class*` scan |
| `exec/seq_extract.zig` | boundary-literal / keyword extraction (`boundary_lits`) |
| `exec/backtrack.zig`, `exec/bounded_bt.zig` | HIR-tree backtracker (+ bounded capture path) |
| `exec/seek.zig` | regular over-approximation prefilter for the backtracking tier |
| `exec/delegate.zig` | regular-island delegation into the backtracker |
| `exec/split_alt.zig` | mixed regular/non-regular top-level alternation |
| `exec/dupword.zig` | adjacent-duplicate-word linear recognizer |
| `exec/onepass.zig`, `exec/charclass.zig`, `exec/core.zig` | shared execution helpers |
| `unicode_class.zig`, `unicode_tables.zig` | Latin-1 `\p` General_Category resolution |
| `match.zig`, `common.zig`, `errors.zig`, `builder.zig` | `Match`/`Group`, shared types/flags, `RegexError`, fluent builder |

## References

- Thompson, Ken (1968). *Programming Techniques: Regular Expression Search Algorithm.*
- Cox, Russ (2007). *Regular Expression Matching Can Be Simple And Fast.*
- **RE2** (Google) — the finite-automaton, linear-time-by-construction philosophy
  and the literal/prefilter routing that the meta engine generalizes.
- **Rust `regex` crate** — API design and prefilter strategy (Teddy, required
  literals, lazy DFA) reference.

---

See also: [README](../README.md) · [API Reference](API.md) ·
[Examples](EXAMPLES.md) · [Advanced Features](ADVANCED_FEATURES.md) ·
[Performance Guide](BENCHMARKS.md)
