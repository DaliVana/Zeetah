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
plus a recursion-depth guard, returning a typed `error.MatchBudgetExceeded` at
match time instead of hanging; the bounded-backtracking *capture* path is already
O(n·m) via a `(state,pos)` visited bitset. The open idea: add a `(node,pos)`
visited-set memo (Spencer/"squared" memoization) on the non-backref portions of
genuinely non-regular patterns to convert worst-case blowup to polynomial while
keeping backref semantics, so they finish fast instead of hitting the budget.
Relates to the ReDoS concerns in `docs/SECURITY_PROBLEMS.md`.

### 2.4 Bit-parallel NFA simulation for small patterns
**Impact: medium-high · Effort: medium · Risk: medium**

IDEAS.md "bit-parallel NFA simulation." For patterns whose Glushkov/Thompson
state count fits in a 64/128/256-bit word, simulate the whole NFA with shift/AND/OR
over a `@Vector` mask — one machine word advances all states per byte. Pairs
naturally with the existing `@Vector` usage in `src/prefilter.zig`. Big win on
short-to-medium patterns where a full DFA table is overkill.

### 2.5 SIMD self-loop / "spin-state" skip in the DFA hot loop
**Impact: high · Effort: medium · Risk: medium · Status: SHIPPED (gated; see `docs/SIMD.md` §7)**

> **Outcome (shipped):** Implemented in `full_dfa.Dfa256.runFromSpin`, gated by
> a per-DFA `has_spin` flag (`SPIN_MIN_WIDTH = 64`: only states self-looping over
> a ≥64-byte class opt in) and `SPIN_TRIGGER = 64` (engage `prefilter.runEnd`
> only after 64 consecutive self-loop bytes). ReleaseFast, best-of-5, 1 MiB:
> `log_parse` **3.5×**, `html_tag`/`path_unix` 1.26×, `json_string` 1.21×,
> `email`/`href` ~1.2–1.3×; corpus **geomean +3.5%**. It remains a *trade* — a
> few patterns with a wide self-loop state but short runs (`xml_attr` 0.71×,
> `grok_named` 0.85×) pay the loop restructure for no skip; the per-DFA gate keeps
> the cost off every pattern without a wide self-loop. `dense_search.findFrom`
> was left scalar (its non-inlined two-branch loop tolerates no per-byte add), and
> inlining `runFromSpin` was rejected (it bloated unrelated no-spin call sites).
> The original proposal text below is kept for context.

IDEAS.md "stable local neighborhood … SIMD scan for a delimiter." The hot DFA
walk (`src/exec/full_dfa.zig`, `lazy_dfa.zig`, `dense_search.zig`, `core.zig`,
`comptime_dfa.zig`) is a serial state recurrence
(`sid = trans[sid*nc + class_of[byte]]`) and cannot be lane-parallelized in the
general case. But a large share of real matching is spent in a state that
*self-loops over a wide byte class* — `.*` consuming to a delimiter, `[^"]*`
over a string body, `\d+` munching digits. While the DFA sits in such a state
the state is invariant across the skipped bytes, so it is sound to SIMD-scan
ahead to the first byte whose class leaves the state and then resume the scalar
walk — no semantic change. The scanning primitive already exists and is
gate-tested: `Ranges.runEnd` in `src/exec/class_span.zig` is exactly "first byte
not in this class," fully `@Vector`-ized. Work: at DFA build (`freezeDense` /
`full_dfa.compute`) detect self-loop states, precompute each one's stay-class as
a `Ranges`, and branch the hot loop into `runEnd` on entry (scalar fallback
otherwise). This is the legitimate, semantics-preserving form of "accelerate the
DFA with vectors" — distinct from 2.4's bit-parallel transition, which the
serial recurrence rules out for the table walk itself.

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
**Impact: medium · Effort: small · Risk: low · Status: SHIPPED (this branch)**

> **Outcome:** Done. `Seq.isCaseInvariant()` (`src/exec/seq_extract.zig`) gates
> the four `!case_insensitive` planner branches as `(!ci or isCaseInvariant())`,
> recovering the `.literal` / `.lit_prefix` / `.reverse_suffix` fast paths for
> letter-free literals under `ci` (digits, punctuation, URLs, version strings).
> Sound because under `ci` the parser folds letters into 2-bit sets that `Seq`
> extraction already drops, so every surviving `Seq` is letter-free; the
> predicate makes that explicit. Covered by `planner.zig` routing tests +
> `tests/feat_literals.zig` match-correctness tests (cross-checked vs the
> case-sensitive engine). Letter-bearing `ci` patterns are unchanged.

The literal / literal-prefix fast paths are still gated behind
`!flags.case_insensitive` in the planner (`src/planner.zig`), so they are
disabled entirely under `case_insensitive`. Recover them by lowering the
first-byte set / literals to a case-folded byte set fed into the existing SIMD
scanner — common real-world case currently left on the table. Concretely a
`@Vector` extension: it reuses the shipped SIMD scanner in `src/prefilter.zig`
verbatim, only widening the byte set fed into it — the highest
value-per-effort SIMD item here. (Likewise 3.1's small-class cross-product
simply feeds more literals into the already-vectorized Teddy / Aho-Corasick
path.)

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

### 4.4 Reuse the vectorized class-span scans in the dup-word backref fast-path
**Impact: low-medium · Effort: tiny · Risk: low · Status: ATTEMPTED — REVERTED (net-negative)**

> **Outcome:** Tried and reverted. Routing `findCap` through `Ranges.runEnd` /
> `firstMember` regressed `backref_word` **~2.9×** (bisected: `runEnd` 1.44×,
> `firstMember` adds ~2×). English words average 4 bytes (max 14 — all < the
> 16-byte SIMD width), so `runEnd` always falls through to its scalar pin loop
> after paying full vector setup, and `firstMember` (per position) never has a
> long gap to skip. Both replace a single cheap scalar `cc.hasBit`. Unfixable
> here — words are never ≥16 bytes, so vectorization cannot win. The scalar
> path is optimal. (A standalone microbench of `findCap` mislead­ingly showed
> "neutral" because it folded away the runtime `?Ranges` unwrap + heap deref
> that the engine pays — measure inside the real engine; see `docs/SIMD.md` §9.)

The adjacent-duplicate-word backref fast-path (`src/exec/dupword.zig`, the
`(\bCLASS+\b)SEP\1` shape) still walks its maximal CLASS run one byte at a time
(`findCap`: the `while (e < n and cc.hasBit(…))` run scan and the outer
start scan), even though `src/exec/class_span.zig` already provides the
`@Vector`-ized `Ranges.runEnd` ("first non-member") and `Ranges.firstMember`
for exactly this. Build a `Ranges` from the CLASS bitmap once and route the run
scan / start scan through the existing helpers — a drop-in reuse of a
gate-tested primitive, no new SIMD code.

---

## Suggested ordering

Resolved by the `@Vector` experiment + ReleaseFast re-eval (now folded into
`docs/SIMD.md` §7–§9): **3.3 SHIPPED** (ci literal routing), **2.5 SHIPPED**
(full_dfa spin-skip, gated — geomean +3.5%), **4.4 REVERTED** (net-negative). The
big takeaway: inside the automaton/scan hot loops the scalar baseline is already
near-optimal for the short runs that survive the prefilter, so unconditional
`@Vector` work there does not pay — SIMD only helps *before* the automaton (the
shipped prefilter / Teddy / `class_span` scanners) or *behind a long-run gate*
(2.5) where runs are long.

Remaining, roughly in priority:

1. **2.3** (backtracker memoization) — would let genuinely non-regular patterns
   finish fast instead of hitting the step budget; relates to
   `docs/SECURITY_PROBLEMS.md`.
2. **1.2** (two-phase captures) — narrows the capture pass to the match region;
   complements the already-shipped `onepass` fast-path.
3. **3.1** (small-class cross-product literal expansion) — opportunistic; feeds
   more literals into the already-vectorized Teddy / Aho-Corasick path.
4. **2.4** (bit-parallel NFA) — opportunistic, pattern-dependent; note the
   short-run caveat from 2.5/4.4 likely applies to small patterns too.
5. **2.2** (bounded backtracker as first-choice capture engine on short inputs)
   and **4.3** (packrat/memoized parse guard) — incremental hardening / small
   wins.

Out of scope (from IDEAS.md, recorded for completeness): FPGA/MC-NFA offload,
multi-tier native JIT (Ignition/Sparkplug/TurboFan analog), SMT/Z3-backed
symbolic automata, multi-core data/pipeline parallelism. Brzozowski-derivative
matching is interesting but a full engine rewrite — deferred, not planned.
