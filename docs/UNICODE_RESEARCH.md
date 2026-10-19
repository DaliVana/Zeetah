# Unicode research notes — what the compared engines actually do

Working notes for the `(?u)` / `.unicode` codepoint-mode phase. Scope: the
engines in the cross-engine benchmark harness (`../zeetah-benchmark`), what each
one does for every Unicode feature zeetah lacks, and which design their
implementation uses. Everything marked **probed** was verified on this machine
(2026-10-19) against the installed library; everything else is from the
engine's own documentation or source.

Versions probed: PCRE2 10.48 (Unicode 17.0.0), Oniguruma 6.9.10, RE2 11.0.0,
Rust `regex` 1.13 / `regex-syntax` 0.8.11 / `regex-automata` 0.4.18 (Unicode
16.0.0 tables), PyPI `regex` 2026.9.29, Zig 0.17.0 `std.unicode`.

---

## 1. Where zeetah stands today

| Feature | zeetah `main` |
|---|---|
| Alphabet | bytes; no matcher decodes UTF-8 |
| `.` | one byte (minus `\n`) |
| `\d \w \s \b` | ASCII |
| `\p{…}` | General_Category only, **Latin-1 byte restriction** (cp ≤ 0xFF); scripts / binary props / `(?i)\p` → `NotImplemented` |
| `(?i)` | ASCII fold only (`a–z` ↔ `A–Z`) |
| `\x{…}` > 0xFF, `\o{…}` > 0o377 | `NotImplemented` (reserved) |
| `\h \v \R` | PCRE **8-bit** sets (NBSP, NEL; no U+2028/2029, no U+2000-block spaces) |
| `(?u)` / `.unicode` | `InvalidPattern` / `NotImplemented` (reserved) |
| Set operations `&&`, `--`, `~~`, nested `[…]` | not parsed (literal bytes in byte mode) |
| `\X` | not parsed |

Already in the tree and reusable: `unicode_class.zig` has the UAX44-LM3 loose
name matcher, full-Unicode General_Category range resolution (`resolve`), the
surrogate-free complement, and a working port of the Thompson/Cox UTF-8
range-splitting algorithm (`toUtf8Sequences`); `common.zig` has `Codepoint`,
`CodepointRange`, `UnicodeClass` (sorted ranges + ASCII bitmap fast path);
`unicode_tables.zig` has the Unicode **17.0.0** gc tables and the generator
`tools/gen_unicode_tables.zig`. None of it is wired into the NFA yet.

The `CompileFlags.unicode` doc-comment states the frozen contract: byte mode is
the committed default and every codepoint-aware behaviour, *including syntax
with a benign byte meaning today*, lives behind the flag. That rules out making
`\w` Unicode by default (PCRE2/RE2/Rust-byte-mode agree) and settles the
design question of "Rust-style default-on" vs "PCRE-style opt-in": **opt-in**.

---

## 2. Engine-by-engine

### 2.1 PCRE2 (the benchmark's reference engine; `pcre2`, `pcre2-jit`)

Model: two orthogonal options. `PCRE2_UTF` makes the subject/pattern UTF-8
(codepoint granularity for `.`, quantifiers, `\x{…}` > 0xFF, Unicode case
equivalence). `PCRE2_UCP` additionally redefines `\d \s \w \b \B` and the POSIX
classes via properties. The harness compiles **neither** (plain
`pcre2_compile(..., 0, ...)`), so in the benchmark PCRE2 is a byte engine except
that `\p{…}` is still full-Unicode (property escapes work without UTF).

Probed behaviour (UTF unless noted):

```
UTF . on é                  [é]
UTF \w café                 [caf]            ← \w stays ASCII without UCP
UCP \w café                 [café] [中] [١٢]  ← L|N|Mn|Pc
UCP \d arabic               [١٢] [45]        ← Nd
UTF (?i)σ                   [Σ] [σ] [ς]      ← simple fold, 3-way orbit
UTF (?i)k                   [k] [K] [K]      ← Kelvin sign included
UTF (?i)strasse             [STRASSE]        ← NO full folding (ß ≠ ss)
UTF \p{Greek}               [αβ]
UTF \p{Letter}              COMPILE ERROR    ← short names only
UTF \p{Alphabetic}          [ab] [中]
UTF \p{scx:Hira}            [か]
UTF [[:alpha:]]             [ab]   / UCP: [ab] [é]
UTF \h                      matches U+3000 (always Unicode, UCP or not)
UTF \R                      matches U+2028 and \r\n
UTF (?i)\p{Lu} on aB        [a] [B]          ← ≥10.45: Lu/Ll/Lt → Lc under (?i)
UTF [a--b]                  COMPILE ERROR    ← no set operations
UTF \X                      [é] [x]          ← UAX#29 grapheme clusters
UTF \x{E9} / \N{U+E9}       [é]  ; non-UTF \x{E9} = the byte 0xE9
UTF \b\w+\b café            [caf] [x] ; UCP: [café] [x]
UTF . on invalid byte       match error (needs PCRE2_MATCH_INVALID_UTF)
```

Property set: gc (short names + `L&`/`Lc`), scripts (Script, and Script
Extensions via `scx:`), `Bidi_Class`, Bidi_Control, and a few binary
properties; special `Any`, `Xan`/`Xps`/`Xsp`/`Xwd`/`Xuc`. No long names, no
`Is` prefix, no blocks. UCP `\s` = `\p{Z}|\h|\v`, `\w` = `\p{L}|\p{N}|\p{Mn}|\p{Pc}`
(10.43+). Case folding: simple, with the two ASCII exceptions (`K`→Kelvin,
`S`→long s) switchable off by `PCRE2_EXTRA_CASELESS_RESTRICT`. `\R` is atomic.
Invalid UTF-8 is a match-time **error** unless `PCRE2_MATCH_INVALID_UTF`.

Implementation: backtracking interpreter / JIT decode UTF-8 at match time;
property tests are a per-character table lookup (`PRIV(ucd_records)`), which
the docs call out as "not fast".

### 2.2 Oniguruma (`oniguruma`; Ruby syntax, `ONIG_ENCODING_UTF8`)

Model: the encoding *is* the mode. The harness uses UTF-8, so Oniguruma runs
**fully Unicode** in the benchmark (the corpus is ASCII in matched regions, so
counts still agree). Probed:

```
. on é                     [é]
\w café 中 ١٢              [café] [中] [١٢]   (WORD_IS_ASCII option → [caf])
\d arabic                  [١٢] [45]
\b\w+\b café               [café] [x]
(?i)σ                      [Σ] [σ] [ς]
(?i)k                      [k] [K] [K]
(?i)strasse                [STRASSE] [straße]  ← FULL case folding (ß = ss)
(?i)ß                      [ss] [SS] [ß]
\p{Greek} / \p{Letter}     yes (long names accepted)
\p{Alphabetic}             [ab] [中]
\p{In_Basic_Latin}         blocks supported
[[:alpha:]]                [ab] [é]            ← POSIX classes are Unicode
\h                         ASCII-only ([a] [b] around U+3000: not matched)
\R                         matches U+2028, \r\n
(?i)\p{Lu} on aB           [B]                 ← property NOT folded
[a-z&&[^aeiou]]            [h] [ll]            ← intersection + nesting
\X                         [é] [x]
\s                         NBSP and U+2028 are whitespace
. on invalid byte          [a] [�] [b]        ← invalid byte matched as a char
```

Implementation: per-encoding callbacks (`mbc_to_code`, `is_code_ctype`,
`get_case_fold_codes_by_str`) called from the backtracking VM; full case
folding is done by expanding the pattern string (the source of CVE-2017-9225 in
6.2.0, see `docs/SECURITY_PROBLEMS.md`).

### 2.3 RE2 (`re2`, UTF-8 encoding by default)

Model: Unicode on, no switch except `Latin1` (whole-pattern). Probed:

```
. on é                     [é]
\w café / \d arabic        [caf] / [45]        ← Perl classes are ASCII (RL1.2a)
\b café                    [caf] [x]           ← \b is ASCII
(?i)σ                      [Σ] [σ] [ς]         ← simple folding
(?i)k                      [k] [K] [K]
(?i)strasse                [STRASSE]
\p{Greek} / \p{L} / \pN    yes (scripts + gc, short and long script names)
\p{Letter} / \p{Alphabetic} / \p{scx=…}   COMPILE ERROR ← no long gc names, no binary props, no scx
[[:alpha:]]                [ab]                 ← ASCII
(?i)\p{Lu} on aB           [a] [B]              ← property folded under (?i)
\x{E9}                     [é]  (UTF-8 bytes)
\C                         one byte
. on invalid byte          [a] [b]              ← invalid byte never matches
Latin1 .                   one byte
\s                         ASCII only
\R                         COMPILE ERROR
```

Implementation (the zeetah-relevant one): every Unicode class is compiled into
a **byte-level UTF-8 automaton** (`re2/compile.cc`, Thompson's `utf8ranges`
split from Plan 9 grep) with a small suffix cache (`rune_cache_`) that re-uses
common continuation-byte states. `\p` under `(?i)` adds the simple-fold orbits
(`unicode_casefold.cc`: the orbit table is stored as `(lo, hi, delta)` runs with
`EvenOdd`/`OddEven` deltas — very compact). Word boundary is ASCII only, so the
DFA needs one byte of context.

### 2.4 Rust `regex` (`rust`) and `fancy-regex` (`fancy-regex`)

Model: Unicode **on by default**, `(?-u)` turns it off per scope; in default
`utf8(true)` mode a byte-mode class that could match a non-ASCII byte is an
error (`(?-u).` and `(?-u)\xFF` are rejected unless the `bytes::Regex` API is
used). `fancy-regex` delegates all of this to `regex-syntax`/`regex-automata`
and adds backtracking features on top; it inherits every semantic below.

Probed:

```
. on é                     ["é"]
\w café 中 ١٢              ["café", "中文", "١٢٣"]   ← Unicode \w (UTS#18 Annex C)
\d arabic                  ["١٢٣", "456"]            ← Nd
\b café                    ["naïve", "café"]          ← Unicode \b
(?i)σ / (?i)k              simple fold incl. Kelvin
(?i)strasse                ["STRASSE"]                ← no full fold
\p{Greek} \p{Letter} \p{Alphabetic} \p{scx=Hira} \p{age:3.2}  all accepted
[[:alpha:]]                ["ab"]                     ← POSIX classes ASCII (RL1.2a)
\s                         White_Space (NEL, LS, NBSP, U+3000; not ZWSP)
[\p{L}--\p{Lu}]            ["ab","ef"]                ← set ops: && -- ~~ and nesting
(?i)\p{Lu} on aB           ["a","B"]                  ← classes folded before negation
\X \R \h                   parse errors (not supported)
(?-u)\w café               ["caf"]
\p{Any}                    one codepoint per match
\p{InBasicLatin}           parse error (no blocks)
```

`UNICODE.md` (shipped in the crate) is the conformance statement: full UTS#18
Level 1 except RL1.6 line boundaries (only `\n`, or CRLF mode) and RL1.2a
compatibility properties (POSIX classes ASCII). Definitions: `\w` =
`Alphabetic ∪ gc=Mark ∪ gc=Decimal_Number ∪ gc=Connector_Punctuation ∪ Join_Control`,
`\s` = `White_Space`, `\d` = `gc=Nd`; `\b` is defined in terms of `\w`. Case
insensitivity is **simple** folding, applied to every class *before* negation
(so `(?i)[^x]` is not "everything").

Implementation (the model zeetah should copy):

* `regex-syntax/src/hir/interval.rs` — `IntervalSet<ClassUnicodeRange>`:
  sorted non-overlapping ranges with `union / intersect / difference /
  symmetric_difference / negate / case_fold_simple / canonicalize`. Folding
  walks the overlapping entries of a sorted `(char, &[char])` orbit table
  (`SimpleCaseFolder`, ~2900 entries; orbit size ≤ 4).
* `regex-syntax/src/unicode.rs` — property lookup: normalise name (lowercase,
  drop `_ - space`), try binary property → general category → script, with
  the `cf`/`sc`/`lc` ambiguity special-cased; `prop=value` / `prop:value` /
  `prop!=value`; `Is` prefix accepted.
* `regex-syntax/src/utf8.rs` — `Utf8Sequences` (the algorithm already ported in
  `unicode_class.toUtf8Sequences`).
* `regex-automata/src/nfa/thompson/compiler.rs` — `c_unicode_class`: ASCII-only
  class → one sparse state; otherwise stream the sorted UTF-8 sequences into
  `Utf8Compiler`, a Daciuk-style incremental **minimal acyclic DFA builder**
  with a bounded hash map of compiled states (`Utf8BoundedMap`, 10 000 slots).
  Result: `\w` is ~283 NFA states instead of ~3000 for the naive
  alternation; the PikeVM on `(?m)^\w{20}` went from 45 s to 1.4 s. Reverse
  compilation needs the `RangeTrie` to re-sort overlapping reversed sequences
  (zeetah does not build reverse NFAs over the HIR, so this is not needed).
* `regex-automata/src/util/look.rs` — Unicode `\b`: decode the codepoint before
  and after `at` (`utf8::decode_last` / `decode`), invalid or missing → not a
  word char, then binary-search `PERL_WORD`. The DFAs (`dfa`, `hybrid`) support
  Unicode `\b` **only while the haystack is ASCII**: they quit on the first
  non-ASCII byte and the meta engine falls back to the PikeVM/onepass/
  backtracker. This is the trick that keeps `\b` cheap on ASCII text.
* Literal extraction under `(?iu)` expands case-fold alternatives
  (`(?i)She` → SHE, SHe, ſHE, …) up to a size budget; beyond it the prefilter
  is dropped.

### 2.5 .NET `System.Text.RegularExpressions` (`dotnet-regex`; not probed)

From the documented semantics: strings are UTF-16, `.` and classes operate on
one **UTF-16 code unit** (surrogate pairs are two chars). `\w`, `\d`, `\s`, `\b`
are **Unicode by default** (`\d` = Nd; `\w` = L, Mn, Nd, Pc; use
`RegexOptions.ECMAScript` for ASCII). `\p{…}`: general categories and **blocks**
(`\p{IsGreek}` is a *block*, not a script); no scripts, no binary properties.
`RegexOptions.IgnoreCase` uses a culture-sensitive case table (invariant by
default since .NET 7, simple 1:1 mapping). No `\X`, no set operations (the
`[a-z-[aeiou]]` subtraction syntax is .NET-specific). The harness uses
`RegexOptions.None`, i.e. Unicode classes.

### 2.6 Python `re` / PyPI `regex` (`python-re`, `python-regex`)

`re` (stdlib, str patterns): Unicode `\w \d \s \b` by default (`re.ASCII` to
opt out), `.` is one code point, simple-ish case folding via `str.lower()` plus
a small special-case table, **no `\p{…}`**, no set operations, no `\X`.

PyPI `regex` (what tokenizer code uses; probed): everything above plus
`\p{…}` with long names, scripts, `scx=`, binary properties, **blocks**
(`\p{InBasicLatin}`), POSIX classes Unicode (`[[:alpha:]]` matches `é` and
`中`), `\h` (Unicode), `\R`, `\X` (UAX#29 incl. ZWJ emoji), set operations in
`V1` mode (`[\p{L}--\p{Lu}]`, `[[a-z]&&[^aeiou]]`), `(?a)` ASCII mode, and
**full** case folding under the `F` flag (default in V1 — but the probe shows
`(?i)strasse` not matching `straße` in the default V0 mode). `(?i)\p{Lu}` matches
both `a` and `B` (property folded).

### 2.7 CTRE, mvzr, POSIX `regex.h`, C++ `std::regex`

CTRE: `\p{…}` is accepted only with its optional Unicode DB header; the harness
**skips** CTRE on the `unicode_prop` and `tokenizer` workloads. mvzr: byte
engine, skipped likewise. POSIX `regex.h` and `std::regex`: byte/locale
engines; `\p` is not a thing. None of these constrain zeetah's design.

---

## 3. Cross-engine comparison matrix

| Feature | PCRE2 (UTF) | PCRE2 (UTF+UCP) | Oniguruma UTF-8 | RE2 | Rust `regex` | .NET | PyPI `regex` |
|---|---|---|---|---|---|---|---|
| `.` = codepoint | ✅ | ✅ | ✅ | ✅ | ✅ | UTF-16 unit | ✅ |
| `\d \w \s` Unicode | ❌ | ✅ | ✅ | ❌ | ✅ | ✅ | ✅ |
| `\b` Unicode | ❌ | ✅ | ✅ | ❌ | ✅ | ✅ | ✅ |
| gc properties | short names | short | short+long | short+long(script) | all aliases | yes | all aliases |
| Scripts | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ (blocks) | ✅ |
| Script_Extensions | ✅ | ✅ | ✅ | ❌ | ✅ | ❌ | ✅ |
| Binary properties | few | few | ✅ | ❌ | ~50 | ❌ | ✅ |
| Blocks | ❌ | ❌ | ✅ | ❌ | ❌ | ✅ | ✅ |
| `(?i)` simple fold | ✅ (+K/S) | ✅ | ✅ | ✅ | ✅ | culture | ✅ |
| `(?i)` full fold (ß↔ss) | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | `F` flag |
| `(?i)\p{Lu}` folded | Lc | Lc | ❌ | ✅ | ✅ | ? | ✅ |
| Set ops `&& -- ~~` | ❌ | ❌ | `&&` only | ❌ | ✅ | `-[…]` | V1 |
| POSIX classes | ASCII | Unicode | Unicode | ASCII | ASCII | n/a | Unicode |
| `\h \v` Unicode | ✅ | ✅ | ❌ | ❌ | ❌ | n/a | ✅ |
| `\R` incl. U+2028/9 | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ | ✅ |
| `\X` | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ | ✅ |
| Invalid UTF-8 input | error | error | matched as char | never matches | never matches | n/a | n/a |

Every automaton engine (RE2, Rust) lowers classes to byte automata and treats
an invalid byte as "no codepoint here"; every backtracker decodes at match
time. zeetah has both tiers, so it needs **both** mechanisms (§5 of the plan).

---

## 4. Decisions the research settles

1. **Opt-in, Rust-semantics.** `(?u)` / `.unicode` / `PatternOptions.unicode`
   switch to codepoint mode; byte mode stays frozen. Inside `(?u)`, follow the
   Rust/UTS#18 definitions (`\w` Annex C, `\s` = White_Space, `\d` = Nd,
   simple case folding, properties folded before negation, set operations,
   POSIX classes ASCII). Where PCRE2-UCP differs (`\w` includes all `N`, only
   `Mn`; `\s` includes `\h\v`), note it in `PCRE_COMPATIBILITY_UNICODE.md`.
   The benchmark gate is unaffected (ASCII corpus).
2. **Byte-level UTF-8 automata for the DFA tier**, built with suffix sharing
   (Daciuk / `Utf8Compiler`), **not** a naive HIR alternation — otherwise
   `\p{L}` is ~3000 NFA states and the tokenizer regex (7 classes) blows the
   runtime NFA ceiling.
3. **Decode-at-match for the backtracking tier** (tree backtracker, compiled
   comptime backtracker) and for Unicode `\b` (`decode_last`/`decode` + binary
   search). Rust's "DFA quits on non-ASCII and falls back" trick for `\b` is
   the follow-up optimisation, not v1.
4. **Simple folding only.** Full folding (ß↔ss) is a 1:n mapping that breaks
   class-as-set semantics and backreferences; only Oniguruma and PyPI-`regex`
   do it. Defer.
5. **Properties to ship:** General_Category (all aliases), Script,
   Script_Extensions, the ~45 binary properties available from PropList /
   DerivedCoreProperties / emoji-data, `Any` / `ASCII` / `Assigned`; `\h \v \R`
   Unicode lists under `(?u)`. Defer: blocks, `Age`, `Bidi_Class`, `\X`,
   `\N{U+…}` (cheap, could ride along), `(*UCP)`-style verbs.
6. **Invalid UTF-8 never matches a codepoint construct** (RE2/Rust), never an
   error (PCRE2) — a byte engine must keep accepting arbitrary bytes.
7. **Tables:** generate from Unicode 17.0.0 UCD files (already the pinned
   version; PCRE2 on this machine is also 17.0.0, Rust is 16.0.0). Range tables
   as `{lo: u21, hi: u21}` (8 B/range); case folding as a sorted orbit table
   `(cp, [≤3]others)` like Rust; names via UAX44-LM3 normalisation with alias
   tables from PropertyAliases / PropertyValueAliases.

---

## 5. Sources

* UTS #18 Unicode Regular Expressions — https://www.unicode.org/reports/tr18/
* `man pcre2unicode`, `man pcre2pattern` (PCRE2 10.48, local)
* Rust `regex` 1.13 `UNICODE.md`; `regex-syntax` 0.8.11 `src/unicode.rs`,
  `src/hir/interval.rs`, `src/hir/translate.rs`; `regex-automata` 0.4.18
  `src/nfa/thompson/compiler.rs` (`Utf8Compiler`, `c_unicode_class`),
  `src/nfa/thompson/range_trie.rs` (design essay), `src/util/look.rs`
  (`is_word_char`) — all from `~/.cargo/registry`
* RE2 11.0.0 `re2/re2.h` (Options, "simple case folding" note); RE2 syntax
  reference for `\pN` / `\C`
* Oniguruma 6.9.10 `oniguruma.h` (`ONIG_OPTION_*_IS_ASCII`,
  `ONIG_SYN_OP2_ESC_P_BRACE_*`)
* PyPI `regex` 2026.9.29 `_regex_core.py` (`SET_OPS`, `FULLCASE`, `VERSION1`)
* `../zeetah-benchmark/UNICODE_USE_CASES.md` (what the gaps are for; UTS#18
  tier mapping) and `benchmarks.json` (`unicode_prop`, `tokenizer` workloads)
* Probe programs: `scratchpad/probe_pcre2.c`, `probe_onig.c`, `probe_re2.cc`,
  `rsprobe/` (Rust), and the PyPI `regex` one-liner — outputs reproduced above.
