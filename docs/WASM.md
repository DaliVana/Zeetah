# WebAssembly (WASM)

Zeetah is a **pure-Zig library** with zero external dependencies. Because Zig
targets WebAssembly natively, you can run Zeetah in a browser, in Node.js, in
WASI runtimes (Wasmtime, Wasmer), or in any other Wasm host — but you do this by
compiling **your own** Zig program (which `@import("zeetah")`s the module) to a
`wasm32` target.

> **There is no prebuilt `zeetah.wasm` and no C / WASM ABI.** Zeetah does **not**
> ship a `.wasm` artifact, and the public surface is the Zig module only
> (`Regex`, `Pattern`, `Builder`, …). Functions like `zeetah_compile`,
> `zeetah_is_match`, `zeetah_free`, or a `ZeetahRegex` handle type **do not
> exist**. If you want a flat C-callable boundary for JavaScript glue, you write
> a tiny Zig `export fn` shim yourself — a sketch is in
> [Writing an export shim](#writing-an-export-shim) below.

This page shows the two realistic paths:

1. **[WASI](#path-1--wasi-self-contained-program)** — compile a self-contained
   Zig program to `wasm32-wasi` and run it under a WASI host. Simplest path; the
   program owns its own allocator and I/O.
2. **[Export shim](#path-2--browserjs-via-an-export-shim)** — compile a Zig
   `export fn` shim to `wasm32-freestanding` for direct calls from browser
   JavaScript over the linear-memory boundary. More work, but no WASI runtime
   needed.

---

## Why there is no prebuilt module

The published package (`build.zig.zon`: `.name = .zeetah`) exposes a single Zig
**module**, `zeetah`, rooted at `src/root.zig`. The repository's `build.zig`
defines the `test`, `doctest`, `bench-tokenizer`, and `parity` steps plus the implicit `install` (which
builds the internal `parity_harness`). It does **not** build a shared library, a
C header, or a `.wasm` file, and `src/root.zig` exports no `extern`/`export`
functions.

So a "WASM build" of Zeetah is really *your* Wasm program with Zeetah linked in
as a dependency. The library itself is allocator-driven and OS-agnostic, so it
compiles cleanly to `wasm32-freestanding` and `wasm32-wasi` with no special
configuration.

---

## Adding Zeetah as a dependency

In your own project's `build.zig.zon`, depend on Zeetah (replace the URL/hash
with a published release once available):

```zig
.dependencies = .{
    .zeetah = .{
        .url = "TBD", // e.g. a release tarball; `zig fetch --save <url>` fills the hash
        .hash = "...",
    },
},
```

Then wire the module into your `build.zig`, targeting Wasm:

```zig
pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Pick ONE target depending on the path you take below.
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi, // or .freestanding for the export-shim path
    });

    const zeetah = b.dependency("zeetah", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "myregex",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zeetah", .module = zeetah.module("zeetah") },
            },
        }),
    });
    b.installArtifact(exe);
}
```

`zig build` then emits your `.wasm` under `zig-out/bin/`.

> Requires **Zig 0.16+** — the same minimum as Zeetah itself.

---

## Path 1 — WASI (self-contained program)

The least friction. Your program owns an allocator and does its own I/O; the
WASI host (Wasmtime, Wasmer, Node's `--experimental-wasi-unstable-preview1`,
browser WASI shims) supplies `memory`, a clock, etc. Everything in Zeetah's
public API is available exactly as on a native target.

```zig
// src/main.zig
const std = @import("std");
const zeetah = @import("zeetah");
const Regex = zeetah.Regex;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var re = try Regex.compile(allocator, "\\d{3}-\\d{4}");
    defer re.deinit();

    if (try re.find("call 555-1234 now")) |m| {
        // find returns a whole-match span only (.slice/.start/.end);
        // it does NOT populate capture groups.
        std.debug.print("{s} @ [{d}..{d})\n", .{ m.slice, m.start, m.end });
    }
}
```

Build and run:

```bash
zig build -Doptimize=ReleaseSmall    # emits zig-out/bin/myregex.wasm

wasmtime zig-out/bin/myregex.wasm    # or: wasmer run zig-out/bin/myregex.wasm
```

If you prefer a one-shot compile without a `build.zig` wiring step, point the
compiler at your sources directly:

```bash
zig build-exe src/main.zig \
    -target wasm32-wasi \
    -O ReleaseSmall \
    --dep zeetah \
    -Mroot=src/main.zig \
    -Mzeetah=<path-to-zeetah>/src/root.zig
```

---

## Path 2 — Browser/JS via an export shim

For direct browser use (no WASI runtime), compile to `wasm32-freestanding` and
expose a few `export fn`s. Because Wasm only passes numbers across the boundary,
strings are exchanged as `(ptr, len)` pairs into the module's **linear memory**.
You are the one who designs and owns this ABI — Zeetah does not provide it.

### Writing an export shim

This is a minimal, realistic sketch. It exports a fixed-buffer allocator for the
JS side to write input bytes into, plus a stateless `isMatch` that compiles the
pattern, runs the match, and frees it in one call. Adapt it to your needs.

```zig
// src/shim.zig — compiled to wasm32-freestanding
const std = @import("std");
const zeetah = @import("zeetah");
const Regex = zeetah.Regex;

// A single linear-memory arena the JS host writes into and reads from.
var buffer: [1 << 20]u8 = undefined; // 1 MiB scratch
var fba = std.heap.FixedBufferAllocator.init(&buffer);

/// JS calls this to learn where to write bytes; it then copies UTF-8 into
/// `memory` at the returned offset (up to `buffer.len`).
export fn bufferPtr() [*]u8 {
    return &buffer;
}

export fn bufferLen() usize {
    return buffer.len;
}

/// Compile `pattern` and test it against `input`, returning 1 / 0 / -1.
/// All four arguments are byte offsets+lengths into linear memory.
/// Returns -1 on any compile or match error (e.g. error.PatternTooComplex).
export fn isMatch(
    pattern_ptr: [*]const u8,
    pattern_len: usize,
    input_ptr: [*]const u8,
    input_len: usize,
) i32 {
    fba.reset();
    const allocator = fba.allocator();

    const pattern = pattern_ptr[0..pattern_len];
    const input = input_ptr[0..input_len];

    var re = Regex.compile(allocator, pattern) catch return -1;
    defer re.deinit();

    const hit = re.isMatch(input) catch return -1;
    return if (hit) 1 else 0;
}

// Required for freestanding builds: define a panic handler so the module
// does not pull in std's default OS-dependent one.
pub fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    while (true) {}
}
```

Build it with the matching export flags:

```bash
zig build-exe src/shim.zig \
    -target wasm32-freestanding \
    -O ReleaseSmall \
    -fno-entry \
    --export=bufferPtr \
    --export=bufferLen \
    --export=isMatch \
    --dep zeetah \
    -Mroot=src/shim.zig \
    -Mzeetah=<path-to-zeetah>/src/root.zig
```

(`-fno-entry` because there is no `main`; `--export=` makes each `export fn`
visible to the host. You can wire the same flags into a `build.zig` executable
via `exe.entry = .disabled;` and `exe.rdynamic = true;`.)

### Calling it from JavaScript

The host writes the pattern and input into the shim's `buffer`, then calls
`isMatch` with the two `(offset, length)` pairs:

```javascript
const bytes = await (await fetch('shim.wasm')).arrayBuffer();
const { instance } = await WebAssembly.instantiate(bytes, {});
const { memory, bufferPtr, bufferLen, isMatch } = instance.exports;

const enc = new TextEncoder();
const base = bufferPtr();              // offset into linear memory
const view = new Uint8Array(memory.buffer, base, bufferLen());

function writeStr(s, at) {
    const b = enc.encode(s);
    view.set(b, at);
    return [base + at, b.length];      // (ptr, len) into linear memory
}

// Lay pattern then input out back-to-back in the shared buffer.
const [pPtr, pLen] = writeStr('\\d{3}-\\d{4}', 0);
const [iPtr, iLen] = writeStr('call 555-1234 now', pLen);

const result = isMatch(pPtr, pLen, iPtr, iLen); // 1 = match, 0 = no match, -1 = error
console.log('matched:', result === 1);
```

> This is *your* ABI. Want to return the match span, find-all results, or
> capture slices? Add more `export fn`s that write their results back into the
> shared buffer (a length-prefixed encoding works well) and decode them on the
> JS side. Keep in mind the semantics of the underlying API: `find` returns a
> whole-match span only, `captures` (which allocates) is the opt-in path for
> submatch slices, `replace`/`replaceAll` expand `$`-references in the template
> (`$0`/`$&`, `$1`..`$N`, `${name}`), and `replaceLiteral`/`replaceAllLiteral`
> insert the replacement verbatim (no `$`-substitution).

---

## Compile-time patterns in WASM

If your pattern is known at compile time, `Pattern` is an excellent fit for Wasm:
the entire parse → NFA → DFA pipeline runs **at compile time** and bakes the
matcher into `.rodata`, so the Wasm module carries no compiler and `isMatch` /
`find` / `count` are **allocation-free** at runtime.

```zig
const zeetah = @import("zeetah");

const Phone = zeetah.Pattern("[0-9]{3}-[0-9]{4}", .{});

export fn phoneMatches(ptr: [*]const u8, len: usize) i32 {
    return if (Phone.isMatch(ptr[0..len])) 1 else 0;
}
```

`Pattern` is **capture-free** and only handles the regular, DFA-representable
subset. Lookaround, backreferences, captures-with-submatches, and look-assertions
are a hard `@compileError` on this path (there is no runtime fallback baked into
a `Pattern`); for those, use the runtime `Regex` shim above.

---

## Memory model

- **Linear memory.** Wasm has a single growable linear memory. In the freestanding
  shim you choose the allocator — the example uses a fixed-size
  `FixedBufferAllocator` (reset per call, so nothing leaks across calls). You can
  instead use a `DebugAllocator` or wrap the host's memory growth, but a
  reset-per-call arena is the simplest correct choice for a stateless ABI.
- **No hidden allocation.** Every Zeetah heap allocation goes through the
  allocator you pass. `find` / `isMatch` / `count` (and all `Pattern` methods
  except `findAll`) compute whole-match results without allocating; `captures`,
  `findAll`, `split`, and `replace` are the allocating calls.
- **Borrowed match views.** A `Match.slice` aliases the input bytes — in the
  shim those bytes live in the shared linear-memory buffer. Read any result out
  (e.g. copy it back into the buffer for JS) *before* the buffer is overwritten
  or the arena is reset.
- **Threading.** Wasm modules are single-threaded by default; Zeetah does no
  threading of its own. Use Web Workers (each with its own instance) for
  parallelism.

---

## Not currently provided

The following are **not** part of Zeetah today. They are reasonable things to
build on top of the library, but the project does not ship them:

- A prebuilt `zeetah.wasm` artifact or an npm package.
- A C ABI / C header, or any `extern`/`export` functions in the published
  module (the shim above is something **you** write).
- A stateful handle API (`zeetah_compile` → handle → `zeetah_is_match` →
  `zeetah_free`). The sketch above is deliberately stateless; if you want
  reusable compiled-regex handles across calls, you design that handle table in
  your own shim.
- Automatic string marshalling, TypeScript bindings, or a streaming/worker-pool
  API.

---

## Resources

- [WebAssembly (MDN)](https://developer.mozilla.org/en-US/docs/WebAssembly)
- [Zig WebAssembly target docs](https://ziglang.org/documentation/master/#WebAssembly)
- [WASI](https://wasi.dev/) — the WebAssembly System Interface
- Zeetah: [README](../README.md) · [API Reference](API.md) ·
  [Architecture](ARCHITECTURE.md)
