/* Zeetah playground UI: wires the editors, flags, result tabs, explainer and
 * quick reference to the wasm engine (zeetah.js). Classic script. */
(function () {
  'use strict';

  const { Engine, ZeetahError, encode } = window.Zeetah;
  const { parse } = window.ZeetahExplain;
  const LIB = window.ZeetahLibrary;
  const dec = new TextDecoder();

  const STORE_KEY = 'zeetah:tester';
  const FLAG_ORDER = 'gimsx';
  const EXEC_LIMIT = 100000; // matches fetched per run
  const MAX_MARKS = 5000; // matches highlighted in the test string
  const MAX_ROWS = 1000; // matches listed in the Matches tab
  const MAX_SEGMENTS = 2000;
  const BENCH_BYTES = 1 << 20;
  const STORE_TEXT_MAX = 512 * 1024;
  const SHARE_URL_MAX = 60000;

  // What each executor (`Regex.kind`) means; `budget` engines are the
  // step-budgeted backtracking tier.
  const ENGINES = {
    literal: ['Pure literal: a SIMD substring scan (Teddy / memchr), no automaton.'],
    literal_alt: ['Large literal alternation: a multi-literal trie scan.'],
    lit_prefix: ['A selective literal prefix is located with SIMD (Teddy), then a DFA confirms each candidate.'],
    reverse_suffix: ['A required literal suffix is found first, then a reverse DFA recovers where the match starts.'],
    dfa: ['Eager DFA: one table lookup per byte, linear time.'],
    lazy_dfa: ['Lazy DFA: states are built on demand because the full table would be too large. Still linear.'],
    dense_search: ['Dense DFA: a single unanchored pass over the input.'],
    class_span: ['Byte-class runs: each 64-byte block is classified into a bitmask with SIMD, then walked with count-trailing-zeros.'],
    class_seq: ['Fixed-length class sequence: Shift-And over 64-byte block bitmasks, gated by the rarest class.'],
    boundary_lits: ['Keyword set between \\b: a multi-literal scan plus an O(1) word-boundary check at both edges.'],
    dup_word: ['Adjacent duplicate word: a dedicated linear scanner.'],
    dfa_edge_look: ['A DFA for the body plus a one-byte look-assertion checked at the match edge.'],
    bt_look: ['Look-assertions (\\b, multiline ^/$, …): a bounded backtracker behind prefilters.', 'budget'],
    backtrack: ['Back-references / lookaround: a step-budgeted backtracker behind a regular "seek" prefilter.', 'budget'],
    split_alt: ['Mixed alternation: regular branches run on a DFA, the others on the backtracker.', 'budget'],
  };

  const ERRORS = {
    InvalidPattern: 'Malformed syntax.',
    NotImplemented: 'Valid regex, but not supported by Zeetah (for example \\p scripts, code points above 0xFF, an unknown POSIX class, or (?u)).',
    PatternTooComplex: 'Too large to build: a compile-time construction ceiling was exceeded.',
    MatchBudgetExceeded: 'The backtracker hit its step budget on this input. Zeetah returns this error instead of hanging.',
    OutOfMemory: 'Out of memory.',
    Internal: 'Internal engine error. Please report the pattern and input.',
    Trap: 'The engine trapped (a bug) and was restarted. Please report the pattern and input.',
  };

  // Quick reference: `before` + (selection or `ph`) + `after` is inserted.
  const REF = [
    ['Character classes', true, [
      ['.', 'any byte except newline'],
      ['\\d', 'digit 0-9'],
      ['\\D', 'not a digit'],
      ['\\w', 'word character A-Z a-z 0-9 _'],
      ['\\W', 'not a word character'],
      ['\\s', 'whitespace'],
      ['\\S', 'not whitespace'],
      ['\\h', 'horizontal whitespace'],
      ['\\v', 'vertical whitespace'],
      ['\\R', 'any line break'],
      ['\\N', 'any byte except newline'],
      ['[abc]', 'one of a, b, c', '[', ']', 'abc'],
      ['[^abc]', 'anything but a, b, c', '[^', ']', 'abc'],
      ['[a-z]', 'range a to z', '[', ']', 'a-z'],
      ['[[:alpha:]]', 'POSIX class', '[[:', ':]]', 'alpha'],
      ['\\p{L}', 'Unicode category (Latin-1)', '\\p{', '}', 'L'],
    ]],
    ['Anchors', false, [
      ['^', 'start of text (line with m)'],
      ['$', 'end of text (line with m)'],
      ['\\A', 'start of text'],
      ['\\z', 'end of text'],
      ['\\Z', 'end, before a final newline'],
      ['\\b', 'word boundary'],
      ['\\B', 'not a word boundary'],
    ]],
    ['Quantifiers', false, [
      ['*', 'zero or more'],
      ['+', 'one or more'],
      ['?', 'optional'],
      ['{n}', 'exactly n', '{', '}', '3'],
      ['{n,}', 'n or more', '{', ',}', '2'],
      ['{n,m}', 'between n and m', '{', '}', '2,5'],
      ['*?', 'lazy: as few as possible'],
      ['++', 'possessive: never give back'],
    ]],
    ['Groups', false, [
      ['(…)', 'capture group', '(', ')'],
      ['(?:…)', 'non-capturing group', '(?:', ')'],
      ['(?<name>…)', 'named capture group', '(?<name>', ')'],
      ['(?>…)', 'atomic group', '(?>', ')'],
      ['a|b', 'a or b', '|'],
      ['\\1', 'back-reference to group 1'],
      ['\\k<name>', 'named back-reference', '\\k<', '>', 'name'],
    ]],
    ['Lookaround', false, [
      ['(?=…)', 'followed by', '(?=', ')'],
      ['(?!…)', 'not followed by', '(?!', ')'],
      ['(?<=…)', 'preceded by (fixed width)', '(?<=', ')'],
      ['(?<!…)', 'not preceded by (fixed width)', '(?<!', ')'],
    ]],
    ['Escapes', false, [
      ['\\.', 'a literal dot'],
      ['\\\\', 'a literal backslash'],
      ['\\n', 'newline'],
      ['\\t', 'tab'],
      ['\\r', 'carriage return'],
      ['\\xHH', 'byte by hex value', '\\x', '', '41'],
      ['\\x{HH}', 'byte, braced form', '\\x{', '}', '41'],
      ['\\0', 'NUL byte'],
    ]],
    ['Inline flags', false, [
      ['(?i)', 'case-insensitive from here'],
      ['(?m)', 'multiline from here'],
      ['(?s)', 'dot matches newline from here'],
      ['(?x)', 'extended (ignore whitespace)'],
      ['(?i:…)', 'case-insensitive inside only', '(?i:', ')'],
    ]],
  ];

  // --- DOM ------------------------------------------------------------------------------

  const $ = (id) => document.getElementById(id);
  const el = {
    version: $('version'),
    libBtn: $('libBtn'),
    libMenu: $('libMenu'),
    shareBtn: $('shareBtn'),
    pattern: $('pattern'),
    patternHl: $('patternHl'),
    flagText: $('flagText'),
    flags: [...document.querySelectorAll('.flag')],
    status: $('status'),
    textMeta: $('textMeta'),
    count: $('count'),
    prevBtn: $('prevBtn'),
    nextBtn: $('nextBtn'),
    clearBtn: $('clearBtn'),
    subjectWrap: $('subjectWrap'),
    subject: $('subject'),
    subjectHl: $('subjectHl'),
    execInfo: $('execInfo'),
    benchScale: $('benchScale'),
    benchBtn: $('benchBtn'),
    benchOut: $('benchOut'),
    tabs: [...document.querySelectorAll('[role="tab"]')],
    matches: $('matches'),
    template: $('template'),
    literal: $('literal'),
    replaceMeta: $('replaceMeta'),
    replaceOut: $('replaceOut'),
    copyReplace: $('copyReplace'),
    splitOut: $('splitOut'),
    codeOut: $('codeOut'),
    copyCode: $('copyCode'),
    engineNote: $('engineNote'),
    explain: $('explain'),
    ref: $('ref'),
    toast: $('toast'),
  };

  // --- state ------------------------------------------------------------------------------

  const state = initialState();
  let engine = null;
  let loadError = null;
  let ex = parse('', ''); // explainer output for the current pattern
  let compiled = null; // { info, ms } | { error } | null (no pattern)
  let run = null; // { matches, truncated, ms } | { error } | null
  let sel = -1;
  let text = indexText(state.text);

  function initialState() {
    const d = LIB.defaultEntry;
    const base = { pattern: d.pattern, flags: d.flags, text: d.text, template: d.template || '', literal: false, tab: 'matches' };
    const fromHash = readHash();
    if (fromHash) return { ...base, ...fromHash };
    try {
      const saved = JSON.parse(localStorage.getItem(STORE_KEY) || 'null');
      if (saved && typeof saved.pattern === 'string') return { ...base, ...saved };
    } catch (_) {}
    return base;
  }

  let saveTimer = 0;
  function save() {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => {
      const s = { ...state };
      if (s.text.length > STORE_TEXT_MAX) delete s.text;
      try {
        localStorage.setItem(STORE_KEY, JSON.stringify(s));
      } catch (_) {}
    }, 300);
  }

  // --- helpers ------------------------------------------------------------------------------

  const escHtml = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
  const fmtNum = (n) => n.toLocaleString('en-US');
  const hasG = () => state.flags.includes('g');
  const engineFlags = () => state.flags.replace('g', '');
  const groupClass = (k) => 'g' + (((k - 1) % 6) + 1);

  function fmtDur(ns) {
    if (ns < 999.5) return ns.toFixed(0) + ' ns';
    if (ns < 999.5e3) return (ns / 1e3).toFixed(ns < 9.995e3 ? 2 : ns < 99.95e3 ? 1 : 0) + ' µs';
    if (ns < 999.5e6) return (ns / 1e6).toFixed(ns < 9.995e6 ? 2 : 1) + ' ms';
    return (ns / 1e9).toFixed(2) + ' s';
  }
  const fmtMs = (ms) => fmtDur(ms * 1e6);
  const fmtRate = (mbs) => (mbs >= 1000 ? (mbs / 1000).toFixed(2) + ' GB/s' : mbs.toFixed(mbs < 10 ? 2 : 0) + ' MB/s');
  function fmtBytes(n) {
    if (n < 1024) return n + ' B';
    if (n < 1 << 20) return (n / 1024).toFixed(1) + ' KiB';
    return (n / (1 << 20)).toFixed(2) + ' MiB';
  }

  /** Run fn once for its result. Unless that already took a while, repeat it
   *  briefly and report the warm average: the first call pays wasm tier-up,
   *  and the browser clock is too coarse for a single microsecond call. */
  function timeIt(fn) {
    const t0 = performance.now();
    const result = fn();
    const first = performance.now() - t0;
    if (first > 20) return { result, ms: first };
    let reps = 0;
    let el = 0;
    const t1 = performance.now();
    do {
      fn();
      reps++;
      el = performance.now() - t1;
    } while (el < 3 && reps < 400);
    return { result, ms: el / reps };
  }

  /** UTF-8 bytes of the test string plus a byte → UTF-16 index map (the
   *  engine reports byte offsets; the textarea works in UTF-16). */
  function indexText(str) {
    const bytes = encode(str);
    if (bytes.length === str.length) return { str, bytes, ascii: true };
    const b2u = new Uint32Array(bytes.length + 1);
    let b = 0;
    for (let u = 0; u < str.length; ) {
      const cp = str.codePointAt(u);
      const units = cp > 0xffff ? 2 : 1;
      const n = cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4; // lone surrogates encode as U+FFFD (3 bytes)
      b2u.fill(u, b, b + n);
      b += n;
      u += units;
    }
    b2u[b] = str.length;
    return { str, bytes, ascii: false, b2u };
  }
  const isCont = (t, b) => b > 0 && b < t.bytes.length && (t.bytes[b] & 0xc0) === 0x80;
  const uStart = (t, b) => (t.ascii ? b : t.b2u[b]);
  function uEnd(t, b) {
    if (t.ascii) return b;
    while (isCont(t, b)) b++;
    return t.b2u[b];
  }

  /** Display a byte range of the test string: decoded, with visible
   *  newlines/tabs, truncated when long. */
  function showVal(s, e) {
    if (e <= s) return '<span class="empty-val">empty</span>';
    const limit = 400;
    let str = dec.decode(text.bytes.subarray(s, Math.min(e, s + limit * 4)));
    let cut = false;
    if (str.length > limit || e - s > limit * 4) {
      str = str.slice(0, limit);
      cut = true;
    }
    let html = escHtml(str)
      .replace(/\n/g, '<span class="ws">↵</span>')
      .replace(/\t/g, '<span class="ws">→</span>')
      .replace(/\r/g, '<span class="ws">␍</span>');
    if (cut) html += '<span class="ws">…</span>';
    return html;
  }

  let toastTimer = 0;
  function toast(msg) {
    el.toast.textContent = msg;
    el.toast.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.toast.classList.remove('show'), 2200);
  }

  async function copyText(s) {
    try {
      await navigator.clipboard.writeText(s);
      return true;
    } catch (_) {
      const ta = document.createElement('textarea');
      ta.value = s;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      let ok = false;
      try {
        ok = document.execCommand('copy');
      } catch (_) {}
      ta.remove();
      return ok;
    }
  }

  function autoGrow(ta) {
    ta.style.height = 'auto';
    ta.style.height = ta.scrollHeight + 'px';
  }

  const timers = {};
  function later(key, ms, fn) {
    clearTimeout(timers[key]);
    timers[key] = setTimeout(fn, ms);
  }

  // --- share links ----------------------------------------------------------------------------

  function toB64url(str) {
    const bytes = encode(str);
    let bin = '';
    for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }

  function fromB64url(s) {
    s = s.replace(/-/g, '+').replace(/_/g, '/');
    while (s.length % 4) s += '=';
    const bin = atob(s);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return dec.decode(bytes);
  }

  function readHash() {
    const m = /^#s=([A-Za-z0-9_-]+)$/.exec(location.hash);
    if (!m) return null;
    try {
      const o = JSON.parse(fromB64url(m[1]));
      const out = {};
      if (typeof o.p === 'string') out.pattern = o.p;
      if (typeof o.f === 'string') out.flags = [...FLAG_ORDER].filter((f) => o.f.includes(f)).join('');
      if (typeof o.t === 'string') out.text = o.t;
      if (typeof o.r === 'string') out.template = o.r;
      if (o.l) out.literal = true;
      return out;
    } catch (_) {
      return null;
    }
  }

  async function share() {
    const base = location.href.split('#')[0];
    const payload = { p: state.pattern, f: state.flags, t: state.text, r: state.template || undefined, l: state.literal ? 1 : undefined };
    let url = base + '#s=' + toB64url(JSON.stringify(payload));
    let note = 'Link copied';
    if (url.length > SHARE_URL_MAX) {
      delete payload.t;
      url = base + '#s=' + toB64url(JSON.stringify(payload));
      note = 'Link copied (the test string is too long to include)';
    }
    if (location.protocol === 'file:') note += '. Note: a file:// link only works on this machine';
    toast((await copyText(url)) ? note : 'Could not copy the link');
  }

  // --- compile + run -----------------------------------------------------------------------------

  function compileNow() {
    ex = parse(state.pattern, state.flags);
    if (!state.pattern) compiled = null;
    else if (!engine) compiled = loadError ? { error: loadError } : null;
    else {
      try {
        const { result, ms } = timeIt(() => engine.compile(state.pattern, engineFlags()));
        compiled = { info: result, ms };
      } catch (e) {
        compiled = { error: e };
        onTrap(e);
      }
    }
    renderPattern();
    renderExplain();
    renderStatus();
    renderCode();
    runNow();
  }

  function runNow() {
    run = null;
    if (compiled && compiled.info) {
      try {
        const { result, ms } = timeIt(() => engine.exec(text.bytes, { global: hasG(), limit: EXEC_LIMIT }));
        for (const m of result.matches) {
          m.us = uStart(text, m.start);
          m.ue = uEnd(text, m.end);
        }
        run = { ...result, ms };
      } catch (e) {
        run = { error: e };
        onTrap(e);
      }
    }
    const n = run && run.matches ? run.matches.length : 0;
    if (sel >= n) sel = n - 1;
    if (sel < 0 && n) sel = 0;
    renderSubject();
    renderCount();
    renderMatches();
    renderActiveTab();
  }

  function onTrap(e) {
    if (e instanceof ZeetahError && e.code === 'Trap' && engine) {
      engine.reset().then(() => toast('The engine trapped and was restarted'));
    }
  }

  // --- rendering: pattern, status, explanation ------------------------------------------------

  function refGroup(ref) {
    if (ref === undefined) return 0;
    if (/^\d+$/.test(ref)) return +ref <= ex.groups.length ? +ref : 0;
    const g = ex.groups.find((x) => x.name === ref);
    return g ? g.index : 0;
  }

  function tokenClass(t, showErrors) {
    if (t.type === 'error' && !showErrors) return 't-literal';
    let cls = 't-' + t.type;
    const g = t.type === 'backref' ? refGroup(t.ref) : t.group;
    if (g && (t.type === 'open' || t.type === 'close' || t.type === 'backref')) cls += ' cap ' + groupClass(g);
    return cls;
  }

  function renderPattern() {
    const p = state.pattern;
    const showErrors = !!(compiled && compiled.error);
    let html = '';
    let pos = 0;
    ex.tokens.forEach((t, i) => {
      if (t.start > pos) html += escHtml(p.slice(pos, t.start));
      html += `<span class="${tokenClass(t, showErrors)}" data-t="${i}">${escHtml(p.slice(t.start, t.end))}</span>`;
      pos = t.end;
    });
    el.patternHl.innerHTML = html + escHtml(p.slice(pos)) + '​';
    el.flagText.textContent = state.flags;
    for (const b of el.flags) b.setAttribute('aria-pressed', String(state.flags.includes(b.dataset.flag)));
  }

  function renderStatus() {
    if (!state.pattern) {
      el.status.innerHTML = '<span class="idle">Type a pattern, or pick one from Examples.</span>';
      return;
    }
    if (!compiled) {
      el.status.innerHTML = '<span class="idle">Loading the engine…</span>';
      return;
    }
    if (compiled.error) {
      const e = compiled.error;
      const code = e.code || 'Error';
      let hint = '';
      if (ex.error) hint = `Likely cause, at position ${ex.error.start + 1}: ${escHtml(ex.error.desc)}.`;
      el.status.innerHTML = `<div class="err-box"><span class="err-name">${escHtml(code)}</span>${escHtml(ERRORS[code] || e.message || '')}${hint ? `<span class="err-hint">${hint}</span>` : ''}</div>`;
      return;
    }
    const info = compiled.info;
    const [desc, tier] = ENGINES[info.engine] || ['', ''];
    const ng = info.groups.length;
    el.status.innerHTML =
      `<span class="engine-chip${tier === 'budget' ? ' bt' : ''}" title="${escHtml(desc)}">${escHtml(info.engine)}</span>` +
      `<span class="stat"><b>${ng}</b> ${ng === 1 ? 'group' : 'groups'}</span>` +
      `<span class="stat">compiled in <b>${fmtMs(compiled.ms)}</b></span>`;
  }

  function renderExplain() {
    if (!state.pattern) {
      el.engineNote.innerHTML = 'Each token of your pattern is explained here as you type.';
      el.explain.innerHTML = '';
      return;
    }
    if (compiled && compiled.info) {
      const [desc, tier] = ENGINES[compiled.info.engine] || ['An internal engine.', ''];
      el.engineNote.innerHTML =
        `Zeetah runs this pattern on <b><code>${escHtml(compiled.info.engine)}</code></b>. ${escHtml(desc)}` +
        (tier === 'budget' ? ' Step-budgeted: an adversarial input returns MatchBudgetExceeded instead of hanging.' : ' Linear in the input size.');
    } else if (compiled && compiled.error) {
      el.engineNote.innerHTML = `The engine rejected this pattern with <b><code>${escHtml(compiled.error.code || 'Error')}</code></b>.`;
    } else {
      el.engineNote.textContent = 'Loading the engine…';
    }
    const showErrors = !!(compiled && compiled.error);
    const p = state.pattern;
    let html = '';
    ex.tokens.forEach((t, i) => {
      if (t.type === 'ws' || t.type === 'close') return;
      if (t.type === 'error' && !showErrors) return;
      const desc = t.desc ? t.desc[0].toUpperCase() + t.desc.slice(1) : '';
      const depth = t.depth ? ` style="--depth: ${t.depth}"` : '';
      html += `<li data-t="${i}"${depth}${t.type === 'error' ? ' class="err"' : ''}>` +
        `<code class="tok ${tokenClass(t, showErrors)}">${escHtml(p.slice(t.start, t.end))}</code>` +
        `<span class="desc">${escHtml(desc)}</span></li>`;
    });
    el.explain.innerHTML = html;
  }

  // --- rendering: test string ---------------------------------------------------------------------

  function groupSegments(m) {
    const s = text.str;
    const a = m.us;
    const b = m.ue;
    const gs = [];
    m.groups.forEach((g, k) => {
      if (!g) return;
      const gs0 = Math.max(a, uStart(text, g[0]));
      const ge0 = Math.min(b, uEnd(text, g[1]));
      if (ge0 > gs0) gs.push({ k: k + 1, s: gs0, e: ge0 });
    });
    if (!gs.length) return escHtml(s.slice(a, b));
    const xs = [...new Set([a, b, ...gs.flatMap((g) => [g.s, g.e])])].sort((x, y) => x - y);
    let html = '';
    for (let j = 0; j + 1 < xs.length; j++) {
      const x = xs[j];
      const y = xs[j + 1];
      let best = null; // innermost covering group: latest start, then highest index
      for (const g of gs) if (g.s <= x && g.e >= y && (!best || g.s > best.s || (g.s === best.s && g.k > best.k))) best = g;
      const seg = escHtml(s.slice(x, y));
      html += best ? `<span class="g ${groupClass(best.k)}">${seg}</span>` : seg;
    }
    return html;
  }

  function renderSubject() {
    const s = text.str;
    const ms = run && run.matches ? run.matches : [];
    let html = '';
    let pos = 0;
    const n = Math.min(ms.length, MAX_MARKS);
    for (let i = 0; i < n; i++) {
      const m = ms[i];
      if (m.us < pos) continue;
      html += escHtml(s.slice(pos, m.us));
      const cls = (i % 2 ? 'alt' : '') + (i === sel ? ' sel' : '');
      if (m.ue === m.us) html += `<mark class="zw${i === sel ? ' sel' : ''}" data-i="${i}"></mark>`;
      else html += `<mark class="${cls}" data-i="${i}">${i === sel && m.groups.length ? groupSegments(m) : escHtml(s.slice(m.us, m.ue))}</mark>`;
      pos = m.ue;
    }
    el.subjectHl.innerHTML = html + escHtml(s.slice(pos)) + '​';
  }

  function renderCount() {
    const b = text.bytes.length;
    el.textMeta.textContent = text.ascii ? fmtNum(b) + ' bytes' : `${fmtNum(text.str.length)} chars · ${fmtNum(b)} bytes`;
    const n = run && run.matches ? run.matches.length : 0;
    el.count.className = 'count';
    if (!run) el.count.textContent = '';
    else if (run.error) {
      el.count.textContent = run.error.code || 'error';
      el.count.classList.add('none');
    } else if (!n) {
      el.count.textContent = 'no match';
      el.count.classList.add('none');
    } else {
      el.count.classList.add('has');
      const total = run.truncated ? fmtNum(n) + '+' : fmtNum(n);
      el.count.textContent = (sel >= 0 ? `${fmtNum(sel + 1)} / ` : '') + total + (n === 1 && !run.truncated ? ' match' : ' matches') + (hasG() ? '' : ' (first)');
    }
    el.prevBtn.disabled = el.nextBtn.disabled = n < 2;
    el.execInfo.innerHTML = run && run.matches ? `matched in <b>${fmtMs(run.ms)}</b> over ${fmtBytes(b)}` : '';
    const badge = document.querySelector('#tab-matches .badge');
    if (badge) badge.textContent = run && run.matches ? (run.truncated ? fmtNum(n) + '+' : fmtNum(n)) : '0';
  }

  function scrollToMark(i) {
    const mark = el.subjectHl.querySelector(`mark[data-i="${i}"]`);
    if (!mark) return;
    const w = el.subjectWrap;
    const top = mark.offsetTop;
    if (top < w.scrollTop + 8 || top + mark.offsetHeight > w.scrollTop + w.clientHeight - 8) {
      w.scrollTop = Math.max(0, top - w.clientHeight / 3);
    }
  }

  function setSel(i, { list = true, mark = true } = {}) {
    const n = run && run.matches ? run.matches.length : 0;
    if (!n) return;
    sel = ((i % n) + n) % n;
    renderSubject();
    renderCount();
    for (const row of el.matches.querySelectorAll('.match.sel')) row.classList.remove('sel');
    const row = el.matches.querySelector(`.match[data-i="${sel}"]`);
    if (row) {
      row.classList.add('sel');
      if (list) row.scrollIntoView({ block: 'nearest' });
    }
    if (mark) scrollToMark(sel);
  }

  function matchAtCaret(c) {
    const ms = run && run.matches ? run.matches : [];
    let lo = 0;
    let hi = ms.length - 1;
    let best = -1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (ms[mid].us <= c) {
        best = mid;
        lo = mid + 1;
      } else hi = mid - 1;
    }
    if (best < 0) return -1;
    const m = ms[best];
    return c < m.ue || (m.us === m.ue && c === m.us) ? best : -1;
  }

  // --- rendering: result tabs -----------------------------------------------------------------------

  function placeholder(msg, error) {
    return `<div class="placeholder${error ? ' error' : ''}">${msg}</div>`;
  }

  function renderMatches() {
    if (!state.pattern) return void (el.matches.innerHTML = placeholder('Matches appear here as you type.'));
    if (!compiled || !compiled.info) return void (el.matches.innerHTML = placeholder(compiled ? 'Fix the pattern to see matches.' : 'Loading the engine…'));
    if (!run || run.error) {
      const code = run && run.error ? run.error.code || 'Error' : 'Error';
      return void (el.matches.innerHTML = placeholder(`<b>${escHtml(code)}</b>: ${escHtml(ERRORS[code] || '')}`, true));
    }
    const ms = run.matches;
    if (!ms.length) return void (el.matches.innerHTML = placeholder('No match.'));
    const groups = compiled.info.groups;
    const rows = [];
    const n = Math.min(ms.length, MAX_ROWS);
    for (let i = 0; i < n; i++) {
      const m = ms[i];
      let g = '';
      if (groups.length) {
        g = '<div class="groups">';
        groups.forEach((gr, k) => {
          const span = m.groups[k];
          g += `<span class="gname ${groupClass(gr.index)}">${gr.name ? escHtml(gr.name) : '$' + gr.index}</span>` +
            `<span class="gspan">${span ? span[0] + '–' + span[1] : ''}</span>` +
            `<span class="val">${span ? showVal(span[0], span[1]) : '<span class="empty-val">did not participate</span>'}</span>`;
        });
        g += '</div>';
      }
      rows.push(
        `<div class="match${i === sel ? ' sel' : ''}" data-i="${i}">` +
          `<div class="match-head"><span class="idx">${i + 1}</span><span class="span" title="byte offsets [start, end)">${m.start}–${m.end}</span>` +
          `<span class="val">${showVal(m.start, m.end)}</span></div>${g}</div>`,
      );
    }
    if (ms.length > n || run.truncated) {
      rows.push(`<div class="more">Showing the first ${fmtNum(n)} of ${fmtNum(ms.length)}${run.truncated ? '+' : ''} matches.</div>`);
    }
    el.matches.innerHTML = rows.join('');
  }

  function renderReplace() {
    if (!compiled || !compiled.info) {
      el.replaceMeta.textContent = 'Result';
      el.replaceOut.textContent = '';
      return;
    }
    try {
      const { result, ms } = timeIt(() => engine.replace(text.bytes, state.template, { global: hasG(), literal: state.literal }));
      const n = run && run.matches ? run.matches.length : 0;
      el.replaceMeta.textContent = `Result · ${hasG() ? fmtNum(n) + (run && run.truncated ? '+' : '') : Math.min(n, 1)} replaced in ${fmtMs(ms)} (${state.literal ? '' : 'template, '}${hasG() ? 'replaceAll' : 'replace'}${state.literal ? 'Literal' : ''})`;
      el.replaceOut.textContent = result;
    } catch (e) {
      el.replaceMeta.textContent = 'Result';
      el.replaceOut.textContent = (e.code || 'Error') + ': ' + (ERRORS[e.code] || e.message);
      onTrap(e);
    }
  }

  function renderSplit() {
    if (!compiled || !compiled.info) return void (el.splitOut.innerHTML = placeholder('Fix the pattern to split the text.'));
    try {
      const segs = engine.split(text.bytes);
      const n = Math.min(segs.length, MAX_SEGMENTS);
      let html = `<div class="more">Regex.split: ${fmtNum(segs.length)} ${segs.length === 1 ? 'segment' : 'segments'}. Splits on every non-empty match (the g flag does not apply).</div>`;
      for (let i = 0; i < n; i++) {
        const [s, e] = segs[i];
        html += `<div class="seg"><span class="idx">${i + 1}</span><span class="span">${s}–${e}</span><span class="val">${showVal(s, e)}</span></div>`;
      }
      if (segs.length > n) html += `<div class="more">Showing the first ${fmtNum(n)}.</div>`;
      el.splitOut.innerHTML = html;
    } catch (e) {
      el.splitOut.innerHTML = placeholder(escHtml((e.code || 'Error') + ': ' + (ERRORS[e.code] || e.message)), true);
      onTrap(e);
    }
  }

  function zigString(s) {
    let o = '"';
    for (const ch of s) {
      const c = ch.codePointAt(0);
      if (ch === '\\') o += '\\\\';
      else if (ch === '"') o += '\\"';
      else if (ch === '\n') o += '\\n';
      else if (ch === '\r') o += '\\r';
      else if (ch === '\t') o += '\\t';
      else if (c < 0x20 || c === 0x7f) o += '\\x' + c.toString(16).padStart(2, '0');
      else o += ch;
    }
    return o + '"';
  }

  function buildCode() {
    const p = state.pattern;
    if (!p) return '// Type a pattern first.';
    const f = engineFlags();
    const fields = [];
    if (f.includes('i')) fields.push('.case_insensitive = true');
    if (f.includes('m')) fields.push('.multiline = true');
    if (f.includes('s')) fields.push('.dot_all = true');
    if (f.includes('x')) fields.push('.extended = true');
    const groups = compiled && compiled.info ? compiled.info.groups : ex.groups;
    const lit = zigString(p);
    const L = [];
    L.push('const std = @import("std");', 'const zeetah = @import("zeetah");', '');
    if (compiled && compiled.error) L.push(`// Note: this pattern does not compile (${compiled.error.code}).`, '');
    L.push('// Runtime: compiled when the program runs.');
    L.push('fn example(allocator: std.mem.Allocator, input: []const u8) !void {');
    L.push(fields.length
      ? `    var re = try zeetah.Regex.compileWithFlags(allocator, ${lit}, .{ ${fields.join(', ')} });`
      : `    var re = try zeetah.Regex.compile(allocator, ${lit});`);
    L.push('    defer re.deinit();', '');
    const show = '        std.debug.print("{d}..{d} {s}\\n", .{ m.start, m.end, m.slice });';
    const groupLines = (indent) => groups.slice(0, 4).map((g) =>
      g.name
        ? `${indent}if (m.groupByName(${zigString(g.name)})) |g| std.debug.print("  ${g.name} = {s}\\n", .{g.slice});`
        : `${indent}if (m.groups[${g.index}]) |g| std.debug.print("  $${g.index} = {s}\\n", .{g.slice});`);
    if (hasG()) {
      if (groups.length) {
        L.push('    var it = re.capturesIterator(input);', '    while (try it.next(allocator)) |found| {', '        var m = found;', '        defer m.deinit(allocator);', show, ...groupLines('        '), '    }');
      } else {
        L.push('    var it = re.iterator(input);', '    while (try it.next(allocator)) |m| {', show, '    }');
      }
    } else if (groups.length) {
      L.push('    if (try re.captures(allocator, input)) |found| {', '        var m = found;', '        defer m.deinit(allocator);', show, ...groupLines('        '), '    }');
    } else {
      L.push('    if (try re.find(input)) |m| {', show, '    }');
    }
    if (state.template) {
      const fn = (hasG() ? 'replaceAll' : 'replace') + (state.literal ? 'Literal' : '');
      L.push('', `    const replaced = try re.${fn}(allocator, input, ${zigString(state.template)});`, '    defer allocator.free(replaced);');
    }
    L.push('}', '');
    // Comptime: PatternOptions has case_insensitive and multiline; s/x go inline.
    let cp = p;
    if (f.includes('x')) cp = '(?x)' + cp;
    if (f.includes('s')) cp = '(?s)' + cp;
    const opts = [];
    if (f.includes('i')) opts.push('.case_insensitive = true');
    if (f.includes('m')) opts.push('.multiline = true');
    L.push('// Comptime: compiled while your program builds; allocation-free at runtime.');
    L.push('// A pattern past a comptime construction limit is a compile error; use Regex then.');
    L.push(`const P = zeetah.Pattern(${zigString(cp)}, .{${opts.length ? ' ' + opts.join(', ') + ' ' : ''}});`, '');
    L.push('fn exampleComptime(input: []const u8) void {');
    if (hasG()) L.push('    var it = P.iterator(input);', '    while (it.next()) |m| {', show, '    }');
    else L.push('    if (P.find(input)) |m| {', show, '    }');
    L.push('}');
    return L.join('\n');
  }

  function renderCode() {
    if (state.tab !== 'code') return;
    el.codeOut.innerHTML = window.ZeetahSite.highlightZig(buildCode());
  }

  function renderActiveTab() {
    if (state.tab === 'replace') renderReplace();
    else if (state.tab === 'split') renderSplit();
    else if (state.tab === 'code') renderCode();
  }

  function selectTab(name) {
    state.tab = name;
    for (const t of el.tabs) {
      const on = t.dataset.tab === name;
      t.setAttribute('aria-selected', String(on));
      t.tabIndex = on ? 0 : -1;
      document.getElementById('panel-' + t.dataset.tab).hidden = !on;
    }
    renderActiveTab();
    save();
  }

  // --- benchmark --------------------------------------------------------------------------------------

  function benchInput() {
    const b = text.bytes;
    if (!el.benchScale.checked || !b.length || b.length >= BENCH_BYTES) return b;
    // Repeat with a newline between copies so matches cannot straddle them.
    const reps = Math.ceil(BENCH_BYTES / (b.length + 1));
    const out = new Uint8Array(reps * (b.length + 1));
    for (let r = 0; r < reps; r++) {
      out.set(b, r * (b.length + 1));
      out[r * (b.length + 1) + b.length] = 10;
    }
    return out;
  }

  function runBench() {
    if (!compiled || !compiled.info) return toast('Fix the pattern first');
    el.benchBtn.disabled = true;
    el.benchOut.hidden = false;
    el.benchOut.innerHTML = '<span class="lbl">Running count() …</span>';
    setTimeout(() => {
      try {
        const input = benchInput();
        const r = engine.bench(input, 400);
        el.benchOut.innerHTML =
          `<div class="metric"><span class="big">${fmtRate(r.mbPerSec)}</span><span class="lbl">throughput</span></div>` +
          `<div class="metric"><span class="big">${fmtDur(r.nsPerOp)}</span><span class="lbl">per count() over ${fmtBytes(input.length)}</span></div>` +
          `<div class="metric"><span class="big">${fmtNum(r.count)}</span><span class="lbl">matches per pass</span></div>` +
          `<span class="note">${fmtNum(r.iters)} timed passes of Regex.count on <code>${escHtml(compiled.info.engine)}</code> in this browser (wasm32 + SIMD128). Native builds are typically several times faster.</span>`;
      } catch (e) {
        el.benchOut.innerHTML = `<span class="lbl">${escHtml((e.code || 'Error') + ': ' + (ERRORS[e.code] || e.message))}</span>`;
        onTrap(e);
      } finally {
        el.benchBtn.disabled = false;
      }
    }, 30);
  }

  // --- examples menu + quick reference --------------------------------------------------------------

  function buildLibrary() {
    const items = LIB.entries.map((e, i) => {
      let eng = '';
      if (engine) {
        try {
          eng = engine.compile(e.pattern, e.flags.replace('g', '')).engine;
        } catch (_) {
          eng = 'error';
        }
      }
      return `<button type="button" role="menuitem" data-i="${i}"><span class="m-top"><span>${escHtml(e.name)}</span><span class="m-engine">${escHtml(eng)}</span></span><span class="m-pat">/${escHtml(e.pattern.replace(/\n/g, ' '))}/${escHtml(e.flags)}</span></button>`;
    });
    el.libMenu.innerHTML = items.join('');
  }

  function openMenu(open) {
    el.libMenu.hidden = !open;
    el.libBtn.setAttribute('aria-expanded', String(open));
    if (open) {
      const first = el.libMenu.querySelector('button');
      if (first) first.focus();
    }
  }

  function applyEntry(e) {
    state.pattern = e.pattern;
    state.flags = e.flags;
    state.text = e.text;
    state.template = e.template || '';
    state.literal = false;
    sel = 0;
    syncInputs();
    text = indexText(state.text);
    compileNow();
    save();
  }

  function buildRef() {
    el.ref.innerHTML = REF.map(([title, open, items], ci) =>
      `<details${open ? ' open' : ''}><summary>${escHtml(title)}</summary><div class="ref-list">` +
      items.map((it, ii) => `<button type="button" class="ref-item" data-c="${ci}" data-i="${ii}"><code>${escHtml(it[0])}</code><span>${escHtml(it[1])}</span></button>`).join('') +
      '</div></details>').join('');
  }

  function insertRef(item) {
    const [code, , before = code, after = '', ph = ''] = item;
    const ta = el.pattern;
    ta.focus();
    const s = ta.selectionStart;
    const e = ta.selectionEnd;
    const mid = ta.value.slice(s, e) || ph;
    const ins = before + mid + after;
    // execCommand keeps the native undo stack; setRangeText is the fallback.
    let ok = false;
    try {
      ok = document.execCommand('insertText', false, ins);
    } catch (_) {}
    if (!ok) {
      ta.setRangeText(ins, s, e, 'end');
      onPatternInput();
    }
    const a = s + before.length;
    if (mid) ta.setSelectionRange(a, a + mid.length);
    else ta.setSelectionRange(a, a);
  }

  // --- input wiring ------------------------------------------------------------------------------------

  function syncInputs() {
    el.pattern.value = state.pattern;
    el.subject.value = state.text;
    el.template.value = state.template;
    el.literal.checked = state.literal;
    autoGrow(el.pattern);
    autoGrow(el.subject);
  }

  function onPatternInput() {
    state.pattern = el.pattern.value;
    autoGrow(el.pattern);
    // The textarea's own text is transparent: repaint the highlight layer now,
    // compile (which may take a few ms) just after.
    ex = parse(state.pattern, state.flags);
    renderPattern();
    later('compile', 40, compileNow);
    save();
  }

  function wire() {
    el.pattern.addEventListener('input', onPatternInput);
    el.pattern.addEventListener('keydown', (e) => {
      // A newline only makes sense in extended mode; otherwise Enter is a no-op.
      if (e.key === 'Enter' && !e.shiftKey && !state.flags.includes('x')) e.preventDefault();
    });

    el.subject.addEventListener('input', () => {
      state.text = el.subject.value;
      autoGrow(el.subject);
      save();
      const go = () => {
        text = indexText(state.text);
        runNow();
      };
      // Small inputs re-run on every keystroke so the marks never lag the
      // text; large ones show plain text until typing pauses.
      if (state.text.length < 50000) return go();
      el.subjectHl.textContent = state.text + '​';
      later('run', 160, go);
    });
    el.subject.addEventListener('click', () => {
      if (el.subject.selectionStart !== el.subject.selectionEnd) return;
      const i = matchAtCaret(el.subject.selectionStart);
      if (i >= 0 && i !== sel) setSel(i, { mark: false });
    });

    for (const b of el.flags) {
      b.addEventListener('click', () => {
        const f = b.dataset.flag;
        const on = state.flags.includes(f) ? state.flags.replace(f, '') : state.flags + f;
        state.flags = [...FLAG_ORDER].filter((x) => on.includes(x)).join('');
        compileNow();
        save();
      });
    }

    el.prevBtn.addEventListener('click', () => setSel(sel - 1));
    el.nextBtn.addEventListener('click', () => setSel(sel + 1));
    el.clearBtn.addEventListener('click', () => {
      state.text = '';
      el.subject.value = '';
      autoGrow(el.subject);
      text = indexText('');
      runNow();
      save();
      el.subject.focus();
    });

    el.matches.addEventListener('click', (e) => {
      const row = e.target.closest('.match');
      if (row) setSel(+row.dataset.i, { list: false });
    });

    for (const t of el.tabs) {
      t.addEventListener('click', () => selectTab(t.dataset.tab));
      t.addEventListener('keydown', (e) => {
        if (e.key !== 'ArrowRight' && e.key !== 'ArrowLeft') return;
        const i = el.tabs.indexOf(t) + (e.key === 'ArrowRight' ? 1 : -1);
        const next = el.tabs[(i + el.tabs.length) % el.tabs.length];
        next.focus();
        selectTab(next.dataset.tab);
      });
    }

    el.template.addEventListener('input', () => {
      state.template = el.template.value;
      later('replace', 40, () => {
        renderReplace();
        save();
      });
    });
    el.literal.addEventListener('change', () => {
      state.literal = el.literal.checked;
      renderReplace();
      save();
    });
    el.copyReplace.addEventListener('click', async () => toast((await copyText(el.replaceOut.textContent)) ? 'Result copied' : 'Could not copy'));
    el.copyCode.addEventListener('click', async () => toast((await copyText(buildCode())) ? 'Zig code copied' : 'Could not copy'));

    el.benchBtn.addEventListener('click', runBench);
    el.shareBtn.addEventListener('click', share);

    el.libBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      openMenu(el.libMenu.hidden);
    });
    el.libMenu.addEventListener('click', (e) => {
      const b = e.target.closest('button[data-i]');
      if (!b) return;
      openMenu(false);
      applyEntry(LIB.entries[+b.dataset.i]);
    });
    el.libMenu.addEventListener('keydown', (e) => {
      if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return;
      e.preventDefault();
      const bs = [...el.libMenu.querySelectorAll('button')];
      const i = bs.indexOf(document.activeElement) + (e.key === 'ArrowDown' ? 1 : -1);
      bs[(i + bs.length) % bs.length].focus();
    });
    document.addEventListener('click', (e) => {
      if (!el.libMenu.hidden && !el.libMenu.contains(e.target)) openMenu(false);
    });
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && !el.libMenu.hidden) {
        openMenu(false);
        el.libBtn.focus();
      }
    });

    el.ref.addEventListener('click', (e) => {
      const b = e.target.closest('.ref-item');
      if (b) insertRef(REF[+b.dataset.c][2][+b.dataset.i]);
    });

    // Hovering an explanation row lights up its token in the pattern.
    let hot = null;
    el.explain.addEventListener('mouseover', (e) => {
      const li = e.target.closest('li[data-t]');
      const span = li && el.patternHl.querySelector(`[data-t="${li.dataset.t}"]`);
      if (span === hot) return;
      if (hot) hot.classList.remove('hot');
      hot = span;
      if (hot) hot.classList.add('hot');
    });
    el.explain.addEventListener('mouseleave', () => {
      if (hot) hot.classList.remove('hot');
      hot = null;
    });

    // Wrapping depends on width: re-measure the auto-growing editors.
    if (typeof ResizeObserver !== 'undefined') {
      let lastW = 0;
      new ResizeObserver(([entry]) => {
        const w = entry.contentRect.width;
        if (w === lastW) return;
        lastW = w;
        autoGrow(el.pattern);
        autoGrow(el.subject);
      }).observe(document.querySelector('.col-main'));
    }
  }

  // --- boot -----------------------------------------------------------------------------------------------

  async function boot() {
    const badge = document.createElement('span');
    badge.className = 'badge';
    badge.textContent = '0';
    document.getElementById('tab-matches').appendChild(badge);

    buildRef();
    wire();
    syncInputs();
    selectTab(state.tab || 'matches');
    if (location.hash) history.replaceState(null, '', location.pathname + location.search);
    compileNow(); // explainer + highlighting before the engine arrives

    try {
      engine = await Engine.load('zeetah.wasm');
      el.version.textContent = 'zeetah ' + engine.version + ' · wasm';
      buildLibrary();
    } catch (e) {
      loadError = { code: 'LoadFailed', message: String(e && e.message ? e.message : e) };
      ERRORS.LoadFailed = 'Could not load zeetah.wasm. Build it with `zig build` and open zig-out/web/index.html.';
      el.version.textContent = 'engine unavailable';
      buildLibrary();
    }
    compileNow();
  }

  boot();
})();
