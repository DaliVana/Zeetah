/* Example patterns for the playground's "Examples" menu. Each one is chosen to
 * land on a different Zeetah engine (shown in the page's status line), and
 * test/smoke.mjs checks that every entry compiles and matches its sample.
 *
 * Classic script: defines `ZeetahLibrary` globally (and module.exports).
 */
(function (root) {
  'use strict';

  const LOG = [
    '2024-03-15 08:12:01 INFO  user=alice@example.com logged in from 192.168.1.20',
    '2024-03-15 08:12:07 WARN  disk usage at 91% on /var (see https://status.example.com/disk?id=7)',
    '2024-03-16 23:59:59 ERROR payment 7f3c9a2e-41b8-4c7d-9e0a-2b6f8d1c3e45 failed: card 4111-1111-1111-1111 declined',
    '2024-03-17 00:00:00 DEBUG retry the the request (attempt 2) for bob.smith@mail.example.org',
  ].join('\n');

  const entries = [
    {
      name: 'ISO dates (named groups)',
      pattern: '(?<year>\\d{4})-(?<month>\\d{2})-(?<day>\\d{2})',
      flags: 'g',
      text: LOG,
      template: '${day}.${month}.${year}',
    },
    {
      name: 'Email addresses',
      pattern: '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}',
      flags: 'g',
      text: LOG,
      template: '<redacted>',
    },
    {
      name: 'URLs',
      pattern: "https?://[a-zA-Z0-9.-]+(?:/[a-zA-Z0-9._~:/?#\\[\\]@!$&'()*+,;=-]*)?",
      flags: 'g',
      text: LOG,
    },
    {
      name: 'IPv4 addresses',
      pattern: '\\b(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\b',
      flags: 'g',
      text: 'gateway 192.168.1.1, dns 8.8.8.8 and 10.0.0.254; not 999.1.1.1 or 1.2.3',
    },
    {
      name: 'Log levels (keyword set)',
      pattern: '\\b(?:ERROR|WARN|INFO|DEBUG)\\b',
      flags: 'g',
      text: LOG,
    },
    {
      name: 'Times hh:mm:ss',
      pattern: '[0-9]{2}:[0-9]{2}:[0-9]{2}',
      flags: 'g',
      text: LOG,
    },
    {
      name: 'Numbers (digit runs)',
      pattern: '[0-9]+',
      flags: 'g',
      text: 'Order 66 shipped 3 crates (1200 kg) on day 17 of 2024.',
    },
    {
      name: 'Duplicate words (back-reference)',
      pattern: '\\b(\\w+)\\s+\\1\\b',
      flags: 'gi',
      text: 'This is is a test of the the duplicate detector. Paris in the\nthe spring. No repeats here.',
      template: '$1',
    },
    {
      name: 'Password rules (lookahead)',
      pattern: '^(?=.*\\d)(?=.*[a-z])(?=.*[A-Z]).{8,}$',
      flags: 'gm',
      text: 'password\nPassw0rd\nshort1A\nCorrectHorse9Battery\nALLCAPS123',
    },
    {
      name: 'Quoted strings with escapes',
      pattern: '"(?:[^"\\\\]|\\\\.)*"',
      flags: 'g',
      text: 'say "hello", then "a \\"quoted\\" word" and "tab\\tend" but not \'single\'',
    },
    {
      name: 'HTML tag pairs',
      pattern: '<(\\w+)[^>]*>(.*?)</\\1>',
      flags: 'g',
      text: '<p class="lead">Hello <b>bold</b> world</p>\n<a href="/x">link</a> <i>unclosed',
    },
    {
      name: 'Markdown links',
      pattern: '\\[([^\\]]+)\\]\\(([^)\\s]+)\\)',
      flags: 'g',
      text: 'See [the docs](https://example.com/docs) and [API](./API.md), not [broken](no closing',
      template: '<a href="$2">$1</a>',
    },
    {
      name: 'Semantic versions',
      pattern: '\\bv?(\\d+)\\.(\\d+)\\.(\\d+)(?:-([0-9A-Za-z.-]+))?\\b',
      flags: 'g',
      text: 'zig 0.17.0, zeetah v0.17.0, pre-release 1.2.3-rc.1; 2.4 is not a full version',
    },
    {
      name: 'UUIDs',
      pattern: '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
      flags: 'g',
      text: LOG,
    },
    {
      name: 'Hex colors',
      pattern: '#(?:[0-9a-fA-F]{3}){1,2}\\b',
      flags: 'g',
      text: 'color: #ff8800; background: #0af; border: #12345; accent #ABCDEF',
    },
    {
      name: 'Trailing whitespace',
      pattern: '[ \\t]+$',
      flags: 'gm',
      text: 'clean line\ntrailing spaces   \ntrailing tab\t\nend',
      template: '',
    },
    {
      name: 'Case-insensitive word',
      pattern: 'zeetah',
      flags: 'gi',
      text: 'Zeetah is a regex engine. ZEETAH runs in wasm. zeetah is byte-oriented.',
    },
    {
      name: 'Unicode words (u flag)',
      pattern: '\\w+',
      flags: 'gu',
      text: 'naïve café — 日本語のテキスト, Привет мир, ١٢٣ and emoji 😀.',
    },
    {
      name: 'Greek or Cyrillic script (u flag)',
      pattern: '\\p{Greek}+|\\p{Cyrillic}+',
      flags: 'gu',
      text: 'alpha αβγ, Привет мир, beta δ; latin stays out.',
    },
    {
      name: 'Key=value pairs (extended mode)',
      pattern: '(?<key>[a-z_]+)   # the key\n=\n(?<value>\\S+)     # up to whitespace',
      flags: 'gx',
      text: 'user=alice role=admin ttl=3600 debug=true',
      template: '${key}: ${value}',
    },
  ];

  const api = { entries, defaultEntry: entries[0] };
  root.ZeetahLibrary = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
