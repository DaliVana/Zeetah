/* Zeetah wasm binding: a small JS API over the export ABI in src/wasm.zig.
 *
 * Classic script (no ES module) so the page also works from file://. Defines
 * `Zeetah` on the global object (and `module.exports` under Node).
 *
 * All offsets are BYTE offsets into the UTF-8 encoding of the input; Zeetah is
 * byte-oriented (`.` matches one byte, `\w` is ASCII).
 */
(function (root) {
  'use strict';

  const enc = new TextEncoder();
  const dec = new TextDecoder('utf-8'); // non-fatal: a split code point decodes as U+FFFD
  const NONE = 0xffffffff;

  /** Flag letters accepted by `compile`, mapped to the shim's flag bits
   *  (`u` is Zeetah's codepoint mode, `.unicode`). */
  const FLAG_BITS = { i: 1, m: 2, s: 4, x: 8, u: 16 };

  class ZeetahError extends Error {
    constructor(code, op) {
      super(code);
      this.name = 'ZeetahError';
      this.code = code; // @errorName from the engine, or 'Trap'
      this.op = op;
    }
  }

  function base64ToBytes(b64) {
    if (typeof Uint8Array.fromBase64 === 'function') return Uint8Array.fromBase64(b64);
    const bin = atob(b64);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  }

  function loadScript(src) {
    return new Promise((resolve, reject) => {
      const s = document.createElement('script');
      s.src = src;
      s.onload = resolve;
      s.onerror = () => reject(new Error('cannot load ' + src));
      document.head.appendChild(s);
    });
  }

  /** Compile the module: fetch `url` over HTTP(S); from file:// (or when the
   *  fetch fails) fall back to the inline base64 copy in zeetah-wasm.js. */
  async function compileModule(url) {
    const fromNetwork = typeof location === 'undefined' || location.protocol !== 'file:';
    if (fromNetwork) {
      try {
        const resp = await fetch(url);
        if (!resp.ok) throw new Error('HTTP ' + resp.status);
        if (WebAssembly.compileStreaming && (resp.headers.get('content-type') || '').includes('application/wasm')) {
          return await WebAssembly.compileStreaming(resp);
        }
        return await WebAssembly.compile(await resp.arrayBuffer());
      } catch (e) {
        if (typeof document === 'undefined') throw e;
      }
    }
    if (typeof root.ZEETAH_WASM_B64 !== 'string') await loadScript(url.replace(/\.wasm$/, '-wasm.js'));
    return WebAssembly.compile(base64ToBytes(root.ZEETAH_WASM_B64));
  }

  class Engine {
    constructor(module, instance) {
      this.module = module;
      this._attach(instance);
    }

    /** Load from a URL (browser), or from bytes / a compiled module (Node). */
    static async load(source = 'zeetah.wasm') {
      let module;
      if (source instanceof WebAssembly.Module) module = source;
      else if (typeof source === 'string') module = await compileModule(source);
      else module = await WebAssembly.compile(source);
      return new Engine(module, await WebAssembly.instantiate(module, {}));
    }

    _attach(instance) {
      this.x = instance.exports;
      this.broken = false;
      this.version = this._outStr(this.x.zt_version(), 'version');
      this.info = null;
    }

    /** Fresh instance after a trap (a trap can leave the heap mid-update). */
    async reset() {
      this._attach(await WebAssembly.instantiate(this.module, {}));
    }

    get memoryBytes() {
      return this.x.memory.buffer.byteLength;
    }

    // --- marshalling ---------------------------------------------------------

    _u8(ptr, len) {
      return new Uint8Array(this.x.memory.buffer, ptr, len);
    }

    _check(rc, op) {
      if (rc >= 0) return rc;
      const name = dec.decode(this._u8(this.x.zt_err_ptr(), this.x.zt_err_len()));
      throw new ZeetahError(name || 'Unknown', op);
    }

    _outStr(rc, op) {
      const n = this._check(rc, op);
      return dec.decode(this._u8(this.x.zt_out_ptr(), n));
    }

    _outBytes(rc, op) {
      const n = this._check(rc, op);
      return this._u8(this.x.zt_out_ptr(), n).slice();
    }

    _words(n) {
      // Re-read the buffer on every call: memory growth detaches old views.
      return new Uint32Array(this.x.memory.buffer, this.x.zt_res_ptr(), n);
    }

    /** Copy each byte array into wasm memory, call fn(ptr0, len0, ptr1, …),
     *  and always free. A wasm trap marks the engine broken. */
    _call(op, arrays, fn) {
      if (this.broken) throw new ZeetahError('Trap', op);
      const ptrs = [];
      try {
        const args = [];
        for (const a of arrays) {
          const p = this.x.zt_alloc(a.length);
          if (!p) throw new ZeetahError('OutOfMemory', op);
          ptrs.push([p, a.length]);
          this._u8(p, a.length).set(a);
          args.push(p, a.length);
        }
        return fn(...args);
      } catch (e) {
        if (e instanceof WebAssembly.RuntimeError) {
          this.broken = true;
          throw new ZeetahError('Trap', op);
        }
        throw e;
      } finally {
        if (!this.broken) for (const [p, n] of ptrs) this.x.zt_free(p, n);
      }
    }

    // --- API -------------------------------------------------------------------

    /** Compile `pattern` with flag letters from "imsxu" (others ignored).
     *  Returns { engine, groups: [{ index, name }] }. */
    compile(pattern, flags = '') {
      let bits = 0;
      for (const f of flags) bits |= FLAG_BITS[f] || 0;
      this.info = null;
      this._call('compile', [enc.encode(pattern)], (p, n) => this._check(this.x.zt_compile(p, n, bits), 'compile'));
      const ng = this._check(this.x.zt_group_count(), 'groups');
      const groups = [];
      for (let g = 1; g <= ng; g++) {
        const len = this._check(this.x.zt_group_name(g), 'groups');
        groups.push({ index: g, name: len ? dec.decode(this._u8(this.x.zt_out_ptr(), len)) : null });
      }
      this.info = { engine: this._outStr(this.x.zt_engine(), 'engine'), groups };
      return this.info;
    }

    /** Matches over `input` (string or UTF-8 bytes). Each match is
     *  { start, end, groups: [[start, end] | null, …] } in byte offsets. */
    exec(input, { global = true, limit = 100000 } = {}) {
      const bytes = typeof input === 'string' ? enc.encode(input) : input;
      return this._call('exec', [bytes], (p, n) => {
        const count = this._check(this.x.zt_exec(p, n, global ? 1 : 0, limit), 'exec');
        const ng = this.info ? this.info.groups.length : 0;
        const stride = 2 + 2 * ng;
        const w = this._words(count * stride);
        const matches = new Array(count);
        for (let i = 0, o = 0; i < count; i++, o += stride) {
          const groups = new Array(ng);
          for (let g = 0; g < ng; g++) {
            const s = w[o + 2 + 2 * g];
            groups[g] = s === NONE ? null : [s, w[o + 3 + 2 * g]];
          }
          matches[i] = { start: w[o], end: w[o + 1], groups };
        }
        return { matches, truncated: this.x.zt_truncated() === 1 };
      });
    }

    /** Replace the first (or every, `global`) match. The template expands
     *  `$0`/`$&`, `$1`…, `${name}`, `$$` unless `literal`. Returns a string. */
    replace(input, template, { global = true, literal = false } = {}) {
      const bytes = typeof input === 'string' ? enc.encode(input) : input;
      return this._call('replace', [bytes, enc.encode(template)], (p, n, t, tn) =>
        dec.decode(this._outBytes(this.x.zt_replace(p, n, t, tn, (global ? 1 : 0) | (literal ? 2 : 0)), 'replace')));
    }

    /** `Regex.split` segments as [start, end] byte-offset pairs. */
    split(input) {
      const bytes = typeof input === 'string' ? enc.encode(input) : input;
      return this._call('split', [bytes], (p, n) => {
        const count = this._check(this.x.zt_split(p, n), 'split');
        const w = this._words(count * 2);
        const out = new Array(count);
        for (let i = 0; i < count; i++) out[i] = [w[2 * i], w[2 * i + 1]];
        return out;
      });
    }

    /** Time `count()` over `input` for about `budgetMs`. Returns
     *  { count, iters, nsPerOp, mbPerSec }. */
    bench(input, budgetMs = 300) {
      const bytes = typeof input === 'string' ? enc.encode(input) : input;
      const now = typeof performance !== 'undefined' ? () => performance.now() : () => Date.now();
      return this._call('bench', [bytes], (p, n) => {
        let iters = 1;
        let count = 0;
        let elapsed = 0;
        // Grow the batch until one batch takes a measurable share of the budget.
        for (;;) {
          const t0 = now();
          count = this._check(this.x.zt_bench(p, n, iters), 'bench');
          elapsed = now() - t0;
          if (elapsed >= budgetMs / 4 || iters >= 1 << 24) break;
          iters = elapsed < 1 ? iters * 16 : Math.min(1 << 24, Math.ceil(iters * (budgetMs / 3) / elapsed));
        }
        const nsPerOp = (elapsed * 1e6) / iters;
        return { count, iters, nsPerOp, mbPerSec: nsPerOp > 0 ? (n / nsPerOp) * 1e3 : Infinity };
      });
    }
  }

  const api = { Engine, ZeetahError, FLAG_BITS, encode: (s) => enc.encode(s), decode: (b) => dec.decode(b) };
  root.Zeetah = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
