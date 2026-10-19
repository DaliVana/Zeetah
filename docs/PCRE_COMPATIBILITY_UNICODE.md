# Zeetah vs. PCRE2 — Unicode Compatibility

The Unicode slice of the Zeetah ↔ **PCRE2 10.x** comparison. For syntax,
escapes, quantifiers, groups, anchors, and Perl control constructs, see
[PCRE_COMPATIBILITY.md](PCRE_COMPATIBILITY.md). The research behind the
design (what PCRE2, Oniguruma, RE2, Rust `regex`, .NET and PyPI `regex`
actually do) is in [UNICODE_RESEARCH.md](UNICODE_RESEARCH.md); the design
itself in [UNICODE_PLAN.md](UNICODE_PLAN.md).

Verified against the engine source — `src/parser.zig`, `src/unicode_class.zig`,
`src/unicode_set.zig`, `src/utf8.zig`, `src/thompson.zig` — and the suite in
`tests/feat_unicode.zig`.

---

## Executive summary

Zeetah has **two modes**, chosen per pattern (or per scope):

- **Byte mode** — the default, and a frozen contract: the matcher runs over a
  256-symbol byte alphabet, `.` is one byte, `\d \w \s \b` are ASCII, `\p` is
  General_Category restricted to Latin-1. This is exactly **Rust `regex` / RE2
  with Unicode mode off**, and it is also what PCRE2 does **without**
  `PCRE2_UTF`/`PCRE2_UCP` (the configuration the cross-engine benchmark runs).
- **Codepoint mode** — `Regex.compileWithFlags(…, .{ .unicode = true })`,
  `Pattern(…, .{ .unicode = true })`, or inline `(?u)` / `(?u:…)` (`(?-u)`
  turns it off again). The match unit becomes one UTF-8-encoded scalar value
  and every Unicode construct gets its UTS #18 Level 1 meaning. Semantically
  this is **Rust `regex` with Unicode on**, which is close to — but not
  identical with — PCRE2 with **`PCRE2_UTF | PCRE2_UCP`**. The differences are
  listed below.

So a PCRE2 pattern compiled with `PCRE2_UTF|PCRE2_UCP` ports to Zeetah by
setting `.unicode = true`; one compiled without them ports as-is.

---

## 1. Core semantics

| Capability | PCRE2 (UTF+UCP) | Zeetah `(?u)` | Zeetah byte mode | Compat |
|---|---|---|---|---|
| Subject alphabet | codepoints | **scalars** (UTF-8 decoded; invalid bytes never match) | bytes | ✅ / ⚠️ |
| `.` | one codepoint (not `\n`) | one scalar (not `\n`; `(?s)` adds it) | one byte | ✅ |
| Quantifiers | per codepoint | per scalar (`.{3}` = 3 characters) | per byte | ✅ |
| `\d` | `\p{Nd}` | `\p{Nd}` | `[0-9]` | ✅ |
| `\s` | `\p{Z}` ∪ `\h` ∪ `\v` | `\p{White_Space}` | ASCII | ⚠️ ¹ |
| `\w` | `\p{L}` ∪ `\p{N}` ∪ `\p{Mn}` ∪ `\p{Pc}` | Alphabetic ∪ **M** ∪ **Nd** ∪ Pc ∪ Join_Control (UTS #18 Annex C) | `[A-Za-z0-9_]` | ⚠️ ² |
| `\b` / `\B` | from `\w` | from `\w` (undecodable neighbour = non-word) | ASCII | ⚠️ ² |
| `\h \v \R` | Unicode lists (always) | Unicode lists | PCRE 8-bit lists | ✅ |
| `\X` | ✅ | ❌ `NotImplemented` | ❌ | ❌ |
| Case-insensitive `(?i)` | simple fold + `K`/`S` ↔ Kelvin / long-s (unless `CASELESS_RESTRICT`) | Unicode **simple** folding (CaseFolding C+S), incl. Kelvin / long-s / `σΣς` | ASCII fold | ✅ |
| Full case folding (`ß` ≡ `ss`) | ❌ | ❌ | ❌ | ✅ (both lack it) |
| `(?i)\p{Lu}` | matches `Lc` (10.45+) | property folded ⇒ every cased letter | `NotImplemented` | ✅ |
| Invalid UTF-8 in the subject | error unless `MATCH_INVALID_UTF` | never matches a codepoint construct, never an error | matched as bytes | ⚠️ |

¹ `\s`: PCRE2-UCP's set is `\p{Z} ∪ \h ∪ \v`; Zeetah's is `White_Space`. They
agree on every common character (space, tab, NEL, NBSP, U+2000–U+200A,
U+2028/9, U+3000, …) and differ only on U+180E MONGOLIAN VOWEL SEPARATOR
(in `\h`, not White_Space) and U+200B ZERO WIDTH SPACE (in neither).
² `\w`: PCRE2 includes *all* numbers (`No` too: ½, ²) and only non-spacing
marks; Zeetah (Rust/UTS #18) excludes `No` but includes all marks (`Mc`, `Me`)
plus `Join_Control` (ZWJ/ZWNJ); letter-numbers (`Nl`, Ⅻ) are in both (via
`Alphabetic`). Letters, digits, `_`, CJK and combining accents agree. The same
delta applies to `\b`.

---

## 2. Unicode properties `\p{…}` / `\P{…}`

| `\p` capability | PCRE2 | Zeetah `(?u)` | Zeetah byte mode |
|---|---|---|---|
| General_Category short names (`\pL`, `\p{Lu}`, `\p{Nd}`, `L&`) | ✅ | ✅ | ✅ Latin-1 only |
| Long names / aliases (`\p{Letter}`, `\p{Uppercase_Letter}`, `gc=Lu`, `gc:Lu`) | ❌ short only | ✅ (UAX #44, loose matching) | ✅ Latin-1 only |
| `Is` prefix (`\p{IsGreek}`) | ❌ | ✅ | ✅ (gc) |
| Scripts (`\p{Greek}`, `\p{Han}`, `sc=Grek`, `Script:Latin`) | ✅ | ✅ (Unicode 17.0.0) | ❌ `NotImplemented` |
| Script extensions (`\p{scx:Hira}`) | ✅ | ✅ | ❌ |
| Binary properties | few (`Bidi_Control`, …) | ~55 (`Alphabetic`, `White_Space`, `Dash`, `Emoji*`, `ID_Start`, `Math`, …) | ❌ |
| `Any`, `ASCII`, `Assigned` | `Any` | ✅ all three | ✅ |
| Bidi_Class (`\p{Bidi_Class:AL}`) | ✅ | ❌ | ❌ |
| PCRE specials `Xan Xps Xsp Xwd Xuc` | ✅ | ❌ | ❌ |
| Blocks (`\p{InGreek}`), `Age` | ❌ | ❌ | ❌ |
| Negation `\P{…}`, `\p{^…}` | ✅ | ✅ (+ `\p{gc!=L}`, `\p{Alphabetic=No}`) | ✅ |
| `\p` inside `[…]` | ✅ | ✅ | ✅ |
| Unknown / misspelled name | error | `NotImplemented` | `NotImplemented` |

---

## 3. Character classes

| Feature | PCRE2 (UTF) | Zeetah `(?u)` |
|---|---|---|
| Codepoint members and ranges (`[à-ÿ]`, `[😀-🙏]`) | ✅ | ✅ |
| `\x{…}` / `\N{U+…}` members | ✅ | ✅ |
| `\d \w \s \h \v \p` members | ✅ | ✅ |
| POSIX `[:alpha:]` | ASCII; Unicode under UCP | ASCII (UTS #18 RL1.2a, like Rust); `[:^alpha:]` complements the whole universe |
| Nested classes `[[a-z]…]` | ❌ | ✅ |
| Set operations `&&` `--` `~~` | ❌ (`[a--b]` is a range error) | ✅ Rust precedence: everything so far ∘ the rest |
| Negation of the whole class | ✅ | ✅ (after folding under `(?i)`) |

A pattern that uses `--` as two literal hyphens in a PCRE class (rare) must
escape one of them under `(?u)`; byte mode is unchanged.

---

## 4. Escapes

| Escape | PCRE2 (UTF) | Zeetah `(?u)` | Zeetah byte mode |
|---|---|---|---|
| `\xHH` | codepoint U+00HH | scalar U+00HH (UTF-8 encoded) | the byte `0xHH` |
| `\x{…}`, `\o{…}` | codepoint ≤ U+10FFFF | scalar ≤ U+10FFFF; surrogates / larger → `InvalidPattern` | ≤ 0xFF, larger → `NotImplemented` |
| `\N{U+hhhh}` | ✅ | ✅ | ❌ |
| `\N{name}` | ❌ | ❌ `NotImplemented` | ❌ |
| `\C` (one code unit) | ✅ | ❌ (use a `(?-u:.)` scope) | n/a |
| Literal non-ASCII in the pattern | one character | one character (malformed UTF-8 in the *pattern* → `InvalidPattern`) | its bytes |

---

## 5. Mode selection

| Mechanism | PCRE2 | Zeetah |
|---|---|---|
| Whole pattern | `PCRE2_UTF` + `PCRE2_UCP` options; `(*UTF)` / `(*UCP)` leaders | `.unicode = true` (`CompileFlags` / `PatternOptions`) |
| Inline | — (UTF cannot be scoped) | `(?u)` toggle, `(?u:…)` scope, `(?-u)` off |
| Per-escape ASCII overrides | `PCRE2_EXTRA_ASCII_BSD/BSS/BSW`, `(?aD)` … | scope with `(?-u:…)` |
| Mixing byte and codepoint constructs | not possible | allowed (`(?u)\w+(?-u)\xFF`) |

Zeetah's `(?u)` is one flag covering both PCRE2 roles (UTF *and* UCP): there
is no "UTF without UCP" mode where `.` is a codepoint but `\w` stays ASCII. To
get that, write `(?u)` and use explicit ASCII classes (`[A-Za-z0-9_]`) where
PCRE2 would have used `\w`.

---

## 6. Performance characteristics worth knowing

- Codepoint classes compile to UTF-8 **byte automata** (suffix-shared; `\p{L}`
  is ~300 NFA states) and run on the regular DFA / lazy-DFA engines; ASCII-only
  classes are still byte classes with every byte fast path.
- The SIMD class-run paths (`class_span`, `class_seq`, Teddy for `(?i)`
  literals) do not apply to wide codepoint classes: on ASCII text `(?u)\w+`
  runs at lazy-DFA speed (~100 MB/s on the benchmark corpus) where byte-mode
  `\w+` runs at ~30 GB/s; `(?iu)sherlock` is a DFA (Kelvin sign in `k`), not a
  Teddy scan.
- Unicode `\b` patterns run on the bounded backtracker / PikeVM; the look-aware
  lazy DFA only models one byte of context.
- PCRE2 itself notes that `\p` matching and UCP `\w`/`\b` are "noticeably
  slower"; both engines pay for Unicode, in different places.

---

## 7. When this matters (and when it doesn't)

**Doesn't matter — parity with PCRE2 in both modes:** ASCII text and byte
protocols (HTTP, logs, config, identifiers, numbers, CSV), structured
extraction over Latin-1 bytes.

**Needs `(?u)` to match PCRE2 UTF/UCP:** `\w+`/`\b`/`\d` over non-Latin text;
`\p{Script}` / binary properties; `\p{L}` meaning all letters; `(?i)` over
non-ASCII (`ß`, `İ`, `Σ`/`σ`, Kelvin); codepoint-granular `.`.

**Still not available anywhere:** `\X`, full case folding, normalization,
script runs, `Bidi_Class`, blocks.

---

## See also

- [PCRE_COMPATIBILITY.md](PCRE_COMPATIBILITY.md) — everything non-Unicode.
- [UNICODE_RESEARCH.md](UNICODE_RESEARCH.md) — probed behaviour of PCRE2,
  Oniguruma, RE2, Rust `regex`, PyPI `regex` and the design decisions.
- [UNICODE_PLAN.md](UNICODE_PLAN.md) — the implementation design.
- [ARCHITECTURE.md](ARCHITECTURE.md) — the `.uclass` node and the UTF-8 compiler.
