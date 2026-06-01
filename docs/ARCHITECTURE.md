# Architecture

Zeetah is not a single regular-expression matcher with a few optimizations
bolted on. It is a **meta engine**: at `compile` time it analyzes the pattern
and *routes* it to the cheapest executor that is still correct. A pure literal
becomes a SIMD substring scan; a general regular pattern becomes a compiled DFA
table walk that runs in **O(n)** per scan; only patterns the DFA cannot express
or fold — lookaround, backreferences, atomic groups — fall back to a bounded
backtracker. You call one API; the engine picks the machine.

This document describes that engine: its pipeline, the two layers of routing,
the prefilters, the safety contract, the split between compile-time and runtime
use, and the **design decisions** (and roads deliberately not taken) behind the
shape it has today.

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
   (backreferences, lookaround, atomic groups, lazy-with-end-anchor) run under
   an explicit step budget and return a typed `error.MatchBudgetExceeded` rather
   than hanging.
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
| `literal` | a single literal, or an exact literal alternation (`cat\|dog\|bird`) | SIMD substring / Teddy multi-literal scan — **no automaton** | `exec/core.zig`, `prefilter.zig` |
| `lit_prefix` | a literal prefix ≥ 3 bytes, unanchored (`hello.*world`) | Teddy-locate the prefix, then verify with an anchored DFA | `exec/core.zig` → `exec/search.zig`, `prefilter.zig` |
| `reverse_suffix` | a selective trailing literal but a weak prefix | use the suffix as a sound fast-negative (no occurrence ⇒ no match), then a forward DFA | `exec/core.zig`, `prefilter.zig`, `exec/full_dfa.zig` |
| `dfa` | the general regular case | eager DFA table walk (`Dfa256`) | `exec/core.zig`, `exec/full_dfa.zig`, `exec/dfa_build.zig` |
| `dense_search` | a bare unanchored DFA of narrow shape (`min_len ≥ 4`, ≤ 16 start bytes, no required literal, not lazy) | a *frozen* dense single-pass unanchored DFA (one sweep, no per-position restart) | `exec/dense_search.zig` |
| `lazy_dfa` | the eager DFA would exceed its state ceiling | the **same** subset construction, evaluated on demand and memoized — bit-identical results | `exec/lazy_dfa.zig`, `exec/lazy_memo.zig` |
| `class_span` | one greedy single contiguous-range `class+` / `class*` | SIMD member-run scan, no automaton | `exec/class_span.zig` |
| `boundary_lits` | `\b(?:kw1\|kw2\|…)\b` keyword alternations | Aho-Corasick locate + O(1) `\b` verify | `exec/seq_extract.zig`, `prefilter.zig` |
| `bt_look` | plain look-assertions (`\b`, `\B`, mid-pattern `^`/`$`, `(?m)` anchors) | bounded backtracker (the DFA does not fold look-assertions) | `exec/bounded_bt.zig` |
| `backtrack` | lookaround / backreferences / atomic groups (incl. possessive quantifiers, which lower to atomic groups) | HIR-tree backtracker, with a `seek` over-approximation prefilter and concat-internal regular "island" delegation | `exec/backtrack.zig`, `exec/seek.zig`, `exec/delegate.zig` |
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
the compile-time `Pattern` path can reuse it. Its very first test is
`if (p.requires_backtracking) return .backtrack;`. It returns a five-variant
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

Patterns the DFA cannot express or fold — backreferences, lookaround, atomic
groups (including possessive quantifiers), and lazy combined with an end-anchor
(`a*?$`) — run on the HIR-tree backtracker (`exec/backtrack.zig`). The
backtracker is governed by an explicit **step budget** scaled to the input plus
a **recursion-depth guard**:

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
`O(n·m)` — never exponential. The two backtrackers are deliberately separate
(see [Design decisions](#design-decisions--roads-not-taken)).

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
them is an engine-design decision, not a per-call option. (The comptime
`Pattern` path applies a tighter HIR cap and the same `MAX_DFA = 256` DFA
ceiling, surfaced as a `@compileError` rather than a runtime error.)

## Compile-time vs. runtime

The same pipeline drives two front ends.

### Runtime — `regex.zig` / `zeetah.Regex`

`Regex.compile` (and `compileWithFlags`) run the full
parse → HIR → analyze → NFA → DFA/executor pipeline at run time, heap-allocating
the chosen executor through the caller's allocator. This is the general path:
it supports the entire feature set, including the non-regular tiers (lookaround,
backreferences, atomic groups, lazy-with-end-anchor) that route to the
backtracker.

### Compile-time — `pattern.zig` / `zeetah.Pattern`

```zig
const Phone = zeetah.Pattern("[0-9]{3}-[0-9]{4}", .{});
// Phone.isMatch(...), Phone.find(...) -> static methods, no allocator, no deinit
```

`Pattern(comptime pattern, comptime opts)` runs the **whole**
parse → NFA → DFA (+ minimize) pipeline *at compile time* and bakes the matcher
into `.rodata` as a static `comptime_dfa.Dfa(n_states, n_classes)` value
(`exec/comptime_dfa.zig`). A pure-literal pattern bakes a comptime Teddy scan
instead of a DFA table. The result is a **type** with **static** methods — no
instance, no allocator, no `deinit`. This is possible precisely because
`planner.plan` and `properties.analyze` never read a haystack.

`PatternOptions` controls the comptime build:

```zig
pub const Options = struct {
    max_dfa_states: usize = 256, // soft budget; bounded by the internal MAX_DFA ceiling
    on_oversize: enum { compile_error, allow_oversized } = .compile_error,
    case_insensitive: bool = false, // peer of (?i)
    multiline: bool = false,        // peer of (?m): ^/$ as line anchors
};
```

`on_oversize = .allow_oversized` bakes a DFA that exceeds `max_dfa_states` but is
still within the internal ceiling; it does **not** rescue a pattern that blows
the ceiling or uses an unsupported feature (no comptime → runtime fallback).

The comptime path covers the **same feature surface as the runtime `Regex`** — the
two share the `parser → HIR` front end, and `Pattern` bakes whichever matcher the
runtime would build: a minimized DFA (or comptime Teddy literal) for regular
patterns, or the **same bounded tree-backtracker** for non-regular ones, with its
seek / over-approximation / delegate prefilters and full capture extraction
(numbered + `(?<name>)` named), all into `.rodata`. So lookaround, backreferences,
atomic/possessive quantifiers, look-assertions (`\b`, `\B`, mid-pattern `^`/`$`,
`(?m)` line anchors), lazy-with-end-anchor, and captures **all work at comptime**.
See *The comptime backtracker* below for how the non-regular tier is baked.

A `Pattern` bakes one matcher with **no runtime fallback**, so the constructs
genuinely unsupported *anywhere* in the engine are a hard `@compileError` rather
than a recoverable runtime `error.NotImplemented`:

- the `.unicode` (codepoint-mode) flag, `\p` scripts / binary props / `\p` under
  `(?i)`,
- an unknown POSIX class name,
- patterns that overflow an internal construction ceiling (`>1000`-count
  repetition; a DFA over the 256-state ceiling). *Exception:* a large keyword
  alternation `\b(?:kw|…)\b` that would blow `MAX_NFA` on the DFA path instead
  routes (via its `\b`) to the tree-backtracker and **compiles** — correct, though
  slower than the runtime's dedicated Aho-Corasick `boundary_lits` engine, which
  has no comptime analogue.

For any of those — or whenever the rejection needs to be a recoverable error — use
the runtime `Regex`.

## Design decisions & roads not taken

Zeetah's engine began as a proposal to rebuild the matcher around a
"meta engine" in the spirit of the Rust `regex` crate, with the twist that
Zig's `comptime` lets the whole strategy decision resolve at *compile time* for
the common case of a known pattern. The realized engine kept the planner-centric
shape and the literal-first ethos but diverged from the proposal in several
deliberate ways. The reasoning is recorded here because it explains why the
engine looks the way it does — and why some "obvious" pieces were intentionally
*not* built.

### The planner is a pure function — one planner, two front-ends

The Rust meta engine must do all of its strategy selection **at runtime**: every
call dispatches through a `Strategy` trait object and every regex carries a
thread-safe cache pool. Zeetah avoids that for comptime patterns because the
strategy decision is, at heart, a pure function `plan(Properties, flags)` that
never reads the haystack. The *same* `plan` drives both the runtime
`Regex.compile` path and the comptime `Pattern` path, so the two front-ends are
guaranteed to choose the same engine — a property the `Pattern`⇄`Regex`
differential test in `tests/feat_api.zig` enforces. `Properties` is the linchpin:
a single plain struct (no allocator in its shape), identical in comptime and
runtime, into which everything the planner needs is precomputed.

### Comptime monomorphization — what gets baked

When the pattern is comptime-known, planning emits a *monomorphized* matcher that
contains **only** the chosen strategy:

- no `Strategy` tagged-union dispatch at runtime, and dead strategies
  (Aho-Corasick, reverse-suffix, lazy DFA, …) are never instantiated → smaller
  binary, no branch misprediction on the hot path;
- prefilter literals become `comptime` byte arrays → fully unrolled SIMD /
  constant Teddy masks; a pure-literal `Pattern` bakes a comptime Teddy scan with
  **no DFA table at all**;
- scratch sizes are exact and baked into `.rodata` → **no allocator** on the
  `isMatch`/`find`/`count` path (only `findAll` / `captures` / `capturesAll`
  allocate, for the result slices / `Match.groups`);
- concurrency is automatically safe because nothing is shared.

The comptime path bakes the planner's regular-tier strategies (`.literal`,
`.reverse_suffix`, `.lit_prefix`, plain `.dfa`) using the *same* gate predicates
as runtime `regex.zig`. The necessary-condition `required` / `req_lit`
prefilters are baked into the comptime DFA too — via the table-type-agnostic
`exec/search.zig` shared with the runtime — which is what keeps the comptime path
**O(n), not O(n²)**, on `a.*X`-style adversarial input (previously a
comptime-only gap).

### The comptime backtracker — baking the non-regular tier

The non-regular tier (backreferences, lookaround, atomic/possessive quantifiers,
look-assertions, lazy-with-end-anchor) is baked the same way the DFA tier is. The
strategy is "bake the value, reuse the executor":

- **HIR → `.rodata`.** `exec/backtrack.zig`'s tree matcher was made generic over
  the HIR store — `BacktrackerG(comptime cap)` (the runtime `Backtracker =
  BacktrackerG(null)` alias is unchanged). `Pattern` parses to a fixed-size comptime
  HIR, **trims it to its exact node count**, and bakes that `Hir(node_count)` into
  `.rodata` — so a small non-regular pattern emits a small table, not the
  build-ceiling-sized store. The matcher's `m`/`cont`/`loopStep` body is identical
  across cap modes; `cc.lookHolds` (word boundaries, line/text anchors) is pure and
  comptime-evaluable, which is what lets look-assertions run at comptime.
- **Captures** are materialized into an inline `Captures(ng, gnames)` value — a
  fixed `[ng+1]?Group` array, **no allocator** (the comptime peer of the runtime's
  heap `Match.groups`; `Pattern.captures(input) ?Captures` vs runtime
  `Regex.captures(a,input) !?Match`). Group **count + `(?<name>)` names** come from
  the shared `parser.scanGroups` (lifted into `parser.zig` so both front-ends agree
  by construction — it is a *source* scan, so a group inside a lookaround still
  reserves its numbered/named slot). `get`/`getName` are compile-time-indexed.
- **The prefilters are baked too**, reusing the *zero-allocator* `full_dfa.compute`
  (the same one the DFA tier uses — the lazy/dense builders are allocator-heavy and
  were deliberately *not* ported):
  - a **seek** over-approximation `Dfa256` (relax `look`/`backref`→ε, drop the
    `atomic` cut) plus the `lb_byte` leading-look-behind `memchr`, threaded into the
    backtracker's own scan loop so it skips dead regions at every step;
  - a **delegate** plan that runs regular islands of a concat at DFA speed.
  Both are baked as values and pointed at with `@constCast` (read-only on the hot
  path, never freed). Soundness mirrors the runtime `seek.build`/`delegate.build`
  guards exactly.
- **Routing** is comptime-only: `pattern.zig buildAll` dispatches on
  `requires_backtracking or has_look` *before* `thompson.build`. The shared
  `properties.requires_backtracking` deliberately omits `has_look` so the *runtime*
  keeps its separate, faster `.bt_look` engine; the comptime path, which has no
  `.bt_look`, folds looks into the one backtracker arm.

Iteration runs over the **full input in absolute coordinates** (`runFrom(input,
from, …)`), never an `input[from..]` slice — a slice would make a resumed start look
like start-of-text and mis-fire `start_line`/`\b`. Correctness is pinned by the
`Pattern`⇄`Regex` differential tests in `tests/feat_api.zig` (find-family, captures,
seek-over-gaps, and look-assertions), plus the cross-engine count gate in the
benchmark, which now exercises the comptime path on every pattern it can build.

### A DFA core, not a PikeVM

The proposal assumed a PikeVM-style linear-bounds finder for the regular core.
The realized engine uses a **DFA table walk** instead: the regular-case
correctness workhorse is the eager `Dfa256` (`exec/full_dfa.zig`,
O(n) per scan, leftmost-first), with the bit-identical **lazy DFA**
(`exec/lazy_dfa.zig`) as the fallback when the eager table overflows its ceiling.
There is no NFA thread simulation at match time. In Zeetah the "slow general
engine" to avoid is therefore the **tree backtracker**, not a PikeVM — and the
planner's whole job is to keep patterns out of it whenever a finite automaton or
literal scan suffices.

### `reverse_suffix` is a fast-negative, not a reverse engine

The proposal included reverse-anchored, reverse-suffix, and reverse-inner
strategies backed by a reverse automaton, which would require a "quadratic guard"
(a stop-offset that abandons the optimization when a reverse `.*` scan would run
back to the haystack start, the classic `[A-Z].*bcdef…` O(m·n²) trap). **None of
the reverse automata were built.** `reverse_suffix` instead uses the trailing
literal *only* as a sound fast-**negative**: if the selective suffix is absent,
the whole haystack is rejected in a single scan; otherwise a forward DFA runs.
There is no per-suffix-hit reverse scan to make quadratic, and therefore no
stop-offset bookkeeping anywhere in the engine. The general linear-time guarantee
comes from the DFA core, not from reverse-scan mitigation.

### No cross-call `Cache` pool — a frozen DFA instead

The proposal anticipated a lazy DFA whose transition table must persist and grow
across calls, requiring a `regex_automata`-style pooled, mutex-guarded mutable
`Cache`. That pool was **not** built. The regular fallback on the hot path is a
**frozen** dense DFA (`freezeDense`) rather than a table that grows across calls,
so there is no shared mutable cache to pool; the lazy DFA is the bit-identical
fallback used *only* when the eager table overflows. The public API takes **no**
`Cache` argument and allocates no cross-call scratch — `find` / `isMatch` /
`findAll` are infallible in that respect and the runtime path inherits the
comptime path's "nothing shared ⇒ trivially thread-safe" property. A per-call
scratch escape hatch can be added additively later without changing the surface.

### Literal-sequence extraction is the highest-leverage layer

Borrowed directly from Rust's `regex`: **search for literals whenever possible;
avoid the general engine whenever possible.** `exec/seq_extract.zig` extracts
literal sequences at three positions — prefix, suffix, and inner (with a split
point) — each tagged exact/inexact and carrying a crude selectivity estimate the
planner uses to decide whether a prefilter is worth it. From a `Seq`, the
prefilter is chosen by shape: one short literal → `memchr`; a few → multi/range
SIMD; several → Teddy; many → Aho-Corasick. Two filters beyond the original plan
also shipped — the **required-byte** and **required-literal-anywhere** filters
described above — plus the **Seek** over-approximation for the backtracking tier.

### The two backtrackers are deliberately separate

The HIR-tree backtracker (`exec/backtrack.zig`) is used *only* for the
inherently non-regular features (backreferences, lookaround, atomic groups); the
cheap-capture core uses the separate **bounded** backtracker
(`exec/bounded_bt.zig`) with its `(state, pos)` visited bitset and strict
`O(n·m)` bound. Merging the two would reintroduce ReDoS — the split is real and
intentional, not an accident of layering.

### Ongoing tuning surfaces

- **Selectivity heuristics.** The prefix-vs-suffix choice and the
  "is this prefilter worth it" estimate are heuristics tuned against the in-repo
  benchmark workloads — an ongoing tuning surface, not a settled one.
- **Match semantics.** Leftmost-first (Perl/RE2) is preserved end-to-end. Lazy
  combined with an end-anchor (`a*?$`) routes to the runtime backtracker and is
  still leftmost-first; it is supported at runtime but `@compileError`s under the
  comptime `Pattern`.

## Module map

| Module | Role |
|--------|------|
| `parser.zig` | recursive-descent parser; emits HIR (no lexer, no AST) |
| `hir.zig` | flat indexed high-level IR; construction ceilings (`MAX_NODES`, `MAX_GROUPS`) |
| `properties.zig` | pure analysis pass over HIR → `Properties` (literals, anchoring, required byte, `requires_backtracking`) |
| `planner.zig` | pure `plan(Properties, Flags) → Strategy` (comptime-evaluable) |
| `thompson.zig` | HIR → Thompson NFA (intermediate); NFA ceilings (`MAX_NFA`, `MAX_EDGES`) |
| `regex.zig` | runtime façade + Layer-1 dispatcher (`MetaKind`) |
| `pattern.zig` | comptime façade (`Pattern`, `PatternOptions`) |
| `prefilter.zig` | required-byte / required-literal / first-byte-SIMD / Teddy / Aho-Corasick |
| `exec/core.zig` | runtime DFA table-walk executor + literal/prefix fast paths (drives `Dfa256`) |
| `exec/search.zig` | table-type-agnostic prefilter search shared by the runtime `Dfa256` and the comptime `Dfa(ns,nk)` |
| `exec/full_dfa.zig`, `exec/dfa_build.zig` | eager DFA construction (subset + minimize) → `Dfa256` |
| `exec/comptime_dfa.zig` | static, allocation-free `Dfa(ns,nk)` baked into `.rodata` by `Pattern` |
| `exec/dense_search.zig` | frozen single-pass unanchored DFA (`dense_search`) |
| `exec/lazy_dfa.zig`, `exec/lazy_memo.zig` | on-demand subset construction + memo (DFA-ceiling fallback) |
| `exec/onepass.zig` | one-pass DFA capture path |
| `exec/class_span.zig` | SIMD single-range `class+`/`class*` scan |
| `exec/seq_extract.zig` | literal-sequence / keyword extraction (`Seq`; `boundary_lits`) |
| `exec/backtrack.zig`, `exec/bounded_bt.zig` | HIR-tree backtracker (backref/lookaround/atomic) + bounded `O(n·m)` capture path |
| `exec/seek.zig` | regular over-approximation prefilter for the backtracking tier |
| `exec/delegate.zig` | concat-internal regular-island delegation into the backtracker |
| `exec/split_alt.zig` | mixed regular/non-regular top-level alternation |
| `exec/dupword.zig` | adjacent-duplicate-word linear recognizer |
| `exec/charclass.zig` | shared character-class helpers |
| `unicode_class.zig`, `unicode_tables.zig` | Latin-1 `\p` General_Category resolution |
| `cache.zig`, `thread_safety.zig` | lazy-DFA memo plumbing; thread-safety helpers |
| `match.zig`, `common.zig`, `errors.zig`, `builder.zig` | `Match`/`Group`, shared types/flags, `RegexError`, fluent builder |

## References

- Thompson, Ken (1968). *Programming Techniques: Regular Expression Search Algorithm.*
- Cox, Russ (2007). *Regular Expression Matching Can Be Simple And Fast.*
- **RE2** (Google) — the finite-automaton, linear-time-by-construction philosophy
  and the literal/prefilter routing that the meta engine generalizes.
- **Rust `regex` crate** — the meta-engine shape, the literal-first ethos, and the
  prefilter strategies (Teddy, required literals, lazy DFA) this engine adapts to
  a comptime-first design.

---

See also: [README](../README.md) · [API Reference](API.md) ·
[Examples](EXAMPLES.md) · [Advanced Features](ADVANCED_FEATURES.md) ·
[Performance Guide](BENCHMARKS.md)
