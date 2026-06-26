# SIMD implementation

This document is the detailed reference for the data-parallel (`@Vector` / byte-shuffle)
code in Zeetah: **what** is vectorized, **where** it lives, **how** it stays
portable and correct, and the **principle** that decides where SIMD is used and
where it deliberately is not.

> **One-line thesis.** Zeetah vectorizes the work where runs are *long*: finding
> where a match could begin (the prefilters), bulk-consuming a whole-pattern class
> run (`class_span`), and skipping a DFA state's long self-loop run in one scan
> (the adaptive spin-skip, §7). It never vectorizes the *per-byte* automaton step
> — a DFA transition is a single cache-hot table lookup, and a 16-byte vector
> kernel only wins when it can skip a long stretch. The prefilter/seek layer
> already strips the long non-matching gaps, so the per-byte path is left with
> short runs where SIMD has nothing to skip. The boundary between "vectorize" and
> "stay scalar" is **measured, not assumed** (§7–§9).

---

## 1. Where the SIMD lives

| File | Role | SIMD primitive |
|------|------|----------------|
| [`src/prefilter.zig`](../src/prefilter.zig) | First-byte set scan + Teddy multi-literal kernel + (scalar) Aho-Corasick | portable `@Vector` compare/`@reduce` + arch byte-shuffle (`pshufb`/`vpshufb`/`tbl`) |
| [`src/exec/class_span.zig`](../src/exec/class_span.zig) | `class+` / `class*` member-run scanner (whole pattern is one greedy class repetition) | portable `@Vector` + NEON-shaped `@reduce(.Max/.Min)` |
| [`src/exec/full_dfa.zig`](../src/exec/full_dfa.zig) | Adaptive self-loop **spin-skip** in the DFA hot loop (`runFromSpin`) | consumes `prefilter.runEnd` (§7) |
| [`src/exec/search.zig`](../src/exec/search.zig) | Wires the prefilters into both DFA front-ends; reverse-inner literal anchor (§8) | consumes the above + `memchr` |
| [`src/exec/seek.zig`](../src/exec/seek.zig) | Over-approximation prefilter for the backtracker tier | consumes `class_span.Ranges.firstMember` |
| [`src/regex.zig`](../src/regex.zig) | Routes a trivial `class+`/`class*` pattern to `class_span` | dispatch only |

The data-parallel *kernels* are concentrated in `prefilter.zig` (the bulk) and
`class_span.zig`. The exec engines mostly *consume* these; the one place a DFA
executor reaches for SIMD itself is the gated self-loop spin-skip (§7), which
calls `prefilter.runEnd` rather than open-coding a vector loop.

---

## 2. Portability model

Zeetah is **one codebase, no per-target source branches, almost no inline asm.**
The portability strategy has three layers:

1. **`@Vector` lowers per target.** Portable vector ops (`==`, `<=`, `-%`, `|`,
   `@select`, `@reduce`) are emitted by the backend as SSE2/AVX2 on x86-64 and
   NEON on aarch64. The lane count is chosen at **comptime**:

   ```zig
   const VLEN = std.simd.suggestVectorLength(u8) orelse 16;  // prefilter.zig:23
   const V    = @Vector(VLEN, u8);
   ```

   `orelse 16` is the 128-bit baseline guard for targets where the query returns
   null.

2. **Feature detection is a comptime switch**, so only the target's prong is
   ever analyzed/emitted — there is no runtime "is AVX2 available?" branch:

   ```zig
   const teddy_simd: bool = switch (builtin.cpu.arch) {     // prefilter.zig:67
       .x86_64  => featureSetHas(.ssse3),
       .aarch64 => featureSetHas(.neon),
       else     => false,
   };
   const teddy_avx2: bool = arch == .x86_64 and featureSetHas(.avx2);
   ```

3. **Inline asm only for the one primitive the portable layer can't express
   well**: the byte-shuffle that the Teddy kernel is built on (`pshufb` /
   `vpshufb` / `tbl`). Even that is selected by a comptime `switch`
   ([`prefilter.zig:520`](../src/prefilter.zig#L520)), so a non-shuffle target
   never references it.

The net result: the *same* `.zig` source compiles to a NEON kernel on Apple
Silicon and an SSE2/AVX2 kernel on Linux x86-64, with the widths and the Teddy
kernel chosen at compile time.

> **Why the LLVM version is not a lever.** Re-measured kernel throughput is
> identical (<1.5%) on Zig 0.16 (LLVM 18) vs 0.17-dev. The win comes from the
> algorithm/shape, not from a newer auto-vectorizer.

---

## 3. The first-byte prefilter (`prefilter.zig`)

The optimizer produces a 256-bit `first_byte_set` bitmap: a strictly *necessary*
condition for where a match may begin. The prefilter scans the haystack for the
next byte in that set, so the automaton is only woken at real candidates rather
than probing every position.

### 3.1 The canonical predicate

Every consumer — vector path, scalar tail, fallback, and the tests — routes
membership through one inline function, so the scalar predicate is byte-identical
everywhere:

```zig
pub inline fn inSet(set: *const [32]u8, c: u8) bool {            // prefilter.zig:112
    return (set[c >> 3] & (@as(u8, 1) << @as(u3, @intCast(c & 7)))) != 0;
}
```

`setBit` ([`:118`](../src/prefilter.zig#L118)) is its write-side counterpart, so
producers and consumers of a `[32]u8` set share one bit layout. This shared
predicate is what makes the vector paths provably equivalent to a naive scan.

### 3.2 Classifying the set: `Prefilter`

Scanning a raw 256-bit bitmap byte-by-byte is itself slow. Instead the bitmap is
classified once into a compact shape ([`Prefilter`](../src/prefilter.zig#L125),
a tagged union) and the kernel iterates exactly the real members/ranges — no
padding work:

| Variant | When | Kernel |
|---------|------|--------|
| `single: u8` | exactly one byte | delegate to std's SIMD `memchr` (`indexOfScalarPos`) |
| `multi: {b:[8]u8, n}` | 2..=8 discrete bytes | vectorized multi-equality (OR of `chunk == splat(b[k])`) |
| `ranges: {lo,span,n}` | 1..=8 byte ranges | vectorized unsigned range test |
| `bitset` | pathological (>8 runs and >8 members) | scalar bitmap loop |

`Prefilter.fromBitset` ([`:138`](../src/prefilter.zig#L138)) does one pass over
32 bytes, no allocation, comptime-evaluable. The dominant cases — a single byte,
a digit/`\w` range, a small literal-first-byte set — all land on a fast variant.

`nextCandidate` ([`:217`](../src/prefilter.zig#L217)) classifies on every call;
`nextCandidatePF` ([`:226`](../src/prefilter.zig#L226)) takes a *pre-classified*
`Prefilter` so hot callers (or comptime-baked patterns) pay only the vector scan,
not the 256-bit re-classification.

### 3.3 The vector kernel and its two helpers

The kernels share two small inline helpers, both shaped for good codegen on both
ISAs:

```zig
// 0x00 / 0xFF lane mask, so masks combine with one integer OR (NEON ORR / SSE
// POR) instead of a bool-vector @select chain (which this toolchain scalarizes).
inline fn maskOf(cmp: Mask) V {                                  // prefilter.zig:199
    return @select(u8, cmp, @as(V, @splat(0xFF)), @as(V, @splat(0)));
}

// First set lane in an accumulated mask, or null. The @reduce keeps the
// overwhelmingly common no-hit path to one horizontal-or; firstTrue runs only
// on a real hit.
inline fn locate(acc: V) ?usize {                               // prefilter.zig:206
    if (@reduce(.Or, acc) == 0) return null;
    return @intCast(std.simd.firstTrue(acc != @as(V, @splat(0))).?);
}
```

A `multi` scan, for example, is one chunk load + `n` compares OR-ed in the `u8`
domain + one `@reduce`:

```zig
while (i + VLEN <= input.len) : (i += VLEN) {                    // prefilter.zig:237
    const chunk: V = input[i..][0..VLEN].*;
    var acc: V = maskOf(chunk == splats[0]);
    var k: usize = 1;
    while (k < n) : (k += 1) acc |= maskOf(chunk == splats[k]);
    if (locate(acc)) |lane| return i + lane;
}
return scalarScan(set, input, i);   // ≤ VLEN-byte scalar tail
```

The `ranges` kernel uses the classic unsigned-wraparound range test
`(c -% lo) <= span` ⇔ `c ∈ [lo, lo+span]` ([`:261`](../src/prefilter.zig#L261)),
one subtract + one compare per range.

### 3.4 `runEnd` — the symmetric "end of a class run"

`runEnd` ([`:296`](../src/prefilter.zig#L296)) is the mirror image: the first
index ≥ `pos` whose byte is *not* in the set (= the end of a maximal in-set run,
or `input.len`). It uses `locateZero` ([`:275`](../src/prefilter.zig#L275))
(first lane that is *zero* = first non-member), and because it's derived from the
same bitmap as `inSet` it can never overshoot a run boundary. Two consumers:
the VM's greedy-class-loop fast path, and — newly — the DFA self-loop **spin-skip**
(§7), which feeds it a state's stay set to bulk-consume a `.*` / `[^"]*` run in
one memory-bandwidth scan instead of one table lookup per byte.

### 3.5 Correctness contract

- The SIMD predicate is derived **losslessly** from the bitmap — every
  accelerated path is exactly `inSet`.
- Chunks are scanned in ascending order and `firstTrue` returns the minimal hit
  lane, so `nextCandidate` always yields the minimal in-set index ≥ `pos`
  (leftmost-correct by construction).
- Each kernel ends in a ≤ VLEN-byte scalar tail (`scalarScan` /`scalarRunEnd`)
  using the same predicate, so inputs shorter than a vector are handled too.

This is pinned by two **differential** tests that compare the vector result
against a naive scalar reference across the single/multi/ranges/bitset shapes and
across input lengths straddling the `VLEN` boundary (`VLEN-1, VLEN, VLEN+1,
2*VLEN, 4096, 4097`): "nextCandidate matches reference scan"
([`:405`](../src/prefilter.zig#L405)) and "runEnd matches reference"
([`:455`](../src/prefilter.zig#L455)).

---

## 4. The Teddy multi-substring kernel (`prefilter.zig`)

Teddy is a *necessary-condition* candidate finder for a small set of literal
needles (an `a|bc|def` alternation, or a multi-literal prefix). It is the
building block the planner's `.literal` / `.prefix_prefilter` strategies consume
(see [planner.zig](../src/planner.zig) and [search.zig](../src/exec/search.zig)).
It locates positions where *some* needle's prefix *could* start, then verifies a
real occurrence — so it never reports a position where no needle starts, and the
engine re-runs from the reported offset, keeping an over-approximation correct.

### 4.1 The shuffle primitive

Teddy is built on a one-instruction 16-byte table lookup
`out[k] = table[idx[k] & 0x0F]` (our indices are nibbles, 0..15):

```zig
const shuf = switch (builtin.cpu.arch) {                         // prefilter.zig:520
    .aarch64 => /* tbl  v.16b, {t.16b}, i.16b */ ,
    .x86_64  => if (teddy_avx2) /* vpshufb ymm (3-operand) */
                else            /* pshufb xmm (2-operand) */ ,
    else     => unreachable,
};
```

`pshufb` (SSSE3) and `tbl` (NEON) both zero a lane whose index has bit 7 set / is
≥ 16; since our indices are nibbles the two are bit-identical, so one algorithm
serves both ISAs.

### 4.2 Fat Teddy (AVX2, 256-bit)

On AVX2, the kernel width `TW` is **32** and `VT = @Vector(32, u8)`
([`:82`](../src/prefilter.zig#L82)): 32 bytes per iteration via `vpshufb ymm`.
Because `vpshufb` looks up *independently per 128-bit lane*, the 16-entry nibble
table is **duplicated into both lanes** (sound because indices are nibbles).
`tileTable` ([`:560`](../src/prefilter.zig#L560)) does this tiling once at build
time — identity for `TW==16`, both-lane duplication for `TW==32`. NEON has no
256-bit shuffle, so it stays at the 128-bit baseline.

### 4.3 The nibble masks and the kernel

For each of the first `nmask` needle bytes, two nibble→bucket-mask shuffles (low
nibble, high nibble) are AND-ed; AND-ing across byte positions leaves, per start
lane, the bucket bits of needles whose first `nmask` bytes all match
(`findTeddy` [`:844`](../src/prefilter.zig#L844), `maskAt`
[`:878`](../src/prefilter.zig#L878)). A neat trick: loading the chunk at byte
offset `j` aligns lane `k` with `input[i+k+j]` — exactly byte `j` of a needle
starting at `i+k` — so **no Teddy lane-shift is needed**.

8 buckets = one bit per needle (`MAX_NEEDLES = 8`). A nonzero lane is a candidate
bitmask; `verifyBucket` ([`:729`](../src/prefilter.zig#L729)) confirms only the
flagged needles in declared order via `@ctz`, running ≈ 1 `std.mem.eql` instead
of `n`. Nibble-collision false positives only cost speed, never correctness.

### 4.4 Adaptive prefix depth (`nmask`)

`TEDDY_NMASK = 3` is the classic "Slim Teddy" prefix depth, but when needles
share a 3-byte prefix the base filter is non-selective and every chunk
verify-storms (the case full Aho-Corasick targets). `build`
([`:626`](../src/prefilter.zig#L626)) therefore **deepens** `nmask` while some
needle pair still collides on the whole `nm`-byte prefix, bounded by the shortest
needle and by `TEDDY_MAXMASK = 8`. Pure scalar (n ≤ 8, len ≤ 64) ⇒
comptime-evaluable, so `pattern.zig` can bake the whole Teddy into `.rodata`.

### 4.5 The single/multi-needle two-byte filter (the portable fallback)

When the byte-shuffle isn't available (`teddy_simd == false`), or for single
needles, Teddy falls back to a portable **two-byte** filter built on a
*rare-byte heuristic*:

- `FREQ` ([`:90`](../src/prefilter.zig#L90)) is an English-biased byte-frequency
  table. `build` picks, per needle, the statistically **rarest** byte (`b2`) at a
  fixed offset `o` — a rarer second probe makes the candidate filter far more
  selective on natural text.
- `findOneSimd` ([`:785`](../src/prefilter.zig#L785)) ANDs `chunk == first_byte`
  with `chunk_at_o == rare_byte`: ANDing two byte tests stays selective even when
  each byte alone is frequent.
- `findMulti` ([`:809`](../src/prefilter.zig#L809)) ORs each needle's
  (first-byte AND rare-byte AND bucket-bit) across 2..8 needles in one pass.
- `findOneMemchr` ([`:767`](../src/prefilter.zig#L767)) is the single-needle
  fast path *when* the rare byte is a `robustlyRareProbe`
  ([`:58`](../src/prefilter.zig#L58)) — a rare letter (`FREQ ≤ 20`) or any
  non-ASCII byte. It delegates to std's tuned `memchr` on that one byte. For
  all-common prefixes (`href="`, `<h2…>`) no such byte exists, so the two-byte
  SIMD filter wins instead — a single-byte memchr there would stop at every
  occurrence and storm the verifier.

### 4.6 Build-time bake

`build` is comptime-evaluable, and `find` is called once per match. So every
per-call derived value — `@splat(b1)`, `@splat(b2)`, the bucket-bit splats, the
tiled nibble tables (and the AVX2 both-lane duplication) — is **materialized once
at build time** ([`:692`–`:702`](../src/prefilter.zig#L692)) and the hot finders
just read them. This removed a per-call tax on dense-hit workloads.

### 4.7 Dispatch (`Teddy.find`, [`:887`](../src/prefilter.zig#L887))

```
n == 1, len == 1   → std memchr on the single byte
n == 1, len >= 2   → findOneMemchr (rare probe) | findOneSimd (common probe)
mixed len-1 needle → findScalarRef (no sound 2nd byte for the set)
teddy_simd         → findTeddy   (true nibble-mask kernel)
else               → findMulti   (portable two-byte filter)
```

`findScalarRef` ([`:747`](../src/prefilter.zig#L747)) is the verbatim original
algorithm — the parity oracle, the definitive scalar tail for every fast path,
and the fallback for shapes the SIMD paths decline.

### 4.8 Aho-Corasick companion (scalar, same family)

`AhoCorasickN(MAX_NODES)` ([`:1012`](../src/prefilter.zig#L1012)) is *not*
vectorized — it's a scalar automaton — but it belongs to the same prefilter
family and is documented here for completeness. Teddy is fastest for a few short
needles; Aho-Corasick wins when there are many or long needles (one linear pass,
no per-candidate re-verify). The comptime arm builds at the 1024-node cap then
`trimmed`s ([`:1031`](../src/prefilter.zig#L1031)) to the exact node count for a
compact `.rodata` bake.

### 4.9 Teddy correctness

The "teddy: SIMD find == scalar reference" differential test
([`:928`](../src/prefilter.zig#L928)) runs full leftmost iteration from *every*
start position against `findScalarRef`, over 15 needle sets (single short/long,
repetitive, len-1, prefix-colliding, 8-needle, prefix sets that force `nmask` to
deepen) and lengths straddling both the 16/32 kernel boundaries and the portable
VLEN boundaries.

---

## 5. The class-span scanner (`class_span.zig`)

For the trivial shape where the *whole* unanchored pattern is one greedy
repetition of a single byte class — `[0-9]+`, `\w+`, `.+`, `[^/\s?#]+` — the
match is just a maximal run of class members, so no automaton is needed at all.
`regex.zig` routes this directly to the `class_span` executor
([regex.zig:666](../src/regex.zig#L666)).

### 5.1 The AArch64 design constraint (important)

This scanner is shaped by a hard NEON fact: **NEON has no `PMOVMSKB`**
(vector→bitmask). The x86 idiom "compare → movemask → ctz" lowers on Apple
Silicon to ~16 per-lane scalar moves per chunk — slower than the scalar DFA. So
this code **never bitcasts a bool-vector to an integer.** Instead:

- Membership is computed as a `0xFF`/`0x00` byte vector via `memberVec`
  ([`:62`](../src/exec/class_span.zig#L62)) using `cmhs` (`>=`/`<=`) + `bsl`
  (`@select`) + `orr` (`|`) — all single NEON instructions.
- Each 16-byte chunk is reduced with **one horizontal `@reduce`**: `.Max` ("any
  member?" → `umaxv`) for `firstMember` ([`:78`](../src/exec/class_span.zig#L78)),
  `.Min` ("any non-member?" → `uminv`) for `runEnd`
  ([`:97`](../src/exec/class_span.zig#L97)).

Whole member / non-member chunks are skipped at full NEON rate; a ≤16-byte scalar
loop only pins the exact index at a run/gap boundary (negligible vs the run
length).

### 5.2 Why it's gated to a single range

`regex.zig` only routes to `class_span` when the class is a **single contiguous
range** ([regex.zig:687](../src/regex.zig#L687)). The chunk-skip scan wins when
the class is *sparse with long gaps* (`[0-9]+` amid prose: **+118%**, measured).
For a dense/short-run class (`\w+`, where word chars are most of the text and
runs/gaps are < 16 B), the per-chunk scalar boundary fallback is pure overhead
and it *loses* to the DFA's tight per-byte loop (**−51%**). That is structural,
not a codegen bug — the NEON-correct `memberVec` did not change it. Multi-range
classes keep the DFA.

`class_span.Ranges` is also consumed by the **backtracker tier's** seek prefilter
via `firstMember` ([seek.zig:127](../src/exec/seek.zig#L127)).

### 5.3 Correctness

`Ranges.fromBitmap` ([`:29`](../src/exec/class_span.zig#L29)) extracts member
ranges from the 256-bit class bitmap (up to `MAXR = 16`). The unit tests
([`:115`](../src/exec/class_span.zig#L115)) check single- and multi-range
(`\w`-like) scans on inputs that exercise both the 16-byte vector path and the
scalar tail on both `firstMember` and `runEnd`.

---

## 6. Integration: where the prefilters plug in

The planner ([planner.zig](../src/planner.zig)) is a *pure* function of the
pattern's properties. It chooses among `.literal` (Teddy only, no automaton),
`.prefix_prefilter` (Teddy/byte-set locate → anchored verify), and `.core`
(plain DFA). The chosen prefilter is then driven by the **table-type-agnostic**
helpers in [`search.zig`](../src/exec/search.zig), which are written once against
a single `runFrom(input, pos) ?usize` primitive so they serve **both** the
runtime `Dfa256` executor and the comptime baked `comptime_dfa.Dfa(ns,nk)`:

- `litPrefixFind` ([search.zig:102](../src/exec/search.zig#L102)) — scan Teddy
  occurrences, anchored-verify each with `runFrom`, take the first that matches
  (leftmost-correct because the prefix literal can't precede its own start).
- `findViaReqLit` ([search.zig:67](../src/exec/search.zig#L67)) — drive a *required
  literal* (single rare byte, or a multi-byte **reverse-inner** anchor — §8) and
  recover the start.
- `requiredAbsent` ([search.zig:32](../src/exec/search.zig#L32)) — if a byte
  every accepting path must consume is absent, answer "no match" in one `memchr`.
  This is what collapses the unanchored DFA-restart O(n²) for `a.*…X`, `.*.*=.*`.

This closes the historical comptime/runtime asymmetry: a comptime `Pattern("a.*X")`
now gets the same O(n) prefilter guarantee the runtime path always had.

Under `case_insensitive`, letter-free literals (`://`, version strings, URLs)
still route to these SIMD fast paths via `Seq.isCaseInvariant` — the parser
case-folds set bitmaps at parse time, so any `Seq` that survives folding is
already letter-free and the prefilter stays sound (+8.4× on `(?i)[A-Za-z].*9999`,
which would otherwise fall back to a 52-bit first-byte-set scan).

---

## 7. SIMD inside the automaton: the adaptive self-loop spin-skip

The one place a DFA executor reaches for SIMD itself — soundly, because it skips a
long *run*, not a per-byte step. A DFA state that **self-loops** over a wide byte
class (`.*`, `[^"]*`, base64 `[A-Za-z0-9+/]+`) is invariant across the run, so it
is correct to SIMD-scan (`prefilter.runEnd`, §3.4) to the first byte that leaves
the state and resume the scalar walk. `Dfa256.runFromSpin`
([full_dfa.zig:152](../src/exec/full_dfa.zig#L152)) does exactly that, behind two
gates that keep it **purely additive**:

- **`SPIN_TRIGGER = 64`** ([full_dfa.zig:35](../src/exec/full_dfa.zig#L35)) —
  engage only after 64 *consecutive* self-loop bytes, so short runs stay 100%
  scalar and never pay vector setup. The skip fires once per run; the counter then
  saturates past the trigger, so the hot path is one compare + one add per byte.
- **`SPIN_MIN_WIDTH = 64`** ([full_dfa.zig:36](../src/exec/full_dfa.zig#L36)) —
  only states whose self-loop class is ≥ 64 bytes wide get a precomputed **stay
  set** (the 256-bit set of bytes that keep the walk in that state). Narrow classes
  (`\d` = 10, `\w` = 63) have short runs in practice, so gating them out keeps those
  patterns on the untouched scalar loop.

A per-DFA `has_spin` flag makes `runFrom`
([full_dfa.zig:114](../src/exec/full_dfa.zig#L114)) dispatch *once* at entry:
patterns with no wide self-loop run the original `runFromPlain` with **zero added
cost**. `runFromSpin` is deliberately **not** `inline` — inlining it bloats every
`runFrom` call site and regresses unrelated no-spin patterns (§9). The result is
byte-identical to the scalar loop, pinned by a differential test (§11).

**Measured** (ReleaseFast, 1 MiB, best-of-5 vs the scalar loop): `log_parse`
**3.5×**, `html_tag` 1.26×, `path_unix` 1.26×, `json_string` 1.21×, `email`
1.20×, `href` 1.24×; corpus **geomean +3.5%**. It is a genuine *trade*: a handful
of patterns with a wide self-loop state but short actual runs (`xml_attr` 0.71×,
`grok_named` 0.85×) pay the loop restructure for no skip — the cost the per-DFA
gate confines to opt-in patterns. (An earlier evaluation deferred this as "a real
trade, gate it before shipping"; the gates above are that gate.)

---

## 8. Reverse-inner literal anchoring (`findViaReqLit`)

`findViaReqLit` ([search.zig:67](../src/exec/search.zig#L67)) drives a
necessary-literal prefilter: a mandatory literal every match must contain, plus a
recipe (`ReqLit.back`) to recover the match start from the literal's position — so
the search scans to candidate regions instead of restarting the DFA at every
position. The anchor is the **most selective mandatory literal run** the pattern
contains (`requiredLiteralBack`
[seq_extract.zig:372](../src/exec/seq_extract.zig#L372)), not just a single byte:
`[a-z]+/api/v2/[a-z]+` keys on `/api/v2/`, and the `uri` pattern `[\w]+://…` keys
on `://` instead of the near-ubiquitous `:`.

The literal is located **not** by generic substring search (`std.mem.indexOfPos`
is far slower than `memchr` when the literal is frequent) but by `memchr` on the
literal's **robustly-rare** byte, then one `std.mem.eql` verify before the
expensive `runFrom`:

- The probe is chosen by `robustlyRareProbe`
  ([prefilter.zig:58](../src/prefilter.zig#L58)) — a low-frequency letter or
  non-ASCII byte — **not** a `FREQ`-rare *punctuation* byte (`/ : -`), which the
  English model mismarks as rare while it is common in machine text. For
  `/api/v2/` the probe is `v` (absent in plain path text → `memchr` returns
  instantly); for `://` it falls back to `:` but the `eql` verify still filters
  out every bare `:` before any `runFrom`.
- `nextLitOccurrence` ([search.zig:50](../src/exec/search.zig#L50)) implements the
  `memchr`-probe + verify; scanning the probe ascending keeps anchor starts
  ascending (leftmost-correct). `ReqLit` is passed **by pointer** — it carries a
  32-byte literal buffer, and single-byte-anchor patterns that call this per match
  cannot afford a by-value copy.

**Measured:** `uri` **1.37×** on the real corpus (it was a 2.4× *regression* with
generic `indexOfPos` — the probe choice is the whole game); synthetic
common-separator cases up to 127×; neutral on every pattern without a multi-byte
inner literal. The `len == 1` path is byte-identical to the previous single-byte
anchor. The optimization always re-verifies with `runFrom`, so it never changes a
result.

---

## 9. Where SIMD does NOT pay (the reverted experiments)

The negative space that defines the boundary — `@Vector` / restructure tried in
places it lost, and reverted:

| Change | Verdict |
|--------|---------|
| Spin-skip in `dense_search` (non-inlined two-branch loop) | **Reverted** — even the minimal restructure regresses tight digit-class patterns; the loop tolerates no per-byte add |
| `dupword` backref scan via vectorized `class_span` | **Reverted** — ~1.35× slower; English words average 4 B and never fill a 16-byte vector, so the kernel pays setup to scan ~4 B |
| Inlining `runFromSpin` (§7) to recover its few regressions | **Reverted** — fixed the has-spin patterns but bloated every `runFrom` call site, tanking unrelated no-spin patterns (`ssn`/`time_hms` −20–30%) |

The recurring reason: a DFA step is one cache-hot table lookup, and the
prefilter/seek/spin layers already remove the long stretches, so what reaches the
*per-byte* path is short (words ≈ 4 B, fields/gaps ≈ 1 B) — far below the 16-byte
SIMD width. SIMD-on-short-data loses.

---

## 10. Reusable principles

1. **Vectorize long runs, not the per-byte step.** SIMD pays *before* the
   automaton (first-byte / Teddy / Aho-Corasick prefilters, the `class+` scanner)
   AND to skip a long self-loop run *inside* it (the spin-skip) — both skip a long
   stretch in one scan. It never pays on the per-byte DFA transition, already a
   single cache-hot lookup. "Inside vs outside" is the wrong axis; "long run vs
   short run" is the right one.

2. **Always measure inside the real engine.** A `@Vector` primitive that
   benchmarks *neutral in isolation* can regress several-fold once it sits behind
   a runtime `?optional` unwrap + heap-pointer indirection in a tight loop — a
   comptime/global microbench folds those away. (`dupword`: neutral micro, 2.9×
   regression in-engine.)

3. **Loop-body sensitivity is real.** Adding *any* per-byte work — even a
   register compare + counter — to a tight non-inlined hot loop can regress it,
   even when the new SIMD path never executes. Gate behind an adaptive run-length
   threshold and re-measure.

4. **Build the way it ships.** Debug penalizes `@Vector` codegen and inflates the
   scalar loop; the original experiment's verdicts were wrong because of a
   `-OReleaseFast`-after-`-M` flag-order bug that silently built Debug. Confirm
   with `@import("builtin").mode`; aggregate min-of-≥3 at 1 MiB.

5. **One predicate, many paths.** Every accelerated path funnels through a single
   canonical scalar predicate (`inSet` / `verifyAt`), and every kernel is pinned
   by a **differential test** against a naive scalar reference across the
   vector-width boundaries. SIMD correctness is *proved by construction and
   tested by oracle*, not hoped for.

6. **A "rare" byte must be rare in the *target* data, not the English model.** The
   `FREQ` table marks structural punctuation (`/ : - .`) as rare, but it is common
   in the logs/URLs/code this engine targets — `memchr`-ing it storms the verifier.
   Anchor on a *robustly* rare byte (low-frequency letter / non-ASCII) when one
   exists (`robustlyRareProbe`); §8 turns this from a 2.4× regression into a 1.37×
   win on `uri`.

7. **Gate at the coarsest granularity that works.** The spin-skip's per-DFA
   `has_spin` flag (decided once at construction) costs nothing on patterns that
   can't benefit; a per-byte gate would tax every pattern. Decide
   "can this even help?" as far up the call tree as the information allows.

---

## 11. Testing the SIMD paths

All SIMD code is covered by differential tests that compare the accelerated result
against a naive scalar oracle, run across input lengths that straddle every
vector-width / trigger boundary:

| Test | File:line | Covers |
|------|-----------|--------|
| `fromBitset classification` | [prefilter.zig:357](../src/prefilter.zig#L357) | union shape selection |
| `nextCandidate matches reference scan` | [prefilter.zig:405](../src/prefilter.zig#L405) | first-byte scan, leftmost |
| `runEnd matches reference` | [prefilter.zig:455](../src/prefilter.zig#L455) | class-run end, no overshoot |
| `teddy: SIMD find == scalar reference` | [prefilter.zig:928](../src/prefilter.zig#L928) | Teddy kernel, all dispatch arms |
| `teddy: build rejects degenerate inputs` | [prefilter.zig:921](../src/prefilter.zig#L921) | build guards |
| `aho-corasick: finds leftmost needle` | [prefilter.zig:1114](../src/prefilter.zig#L1114) | AC automaton |
| `class_span: ranges + scan basics` | [class_span.zig:115](../src/exec/class_span.zig#L115) | member-run scan |
| `class_span: multi-range class` | [class_span.zig:134](../src/exec/class_span.zig#L134) | `\w`-like multi-range |
| `runFromSpin == runFromPlain` | [full_dfa.zig:610](../src/exec/full_dfa.zig#L610) | spin-skip (§7) ≡ scalar, runs ≫ trigger |
| `requiredLiteralBack picks most selective literal` | [seq_extract.zig:753](../src/exec/seq_extract.zig#L753) | reverse-inner anchor selection (§8) |
| `reverse-inner req_lit on/off agree` | [core.zig:178](../src/exec/core.zig#L178) | anchor (§8) ≡ brute-force `findAll` |

The cross-engine benchmark's match-count gate (`aggregate.py`) is the final
backstop: every SIMD path keeps it green (0 mismatches across all engines and
workloads). The two shipped automaton-level optimizations (§7, §8) additionally
held every one of the 54 benchmark workloads' match counts identical to baseline.
