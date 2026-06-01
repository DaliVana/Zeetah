# Comptime-generated bounded backtracker — implementation handoff

Branch: `comptime-backtracker` (from `main` @ e7c17a0).

> **STATUS 2026-06-01: IMPLEMENTED & GREEN, incl. full capture parity.** All four
> steps below are done AND the comptime path now has full capture-submatch parity
> with the runtime `Regex` (numbered + named groups), which the original plan left
> as a follow-up. Full suite passes (`zig build test` → 42/42 steps, 234/234 tests).
> `Pattern(...)` accepts the non-regular subset (backref, lookaround,
> atomic/possessive, and `lazy && anchored_end`) at compile time via a
> comptime-baked tree backtracker. What landed, file by file:
> - **`src/exec/backtrack.zig`** — `Backtracker` is now `BacktrackerG(comptime cap)`
>   (`const H = hir.Hir(cap)`, `const Self = @This()`, receivers `*Self`); the
>   runtime alias `pub const Backtracker = BacktrackerG(null)` keeps all ~6 runtime
>   call sites unchanged. Pure wrapper+reindent, no logic change (verify: `git diff -w`).
> - **`src/parser.zig`** — `scanGroups` was LIFTED here from `regex.zig` as `pub fn
>   scanGroups` — the single source of truth for capture numbering + `(?<name>)`
>   names, shared by both front-ends so they agree by construction. It is a *source*
>   scan (counts a `(` inside a lookaround / `{m,n}` re-parse, which is HIR-non-
>   capturing) ⇒ a safe upper bound on the highest HIR `.cap` index = exactly the
>   live slot-reset range the backtracker needs.
> - **`src/regex.zig`** — its private `scanGroups` body replaced by
>   `const scanGroups = parser.scanGroups;` (call site unchanged). Net −51 lines.
> - **`src/properties.zig`** — UNCHANGED from `main` (an interim `nGroups` HIR-walk
>   helper was added then removed once `scanGroups` became the shared sizer; `git
>   diff` is empty). Don't re-add it.
> - **`src/pattern.zig`** — `Built` gains `hir: Hir(HIR_CAP)` + `n_groups` + `gnames`;
>   `buildAll`, if `requires_backtracking`, calls `parser.scanGroups` for count+names
>   and returns the `.backtrack` strat BEFORE `thompson.build`. `Pattern`'s
>   `.backtrack` arm (before the DFA-budget logic) trims the HIR to `Hir(node_count)`,
>   bakes it + the `gnames`, and emits `has_dfa=false` `isMatch/find/count/findAll`
>   PLUS `captures/capturesAll` over `BacktrackerG(node_count)`. The capture path
>   mirrors the runtime `regex.capturesFrom` slot→`Group` materialization (shift to
>   absolute coords, group 0 = whole match, absent ⇒ null, names from `gnames`).
>   Exposes `pub const bt_node_count` for the trim test. `Strat` gained `.backtrack`.
> - **`tests/feat_api.zig`** — `btAgree()` (find-family) + `btCapAgree()` (captures)
>   differential helpers, 7 tests total: non-regular subset agreement, budget-over-
>   longer-input, findAll/count parity, trimmed-rodata sanity, numbered-capture
>   parity, named-capture parity (incl. `groupByName`), capturesAll parity. Each
>   asserts `comptime !P.has_dfa`.
>
> Two load-bearing facts for anyone extending this:
> 1. A green `zig build test` over *regular* patterns proves NOTHING about this arm —
>    it is comptime-eliminated unless a non-regular `Pattern` is instantiated. The
>    `feat_api` `btAgree`/`btCapAgree` tests are the sole validator; keep ≥1 of each.
> 2. Count + names come from `parser.scanGroups` over the source (NOT an HIR walk),
>    matching the runtime exactly — including groups inside lookaround, which are
>    HIR-non-capturing yet still reserve a numbered/named (non-participating) slot.
>
> **PERF (2026-06-01, post-captures): comptime seek prefilter.** The `.backtrack`
> arm now bakes a `seek_mod.Seek` and threads it into `BacktrackerG.init` when the
> HIR has a leading positive single-byte look-behind (`(?<=X)` ⇒
> `seq_extract.requiredLeadingLookbehindByte`, already generic over `cap`). `run`'s
> scan loop then `memchr`s to the next `X` at every step instead of a per-byte
> tree-walk — the same `lb_byte` filter the runtime `seek.build` uses. Measured
> (cross-engine bench, 1 MiB, min-of-3, counts agree): `lookbehind_amount`
> `(?<=\$)[0-9]+…` count **89 → 2678 MB/s (~30×)**, flipping it from 0.05× CTRE to
> **1.37× CTRE**.
>
> **PERF #2 (2026-06-01): comptime over-approximation DFA seek.** Generalizes the
> above to patterns with NO leading look-behind (atomic groups / possessive
> quantifiers, e.g. `atomic_token` `(?>[A-Za-z0-9_]+)@`). `pattern.zig overApproxDfa`
> builds a regular over-approximation (`hir.cloneSubtree(…, relax=true)`:
> `look`/`look_around`/`backref`→ε, `atomic` cut dropped) and compiles it with the
> SAME zero-allocator `thompson.build`/`full_dfa.compute` the regular arm uses — so
> it runs at comptime and bakes a `Dfa256` **value** into `.rodata` (no heap; this
> is why the route was "reuse `full_dfa`", not "make `freezeDense` comptime" — the
> dense builder is ~43 alloc sites, `full_dfa.compute` is zero). It's threaded into
> the backtracker via the runtime `seek.Seek`'s existing `dfa` `locate` path
> (`Seek.dfa = @constCast(&baked_dfa256)` — sound: the `dfa` path only *reads* it
> via `core.findLeftmost`, and the comptime `Seek` is never `deinit`'d). `lb_byte`
> still takes precedence when present (same layering as runtime). Soundness guards
> mirror `seek.build` exactly (drop if `lazy && anchored_end` / anchored / nullable
> approximation / build-fail). To make `cloneSubtree` callable at comptime it was
> generalized over BOTH store caps (`dcap`/`scap`); the 3 runtime callers
> (`seek`/`delegate`/`split_alt`) pass `null, null`. Measured: `atomic_token` count
> **31 → 288 MB/s (~9×)**, 0.18× → **1.70× CTRE**; grep **4.1× CTRE**. (Still ~0.6×
> the *runtime* backtracker on count — runtime's over-approx is a bit more selective
> — but beats it on grep.)
>
> Both perf steps are correctness-transparent (only move the scan start): the
> `btAgree`/`btCapAgree` differentials, a dedicated `seekParity` test (findAll/count
> over multi-match inputs with dead gaps — the case a wrong skip would break), and
> the cross-engine count gate all pass.
>
> **PERF #3 (2026-06-01): comptime-baked `delegate` plan — DONE, but ~no tokenizer
> win (measured, not assumed).** The last non-baked runtime prefilter: concat-internal
> regular-island delegation (a greedy/no-alt/no-cap regular *prefix* of a `concat`
> runs at DFA speed via `core.matchEndFrom`, the irregular glue stays in the
> tree-walk). `pattern.zig delegateIslands` reuses `delegate`'s classifier
> (`delegatable`/`hasUnboundedRep`/`minLen`, now `pub` + cap-generic) and the
> zero-allocator `thompson.build`/`full_dfa.compute` to bake each island's anchored
> `Dfa256` into `.rodata`; a baked `delegate.Plan` VALUE holds `@constCast(&dfa)`
> pointers (same soundness as the seek: read-only via `matchEndFrom`, never
> `deinit`'d) and is threaded into `BT.init`'s `del` arg. `delegateIslands` is
> cap-generic and runs over the trimmed baked `Hir(NN)` (refs preserved 1:1).
>
> HONEST OUTCOME: it fires for exactly ONE benchmark pattern (tokenizer, 1 island —
> the `\p{L}+` run; NOT atomic_token, whose only concat-left child is `.atomic`,
> rejected by `delegatable`). And an A/B (delegate ON vs forced-null, same build,
> min-of-3 @1MiB) showed **tokenizer ~28 MB/s either way — no measurable change.**
> The tokenizer's cost is dominated by its 8-way alternation of possessive/lookahead
> branches walked per byte; the single regular island is a tiny fraction, so
> delegating it moves nothing. So the earlier hypothesis ("baking delegate closes the
> ~0.71× tokenizer gap") was WRONG — the gap is the irreducible tree-walk, not the
> island. The delegate IS still worth keeping: on island-*dominated* inputs it's not
> cosmetic but correctness-relevant — e.g. `[a-z]+[0-9]+(?=END)` over a ~1 MB
> `a…a1234END` input returns the match at ~1.4 GB/s WITH the delegate, but
> *budget-exceeds → no-match* WITHOUT it (the per-byte tree-walk blows the anti-ReDoS
> step budget). Differential `seekParity`-style test added over delegate-firing
> patterns (`[a-z]+[0-9]+(?=END)` etc.); on==off, comptime==runtime. Suite 236/236.
>
> **ALSO FIXED (latent, pre-existing): `buildAll`'s parse-error `catch` switch was
> non-exhaustive** — only `Unsupported`/`TooComplex`, missing `hir.Error.Invalid`.
> It compiled only because the switch is analyzed for exhaustiveness *just* when a
> pattern's comptime parse actually fails; no shipped pattern hit that until a
> harness fed `Pattern` a `\b`-bearing pattern (comptime `lookLeaf` rejects `\b` ⇒
> parse fails ⇒ switch analyzed). Added the `.invalid` outcome → a hard
> `@compileError` (malformed syntax; no runtime fallback at comptime). `Outcome`
> gained `.invalid`.
>
> **PERF/COVERAGE #4 (2026-06-01): comptime LOOK-ASSERTIONS enabled ⇒ ALL 41
> benchmark patterns now compile (was 38).** Previously `\b \B`, `(?m)^ $`, `\Z`
> were a `@compileError` (`parser.lookLeaf`: `cap != null ⇒ Error.Unsupported`) — a
> pre-existing gate, NOT a real capability gap, since the comptime backtracker's
> `m`/`cont` already evaluate `.look` via `cc.lookHolds` (pure, comptime-safe). The
> fix was exactly what the old note predicted:
>   1. `parser.lookLeaf` — drop the `cap != null` reject; build the `.look` node for
>      both stores. (`\A`/`\z`/leading-`^`/trailing-`$` were never blocked — the
>      prescan folds them into the anchored-DFA fast path; only mid-pattern / `(?m)`
>      / `\b` / `\Z` looks produce `.look` nodes.)
>   2. `pattern.zig buildAll` — route `props.has_look` to the `.backtrack` arm
>      (`if (requires_backtracking or has_look)`) BEFORE `thompson.build`. This is a
>      COMPTIME-ONLY widening: `properties.requires_backtracking` deliberately still
>      omits `has_look` so the *runtime* keeps its separate `.bt_look` engine (NFA +
>      visited bitset, line-anchor `\n`-memchr); the comptime path has no `.bt_look`
>      and reuses the one tree-backtracker arm.
>   3. `Options.multiline` (new) — threads to `parser.parse` for the struct-flag
>      multiline form (`multiline_log`); inline `(?m)` already worked.
>
> **BUG FOUND + FIXED en route (the differential test earned its keep):** the
> comptime look path first gave `(?m)^#` count=4 vs runtime 3 — `nextSpan`/
> `nextCaptures` ran the backtracker over a `input[from..]` SLICE, so a resumed start
> looked like start-of-text and mis-fired `start_line`/`\b`. Added
> `backtrack.runFrom(input, from, slots)` that scans the FULL input from absolute
> `from` (the absolute-coord convention the runtime `.bt_look`/`btLookLineScan` uses);
> the comptime path now calls it (no more slice, no slot-shift). `run` =
> `runFrom(…,0,…)`, so runtime callers are unchanged.
>
> Outcomes (counts all == runtime): `backref_word` `(\b…\b) \1` ✓ (41 MB/s);
> `multiline_log` ✓ via `Options.multiline`; `deep_alternation` ✓ — its 40-keyword
> `\b(?:…)\b` now routes to the tree-walker, BYPASSING the `MAX_NFA=256` ceiling that
> rejects it on the DFA path (no `boundary_lits` AC engine needed at comptime). HONEST
> PERF: deep_alternation runs at ~4 MB/s on the comptime tree-walker (correct but
> slow — the runtime's `boundary_lits` Aho-Corasick is far faster); comptime here
> trades speed for *compiling at all*. `delegateIslands`/`overApproxDfa` needed
> `@setEvalBranchQuota(8M)` for the deep recursion. Suite 237/237; added a look
> differential test (`\b`, deep-alt, `\Z`, `(?m)`). Benchmark: all 41 `comptime:true`,
> harness threads `wl.multiline`, gate green.
>
> Original handoff plan below (kept for provenance; its Step 3 "captures" follow-up
> and Step 4 are now DONE).
> ---

Goal: close the comptime feature gap with CTRE by letting `Pattern(...)` accept the
**non-regular** subset (lookaround, backreferences, atomic groups / possessive
quantifiers) at compile time — *without* touching the regular DFA path, so regular
patterns keep their O(n) guarantee and only genuinely non-regular ones pay
bounded backtracking.

Strategy in one line: **bake the already-comptime-built HIR into `.rodata`, then emit
a monomorphized `find()` that runs the existing allocation-free tree backtracker over
runtime input** — architecturally identical to how the DFA path bakes `Dfa(ns,nk)`.

> Note: line numbers below were captured against a green build and cross-checked with
> `grep`/`sha256`/`wc`, but they will drift as the files change — re-confirm exact lines
> in your session before editing rather than trusting these verbatim.

## Verified facts (high confidence)

1. **The parser already produces the non-regular nodes.** `parser.zig` emits
   `.backref`, `.look_around`, `.atomic` (and `.look`) nodes — it does NOT reject them.
   So the comptime HIR for these patterns is fully built and valid.
2. **`thompson.build` is what rejects them** — `.backref, .look_around, .atomic =>
   Error.Unsupported` (around thompson.zig:135). `.look` is handled (conditional
   epsilon edges).
3. **Today these patterns compile-error via the wrong path.** `pattern.zig buildAll`
   catches *all* thompson errors as `.exploded` (pattern.zig:92-94), so a backref/
   lookaround pattern currently hits the "too complex / blew internal ceiling"
   `@compileError` (pattern.zig:134), not the "unsupported feature" one (pattern.zig:323).
   Minor existing inconsistency; our change removes it for the supported subset.
4. **The tree backtracker is reuse-ready.** `exec/backtrack.zig`:
   - Allocation-free. `run(input, slots_out)` takes a caller-sized `slots: []i32`;
     everything else is stack (CPS `Cont` frames + inline `[2*(MAX_GROUPS+1)]i32`).
   - Walks the HIR tree directly (`const H = hir.Hir(null)` at backtrack.zig:20).
   - Implements the whole non-regular set: lookaround, backref, atomic, lazy, captures.
   - Has the anti-ReDoS budget (`8000 + (len+1)*4000`) and `MAX_DEPTH=16384` guard.
   - **`run` does its own unanchored leftmost scan** (the `while (start <= input.len)`
     loop at backtrack.zig:289). So NO separate scan wrapper is needed — this resolves
     the earlier open question about whether the scan lived in `core.zig`. It does not.
5. **`properties.analyze` already detects this at comptime.** `requires_backtracking`
   is set true when the HIR contains `.backref` / `.look_around` / `.atomic`
   (containsBacktrack, properties.zig:~109). `analyze` is pure/comptime-evaluable and
   `buildAll` already calls it (pattern.zig:112). (Note: the `requires_backtracking`
   doc-comment in `Properties` is stale — it claims these route to Unsupported in the
   parser; the *code* sets the flag correctly.)
6. **HIR is comptime-bakeable** — `Hir(cap)` with `cap != null` is fixed arrays, no
   pointers, no allocator. `Match`/`Group` (match.zig) + `wholeMatch`/`advanceEmpty`
   are shared. `exec/charclass.zig` `hasBit`/`isWord`/`lookHolds` are inline,
   comptime-safe.
7. **`n_groups` is NOT stored on the HIR** — it's a parser-local field
   (`parser.zig:261`). The comptime path must compute it by walking the baked HIR.

## Why `n_groups` correctness is REQUIRED (not optional)

`backtrack.run` only clears/copies the *live* slot range `2*(n_groups+1)` per start
position (backtrack.zig:303-304). If `n_groups` is too small, a `.cap`/`.backref`
group's slots are never reset between start positions → wrong/garbage matches. The
`slots` array has capacity for `MAX_GROUPS`, so capacity is fine; the **live range
must cover the highest group index used**. So: compute `n_groups = max .cap set_idx`
by walking the HIR at comptime, pass it to the backtracker.

## Implementation steps

### Step 1 — make the backtracker generic over `cap`
`exec/backtrack.zig`: replace the file-level `const H = hir.Hir(null)` with a
`pub fn Backtracker(comptime cap: ?usize) type { const H = hir.Hir(cap); return struct { ... } }`
wrapper (or add a parallel generic and keep `Backtracker = BacktrackerG(null)` as an
alias so the ~6 existing runtime call sites in regex.zig / dupword.zig / delegate.zig /
split_alt.zig keep compiling unchanged). The body only uses `h.node()`, `h.setBitmap()`,
`h.root` — all identical across cap modes — so the change is mechanical.

### Step 2 — bake a trimmed HIR into rodata
In `buildAll`, the full `Hir(HIR_CAP=2048)` is `[2048]HNode + [2048][32]u8` (~98 KB)
and its tail is `undefined` (initComptime sets `.nodes = undefined`; only the first
`node_count` are written). Baking `undefined` into a const is illegal, and baking 98 KB
per pattern is wasteful. So **trim to exact size**: build a fresh comptime
`Hir(node_count)` (and copy the first `set_count` sets) — mirrors how the DFA path
sizes `Dfa(ns,nk)` to exact states×classes and fills padding. Keep it as a `const` in
the returned `struct`.

### Step 3 — wire `buildAll` / `Pattern` dispatch
- In `buildAll`: after `parser.parse` succeeds and `props = properties.analyze(...)`,
  branch BEFORE `thompson.build` (which would error): if
  `props.requires_backtracking` (and the pattern isn't otherwise `.unsupported`, e.g.
  `\p` under `(?i)`), return a new `Built` variant carrying the trimmed HIR +
  `n_groups` + anchored flags, instead of a DFA.
- Add a `.backtrack` arm to the `Built`/`Strat` machinery (today `.backtrack` is folded
  into `.dfa` at pattern.zig:120 — split it out).
- In `Pattern`: add a backtracking executor `struct` (alongside the literal and DFA
  ones) exposing `has_dfa = false`, and:
  - `isMatch` / `find` / `findFrom` / `count` — allocation-free. Each call constructs a
    fresh `var bt = Backtracker(NC).init(&baked_hir, a_start, a_end, n_groups, null, null)`
    on the stack and calls `run` with a stack `slots` buffer. (Mirror regex.zig:911.)
  - `captures` / `capturesAll` / `findAll` / `replace*` — take an allocator only to
    materialize `Match.groups` from `slots` (same split the runtime `Regex` uses,
    regex.zig:1075).
- Keep the `@compileError` at pattern.zig:323 ONLY for the genuinely unsupported
  residue (e.g. `\p` under `(?i)`, variable-width lookbehind if you choose to reject
  at comptime rather than return MatchBudgetExceeded at runtime).

### Step 4 — tests
- Differential against runtime `Regex` (extend `tests/feat_api.zig`): for a set of
  non-regular patterns (`(\w+)\1`, `foo(?=bar)`, `(?<=x)y`, `a*+a`, `(?>a*)a`), assert
  `Pattern(p,...).find(s)` matches `Regex.compile(p).find(s)` across inputs.
- ReDoS/budget: confirm a pathological backref pattern returns no-match within budget
  rather than hanging (the budget is inherited from `run`, so this should pass for free).
- Rodata size sanity: confirm trimmed bake (Step 2) — a tiny pattern shouldn't emit a
  98 KB table.

## Open items to resolve in-session
- Exact shape of the `Built` union once `.backtrack` is split from `.dfa`.
- Whether to expose `n_groups` from the parser onto the HIR (cleaner) vs. compute by
  walking the HIR in properties (no parser change). Walking is self-contained; prefer it
  for the prototype.
- Variable-width lookbehind: runtime returns `error.Budget`; decide comptime policy
  (reject with `@compileError`, or keep the runtime-style bounded failure).
- Confirm `containsBacktrack` also implies we skip `thompson`/`full_dfa` entirely for
  these patterns (it should — they'd only error).

## Repo state left for the fresh session
- Branch `comptime-backtracker` checked out, working tree clean.
- A stale interactive rebase of `feat/meta-engine` (unrelated, pre-existing) was cleared
  with `git rebase --quit` (no branches moved, no commits lost; the 3 pending commits
  remain in reflog/objects).
