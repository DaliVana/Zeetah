//! SIMD byte-class span scanner for the trivial shape `class+` / `class*`
//! (the *whole* unanchored pattern is one greedy repetition of a single
//! byte class — `[0-9]+`, `\w+`, `.+`, `[^/\s?#]+`, …). The match is just a
//! maximal run of class members, so no automaton is needed.
//!
//! Two scanners live here:
//!
//! * `Class` — the `.class_span` executor. Classifies **64 bytes at a time
//!   into one `u64` membership bitmask** and answers every query with bit
//!   arithmetic on it: the next member is a `ctz`, a run end is a `ctz` of
//!   the complement, the run starts of a block are `m & ~(m << 1 | carry)`
//!   (so `count` is a `popCount` per block, with no per-run branch at all).
//!   One mask serves every short run inside the block, which is what makes
//!   dense / short-run classes (`\w+`, words ≈ 5 B) cheap — the per-run cost
//!   is a few scalar bit ops, not a vector scan re-started per run.
//!   On AArch64 the mask is built without a `PMOVMSKB` (NEON has none): an
//!   `ld4` de-interleaving load + a `sri` chain + one `shrn` yields the
//!   natural-order 64-bit mask in ~10 instructions. On x86_64 it is four
//!   `pmovmskb`.
//! * `Ranges` — the original 16-byte range scanner (`@reduce(.Max/.Min)` +
//!   a ≤16-byte scalar finish), still used by the backtracker's `seek`
//!   prefilter and the compiled backtracker.

const std = @import("std");
const common = @import("../common.zig");
const simd = @import("../simd.zig");
const hir = @import("../hir.zig");
const cc = @import("charclass.zig");

const W = 16; // native NEON q-register width
const V = @Vector(W, u8);
const MAXR = 16;

pub const Ranges = struct {
    lo: [MAXR]u8 = @splat(0),
    hi: [MAXR]u8 = @splat(0),
    n: u8 = 0,

    /// Extract contiguous member ranges from a 256-bit class bitmap.
    /// `null` if empty or it needs more than `MAXR` ranges.
    pub fn fromBitmap(bm: [32]u8) ?Ranges {
        var r: Ranges = .{};
        var c: usize = 0;
        while (c < 256) {
            if (!common.hasBit(&bm, @intCast(c))) {
                c += 1;
                continue;
            }
            if (r.n >= MAXR) return null;
            const lo: u8 = @intCast(c);
            while (c < 256 and common.hasBit(&bm, @intCast(c))) c += 1;
            r.lo[r.n] = lo;
            r.hi[r.n] = @intCast(c - 1);
            r.n += 1;
        }
        if (r.n == 0) return null;
        return r;
    }

    inline fn inClass(self: *const Ranges, b: u8) bool {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (b >= self.lo[i] and b <= self.hi[i]) return true;
        }
        return false;
    }

    /// Per-lane membership as a `0xFF`/`0x00` byte vector. `@select(u8,…)`
    /// lowers to NEON `bsl` (bitwise select — one instruction), unlike a
    /// bool-vector→int `@bitCast` (which has no NEON form).
    inline fn memberVec(self: *const Ranges, v: V) V {
        const ff: V = @splat(0xFF);
        const zero: V = @splat(0);
        var m: V = zero;
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            const ge = v >= @as(V, @splat(self.lo[i])); // cmhs
            const le = v <= @as(V, @splat(self.hi[i])); // cmhs
            const le_m: V = @select(u8, le, ff, zero); // bsl
            const inr: V = @select(u8, ge, le_m, zero); // bsl  (ge && le)
            m |= inr; // orr.16b
        }
        return m;
    }

    /// First index ≥ `from` whose byte is a class member, or `null`.
    pub fn firstMember(self: *const Ranges, input: []const u8, from: usize) ?usize {
        var i = from;
        while (i + W <= input.len) : (i += W) {
            const v: V = input[i..][0..W].*; // ldr q
            if (@reduce(.Max, self.memberVec(v)) != 0) { // umaxv: any member?
                var j = i;
                while (j < i + W) : (j += 1) {
                    if (self.inClass(input[j])) return j;
                }
            }
        }
        while (i < input.len) : (i += 1) {
            if (self.inClass(input[i])) return i;
        }
        return null;
    }

    /// First index ≥ `from` whose byte is *not* a class member (= the end of
    /// the run starting at `from`); `from` if `input[from]` is a non-member.
    pub fn runEnd(self: *const Ranges, input: []const u8, from: usize) usize {
        var i = from;
        while (i + W <= input.len) : (i += W) {
            const v: V = input[i..][0..W].*;
            if (@reduce(.Min, self.memberVec(v)) == 0) { // uminv: any non-member?
                var j = i;
                while (j < i + W) : (j += 1) {
                    if (!self.inClass(input[j])) return j;
                }
            }
        }
        while (i < input.len) : (i += 1) {
            if (!self.inClass(input[i])) return i;
        }
        return input.len;
    }
};

// ---------------------------------------------------------------------------
// `Class`: 64-byte block-bitmask scanner (the `.class_span` executor)
// ---------------------------------------------------------------------------

const V16 = @Vector(16, u8);

/// Bytes classified per mask: one `u64`, bit `k` ⇔ byte `k` of the block.
pub const BLOCK = 64;

/// The SIMD shape of the build target, fixed at comptime (no runtime branch).
/// Shared with `simd.shuffle` so the load order chosen here (`loadRaw`,
/// `pack`) and the shuffle prong always agree.
const isa = simd.arch;

/// A real byte shuffle exists ⇒ arbitrary classes can be classified with
/// nibble lookups. Without one only range-shaped classes are accepted
/// (`Class.fromBitmap` returns null), so the planner keeps the DFA there.
pub const has_shuffle = simd.has_shuffle;

/// `out[k] = table[idx[k]]` for nibble indices — the shared `simd.shuffle`
/// (NEON `tbl`, SSSE3 `pshufb`, `vpshufb` under AVX). Its portable prong is
/// analysed but never executed here: `fromBitmap` never selects a nibble
/// method without a shuffle.
inline fn shuf(table: V16, idx: V16) V16 {
    return simd.shuffle(16, table, idx);
}

/// AArch64 `ld4`: de-interleave 64 bytes so lane `j` of vector `k` holds
/// byte `4j + k`. Zig/LLVM do not form `ld4` from stride-4 `@shuffle`s (it
/// emits ~64 lane moves), hence the asm. The memory clobber orders it after
/// any store to the source (the tail buffer in `window`).
inline fn ld4(p: [*]const u8) [4]V16 {
    var a: V16 = undefined;
    var b: V16 = undefined;
    var c: V16 = undefined;
    var d: V16 = undefined;
    asm ("ld4 { v28.16b, v29.16b, v30.16b, v31.16b }, [%[p]]"
        : [a] "={v28}" (a),
          [b] "={v29}" (b),
          [c] "={v30}" (c),
          [d] "={v31}" (d),
        : [p] "r" (p),
        : .{ .memory = true });
    return .{ a, b, c, d };
}

/// AArch64 `sri` (shift right and insert): keep `a`'s top `n` bits, insert
/// `b >> n` below them.
inline fn sri(a: V16, b: V16, comptime n: u8) V16 {
    return asm ("sri %[a].16b, %[b].16b, %[n]"
        : [ret] "=w" (-> V16),
        : [a] "0" (a),
          [b] "w" (b),
          [n] "i" (n),
    );
}

/// 64 raw input bytes in the target's load order (`ld4`-de-interleaved on
/// NEON, four plain 16-byte loads elsewhere) — input to `Class.maskRaw`.
pub const Raw = [4]V16;

pub inline fn loadRaw(p: [*]const u8) Raw {
    return switch (isa) {
        .neon => ld4(p),
        else => .{ p[0..16].*, p[16..32].*, p[32..48].*, p[48..64].* },
    };
}

inline fn ffMask(c: @Vector(16, bool)) V16 {
    return @select(u8, c, @as(V16, @splat(0xFF)), @as(V16, @splat(0)));
}

/// Pack four `0x00`/`0xFF` membership vectors (as produced by `loadBlock`)
/// into the natural-order 64-bit mask, bit `k` ⇔ byte `k`.
inline fn pack(vs: [4]V16) u64 {
    switch (isa) {
        .neon => {
            // vs[k] lane j ⇔ byte 4j+k (ld4 order). Fold the 4 lanes of byte
            // group j into one nibble (bit k ⇔ byte 4j+k), duplicate it into
            // both halves of the byte, then `shrn #4` packs nibble pairs into
            // bytes — byte m of the result covers bytes 8m..8m+7, in order.
            const t0 = sri(vs[1], vs[0], 1);
            const t1 = sri(vs[3], vs[2], 1);
            const t2 = sri(t1, t0, 2);
            const t3 = sri(t2, t2, 4);
            const w: @Vector(8, u16) = @bitCast(t3);
            const n: @Vector(8, u8) = @truncate(w >> @splat(4));
            return @bitCast(n);
        },
        else => {
            const z: V16 = @splat(0);
            const b0: u16 = @bitCast(vs[0] != z);
            const b1: u16 = @bitCast(vs[1] != z);
            const b2: u16 = @bitCast(vs[2] != z);
            const b3: u16 = @bitCast(vs[3] != z);
            return @as(u64, b0) | @as(u64, b1) << 16 | @as(u64, b2) << 32 | @as(u64, b3) << 48;
        },
    }
}

inline fn lowBits(n: usize) u64 {
    return (@as(u64, 1) << @intCast(n)) - 1; // n < 64
}

/// A run of members `[start, end)`.
pub const Span = struct { start: usize, end: usize };

pub const Class = struct {
    /// How a 16-byte vector is classified, chosen once by `fromBitmap`:
    /// `range`/`range2` = one/two contiguous ranges (wrapping subtract +
    /// unsigned compare per range); `nibble` = any ASCII-only class (two
    /// nibble shuffles); `nibble2` = any byte class (four shuffles).
    pub const Method = enum { range, range2, nibble, nibble2 };

    method: Method = .range,
    lo: [2]u8 = @splat(0),
    span: [2]u8 = @splat(0),
    /// `t_lo[c & 15]` bit `h` ⇔ byte `(h << 4) | (c & 15)` is a member, for
    /// hi nibble `h` 0..7; `t_lo2` the same for hi nibbles 8..15.
    t_lo: [16]u8 = @splat(0),
    t_lo2: [16]u8 = @splat(0),
    /// `t_hi[h]` = `1 << h` for h < 8 else 0; `t_hi2[h]` = `1 << (h - 8)` for
    /// h ≥ 8 else 0. So `t_lo[lo] & t_hi[hi] | t_lo2[lo] & t_hi2[hi]` is
    /// nonzero exactly for members.
    t_hi: [16]u8 = @splat(0),
    t_hi2: [16]u8 = @splat(0),

    /// Build the scanner for a 256-bit class bitmap, or `null` if the class
    /// is empty, or needs a byte shuffle the target lacks (> 2 ranges on a
    /// `portable` target).
    pub fn fromBitmap(bm: [32]u8) ?Class {
        var c: Class = .{};
        // One or two contiguous ranges: compare-based, no shuffle needed.
        if (Ranges.fromBitmap(bm)) |r| {
            if (r.n <= 2) {
                for (0..r.n) |k| {
                    c.lo[k] = r.lo[k];
                    c.span[k] = r.hi[k] - r.lo[k];
                }
                c.method = if (r.n == 1) .range else .range2;
                return c;
            }
        } else if (std.mem.allEqual(u8, &bm, 0)) {
            return null; // empty (a null from `Ranges` otherwise means > MAXR ranges)
        }
        if (!has_shuffle) return null;
        for (0..256) |b| {
            if (!common.hasBit(&bm, @intCast(b))) continue;
            const h = b >> 4;
            if (h < 8) c.t_lo[b & 15] |= @as(u8, 1) << @intCast(h) else c.t_lo2[b & 15] |= @as(u8, 1) << @intCast(h - 8);
        }
        for (0..16) |h| {
            if (h < 8) c.t_hi[h] = @as(u8, 1) << @intCast(h) else c.t_hi2[h] = @as(u8, 1) << @intCast(h - 8);
        }
        // Any member ≥ 0x80 needs the second table pair.
        c.method = if (std.mem.allEqual(u8, bm[16..], 0)) .nibble else .nibble2;
        return c;
    }

    /// Per-lane membership as `0xFF`/`0x00`.
    inline fn member(self: *const Class, comptime m: Method, v: V16) V16 {
        switch (m) {
            .range => return ffMask((v -% @as(V16, @splat(self.lo[0]))) <= @as(V16, @splat(self.span[0]))),
            .range2 => return ffMask((v -% @as(V16, @splat(self.lo[0]))) <= @as(V16, @splat(self.span[0]))) |
                ffMask((v -% @as(V16, @splat(self.lo[1]))) <= @as(V16, @splat(self.span[1]))),
            .nibble => {
                const x = shuf(self.t_lo, v & @as(V16, @splat(0x0F))) & shuf(self.t_hi, v >> @splat(4));
                return ffMask(x != @as(V16, @splat(0)));
            },
            .nibble2 => {
                const lo = v & @as(V16, @splat(0x0F));
                const hi = v >> @splat(4);
                const x = (shuf(self.t_lo, lo) & shuf(self.t_hi, hi)) |
                    (shuf(self.t_lo2, lo) & shuf(self.t_hi2, hi));
                return ffMask(x != @as(V16, @splat(0)));
            },
        }
    }

    /// Membership vectors of the 64 bytes at `p` (lane order is the target's
    /// load order — `pack` undoes it).
    inline fn loadBlock(self: *const Class, comptime m: Method, p: [*]const u8) [4]V16 {
        return self.memberRaw(m, loadRaw(p));
    }

    inline fn memberRaw(self: *const Class, comptime m: Method, raw: Raw) [4]V16 {
        return .{ self.member(m, raw[0]), self.member(m, raw[1]), self.member(m, raw[2]), self.member(m, raw[3]) };
    }

    /// Membership mask of a block already loaded with `loadRaw` — lets several
    /// classes share one load (`class_seq`). Dispatches on `method` once per call.
    pub inline fn maskRaw(self: *const Class, raw: Raw) u64 {
        return switch (self.method) {
            inline else => |m| pack(self.memberRaw(m, raw)),
        };
    }

    /// Membership mask of `input[pos..pos+64)`, bits at/after `input.len`
    /// clear. Requires `pos < input.len`. A short window reuses the overlapping
    /// last 64 bytes (shifted down) when the input has them, else a padded copy.
    inline fn window(self: *const Class, comptime m: Method, input: []const u8, pos: usize) u64 {
        if (pos + BLOCK <= input.len) return pack(self.loadBlock(m, input.ptr + pos));
        if (input.len >= BLOCK) {
            const base = input.len - BLOCK; // base < pos < input.len
            return pack(self.loadBlock(m, input.ptr + base)) >> @intCast(pos - base);
        }
        var buf: [BLOCK]u8 = @splat(0);
        const rem = input.len - pos;
        @memcpy(buf[0..rem], input[pos..]);
        return pack(self.loadBlock(m, &buf)) & lowBits(rem);
    }

    /// `window` with the method dispatched at runtime, for callers that walk the
    /// block masks themselves (`word_set`). Requires `pos < input.len`.
    pub inline fn windowAt(self: *const Class, input: []const u8, pos: usize) u64 {
        return switch (self.method) {
            inline else => |m| self.window(m, input, pos),
        };
    }

    inline fn anyMember(vs: [4]V16) bool {
        return @reduce(.Max, vs[0] | vs[1] | vs[2] | vs[3]) != 0;
    }

    inline fn allMembers(vs: [4]V16) bool {
        return @reduce(.Min, vs[0] & vs[1] & vs[2] & vs[3]) != 0;
    }

    /// First index ≥ `from` whose byte is a member, or `null`.
    pub fn firstMember(self: *const Class, input: []const u8, from: usize) ?usize {
        return switch (self.method) {
            inline else => |m| self.firstMemberT(m, input, from),
        };
    }

    fn firstMemberT(self: *const Class, comptime m: Method, input: []const u8, from: usize) ?usize {
        var p = from;
        while (p + BLOCK <= input.len) : (p += BLOCK) {
            const vs = self.loadBlock(m, input.ptr + p);
            // Gap blocks cost one horizontal max; the mask is packed only
            // for the block that holds the hit.
            if (anyMember(vs)) return p + @ctz(pack(vs));
        }
        if (p >= input.len) return null;
        const w = self.window(m, input, p);
        return if (w != 0) p + @ctz(w) else null;
    }

    /// First index ≥ `from` whose byte is *not* a member (= the end of the run
    /// starting at `from`), or `input.len`.
    pub fn runEnd(self: *const Class, input: []const u8, from: usize) usize {
        return switch (self.method) {
            inline else => |m| self.runEndT(m, input, from),
        };
    }

    fn runEndT(self: *const Class, comptime m: Method, input: []const u8, from: usize) usize {
        var p = from;
        while (p + BLOCK <= input.len) : (p += BLOCK) {
            const vs = self.loadBlock(m, input.ptr + p);
            if (!allMembers(vs)) return p + @ctz(~pack(vs));
        }
        if (p >= input.len) return input.len;
        // Bits at/after input.len are clear ⇒ `~w` stops there at the latest.
        return p + @ctz(~self.window(m, input, p));
    }

    /// The leftmost maximal member run starting at/after `from`, or `null`.
    /// Start and end usually fall in the same 64-byte window, so a typical
    /// call classifies one block.
    pub fn nextRun(self: *const Class, input: []const u8, from: usize) ?Span {
        return switch (self.method) {
            inline else => |m| self.nextRunT(m, input, from),
        };
    }

    fn nextRunT(self: *const Class, comptime m: Method, input: []const u8, from: usize) ?Span {
        var p = from;
        const w: u64 = blk: while (true) : (p += BLOCK) {
            if (p >= input.len) return null;
            if (p + BLOCK > input.len) {
                const t = self.window(m, input, p);
                if (t == 0) return null;
                break :blk t;
            }
            const vs = self.loadBlock(m, input.ptr + p);
            if (anyMember(vs)) break :blk pack(vs);
        };
        const off: u6 = @intCast(@ctz(w));
        const s = p + off;
        // Run length inside the window; it reaches the window's end only if
        // the run may continue (a short tail window has its out-of-input bits
        // clear, so it always stops inside).
        const k: usize = @ctz(~(w >> off));
        if (k < BLOCK - @as(usize, off)) return .{ .start = s, .end = s + k };
        return .{ .start = s, .end = self.runEndT(m, input, p + BLOCK) };
    }

    /// Number of maximal member runs in `input` (= the `class+` match count):
    /// a branch-free `popCount` of the run starts of each block.
    pub fn countRuns(self: *const Class, input: []const u8) usize {
        return switch (self.method) {
            inline else => |m| self.countRunsT(m, input),
        };
    }

    fn countRunsT(self: *const Class, comptime m: Method, input: []const u8) usize {
        var n: usize = 0;
        var carry: u64 = 0; // bit 0 ⇔ the byte before this block is a member
        var p: usize = 0;
        while (p + BLOCK <= input.len) : (p += BLOCK) {
            const w = pack(self.loadBlock(m, input.ptr + p));
            n += @popCount(w & ~((w << 1) | carry));
            carry = w >> 63;
        }
        if (p < input.len) {
            const w = self.window(m, input, p);
            n += @popCount(w & ~((w << 1) | carry));
        }
        return n;
    }

    /// Append every maximal member run of `input`, in order, as
    /// `make(input, start, end)` — the `class+` `findAll`. Run starts and
    /// ends are walked with `ctz` straight off each block's mask.
    pub fn appendRuns(
        self: *const Class,
        comptime T: type,
        allocator: std.mem.Allocator,
        list: *std.ArrayList(T),
        input: []const u8,
        comptime make: fn ([]const u8, usize, usize) T,
    ) !void {
        switch (self.method) {
            inline else => |m| try self.appendRunsT(m, T, allocator, list, input, make),
        }
    }

    fn appendRunsT(
        self: *const Class,
        comptime m: Method,
        comptime T: type,
        allocator: std.mem.Allocator,
        list: *std.ArrayList(T),
        input: []const u8,
        comptime make: fn ([]const u8, usize, usize) T,
    ) !void {
        // Size the list exactly first: the popCount pass is ~30× cheaper than
        // the walk, and it spares the walk every regrow copy of a list that
        // can reach input.len / 2 entries.
        try list.ensureUnusedCapacity(allocator, self.countRunsT(m, input));
        var carry: u64 = 0;
        var cur: usize = 0; // start of the run currently open
        var p: usize = 0;
        while (p < input.len) : (p += BLOCK) {
            const w = self.window(m, input, p);
            const prev = (w << 1) | carry; // bit k ⇔ byte k-1 is a member
            const starts = w & ~prev;
            // Run ends (first non-member after a run) are disjoint from the
            // starts, so one ascending walk over both alternates start, end.
            var ev = starts | (~w & prev);
            while (ev != 0) : (ev &= ev - 1) {
                const b: u6 = @intCast(@ctz(ev));
                if ((starts >> b) & 1 != 0) {
                    cur = p + b;
                } else {
                    list.appendAssumeCapacity(make(input, cur, p + b));
                }
            }
            // A short tail window has its last bit clear, so a run reaching
            // EOF there closed above; only a full final block leaves it open.
            carry = w >> 63;
        }
        if (carry != 0) list.appendAssumeCapacity(make(input, cur, input.len));
    }
};

// ---------------------------------------------------------------------------
// `RunSpec`: the whole `.class_span` shape (recogniser + executor), shared by
// the runtime `Regex` and the comptime `Pattern` so the two routers agree
// ---------------------------------------------------------------------------

/// Unbounded repetition count.
pub const INF: u32 = std.math.maxInt(u32);

/// A whole pattern that is one repeated byte class `S`, as a run shape:
///
/// * `.star` — `S*`: the (possibly empty) run at the search position.
/// * `.runs` — `S{min,max}` with `min ≥ 1` (`S+`, `S{m,}`, `S{m,n}`): every
///   maximal `S` run, greedily cut into `max`-byte matches, keeping a last
///   piece of ≥ `min` bytes (for `max = INF`: each run of length ≥ `min`).
/// * `.word` — `\b S{min,max} \b` with `S ⊆ \w`: the `\b`s force a match to
///   be a whole maximal `\w` run, so the matches are the `\w` runs of length
///   `[min, max]` made only of `S` bytes.
pub const RunSpec = struct {
    pub const Mode = enum { star, runs, word };

    mode: Mode = .runs,
    /// The class whose maximal runs are walked: `S`, or `\w` for `.word`.
    run: Class = .{},
    min: u32 = 1,
    max: u32 = INF,
    /// `.word` with `S ⊊ \w`: `S`'s bitmap, checked per byte of a candidate
    /// run; `null` when every `\w` run is made of `S` bytes.
    sub: ?[32]u8 = null,

    /// Recognise the shape from a HIR (runtime or comptime), or `null`. Only a
    /// flat concatenation of greedy single-class pieces qualifies — `S`,
    /// `S?`, `S*`, `S+` (what the parser lowers `{m,n}` to), optionally
    /// bracketed by `\b … \b` — with no anchors and no capture groups.
    pub fn recognize(h: anytype) ?RunSpec {
        @setEvalBranchQuota(1_000_000);
        if (h.anchored_start or h.anchored_end or h.saw_lazy) return null;
        // Flatten the left-leaning concat spine (iteratively: `\w{1000}` is a
        // 1000-deep chain).
        var lo: u64 = 0;
        var hi: u64 = 0;
        var cls: ?[32]u8 = null;
        var n: usize = 0;
        var stack: [64]hir.NodeRef = undefined;
        var sp: usize = 1;
        stack[0] = h.root;
        var pieces_wb_first = false;
        var pieces_wb_last = false;
        while (sp > 0) {
            sp -= 1;
            const nd = h.node(stack[sp]);
            if (nd.tag == .concat) {
                if (sp + 2 > stack.len) return null;
                stack[sp] = nd.b;
                stack[sp + 1] = nd.a; // popped first ⇒ left to right
                sp += 2;
                continue;
            }
            const is_last = sp == 0;
            if (nd.tag == .look) {
                if (nd.set_idx != @backingInt(hir.LookKind.word_boundary)) return null;
                // `\b` only as the very first / very last factor.
                if (n == 0 and !pieces_wb_first) {
                    pieces_wb_first = true;
                    continue;
                }
                if (is_last) {
                    pieces_wb_last = true;
                    continue;
                }
                return null;
            }
            const piece = pieceOf(h, nd) orelse return null;
            if (piece.set) |bm| {
                if (cls) |c| {
                    if (!std.mem.eql(u8, &c, &bm)) return null;
                } else cls = bm;
            }
            lo += piece.lo;
            hi = if (hi == INF or piece.hi == INF) INF else hi + piece.hi;
            n += 1;
        }
        const bm = cls orelse return null;
        if (pieces_wb_first != pieces_wb_last) return null; // `\bS+` / `S+\b`
        if (lo > INF - 1 or (hi != INF and hi >= INF)) return null;
        var s: RunSpec = .{ .min = @intCast(lo), .max = @intCast(hi) };
        if (pieces_wb_first) {
            // `\b S{m,n} \b`, S ⊆ \w (else a `\b` next to a non-word S byte
            // would not bracket a whole run).
            if (lo == 0) return null;
            var word: [32]u8 = @splat(0);
            for (0..256) |b| if (cc.isWord(@intCast(b))) common.setBit(&word, @intCast(b));
            for (0..32) |i| if (bm[i] & ~word[i] != 0) return null;
            s.mode = .word;
            s.run = Class.fromBitmap(word) orelse return null;
            if (!std.mem.eql(u8, &bm, &word)) s.sub = bm;
            return s;
        }
        s.run = Class.fromBitmap(bm) orelse return null;
        if (lo == 0) {
            if (hi != INF) return null; // nullable bounded (`S{0,n}`): not this shape
            s.mode = .star;
            s.min = 0;
        }
        return s;
    }

    const Piece = struct { set: ?[32]u8, lo: u32, hi: u32 };

    /// One concat factor as a count interval over a single class: `S` = [1,1],
    /// `S?` = [0,1], `S*` = [0,∞), `S+` = [1,∞) (greedy only); `empty` = [0,0].
    fn pieceOf(h: anytype, nd: hir.HNode) ?Piece {
        switch (nd.tag) {
            .set => return .{ .set = h.setBitmap(nd.set_idx), .lo = 1, .hi = 1 },
            .empty => return .{ .set = null, .lo = 0, .hi = 0 },
            .opt, .star, .plus => {
                if (!nd.greedy) return null;
                const c = h.node(nd.a);
                if (c.tag != .set) return null;
                const bm = h.setBitmap(c.set_idx);
                return switch (nd.tag) {
                    .opt => .{ .set = bm, .lo = 0, .hi = 1 },
                    .star => .{ .set = bm, .lo = 0, .hi = INF },
                    else => .{ .set = bm, .lo = 1, .hi = INF },
                };
            },
            else => return null,
        }
    }

    /// Plain `S+` / `\b\w+\b`, whose match set (from offset 0) is exactly the
    /// maximal runs — served by the block-mask `countRuns` / `appendRuns`.
    inline fn allRuns(self: *const RunSpec) bool {
        return self.min == 1 and self.max == INF and self.sub == null and self.mode != .star;
    }

    /// Visit, in order, the maximal runs of `self.run` in `input[from..]` as
    /// `sink.run(s, e) bool` (false stops). A run already open at `from` is
    /// visited from `from` (`.runs`: its suffix still matches) or skipped
    /// (`.word`: no `\b` in front of it).
    inline fn eachRun(self: *const RunSpec, input: []const u8, from: usize, sink: anytype) void {
        var carry: u64 = @intFromBool(self.mode == .word and from > 0 and from <= input.len and cc.isWord(input[from - 1]));
        var cur: ?usize = null;
        var p = from;
        while (p < input.len) : (p += BLOCK) {
            const w = self.run.windowAt(input, p);
            const prev = (w << 1) | carry;
            const starts = w & ~prev;
            var ev = starts | (~w & prev);
            while (ev != 0) : (ev &= ev - 1) {
                const b: u6 = @intCast(@ctz(ev));
                if ((starts >> b) & 1 != 0) {
                    cur = p + b;
                } else if (cur) |s| {
                    if (!sink.run(s, p + b)) return;
                    cur = null;
                }
            }
            carry = w >> 63;
        }
        if (carry != 0) if (cur) |s| {
            _ = sink.run(s, input.len);
        };
    }

    /// Emit the matches of one maximal run `[s, e)` via `sink.emit(a, b) bool`.
    inline fn runMatches(self: *const RunSpec, input: []const u8, s: usize, e: usize, sink: anytype) bool {
        const len = e - s;
        switch (self.mode) {
            .star => unreachable,
            .word => {
                if (len < self.min or len > self.max) return true;
                if (self.sub) |*bm| {
                    for (input[s..e]) |c| if (!common.hasBit(bm, c)) return true;
                }
                return sink.emit(s, e);
            },
            .runs => {
                if (self.max == INF) {
                    if (len >= self.min) return sink.emit(s, e);
                    return true;
                }
                // Greedy leftmost-first: whole `max` pieces, then a tail of
                // ≥ `min` bytes (a shorter tail cannot start a match).
                var p = s;
                while (e - p >= self.max) : (p += self.max) {
                    if (!sink.emit(p, p + self.max)) return false;
                }
                if (e - p >= self.min and e > p) return sink.emit(p, e);
                return true;
            },
        }
    }

    /// Leftmost match at/after `from`, or `null`.
    pub fn nextMatch(self: *const RunSpec, input: []const u8, from: usize) ?Span {
        if (self.mode == .star) return .{ .start = from, .end = self.run.runEnd(input, from) };
        if (self.mode == .runs and self.allRuns()) return self.run.nextRun(input, from);
        var sink: struct {
            spec: *const RunSpec,
            input: []const u8,
            found: ?Span = null,
            inline fn run(k: *@This(), s: usize, e: usize) bool {
                return k.spec.runMatches(k.input, s, e, k);
            }
            inline fn emit(k: *@This(), s: usize, e: usize) bool {
                k.found = .{ .start = s, .end = e };
                return false;
            }
        } = .{ .spec = self, .input = input };
        self.eachRun(input, from, &sink);
        return sink.found;
    }

    pub fn isMatch(self: *const RunSpec, input: []const u8) bool {
        if (self.mode == .star) return true;
        if (self.allRuns()) return self.run.firstMember(input, 0) != null;
        return self.nextMatch(input, 0) != null;
    }

    /// Number of leftmost non-overlapping matches.
    pub fn count(self: *const RunSpec, input: []const u8) usize {
        if (self.mode == .star) return countStar(self, input);
        if (self.allRuns()) return self.run.countRuns(input);
        var sink: struct {
            spec: *const RunSpec,
            input: []const u8,
            n: usize = 0,
            inline fn run(k: *@This(), s: usize, e: usize) bool {
                return k.spec.runMatches(k.input, s, e, k);
            }
            inline fn emit(k: *@This(), _: usize, _: usize) bool {
                k.n += 1;
                return true;
            }
        } = .{ .spec = self, .input = input };
        self.eachRun(input, 0, &sink);
        return sink.n;
    }

    /// `S*` iteration: a (possibly empty) match at every search position,
    /// advancing one byte past an empty match (the shared `advanceEmpty` rule).
    fn countStar(self: *const RunSpec, input: []const u8) usize {
        var n: usize = 0;
        var pos: usize = 0;
        while (pos <= input.len) : (n += 1) {
            const e = self.run.runEnd(input, pos);
            pos = if (e == pos) e + 1 else e;
        }
        return n;
    }

    /// Append every leftmost non-overlapping match as `make(input, start, end)`.
    pub fn appendAll(
        self: *const RunSpec,
        comptime T: type,
        allocator: std.mem.Allocator,
        list: *std.ArrayList(T),
        input: []const u8,
        comptime make: fn ([]const u8, usize, usize) T,
    ) !void {
        if (self.allRuns()) return self.run.appendRuns(T, allocator, list, input, make);
        if (self.mode == .star) {
            var pos: usize = 0;
            while (pos <= input.len) {
                const e = self.run.runEnd(input, pos);
                try list.append(allocator, make(input, pos, e));
                pos = if (e == pos) e + 1 else e;
            }
            return;
        }
        var sink: struct {
            spec: *const RunSpec,
            input: []const u8,
            allocator: std.mem.Allocator,
            list: *std.ArrayList(T),
            err: ?std.mem.Allocator.Error = null,
            inline fn run(k: *@This(), s: usize, e: usize) bool {
                return k.spec.runMatches(k.input, s, e, k);
            }
            inline fn emit(k: *@This(), s: usize, e: usize) bool {
                k.list.append(k.allocator, make(k.input, s, e)) catch |err| {
                    k.err = err;
                    return false;
                };
                return true;
            }
        } = .{ .spec = self, .input = input, .allocator = allocator, .list = list };
        self.eachRun(input, 0, &sink);
        if (sink.err) |err| return err;
    }
};

test "class_span: ranges + scan basics" {
    var bm: [32]u8 = @splat(0);
    for ('0'..'9' + 1) |x| common.setBit(&bm, @intCast(x));
    const r = Ranges.fromBitmap(bm).?;
    try std.testing.expectEqual(@as(u8, 1), r.n);

    const s = "abc 12345 def 6789xx";
    try std.testing.expectEqual(@as(?usize, 4), r.firstMember(s, 0));
    try std.testing.expectEqual(@as(usize, 9), r.runEnd(s, 4));
    try std.testing.expectEqual(@as(?usize, 14), r.firstMember(s, 9));
    try std.testing.expectEqual(@as(usize, 18), r.runEnd(s, 14));
    // long input exercising the 16-byte vector path on both sides
    const rep = common.repeat;
    const long = rep("x", 40) ++ rep("7", 50) ++ rep("y", 5);
    try std.testing.expectEqual(@as(?usize, 40), r.firstMember(long, 0));
    try std.testing.expectEqual(@as(usize, 90), r.runEnd(long, 40));
    try std.testing.expectEqual(@as(?usize, null), r.firstMember("zzzz", 0));
}

test "class_span: multi-range class (\\w-like) scans correctly" {
    var bm: [32]u8 = @splat(0);
    for ([_][2]u8{ .{ '0', '9' }, .{ 'A', 'Z' }, .{ 'a', 'z' }, .{ '_', '_' } }) |rg| {
        for (rg[0]..@as(usize, rg[1]) + 1) |x| common.setBit(&bm, @intCast(x));
    }
    const r = Ranges.fromBitmap(bm).?;
    try std.testing.expectEqual(@as(u8, 4), r.n);
    const s = "  foo_Bar123!! tail99 ";
    try std.testing.expectEqual(@as(?usize, 2), r.firstMember(s, 0));
    try std.testing.expectEqual(@as(usize, 12), r.runEnd(s, 2));
    try std.testing.expectEqual(@as(?usize, 15), r.firstMember(s, 12));
}

// --- `Class` differential tests: every query vs a scalar bitmap oracle ---

const Oracle = struct {
    bm: [32]u8,

    fn in(self: *const Oracle, b: u8) bool {
        return common.hasBit(&self.bm, b);
    }
    fn first(self: *const Oracle, s: []const u8, from: usize) ?usize {
        var i = from;
        while (i < s.len) : (i += 1) if (self.in(s[i])) return i;
        return null;
    }
    fn end(self: *const Oracle, s: []const u8, from: usize) usize {
        var i = from;
        while (i < s.len and self.in(s[i])) i += 1;
        return i;
    }
    fn runs(self: *const Oracle, s: []const u8) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (self.first(s, i)) |st| : (n += 1) i = self.end(s, st);
        return n;
    }
};

fn testSpan(_: []const u8, start: usize, end: usize) Span {
    return .{ .start = start, .end = end };
}

fn setBit(bm: *[32]u8, b: usize) void {
    common.setBit(bm, @intCast(b));
}

/// A random class of one of the shapes the methods specialise on.
fn randomClass(r: std.Random, shape: usize) [32]u8 {
    var bm: [32]u8 = @splat(0);
    switch (shape % 8) {
        0 => { // one range (.range)
            const a = r.int(u8);
            const b = r.intRangeAtMost(u8, a, 255);
            for (a..@as(usize, b) + 1) |x| setBit(&bm, x);
        },
        1 => { // two ranges (.range2), possibly touching the 0x00 / 0xFF edges
            const a = r.intRangeAtMost(u8, 0, 100);
            const b = r.intRangeAtMost(u8, a, 120);
            const c = r.intRangeAtMost(u8, 140, 250);
            for (a..@as(usize, b) + 1) |x| setBit(&bm, x);
            for (c..256) |x| setBit(&bm, x);
        },
        2, 3 => { // sparse-ish ASCII set (.nibble)
            for (0..128) |x| if (r.uintLessThan(u8, 10) < 3) setBit(&bm, x);
        },
        4 => { // arbitrary bytes incl. non-ASCII (.nibble2)
            for (0..256) |x| if (r.uintLessThan(u8, 10) < 4) setBit(&bm, x);
        },
        5 => { // complement of a few bytes, e.g. [^\n] / [^"\\] (.range2 / .nibble2)
            for (0..256) |x| setBit(&bm, x);
            for (0..1 + r.uintLessThan(usize, 4)) |_| {
                const b = r.int(u8);
                bm[b >> 3] &= ~(@as(u8, 1) << @as(u3, @intCast(b & 7)));
            }
        },
        6 => for (0..256) |x| setBit(&bm, x), // full class
        else => setBit(&bm, r.int(u8)), // single byte
    }
    return bm;
}

test "class_span: Class == scalar oracle (random classes, lengths, offsets)" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xC1A55);
    const r = prng.random();
    const lens = [_]usize{ 0, 1, 2, 15, 16, 17, 31, 32, 33, 63, 64, 65, 66, 100, 127, 128, 129, 191, 192, 193, 255 };
    var store: [8 + 256]u8 = undefined;
    var shape: usize = 0;
    while (shape < 160) : (shape += 1) {
        const o = Oracle{ .bm = randomClass(r, shape) };
        const cls = Class.fromBitmap(o.bm) orelse {
            // Only the empty class, or a > 2-range class without a shuffle.
            continue;
        };
        var mem: [256]u8 = undefined;
        var non: [256]u8 = undefined;
        var nm: usize = 0;
        var nn: usize = 0;
        for (0..256) |b| {
            if (o.in(@intCast(b))) {
                mem[nm] = @intCast(b);
                nm += 1;
            } else {
                non[nn] = @intCast(b);
                nn += 1;
            }
        }
        for (lens) |len| {
            // Alternate member / non-member segments of random length so
            // runs straddle the 64-byte block edges; unaligned base.
            const off = r.uintLessThan(usize, 8);
            const s = store[off .. off + len];
            var i: usize = 0;
            var want_member = r.boolean();
            while (i < len) {
                const seg = @min(len - i, 1 + r.uintLessThan(usize, if (r.boolean()) 6 else 90));
                for (s[i .. i + seg]) |*c| {
                    const use_member = (want_member and nm > 0) or nn == 0;
                    c.* = if (use_member) mem[r.uintLessThan(usize, nm)] else non[r.uintLessThan(usize, nn)];
                }
                i += seg;
                want_member = !want_member;
            }
            for (0..len + 1) |from| {
                try std.testing.expectEqual(o.first(s, from), cls.firstMember(s, from));
                try std.testing.expectEqual(o.end(s, from), cls.runEnd(s, from));
                const want: ?Span = if (o.first(s, from)) |st| Span{ .start = st, .end = o.end(s, st) } else null;
                try std.testing.expectEqual(want, cls.nextRun(s, from));
            }
            try std.testing.expectEqual(o.runs(s), cls.countRuns(s));
            var list: std.ArrayList(Span) = .empty;
            defer list.deinit(gpa);
            try cls.appendRuns(Span, gpa, &list, s, testSpan);
            try std.testing.expectEqual(o.runs(s), list.items.len);
            var at: usize = 0;
            for (list.items) |sp| {
                const st = o.first(s, at).?;
                try std.testing.expectEqual(Span{ .start = st, .end = o.end(s, st) }, sp);
                at = sp.end;
            }
        }
    }
}

test "class_span: Class method selection" {
    var digits: [32]u8 = @splat(0);
    for ('0'..'9' + 1) |x| setBit(&digits, x);
    try std.testing.expectEqual(Class.Method.range, Class.fromBitmap(digits).?.method);

    var dot: [32]u8 = @splat(0); // [^\n]
    for (0..256) |x| if (x != '\n') setBit(&dot, x);
    try std.testing.expectEqual(Class.Method.range2, Class.fromBitmap(dot).?.method);

    var word: [32]u8 = @splat(0); // \w
    for (0..128) |x| if (std.ascii.isAlphanumeric(@intCast(x)) or x == '_') setBit(&word, x);
    if (has_shuffle) {
        try std.testing.expectEqual(Class.Method.nibble, Class.fromBitmap(word).?.method);
        setBit(&word, 0xE9); // é (Latin-1 \p{L})
        try std.testing.expectEqual(Class.Method.nibble2, Class.fromBitmap(word).?.method);
    } else {
        try std.testing.expect(Class.fromBitmap(word) == null);
    }
    try std.testing.expect(Class.fromBitmap(@splat(0)) == null);
}
