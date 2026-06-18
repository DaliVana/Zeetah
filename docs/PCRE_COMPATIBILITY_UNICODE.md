# Zeetah vs. PCRE2 — Unicode Compatibility

The Unicode slice of the Zeetah ↔ **PCRE2 10.x** comparison. For syntax,
escapes, quantifiers, groups, anchors, and Perl control constructs, see
[PCRE_COMPATIBILITY.md](PCRE_COMPATIBILITY.md).

Verified against the real engine source — `src/parser.zig`,
`src/unicode_class.zig`, `src/exec/charclass.zig`.

---

## Executive summary

Zeetah is **byte-oriented end to end**: the matcher runs over a 256-symbol (byte)
alphabet and **no matcher decodes UTF-8**. This is exactly **Rust `regex` / RE2
with Unicode mode off**. PCRE2, by contrast, offers full codepoint matching and
Unicode property tables under its UTF + UCP options.

The headline:

- **Byte mode is the permanent, committed default** — it will not change.
- **Codepoint mode is reserved, not implemented** — `(?u)` / `.unicode` both
  return `error.NotImplemented` today, and when shipped they will *add*
  codepoint behavior **only when opted in**, never altering the byte default.
  So a future Unicode phase is an additive, non-breaking change.
- The one Unicode feature that *does* work today is `\p{…}` General_Category,
  but **only restricted to the Latin-1 byte range** (U+0000–U+00FF).

Therefore Unicode-heavy PCRE patterns are the **least portable** category. If
your inputs are ASCII / byte protocols (HTTP, logs, config, identifiers,
numbers), none of this matters and the two engines agree.

---

## 1. Core semantics: byte vs. codepoint

| Capability | PCRE2 (UTF + UCP) | Zeetah | Compat |
|---|---|---|---|
| Subject alphabet | Codepoints | **Bytes** (256 symbols), no UTF-8 decode in matcher | ⚠️ RE2 Unicode-off |
| `.` granularity | One codepoint | **One byte** | ⚠️ a multibyte char = N `.` matches |
| `\w` / `\d` / `\s` | Unicode-aware | **ASCII only** (`[A-Za-z0-9_]`, `[0-9]`, ASCII WS) | ⚠️ |
| `\b` / `\B` | Unicode word boundary | **ASCII word boundary** (`isWord` = `[A-Za-z0-9_]`) | ⚠️ |
| `\X` (extended grapheme cluster) | ✅ | ❌ `NotImplemented` | ❌ |
| Case-insensitive `(?i)` fold | Unicode simple/full fold | **ASCII-only fold** (`a–z` ↔ `A–Z`), done at set construction | ⚠️ |

Evidence:

- `src/common.zig`: `pub const Char = u8;` — the entire class machinery is
  byte-typed; character sets are 256-bit bitmaps (`[32]u8`).
- `src/exec/charclass.zig`: `isWord(c)` = `[A-Za-z0-9_]` exactly; `\b` is
  `bw != aw` over that ASCII predicate.
- `src/parser.zig` `foldCaseBitmap`: folds only `'a'..'z'` ↔ `'A'..'Z'`.

**Practical consequence:** a pattern like `\w+` applied to `"café"` matches
`"caf"` plus the two bytes of `é` are *not* word characters — so it stops at
`caf`. PCRE in UTF+UCP mode matches the whole word. Byte mode also means `.`
over UTF-8 text counts bytes, not characters.

---

## 2. Unicode properties `\p{…}` / `\P{…}`

Supported **syntactically**, but resolved to a **Latin-1 byte restriction** of
the property — codepoints above U+00FF are silently dropped from the generated
bitmap.

| `\p` capability | PCRE2 | Zeetah | Notes |
|---|---|---|---|
| General_Category, one/two-letter (`\pL`, `\p{Lu}`, `\p{Nd}`, `\p{L}`…) | ✅ full Unicode | ⚠️ **only codepoints ≤ U+00FF** | the only working `\p` path |
| `\pL` shorthand (no braces) | ✅ | ✅ (Latin-1) | |
| Negation `\P{…}`, `\p{^…}`, enclosing `[^\p{…}]` | ✅ | ✅ (Latin-1) | |
| `\p{…}` inside a class `[\p{L}_]` | ✅ | ✅ (Latin-1) | |
| Scripts `\p{Greek}`, `\p{Han}` | ✅ | ❌ `NotImplemented` | `UnsupportedUnicodeProperty` → `NotImplemented` |
| Script extensions `\p{scx:…}` | ✅ | ❌ `NotImplemented` | |
| Binary properties `\p{White_Space}`, `\p{Alphabetic}` | ✅ | ❌ `NotImplemented` | |
| Unknown / misspelled property name | error | ❌ `NotImplemented` | `UnknownUnicodeProperty` → `NotImplemented` |
| `\p{…}` under `(?i)` | ✅ Unicode fold | ❌ `NotImplemented` | guarded: `if (p.ci) return Error.Unsupported;` |

Evidence: `src/unicode_class.zig` `resolveLatin1Bitmap()` clamps ranges to
`0xFF`; `src/parser.zig` `readPropBitmap()` catches
`UnknownUnicodeProperty` / `UnsupportedUnicodeProperty` and maps them to
`Error.Unsupported` → `NotImplemented`. The `(?i)` guard is in `parsePropClass`.

> So `\p{L}` "works", but only as *the Latin-1 letters* (A–Z, a–z, plus the
> accented Latin-1 block) — not as Unicode `Letter`. For ASCII/Latin-1 text this
> is often enough; for anything beyond, it under-matches relative to PCRE.

---

## 3. Unicode mode flags

| Flag / option | PCRE2 | Zeetah |
|---|---|---|
| UTF mode (`(*UTF)`, `PCRE2_UTF`) / inline `(?u)` | ✅ codepoint matching | ❌ `(?u)` → `NotImplemented` |
| UCP (`PCRE2_UCP`) — Unicode props for `\w\d\s\b` | ✅ | ❌ |
| ASCII mode `(?a)` | ✅ | ❌ `NotImplemented` |
| `.unicode` compile flag | n/a (PCRE uses options) | ❌ `error.NotImplemented` (reserved) |

The reserved-but-not-implemented contract is explicit in the engine: `(?u)` and
`.unicode` parse to a dedicated unsupported path rather than being ignored, so a
pattern that *needs* Unicode fails loudly instead of silently matching as bytes.

---

## 4. When this matters (and when it doesn't)

**Doesn't matter — full parity with PCRE:**

- ASCII text and byte protocols: HTTP headers, log lines, config files,
  identifiers, numbers, hex, CSV/TSV, most structured-extraction workloads.
- Patterns whose only "Unicode" need is matching specific Latin-1 bytes.

**Does matter — Zeetah under-matches or rejects vs PCRE:**

1. `\w+`, `\b`, `\d` expected to span non-ASCII letters/digits → ASCII-only here.
2. `\p{Script}` / binary properties (`\p{Han}`, `\p{Alphabetic}`) → rejected.
3. `\p{L}` expected to mean Unicode `Letter` → only Latin-1 here.
4. `(?i)` over non-ASCII (e.g. `ß`, `İ`, `Σ`/`σ`) → ASCII fold only; `(?i)\p{…}`
   rejected.
5. Codepoint-granular `.` over UTF-8 → counts bytes, not characters.
6. `\X` grapheme clusters → unsupported.

**Workarounds today:**

- Match raw UTF-8 byte sequences explicitly when you know the encoding (e.g. the
  two bytes `\xC3\xA9` for `é` — but note Zeetah has no `\x` escape either, so
  you must use the literal bytes in the pattern string).
- Normalize/transliterate input to ASCII before matching where acceptable.
- Use `[…]` byte classes that enumerate the Latin-1 bytes you care about.
- For anything genuinely Unicode-aware, Zeetah is **not a drop-in today** — wait
  for the opt-in codepoint phase, or keep that pattern on PCRE.

---

## 5. Note for CTRE / cross-engine readers

In Zeetah's own cross-engine benchmark, CTRE is *skipped* on the
Unicode-property workloads because those patterns don't compile under it either —
so the practical gap between Zeetah and the C++ compile-time baseline on Unicode
is narrower than it first appears. The real Unicode comparison is against PCRE2,
ICU, and Rust's `regex` with Unicode **on**, where Zeetah is intentionally a
byte-mode engine.

---

## See also

- [PCRE_COMPATIBILITY.md](PCRE_COMPATIBILITY.md) — everything non-Unicode
  (escapes, classes, quantifiers, groups, anchors, Perl control constructs).
- [CTRE_TO_ZEETAH.md](CTRE_TO_ZEETAH.md) — the byte-vs-codepoint discussion from
  the CTRE migration angle (§7 there).
- [ARCHITECTURE.md](ARCHITECTURE.md) — the meta-engine routing.
