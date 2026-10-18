//! Shared arch-specific SIMD primitives.
//!
//! Today that is the one instruction the portable `@Vector` layer cannot
//! express well: the **byte shuffle** (`pshufb` on SSSE3, `vpshufb` under
//! AVX/AVX2, `tbl` on NEON) that both the Teddy multi-literal kernel
//! (`prefilter.zig`) and the nibble classifier (`exec/class_span.zig`) are
//! built on. Everything is selected by *comptime* conditions on the build
//! target, so only the target's prong is analysed and emitted — there is no
//! per-target runtime branch.

const std = @import("std");
const builtin = @import("builtin");

/// The SIMD shape of the build target, fixed at comptime. This is the one
/// place that inspects the target's arch and features; every kernel switches
/// on `arch` (or on the flags derived from it below) so they cannot disagree.
pub const Arch = enum { neon, sse, portable };

pub const arch: Arch = switch (builtin.cpu.arch) {
    .aarch64 => if (std.Target.aarch64.featureSetHas(builtin.cpu.features, .neon)) .neon else .portable,
    .x86_64 => if (std.Target.x86.featureSetHas(builtin.cpu.features, .ssse3)) .sse else .portable,
    else => .portable,
};

/// Is a real one-instruction byte shuffle available for the build target?
/// When false the shuffle-based kernels are never planned (Teddy falls back
/// to the portable two-byte filter, `class_span.Class.fromBitmap` refuses
/// classes that need nibble lookups), so `shuffle`'s portable prong is
/// analysed but never executed.
pub const has_shuffle: bool = arch != .portable;

/// 3-operand `vpshufb` needs AVX for an xmm (16-byte) shuffle and AVX2 for a
/// ymm (32-byte) one.
pub const x86_avx: bool = builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx);
pub const x86_avx2: bool = builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);

/// Per-128-bit-lane table lookup, `W` = 16 or 32 bytes:
/// `out[k] = table[(k & ~15) | (idx[k] & 0x0F)]`, or `0` where `idx[k]` has
/// bit 7 set. `pshufb`/`vpshufb` and `tbl` agree on this for nibble indices
/// (`tbl` zeroes any index ≥ 16, `pshufb` any index with bit 7 set), which is
/// all the callers ever pass. `W == 32` is x86-only (NEON has no 256-bit
/// shuffle) and looks up *independently per 128-bit lane*, so a 16-entry
/// table must be duplicated into both lanes by the caller.
pub inline fn shuffle(comptime W: usize, table: @Vector(W, u8), idx: @Vector(W, u8)) @Vector(W, u8) {
    const Vec = @Vector(W, u8);
    comptime std.debug.assert(W == 16 or W == 32);
    if (builtin.cpu.arch == .aarch64 and has_shuffle) {
        comptime std.debug.assert(W == 16);
        return asm ("tbl %[o].16b, {%[t].16b}, %[i].16b"
            : [o] "=w" (-> Vec),
            : [t] "w" (table),
              [i] "w" (idx),
        );
    } else if (builtin.cpu.arch == .x86_64 and (if (W == 32) x86_avx2 else x86_avx)) {
        // 3-operand AVX form: out = vpshufb(table, idx); xmm or ymm by type.
        return asm ("vpshufb %[i], %[t], %[o]"
            : [o] "=x" (-> Vec),
            : [t] "x" (table),
              [i] "x" (idx),
        );
    } else if (builtin.cpu.arch == .x86_64 and has_shuffle and W == 16) {
        // 2-operand SSSE3 form: table is read-modify-write.
        var t = table;
        asm ("pshufb %[i], %[t]"
            : [t] "+x" (t),
            : [i] "x" (idx),
        );
        return t;
    } else {
        const ta: [W]u8 = table;
        const ia: [W]u8 = idx;
        var out: [W]u8 = undefined;
        for (&out, ia, 0..) |*o, i, k| {
            o.* = if (i & 0x80 != 0) 0 else ta[(k & ~@as(usize, 15)) | (i & 0x0F)];
        }
        return out;
    }
}

/// Scalar reference with the documented semantics, for the test below.
fn shuffleRef(comptime W: usize, table: [W]u8, idx: [W]u8) [W]u8 {
    var out: [W]u8 = undefined;
    for (&out, idx, 0..) |*o, i, k| {
        o.* = if (i & 0x80 != 0) 0 else table[(k & ~@as(usize, 15)) | (i & 0x0F)];
    }
    return out;
}

test "simd: shuffle(16) matches the scalar reference (nibble and bit-7 indices)" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const r = prng.random();
    var iter: usize = 0;
    while (iter < 2000) : (iter += 1) {
        var table: [16]u8 = undefined;
        var idx: [16]u8 = undefined;
        r.bytes(&table);
        for (&idx) |*i| {
            // mostly nibbles (what callers pass), sometimes a bit-7 "zero me" index
            i.* = if (r.int(u3) == 0) 0x80 | r.int(u8) else r.int(u4);
        }
        const got: [16]u8 = shuffle(16, table, idx);
        try std.testing.expectEqualSlices(u8, &shuffleRef(16, table, idx), &got);
    }
}
