//! SIMD first-byte prefilter.
//!
//! The optimizer produces a 256-bit `first_byte_set` bitmap — a strictly
//! necessary condition for where a match may start. This module scans the
//! input for the next byte in that set using portable `@Vector` code, so the
//! automaton is only woken at real candidates instead of probing every byte.
//!
//! Correctness: the SIMD predicate is derived *losslessly* from the bitmap
//! (every accelerated path is exactly equivalent to `inSet`), and chunks are
//! scanned in ascending order with `std.simd.firstTrue`, so `nextCandidate`
//! always returns the minimal in-set index >= pos. Match semantics
//! (leftmost-first) are preserved by construction.
//!
//! Portable across Linux x86_64 (SSE2/AVX2) and macOS ARM64 (NEON): one
//! codebase, no per-target branches, no inline asm — `@Vector` ops lower per
//! target and `suggestVectorLength` picks the lane count at comptime.

const std = @import("std");
const builtin = @import("builtin");

/// Vector lane count, chosen per target at comptime. `orelse 16` guards
/// targets where the query returns null (128-bit baseline).
const VLEN = std.simd.suggestVectorLength(u8) orelse 16;
const V = @Vector(VLEN, u8);
const Mask = @Vector(VLEN, bool);

// The Teddy kernel vector type/width is `VT`/`TW` (defined below): the
// 128-bit PSHUFB/TBL baseline, or 256-bit on AVX2 ("Fat Teddy"). It is
// independent of the prefilter scan's `V`/`VLEN`.

/// Base number of leading needle bytes the Teddy nibble masks cover. 3 is the
/// classic aho-corasick "Slim Teddy" choice; the effective count starts at
/// `min(min_needle_len, TEDDY_NMASK)` and `build` deepens it adaptively (see
/// `TEDDY_MAXMASK`) when needles share a short prefix.
const TEDDY_NMASK: usize = 3;

/// Adaptive cap for the Teddy prefix-mask depth. When the needle set shares a
/// `TEDDY_NMASK`-byte prefix the base filter is non-selective and every chunk
/// verify-storms; `build` then deepens `nmask` (still ≤ shortest needle) up to
/// this cap so the necessary condition stays discriminating. Pure scalar /
/// comptime-safe; the struct only grows by `(TEDDY_MAXMASK)*2*16` bytes.
const TEDDY_MAXMASK: usize = 8;

/// `FREQ` ceiling for a *letter* probe to count as robustly rare. 20 admits
/// `k q x z j v b` and damped-uppercase (`S`=16, `O`=19) while excluding
/// common letters. Digits/punctuation/space are excluded structurally (not by
/// `FREQ`) because their rarity is corpus-dependent — see `robustlyRareProbe`.
const MEMCHR_FREQ_MAX: u16 = 20;

/// A single-byte memchr is the fast path only when the probe is rare in
/// *arbitrary* input. Letters with low `FREQ` and any non-ASCII byte qualify;
/// digits, space and punctuation are deliberately excluded — they are
/// frequent in the machine text this engine targets (logs/HTML/URLs/code),
/// so memchr on them would stop at every occurrence and storm the verifier.
/// For those, the two-byte SIMD filter (`findOneSimd`) stays selective. `FREQ`
/// itself is left as the generic English model (perturbing it globally just
/// relocates the slow workload).
inline fn robustlyRareProbe(b: u8) bool {
    if (b >= 0x80) return true; // non-ASCII: rare in text ⇒ excellent probe
    const is_alpha = (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z');
    return is_alpha and FREQ[b] <= MEMCHR_FREQ_MAX;
}

/// Is a real SIMD byte-shuffle (the Teddy kernel primitive) available for the
/// build target? Decided entirely at comptime — no runtime per-target branch.
/// When false, the portable two-byte `@Vector` filter is the fast path.
const teddy_simd: bool = switch (builtin.cpu.arch) {
    .x86_64 => std.Target.x86.featureSetHas(builtin.cpu.features, .ssse3),
    .aarch64 => std.Target.aarch64.featureSetHas(builtin.cpu.features, .neon),
    else => false,
};

/// AVX2 256-bit "Fat Teddy": process 32 bytes per iteration via `vpshufb
/// ymm`. x86_64-only (NEON has no 256-bit shuffle); the 16-entry nibble
/// table is duplicated into *both* 128-bit lanes because `vpshufb` looks up
/// independently per 128-bit lane — correct here since indices are nibbles.
const teddy_avx2: bool = builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);

/// Teddy kernel width and its vector type: 32 on AVX2, else the 128-bit
/// baseline shared by SSSE3 PSHUFB and NEON TBL.
const TW: usize = if (teddy_avx2) 32 else 16;
const VT = @Vector(TW, u8);

/// Approximate byte-frequency weight (English text biased): common bytes
/// score high, rare bytes low. The rare-byte heuristic picks the needle
/// offset whose byte minimises this — a rarer second probe makes the SIMD
/// candidate filter far more selective on natural text. Used only by the
/// scalar, comptime-safe `Teddy.build`.
pub const FREQ: [256]u16 = blk: {
    var f = [_]u16{1} ** 256; // unknown/binary bytes: rare (good probes)
    // Letter frequencies (per-mille, Cornell/Lewand ordering), applied to
    // both cases; uppercase damped (rarer in running text).
    const letters = "etaoinshrdlcumwfgypbvkjxqz";
    const w = [_]u16{ 127, 91, 82, 75, 70, 67, 63, 61, 60, 43, 40, 28, 28, 24, 24, 22, 20, 20, 19, 15, 10, 8, 8, 2, 2, 1 };
    for (letters, 0..) |c, idx| {
        f[c] = w[idx]; // lowercase
        f[c - 32] = (w[idx] / 4) + 1; // uppercase: damped
    }
    f[' '] = 180;
    f['\n'] = 30;
    f['\t'] = 6;
    f[','] = 20;
    f['.'] = 20;
    f['0'] = 12;
    for ("123456789") |c| f[c] = 9;
    break :blk f;
};

/// Canonical 256-bit-set membership test. Every consumer routes through this
/// so the scalar predicate is identical everywhere.
pub inline fn inSet(set: *const [32]u8, c: u8) bool {
    return (set[c >> 3] & (@as(u8, 1) << @as(u3, @intCast(c & 7)))) != 0;
}

/// Canonical 256-bit-set insertion — the write-side counterpart of `inSet`,
/// so producers and consumers of a `[32]u8` set share one bit layout.
pub inline fn setBit(set: *[32]u8, c: u8) void {
    set[c >> 3] |= (@as(u8, 1) << @as(u3, @intCast(c & 7)));
}

/// Compact classification of the first-byte set, derived from the bitmap.
/// The kernels iterate exactly `n` real members/ranges (no padding work), so
/// the dominant single-range / few-byte cases cost one vector op per chunk.
pub const Prefilter = union(enum) {
    /// Exactly one byte — delegate to std's already-SIMD scalar memchr.
    single: u8,
    /// 2..=8 discrete bytes — vectorized multi-equality.
    multi: struct { b: [8]u8, n: u8 },
    /// 1..=8 byte ranges — vectorized unsigned range test.
    ranges: struct { lo: [8]u8, span: [8]u8, n: u8 },
    /// Pathological set — scalar bitmap loop.
    bitset,

    /// Classify the (already case-folded) bitmap. One pass over 32 bytes, no
    /// allocation. The optimizer guarantees `0 < popcount < 256`; a 0-bit set
    /// defensively falls back to `.bitset`.
    pub fn fromBitset(set: *const [32]u8) Prefilter {
        var members: [9]u8 = undefined;
        var nmem: usize = 0;
        var runs_lo: [9]u8 = undefined;
        var runs_hi: [9]u8 = undefined;
        var nruns: usize = 0;

        var c: usize = 0;
        while (c < 256) {
            if (inSet(set, @intCast(c))) {
                const start = c;
                while (c < 256 and inSet(set, @intCast(c))) : (c += 1) {
                    if (nmem < members.len) members[nmem] = @intCast(c);
                    nmem += 1;
                }
                if (nruns < runs_lo.len) {
                    runs_lo[nruns] = @intCast(start);
                    runs_hi[nruns] = @intCast(c - 1);
                }
                nruns += 1;
            } else {
                c += 1;
            }
        }

        if (nmem == 0) return .bitset; // defensive; optimizer forbids this
        if (nmem == 1) return .{ .single = members[0] };

        if (nmem <= 8) {
            var m: [8]u8 = .{0} ** 8;
            for (0..nmem) |i| m[i] = members[i];
            return .{ .multi = .{ .b = m, .n = @intCast(nmem) } };
        }

        if (nruns <= 8) {
            var lo: [8]u8 = .{0} ** 8;
            var span: [8]u8 = .{0} ** 8;
            for (0..nruns) |i| {
                lo[i] = runs_lo[i];
                span[i] = runs_hi[i] - runs_lo[i];
            }
            return .{ .ranges = .{ .lo = lo, .span = span, .n = @intCast(nruns) } };
        }

        return .bitset;
    }
};

/// Scalar fallback / tail: the minimal index in `input[pos..]` whose byte is
/// in `set`, or null. Identical predicate to `inSet`.
inline fn scalarScan(set: *const [32]u8, input: []const u8, pos: usize) ?usize {
    var i = pos;
    while (i < input.len) : (i += 1) {
        if (inSet(set, input[i])) return i;
    }
    return null;
}

/// Lane-wise 0x00 / 0xFF from a comparison result, so masks combine with a
/// single integer OR per term (NEON ORR / SSE POR) instead of a bool-vector
/// `@select` chain (which this toolchain scalarizes).
inline fn maskOf(cmp: Mask) V {
    return @select(u8, cmp, @as(V, @splat(0xFF)), @as(V, @splat(0)));
}

/// Index of the first set (non-zero) lane in an accumulated mask, or null.
/// The `@reduce` keeps the no-hit path (the overwhelming majority of chunks)
/// down to one horizontal-or; `firstTrue` runs only when a hit exists.
inline fn locate(acc: V) ?usize {
    if (@reduce(.Or, acc) == 0) return null;
    return @intCast(std.simd.firstTrue(acc != @as(V, @splat(0))).?);
}

/// THE single entry point. Returns the minimal index >= `pos` whose byte is in
/// `set`, or null if `input[pos..]` contains none. Leftmost-correct.
///
/// Classifies the set on every call (a 256-bit scan). Hot callers whose set
/// is fixed should classify once via `Prefilter.fromBitset` and call
/// `nextCandidatePF` to keep the per-call cost at the vector scan only.
pub fn nextCandidate(set: *const [32]u8, input: []const u8, pos: usize) ?usize {
    return nextCandidatePF(Prefilter.fromBitset(set), set, input, pos);
}

/// Pre-classified variant: same result as `nextCandidate` but takes an
/// already-computed `Prefilter` (e.g. baked at comptime), so the per-call
/// 256-bit `fromBitset` classification is skipped entirely. `set` is still
/// needed for the scalar tail / `.bitset` fallback (its membership is
/// identical to whatever produced `p`).
pub fn nextCandidatePF(p: Prefilter, set: *const [32]u8, input: []const u8, pos: usize) ?usize {
    if (pos >= input.len) return null;

    switch (p) {
        .single => |b| return std.mem.indexOfScalarPos(u8, input, pos, b),

        .multi => |m| {
            const n: usize = m.n;
            var splats: [8]V = undefined;
            for (0..n) |k| splats[k] = @splat(m.b[k]);
            var i = pos;
            while (i + VLEN <= input.len) : (i += VLEN) {
                const chunk: V = input[i..][0..VLEN].*;
                // OR per-term masks in the u8 domain (one ORR/POR each) — far
                // better codegen than chaining @select over bool vectors.
                var acc: V = maskOf(chunk == splats[0]);
                var k: usize = 1;
                while (k < n) : (k += 1) acc |= maskOf(chunk == splats[k]);
                if (locate(acc)) |lane| return i + lane;
            }
            return scalarScan(set, input, i);
        },

        .ranges => |r| {
            const n: usize = r.n;
            var lov: [8]V = undefined;
            var spanv: [8]V = undefined;
            for (0..n) |k| {
                lov[k] = @splat(r.lo[k]);
                spanv[k] = @splat(r.span[k]);
            }
            var i = pos;
            while (i + VLEN <= input.len) : (i += VLEN) {
                const chunk: V = input[i..][0..VLEN].*;
                // unsigned wrapping subtract: c in [lo, lo+span] <=> (c -% lo) <= span
                var acc: V = maskOf((chunk -% lov[0]) <= spanv[0]);
                var k: usize = 1;
                while (k < n) : (k += 1) acc |= maskOf((chunk -% lov[k]) <= spanv[k]);
                if (locate(acc)) |lane| return i + lane;
            }
            return scalarScan(set, input, i);
        },

        .bitset => return scalarScan(set, input, pos),
    }
}

/// Index of the first lane that is **zero** (byte NOT in set) in an accumulated
/// in-set mask, or null if every lane is in the set.
inline fn locateZero(acc: V) ?usize {
    const z: Mask = acc == @as(V, @splat(0));
    if (@reduce(.Or, maskOf(z)) == 0) return null;
    return @intCast(std.simd.firstTrue(z).?);
}

/// Scalar fallback / tail for `runEnd`: first index in `[pos, input.len]` whose
/// byte is NOT in `set` (== `input.len` if the run reaches EOF). Same predicate
/// as `inSet`.
inline fn scalarRunEnd(set: *const [32]u8, input: []const u8, pos: usize) usize {
    var i = pos;
    while (i < input.len and inSet(set, input[i])) : (i += 1) {}
    return i;
}

/// Symmetric to `nextCandidate`: the end of the maximal run of in-`set` bytes
/// starting at `pos` — i.e. the **minimal** index >= `pos` whose byte is NOT in
/// `set`, or `input.len` if every byte from `pos` to EOF is in `set`. Used by
/// the VM's greedy-class-loop fast path to bulk-consume a quantifier run in one
/// memory-bandwidth scan instead of one NFA step per byte. Derived from the
/// same bitmap as `inSet`, so it never overshoots a run boundary.
pub fn runEnd(set: *const [32]u8, input: []const u8, pos: usize) usize {
    if (pos >= input.len) return input.len;

    switch (Prefilter.fromBitset(set)) {
        .single => |b| {
            const bv: V = @splat(b);
            var i = pos;
            while (i + VLEN <= input.len) : (i += VLEN) {
                const chunk: V = input[i..][0..VLEN].*;
                if (locateZero(maskOf(chunk == bv))) |lane| return i + lane;
            }
            return scalarRunEnd(set, input, i);
        },

        .multi => |m| {
            const n: usize = m.n;
            var splats: [8]V = undefined;
            for (0..n) |k| splats[k] = @splat(m.b[k]);
            var i = pos;
            while (i + VLEN <= input.len) : (i += VLEN) {
                const chunk: V = input[i..][0..VLEN].*;
                var acc: V = maskOf(chunk == splats[0]);
                var k: usize = 1;
                while (k < n) : (k += 1) acc |= maskOf(chunk == splats[k]);
                if (locateZero(acc)) |lane| return i + lane;
            }
            return scalarRunEnd(set, input, i);
        },

        .ranges => |r| {
            const n: usize = r.n;
            var lov: [8]V = undefined;
            var spanv: [8]V = undefined;
            for (0..n) |k| {
                lov[k] = @splat(r.lo[k]);
                spanv[k] = @splat(r.span[k]);
            }
            var i = pos;
            while (i + VLEN <= input.len) : (i += VLEN) {
                const chunk: V = input[i..][0..VLEN].*;
                var acc: V = maskOf((chunk -% lov[0]) <= spanv[0]);
                var k: usize = 1;
                while (k < n) : (k += 1) acc |= maskOf((chunk -% lov[k]) <= spanv[k]);
                if (locateZero(acc)) |lane| return i + lane;
            }
            return scalarRunEnd(set, input, i);
        },

        .bitset => return scalarRunEnd(set, input, pos),
    }
}

// ===========================================================================
// Tests
// ===========================================================================

fn setRange(set: *[32]u8, lo: u8, hi: u8) void {
    var c: usize = lo;
    while (c <= hi) : (c += 1) setBit(set, @intCast(c));
}

test "fromBitset classification" {
    // single
    {
        var s = std.mem.zeroes([32]u8);
        setBit(&s, 'x');
        try std.testing.expect(Prefilter.fromBitset(&s) == .single);
        try std.testing.expectEqual(@as(u8, 'x'), Prefilter.fromBitset(&s).single);
    }
    // multi: 4 scattered discrete bytes (cat|dog|bird|fish -> {b,c,d,f})
    {
        var s = std.mem.zeroes([32]u8);
        for ("bcdf") |b| setBit(&s, b);
        const pf = Prefilter.fromBitset(&s);
        try std.testing.expect(pf == .multi);
        try std.testing.expectEqual(@as(u8, 4), pf.multi.n);
        try std.testing.expectEqualSlices(u8, "bcdf", pf.multi.b[0..4]);
    }
    // ranges(1): \d
    {
        var s = std.mem.zeroes([32]u8);
        setRange(&s, '0', '9');
        try std.testing.expect(Prefilter.fromBitset(&s) == .ranges);
    }
    // ranges(4): \w  = [0-9][A-Z]_[a-z]
    {
        var s = std.mem.zeroes([32]u8);
        setRange(&s, '0', '9');
        setRange(&s, 'A', 'Z');
        setBit(&s, '_');
        setRange(&s, 'a', 'z');
        try std.testing.expect(Prefilter.fromBitset(&s) == .ranges);
    }
    // bitset fallback: >8 scattered runs of >8 members total
    {
        var s = std.mem.zeroes([32]u8);
        var c: usize = 0;
        while (c < 256) : (c += 16) setBit(&s, @intCast(c)); // 16 isolated members/runs
        try std.testing.expect(Prefilter.fromBitset(&s) == .bitset);
    }
}

/// Reference scan: minimal in-set index >= pos via the canonical predicate.
fn refScan(set: *const [32]u8, input: []const u8, pos: usize) ?usize {
    var i = pos;
    while (i < input.len) : (i += 1) if (inSet(set, input[i])) return i;
    return null;
}

test "nextCandidate matches reference scan (differential, leftmost)" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rnd = prng.random();

    var sets: [4][32]u8 = undefined;
    for (&sets) |*s| s.* = std.mem.zeroes([32]u8);
    setBit(&sets[0], 'x'); // single
    for ("aqz0") |b| setBit(&sets[1], b); // multi
    setRange(&sets[2], '0', '9'); // ranges
    {
        var c: usize = 0;
        while (c < 256) : (c += 16) setBit(&sets[3], @intCast(c)); // bitset
    }

    const lengths = [_]usize{ VLEN - 1, VLEN, VLEN + 1, 2 * VLEN, 4096, 4097 };
    const alloc = std.testing.allocator;

    for (&sets) |*s| {
        for (lengths) |len| {
            const buf = try alloc.alloc(u8, len);
            defer alloc.free(buf);
            for (buf) |*b| b.* = rnd.int(u8);
            // Sparsely sprinkle guaranteed members so hits actually occur.
            var k: usize = 0;
            while (k < len) : (k += 37) buf[k] = if (inSet(s, 'x')) 'x' else blk: {
                var c: u8 = 0;
                while (!inSet(s, c)) c +%= 1;
                break :blk c;
            };

            var p: usize = 0;
            while (true) {
                const got = nextCandidate(s, buf, p);
                const want = refScan(s, buf, p);
                try std.testing.expectEqual(want, got);
                if (got == null) break;
                p = got.? + 1;
                if (p > len) break;
            }
        }
    }
}

/// Reference: first index >= pos NOT in set (== len if run reaches EOF).
fn refRunEnd(set: *const [32]u8, input: []const u8, pos: usize) usize {
    var i = pos;
    while (i < input.len and inSet(set, input[i])) : (i += 1) {}
    return i;
}

test "runEnd matches reference (differential, no overshoot)" {
    var prng = std.Random.DefaultPrng.init(0x5EED);
    const rnd = prng.random();

    var sets: [4][32]u8 = undefined;
    for (&sets) |*s| s.* = std.mem.zeroes([32]u8);
    setBit(&sets[0], 'a'); // single ('a+' run)
    for ("aqz0") |b| setBit(&sets[1], b); // multi
    setRange(&sets[2], '0', '9'); // ranges ('[0-9]+' run)
    {
        var c: usize = 0;
        while (c < 256) : (c += 16) setBit(&sets[3], @intCast(c)); // bitset
    }

    const lengths = [_]usize{ VLEN - 1, VLEN, VLEN + 1, 2 * VLEN, 4096, 4097 };
    const alloc = std.testing.allocator;

    for (&sets) |*s| {
        // pick a guaranteed in-set byte to build long runs from
        var member: u8 = 0;
        while (!inSet(s, member)) member += 1;

        for (lengths) |len| {
            const buf = try alloc.alloc(u8, len);
            defer alloc.free(buf);
            // Mostly long in-set runs, with random out-of-set breaks.
            for (buf) |*b| b.* = member;
            var k: usize = 13;
            while (k < len) : (k += 29 + (rnd.int(u8) % 64)) {
                var c = rnd.int(u8);
                while (inSet(s, c)) c +%= 1; // force a genuine non-member
                buf[k] = c;
            }

            // Check every starting position (runEnd must never overshoot the
            // first non-member, and must reach len iff the rest is all in-set).
            for (0..len + 1) |p| {
                try std.testing.expectEqual(refRunEnd(s, buf, p), runEnd(s, buf, p));
            }
        }
    }
}

// --- Teddy multi-substring prefilter ---------------------------------------
//
// A *necessary-condition* candidate finder for a small set of literal
// needles (e.g. an `a|bc|def` alternation, or a multi-literal prefix). It
// reuses the SIMD first-byte scan over the union of every needle's first
// byte, then verifies a real needle occurrence at the candidate, so it never
// reports a position where no needle actually starts. The engine still
// re-runs from the returned offset, so an over-approximation stays correct.
//
// This is the building block the planner's literal / prefix-prefilter
// strategies consume; the SIMD Teddy kernel must keep matching this
// scalar-verified baseline.

/// 16-byte table lookup (one instruction): `out[k] = table[idx[k] & 0x0F]`
/// for our nibble indices (0..15) — PSHUFB on x86_64 SSSE3, TBL on aarch64
/// NEON. Both zero a lane whose index has bit7 set / is >=16; our indices are
/// nibbles so the two are bit-identical. Arch is selected by a *comptime*
/// switch, so only the target's prong is analysed/emitted (no per-target
/// runtime branch; non-shuffle targets never reference this).
/// One-instruction byte shuffle `out[k] = table[idx[k] & 0x0F]` (our indices
/// are nibbles). Width = `TW` (16 baseline, 32 on AVX2). The arch/feature
/// branch is a *comptime* switch — only the target's prong is analysed/emitted.
const shuf = switch (builtin.cpu.arch) {
    .aarch64 => struct {
        inline fn f(table: VT, idx: VT) VT {
            return asm ("tbl %[o].16b, {%[t].16b}, %[i].16b"
                : [o] "=w" (-> VT),
                : [t] "w" (table),
                  [i] "w" (idx),
            );
        }
    }.f,
    .x86_64 => if (teddy_avx2) struct {
        // 3-operand AVX2: ymm = vpshufb(table, idx), per-128-lane lookup.
        inline fn f(table: VT, idx: VT) VT {
            return asm ("vpshufb %[i], %[t], %[o]"
                : [o] "=x" (-> VT),
                : [t] "x" (table),
                  [i] "x" (idx),
            );
        }
    }.f else struct {
        inline fn f(table: VT, idx: VT) VT {
            var t = table;
            asm ("pshufb %[i], %[t]"
                : [t] "+x" (t),
                : [i] "x" (idx),
            );
            return t;
        }
    }.f,
    else => struct {
        inline fn f(_: VT, _: VT) VT {
            unreachable;
        }
    }.f,
};

/// Tile a 16-entry nibble table across the kernel width. For `TW==16` this is
/// the identity; for `TW==32` the table is duplicated into both 128-bit lanes
/// (required by AVX2 `vpshufb`'s per-lane semantics — sound because the
/// indices are nibbles 0..15).
inline fn tileTable(m: [16]u8) VT {
    if (TW == 16) return m;
    var out: [TW]u8 = undefined;
    inline for (0..TW) |k| out[k] = m[k & 15];
    return out;
}

pub const Teddy = struct {
    pub const MAX_NEEDLES: usize = 8;
    pub const MAX_LEN: usize = 64;

    pat: [MAX_NEEDLES][MAX_LEN]u8 = [_][MAX_LEN]u8{[_]u8{0} ** MAX_LEN} ** MAX_NEEDLES,
    len: [MAX_NEEDLES]u8 = [_]u8{0} ** MAX_NEEDLES,
    n: u8 = 0,
    first: [32]u8 = [_]u8{0} ** 32,

    // --- two-byte filter (rare-byte heuristic), one entry per needle ---
    /// First byte of needle w (== pat[w][0]); kept explicit so the hot loop
    /// never indexes `pat`.
    b1: [MAX_NEEDLES]u8 = [_]u8{0} ** MAX_NEEDLES,
    /// The statistically rarest byte within needle w (by `FREQ`).
    b2: [MAX_NEEDLES]u8 = [_]u8{0} ** MAX_NEEDLES,
    /// Offset of `b2` within needle w. `0` sentinel when len==1 (unused).
    o: [MAX_NEEDLES]u8 = [_]u8{0} ** MAX_NEEDLES,
    /// True iff every needle has len>=2 (so the 2-byte filter / Teddy are
    /// sound for the whole set; a len-1 needle has no decorrelated 2nd byte).
    all_ge2: bool = false,
    /// Single-needle (n==1, len>=2) dispatch: use the std-memchr-on-rare-byte
    /// `findOneMemchr` iff the probe is a `robustlyRareProbe` (rare letter or
    /// non-ASCII). For prefixes of all-common bytes (`eni-`, `href="`,
    /// `<h2 …>`) no such byte exists, so the selective two-byte SIMD filter
    /// (`findOneSimd`) wins — single-byte memchr would storm. Baked at build.
    one_memchr: bool = false,

    // --- Teddy nibble masks (8 buckets = 1 bit per needle) ---
    mask_lo: [TEDDY_MAXMASK][16]u8 = [_][16]u8{[_]u8{0} ** 16} ** TEDDY_MAXMASK,
    mask_hi: [TEDDY_MAXMASK][16]u8 = [_][16]u8{[_]u8{0} ** 16} ** TEDDY_MAXMASK,
    /// Mask bytes actually used: starts at min(min_len, TEDDY_NMASK) and is
    /// deepened by `build` (≤ min_len, ≤ TEDDY_MAXMASK) until the prefixes
    /// separate the needle set, so the necessary condition stays selective.
    nmask: u8 = 0,

    // --- Fix 3: per-needle scan vectors baked once at `build` time ---
    // `find` is called once per match (`count`/`nextSpanFrom` loop), so
    // re-deriving these splats / tiled nibble tables on every call was a
    // per-call tax on dense-hit workloads. `build` is comptime-evaluable, so
    // these are materialised at pattern-compile time and the hot finders just
    // read them.
    /// `@splat(b1[k])` — first byte of needle k, broadcast.
    splat_b1: [MAX_NEEDLES]V = [_]V{@splat(0)} ** MAX_NEEDLES,
    /// `@splat(b2[k])` — rare byte of needle k, broadcast.
    splat_b2: [MAX_NEEDLES]V = [_]V{@splat(0)} ** MAX_NEEDLES,
    /// `@splat(1 << k)` — needle k's bucket bit, broadcast (findMulti).
    splat_bit: [MAX_NEEDLES]V = [_]V{@splat(0)} ** MAX_NEEDLES,
    /// max rare-byte offset across needles (findMulti loop bound).
    maxo: usize = 0,
    /// Width-tiled low/high nibble tables (findTeddy); on AVX2 this also
    /// bakes the both-128-lane duplication once instead of per call.
    tlv: [TEDDY_MAXMASK]VT = [_]VT{@splat(0)} ** TEDDY_MAXMASK,
    thv: [TEDDY_MAXMASK]VT = [_]VT{@splat(0)} ** TEDDY_MAXMASK,

    pub const Hit = struct { start: usize, which: u8 };

    /// Build from a slice of needles. Returns null if it cannot represent the
    /// set (too many / too long / an empty needle, which would defeat the
    /// prefilter). Pure scalar — comptime-evaluable (pattern.zig bakes it).
    pub fn build(needles: []const []const u8) ?Teddy {
        if (needles.len == 0 or needles.len > MAX_NEEDLES) return null;
        var t = Teddy{};
        var min_len: usize = MAX_LEN;
        var ge2 = true;
        for (needles, 0..) |nd, i| {
            if (nd.len == 0 or nd.len > MAX_LEN) return null;
            for (nd, 0..) |b, j| t.pat[i][j] = b;
            t.len[i] = @intCast(nd.len);
            setBit(&t.first, nd[0]);
            t.b1[i] = nd[0];
            if (nd.len >= 2) {
                // Rarest byte → most selective second probe. Tie: prefer the
                // larger offset (more decorrelated from the first byte).
                var best: usize = 0;
                var bestf: u16 = FREQ[nd[0]];
                for (nd, 0..) |b, j| {
                    if (FREQ[b] <= bestf) {
                        bestf = FREQ[b];
                        best = j;
                    }
                }
                t.o[i] = @intCast(best);
                t.b2[i] = nd[best];
            } else {
                ge2 = false;
                t.o[i] = 0;
                t.b2[i] = nd[0];
            }
            if (nd.len < min_len) min_len = nd.len;
        }
        t.n = @intCast(needles.len);
        t.all_ge2 = ge2;
        t.one_memchr = t.n == 1 and t.len[0] >= 2 and robustlyRareProbe(t.b2[0]);

        // Adaptive prefix depth: start at the Slim-Teddy base, then deepen
        // while some needle pair shares the whole nm-byte prefix (the filter
        // would be non-selective there and verification would storm — the
        // case full Aho-Corasick targets). Bounded by the shortest needle and
        // TEDDY_MAXMASK. Pure scalar (n≤8, len≤64) ⇒ comptime-evaluable.
        var nm: usize = @min(min_len, TEDDY_NMASK);
        const cap: usize = @min(min_len, TEDDY_MAXMASK);
        while (nm < cap) : (nm += 1) {
            var collide = false;
            var a: usize = 0;
            while (a < needles.len and !collide) : (a += 1) {
                var b: usize = a + 1;
                while (b < needles.len) : (b += 1) {
                    if (std.mem.eql(u8, needles[a][0..nm], needles[b][0..nm])) {
                        collide = true;
                        break;
                    }
                }
            }
            if (!collide) break;
        }
        t.nmask = @intCast(nm);
        for (needles, 0..) |nd, i| {
            const bit: u8 = @as(u8, 1) << @as(u3, @intCast(i));
            var j: usize = 0;
            while (j < nm) : (j += 1) {
                const c = nd[j];
                t.mask_lo[j][c & 0x0F] |= bit;
                t.mask_hi[j][c >> 4] |= bit;
            }
        }
        // Fix 3: bake the per-needle scan vectors once (build is comptime).
        for (0..t.n) |k| {
            t.splat_b1[k] = @splat(t.b1[k]);
            t.splat_b2[k] = @splat(t.b2[k]);
            t.splat_bit[k] = @splat(@as(u8, 1) << @as(u3, @intCast(k)));
            if (t.o[k] > t.maxo) t.maxo = t.o[k];
        }
        for (0..t.nmask) |j| {
            t.tlv[j] = tileTable(t.mask_lo[j]);
            t.thv[j] = tileTable(t.mask_hi[j]);
        }
        return t;
    }

    /// Earliest-declared needle that matches at absolute position `cand`, or
    /// null. THE authoritative predicate — every fast path funnels here, so
    /// semantics are byte-identical to the original scalar matcher.
    inline fn verifyAt(self: *const Teddy, input: []const u8, cand: usize) ?Hit {
        var w: usize = 0;
        while (w < self.n) : (w += 1) {
            const L = self.len[w];
            if (cand + L <= input.len and
                std.mem.eql(u8, input[cand .. cand + L], self.pat[w][0..L]))
            {
                return .{ .start = cand, .which = @intCast(w) };
            }
        }
        return null;
    }

    /// Verify only the candidate needles flagged in `bucket` (bit `w` ⇒ needle
    /// `w`'s prefix matched at `cand`), in ascending = declared order. This is
    /// `verifyAt`'s predicate restricted to a sound *superset* of the truly
    /// matching needles (any real match has its prefix bits set), so it
    /// returns the identical `(start, which)` while running ≈1 `std.mem.eql`
    /// instead of `n` — the dominant alternation cost. `bucket != 0` always
    /// here (callers gate on a nonzero lane).
    inline fn verifyBucket(self: *const Teddy, input: []const u8, cand: usize, bucket: u8) ?Hit {
        var b = bucket;
        while (b != 0) {
            const w: usize = @ctz(b);
            const L = self.len[w];
            if (cand + L <= input.len and
                std.mem.eql(u8, input[cand .. cand + L], self.pat[w][0..L]))
            {
                return .{ .start = cand, .which = @intCast(w) };
            }
            b &= b - 1; // clear lowest set bit → next candidate, ascending
        }
        return null;
    }

    /// Verbatim original algorithm (first-byte union scan + declared-order
    /// verify). Parity oracle, definitive scalar tail for every fast path,
    /// and the fallback for shapes the SIMD paths decline.
    fn findScalarRef(self: *const Teddy, input: []const u8, pos: usize) ?Hit {
        var i = pos;
        while (nextCandidate(&self.first, input, i)) |cand| {
            if (self.verifyAt(input, cand)) |h| return h;
            i = cand + 1;
        }
        return null;
    }

    /// Single-needle (len>=2) SIMD memmem. Locate the statistically rarest
    /// needle byte `b2` (at fixed offset `o`) with std's already-wide memchr,
    /// then declared-order verify the full needle at the implied start. This
    /// reuses the tuned `indexOfScalarPos` instead of a hand-rolled,
    /// non-unrolled two-byte vector loop.
    ///
    /// Leftmost-correct: a needle occurrence at start `s` has its `b2` at the
    /// fixed absolute position `s + o`, so `b2` positions scanned ascending
    /// map monotonically to candidate starts — the first that `verifyBucket`
    /// confirms is the minimal match start ≥ `pos`. `verifyBucket` is
    /// authoritative and bounds-checked, so this needs no scalar tail.
    fn findOneMemchr(self: *const Teddy, input: []const u8, pos: usize) ?Hit {
        const o: usize = self.o[0];
        const b2: u8 = self.b2[0];
        var p = pos + o; // earliest possible `b2` position for a start ≥ pos
        if (p > input.len) return null; // needle can't fit ⇒ no match
        while (std.mem.indexOfScalarPos(u8, input, p, b2)) |hit| {
            // Single needle ⇒ bucket is constant bit 0. `hit - o` ≥ pos.
            if (self.verifyBucket(input, hit - o, 1)) |h| return h;
            p = hit + 1;
        }
        return null;
    }

    /// Original two-byte SIMD filter (first byte AND rare byte at offset `o`),
    /// then declared-order verify. Kept for single needles whose probe byte is
    /// *common* (`one_memchr == false`): ANDing two byte tests stays selective
    /// even when each byte alone is frequent, where a single-byte memchr would
    /// stop at every occurrence and storm the verifier.
    fn findOneSimd(self: *const Teddy, input: []const u8, pos: usize) ?Hit {
        const o: usize = self.o[0];
        const f: V = self.splat_b1[0];
        const s2: V = self.splat_b2[0];
        var i = pos;
        while (i + o + VLEN <= input.len) : (i += VLEN) {
            const c0: V = input[i..][0..VLEN].*;
            const c1: V = input[i + o ..][0..VLEN].*;
            const cand: V = maskOf(c0 == f) & maskOf(c1 == s2);
            if (@reduce(.Or, cand) != 0) {
                const lanes: [VLEN]u8 = cand;
                var lane: usize = 0;
                while (lane < VLEN) : (lane += 1) {
                    if (lanes[lane] != 0) {
                        if (self.verifyBucket(input, i + lane, 1)) |h| return h;
                    }
                }
            }
        }
        return self.findScalarRef(input, i);
    }

    /// Multi-needle (n in 2..8, all len>=2) portable two-byte filter: OR each
    /// needle's (first byte AND rare byte) mask, then declared-order verify.
    fn findMulti(self: *const Teddy, input: []const u8, pos: usize) ?Hit {
        const n: usize = self.n;
        // Fix 3: per-needle splats / bitmasks / maxo baked at `build` time.
        const fv = &self.splat_b1;
        const s2v = &self.splat_b2;
        const bitv = &self.splat_bit;
        const maxo: usize = self.maxo;
        var i = pos;
        while (i + maxo + VLEN <= input.len) : (i += VLEN) {
            const c0: V = input[i..][0..VLEN].*;
            var acc: V = maskOf(c0 == fv[0]) &
                maskOf(@as(V, input[i + self.o[0] ..][0..VLEN].*) == s2v[0]) & bitv[0];
            var k: usize = 1;
            while (k < n) : (k += 1) {
                const ck: V = input[i + self.o[k] ..][0..VLEN].*;
                acc |= maskOf(c0 == fv[k]) & maskOf(ck == s2v[k]) & bitv[k];
            }
            if (@reduce(.Or, acc) != 0) {
                const lanes: [VLEN]u8 = acc;
                var lane: usize = 0;
                while (lane < VLEN) : (lane += 1) {
                    if (lanes[lane] != 0) {
                        if (self.verifyBucket(input, i + lane, lanes[lane])) |h| return h;
                    }
                }
            }
        }
        return self.findScalarRef(input, i);
    }

    /// True Teddy mask kernel (arch byte-shuffle). For each of the first
    /// `nmask` needle bytes, two nibble→bucket-mask shuffles AND together;
    /// ANDing across byte positions leaves, per start lane, the bucket bits
    /// of needles whose first `nmask` bytes all match. `verifyBucket` is
    /// authoritative, so nibble-collision false positives only cost speed.
    fn findTeddy(self: *const Teddy, input: []const u8, pos: usize) ?Hit {
        const nm: usize = self.nmask; // ≥2 (all_ge2 ⇒ min_len≥2); ≤ min_len
        const lo4: VT = @splat(0x0F);
        const sh4: @Vector(TW, u3) = @splat(4);
        // Fix 3: tiled nibble tables baked at `build` time (also bakes the
        // AVX2 both-128-lane duplication once instead of per call).
        const tlv = &self.tlv;
        const thv = &self.thv;
        var i = pos;
        while (i + (nm - 1) + TW <= input.len) : (i += TW) {
            var cand: VT = maskAt(input, i, 0, tlv[0], thv[0], lo4, sh4);
            var j: usize = 1;
            while (j < nm) : (j += 1) {
                cand &= maskAt(input, i, j, tlv[j], thv[j], lo4, sh4);
            }
            if (@reduce(.Or, cand) != 0) {
                const lanes: [TW]u8 = cand;
                var lane: usize = 0;
                while (lane < TW) : (lane += 1) {
                    if (lanes[lane] != 0) {
                        // `cand[lane]` is the per-needle candidate bitmask.
                        if (self.verifyBucket(input, i + lane, lanes[lane])) |h| return h;
                    }
                }
            }
        }
        return self.findScalarRef(input, i);
    }

    /// Per-needle candidate bitmask at needle-byte position `j` for every
    /// start lane in the `TW`-byte window at `i`. Loading the chunk at offset
    /// `j` aligns lane `k` with input[i+k+j] — exactly byte `j` of a needle
    /// starting at `i+k` — so no Teddy lane-shift is needed. `tl`/`th` are the
    /// width-tiled nibble tables (duplicated per 128-bit lane on AVX2).
    inline fn maskAt(input: []const u8, i: usize, j: usize, tl: VT, th: VT, lo4: VT, sh4: @Vector(TW, u3)) VT {
        const chunk: VT = input[i + j ..][0..TW].*;
        const lo = chunk & lo4;
        const hi = chunk >> sh4;
        return shuf(tl, lo) & shuf(th, hi);
    }

    /// Next position >= `pos` at which some needle occurs, or null. Leftmost
    /// across positions; at a tie returns the earliest-declared needle.
    pub fn find(self: *const Teddy, input: []const u8, pos: usize) ?Hit {
        if (pos >= input.len) return null;
        if (self.n == 1) {
            if (self.len[0] == 1) {
                return if (std.mem.indexOfScalarPos(u8, input, pos, self.b1[0])) |s|
                    Hit{ .start = s, .which = 0 }
                else
                    null;
            }
            return if (self.one_memchr) self.findOneMemchr(input, pos) else self.findOneSimd(input, pos);
        }
        if (!self.all_ge2) return self.findScalarRef(input, pos);
        if (teddy_simd) return self.findTeddy(input, pos);
        return self.findMulti(input, pos);
    }
};

test "teddy: multi-substring find matches a naive scan" {
    const needles = [_][]const u8{ "cat", "dog", "bird" };
    const t = Teddy.build(&needles).?;
    const hay = "a cat and a dog saw a bird; cathedral";

    // Reference: leftmost needle occurrence from each position.
    var pos: usize = 0;
    var found: usize = 0;
    while (t.find(hay, pos)) |hit| {
        try std.testing.expect(std.mem.startsWith(u8, hay[hit.start..], needles[hit.which]));
        found += 1;
        pos = hit.start + 1;
    }
    // cat@2, dog@12, bird@22, cat@28 (in "cathedral")
    try std.testing.expectEqual(@as(usize, 4), found);
}

test "teddy: build rejects degenerate inputs" {
    try std.testing.expect(Teddy.build(&[_][]const u8{}) == null);
    try std.testing.expect(Teddy.build(&[_][]const u8{ "ok", "" }) == null);
    const big = "x" ** (Teddy.MAX_LEN + 1);
    try std.testing.expect(Teddy.build(&[_][]const u8{big}) == null);
}

test "teddy: SIMD find == scalar reference (differential, leftmost+order)" {
    var prng = std.Random.DefaultPrng.init(0x7EDD1);
    const rnd = prng.random();
    const alloc = std.testing.allocator;

    const sets = [_][]const []const u8{
        &.{"xy"}, // single short
        &.{"Sherlock"}, // single long
        &.{"aaaa"}, // single repetitive (first==last)
        &.{"z"}, // single len-1 (memchr delegation)
        &.{ "cat", "dog", "bird", "fish" }, // multi varying-len
        &.{ "ab", "cd", "ef" }, // multi same-len
        &.{ "cat", "cathedral" }, // prefix pair, declared order
        &.{ "cathedral", "cat" }, // prefix pair, reversed (tie → earliest)
        &.{ "abc", "abd" }, // share first+second byte, stress filter
        &.{ "ab", "x" }, // mixed len-1 → all_ge2=false fallback
        &.{ "aXa", "aYa" }, // first==last, differing middle
        &.{ "the", "and", "ing", "ion", "ent", "for", "her", "tha" }, // 8 needles
        // C: prefix-colliding long needles → adaptive nmask deepens to cap.
        &.{ "internation", "internationale", "internationalize" },
        // C: 8 needles sharing a 6-byte prefix → nmask deepens to 7.
        &.{ "prefixaa", "prefixbb", "prefixcc", "prefixdd", "prefixee", "prefixff", "prefixgg", "prefixhh" },
        // single long repetitive, longer than the 32-wide kernel window.
        &.{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
    };
    // Includes 16/32-wide kernel boundaries (16,17,31,32,33) and the
    // portable-VLEN boundaries.
    const lengths = [_]usize{ 15, 16, 17, 31, 32, 33, VLEN - 1, VLEN, VLEN + 1, 2 * VLEN, 4096, 4097 };

    for (sets) |needles| {
        const t = Teddy.build(needles).?;
        // Alphabet biased to needle bytes so hits actually occur.
        var alpha: [16]u8 = undefined;
        var ai: usize = 0;
        for (needles) |nd| for (nd) |b| {
            if (ai < alpha.len) {
                alpha[ai] = b;
                ai += 1;
            }
        };
        while (ai < alpha.len) : (ai += 1) alpha[ai] = 'A' + @as(u8, @intCast(ai));

        for (lengths) |len| {
            const buf = try alloc.alloc(u8, len);
            defer alloc.free(buf);
            for (buf) |*c| c.* = alpha[rnd.int(usize) % alpha.len];
            // Sprinkle whole needles to force boundary-crossing hits.
            var k: usize = 0;
            while (k + 12 < len) : (k += 17) {
                const nd = needles[rnd.int(usize) % needles.len];
                if (k + nd.len <= len) @memcpy(buf[k..][0..nd.len], nd);
            }

            // Full leftmost iteration must match step-for-step from EVERY pos.
            for (0..len + 1) |start_pos| {
                var p = start_pos;
                while (true) {
                    const got = t.find(buf, p);
                    const want = t.findScalarRef(buf, p);
                    try std.testing.expectEqual(want != null, got != null);
                    if (want == null) break;
                    try std.testing.expectEqual(want.?.start, got.?.start);
                    try std.testing.expectEqual(want.?.which, got.?.which);
                    p = want.?.start + 1;
                    if (p > len) break;
                }
            }
        }
    }
}

// --- Aho-Corasick multi-substring prefilter ---------------------------------
//
// Teddy is fastest for a few short needles; Aho-Corasick wins when there are
// many needles or long ones (one linear pass, no per-candidate re-verify).
// Both are *necessary-condition* candidate finders — the engine re-runs from
// the reported offset, so an over-approximation is still correct.

pub const AhoCorasick = struct {
    pub const MAX_NODES: usize = 1024;

    // goto[node][byte] -> child node (0 = none, root = 0 is fine since root is
    // never a goto target). fail[node] -> failure link. out_len[node] -> the
    // length of a needle ending here (0 = none); ties keep the shortest so the
    // reported start is the earliest possible (still a sound prefilter).
    goto: [MAX_NODES][256]u16 = [_][256]u16{[_]u16{0} ** 256} ** MAX_NODES,
    fail: [MAX_NODES]u16 = [_]u16{0} ** MAX_NODES,
    out_len: [MAX_NODES]u16 = [_]u16{0} ** MAX_NODES,
    n_nodes: usize = 1, // node 0 = root

    pub const Hit = struct { start: usize, len: usize };

    /// Build from needles. Returns null if it would exceed the node budget or
    /// any needle is empty.
    pub fn build(needles: []const []const u8) ?AhoCorasick {
        var ac = AhoCorasick{};
        for (needles) |nd| {
            if (nd.len == 0) return null;
            var cur: u16 = 0;
            for (nd) |b| {
                if (ac.goto[cur][b] == 0) {
                    if (ac.n_nodes >= MAX_NODES) return null;
                    ac.goto[cur][b] = @intCast(ac.n_nodes);
                    ac.n_nodes += 1;
                }
                cur = ac.goto[cur][b];
            }
            if (ac.out_len[cur] == 0 or nd.len < ac.out_len[cur]) {
                ac.out_len[cur] = @intCast(nd.len);
            }
        }
        // BFS to compute failure links + propagate outputs.
        var queue: [MAX_NODES]u16 = undefined;
        var qh: usize = 0;
        var qt: usize = 0;
        var c: usize = 0;
        while (c < 256) : (c += 1) {
            const ch = ac.goto[0][c];
            if (ch != 0) {
                ac.fail[ch] = 0;
                queue[qt] = ch;
                qt += 1;
            }
        }
        while (qh < qt) {
            const u = queue[qh];
            qh += 1;
            var b: usize = 0;
            while (b < 256) : (b += 1) {
                const v = ac.goto[u][b];
                if (v == 0) {
                    ac.goto[u][b] = ac.goto[ac.fail[u]][@intCast(b)];
                } else {
                    ac.fail[v] = ac.goto[ac.fail[u]][@intCast(b)];
                    if (ac.out_len[v] == 0 and ac.out_len[ac.fail[v]] != 0) {
                        ac.out_len[v] = ac.out_len[ac.fail[v]];
                    }
                    queue[qt] = v;
                    qt += 1;
                }
            }
        }
        return ac;
    }

    /// First needle occurrence at/after `pos`, or null. One linear pass.
    pub fn find(self: *const AhoCorasick, input: []const u8, pos: usize) ?Hit {
        var node: u16 = 0;
        var i = pos;
        while (i < input.len) : (i += 1) {
            node = self.goto[node][input[i]];
            const l = self.out_len[node];
            if (l != 0) return .{ .start = i + 1 - l, .len = l };
        }
        return null;
    }
};

test "aho-corasick: finds leftmost needle == naive scan" {
    const needles = [_][]const u8{ "he", "she", "his", "hers" };
    const ac = AhoCorasick.build(&needles).?;
    const hay = "ushers say his name; hershey";

    var pos: usize = 0;
    var hits: usize = 0;
    while (ac.find(hay, pos)) |h| {
        // Verify it really is one of the needles.
        var ok = false;
        for (needles) |nd| {
            if (h.len == nd.len and std.mem.eql(u8, hay[h.start .. h.start + h.len], nd)) ok = true;
        }
        try std.testing.expect(ok);
        hits += 1;
        pos = h.start + 1;
    }
    try std.testing.expect(hits >= 3);
}

test "aho-corasick: rejects degenerate needles" {
    try std.testing.expect(AhoCorasick.build(&[_][]const u8{ "a", "" }) == null);
}
