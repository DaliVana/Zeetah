# zeetah.dev website

The source of [zeetah.dev](https://zeetah.dev/): an online regex tester and
builder for [Zeetah](../README.md), with the engine compiled to WebAssembly and
running entirely in the browser, plus two documentation pages: a usage guide
(`guide.html`) and an explainer of the engine (`how-it-works.html`).

- **Live matching**: highlights every match in the test string as you type,
  with the selected match's capture groups colored inside it. Click a match in
  the text or the list, or step through them with the arrows.
- **Flags**: `g` (all matches), `i`, `m`, `s`, `x`, `u` (Zeetah's Unicode
  mode: characters instead of bytes, Unicode `\w \b \p{…}`, case folding).
- **Engine insight**: shows which of Zeetah's executors the pattern was routed
  to (`literal`, `class_span`, `dfa`, `lazy_dfa`, `backtrack`, …), how long it
  took to compile and match, and a one-click `count()` benchmark over 1 MiB.
- **Explanation**: a token-by-token plain-English breakdown of the pattern,
  with syntax highlighting and a best-effort error location (Zeetah's errors
  name *what* is wrong, not *where*).
- **Replace / Split** tabs over Zeetah's `replace*` and `split`, with `$1`,
  `${name}`, `$&` templates.
- **Zig code** tab: the pattern as a runtime `Regex` and a comptime `Pattern`
  snippet, ready to paste.
- **Quick reference** (click to insert), an **Examples** menu, **Share** links
  (state in the URL hash), local persistence, light/dark theme.

## Build and run

Requires Zig **0.17.0**. The site is built from the enclosing Zeetah checkout
(`..`, a path dependency in `build.zig.zon`), so it always uses the engine in
this repository. Run the commands from `website/`:

```sh
zig build            # → zig-out/web/
zig build serve      # build, then serve zig-out/web on http://localhost:8080 (needs python3)
zig build test       # Node smoke test of the wasm ABI, binding and examples
```

`zig-out/web/index.html` also works when opened straight from disk: from
`file://` the page cannot fetch `zeetah.wasm`, so it loads the base64 copy the
build embeds in `zeetah-wasm.js` instead. Over HTTP it fetches the `.wasm`
directly (streaming compile when served as `application/wasm`).

While `serve` runs, a `zig build` in another terminal updates `zig-out/web/`
in place, so a page reload picks up the change.

Options: `-Doptimize=small` gives a smaller module (about 1.1 MB vs 1.4 MB for
the default `fast`; roughly 180 KB of either is Zeetah's Unicode property and
case-folding tables), `-Dport=9000` changes the `serve` port, and
`-Dsite-url=https://example.org/regex/` sets the public URL (see below).

## Deploy and SEO

`.github/workflows/pages.yml` builds the site and deploys it to GitHub Pages on
every push to `main` that touches `website/` or the engine; pull requests only
build and smoke-test it. One-time setup:

1. **Repository settings:** Settings → Pages → Source: *GitHub Actions*, and
   Custom domain: `zeetah.dev`. After DNS resolves, tick *Enforce HTTPS*.
2. **DNS for `zeetah.dev`** at the registrar:
   - `A` records for `zeetah.dev`: `185.199.108.153`, `185.199.109.153`,
     `185.199.110.153`, `185.199.111.153`;
   - `AAAA` records: `2606:50c0:8000::153`, `2606:50c0:8001::153`,
     `2606:50c0:8002::153`, `2606:50c0:8003::153`;
   - `CNAME` record for `www.zeetah.dev` → `dalivana.github.io` (GitHub then
     redirects `www` to the apex).
3. **Verify the domain** under your GitHub account's Settings → Pages, so no
   other repository can claim it.

`.dev` is on the HSTS preload list, so browsers only ever load it over HTTPS;
the site is unreachable until GitHub has issued its certificate.

The public URL is `-Dsite-url` (default `https://zeetah.dev/`). The build fills
it into the `%SITE_URL%` placeholders of the templates listed in `build.zig`
(canonical links, Open Graph / Twitter cards, JSON-LD, `sitemap.xml`,
`robots.txt` and `llms.txt`) and, for a custom domain, writes the `CNAME` file.
All other links are relative, so the site also works from a sub-path.

What is in place for search and AI answer engines:

- one `h1`, a unique title (under 60 characters) and description (under 160)
  per page, canonical URLs, Open Graph and Twitter cards with `og-image.jpg`;
- JSON-LD: `WebSite`, `WebApplication`, `SoftwareSourceCode` and `FAQPage` on
  the tester; `TechArticle` and `BreadcrumbList` on the docs;
- crawlable text on the tester page (an intro, "About Zeetah" and an FAQ whose
  answers match the JSON-LD), and docs written answer-first with concrete facts;
- `sitemap.xml`, a `robots.txt` that explicitly allows AI crawlers, and
  `llms.txt` (a plain-Markdown summary for language models).

After the first deploy, add `zeetah.dev` to Google Search Console and Bing
Webmaster Tools and submit `https://zeetah.dev/sitemap.xml`. Keep the benchmark
numbers in the tester FAQ and `llms.txt` in sync with the Zeetah README.

## Layout

| Path | What it is |
|---|---|
| `src/wasm.zig` | The `wasm32-freestanding` export ABI over Zeetah's public `Regex` API: `zt_compile`, `zt_exec`, `zt_replace`, `zt_split`, `zt_bench`, plus memory and result-buffer accessors. One compiled regex at a time. |
| `src/embed.zig` | Build helper that writes `zeetah-wasm.js` (the module as base64) for `file://` use. |
| `web/zeetah.js` | JS binding: `Zeetah.Engine.load()`, then `compile`, `exec`, `replace`, `split`, `bench`. All offsets are UTF-8 **byte** offsets. |
| `web/explain.js` | Tokenizer and explainer for Zeetah's syntax (highlighting, explanation panel, error hints). |
| `web/library.js` | The Examples menu; each entry lands on a different engine. |
| `web/app.js`, `index.html`, `style.css` | The tester page. |
| `web/guide.html`, `web/how-it-works.html` | Documentation pages. Their code samples compile against Zeetah 0.17.0. |
| `web/site.js` | Shared by all pages: theme toggle, Zig highlighting and copy buttons for code blocks. |
| `src/site.zig` | Build helper that fills `%SITE_URL%` in the templates. |
| `../.github/workflows/pages.yml` | Builds, tests and deploys the site to GitHub Pages. |
| `web/sitemap.xml`, `robots.txt`, `llms.txt`, `og-image.jpg` | SEO and AI-search files. |
| `test/smoke.mjs` | Node test: the ABI, the binding, every example, and the explainer's group numbering against the engine's. |

## Notes

- Zeetah is byte-oriented by default: `.` matches one byte, `\w`/`\d`/`\b` are
  ASCII. The `u` flag switches the engine to Unicode mode (`.unicode`). Match
  offsets are byte offsets into the UTF-8 text either way; the page maps them
  back to characters for highlighting.
- The module is built with `simd128`, so Zeetah's portable vector scans use
  Wasm SIMD (Chrome 91+, Firefox 89+, Safari 16.4+). Zeetah's byte-shuffle
  kernels (NEON `tbl` / SSSE3 `pshufb`) have no wasm port yet, so a few
  class shapes route to a DFA here instead of `class_span`.
- A wasm trap (an engine bug) is caught; the module is re-instantiated and the
  page keeps working.
