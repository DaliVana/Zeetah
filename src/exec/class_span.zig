//! SIMD byte-class span scanner for the trivial shape `class+` / `class*`
//! (the *whole* unanchored pattern is one greedy repetition of a single
//! byte class — `[0-9]+`, `\w+`, `.+`, `[^/\s?#]+`, …). The match is just a
//! maximal run of class members, so no automaton is needed.
//!
//! AArch64 note (the reason an earlier version regressed): NEON has **no
//! `PMOVMSKB`** (vector→bitmask). The x86 idiom "compare → movemask → ctz"
//! lowers on Apple Silicon to ~16 per-lane `umov`/`mov.b` scalar moves per
//! chunk — slower than the scalar DFA. So this version never bitcasts a
//! bool-vector to an integer. Instead each 16-byte chunk is classified with
//! `cmhs`+`bsl`+`orr` and reduced with a single horizontal `@reduce(.Max)`
//! / `@reduce(.Min)` (one `umaxv`/`uminv`). Whole member/non-member chunks
//! are skipped at full NEON rate; a ≤16-byte scalar loop only pins the
//! exact index at a run/gap boundary (negligible vs the run length).

const std = @import("std");

const W = 16; // native NEON q-register width
const V = @Vector(W, u8);
const MAXR = 16;

pub const Ranges = struct {
    lo: [MAXR]u8 = [_]u8{0} ** MAXR,
    hi: [MAXR]u8 = [_]u8{0} ** MAXR,
    n: u8 = 0,

    /// Extract contiguous member ranges from a 256-bit class bitmap.
    /// `null` if empty or it needs more than `MAXR` ranges.
    pub fn fromBitmap(bm: [32]u8) ?Ranges {
        var r: Ranges = .{};
        var c: usize = 0;
        while (c < 256) {
            const member = (bm[c >> 3] & (@as(u8, 1) << @as(u3, @intCast(c & 7)))) != 0;
            if (!member) {
                c += 1;
                continue;
            }
            if (r.n >= MAXR) return null;
            const lo: u8 = @intCast(c);
            while (c < 256 and
                (bm[c >> 3] & (@as(u8, 1) << @as(u3, @intCast(c & 7)))) != 0) : (c += 1)
            {}
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

test "class_span: ranges + scan basics" {
    var bm = [_]u8{0} ** 32;
    var c: u8 = '0';
    while (c <= '9') : (c += 1) bm[c >> 3] |= (@as(u8, 1) << @as(u3, @intCast(c & 7)));
    const r = Ranges.fromBitmap(bm).?;
    try std.testing.expectEqual(@as(u8, 1), r.n);

    const s = "abc 12345 def 6789xx";
    try std.testing.expectEqual(@as(?usize, 4), r.firstMember(s, 0));
    try std.testing.expectEqual(@as(usize, 9), r.runEnd(s, 4));
    try std.testing.expectEqual(@as(?usize, 14), r.firstMember(s, 9));
    try std.testing.expectEqual(@as(usize, 18), r.runEnd(s, 14));
    // long input exercising the 16-byte vector path on both sides
    const long = ("x" ** 40) ++ ("7" ** 50) ++ ("y" ** 5);
    try std.testing.expectEqual(@as(?usize, 40), r.firstMember(long, 0));
    try std.testing.expectEqual(@as(usize, 90), r.runEnd(long, 40));
    try std.testing.expectEqual(@as(?usize, null), r.firstMember("zzzz", 0));
}

test "class_span: multi-range class (\\w-like) scans correctly" {
    var bm = [_]u8{0} ** 32;
    for ([_][2]u8{ .{ '0', '9' }, .{ 'A', 'Z' }, .{ 'a', 'z' }, .{ '_', '_' } }) |rg| {
        var x: u8 = rg[0];
        while (x <= rg[1]) : (x += 1) bm[x >> 3] |= (@as(u8, 1) << @as(u3, @intCast(x & 7)));
    }
    const r = Ranges.fromBitmap(bm).?;
    try std.testing.expectEqual(@as(u8, 4), r.n);
    const s = "  foo_Bar123!! tail99 ";
    try std.testing.expectEqual(@as(?usize, 2), r.firstMember(s, 0));
    try std.testing.expectEqual(@as(usize, 12), r.runEnd(s, 2));
    try std.testing.expectEqual(@as(?usize, 15), r.firstMember(s, 12));
}
