# Meta Regex Engine — Architecture Analysis (comptime-first)

Status: **design analysis that has since SHIPPED**. This document began as a
proposal to rebuild Zeetah's top-level engine around a "meta engine" (à la the
Rust `regex` crate), with the twist that Zig's `comptime` lets us resolve almost
the entire strategy decision tree at *compile time* for the common case of a
literal pattern. Most of the plan below is now implemented; where the realized
engine diverged from the original proposal, the text is annotated **(shipped:
…)**. The analytical narrative is preserved so the reasoning behind each
decision stays on record.

The realized engine lives in `src/regex.zig` (runtime), `src/pattern.zig`
(comptime), `src/planner.zig` (the pure planner), `src/properties.zig` (the
analysis pass), `src/prefilter.zig`, and the per-strategy executors under
`src/exec/`.

---

## 1. The core thesis

The Rust meta engine must do all of its strategy selection **at runtime**,
because it has no compile-time pattern. Every call dispatches through a
`Strategy` trait object, every regex carries a thread-safe `Cache` pool, and
unused engines still exist in the binary.

We can do better. The meta engine is, at heart, a **pure function**:

```
plan(pattern, flags) -> Strategy
```

`plan` only reads the pattern's `Properties` and flags — never the haystack. So
when the pattern is `comptime`-known (the dominant case in this codebase via
`Pattern`), `plan` can run **at compile time** and emit a *monomorphized*
search routine that contains **only the chosen strategy**:

(Shipped: `plan` lives in `src/planner.zig` as `pub fn plan(p: Properties,
flags: Flags) Strategy` — a pure function over the analysis struct, exactly as
proposed. `Strategy` is a 5-variant union: `.literal`, `.prefix_prefilter`,
`.reverse_suffix`, `.core`, and a `.backtrack` sentinel. Non-regular patterns
are intercepted by `regex.zig` *before* `plan` is consulted, so `Strategy` is
really the regular-tier sub-decision shared with the comptime path; the full
runtime taxonomy is the ~12-variant `MetaKind` enum in `regex.zig`.)

- no `Strategy` tagged-union dispatch at runtime,
- no `Cache` pool (scratch sized exactly from the comptime NFA/DFA, stack-allocated),
- dead strategies (Aho-Corasick, reverse-suffix, lazy DFA, …) are never
  instantiated → smaller binary, no branch misprediction,
- prefilter literals become `comptime` byte arrays → fully unrolled SIMD.

The same `plan` logic, expressed once over a plain data IR, also drives the
**runtime** path (`Regex.compile(allocator, pattern)`). One planner, two
front-ends.

(Shipped: the runtime path does not use a thread-safe `Cache` pool — see §8.
Each runtime executor in `src/exec/` carries its own scratch, and the regular
fallback engines walk a frozen DFA table rather than a growable lazy-DFA cache
on the hot path.)

> Distilled goal (borrowed from Rust): **search for literals whenever
> possible; avoid the slow general engine whenever possible.** Comptime just
> lets us bake the winner in instead of choosing it on every call. (In Zeetah
> the "slow general engine" to avoid is the tree backtracker; the regular
> workhorse is a DFA, not a PikeVM — see §9.)

---

## 2. What the meta engine needed vs. what shipped

This was the original gap analysis. The "Status" column records where each item
landed in the realized engine. Note that the shipped pipeline is
`parser → HIR → thompson NFA → DFA / executors` — there is **no AST stage** and
no PikeVM; the names below in the "needed" column are the proposal's working
labels, and the realized filenames are given in the Status column.

| Capability | Needed (proposal) | Status (shipped) |
|---|---|---|
| Parser | one parser usable in both modes | **Done** — `src/parser.zig` emits an HIR (`src/hir.zig`), shared by runtime and comptime; no separate AST IR |
| HIR / lowering | shared, comptime-capable | **Done** — `src/hir.zig` |
| Thompson NFA | one NFA builder, comptime-capable | **Done** — `src/thompson.zig` |
| Regular fallback engine | linear bounds finder | **Done differently** — there is no PikeVM; the regular fallback is the eager DFA (`src/exec/dfa.zig`, `Dfa256`), with the bit-identical **lazy DFA** (`src/exec/lazy_dfa.zig`) when the eager table overflows |
| Backtracker | keep for backref/lookaround | **Done** — `src/exec/backtrack.zig` (HIR-tree, step-budgeted) for lookaround/backreferences |
| Bounded backtracker | O(n·m) capture path | **Done** — `src/exec/bounded_bt.zig` uses a `(state,pos)` visited bitset, strictly O(n·m) |
| One-pass DFA | cheap captures | **Done** — `src/exec/onepass.zig` |
| Full DFA | comptime fast path when it fits | **Done** — `src/exec/full_dfa.zig` / `src/exec/dfa_build.zig`; `Pattern` bakes it into `.rodata` |
| Literal-sequence extraction | prefix/suffix/inner literals | **Done** — `src/exec/seq_extract.zig`; prefilters in `src/prefilter.zig` (single/multi/range/bitset SIMD, **Teddy**, **Aho-Corasick**) |
| Reverse-suffix strategy | reverse optimizations | **Done in spirit** — shipped as a selective trailing-literal **fast-negative** (`reverse_suffix` MetaKind) feeding a forward DFA, not a full reverse engine (see §7) |
| ReDoS gating | a planning input | **Done** — `src/properties.zig` (`analyze`) computes `requires_backtracking` and the literal/anchor facts the planner reads |
| Strategy planner | the central new component | **Done** — `src/planner.zig`, pure `plan(Properties, Flags) -> Strategy` |
| Cache pool | runtime mutable scratch | **Not shipped** — the runtime path uses per-executor scratch and a frozen dense DFA instead of a growable cross-call cache (see §8) |

Net: the realized engine kept the planner-centric shape and the literal-first
ethos, replaced the PikeVM-centric core with a DFA / lazy-DFA core, and dropped
the cross-call `Cache` pool. Reverse-suffix shipped as a fast-negative filter
rather than a reverse automaton.

---

## 3. Proposed layering

As shipped, the stage between source text and the planner is
`parser → HIR → thompson NFA` (no AST stage):

```
                        ┌───────────────────────────────┐
  pattern (comptime  →  │  parser  →  HIR              │   (shared, comptime-capable)
   or runtime str)      └───────────────┬───────────────┘
                                        │
                        ┌───────────────▼───────────────┐
                        │  Properties (plain data)       │   pure, comptime-evaluable
                        │  • anchored_start / _end       │   (src/properties.zig)
                        │  • min_len / max_len           │
                        │  • requires_backtracking       │
                        │  • prefix / suffix literals    │
                        │  • required byte / required lit│
                        │  • first-byte set              │
                        └───────────────┬───────────────┘
                                        │
                        ┌───────────────▼───────────────┐
                        │  plan(props, flags) -> Strategy│   THE decision tree (§5)
                        └───────────────┬───────────────┘
                  comptime ┌────────────┴────────────┐ runtime
                           ▼                         ▼
            monomorphized search type      MetaKind dispatch
            (only chosen engine,           (~12 executors in src/exec/;
             baked DFA / Teddy,             per-executor scratch,
             no allocator)                  frozen DFA — no Cache pool)
```

`Properties` is the linchpin: a single plain struct, no allocator in its
shape, identical in comptime and runtime. Everything the planner needs to
decide is precomputed into it, so `plan` itself is trivially comptime-evaluable
— which is exactly why the comptime `Pattern` path can run the whole
analysis-and-route at compile time.

(Shipped: the proposal's `needs_captures` / `is_one_pass` / `redos_risk` /
inner-literal fields were folded into the realized `Properties` differently —
captures and one-pass detection are decided in the executor layer, and the
ReDoS decision surfaces as the single `requires_backtracking` predicate.)

---

## 4. Literal-sequence extraction (the biggest gap)

Today we only extract a first-byte set and an exact prefix string. The meta
engine needs **literal sequences** at three positions, mirroring
`regex-syntax`'s `Seq`:

- **prefix Seq** — literals every match must start with.
- **suffix Seq** — literals every match must end with.
- **inner Seq + split point** — a literal that cleanly partitions the regex.

Each `Literal` is *exact* (the match cannot extend through it) or *inexact* (a
truncated prefix of a longer possibility). Each `Seq` tracks: the literal set,
whether it is exact, and a crude *selectivity / false-positive* estimate used by
the planner to decide whether the prefilter is worth it (Rust's
`Seq::optimize_for_prefix_by_preference`).

Prefilter selection from a `Seq` (extends `prefilter.zig`):

- 1 literal, len 1 → `memchr` (`.single`).
- few short literals → `.multi` / `.ranges` SIMD.
- several literals → **Teddy** (SIMD multi-substring, ≤ 8 needles).
- many literals → **Aho-Corasick**.
- non-selective → no prefilter.

(Shipped: literal-sequence extraction is `src/exec/seq_extract.zig`; the
prefilters are `src/prefilter.zig`. All of the above landed — single/multi/
range/bitset first-byte SIMD, Teddy with adaptive nibble masks backing the
`literal`/`lit_prefix`/`reverse_suffix` kinds, and Aho-Corasick backing the
`boundary_lits` kind for `\b(?:kw1|kw2|…)\b` keyword alternations. Two further
prefilters not in the original plan also shipped: a **required-byte** filter (a
single byte every accepting path must consume → one `memchr` no-match) and a
**required-literal-anywhere** filter (a rare mandatory literal with a
start-recovery recipe). A **Seek** over-approximation skips proven-dead
prefixes for the backtracking tier.)

Comptime payoff: with a comptime pattern the `Seq` is `comptime`, so the chosen
prefilter is baked in with the literal bytes as constants — a pure-literal
`Pattern` bakes a comptime Teddy scan with no DFA table at all.

This entire layer is pure AST analysis → trivially comptime-evaluable, and it
is the highest-leverage missing piece.

---

## 5. The planner decision tree

This was the proposed decision tree; the shipped `plan` is a leaner version of
it (see the **(shipped: …)** note that follows).

`plan(props, flags)` — evaluate in order; first match wins:

1. **No engine needed.** Pattern is a literal or an alternation/concatenation of
   literals with no unbounded repetition → emit a pure literal-search strategy
   (`memmem` / Teddy / Aho-Corasick). *No NFA is ever built.*

2. **Reverse-anchored.** `anchored_end` (`$`/`\z`) and not `anchored_start` →
   reverse scan from end of haystack with a reverse engine.

3. **Prefix prefilter.** A selective prefix `Seq` exists → prefilter scans for
   candidates; forward engine confirms from each.

4. **Reverse-suffix.** No good prefix, but a selective suffix `Seq` exists →
   scan for suffix occurrences, match the regex *in reverse* from each
   candidate. **Quadratic guard required** (§7).

5. **Reverse-inner.** No prefix/suffix, but a selective inner `Seq` that cleanly
   partitions the regex → split at the literal: first half → reverse engine,
   second half → forward engine. **Quadratic guard required** (§7).

6. **Core.** Fallback. Compose the available engines:
   - Find match bounds with the **fastest available DFA**: comptime full DFA if
     it fit the state budget, else lazy DFA.
   - DFA may *fail* (lazy-DFA cache thrash heuristic) → fall back to one-pass
     DFA / bounded backtracker for bounds.
   - **Captures** (only on the opt-in `captures()` path): after bounds are
     known, report group offsets via one-pass DFA → bounded backtracker.
   - Lookaround / backreferences force the HIR-tree backtracker
     (`src/exec/backtrack.zig`).

(Shipped: the realized `plan` in `src/planner.zig` returns a 5-variant
`Strategy` — `.literal`, `.prefix_prefilter`, `.reverse_suffix`, `.core`, and a
`.backtrack` sentinel — and its first test is literally `if
(p.requires_backtracking) return .backtrack;`. The reverse-**anchored** (step 2)
and reverse-**inner** (step 5) branches were **not** built as reverse engines;
the realized engine has no reverse automaton. `reverse_suffix` shipped as a
selective trailing-literal *fast-negative* feeding a forward DFA. The full
runtime taxonomy is broader than the planner's 5 variants — `regex.zig`'s
`MetaKind` adds `dense_search` (a frozen single-pass unanchored DFA for narrow
unanchored shapes), `class_span` (a SIMD member-run scan for a single
contiguous `class+`/`class*`), `boundary_lits`, `bt_look` (look-assertions on
the bounded backtracker), `split_alt` (top-level alternation mixing regular and
non-regular branches), and `dup_word` (the `(\b\w+\b)\s+\1` adjacent-duplicate
shape, a single O(n) linear scan). Non-regular patterns are intercepted in
`regex.zig` before `plan` runs, which is why `.backtrack` is only a sentinel.)

Each branch's *guards* (steps 1–5) are computed from `Properties`, so each is a
single comptime `if` in the comptime path.

---

## 6. Comptime monomorphization plan

What becomes comptime-resolved when the pattern is a literal:

| Decision | Resolved at comptime to |
|---|---|
| Strategy choice (§5) | a single concrete search `type`; other strategies not instantiated. **(shipped)** the comptime `Pattern` now bakes the planner's regular-tier strategies — `.literal` (Teddy only, no DFA table), `.reverse_suffix` (trailing-literal Teddy fast-negative + forward DFA), `.lit_prefix` (leading-literal Teddy locate + anchored `runFrom` verify), and plain `.dfa` — using the *same* gate predicates as the runtime `regex.zig`, so the two front-ends pick the same engine (differential-tested) |
| Prefilter kind + literals | specialized type with `comptime` byte arrays; unrolled SIMD / constant Teddy masks. **(shipped)** the necessary-condition `required` (byte every match consumes → one `memchr`) and `req_lit` (rare mandatory literal + start-recovery) prefilters are now baked into the comptime DFA too, via the table-type-agnostic `src/exec/search.zig` shared with the runtime. This is what makes the comptime path **O(n), not O(n²)**, on `a.*X`-style adversarial input — previously a comptime-only gap |
| DFA vs lazy DFA | run subset construction at comptime; **if it fits `max_dfa_states`** bake the full DFA (`src/exec/full_dfa.zig`); pure literals bake a comptime Teddy scan with no DFA table |
| Scratch sizes | exact, baked into `.rodata` → **no allocator** (only `findAll` allocates, for the result slice) |
| Captures | the comptime `Pattern` path is **capture-free**: it exposes no `captures` method at all; submatch extraction is a hard `@compileError` (use the runtime `Regex.captures`) |
| Quadratic guard (§7) | the realized engine has no reverse-suffix automaton, so there is no stop-offset bookkeeping to omit |
| Look-assertions present? | if present (`\b`, `\B`, mid `^`/`$`, `(?m)`), the comptime path `@compileError`s — those are runtime-only |

Concretely, the comptime front-end is `src/pattern.zig`'s
`Pattern(comptime pattern, comptime opts: Options) type`, exposing **static**
methods (no instance, no allocator, no `deinit`): `isMatch(input) bool`,
`find(input) ?Match` (no error union), `count(input) usize`, and
`findAll(allocator, input) ![]Match`, plus `pub const has_dfa = true`. It runs
the whole parse → NFA → DFA(+minimize)
pipeline at compile time and bakes the matcher into `.rodata`.

(Shipped: the proposal's "comptime path chooses lazy DFA or PikeVM on
explosion" did **not** land — there is no comptime lazy-DFA downgrade and no
PikeVM. `PatternOptions = struct { max_dfa_states: usize = 256, on_oversize:
enum { compile_error, allow_oversized } = .compile_error, case_insensitive:
bool = false }`. `max_dfa_states` is a soft budget bounded by an internal
MAX_DFA = 256 ceiling and does not raise it. `on_oversize = .allow_oversized`
bakes a DFA over that soft budget but within the ceiling; it does **not** rescue
patterns that blow the ceiling or use an unsupported feature. The comptime path
hard-`@compileError`s — with no runtime
fallback — for captures-with-submatch extraction, lookaround, backreferences,
look-assertions, `\p` under `(?i)`, lazy + end-anchor (`a*?$`, which routes to
the runtime backtracker), and patterns exceeding the DFA ceiling.)

---

## 7. Quadratic-blowup mitigation (reverse-suffix / reverse-inner)

The known `[A-Z].*bcdefghijklmnopq` failure: every suffix hit triggers a
reverse `.*` scan back to the haystack start → O(m·n²).

Mitigation (same as Rust): the reverse engines take a **stop offset** = end of
the last suffix match. If the reverse scan would pass it, it returns a
*"quadratic"* error; the meta engine catches it and **abandons the optimization,
falling back to the core strategy** for the rest of the haystack. The O(m·n)
guarantee is preserved; we just lose the literal speedup on adversarial input.

Comptime refinement: syntactic analysis (does the suffix/inner literal overlap
the unbounded repetition immediately preceding it?) cannot *prove* safety, but
it can prove *absence of risk*. When risk is syntactically impossible, the
comptime path **omits the stop-offset bookkeeping and the core fallback engine**
entirely — strictly smaller, faster code than Rust can produce here.

(Shipped: the realized engine sidesteps this entire problem because it has **no
reverse engine**. `reverse_suffix` uses the trailing literal only as a sound
fast-*negative* — if the selective suffix is absent the haystack is rejected by
a single scan — and then runs a forward DFA. There is therefore no per-suffix-
hit reverse scan to make quadratic, and no stop-offset machinery. The general
ReDoS guarantee comes from a different place than this section assumed; see §9.)

---

## 8. The Cache pool (runtime path only) — NOT shipped

The proposal anticipated a lazy DFA whose transition table must persist and grow
across calls, requiring shared mutable scratch:

Proposed runtime design (mirrors `regex_automata::util::pool`):

- per-`Regex` `Pool(Cache)`: a fast single-slot path guarded by one atomic, a
  fallback `Mutex`-guarded stack of caches keyed by an owner thread id;
- `Regex.find` etc. transparently borrow/return a `Cache` → infallible API, no
  `Cache` in the public signature;
- a low-level `findWithCache(&cache, …)` escape hatch for hot loops.

(Shipped: the cross-call `Cache` pool was **not** built. The realized regular
fallback is a **frozen** dense DFA (`freezeDense`) rather than a lazy table that
grows across calls, so the hot path has no shared mutable cache to pool. The
lazy DFA (`src/exec/lazy_dfa.zig`) is the bit-identical fallback used only when
the eager table overflows. The public API takes **no** `Cache` argument: the
former no-op `findCached` escape hatch was removed for alpha (it was uncallable
externally — `Cache` was never exported — and added nothing over `find`). A
real per-call scratch API can be added additively later. `Regex.find` /
`isMatch` / `findAll` take no cache and allocate no cross-call scratch.)

Comptime path: **no pool at all.** Scratch is baked into `.rodata`; concurrency
is automatically safe because nothing is shared. The runtime path inherits the
same property by using a frozen DFA instead of a growable cache.

---

## 9. Engine inventory & semantics notes

This is the realized inventory (the proposal's PikeVM and reverse NFA/DFA were
not built):

- **Eager DFA** (`src/exec/dfa.zig`, `Dfa256`): the regular-case correctness
  workhorse — a table walk, O(n) per scan, leftmost-first.
- **Lazy DFA** (`src/exec/lazy_dfa.zig`): the same subset construction evaluated
  on demand, **bit-identical** to the eager DFA, used when the eager table
  exceeds its state ceiling. The regular fallback never escalates to
  backtracking.
- **Bounded backtracker** (`src/exec/bounded_bt.zig`): the cheap-capture path,
  a `(state,pos)` visited bitset giving strictly **O(n·m)** — never exponential.
- **One-pass DFA** (`src/exec/onepass.zig`): captures at DFA speed when the NFA
  is one-pass.
- **HIR-tree backtracker** (`src/exec/backtrack.zig`): the only path for the
  inherently non-regular features — **lookaround and backreferences**. It is
  step-budgeted (and depth-guarded), not exponential-in-practice (see §9 of the
  ReDoS contract below). It carries a `seek` regular over-approximation
  prefilter and delegates concat-internal regular "islands" to a DFA.
- **Full DFA** (`src/exec/full_dfa.zig` / `src/exec/dfa_build.zig`): the comptime
  fast path that `Pattern` bakes into `.rodata`.
- **Specialized scanners**: `class_span` (SIMD member-run for a single
  contiguous `class+`/`class*`), `dup_word` (a single O(n) scan for
  `(\b\w+\b)\s+\1`), and the `boundary_lits` Aho-Corasick + O(1) `\b` verify.

### ReDoS contract (be precise)

- **Regular** patterns are **linear by construction** — a DFA table walk, O(n)
  per scan. If the eager DFA explodes it falls back to the bit-identical **lazy
  DFA**, never to backtracking. Classic "catastrophic" regular shapes such as
  `(a+)+$`, `(a*)*$`, `(.*)*$` **compile and run linearly** — they are **not**
  rejected at compile time.
- **Non-regular** patterns (backreferences, lookaround, and lazy + end-anchor)
  run on the tree backtracker under an explicit **step budget**
  (`8000 + (len+1)*4000`) plus a recursion-depth guard (`MAX_DEPTH = 16384`).
  Exceeding it returns a typed `error.MatchBudgetExceeded` at **match** time —
  never a hang (distinct from the compile-time `PatternTooComplex` below).
- **Construction ceilings** (NFA states 256, edges 2048, DFA states 256, HIR
  nodes 4096, capture groups 32) raise `error.PatternTooComplex` at **compile**
  time for patterns too large to build.

---

## 10. Migration phasing (as proposed; outcome annotated)

1. **IR consolidation.** One comptime-capable parser + NFA builder; introduce
   the `Properties` struct. *(Shipped: `src/parser.zig` → `src/hir.zig` →
   `src/thompson.zig`, with `src/properties.zig` as the analysis pass. There is
   no AST stage and no second slim parser to delete — the realized pipeline went
   straight to HIR.)*
2. **Literal-sequence extraction.** Prefix/suffix `Seq` + selectivity; extend
   the SIMD prefilters, add Teddy, then Aho-Corasick. *(Shipped:
   `src/exec/seq_extract.zig` + `src/prefilter.zig`, plus the required-byte and
   required-literal-anywhere filters that were not in the original plan.)*
3. **Planner skeleton.** `plan(props,flags) -> Strategy`, parity-checked against
   the test suite. *(Shipped: `src/planner.zig`; the regular core is a DFA, not
   a PikeVM.)*
4. **Reverse engines + strategies 2/4/5** with the quadratic guard (§7).
   *(Not shipped as reverse automata — `reverse_suffix` is a fast-negative
   filter; reverse-anchored and reverse-inner were not built.)*
5. **Lazy DFA** (runtime fallback) and **one-pass DFA** (captures). *(Shipped:
   `src/exec/lazy_dfa.zig`, `src/exec/onepass.zig`. The `Cache` pool from the
   same proposed phase was not — see §8.)*
6. **Comptime monomorphization.** Generalize the comptime path to emit the
   planned strategy, not only a DFA. *(Shipped: `src/pattern.zig`'s `Pattern`
   bakes the planned matcher into `.rodata`; pure literals bake a comptime Teddy
   scan with no DFA table.)*

Each phase was independently shippable and regression-tested against the
existing suite (`zig build test` runs the unit suite plus the feature/contract
files); the planner can always fall back to the DFA "core" so correctness never
regresses while strategies are added.

---

## 11. Open questions / risks (as raised; status annotated)

- **Comptime cost.** Subset construction + Teddy at `comptime` for large
  patterns costs compiler time. *(Resolved by construction: `Pattern` enforces
  the same hard ceilings as the runtime — MAX_DFA = 256, etc. — and
  `@compileError`s rather than silently degrading; `on_oversize =
  .allow_oversized` only bakes an over-soft-budget DFA that is still within the
  ceiling, it does not delegate unsupported features to the runtime.)*
- **One parser, two modes.** *(Resolved: `src/parser.zig` is the single parser
  used by both the runtime `Regex` and the comptime `Pattern`; there is no
  separate slim comptime parser to keep in sync.)*
- **Backtracker semantics split.** The HIR-tree backtracker
  (`src/exec/backtrack.zig`) is *only* for backref/lookaround; the cheap-capture
  core uses the separate bounded backtracker (`src/exec/bounded_bt.zig`, O(n·m)
  visited bitset). Mixing them would reintroduce ReDoS — the split is real and
  intentional.
- **Selectivity heuristic.** The prefix-vs-suffix choice and the "is this
  prefilter worth it" estimate remain heuristics tuned against the in-repo
  benchmark workloads; this is an ongoing tuning surface, not a settled one.
- **Match semantics.** Leftmost-first (Perl/RE2) is preserved end-to-end. Lazy
  combined with an end-anchor (`a*?$`) routes to the runtime backtracker and is
  still leftmost-first; it is supported at runtime but `@compileError`s under
  comptime `Pattern`.
