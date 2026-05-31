# Zeetah — Performance / Memory / Algorithmic Improvements — Actionable Plan

Distilled from `docs/IDEAS.md` and filtered against the current codebase. Only
items with a concrete implementation path in a Zig library are kept. FPGA/MC-NFA,
full multi-tier JIT, and SMT-solver-backed symbolic automata are intentionally
excluded as out of scope.

> **Status note (current architecture):** The runtime is a planner-driven
> dispatcher (`src/regex.zig` + the pure `src/planner.zig`) over an HIR pipeline
> (`src/parser.zig` → `src/hir.zig` → `src/thompson.zig` → DFA/executors in
> `src/exec/`); the comptime path is `src/pattern.zig`. Items that have already
> shipped have been removed from this plan — what remains below is open work.
> (For the record, the meta-engine rewrite already landed the runtime eager +
> `lazy_dfa` tiers, pay-for-play capture-free `find`/`isMatch`, prefilter-driven
> skipping via `seek`, the required-literal / Teddy / Aho-Corasick prefilters,
> the `reverse_suffix` span finder, the `onepass` capture fast-path, and the
> structural literal-run / optimizer wins now folded into HIR construction.)

Legend — **Impact**: speedup/memory reach. **Effort**: rough size. **Risk**:
correctness blast radius.

---

## Tier 1 — High impact, self-contained

### 1.2 Two-phase capture extraction (find span fast, then capture)
**Impact: high · Effort: medium · Risk: medium**

IDEAS.md "two-phase search composition." (Today captures are opt-in: `find`/
`isMatch`/`findAll` are capture-free, and only `captures()` allocates and fills
submatch slots, via a bounded-backtracking capture path that is O(n·m) by a
`(state,pos)` visited bitset.) This item is the further optimization of
amortizing capture work over only the match region rather than the whole input.

- Phase 1: lazy DFA or existing prefilter finds match start/end offsets.
- Phase 2: run the capture engine **only on that slice** to fill capture slots.
- Amortizes capture-tracking cost over the match region instead of the whole
  input. Already partly unlocked by the (now-shipped) `reverse_suffix` span
  finder.

---

## Tier 2 — Algorithmic engine additions

### 2.2 Bounded backtracker as a first-choice capture engine for short haystacks
**Impact: medium · Effort: small · Risk: low**

IDEAS.md "Bounded Backtracker" row. A bounded backtracker already exists (under
`src/exec/`) with an explicit step budget and recursion-depth guard, and the
opt-in `captures()` runs on a bounded-backtracking capture path whose visited
`(state,pos)` bitset keeps it O(n·m). The open idea: promote it to a
*first-choice* capture engine specifically when `haystack.len` is small and the
pattern is regular, where it can beat a thread-set simulation on short inputs.

### 2.3 Backtracker memoization (polynomial backreference/lookaround)
**Impact: high (ReDoS) · Effort: medium · Risk: medium**

IDEAS.md "memory-efficient approximations of backreferences" + memoization
section. The ReDoS contract is already explicit: regular patterns are linear by
construction (DFA, never backtracking), and non-regular patterns (backreferences,
lookaround, lazy+end-anchor) run on the tree backtracker under a step budget
plus a recursion-depth guard, returning a typed `error.PatternTooComplex` at
match time instead of hanging; the bounded-backtracking *capture* path is already
O(n·m) via a `(state,pos)` visited bitset. The open idea: add a `(node,pos)`
visited-set memo (Spencer/"squared" memoization) on the non-backref portions of
genuinely non-regular patterns to convert worst-case blowup to polynomial while
keeping backref semantics, so they finish fast instead of hitting the budget.
Relates to the ReDoS concerns in `docs/SECURITY_PROBLES.md`.

### 2.4 Bit-parallel NFA simulation for small patterns
**Impact: medium-high · Effort: medium · Risk: medium**

IDEAS.md "bit-parallel NFA simulation." For patterns whose Glushkov/Thompson
state count fits in a 64/128/256-bit word, simulate the whole NFA with shift/AND/OR
over a `@Vector` mask — one machine word advances all states per byte. Pairs
naturally with the existing `@Vector` usage in `src/prefilter.zig`. Big win on
short-to-medium patterns where a full DFA table is overkill.

---

## Tier 3 — Prefilter / literal extraction upgrades

### 3.1 Small-class / optional cross-product literal expansion
**Impact: high · Effort: medium · Risk: low**

The first-byte, required-literal-anywhere, Teddy multi-substring, and
Aho-Corasick keyword prefilters in `src/prefilter.zig` are already shipped; this
is the remaining open piece from IDEAS.md's literal-extraction list:

- Small-class / optional cross-product expansion (`abc?de?[x-z]` → a handful of
  literals) with a memory-bound abort, ordered leftmost-first to preserve
  Perl semantics (IDEAS.md explicitly calls out non-commutative alternation).

### 3.3 Case-insensitive prefilter
**Impact: medium · Effort: small · Risk: low**

The literal / literal-prefix fast paths are still gated behind
`!flags.case_insensitive` in the planner (`src/planner.zig`), so they are
disabled entirely under `case_insensitive`. Recover them by lowering the
first-byte set / literals to a case-folded byte set fed into the existing SIMD
scanner — common real-world case currently left on the table.

---

## Tier 4 — Cheap structural wins

### 4.3 Packrat/memoized parse guard
**Impact: low-medium (DoS hardening) · Effort: small · Risk: low**

IDEAS.md packrat-parsing section. The recursive-descent parser (`src/parser.zig`)
feeds an HIR build that is bounded by construction ceilings (HIR nodes 4096, NFA
states 256, edges 2048, DFA states 256, capture groups 32), which raise
`error.PatternTooComplex` at compile for over-large patterns. The open idea: add
explicit parse-time depth limits + memoization so pathological *nested syntax*
cannot blow compile-time stack before those ceilings are reached, guaranteeing
linear-time parsing.

---

## Suggested ordering

Remaining, roughly in priority:

1. **3.3** (case-insensitive prefilter) — small, high-value, reuses existing
   SIMD; the literal/prefix fast paths are still gated off under
   `case_insensitive`.
2. **2.3** (backtracker memoization) — would let genuinely non-regular patterns
   finish fast instead of hitting the step budget; relates to
   `docs/SECURITY_PROBLES.md`.
3. **1.2** (two-phase captures) — narrows the capture pass to the match region;
   complements the already-shipped `onepass` fast-path.
4. **2.4** (bit-parallel NFA) and the open part of **3.1** (small-class
   cross-product literal expansion) — opportunistic, pattern-dependent
   accelerators.
5. **2.2** (bounded backtracker as first-choice capture engine on short inputs)
   and **4.3** (packrat/memoized parse guard) — incremental hardening / small
   wins.

Out of scope (from IDEAS.md, recorded for completeness): FPGA/MC-NFA offload,
multi-tier native JIT (Ignition/Sparkplug/TurboFan analog), SMT/Z3-backed
symbolic automata, multi-core data/pipeline parallelism. Brzozowski-derivative
matching is interesting but a full engine rewrite — deferred, not planned.
