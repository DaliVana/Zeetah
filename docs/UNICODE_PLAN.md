# Unicode codepoint mode — implementation plan

Companion to [UNICODE_RESEARCH.md](UNICODE_RESEARCH.md) (what the compared
engines do and why the decisions below were taken). This document is the design
the `research` branch implements.

## 0. Contract

* **Byte mode is frozen.** Every behaviour below is reachable only through the
  `.unicode` compile flag, `PatternOptions.unicode`, or an inline `(?u)` /
  `(?u:…)` scope (`(?-u)` turns it back off). No pattern that compiles today
  changes meaning. The reserved-syntax rejections in byte mode (`\p{Script}`,
  `\x{>FF}`, `(?i)\p`) stay rejections.
* **Semantics inside `(?u)` = Rust `regex` / UTS #18 Level 1** (the natural
  codepoint-mode peer of today's "Rust/RE2 with Unicode off"), with PCRE's
  `\h \v \R` Unicode lists added because zeetah already has those escapes:
  * the match unit is one Unicode scalar value, encoded as UTF-8;
  * `.` / `\N` = any scalar except `\n` (`(?s)`: any scalar);
  * `\d` = `\p{Nd}`, `\s` = `\p{White_Space}`,
    `\w` = `\p{Alphabetic} ∪ \p{M} ∪ \p{Nd} ∪ \p{Pc} ∪ \p{Join_Control}`
    (UTS #18 Annex C), `\b` / `\B` defined from that `\w`;
  * `\p{…}`: General_Category (all UAX #44 aliases, `L&`), `Script`,
    `Script_Extensions`, the binary properties of PropList /
    DerivedCoreProperties / emoji-data, `Any` / `ASCII` / `Assigned`;
    `\P`, `\p{^…}`, `name=value`, `name:value`, `name!=value`, bare values,
    loose matching (UAX44-LM3, optional `Is` prefix);
  * `[…]`: codepoint ranges, nested classes, `&&` `--` `~~`, negation of the
    whole result, POSIX classes ASCII (RL1.2a, like Rust);
  * `(?i)`: Unicode **simple** case folding (CaseFolding.txt C+S), applied to
    literals and every class (property classes too) *before* negation;
    backreferences compare under the same folding;
  * `\xHH`, `\x{…}`, `\o{…}`, `\0oo` and the new `\N{U+hhhh}` denote
    codepoints (encoded as UTF-8); a literal non-ASCII character in the pattern
    is one codepoint;
  * invalid UTF-8 in the haystack never matches a codepoint construct and is
    never an error; `\b` treats an undecodable neighbour as non-word.
* **Out of scope (v1, documented as such):** `\X`, full case folding (ß↔ss),
  normalization, blocks (`InGreek`), `Age`, `Bidi_Class`, script runs,
  DFA-tier Unicode `\b` (runs on the bounded backtracker), `(?iu)` literal
  prefilters (such patterns route to the DFA, not Teddy).

## 1. Data: `src/unicode_tables.zig` (generated)

`tools/gen_unicode_tables.zig` grows from one input file to nine
(`DerivedGeneralCategory`, `Scripts`, `ScriptExtensions`, `PropList`,
`DerivedCoreProperties`, `emoji-data`, `CaseFolding`, `PropertyValueAliases`,
`PropertyAliases`, all Unicode 17.0.0, downloaded into the git-ignored
`tools/ucd/`). Emitted, all sorted/merged `Range{lo,hi: u21}` slices:

| Export | Content |
|---|---|
| `gc_*`, `Category`, `rangesFor` | as today |
| `Script` enum, `scriptRanges(s)`, `scxRanges(s)` | Script and Script_Extensions (scx of a codepoint defaults to its Script when `ScriptExtensions.txt` has no entry) |
| `script_names` | normalised alias → `Script` (4-letter code and long name, from `PropertyValueAliases.txt`) |
| `BinaryProp` enum, `binaryRanges(p)`, `binary_names` | every non-contributory binary property in the three source files, aliases from `PropertyAliases.txt` |
| `case_fold` | sorted `{cp, n, others[3]}`: the simple-fold **orbit** of every codepoint with a non-trivial class (CaseFolding C+S grouped by target) |
| `perl_word`, `perl_space`, `perl_digit` | the derived `\w \s \d` sets |

Size budget: ≈ 25–30 k ranges ≈ 200–250 KB `.rodata` in a binary that compiles
patterns (comparable to RE2/PCRE2; Rust ships more). Worth a build option later,
not now.

## 2. Set algebra + UTF-8 helpers: `src/unicode_set.zig`, `src/utf8.zig`

`unicode_set.zig` — allocation-free range algebra over sorted, non-overlapping,
surrogate-free `[]CodepointRange` with an explicit output buffer (`RangeBuf(cap)`
= fixed array at comptime, `ArrayListUnmanaged` at runtime, same method
surface): `normalize`, `complement`, `union`, `intersect`, `difference`,
`symmetricDifference`, `foldSimple` (walk the orbit table over each range, add
orbits, re-normalise — Rust's `case_fold_simple`), `isAscii`, `minUtf8Len` /
`maxUtf8Len`, `leadByteSet`, `contains(cp)`.

`utf8.zig` — strict `decodeAt(s, i)`, `decodeBefore(s, i)` (both reject
overlong / surrogate / > U+10FFFF / truncated), `encode`, `isWordCp`
(ASCII fast path + binary search in `perl_word`), `foldCanon(cp)` (orbit
minimum), `Utf8SeqIter` (the Thompson/Cox sequence splitter as a fixed-stack
iterator, so the NFA lowering needs no allocator — `unicode_class.toUtf8Sequences`
becomes a thin wrapper).

`unicode_class.zig` — `parseSpec` returns a `Query` (`gc(cats) | special |
script(id) | scx(id) | binary(id)`), resolved into a `RangeBuf`; the Latin-1
byte-mode path keeps its exact current behaviour and error contract
(gc-only; everything else `UnsupportedUnicodeProperty`).

## 3. IR: `.uclass` in `src/hir.zig`

A Unicode class is **one HIR node**, never a tree of byte sets:

```zig
/// Consumes one UTF-8-encoded scalar value from codepoint set `set_idx`
/// (an index into `uclasses`). Only produced under `(?u)`; an ASCII-only
/// set is emitted as a plain `.set` instead, so every byte-class fast path
/// (class_span, class_seq, Teddy, …) keeps applying.
uclass,
```

`Hir(cap)` gains a `uranges` pool (`[URANGE_CAP]CodepointRange` comptime /
growable runtime, deduplicated on insert so `\p{L}` three times costs one
copy) and `uclasses: {off, len}` descriptors; `addUClass`, `uclassRanges`,
`cloneSubtree` re-interns. Ceilings: comptime 8192 ranges / 256 classes,
runtime 2²⁰ ranges / 65535 classes (→ `TooComplex`).

Every exhaustive `switch (nd.tag)` gets a `.uclass` arm (the compiler enforces
this): `properties` (min/max len = min/max UTF-8 length, `firstBytes` = lead
bytes, `has_uclass`), `seq_extract` (never a literal), `class_span` /
`class_seq` / `dupword` / `edge_look` (not their shape), `split_alt` /
`delegate` (regular ⇒ eligible), `line_dfa` (`\n` ∈ set?), `backtrack` /
`compiled_bt` (decode-and-test), `thompson` (§4), `pattern.zig` helpers.

## 4. Lowering: UTF-8 automata with suffix sharing (`src/thompson.zig`)

`lower(.uclass)` streams the class's UTF-8 byte-range sequences (sorted, from
`Utf8SeqIter` over sorted ranges) into a port of regex-automata's
`Utf8Compiler`: a Daciuk-style incremental construction that freezes each
finished trie node into an NFA state and re-uses an identical, already-frozen
state through a bounded hash map keyed on the transition list (verified
against the builder's own edge arrays, so the map stores only
`{hash, state, first_edge, n}`). Transitions become `.consume` edges with a
range bitmap each. Result: `\p{L}` ≈ 300 NFA states instead of ≈ 3000; the
cl100k tokenizer (seven Unicode classes) fits the runtime NFA ceiling with
room; `(?u).` is the classic 9-sequence / ~15-state automaton. Both builders
(`Nfa(cap)` comptime, `RtBuilder` runtime) share one generic implementation,
exactly like `lower` today.

Downstream nothing changes: subset construction, the lazy DFA, dense search,
the PikeVM, the bounded backtracker and the one-pass capture walker are byte
machines and consume the result unchanged. The eager DFA's 256-state ceiling
will often trip on wide Unicode classes → the existing lazy-DFA fallback.

## 5. Parser: `(?u)` mode (`src/parser.zig`)

* `ParseFlags.unicode`, scoped like `ci` (`Modes` save/restore), `u` in the
  inline flag grammar; `Regex.compileWithFlags` stops rejecting `.unicode`.
* New leaf builders: `cpLeaf(cp)` (ASCII → `.set`; non-ASCII literal → concat
  of its UTF-8 bytes so literal extraction / Teddy still see bytes; under
  `(?i)` → the fold orbit as a class) and `uclassLeaf(ranges)` (ASCII-only →
  `.set`, else `.uclass`).
* Codepoint-mode atoms: literal decoding (invalid UTF-8 in the pattern →
  `Invalid`), `.`/`\N`, `\d\w\s` + negations, `\h\v` + negations, `\R`
  (adds U+2028/2029), `\p`/`\P` (full resolution; under `(?i)` folded),
  `\xHH`/`\x{}`/`\o{}`/`\0`/`\N{U+}` as codepoints, `\b`/`\B` →
  `word_boundary_unicode` / `non_word_boundary_unicode`.
* `parseUClass`: accumulate a `RangeBuf`; items = literal (decoded), range,
  escape, `\d\w\s\h\v\p` members, POSIX `[:name:]` / `[:^name:]`, nested
  `[…]`; `&&` / `--` / `~~` with Rust precedence (everything-so-far ∘ rest);
  then fold (if `(?i)`), then negate (if `[^`), then `uclassLeaf`.
* Backreferences: `HNode.ufold` — compare codepoint-wise via `foldCanon`
  (byte lengths may differ: `K` vs `K`).

## 6. Assertions: Unicode `\b` (`src/exec/charclass.zig`, `lazy_dfa.zig`)

`LookKind.word_boundary_unicode` / `non_word_boundary_unicode`; `lookHolds`
decodes the codepoint before and after `pos` and tests `isWordCp` (Rust's
`is_word_char::fwd/rev`). `lazy_dfa.lookSupported` refuses the new kinds, so
such patterns take the existing `.bt_look` route (bounded backtracker /
PikeVM), which already evaluates looks through `lookHolds`. Follow-up (not
v1): the Rust trick of letting the look-mode lazy DFA treat Unicode `\b` as
ASCII `\b` until it sees a byte ≥ 0x80, then fall back.

## 7. Comptime `Pattern` (`src/pattern.zig`, `src/exec/compiled_bt.zig`)

* `Options.unicode`; `buildAll(pattern, ci, ml, unicode)`;
  `compilesAtComptime` keeps its signature, `compilesWith(pattern, opts)` added.
* Trimmed/baked HIR copies carry `uranges` / `uclasses`.
* Routing: a `(?u)` pattern first takes the normal cascade; if the regular
  build explodes the comptime NFA ceiling (wide classes), it routes to the
  compiled backtracker arm instead of `@compileError` — the compiled
  backtracker matches `.uclass` by decode + binary search (`UClassNode`,
  `GreedyUClassLoop` with codepoint give-back, general `Loop` otherwise), so
  `Pattern("\\p{L}+", .{ .unicode = true })` works, just not as a DFA.

## 8. Tests

`tests/feat_unicode.zig` keeps every byte-mode test verbatim (frozen
contract) and adds `(?u)` suites: unit `.`, `\d\w\s\b`, properties
(gc/script/scx/binary/aliases/negation/`!=`), classes (ranges, escapes,
nesting, `&& -- ~~`, negation, POSIX), simple folding (σ/Σ/ς, k/K/Kelvin,
`(?i)\p{Lu}`, no ß→ss), codepoint escapes, `\h\v\R`, backrefs under
`(?iu)`, invalid-UTF-8 inputs, `(?u)`↔byte-mode divergence table, the
verbatim cl100k tokenizer regex (possessive + `\p`) on multibyte text,
captures/findAll/count, and comptime `Pattern(.unicode)` ⇄ runtime `Regex`
parity over all of it. Module unit tests cover the algebra, folding, the
UTF-8 compiler (membership round-trip against decode-and-test, state count
bound) and the decoders. `tests/doc_examples.zig` drops the "unicode flag is
rejected" assertion.

## 9. Docs

README feature table + Unicode footnotes, `PCRE_COMPATIBILITY_UNICODE.md`
(now a real comparison), `API.md` flags, `ADVANCED_FEATURES.md` Unicode
section, `ARCHITECTURE.md` module map / pipeline (`.uclass`, UTF-8
compiler), `root.zig` / `common.zig` / `errors.zig` comments,
`BENCHMARKS.md` tokenizer note (the greedy rewrite is no longer needed).

## 10. Order of work

1. docs (this file + research) · 2. generator + tables · 3. `unicode_set` /
`utf8` / `unicode_class` queries · 4. HIR node + thompson UTF-8 compiler +
all switch arms · 5. parser `(?u)` + runtime plumbing + `\b` · 6. comptime
path · 7. tests · 8. docs · 9. `zig build test`, tokenizer bench in both
modes, wasm32 compile check.
