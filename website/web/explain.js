/* Pattern tokenizer + plain-English explainer for Zeetah's regex syntax.
 *
 * Drives the pattern syntax highlighting, the "Explanation" panel, and a
 * best-effort error location (Zeetah reports *what* is wrong, e.g.
 * InvalidPattern, but not *where*). The engine stays the authority on what
 * compiles; this is a tolerant helper that never throws.
 *
 * Classic script: defines `ZeetahExplain` globally (and module.exports).
 */
(function (root) {
  'use strict';

  const SHORTHAND = {
    d: 'a digit (0-9)',
    D: 'any byte except a digit',
    w: 'a word character (A-Z, a-z, 0-9, _)',
    W: 'any byte except a word character',
    s: 'an ASCII whitespace character',
    S: 'any byte except ASCII whitespace',
    h: 'horizontal whitespace (tab, space, NBSP 0xA0)',
    H: 'any byte except horizontal whitespace',
    v: 'vertical whitespace (LF, VT, FF, CR, NEL 0x85)',
    V: 'any byte except vertical whitespace',
    N: 'any byte except a newline',
    R: 'a line break (\\r\\n, or one of \\n \\v \\f \\r NEL)',
  };
  const ANCHOR_ESC = {
    b: 'a word boundary',
    B: 'a position that is not a word boundary',
    A: 'the very start of the text',
    z: 'the very end of the text',
    Z: 'the end of the text, or just before a final newline',
  };
  const CHAR_ESC = { n: 'newline (\\n)', t: 'tab (\\t)', r: 'carriage return (\\r)', f: 'form feed (\\f)', e: 'escape (0x1B)', a: 'bell (0x07)' };
  const POSIX = {
    alpha: 'letters', digit: 'digits', alnum: 'letters and digits', upper: 'uppercase letters', lower: 'lowercase letters',
    space: 'whitespace', blank: 'space and tab', punct: 'punctuation', xdigit: 'hex digits', word: 'word characters',
    cntrl: 'control characters', print: 'printable characters', graph: 'visible characters', ascii: 'ASCII bytes',
  };

  const isDigit = (c) => c >= '0' && c <= '9';
  const isHex = (c) => /^[0-9a-fA-F]$/.test(c);
  const show = (c) => {
    if (c === ' ') return 'space';
    if (c === '\n') return 'newline';
    if (c === '\t') return 'tab';
    return "'" + c + "'";
  };

  /** Read an escape starting at p[i] === '\\'. `inSet` selects the
   *  character-set meaning (no anchors or back-references there). */
  function readEscape(p, i, inSet) {
    const c = p[i + 1];
    if (c === undefined) return { end: i + 1, type: 'error', desc: 'a trailing backslash escapes nothing' };
    if (SHORTHAND[c] && !(inSet && (c === 'R' || c === 'N'))) return { end: i + 2, type: 'class', desc: SHORTHAND[c], item: SHORTHAND[c] };
    if (!inSet && ANCHOR_ESC[c]) return { end: i + 2, type: 'anchor', desc: ANCHOR_ESC[c] };
    if (!inSet && c >= '1' && c <= '9') {
      let j = i + 1;
      while (isDigit(p[j] || '')) j++;
      const n = p.slice(i + 1, j);
      return { end: j, type: 'backref', desc: 'the same text as group ' + n + ' matched (back-reference)', ref: n };
    }
    if (!inSet && c === 'k' && /[<{']/.test(p[i + 2] || '')) {
      const close = { '<': '>', '{': '}', "'": "'" }[p[i + 2]];
      const j = p.indexOf(close, i + 3);
      if (j < 0) return { end: p.length, type: 'error', desc: 'unterminated named back-reference' };
      const name = p.slice(i + 3, j);
      return { end: j + 1, type: 'backref', desc: 'the same text as group "' + name + '" matched (back-reference)', ref: name };
    }
    if (c === 'x') {
      if (p[i + 2] === '{') {
        const j = p.indexOf('}', i + 3);
        if (j < 0) return { end: p.length, type: 'error', desc: 'unterminated \\x{…} escape' };
        const v = p.slice(i + 3, j);
        return { end: j + 1, type: 'escape', desc: 'the byte 0x' + v.toUpperCase(), item: '0x' + v.toUpperCase() };
      }
      let j = i + 2;
      while (j < i + 4 && isHex(p[j] || '')) j++;
      const v = p.slice(i + 2, j) || '0';
      return { end: j, type: 'escape', desc: 'the byte 0x' + v.toUpperCase().padStart(2, '0'), item: '0x' + v.toUpperCase() };
    }
    if (c === 'o' && p[i + 2] === '{') {
      const j = p.indexOf('}', i + 3);
      if (j < 0) return { end: p.length, type: 'error', desc: 'unterminated \\o{…} escape' };
      return { end: j + 1, type: 'escape', desc: 'the byte with octal value ' + p.slice(i + 3, j), item: 'octal ' + p.slice(i + 3, j) };
    }
    if (c === '0') {
      let j = i + 2;
      while (j < i + 4 && /[0-7]/.test(p[j] || '')) j++;
      const v = p.slice(i + 2, j);
      return { end: j, type: 'escape', desc: v ? 'the byte with octal value ' + v : 'the NUL byte (0x00)', item: v ? 'octal ' + v : 'NUL' };
    }
    if (c === 'p' || c === 'P') {
      let name;
      let end;
      if (p[i + 2] === '{') {
        const j = p.indexOf('}', i + 3);
        if (j < 0) return { end: p.length, type: 'error', desc: 'unterminated \\p{…} property' };
        name = p.slice(i + 3, j);
        end = j + 1;
      } else {
        name = p[i + 2] || '';
        end = i + 3;
      }
      let neg = c === 'P';
      if (name.startsWith('^')) {
        neg = !neg;
        name = name.slice(1);
      }
      const d = (neg ? 'any byte NOT in' : 'a byte in') + ' Unicode category ' + name + ' (Latin-1 range)';
      return { end, type: 'class', desc: d, item: (neg ? 'not ' : '') + '\\p{' + name + '}' };
    }
    if (CHAR_ESC[c]) return { end: i + 2, type: 'escape', desc: CHAR_ESC[c], item: CHAR_ESC[c] };
    if (inSet && c === 'b') return { end: i + 2, type: 'escape', desc: 'backspace (0x08)', item: 'backspace' };
    return { end: i + 2, type: 'escape', desc: 'the literal character ' + show(c), item: show(c), lit: c };
  }

  /** Parse a `[...]` set at p[i] === '['. */
  function readSet(p, i) {
    let j = i + 1;
    let neg = false;
    if (p[j] === '^') {
      neg = true;
      j++;
    }
    const items = [];
    let first = true;
    while (j < p.length) {
      if (p[j] === ']' && !first) {
        const list = items.length > 8 ? items.slice(0, 8).join(', ') + ', …' : items.join(', ');
        return { end: j + 1, type: 'set', desc: (neg ? 'any byte except ' : 'one of: ') + (list || 'nothing') };
      }
      first = false;
      let atom;
      let atomEnd;
      let lit = null;
      if (p[j] === '[' && p[j + 1] === ':') {
        const k = p.indexOf(':]', j + 2);
        if (k < 0) return { end: p.length, type: 'error', desc: 'unterminated POSIX class [:…:]' };
        let name = p.slice(j + 2, k);
        const pneg = name.startsWith('^');
        if (pneg) name = name.slice(1);
        atom = (pneg ? 'not ' : '') + (POSIX[name] || 'POSIX [:' + name + ':]');
        atomEnd = k + 2;
      } else if (p[j] === '\\') {
        const e = readEscape(p, j, true);
        if (e.type === 'error') return { end: e.end, type: 'error', desc: e.desc };
        atom = e.item || e.desc;
        lit = e.lit !== undefined ? e.lit : null;
        atomEnd = e.end;
      } else {
        lit = p[j];
        atom = show(p[j]);
        atomEnd = j + 1;
      }
      // Range a-z (a '-' before ']' is a literal dash).
      if (lit !== null && p[atomEnd] === '-' && p[atomEnd + 1] !== undefined && p[atomEnd + 1] !== ']') {
        let hiEnd = atomEnd + 2;
        let hi = p[atomEnd + 1];
        if (hi === '\\') {
          const e = readEscape(p, atomEnd + 1, true);
          hi = e.lit !== undefined ? e.lit : e.item;
          hiEnd = e.end;
        }
        atom = show(lit) + '–' + (hi.length === 1 ? show(hi) : hi);
        atomEnd = hiEnd;
        if (hi.length === 1 && lit > hi) return { end: atomEnd, type: 'error', desc: 'range ' + lit + '-' + hi + ' is out of order' };
      }
      items.push(atom);
      j = atomEnd;
    }
    return { end: p.length, type: 'error', desc: 'unterminated character set: missing ]' };
  }

  function quantDesc(q) {
    let base;
    if (q.min === 0 && q.max === Infinity) base = 'zero or more times';
    else if (q.min === 1 && q.max === Infinity) base = 'one or more times';
    else if (q.min === 0 && q.max === 1) base = 'optional (zero or one time)';
    else if (q.max === Infinity) base = q.min + ' or more times';
    else if (q.min === q.max) base = 'exactly ' + q.min + (q.min === 1 ? ' time' : ' times');
    else base = 'between ' + q.min + ' and ' + q.max + ' times';
    if (q.mode === 'lazy') return base + ', as few as possible (lazy)';
    if (q.mode === 'possessive') return base + ', never giving any back (possessive)';
    return base + ', as many as possible (greedy)';
  }

  /** Quantifier at p[i], or null. */
  function readQuant(p, i) {
    const c = p[i];
    let q = null;
    let end = i + 1;
    if (c === '*') q = { min: 0, max: Infinity };
    else if (c === '+') q = { min: 1, max: Infinity };
    else if (c === '?') q = { min: 0, max: 1 };
    else if (c === '{') {
      const m = /^\{(\d+)(,(\d*))?\}/.exec(p.slice(i));
      if (!m) return null;
      const min = +m[1];
      const max = m[2] === undefined ? min : m[3] === '' ? Infinity : +m[3];
      q = { min, max };
      end = i + m[0].length;
      if (max < min) return { end, q, bad: 'the bounds of {' + min + ',' + max + '} are out of order' };
    } else return null;
    q.mode = 'greedy';
    if (p[end] === '?') {
      q.mode = 'lazy';
      end++;
    } else if (p[end] === '+') {
      q.mode = 'possessive';
      end++;
    }
    return { end, q };
  }

  const LOOK = {
    '?=': 'lookahead: the text ahead must match',
    '?!': 'negative lookahead: the text ahead must NOT match',
    '?<=': 'lookbehind: the text before must match (fixed width)',
    '?<!': 'negative lookbehind: the text before must NOT match (fixed width)',
    '?>': 'atomic group: once matched, never backtracked into',
    '?:': 'non-capturing group',
  };

  /**
   * parse(pattern, flags) → {
   *   tokens: [{ start, end, type, desc, depth, group? }],
   *   groups: [{ index, name, start }],
   *   error: { start, end, desc } | null,
   * }
   * Token types: literal escape class set dot anchor quant open close alt
   * backref flags comment ws error.
   */
  function parse(pattern, flags = '') {
    const p = pattern;
    const tokens = [];
    const groups = [];
    const stack = []; // open groups: { token, ext, multi, dotall }
    let ext = flags.includes('x');
    let multi = flags.includes('m');
    let dotall = flags.includes('s');
    let canRepeat = false; // is there an atom a quantifier could apply to?
    let error = null;
    const fail = (start, end, desc) => {
      if (!error) error = { start, end, desc };
      tokens.push({ start, end, type: 'error', desc, depth: stack.length });
    };

    let i = 0;
    while (i < p.length) {
      const c = p[i];
      const depth = stack.length;

      if (ext && /\s/.test(c)) {
        let j = i + 1;
        while (j < p.length && /\s/.test(p[j])) j++;
        tokens.push({ start: i, end: j, type: 'ws', depth });
        i = j;
        continue;
      }
      if (ext && c === '#') {
        let j = p.indexOf('\n', i);
        if (j < 0) j = p.length;
        tokens.push({ start: i, end: j, type: 'comment', desc: 'comment (ignored in extended mode)', depth });
        i = j;
        continue;
      }

      if (c === '\\') {
        const e = readEscape(p, i, false);
        if (e.type === 'error') fail(i, e.end, e.desc);
        else tokens.push({ start: i, end: e.end, type: e.type, desc: e.desc, depth, lit: e.lit });
        canRepeat = e.type !== 'anchor' && e.type !== 'error';
        i = e.end;
        continue;
      }
      if (c === '[') {
        const s = readSet(p, i);
        if (s.type === 'error') fail(i, s.end, s.desc);
        else tokens.push({ start: i, end: s.end, type: 'set', desc: s.desc, depth });
        canRepeat = s.type !== 'error';
        i = s.end;
        continue;
      }
      if (c === '(') {
        let j = i + 1;
        let tok = null;
        const rest = p.slice(i + 1);
        const named = /^\?(?:P?<([A-Za-z_][A-Za-z0-9_]*)>|'([A-Za-z_][A-Za-z0-9_]*)')/.exec(rest);
        const flagGroup = /^\?([imsxU]*)(?:-([imsxU]*))?([:)])/.exec(rest);
        const lookKey = ['?<=', '?<!', '?=', '?!', '?>', '?:'].find((k) => rest.startsWith(k));
        if (lookKey) {
          j = i + 1 + lookKey.length;
          tok = { type: 'open', desc: LOOK[lookKey], look: lookKey !== '?:' };
        } else if (named) {
          const name = named[1] || named[2];
          const index = groups.length + 1;
          groups.push({ index, name, start: i });
          j = i + 1 + named[0].length;
          tok = { type: 'open', desc: 'capture group ' + index + ' named "' + name + '"', group: index };
        } else if (flagGroup && (flagGroup[1] || flagGroup[2])) {
          const on = flagGroup[1] || '';
          const off = flagGroup[2] || '';
          const names = { i: 'case-insensitive', m: 'multiline', s: 'dot matches newline', x: 'extended', U: 'swap greedy' };
          const parts = [...on].map((f) => names[f] || f).concat([...off].map((f) => 'not ' + (names[f] || f)));
          j = i + 1 + flagGroup[0].length;
          if (flagGroup[3] === ')') {
            // (?i) — applies to the rest of the enclosing group.
            if (on.includes('x')) ext = true;
            if (off.includes('x')) ext = false;
            if (on.includes('m')) multi = true;
            if (off.includes('m')) multi = false;
            if (on.includes('s')) dotall = true;
            if (off.includes('s')) dotall = false;
            tokens.push({ start: i, end: j, type: 'flags', desc: 'turn on ' + parts.join(', ') + ' for the rest of the enclosing group', depth });
            canRepeat = false;
            i = j;
            continue;
          }
          tok = { type: 'open', desc: 'non-capturing group with ' + parts.join(', '), scoped: { on, off } };
        } else if (rest.startsWith('?')) {
          let k = i + 2;
          while (k < p.length && p[k] !== ')' && p[k] !== ':') k++;
          fail(i, Math.min(k + 1, p.length), 'unrecognised group syntax (' + p.slice(i, Math.min(k + 1, p.length)) + ')');
          i = Math.min(k + 1, p.length);
          continue;
        } else {
          const index = groups.length + 1;
          groups.push({ index, name: null, start: i });
          tok = { type: 'open', desc: 'capture group ' + index, group: index };
        }
        const t = { start: i, end: j, depth, ...tok };
        tokens.push(t);
        stack.push({ token: t, ext, multi, dotall });
        if (tok.scoped) {
          const { on, off } = tok.scoped;
          if (on.includes('x')) ext = true;
          if (off.includes('x')) ext = false;
          if (on.includes('m')) multi = true;
          if (off.includes('m')) multi = false;
          if (on.includes('s')) dotall = true;
          if (off.includes('s')) dotall = false;
        }
        canRepeat = false;
        i = j;
        continue;
      }
      if (c === ')') {
        const open = stack.pop();
        if (!open) {
          fail(i, i + 1, 'unmatched ) with no group to close');
          i++;
          continue;
        }
        ({ ext, multi, dotall } = open);
        tokens.push({ start: i, end: i + 1, type: 'close', desc: 'end of ' + open.token.desc.split(':')[0], depth: stack.length, group: open.token.group, pair: open.token });
        open.token.pair = tokens[tokens.length - 1];
        canRepeat = true;
        i++;
        continue;
      }
      if (c === '|') {
        tokens.push({ start: i, end: i + 1, type: 'alt', desc: 'or: alternatively, match what follows', depth: Math.max(0, depth - 1) });
        canRepeat = false;
        i++;
        continue;
      }
      const q = readQuant(p, i);
      if (q) {
        if (!canRepeat) fail(i, q.end, 'quantifier ' + p.slice(i, q.end) + ' has nothing to repeat');
        else if (q.bad) fail(i, q.end, q.bad);
        else tokens.push({ start: i, end: q.end, type: 'quant', desc: quantDesc(q.q), depth });
        canRepeat = false;
        i = q.end;
        continue;
      }
      if (c === '.') {
        tokens.push({ start: i, end: i + 1, type: 'dot', desc: dotall ? 'any byte, including newline' : 'any byte except newline', depth });
        canRepeat = true;
        i++;
        continue;
      }
      if (c === '^' || c === '$') {
        const d = c === '^' ? (multi ? 'the start of a line' : 'the start of the text') : multi ? 'the end of a line' : 'the end of the text';
        tokens.push({ start: i, end: i + 1, type: 'anchor', desc: d, depth });
        canRepeat = false;
        i++;
        continue;
      }
      // Literal: one code point (a surrogate pair stays together).
      const cp = p.codePointAt(i);
      const len = cp > 0xffff ? 2 : 1;
      tokens.push({ start: i, end: i + len, type: 'literal', depth, lit: p.slice(i, i + len) });
      canRepeat = true;
      i += len;
    }
    for (const open of stack) fail(open.token.start, open.token.end, 'unclosed group: missing )');

    return { tokens: mergeLiterals(p, tokens), groups, error };
  }

  /** Fold runs of literals into one "literal text" token, keeping the last
   *  character separate when a quantifier applies to it alone. */
  function mergeLiterals(p, tokens) {
    const out = [];
    for (let k = 0; k < tokens.length; k++) {
      const t = tokens[k];
      if (t.type !== 'literal' && !(t.type === 'escape' && t.lit !== undefined)) {
        out.push(t);
        continue;
      }
      let e = k;
      while (e + 1 < tokens.length && isLit(tokens[e + 1]) && tokens[e + 1].depth === t.depth) e++;
      if (e > k && tokens[e + 1] && tokens[e + 1].type === 'quant') e--;
      if (e === k) {
        out.push(t.type === 'literal' ? { ...t, desc: 'the character ' + show(t.lit) } : t);
        continue;
      }
      const text = tokens.slice(k, e + 1).map((x) => x.lit).join('');
      out.push({ start: t.start, end: tokens[e].end, type: 'literal', depth: t.depth, desc: 'the text "' + text + '"' });
      k = e;
    }
    return out;
  }
  const isLit = (t) => t.type === 'literal' || (t.type === 'escape' && t.lit !== undefined);

  const api = { parse };
  root.ZeetahExplain = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
