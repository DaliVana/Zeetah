# zeetah — Readability, Maintainability & NASA Power-of-10 Review

**Date:** 2026-06-27 · **Commit:** `7f1fdc0` · **Version:** 0.16.1 · **Scope:** `src/` (41 files, ~18,200 lines)

> Source-file links in this document are relative to this `docs/` directory (`../src/...`).

## Methodology

This review was produced by a multi-agent pass over the whole engine: 16 file-cluster reviewers (each
finding adversarially re-verified against the cited code by an independent skeptic), 10 NASA Power-of-10
global rule auditors, an architecture mapper, and a synthesizer. 144 findings were confirmed; 1 was
rejected as a false positive. Two C-oriented conventions were adapted to Zig before judging:

- **`fn Name(comptime X) type { ... }` is Zig's generic / parametric-struct idiom** — a module/class
  factory returning a struct type, *not* a single leaf function. Its body is **not** counted against
  Rule 4 (function length); the leaf functions/methods *inside* it are.
- **Comptime recursion and comptime/build-time allocation are "initialization"** — Rule 1 flags only
  *runtime* unbounded recursion; Rule 3 flags only *per-match steady-state* allocation.

The known O(n²) `<class>+$` unanchored search and its intentional red-team test marker are a documented,
tracked limitation and were treated as out of scope.

## Status — work completed since this review (2026-06-27)

Part of this review has been actioned in the working tree. Every change below was validated under **both**
`zig build test` (Debug) and `zig build test -Doptimize=ReleaseSafe` (optimized codegen + safety checks +
the new asserts active); the comptime⇄runtime differential and the security/ReDoS suite are the behavioral
guard for the refactors.

**Zero-risk hardening**
- ✅ **#2 capacity assertions** on the fixed-size hot-construction buffers (`dfa_build.closure`,
  `full_dfa.compute`/`computeReverse`, and `lazy_dfa` `closureRev`/`step`/`aStep`/`uStep`/`rStep`).
- ✅ **`slotsToCaps` group-0 precondition assert** (pattern.zig detailed finding #5).
- ✅ **#8 dead code deleted** — `profiling.zig` and `benchmark.zig` removed; `root.zig` comment updated.
- ✅ **#9 ReleaseSafe CI job** added to `.github/workflows/ci.yml`.
- ✅ **#10 doc drift fixed** — `thread_safety.zig` rewritten to the real pooled-scratch mechanism; the
  `unicode_tables.zig` header prose moved into the generator's emit block; the stale `compress` "inline
  bake" comment corrected (pattern.zig detailed finding #4).

**Structural refactors**
- ✅ **#1 cascades decomposed** — `regex.zig:compileWithFlags` 442→178 lines (8 named arm helpers) and
  `pattern.zig:buildAll` 256→65 lines (7 named arm helpers), with matching helper names + order so the
  comptime⇄runtime correspondence is diffable. Routing logic was moved verbatim (differential-tested
  identical; only `&h`→`h`/`h.*` pointer adjustments and one `if`→early-return tidy in `tryClassSpan`).
- ✅ **#5 unified capture-numbering recognizer** — the standalone `scanGroups` byte-scanner (a second copy
  of the paren/class/escape/lookaround grammar) was **deleted**; both front-ends now read the numbering +
  names the parser itself emits via the new `parser.parseCaptures` (−51 lines net). The runtime parses the
  `Regex`-owned copy so the `(?<name>)` name slices stay alive. `tests/capture_numbering.zig` was
  repurposed to guard the single recognizer's internal consistency (reported count == baked `.cap` nodes,
  contiguous 1..N, in-lookaround captures excluded) over a divergence-prone corpus. There is now nothing
  to keep in sync — the duplication is gone, not just guarded.

**Still open:** #3 (dedup the 4× DFA run loops), #4 (shared `\p{}` spec parser), #6 (one canonical
`hasBit`/`Span`), #7 (name the anti-ReDoS budget constants + dense-route predicate).

## Executive summary

zeetah is a high-quality, two-front-end regex engine whose code is unusually well-documented — doc
comments are genuinely load-bearing, soundness arguments are written inline, and tuning constants are
mostly justified against measurements. The structural foundations are strong: **zero file-scope mutable
globals**, an immutable-by-default `const`:`var` skew, error-union propagation everywhere (838 `try`,
zero empty `catch {}`), pooled allocation-free matching with a hard-capped (8192-state) lazy DFA, and a
differential test harness pinning comptime↔runtime parity. The few things that actually matter are
concentrated and recurring. **First**, two oversized dispatch cascades — `regex.zig:compileWithFlags`
(442 lines) and its comptime twin `pattern.zig:buildAll` (256 lines) — must be hand-kept in behavioral
lockstep, and the same length problem recurs in the DFA builders (`full_dfa.compute`/`computeReverse`).
**Second**, a family of fixed-size hot-construction buffers (`seeds[]`, closure `stack[]`, capture slots)
are written with no capacity assertion, guarded only by non-local edge-count invariants — exactly the
silent-overflow class that bites under user-chosen ReleaseFast. **Third**, pervasive duplication (the DFA
run loops copied across `Dfa256`/`PackedDfa`, `hasBit` in 7+ files, the reverse-reachability scan
triplicated, the spec parser copied verbatim between full-Unicode and Latin-1 paths, the comptime
front-end's HIR-bake and verb re-export blocks) creates drift hazards that only differential tests — not
the type system — currently catch. None of these are confirmed correctness bugs; the residual risk is
maintainability and defense-in-depth, not behavior. Two latent traps are worth fixing outright: the
unguarded group-0 `@intCast` in `pattern.zig:slotsToCaps` (panics in safe builds if ever called with an
unset whole-match span) and a stale `pattern.zig:compress` doc comment that describes an "inline bake"
that no longer exists.

## NASA Power-of-10 scorecard

| Rule | Status | Headline |
|------|--------|----------|
| 1 — No goto/recursion | Compliant | Zero goto; runtime recursion bounded by depth+step budgets or converted to explicit-stack loops. |
| 2 — Bounded loops | Compliant | Every loop provably terminates; the lone literal exception is one well-documented TAS spinlock. |
| 3 — No alloc after init | Mostly compliant | Hot path is pooled/alloc-free; lazy DFA cache hard-capped at 8192 with flush/restart. |
| 4 — Functions ≤60 lines | **Partial** | ~93% comply; the genuine offenders are the two engine-selection cascades and the powerset DFA builders. |
| 5 — ≥2 assertions/fn | **Partial** | Literal density ~0.5%; spirit met by Zig safety + error unions, but the assert-free hot path is unchecked under ReleaseFast. |
| 6 — Smallest scope | Mostly compliant | No mutable globals; the 31-field `Regex` god-struct is scope-gated by a `kind` tag, not by the compiler. |
| 7 — Check return values | Compliant | No return/error silently dropped; planner accelerators map failure to a correct slow-path fallback. |
| 8 — Limit preprocessor (comptime) | Compliant | Disciplined generic factories + compile-time validation; near-zero reflection/codegen. |
| 9 — Limit pointers | Compliant | Exactly 2 justified type-erasure function pointers; no deep deref chains. |
| 10 — Clean compile | Mostly compliant | Zero diagnostics, no globally-disabled safety; gap is that the shipped ReleaseFast path is never test-exercised. |

**Rule 4 (partial):** 19 leaf functions exceed 60 lines; the priority pair is `compileWithFlags` (442)
and `buildAll` (256), which also carry the cross-front-end drift coupling, followed by `full_dfa.compute`
(243) / `computeReverse` (121). The `fn Name(comptime X) type` factories (Parser, Pattern, BacktrackerG,
Dfa, Nfa, …) are module/class factories and correctly excluded.

**Rule 5 (partial):** Do not chase the literal "2/fn" count. The real gap is ~10–15 hot-path functions
(`full_dfa.step`/`runFrom`, `bounded_bt.recCap`, `onepass.fill`) whose build-established structural
invariants (`state < n_states`, `slot < MAX_SLOTS`) are compiled out under ReleaseFast; converting the
~28 prose preconditions into `std.debug.assert` closes this at zero release cost.

**Rule 6 (mostly compliant):** Only finding is `Regex` (31 fields, ~24 engine-specific and null for all
but the active `kind`); a `kind: union(enum)` would make field scope compiler-enforced.

**Rule 10 (mostly compliant):** Compile is clean by construction (Zig has no warning tier; unused vars
are errors). The intent-gap is that CI tests only in Debug while the published artifact is ReleaseFast
(212 `@intCast` unchecked there) — fix is a `zig build test -Doptimize=ReleaseSafe` job, not source
changes.

## Top priorities

1. **[High · ✅ DONE] Decompose the two engine-selection cascades and end their hand-synced coupling.**
   `regex.zig:compileWithFlags` ([../src/regex.zig:451](../src/regex.zig#L451)–892, 442 lines) and
   `pattern.zig:buildAll` ([../src/pattern.zig:512](../src/pattern.zig#L512)–767, 256 lines) each thread
   ~13 engine arms with their own create/errdefer bookkeeping, and the two front-ends must stay
   behaviorally identical with only a differential test as the safety net. *Fix:* extract each arm into a
   named `tryEdgeLook/trySplitAlt/tryDupWord/…/buildRegularDfa` helper returning `?Regex`/`?Built`
   (mirroring the existing `buildDenseRegex`/`buildLazyRegex` factoring), collapsing each cascade to an
   ordered `if (try tryX(...)) |r| return r;`. This attacks Rule 4, the deep-nesting cognitive load, the
   errdefer/ownership footgun, and the doc/code drift simultaneously.

2. **[High · ✅ DONE] Add capacity assertions to the fixed-size hot-construction buffers.** The subset-construction
   `seeds[MAX_EDGES]` and closure DFS `stack[MAX_EDGES]`/`out[MAX_NFA]` are filled with no bounds check,
   guarded only by a non-local edge-count argument in thompson.zig comments — the silent-overflow class
   Rule 7 targets. Sites: [../src/exec/dfa_build.zig:139](../src/exec/dfa_build.zig#L139)–159 (closure
   pushes targets *before* the `seen[]` dedup, so `sp` is bounded by edge multiplicity, not `MAX_EDGES`),
   [../src/exec/full_dfa.zig:505](../src/exec/full_dfa.zig#L505)–516 and :646, and
   [../src/exec/lazy_dfa.zig:240](../src/exec/lazy_dfa.zig#L240)–267 (`closureRev`) + the four gather
   loops (480–591). *Fix:* `std.debug.assert(sp < stack.len)` / `assert(ns < seeds.len)` /
   `assert(len < out.len)` before each accumulating write — free in ReleaseFast, converts silent
   corruption into a trap, documents the fan-out invariant.

3. **[High] Collapse the duplicated DFA run loops and the seed-collection gather.**
   `runFromPlain`/`runFromSpin` are copy-pasted across `Dfa256` and `PackedDfa`
   ([../src/exec/full_dfa.zig:122](../src/exec/full_dfa.zig#L122)–195 vs 264–327, doc-commented "Verbatim
   port"), and the PackedDfa copies have **no differential coverage** (the test at :822 exercises only
   Dfa256). The match semantics (DEAD-sink break, last_accept, `a_end` suffix rule, spin-skip) are the
   engine's correctness core, now in four hand-synced places. Separately, the lazy-DFA gather is copied
   four times across `step`/`aStep`/`uStep`/`rStep`
   ([../src/exec/lazy_dfa.zig:476](../src/exec/lazy_dfa.zig#L476)–606). *Fix:* make the loop generic over
   a `step(state, cls)` accessor via `inline fn runImpl(dfa: anytype, ...)` (the technique
   `line_dfa.matchEnd` already uses); extract a shared `collectSeeds(...)` for the gather.

4. **[High] Extract the shared spec parser between the full-Unicode and Latin-1 `\p{}` resolvers.**
   `resolve` ([../src/unicode_class.zig:250](../src/unicode_class.zig#L250)–313) and
   `resolveLatin1Bitmap` (330–393) duplicate ~30 lines of negation/alias/unsupported-vs-unknown parsing
   verbatim; the doc even says it is "copied verbatim so the error contract is identical." A one-sided
   edit silently diverges `\p{}` membership comptime vs runtime. *Fix:* one private
   `parseSpec(...) error{...}!struct{found, negated}` called by both, branching only on
   RangeList-vs-bitmap materialization — makes the identical error contract structural.

5. **[High · ✅ DONE] Make capture-numbering a single recognizer instead of two hand-synced grammars.**
   `scanGroups` ([../src/parser.zig:288](../src/parser.zig#L288)–367) re-implements the same
   paren/class/escape/lookaround grammar that `parsePrimary`/`openGroup`
   ([../src/parser.zig:898](../src/parser.zig#L898)–1018) implements; the comment notes a `(?=(a)b)(a)(b)`
   mis-numbering bug this duplication already caused. *Fix:* have the real parse emit the canonical
   numbering+names, or factor one shared `classifyParen(pat, i)` helper; at minimum add a cross-check test
   asserting `scanGroups` count/names equal the parser's final `n_groups`/names over the bench corpus.

6. **[Medium] Promote one canonical `hasBit` / `Span` and delete the per-module copies.** The 32-byte
   bitset membership test is byte-identical in 7+ files under two names (`hasBit`/`bitsetHas`/`inSet`):
   [../src/exec/charclass.zig:14](../src/exec/charclass.zig#L14) (already `pub`), dfa_build.zig:19,
   full_dfa.zig:44, lazy_dfa.zig:59, onepass.zig:53, seq_extract.zig:69, prefilter.zig:112. `Span` is
   structurally redeclared in 5 modules ([../src/exec/search.zig:23](../src/exec/search.zig#L23) is
   canonical) — nominally-distinct types that defeat the "one nominal Span" header. *Fix:* import
   `charclass.hasBit` (or hoist to common.zig) everywhere; alias `search.Span` in
   dense_search/backtrack/onepass/bounded_bt/dupword.

7. **[Medium] Name the anti-ReDoS step-budget constants and the dense-route predicate.**
   [../src/exec/backtrack.zig:421](../src/exec/backtrack.zig#L421) `self.budget = 8000 + (input.len+1)*4000`
   is the single most safety-relevant tunable in the file, written as two bare literals. Separately,
   `buildDenseRegex` is called from two duplicated guard sites
   ([../src/regex.zig:785](../src/regex.zig#L785)–816) where guard 2 is load-bearing for the $-anchored
   anti-ReDoS guarantee. *Fix:* hoist `BUDGET_BASE`/`BUDGET_PER_BYTE` with a comment defining a "step";
   factor the lever-A decision into one `denseRoute(...)` predicate so the guard has one definition and
   one test point.

8. **[Medium · ✅ DONE] Delete the dead `profiling.zig` and `benchmark.zig`.**
   [../src/profiling.zig:1](../src/profiling.zig#L1)–241 is never imported/built/tested and has already
   silently rotted (the `Instant` stub zeroes all timings; `format` uses the removed pre-0.16 4-arg
   signature). [../src/benchmark.zig:1](../src/benchmark.zig#L1)–52 is likewise orphaned with a latent
   divide-by-zero on `iterations==0`. *Fix:* delete both (and drop `profiling` from the root.zig:28 list),
   or wire them into `internal.zig` so `refAllDecls` compiles them — do not leave them half-attached.

9. **[Medium · ✅ DONE] Add a ReleaseSafe CI test job.** CI runs `zig build test` in Debug only; the shipped
   ReleaseFast artifact (212 `@intCast`, assert-free hot loops) is never executed under test
   ([../build.zig:11](../build.zig#L11), ci.yml:27/50). *Fix:* add `zig build test -Doptimize=ReleaseSafe`
   — keeps all bounds/overflow/cast checks active over the optimization-adjacent codegen, directly
   mitigating the Rule 5 and Rule 10 gaps with no source change.

10. **[Medium · ✅ DONE] Fix the thread-safety doc and the generated-table header drift.** The 80-line
    `ThreadSafety` doc ([../src/thread_safety.zig:3](../src/thread_safety.zig#L3)–82) claims "no shared
    mutable state / no internal caching," contradicted by the per-`Regex` `lazy_pool`/`bt_pool` scratch
    ([../src/regex.zig:238](../src/regex.zig#L238)–250) — the conclusion (safe) holds but the stated
    *mechanism* is wrong. Separately, [../src/unicode_tables.zig:7](../src/unicode_tables.zig#L7)–12
    contains hand-written prose the generator does not emit, so regeneration silently deletes it. *Fix:*
    rewrite the thread-safety doc to describe the real mechanism (immutable program +
    internally-synchronized scratch pools); move the table-header prose into the generator's emit block.

## Readability

- **Oversized multi-concern leaf functions** force the reader to hold a whole state machine in view:
  `compileWithFlags` (442, [../src/regex.zig:451](../src/regex.zig#L451)), `buildAll` (256,
  [../src/pattern.zig:512](../src/pattern.zig#L512)), `compute` (243,
  [../src/exec/full_dfa.zig:578](../src/exec/full_dfa.zig#L578)), `parsePrimary` (~180, with a 5×-copied
  modes-save/parseAlt/restore/expect-`)` close sequence,
  [../src/parser.zig:898](../src/parser.zig#L898)), `capturesFrom` (111, five capture strategies in one
  labeled block, [../src/regex.zig:1148](../src/regex.zig#L1148)), `main` (147,
  [../src/main.zig:29](../src/main.zig#L29)). The DFA run loops also scatter `i`/`last_accept` updates
  across spin/non-spin branches with a duplicated tail
  ([../src/exec/comptime_dfa.zig:219](../src/exec/comptime_dfa.zig#L219)–260).
- **Terse single-letter names in the hottest safety-critical control flow:** the CPS tree-walker
  `m`/`cont`/`k`/`l`/`c`/`e`/`w`/`g`/`su` ([../src/exec/backtrack.zig:156](../src/exec/backtrack.zig#L156)–367)
  and the bounded-BT `seen`/`pushReach`/`pushCap` dirty-tracking (`w`/`bit`/`sp`/`n`,
  [../src/exec/bounded_bt.zig:159](../src/exec/bounded_bt.zig#L159)). Mechanical rename is low-risk,
  high-payoff in the audited path.
- **Magic numbers lacking a name or rationale:** the 32-byte bitset `>>3`/`&7` decomposition repeated
  across prefilter/common/exec; spin-tuning `16`
  ([../src/exec/comptime_dfa.zig:295](../src/exec/comptime_dfa.zig#L295)), `SPIN_TRIGGER=64` duplicated
  across two files, `flushes > 8` ([../src/exec/lazy_dfa.zig:293](../src/exec/lazy_dfa.zig#L293)/399),
  `skipToStart` thresholds `8`/`16` ([../src/exec/core.zig:41](../src/exec/core.zig#L41)). The fixed
  64-byte normalize buffers ([../src/unicode_class.zig:41](../src/unicode_class.zig#L41)) silently
  truncate over-length `\p{}` names.
- **Doc/code drift in comments:** a stale ~19-line docblock precedes `reverseScan` describing a
  refactored-away function ([../src/exec/lazy_dfa.zig:334](../src/exec/lazy_dfa.zig#L334)–352); the
  `runFrom` contract block is misattached above `step`
  ([../src/exec/full_dfa.zig:92](../src/exec/full_dfa.zig#L92)–114); the `leadingLookbehindSet` doc
  describes a different function first
  ([../src/exec/seq_extract.zig:606](../src/exec/seq_extract.zig#L606)–620); `isOnePass`'s header
  references abandoned reasoning ([../src/exec/onepass.zig:17](../src/exec/onepass.zig#L17)–19); two
  stacked drifted doc blocks on `shuf` ([../src/prefilter.zig:567](../src/prefilter.zig#L567)–575); and
  the `compress` "inline bake" claim ([../src/pattern.zig:71](../src/pattern.zig#L71)–86) describes code
  structure that no longer exists.
- **Dense soundness predicates as negated boolean arithmetic** that decide O(n) vs O(n²)-vulnerable
  routing — name the intermediates ([../src/properties.zig:333](../src/properties.zig#L333), :192).
  Lookaround flags decoded via bit math out of a field named `set_idx`
  ([../src/exec/edge_look.zig:94](../src/exec/edge_look.zig#L94)) deserve `isBehind()`/`isNegative()`
  accessors.

## Maintainability

- **Duplication that must be hand-kept in lockstep** (the dominant theme): the DFA run loops (4 copies),
  `hasBit`/`Span` (7+/5 copies), the reverse-reachability scan triplicated across
  `dense_search.findFrom` ×2 and `search.reverseSearch`
  ([../src/exec/dense_search.zig:66](../src/exec/dense_search.zig#L66)–118), the Unicode spec parser, the
  `scanGroups`/`parsePrimary` grammar, `intern`/`rintern`
  ([../src/exec/lazy_memo.zig:82](../src/exec/lazy_memo.zig#L82)–142), three structurally identical
  literal-set containers + four spine flatteners with divergent overflow semantics
  ([../src/exec/seq_extract.zig](../src/exec/seq_extract.zig)), ~14 fixed-token builder methods + three
  hand-rolled concat loops std could replace ([../src/builder.zig:57](../src/builder.zig#L57)–197),
  `findLeftmost`/`isMatch` ([../src/exec/core.zig:70](../src/exec/core.zig#L70)–118). Each is a "fix one,
  miss the others" trap.
- **Type-safety footguns where an invariant is convention-only, not compiler-enforced:**
  `delegate.Plan.deinit` blind-casts every erased island pointer to `*PackedDfa`
  ([../src/exec/delegate.zig:143](../src/exec/delegate.zig#L143)) — a comptime-baked .rodata plan would be
  `@constCast`-freed (UB); `Seek` is a 6-optional union-by-convention whose mutual exclusion is enforced
  only by `build`'s control flow ([../src/exec/seek.zig:74](../src/exec/seek.zig#L74)–151);
  `split_alt.Seg` uses a tag + two parallel optionals that `run` and `freeSegItems` read from different
  fields ([../src/exec/split_alt.zig:37](../src/exec/split_alt.zig#L37)). Each is the canonical
  "make-illegal-states-unrepresentable via `union(enum)`" candidate, sharing root cause with the `Regex`
  god-struct (Rule 6).
- **`Regex.deinit` hand-frees 14 owned optionals with four distinct teardown idioms** ~450 lines from
  their construction sites ([../src/regex.zig:894](../src/regex.zig#L894)–937); a field added but
  forgotten leaks silently. Add a per-`MetaKind` deinit test under the testing allocator.
- **Two near-identical predicates with confusable names:** `isOnePass` (match-shape signal) vs
  `isOnePassNfa` (capture-correctness gate, [../src/exec/onepass.zig:34](../src/exec/onepass.zig#L34)/68)
  — a future caller gating captures on the wrong one silently corrupts captures. Rename to
  `dfaMatchIsOnePass`/`isCaptureOnePass`.
- **Generated-table provenance gaps:** no CI check that the committed tables match generator output, and
  regeneration is not reproducible (undated/unhashed UCD input,
  [../tools/gen_unicode_tables.zig:11](../tools/gen_unicode_tables.zig#L11)). The UCD input is *not*
  committed, so a hermetic regenerate-and-diff requires a deliberate vendoring change; a `unicode_version`
  assertion test is the cheap interim.
- **Magic/edge-kind integers as a bare protocol** (`0=eps,1=consume,2=look`) hand-assigned in thompson
  and switched with an `else`-catches-consume arm in onepass/closureOk
  ([../src/thompson.zig:55](../src/thompson.zig#L55), [../src/exec/onepass.zig:85](../src/exec/onepass.zig#L85))
  — a 4th kind misclassifies silently. Define `enum(u8) EdgeKind` and switch exhaustively.

## `pattern.zig` — comptime front-end (detailed)

The comptime twin of `regex.zig`'s `compileWithFlags`: `Pattern(pattern, opts)` runs the full
parse→HIR→NFA→DFA pipeline at compile time and monomorphizes a baked matcher into `.rodata`. Impressive,
security-conscious comptime engineering; its weaknesses are all about duplication that must stay in
lockstep, plus two latent correctness traps.

1. **[High · ✅ DONE · Rule 4 / maintainability] `buildAll` is a 256-line leaf function.**
   [../src/pattern.zig:512](../src/pattern.zig#L512)–767. A flat sequence of eight strategy-routing gates,
   each hand-constructing a wide `Built` struct literal — the routing brain and the designated lockstep
   peer of `compileWithFlags` (see Top priority #1). *Fix:* extract each gate into a named `try*` helper
   returning `?Built`; `buildAll` becomes an `orelse` chain.

2. **[High · maintainability/readability] Eight near-identical 12-line verb/capture re-export blocks.**
   [../src/pattern.zig:1414](../src/pattern.zig#L1414), 1485, 1536, 1576, 1600, 1638, 1714, 1819. Each
   returned arm ends with a copy-pasted `const V = WholeMatchVerbs(...)` / `const C = CaptureSupport(...)`
   re-export block (forced by Zig 0.16 dropping `usingnamespace`). Worse, the blocks are *subtly
   inconsistent* — some arms define a specialized `isMatch` and omit it from the re-export, others include
   it — so they look identical but aren't. *Fix:* one comptime mixin factory
   (`WholeMatchArm(nextSpanFrom, built, opts)`) supplying the common members, with the `isMatch`-override
   as an explicit parameter; collapses ~110 lines.

3. **[Medium · maintainability] Baked-HIR comptime block duplicated verbatim.**
   [../src/pattern.zig:925](../src/pattern.zig#L925)–938 and 1227–1242. The "trim `HIR_CAP`=2048 store to
   an exact-sized `Hir(NN)`" field-copy appears twice; a new `hir.Hir` field updated in only one copy
   silently bakes a stale/`undefined` field into `.rodata`. *Fix:* extract `fn bakeExactHir(...)` and call
   it from both sites (mirroring how `compressTo` is the single source of truth for the DFA bake).

4. **[Medium · ✅ DONE · readability/maintainability] Stale, self-contradictory `compress` doc comment.**
   [../src/pattern.zig:71](../src/pattern.zig#L71)–86. Claims "the main matcher table bakes the same shape
   **inline** in the `use_dfa` arm below. Field-for-field identical to that inline bake." Verified false:
   the `use_dfa` arm calls `compress(m)` (line 1745); the only field-by-field bake is in `compressTo`
   (102–137). A reader will hunt for a non-existent inline bake. *Fix:* replace with one accurate sentence
   naming `compressTo` as the single field-mapping source of truth.

5. **[Medium · ✅ DONE · Rule 7] `slotsToCaps` unconditionally `@intCast`s the group-0 slots.**
   [../src/pattern.zig:1047](../src/pattern.zig#L1047)–1059. Groups `1..NG+1` are guarded
   (`if (s >= 0 and e >= 0 and s <= e)`) but group 0 is cast with no guard; the unset sentinel is `-1`, so
   `@intCast(-1)` to a `usize` index panics in safe builds. Safe today *only by caller discipline* (every
   `capturesFrom` path pre-fills slots 0/1). *Fix:* assert `slots[0] >= 0 and slots[1] >= 0` at entry (or
   apply the same `>= 0` guard to group 0), and document the asymmetry.

6. **[Low · Rule 2/readability] `flattenAlt` counts past the buffer cap.**
   [../src/pattern.zig:216](../src/pattern.zig#L216)–226. Writes `out[n.*]` only when
   `n.* < MAX_ALT_BRANCHES` but always increments `n.*`, relying on the caller's after-the-fact
   `n > MAX_ALT_BRANCHES` rejection (line 242). Correct and comptime-only (a bug is a compile error), but
   easy to misread as an OOB write. *Fix:* a one-line comment at the increment, or return
   `{ n, overflowed }` to make the over-wide signal explicit.

7. **[Low · maintainability] Capture-path duplication (seek + alt-dispatch baking).**
   `cap_seek`/`cap_alt_*` in `CaptureSupport` ([../src/pattern.zig:998](../src/pattern.zig#L998)–1044)
   duplicate `bt_seek`/`alt_*` in the `.backtrack` arm (1313–1336, 1264–1275). Partly forced (two distinct
   returned struct types can't share a `const`), but the three-way seek-layering *precedence* is now
   duplicated and must match the runtime `seek.Seek`. *Fix:* hoist `buildSeek(...)`/`buildAltDisp(...)`
   free comptime helpers; only the per-struct `const` bake stays at each site.

8. **[Info · maintainability] Un-named comptime eval-branch quotas.**
   [../src/pattern.zig:100](../src/pattern.zig#L100), 237, 387, 422, 437, 482, 513, 1463. Quotas span
   `1_000_000`…`50_000_000` as bare magic numbers — the comptime-budget equivalent of the runtime step
   budget, load-bearing and un-greppable as a group. *Fix:* name them (`BUILD_QUOTA`, `AC_TRIM_QUOTA`)
   with one comment on the scaling relationship to `HIR_CAP`/`MAX_NFA`.

9. **[Info · maintainability] Aho-Corasick automaton built twice (decide, then rebuild to trim).**
   `buildAll` builds AC to decide the `.boundary_lits` route
   ([../src/pattern.zig:594](../src/pattern.zig#L594)), discards it, and the arm rebuilds it to trim
   ([../src/pattern.zig:1466](../src/pattern.zig#L1466)) — deliberate, to keep the 528 KB AC out of the
   one-concrete-type `Built`. Comptime-only, so a mismatch is a compile error. *Fix:* none needed; add an
   `// INVARIANT:` cross-reference at both sites so the intentional double-build survives future
   "deduplication."

## Per-module quality scores

| Module | Readability /5 | Maintainability /5 | One-line note |
|--------|:---:|:---:|---|
| seq-extract (`seq_extract.zig`) | 5 | 4 | Exemplary soundness docs; watch runtime tree-recursion depth bound + container triplication. |
| unicode-class+properties | 4 | 4 | Strong; Unicode spec-parser duplication is the one real drift hazard. |
| unicode-tables (generated) | 4 | 4 | Well-provenanced; header prose + no regen-check are the gaps. |
| comptime-dfa+dense | 4 | 4 | Excellent why-comments; triplicated reverse pass is the drift risk. |
| onepass+split+lookaround | 4 | 4 | Conservative, well-justified fast paths; edge-kind ints + two "one-pass" predicates. |
| frontend-ir | 4 | 4 | Elegant dual-cap IR + model planner; ceiling-constant fragmentation + builder duplication. |
| surface-cli | 4 | 4 | Exemplary public API; dead benchmark code + unbounded stdin. |
| runtime-api (`regex.zig`) | 4 | 3 | Heavily/accurately documented; risk concentrated in one 442-line constructor + manual deinit. |
| comptime-entry (`pattern.zig`) | 3.5 | 3 | Impressive comptime engineering; `buildAll` length + HIR/verb/seek duplication + stale `compress` doc + unguarded group-0 cast. |
| parser | 4 | 3 | Bounded, accurate, well-commented; `scanGroups`/`parsePrimary` grammar duplication stands out. |
| prefilter | 4 | 3 | Dense SIMD with scalar references + differential tests; 4× scan-body duplication. |
| infra | 4 | 3 | Clean live modules; orphaned `profiling.zig` + untested `SharedRegex`. |
| exec-support | 4 | 3 | Soundness written inline; `delegate` type-erasure footgun + `hasBit`/`Span` proliferation. |
| lazy-dfa | 3 | 3 | Mature thread-aware design; unchecked scratch buffers + 4× gather duplication. |
| full-dfa-build | 3 | 3 | Load-bearing docs; 240-line builders + unasserted seed/closure buffers + run-loop duplication. |
| backtrackers | 3 | 4 | Strong safety reasoning (budget/depth/dirty-reset); terse names + magic budget constants. |

## What's already good

- **Zero file-scope mutable globals** across 41 files — the strongest Rule 6 signal, achieved
  structurally, not by convention.
- **The two-path architecture** (comptime `Pattern` → .rodata, runtime `Regex.compile`) with a single
  shared IR/parser and a differential harness pinning behavioral parity — genuinely hard to get right, and
  the `anytype`/generic-factory monomorphization keeps it type-safe without runtime indirection.
- **Allocation discipline:** the matching hot path is pooled and alloc-free after warm-up, the one growing
  structure (lazy DFA cache) is hard-capped at 8192 with an RE2-style flush/restart, and OOM surfaces as
  typed errors with correct `errdefer` ladders — Rule 3's spirit fully met for an allocator-injecting
  library.
- **Error handling:** 838 `try`, zero empty `catch {}`, and a deliberate, documented design where planner
  accelerators map failure to a correctness-equivalent slow-path fallback (`delegate.zig`: "never an
  error, never a wrong plan") — Rule 7 compliant.
- **Documentation quality is the codebase's standout strength:** doc comments are load-bearing, soundness
  arguments and performance tradeoffs are written inline, SIMD paths are paired with scalar references and
  exhaustive differential tests, and most tuning constants cite their rationale.
- **Recursion/loop discipline:** every runtime recursion carries an explicit depth/step/visited bound (the
  bounded backtracker was deliberately rewritten to an explicit grown stack), every loop provably
  terminates, and the comptime pipeline compiles cleanly with no globally-disabled safety — Rules 1, 2, 8,
  9 effectively met.
- **A minimal, well-curated public surface** (`root.zig`/`errors.zig` are exemplary, with stability
  reasoning in the doc comments) and a thread-safe pooled-scratch concurrency model that is actually
  correct — even where its doc describes the wrong mechanism.
