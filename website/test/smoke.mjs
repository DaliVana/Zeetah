// Smoke test for the wasm ABI (src/wasm.zig) through the JS binding
// (web/zeetah.js), plus a cross-check of the explainer (web/explain.js)
// against the engine's own group table.
//
//   node test/smoke.mjs <zeetah.wasm> <zeetah.js> <explain.js> <library.js>   (zig build test)

import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import assert from 'node:assert/strict';
import { resolve } from 'node:path';

const [wasmPath, bindingPath, explainPath, libraryPath] = process.argv.slice(2).map((a) => resolve(a));
const require = createRequire(import.meta.url);
const { Engine, ZeetahError } = require(bindingPath);
const { parse } = require(explainPath);
const library = require(libraryPath);

const z = await Engine.load(readFileSync(wasmPath));
assert.equal(WebAssembly.Module.imports(z.module).length, 0, 'module must not need imports');
assert.match(z.version, /^\d+\.\d+\.\d+$/);

let passed = 0;
function test(name, fn) {
  try {
    fn();
    passed++;
  } catch (e) {
    console.error('FAIL ' + name);
    throw e;
  }
}
const spans = (r) => r.matches.map((m) => [m.start, m.end]);

test('class run, all matches', () => {
  z.compile('\\d+');
  assert.deepEqual(spans(z.exec('a12 b345')), [[1, 3], [5, 8]]);
});

test('first match only without g', () => {
  z.compile('\\d+');
  assert.deepEqual(spans(z.exec('a12 b345', { global: false })), [[1, 3]]);
});

test('limit reports truncation', () => {
  z.compile('a');
  const r = z.exec('aaaa', { limit: 2 });
  assert.equal(r.matches.length, 2);
  assert.equal(r.truncated, true);
  assert.equal(z.exec('aaaa', { limit: 4 }).truncated, false);
});

test('named groups and spans', () => {
  const info = z.compile('(?<y>\\d{4})-(?<m>\\d{2})');
  assert.deepEqual(info.groups, [{ index: 1, name: 'y' }, { index: 2, name: 'm' }]);
  const r = z.exec('on 2024-03 and 1999-12');
  assert.deepEqual(r.matches[0], { start: 3, end: 10, groups: [[3, 7], [8, 10]] });
  assert.deepEqual(r.matches[1].groups, [[15, 19], [20, 22]]);
});

test('non-participating group is null', () => {
  z.compile('(a)?b');
  assert.deepEqual(z.exec('b').matches[0].groups, [null]);
});

test('case-insensitive flag', () => {
  z.compile('hello', 'i');
  assert.deepEqual(spans(z.exec('say HeLLo')), [[4, 9]]);
});

test('multiline flag', () => {
  z.compile('^\\w+', 'm');
  assert.deepEqual(spans(z.exec('ab\ncd')), [[0, 2], [3, 5]]);
});

test('byte offsets over UTF-8', () => {
  z.compile('é');
  assert.deepEqual(spans(z.exec('café é')), [[3, 5], [6, 8]]);
});

test('unicode flag: characters, Unicode \\w, scripts, set ops, case folding', () => {
  z.compile('.', 'u');
  assert.deepEqual(spans(z.exec('aé😀')), [[0, 1], [1, 3], [3, 7]]);
  z.compile('\\w+', 'u');
  assert.deepEqual(spans(z.exec('naïve café')), [[0, 6], [7, 12]]);
  z.compile('\\p{Greek}+', 'u');
  assert.deepEqual(spans(z.exec('abc αβγ')), [[4, 10]]);
  z.compile('[\\p{L}--\\p{Lu}]+', 'u');
  assert.deepEqual(spans(z.exec('abCDef')), [[0, 2], [4, 6]]);
  z.compile('(?iu)k');
  assert.equal(z.exec('kK\u212A').matches.length, 3);
  // Byte mode is unchanged: `.` is one byte, \w stops at the first non-ASCII byte.
  z.compile('.');
  assert.equal(z.exec('aé😀').matches.length, 7);
  z.compile('\\w+');
  assert.deepEqual(spans(z.exec('naïve café')), [[0, 2], [4, 6], [7, 10]]);
});

test('replace with template, first and all', () => {
  z.compile('(\\w+)@(\\w+)');
  assert.equal(z.replace('a@b c@d', '$2 at $1'), 'b at a d at c');
  assert.equal(z.replace('a@b c@d', '[$&]', { global: false }), '[a@b] c@d');
  z.compile('(?<user>\\w+)@');
  assert.equal(z.replace('x@y', '${user}!'), 'x!y');
});

test('literal replace keeps $', () => {
  z.compile('\\d+');
  assert.equal(z.replace('a1 b2', '$1', { literal: true }), 'a$1 b$1');
});

test('split', () => {
  z.compile(',\\s*');
  assert.deepEqual(z.split('a, b,c'), [[0, 1], [3, 4], [5, 6]]);
});

test('back-reference and lookahead', () => {
  z.compile('\\b(\\w+)\\s+\\1\\b');
  assert.deepEqual(spans(z.exec('the the cat')), [[0, 7]]);
  z.compile('\\w+(?=!)');
  assert.deepEqual(spans(z.exec('hi there!')), [[3, 8]]);
});

test('compile errors are typed', () => {
  assert.throws(() => z.compile('abc('), (e) => e instanceof ZeetahError && e.code === 'InvalidPattern');
  assert.throws(() => z.compile(''), (e) => e.code === 'EmptyPattern');
  assert.throws(() => z.compile('\\p{Greek}'), (e) => e.code === 'NotImplemented');
  assert.throws(() => z.compile('a{5000}'), (e) => e.code === 'PatternTooComplex');
  // The engine still works after a failed compile.
  z.compile('ok');
  assert.equal(z.exec('ok ok').matches.length, 2);
});

test('engine routing is reported', () => {
  assert.equal(z.compile('foo').engine, 'literal');
  assert.equal(z.compile('[a-z]+').engine, 'class_span');
  assert.equal(z.compile('\\b(\\w+)\\s+\\1\\b').engine.length > 0, true);
});

test('bench counts matches', () => {
  z.compile('\\d+');
  const b = z.bench('a1 b22 c333 '.repeat(100), 20);
  assert.equal(b.count, 300);
  assert.ok(b.iters >= 1 && b.nsPerOp > 0);
});

test('large input grows memory safely', () => {
  z.compile('x');
  const big = 'ab'.repeat(1 << 21) + 'x';
  assert.deepEqual(spans(z.exec(big)), [[big.length - 1, big.length]]);
});

// The explainer must number groups exactly like the engine.
const corpus = [
  '(?<year>\\d{4})-(?<month>\\d{2})-(?<day>\\d{2})',
  '\\b(\\w+)\\s+\\1\\b',
  '(a)(?:b)(?=c)(?<n>d)(?P<m>e)',
  '^(?=.*\\d)(?=.*[a-z])(?=.*[A-Z]).{8,}$',
  '"(?:[^"\\\\]|\\\\.)*"',
  '<(\\w+)[^>]*>(.*?)</\\1>',
  '\\[([^\\]]+)\\]\\(([^)]+)\\)',
  '(?i)(foo|bar)+?baz{2,3}',
  '(?x) (\\d+) # digits\n [a-z]+',
  '[[:alpha:]_][[:alnum:]_]*',
];
test('explainer group numbering matches the engine', () => {
  for (const pat of corpus) {
    const info = z.compile(pat);
    const ex = parse(pat);
    assert.equal(ex.error, null, pat + ': ' + (ex.error && ex.error.desc));
    assert.deepEqual(ex.groups.map((g) => g.name), info.groups.map((g) => g.name), pat);
  }
});

test('explainer locates obvious syntax errors', () => {
  assert.equal(parse('abc(').error.start, 3);
  assert.equal(parse('a)').error.start, 1);
  assert.equal(parse('[abc').error.start, 0);
  assert.equal(parse('*a').error.start, 0);
  assert.match(parse('a{3,2}').error.desc, /out of order/);
});

test('explainer understands the u flag', () => {
  assert.equal(parse('(?u)[\\p{L}--\\p{Lu}]+\\N{U+1F600}', '').error, null);
  assert.equal(parse('[a-z&&[^aeiou]]+\\x{1F600}', 'u').error, null);
  assert.match(parse('.', 'u').tokens[0].desc, /character/);
  assert.match(parse('.', '').tokens[0].desc, /byte/);
  assert.match(parse('(?u)\\b', '').tokens[1].desc, /Unicode/);
});

test('explainer merges literal runs before quantifiers', () => {
  const t = parse('abc+').tokens.map((x) => [x.type, x.start, x.end]);
  assert.deepEqual(t, [['literal', 0, 2], ['literal', 2, 3], ['quant', 3, 4]]);
});

test('every example compiles, matches its sample, and explains cleanly', () => {
  for (const e of library.entries) {
    const info = z.compile(e.pattern, e.flags.replace('g', ''));
    const r = z.exec(e.text, { global: e.flags.includes('g') });
    assert.ok(r.matches.length > 0, e.name + ': no match on its sample');
    const ex = parse(e.pattern, e.flags);
    assert.equal(ex.error, null, e.name + ': ' + (ex.error && ex.error.desc));
    assert.deepEqual(ex.groups.map((g) => g.name), info.groups.map((g) => g.name), e.name);
  }
});

console.log(`smoke: ${passed} tests passed (zeetah ${z.version}, ${(z.memoryBytes / 1048576).toFixed(0)} MiB memory)`);
