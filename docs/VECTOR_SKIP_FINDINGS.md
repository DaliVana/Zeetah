# `@Vector` acceleration experiment — what we tried and what we found

A focused investigation into extending the existing `@Vector` SIMD usage
(`src/prefilter.zig`, `src/exec/class_span.zig`) into the DFA hot loops and the
`dupword` backref fast-path, plus a case-insensitive planner fix. Measured
against the cross-engine benchmark (1 MiB corpus, `min`-of-3 runs, the
`zeetah-benchmark` repo's `zig_bench` harness on the Apple-Silicon/NEON target).

> ## ⚠️ ReleaseFast re-evaluation (2026-06) — read this first
> **The original numbers below were measured in DEBUG mode.** The methodology
> command placed `-OReleaseFast` *after* the `-M` module args, which in Zig's
> multi-module CLI silently leaves every module at the Debug default (verified
> via `@import("builtin").mode`). Debug penalizes `@Vector` codegen and inflates
> the scalar loop, so the magnitudes and some verdicts were wrong. Re-ran each
> change in real ReleaseFast (interleaved min-of-9, Apple M4):
>
> | | Debug claim | ReleaseFast | Revised verdict |
> |---|---|---|---|
> | **T3** ci-literal routing | "neutral/positive" | **+8.4×** on `(?i)[A-Za-z].*9999`; neutral elsewhere | **SHIPPED — sound, clear win** |
> | **T1a** full_dfa spin-skip | "neutral at 1 MB" | **+~5×** on long self-loops; **−5–12% on short-run full_dfa workloads** (corpus geomean 0.968) | **DEFERRED — a real trade, gate it before shipping** |
> | **T1b** dense_search spin-skip | −1.5× regression | ~neutral (minimal proxy); real machinery ~−5–12% | revert defensible, magnitude was inflated |
> | **T2** dupword vectorization | −2.9× | **−1.35×** | revert correct, magnitude ~2× inflated |
>
> **This branch now ships T3 only.** T1a is deferred: its long-run upside is
> real, but on by default it taxes short-run patterns ~5–12%, so it needs a gate
> (engage only when a wide self-loop class is present *and* long runs are
> expected). The architectural thesis still holds — SIMD wins only where runs are
> long; it's just that long self-loop runs *do* occur in machine-generated data
> (minified JSON, base64, long quoted bodies), which the short-run corpus lacks.

**TL;DR (original, Debug):** the only changes worth keeping are the
**case-insensitive literal fast paths** (sound, neutral-to-positive) and a
**single adaptive SIMD spin-skip in `full_dfa`** (neutral here; upside only on
long-run inputs). Every other `@Vector` extension *regressed* and was reverted.
The recurring reason is one principle:

> **The scalar baseline is already near-optimal for the data that actually
> occurs.** A DFA step is one cache-hot table lookup per byte; a `cc.hasBit`
> class test is one indexed bit-test. A `@Vector` routine (16-byte load +
> range-`memberVec` + horizontal `@reduce` + scalar pin) only wins when it can
> skip a *long* run — and the prefilter/`seek` layer already removes the long
> non-matching stretches before these loops run, so in practice the runs left
> are short (words ≈ 4 bytes, fields/gaps ≈ 1 byte), far below the 16-byte SIMD
> width. SIMD-on-short-data loses.

---

## What was tried

| # | Change | File(s) | Verdict |
|---|--------|---------|---------|
| T3 | Case-insensitive literal/prefix/suffix fast paths | `planner.zig`, `seq_extract.zig` | **SHIPPED** — sound; +8.4× on its target case (ReleaseFast) |
| T1a | SIMD self-loop "spin-skip" in `full_dfa.Dfa256.runFrom` | `full_dfa.zig` | **DEFERRED** — +~5× long runs / −5–12% short runs; gate first |
| T1b | SIMD spin-skip in `dense_search.DenseSearch.findFrom` | `dense_search.zig`, `lazy_dfa.zig` | **REVERTED** — net-negative |
| T2 | `dupword.findCap` reuse of `class_span.Ranges` scans | `dupword.zig` | **REVERTED** — ~2.9× slower |

### T3 — Case-insensitive literal fast paths (KEPT)
Under `case_insensitive` the planner disabled the `.literal` / `.lit_prefix` /
`.reverse_suffix` fast paths entirely. Investigation showed the parser already
case-folds set bitmaps at parse time, so under `ci` a literal letter becomes a
**2-bit set** that `Seq` extraction drops — meaning every `Seq` that survives
under `ci` is already letter-free. We made that soundness condition explicit
(`Seq.isCaseInvariant()`) and relaxed the four `!case_insensitive` gates to
`(!ci or seq.isCaseInvariant())`. This recovers the fast paths for letter-free
literals (digits, punctuation, URLs like `://`, version strings) — the worst
prior case, `[A-Z].*9999` under `ci`, went from a 52-bit first-byte prefilter to
a selective suffix. Purely additive; letter-bearing `ci` patterns are unchanged.

### T1 — SIMD self-loop "spin-skip" in the DFA hot loop
Idea from `IDEAS.md` ("stable local neighborhood … SIMD scan for a delimiter").
A DFA state that *self-loops* over a wide byte class (`.*` consuming, `[^"]*`
over a string body, `\d+`) is invariant across the run, so it is sound to
SIMD-scan to the first byte that leaves the state (`class_span.Ranges.runEnd`)
and resume the scalar walk.

Three integration costs were identified and each addressed:
1. **Per-byte table load.** First version checked `stay[state]` every byte →
   replaced by *triggering on a self-loop* (`next == state`, a free register
   compare) so the spin table is consulted only when actually spinning.
2. **Struct bloat.** `[256]?Ranges` (~8.7 KB) → compact `stay_idx: [256]u8` +
   a small `stay_ranges` table (~1.3 KB), touched only on self-loop bytes.
3. **Loop restructure.** Kept the common path identical to the original loop
   plus one compare.

Crucial measured result: the trigger+compact redesign performed **identically**
to the per-byte version (median 0.999) — i.e. the per-byte check was *not* the
bottleneck. The real cost was the SIMD-setup-vs-cache-hot-lookup mismatch on
short runs. The fix that mattered was a **4th** change: **adaptive engagement** —
count consecutive self-loop bytes and only switch to `runEnd` after
`SPIN_TRIGGER` (= 64) bytes. Short runs stay 100% scalar (no regression); only
genuinely long runs pay SIMD.

- **`full_dfa` (inlined, single-table):** adaptive version is **neutral** —
  median 1.009, max 1.095 at 1 MB, no >1.10 regressions (vs the original
  per-byte version's `unicode_prop` 2.6×, `word` 2×, `email` 1.8×). **Kept.**
- **`dense_search` (non-inlined, two-branch `have`/`!have`):** even the
  *minimal adaptive restructure* regressed `semver`/`ipv4`/`phone_us`/
  `credit_card` ~1.5× and `atomic_token` 1.65× — on patterns whose digit class
  is < 16 bytes wide, so the spin set is never even built and **SIMD never
  engages**. The regression is purely the `next == sid` compare + spin counter
  pessimizing an extremely tight, non-inlined loop. **Reverted** — this loop is
  too sensitive to tolerate any per-byte addition.

### T2 — `dupword` reuse of vectorized `class_span` scans (REVERTED)
Routed `dupword.findCap`'s maximal-CLASS-run scan and word-start scan through
`Ranges.runEnd` / `Ranges.firstMember`. Regressed `backref_word` **~2.9×**
(flat 26 vs 75 MB/s across all input sizes → a uniform per-byte cost).
Bisected in the real engine: `runEnd`-only = 1.44×, `firstMember` adds ~2× more.
Causes:
- English words average **4 bytes, max 14 — all < 16**, so `runEnd` *always*
  falls through the vector chunk into its scalar pin loop: full SIMD setup to
  scan ~4 bytes, never a real vector skip.
- Inter-word gaps are mostly **1 byte**, so `firstMember` (called per position)
  never has a long run to skip and pays setup to return immediately.

Both replaced a single cheap scalar `cc.hasBit`. Unfixable even with an adaptive
threshold, because words are *never* ≥ 16 bytes — vectorization can't win here.

---

## The microbench-vs-engine lesson (important)

A standalone microbench of the *exact* `dupword.findCap` measured **neutral**
(0.94–1.14×), yet the same code in the engine regressed **2.9×**. The microbench
used a `comptime`-folded class and a global `Ranges`, so the compiler eliminated
the per-iteration `?Ranges` unwrap and the heap dereference. In the engine,
`self.class_ranges` is a **runtime optional unwrapped inside the hot loop** over
an **opaque heap `Ranges`**, and the overhead is fully exposed.

> **A `@Vector` primitive that benchmarks neutral *in isolation* can still
> regress several-fold once it sits behind a runtime branch + pointer
> indirection in a tight loop. Always measure inside the real engine.**

Corollary: LLVM version is not the lever. The kernel throughput is **identical**
under Zig 0.16 (LLVM 18) and 0.17-dev (newer LLVM) — within <1.5% across all
run-length regimes. (Note: the engine does not yet build on 0.17-dev — the `**`
repetition operator was removed there; ~144 sites would need porting to
`@splat`.) The self-hosted backend OOM-killed on this aarch64-macOS target.

---

## Benchmark methodology notes (for reproducing)

- Build one harness per engine variant — **`-OReleaseFast` MUST precede the
  `-M` args** (in Zig's multi-module CLI the optimize mode applies to modules
  defined *after* it; placed last it silently builds Debug — the bug that
  invalidated the original numbers here):
  `zig build-exe -OReleaseFast --dep zeetah -Mroot=zig_bench.zig -Mzeetah=<src/root.zig> -lc`.
  Confirm with `@import("builtin").mode`.
- Run-to-run variance is ~±10 % on small inputs; **aggregate `min` of ≥3 runs**
  and judge at the **1 MiB** size. Establish a noise floor (base-vs-base) before
  trusting any single outlier.
- **Isolate one change at a time.** Several false attributions happened when
  comparing builds that bundled multiple changes (e.g. `backref_word` and
  `atomic_token` regressions came from *different* changes than first assumed).
- Correctness is gated by the cross-engine `aggregate.py` match-count gate —
  every variant here kept it green (0 mismatches across all engines/workloads).

## Where SIMD *does* pay in this engine
The shipped, winning `@Vector` uses share one trait — they run **before** the
automaton, over long stretches the match can't start in: the first-byte / Teddy
/ Aho-Corasick prefilters and the whole-pattern `class_span` (`class+`) scanner
in `src/prefilter.zig` / `src/exec/class_span.zig`. That is the regime where the
runs are long and the scalar alternative (per-position automaton restart) is
expensive. Inside the automaton hot loop, the scalar step is already too cheap
to beat on the short runs that survive the prefilter.
