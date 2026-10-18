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
| [`src/simd.zig`](../src/simd.zig) | The one shared arch primitive: `simd.shuffle(W, table, idx)` (16- or 32-byte per-lane table lookup) + the comptime `has_shuffle` capability flag | inline asm `pshufb` / `vpshufb` / `tbl`, portable fallback |
| [`src/prefilter.zig`](../src/prefilter.zig) | First-byte set scan + Teddy multi-literal kernel + (scalar) Aho-Corasick | portable `@Vector` compare/`@reduce` + `simd.shuffle` |
| [`src/exec/class_span.zig`](../src/exec/class_span.zig) | `class+` / `class*` member-run scanner (whole pattern is one greedy class repetition) | 64-byte block → `u64` mask (`ld4`+`sri`+`shrn` on NEON, `pmovmskb` on x86) + nibble `tbl`/`pshufb` classify; `Ranges` keeps the 16-byte `@reduce` scan for `seek` |
| [`src/exec/class_seq.zig`](../src/exec/class_seq.zig) | Fixed-length class-sequence matcher (`[0-9]{2}:[0-9]{2}:[0-9]{2}`, UUIDs, MACs) | `class_span`'s block masks, one shared load per block; shifted 128-bit mask pairs ANDed per run; gate filter + `memchr` skip |
| [`src/exec/word_set.zig`](../src/exec/word_set.zig) | `\b(?:kw1\|kw2\|…)\b` with word-only keywords (`boundary_lits` `.words`) | `class_span`'s `\w` block mask walked with `ctz`; length + (first, last) byte bit filters; open-addressing keyword table |
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
   well**: the byte-shuffle that the Teddy kernel and the `class_span` nibble
   classifier are built on (`pshufb` / `vpshufb` / `tbl`). It lives once, in
   [`src/simd.zig`](../src/simd.zig) (`simd.shuffle`), selected by comptime
   conditions on the target, so a non-shuffle target never emits it.

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
The multi-literal needle set is widened by **cross-product expansion** of a
leading literal run across small optional/class/alternation wobbles in
`seq_extract.prefix` (`colou?r` → {color, colour}; `gr[ae]y` → {gray, grey};
bounded to ≤ 8 alternatives), so more patterns reach this SIMD kernel instead of
falling back to a broad first-byte-set scan — the same expanded `Seq` feeds the
runtime and the comptime-baked Teddy alike.
It locates positions where *some* needle's prefix *could* start, then verifies a
real occurrence — so it never reports a position where no needle starts, and the
engine re-runs from the reported offset, keeping an over-approximation correct.

### 4.1 The shuffle primitive

Teddy is built on a one-instruction 16-byte table lookup
`out[k] = table[idx[k] & 0x0F]` (our indices are nibbles, 0..15). The primitive
is shared with the `class_span` nibble classifier (§5) and lives in
[`src/simd.zig`](../src/simd.zig):

```zig
pub inline fn shuffle(comptime W: usize, table: @Vector(W, u8), idx: @Vector(W, u8)) @Vector(W, u8)
//  aarch64 + NEON            → tbl  v.16b, {t.16b}, i.16b        (W == 16 only)
//  x86_64 + AVX (W=16) /     → vpshufb xmm/ymm (3-operand)
//           AVX2 (W=32)
//  x86_64 + SSSE3            → pshufb xmm (2-operand, W == 16)
//  otherwise                 → portable per-lane scalar lookup
```

`pshufb` (SSSE3) and `tbl` (NEON) both zero a lane whose index has bit 7 set / is
≥ 16; since our indices are nibbles the two are bit-identical, so one algorithm
serves both ISAs. `prefilter.shuf` and `class_span.shuf` are one-line wrappers
that fix `W` to the kernel width (`TW` for Teddy, 16 for `class_span`), and the
comptime `simd.has_shuffle` flag is what both planners consult before choosing
a shuffle-based kernel.

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

### 4.10 Case-folded needles (`Teddy.buildFolded`)

Under `(?i)` every letter is a two-byte set `{C, c}`, so the exact literal
extractors could only represent `(?i)sherlock holmes` as 2^14 alternatives and
gave up — the planner then sent case-insensitive literals to the DFA behind a
`{S, s}` first-byte filter (rebar `01-literal/sherlock-casei-en`: 0.05× of
PCRE2-JIT). `seq_extract.foldLiterals` instead keeps such a literal (or an
alternation of ≤ 8, or a leading run) as **one alternative plus a fold mask**:
`0x20` where the position is a case pair `{c, c ^ 0x20}`, with the canonical byte
`c | 0x20` stored. The planner routes it through the ordinary `.literal` /
`.prefix_prefilter` → `.lit_prefix` routes, so the runtime `Regex` and the
comptime `Pattern` both pick it up from the shared `core.buildLiteral`.

- **Masks stay exact.** The two bytes of a case pair share their low nibble and
  differ only in bit 1 of the high nibble, so setting both high-nibble bits in a
  needle's bucket matches exactly `{C, c}` — no 2^k needle blow-up; each
  alternative is still one bucket.
- **Verification** is `x | fold == canonical` per byte — for a needle of ≤ 16
  bytes, one 16-byte OR + compare + `@reduce(.And)` (pad lanes are `0xFF` in
  both vectors, so they always agree).
- **Dispatch.** The memchr-on-rare-byte and two-byte-equality paths compare
  exact bytes, so a folded set always takes the nibble kernel (or the
  first-byte-set reference scan without a byte shuffle; the first-byte set holds
  both cases).
- A deeper mask for folded sets (4–6 bytes instead of 3) was measured and
  rejected: the extra shuffles cost more than the false positives they remove.

rebar (M4 Pro), against the same `feat/zig-0.17` build: `01-literal/sherlock-casei-en`
950 → 96.5 µs (**9.8×**, level with rust/regex; PCRE2-JIT 46 µs) and
`02-literal-alternate/sherlock-casei-en` 2,080 → 120 µs (**17.4×**, 2nd behind
.NET compiled 109 µs; rust/regex 665 µs, PCRE2-JIT 1,070 µs). The case-sensitive
`sherlock-en` rows are unchanged (0.98×/0.99×).

---

## 5. The class-span scanner (`class_span.zig`)

For the trivial shape where the *whole* unanchored pattern is one greedy
repetition of a single byte class — `[0-9]+`, `\w+`, `.+`, `[^/\s?#]+` — the
match is just a maximal run of class members, so no automaton is needed at all.
`regex.zig` routes this directly to the `class_span` executor
(`tryClassSpan`, [regex.zig:842](../src/regex.zig#L842)) for **any** byte class —
and so does the comptime `Pattern` (`tryClassSpanBuilt`), through the same
recogniser.

The recognised shape is wider than `S+` (`class_span.RunSpec`): any flat
concatenation of greedy single-class pieces (`S`, `S?`, `S*`, `S+` — what the
parser lowers `{m,n}` to) adds up to a count interval `[m, n]`, optionally
bracketed by `\b … \b`:

| Pattern | Matches (leftmost-first, non-overlapping) |
|---------|-------------------------------------------|
| `S+`, `S{m,}` | every maximal `S` run of length ≥ `m` |
| `S{m,n}` | each run cut greedily into `n`-byte pieces, plus a last piece of ≥ `m` bytes |
| `S*` | the (possibly empty) run at each search position |
| `\bS{m,n}\b`, `S ⊆ \w` | the whole `\w` runs of length `[m, n]` made only of `S` bytes (the `\b`s forbid starting or ending inside a word) |

So `\b[0-9A-Za-z_]+\b`, `\b\w{12,}\b`, `[A-Za-z]{8,13}` and `[0-9]{4}` all run off
the run boundaries of one mask — popcount for the plain run shapes, a `ctz` walk
with a length test (and, for `S ⊊ \w`, a byte check) otherwise.

### 5.1 One bitmask per 64 bytes (`Class`)

The executor (`Class`, [class_span.zig:250](../src/exec/class_span.zig#L250))
classifies 64 bytes into one `u64` — bit `k` ⇔ byte `k` is a member — and
answers every query with scalar bit arithmetic on that mask:

| Query | Bit trick |
|-------|-----------|
| next member (`firstMember`) | `ctz(m)` |
| run end (`runEnd`) | `ctz(~m)` |
| next run (`nextRun`, the iterator) | `ctz(m)`, then `ctz(~(m >> off))` — usually one block for both |
| `count` of `class+` (`countRuns`) | `popCount(m & ~(m << 1 \| carry))` per block — no per-run branch |
| `findAll` of `class+` (`appendRuns`) | walk run starts `m & ~prev` and ends `~m & prev` with `ctz` / `x & (x-1)` |

This is the "heat-seeking / compacting tokenizer" idea from Niles Salter's
*Accelerating the Zig Tokenizer* talk: separate *producing* the class bits
(data-parallel) from *consuming* them (the `ctz` loop), so one mask serves
every short run inside the block. That is what flipped the old verdict below:
the per-run cost is now a few scalar ops, not a vector scan restarted per run,
so dense / short-run classes (`\w+`, words ≈ 5 B) are the *best* case.

**Classification** (`Class.Method`, chosen once by `fromBitmap`
[`:273`](../src/exec/class_span.zig#L273)): one or two contiguous ranges use a
wrapping subtract + unsigned compare per range (`range` / `range2` — `[0-9]`,
`[^\n]`, `[a-zA-Z]`); any other ASCII class uses two nibble lookups
(`tbl`/`pshufb`, the Teddy primitive) — `t_lo[c & 15] & t_hi[c >> 4]`
(`nibble`, `\w`); a class with bytes ≥ 0x80 uses four (`nibble2`, Latin-1
`\p{L}`, `\S`, `[^"]`). Without a byte shuffle (`portable` targets) only the
range methods exist and `fromBitmap` returns null otherwise, so the planner
keeps the DFA there.

**The AArch64 mask** (`pack`, [`:217`](../src/exec/class_span.zig#L217)). NEON
has no `PMOVMSKB`, and a bool-vector `@bitCast` lowers to ~36 instructions per 64
bytes. Instead the block is loaded with **`ld4`** (de-interleaving: lane `j` of
vector `k` = byte `4j+k`), classified, and folded with a **`sri` chain** into one
nibble per 4-byte group, duplicated into both halves of the byte; one **`shrn
#4`** then packs the nibble pairs into the natural-order `u64` — ~10
instructions for 64 bytes. Zig/LLVM do not form `ld4` from stride-4 `@shuffle`s
(they emit ~64 lane moves), so `ld4` and `sri` are tiny comptime-gated inline asm
like the Teddy `tbl`. On x86_64 the mask is four `pmovmskb`.

**Gaps and long runs** stay at full rate: `firstMember` / `runEnd` test each
block with one `umaxv` / `uminv` of the four membership vectors and pack the mask
only for the block holding the boundary. **Tails** need no scalar loop: a window
that runs past the end reuses the overlapping last 64 bytes (shifted down), or a
zero-padded copy when the whole input is shorter than a block; bits past
`input.len` are clear, so a run reaching EOF ends there. `findAll` pre-counts
the runs (the `popCount` pass is ~30× cheaper than the walk) and allocates the
result once — a dense `\w+` over 1 MiB is ~200K matches, and the regrowth copies
had cost ~1.8× at that size.

### 5.2 Results (and the old single-range gate)

Before this design, `class_span` was gated to a **single contiguous range**: its
16-byte chunk scan restarted per run with a ≤16-byte scalar boundary loop, which
won on sparse classes (`[0-9]+`, +118%) but lost to the DFA on dense short-run
ones (`\w+`, −51%), so multi-range classes kept the DFA. The block mask removes
the restart, so the gate is gone.

`run_compare.sh` against `feat/zig-0.17` (M4 Pro, Zig 0.17.0-dev.2384, 1 MiB,
best of 3; the 633 untouched rows have geomean 1.000×, p5/p95 0.945×/1.049×):

| Workload | Before | `count` MB/s | `findAll` (`count-spans`) MB/s |
|----------|--------|--------------|--------------------------------|
| `word` `\w+` | DFA | 280 → 27,443 (**98×**) | 240 → 2,070 (**8.6×**) |
| `unicode_prop` `[\p{L}\p{N}_]+` | DFA | 304 → 17,772 (**59×**) | 252 → 1,857 (**7.4×**) |
| `digits` `[0-9]+` | `class_span` (16-byte) | 748 → 42,367 (**57×**) | 473 → 3,827 (**8.1×**) |
| `quantifier` `a+` | `class_span` (16-byte) | 1,143 → 39,820 (**35×**) | 861 → 8,004 (**9.3×**) |

`grep` mode (`isMatch` per short line) moves 1.0–1.5×: a line is one block.

`class_span.Ranges` — the original 16-byte scanner — is still what the
**backtracker tier's** seek prefilter uses via `firstMember`
([seek.zig:127](../src/exec/seek.zig#L127)).

### 5.3 Correctness

`Class == scalar oracle` ([`:617`](../src/exec/class_span.zig#L617)) checks every
query (`firstMember`, `runEnd`, `nextRun` from every offset, `countRuns`,
`appendRuns`) for 160 random classes covering every method — single bytes, the
full class, complements, `0x00`/`0xFF` edges — on unaligned inputs whose lengths
straddle the 64-byte block and tail paths. The engine-level
`class_span == DFA on language-equivalent patterns`
([regex.zig:1945](../src/regex.zig#L1945)) pins `find` / `findAll` / `count` /
`isMatch` / the iterator against the same language on the DFA (`C+` ≡ `CC*`,
`C*` ≡ `(?:CC*)?`). The `Ranges` tests ([`:514`](../src/exec/class_span.zig#L514))
are unchanged.

### 5.4 Fixed-length class sequences (`class_seq.zig`)

The same block masks answer a second shape: a whole pattern that is a fixed
sequence of byte classes — `[0-9]{2}:[0-9]{2}:[0-9]{2}`,
`[0-9a-f]{8}-[0-9a-f]{4}-…`, `(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}`,
`([0-9]{4})-([0-9]{2})-([0-9]{2})`. Every match has the same length `L`, so a
match *ends* at byte `e` iff each pattern position `k` holds a member of its
class at `e - (L-1-k)`: the end mask of a whole block is
`AND_k (mask[class_k] << (L-1-k))`, the shifts pulling in the previous block's
bits. This is the multi-character-symbol matcher of Niles Salter's accelerated
Zig tokenizer (per-position class bits, shifted and ANDed — "`x << 1` tells you
about the previous byte"), applied to regex.

- **Recognition** (`ClassSeq.fromHir`): only `set` leaves under `concat` /
  `cap` (the parser has already expanded `{n}`), unanchored, `L` ∈ [2, 64],
  ≤ 4 distinct classes, not a pure literal (Teddy/`memchr` stay faster there).
- **Runs, not positions.** Consecutive positions of one class form a run;
  "the last `r` bytes are all members" is a `log2(r)`-step doubling
  (`R_2a = R_a & (R_a << a)`) over the (previous, current) mask pair held as a
  128-bit value in registers (`runMask`). Per-block cost scales with the number
  of runs (UUID: 9), not with `L` (UUID: 36).
- **Gate filter.** The class with the fewest members (`:`, `-`, `#`) is the
  *gate*: each block first evaluates only the gate's runs — "two `-` exactly 3
  bytes apart" — a necessary condition that rejects most blocks after
  classifying one class; the other classes are classified only for surviving
  blocks (the previous block's lazily). A one-byte gate absent from a block
  jumps to its next occurrence with `memchr`, so a sparse anchor
  (`#[0-9a-fA-F]{6}`) scans at `memchr` speed.
- **Leftmost non-overlapping** matches fall out of a `ctz` walk over the end
  mask: fixed length ⇒ ascending ends are ascending starts, and an end is kept
  iff its start is at/after the previous match's end.
- **Captures** keep the two-phase path: the span comes from `class_seq`, the
  retained NFA refills the slots one-pass (a fixed sequence always is).

`run_compare.sh` against `feat/zig-0.17` (M4 Pro, Zig 0.17.0-dev.2384, 1 MiB,
best of 3; the 591 untouched rows have geomean 1.001×, p5/p95 0.949×/1.046×;
every match count identical):

| Workload | Before | `count` MB/s | `findAll` (`count-spans`) MB/s |
|----------|--------|--------------|--------------------------------|
| `credit_card` `[0-9]{4}[ -]…` | `dense_search` | 477 → 5,368 (**11.3×**) | 473 → 6,049 (**12.8×**) |
| `time_hms` `[0-9]{2}:[0-9]{2}:[0-9]{2}` | DFA + req. literal | 4,132 → 12,258 (**3.0×**) | 3,492 → 10,645 (**3.0×**) |
| `uuid` | DFA + req. literal | 4,269 → 11,502 (**2.7×**) | 4,681 → 10,070 (**2.2×**) |
| `mac_addr` | DFA + req. literal | 4,882 → 12,925 (**2.6×**) | 4,888 → 11,899 (**2.4×**) |
| `date_iso` `[0-9]{4}-[0-9]{2}-[0-9]{2}` | DFA + req. literal | 4,949 → 11,290 (**2.3×**) | 4,991 → 8,809 (**1.8×**) |
| `ssn` `[0-9]{3}-[0-9]{2}-[0-9]{4}` | DFA + req. literal | 5,220 → 10,655 (**2.0×**) | 5,438 → 9,092 (**1.7×**) |
| `date_fields` (3 groups, logs) | DFA | 8,471 → 16,502 (**1.9×**) | 8,557 → 14,075 (**1.6×**) |
| `hex_color` `#[0-9a-fA-F]{6}` | DFA + `memchr('#')` | 14,821 → 16,622 (1.1×) | 13,927 → 14,847 (1.1×) |

`grep` mode (`isMatch` per short line) moves 0.96–1.22× (`credit_card` 3.6×);
`date_fields` `count-captures` 1.05× (slot reconstruction dominates).

### 5.5 Keyword sets as whole words (`word_set.zig`)

`\b(?:break|case|…|let)\b` with **word-only** keywords is the tokenizer's
keyword step. The first and last byte of each keyword are word bytes, so `\b` on
both sides forces a match to be a whole maximal `\w` run; the matches are exactly
the `\w` runs equal to some keyword (at most one keyword equals a given run, so
source-order tie-breaking never arises). `boundary_lits` therefore takes a
`.words` strategy for keyword lists larger than Teddy's 8 (`buildPre` keeps
Teddy for ≤ 8; any keyword with a non-word byte, or longer than 16 bytes, keeps
Aho-Corasick):

- **Walk the words, not the bytes.** `class_span`'s `\w` class gives one mask
  per 64-byte block; run starts `m & ~(m << 1 | carry)` and ends
  `~m & (m << 1 | carry)` are visited with `ctz` — the cost is per word of input
  and independent of the keyword count (Aho-Corasick pays a scalar table step per
  byte).
- **Reject cheaply, then look up.** Two bit tests turn away almost every ordinary
  word with a predictable branch: its length (`len_bits`) and its (first, last)
  byte pair (`pair_bits`, 512 bytes, low 6 bits of each byte). Only survivors hash
  (first 8 bytes + length) into a half-full open-addressing table whose entries
  hold the whole keyword (≤ 16 bytes) for an exact two-word compare. Without the
  pair filter nearly every English word reached the table and its data-dependent
  probe loop — 0.8 GB/s; with it, 1.45 GB/s on the same walk.
- **Shared runtime + comptime.** The set is built allocation-free, so the comptime
  `Pattern.boundary_lits` arm bakes the same matcher into `.rodata`.

`run_compare.sh` against `feat/zig-0.17`, `deep_alternation` (39 JS keywords;
best of 3; the 578 untouched rows have geomean 1.000×, p5/p95 0.959×/1.048×;
every match count identical):

| Engine | Model | 256 KiB MB/s | 1 MiB MB/s |
|--------|-------|--------------|------------|
| runtime `Regex` | `count` | 339 → 2,392 (**7.1×**) | 330 → 1,297 (**3.9×**) |
| runtime `Regex` | `count-spans` | 338 → 2,386 (**7.1×**) | 327 → 1,290 (**3.9×**) |
| runtime `Regex` | `grep` | 432 → 1,372 (**3.2×**) | 423 → 1,095 (**2.6×**) |
| comptime `Pattern` | `count` | 297 → 2,540 (**8.6×**) | 295 → 1,352 (**4.6×**) |
| comptime `Pattern` | `count-spans` | 302 → 2,500 (**8.3×**) | 293 → 1,504 (**5.1×**) |

(RE2, the fastest competitor on this workload in the Oct 1 cross-engine run:
598 MB/s.) Small keyword sets keep their Teddy path unchanged.

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
   short run" is the right one — **unless the vector work is shared across the
   short runs**: one 64-byte bitmask, consumed with `ctz` / `popCount`, serves
   every run in the block, so short runs cost scalar bit ops instead of a vector
   scan each (§5.1 — `\w+` went from the DFA's 280 MB/s to ~27 GB/s `count`).

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
| `class_span: ranges + scan basics` | [class_span.zig:514](../src/exec/class_span.zig#L514) | `Ranges` member-run scan |
| `class_span: multi-range class` | [class_span.zig:534](../src/exec/class_span.zig#L534) | `Ranges` `\w`-like multi-range |
| `class_span: Class == scalar oracle` | [class_span.zig:617](../src/exec/class_span.zig#L617) | every `Class` query × every method, lengths/offsets across 64-byte blocks |
| `class_span == DFA on language-equivalent patterns` | [regex.zig:1945](../src/regex.zig#L1945) | `find`/`findAll`/`count`/`isMatch`/iterator vs `CC*` on the DFA |
| `class_seq: every query == naive matcher` | [class_seq.zig:414](../src/exec/class_seq.zig#L414) | `nextFrom` from every offset / `count` / `appendAll` / `isMatch`, 400 random sequences (lengths 2–64), haystacks across block edges |
| `class_seq == naive matcher on random fixed-length patterns` | [regex.zig:2042](../src/regex.zig#L2042) | routing + every public API on random `\d`/`[a-f]`/`.`/`[^"]`/`{n}`/group patterns |
| `word_set: find == naive \b(?:…)\b` | [word_set.zig:201](../src/exec/word_set.zig#L201) | `find` from every offset, 60 random keyword sets (prefix-sharing, inside longer words), across block edges |
| `boundary_lits (words / Teddy / Aho-Corasick) == naive` | [regex.zig:2160](../src/regex.zig#L2160) | all three strategies through the public API vs the `\b(?:…)\b` definition |
| `runFromSpin == runFromPlain` | [full_dfa.zig:610](../src/exec/full_dfa.zig#L610) | spin-skip (§7) ≡ scalar, runs ≫ trigger |
| `requiredLiteralBack picks most selective literal` | [seq_extract.zig:753](../src/exec/seq_extract.zig#L753) | reverse-inner anchor selection (§8) |
| `reverse-inner req_lit on/off agree` | [core.zig:178](../src/exec/core.zig#L178) | anchor (§8) ≡ brute-force `findAll` |

The cross-engine benchmark's match-count gate (`aggregate.py`) is the final
backstop: every SIMD path keeps it green (0 mismatches across all engines and
workloads). The two shipped automaton-level optimizations (§7, §8) additionally
held every one of the 54 benchmark workloads' match counts identical to baseline.
