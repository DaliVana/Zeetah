//! Allocation-free codepoint range-set algebra for codepoint mode.
//!
//! A set is a sorted, non-overlapping, non-adjacent, surrogate-free slice of
//! `CodepointRange`s. `RangeBuf(cap)` is the growable owner — a fixed array at
//! comptime (`cap == N`) so the comptime `Pattern` pipeline needs no allocator,
//! an `ArrayListUnmanaged` at runtime (`cap == null`) — with one method surface
//! so the parser and the property resolver are written once (the same
//! `Hir(cap)` pattern). Every operation below is pure and comptime-evaluable.
//!
//! Operations (Rust `regex-syntax`'s `IntervalSet` surface): `normalize`,
//! `complement`, `intersect`, `difference`, `symmetricDifference`, union by
//! `appendSlice` + `normalize`, and `foldSimple` — closure under Unicode simple
//! case folding, which must run **before** negation (`(?i)[^x]`).

const std = @import("std");
const common = @import("common.zig");
const tables = @import("unicode_tables.zig");
const utf8 = @import("utf8.zig");

pub const R = common.CodepointRange;
pub const MAX_CP: u21 = common.MAX_CODEPOINT;
const SURR_LO: u32 = 0xD800;
const SURR_HI: u32 = 0xDFFF;

/// Capacity overflow (comptime) or allocation failure (runtime). Callers map
/// it to `hir.Error.TooComplex`.
pub const Error = error{TooComplex};

/// Growable range list. See the module doc for the comptime/runtime split.
pub fn RangeBuf(comptime cap: ?usize) type {
    return struct {
        const Self = @This();
        pub const is_comptime = cap != null;

        buf: if (cap) |c| [c]R else std.ArrayListUnmanaged(R),
        /// Comptime store only (the runtime list knows its own length).
        n: usize,
        /// Runtime store only (`undefined` at comptime).
        a: std.mem.Allocator,

        pub fn init(a: std.mem.Allocator) Self {
            return .{ .buf = if (cap != null) undefined else .empty, .n = 0, .a = a };
        }

        pub fn deinit(self: *Self) void {
            if (cap == null) self.buf.deinit(self.a);
        }

        pub fn items(self: *const Self) []const R {
            return if (cap != null) self.buf[0..self.n] else self.buf.items;
        }

        pub fn mut(self: *Self) []R {
            return if (cap != null) self.buf[0..self.n] else self.buf.items;
        }

        pub fn len(self: *const Self) usize {
            return if (cap != null) self.n else self.buf.items.len;
        }

        pub fn clear(self: *Self) void {
            if (cap != null) self.n = 0 else self.buf.clearRetainingCapacity();
        }

        /// Shrink to the first `k` ranges.
        pub fn truncate(self: *Self, k: usize) void {
            if (cap != null) self.n = k else self.buf.shrinkRetainingCapacity(k);
        }

        pub fn append(self: *Self, r: R) Error!void {
            if (cap) |c| {
                if (self.n >= c) return Error.TooComplex;
                self.buf[self.n] = r;
                self.n += 1;
            } else {
                self.buf.append(self.a, r) catch return Error.TooComplex;
            }
        }

        pub fn appendSlice(self: *Self, rs: []const R) Error!void {
            for (rs) |r| try self.append(r);
        }

        /// Append a generated table (`tables.Range` has the same shape).
        pub fn appendTable(self: *Self, rs: []const tables.Range) Error!void {
            for (rs) |r| try self.append(.{ .lo = r.lo, .hi = r.hi });
        }

        /// Replace the contents with `rs`.
        pub fn setFrom(self: *Self, rs: []const R) Error!void {
            self.clear();
            try self.appendSlice(rs);
        }
    };
}

fn lessThan(_: void, x: R, y: R) bool {
    return x.lo < y.lo;
}

/// Sort, merge overlapping/adjacent ranges, and remove the surrogate hole —
/// in place. Idempotent; every other operation expects normalized inputs.
pub fn normalize(buf: anytype) Error!void {
    const s = buf.mut();
    std.mem.sort(R, s, {}, lessThan);
    // Merge in place.
    var w: usize = 0;
    for (s) |r| {
        if (w > 0 and r.lo <= @as(u32, s[w - 1].hi) + 1) {
            if (r.hi > s[w - 1].hi) s[w - 1].hi = r.hi;
        } else {
            s[w] = r;
            w += 1;
        }
    }
    buf.truncate(w);
    // Subtract [D800, DFFF]. After merging at most one range can cover the
    // whole hole (then nothing else intersects it); several ranges can lie
    // inside / cross one edge of it. Clip or drop in a write pass and append
    // the split-off upper part (re-sorted) if a range straddles the hole.
    var upper: ?R = null;
    var w2: usize = 0;
    const s2 = buf.mut();
    for (s2) |r| {
        if (r.hi < SURR_LO or r.lo > SURR_HI) {
            s2[w2] = r;
            w2 += 1;
        } else if (r.lo < SURR_LO and r.hi > SURR_HI) {
            s2[w2] = .{ .lo = r.lo, .hi = SURR_LO - 1 };
            w2 += 1;
            upper = .{ .lo = SURR_HI + 1, .hi = r.hi };
        } else if (r.lo < SURR_LO) {
            s2[w2] = .{ .lo = r.lo, .hi = SURR_LO - 1 };
            w2 += 1;
        } else if (r.hi > SURR_HI) {
            s2[w2] = .{ .lo = SURR_HI + 1, .hi = r.hi };
            w2 += 1;
        } // else: entirely inside the hole → dropped
    }
    buf.truncate(w2);
    if (upper) |u| {
        try buf.append(u);
        std.mem.sort(R, buf.mut(), {}, lessThan);
    }
}

/// `out` := complement of the normalized set `in` within the scalar universe
/// [0, 0x10FFFF] minus surrogates. `out` is cleared first.
pub fn complement(in: []const R, out: anytype) Error!void {
    out.clear();
    var expected: u32 = 0;
    for (in) |r| {
        if (r.lo > expected) try out.append(.{ .lo = @intCast(expected), .hi = @intCast(r.lo - 1) });
        expected = @as(u32, r.hi) + 1;
    }
    if (expected <= MAX_CP) try out.append(.{ .lo = @intCast(expected), .hi = MAX_CP });
    try normalize(out); // clips the surrogate hole out of the gaps
}

/// `out` := `a` ∩ `b` (both normalized; `out` cleared first).
pub fn intersect(a: []const R, b: []const R, out: anytype) Error!void {
    out.clear();
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        const lo = @max(a[i].lo, b[j].lo);
        const hi = @min(a[i].hi, b[j].hi);
        if (lo <= hi) try out.append(.{ .lo = lo, .hi = hi });
        if (a[i].hi < b[j].hi) i += 1 else j += 1;
    }
}

/// `out` := `a` \ `b` (both normalized; `out` cleared first).
pub fn difference(a: []const R, b: []const R, out: anytype) Error!void {
    out.clear();
    var j: usize = 0;
    for (a) |ra| {
        var cur: u32 = ra.lo;
        while (j < b.len and b[j].hi < ra.lo) j += 1;
        var k = j;
        while (k < b.len and b[k].lo <= ra.hi) : (k += 1) {
            if (b[k].lo > cur) try out.append(.{ .lo = @intCast(cur), .hi = @intCast(b[k].lo - 1) });
            cur = @as(u32, b[k].hi) + 1;
            if (cur > ra.hi) break;
        }
        if (cur <= ra.hi) try out.append(.{ .lo = @intCast(cur), .hi = ra.hi });
    }
}

/// `out` := `a` △ `b` (both normalized). `scratch` is a second buffer the
/// operation clobbers.
pub fn symmetricDifference(a: []const R, b: []const R, out: anytype, scratch: anytype) Error!void {
    try difference(a, b, out);
    try difference(b, a, scratch);
    try out.appendSlice(scratch.items());
    try normalize(out);
}

/// First `case_fold` entry whose `cp >= x`.
fn foldLowerBound(x: u21) usize {
    const t = &tables.case_fold;
    var lo: usize = 0;
    var hi: usize = t.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (t[mid].cp < x) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Close `buf` under Unicode simple case folding (CaseFolding.txt C + S):
/// every member's orbit is added, then the set is re-normalized. Must run
/// before negation. `buf` must be normalized.
pub fn foldSimple(buf: anytype) Error!void {
    const n = buf.len();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const r = buf.items()[i]; // re-fetch: appends below may move the storage
        var k = foldLowerBound(r.lo);
        while (k < tables.case_fold.len and tables.case_fold[k].cp <= r.hi) : (k += 1) {
            const e = &tables.case_fold[k];
            for (e.others[0..e.n]) |o| try buf.append(.{ .lo = o, .hi = o });
        }
    }
    try normalize(buf);
}

// --- Queries over a normalized set -------------------------------------------

pub fn contains(ranges: []const R, cp: u21) bool {
    return utf8.inRanges(ranges, cp);
}

/// Every member is < 0x80 (so the set is exactly a byte set).
pub fn isAscii(ranges: []const R) bool {
    return ranges.len == 0 or ranges[ranges.len - 1].hi < 0x80;
}

/// The 256-bit byte map of an ASCII-only set (bits ≥ 0x80 stay clear).
pub fn asciiBitmap(ranges: []const R) [32]u8 {
    var bm: [32]u8 = @splat(0);
    for (ranges) |r| {
        var c: u32 = r.lo;
        while (c <= r.hi and c < 0x80) : (c += 1) common.setBit(&bm, @intCast(c));
    }
    return bm;
}

/// Shortest / longest UTF-8 encoding of any member (0 for an empty set).
pub fn minUtf8Len(ranges: []const R) u3 {
    return if (ranges.len == 0) 0 else utf8.encodedLen(ranges[0].lo);
}
pub fn maxUtf8Len(ranges: []const R) u3 {
    return if (ranges.len == 0) 0 else utf8.encodedLen(ranges[ranges.len - 1].hi);
}

fn leadByte(cp: u21) u8 {
    var b: [4]u8 = undefined;
    _ = utf8.encode(cp, &b);
    return b[0];
}

/// OR into `set` every byte that can begin the encoding of a member. Within one
/// encoding length the lead byte is monotonic in the scalar, so each range is
/// split at the length boundaries and contributes `lead(lo)..lead(hi)`.
pub fn leadBytes(ranges: []const R, set: *[32]u8) void {
    const bounds = [_]u32{ 0x7F, 0x7FF, 0xFFFF, 0x10FFFF };
    for (ranges) |r| {
        var lo: u32 = r.lo;
        for (bounds) |b| {
            if (lo > b) continue;
            const hi: u32 = @min(@as(u32, r.hi), b);
            var x: u32 = leadByte(@intCast(lo));
            const y: u32 = leadByte(@intCast(hi));
            while (x <= y) : (x += 1) common.setBit(set, @intCast(x));
            if (hi == r.hi) break;
            lo = b + 1;
        }
    }
}

/// Number of scalars in the set.
pub fn count(ranges: []const R) u32 {
    var n: u32 = 0;
    for (ranges) |r| n += @as(u32, r.hi) - r.lo + 1;
    return n;
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;
const TBuf = RangeBuf(null);

fn expectRanges(expected: []const R, got: []const R) !void {
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| {
        try testing.expectEqual(e.lo, g.lo);
        try testing.expectEqual(e.hi, g.hi);
    }
}

test "normalize sorts, merges adjacent/overlapping and clips surrogates" {
    var b = TBuf.init(testing.allocator);
    defer b.deinit();
    try b.appendSlice(&.{ .{ .lo = 10, .hi = 20 }, .{ .lo = 0, .hi = 5 }, .{ .lo = 6, .hi = 9 }, .{ .lo = 15, .hi = 30 } });
    try normalize(&b);
    try expectRanges(&.{.{ .lo = 0, .hi = 30 }}, b.items());

    try b.setFrom(&.{ .{ .lo = 0xD000, .hi = 0xE100 }, .{ .lo = 0xD900, .hi = 0xD950 } });
    try normalize(&b);
    try expectRanges(&.{ .{ .lo = 0xD000, .hi = 0xD7FF }, .{ .lo = 0xE000, .hi = 0xE100 } }, b.items());

    try b.setFrom(&.{ .{ .lo = 0xD800, .hi = 0xD900 }, .{ .lo = 0xDF00, .hi = 0xDFFF }, .{ .lo = 'a', .hi = 'a' } });
    try normalize(&b);
    try expectRanges(&.{.{ .lo = 'a', .hi = 'a' }}, b.items());
}

test "complement is an involution over the scalar universe" {
    var a = TBuf.init(testing.allocator);
    defer a.deinit();
    var c = TBuf.init(testing.allocator);
    defer c.deinit();
    var cc = TBuf.init(testing.allocator);
    defer cc.deinit();
    try a.setFrom(&.{ .{ .lo = 'a', .hi = 'z' }, .{ .lo = 0x4E00, .hi = 0x9FFF } });
    try complement(a.items(), &c);
    try testing.expect(!contains(c.items(), 'q'));
    try testing.expect(contains(c.items(), 'A'));
    try testing.expect(!contains(c.items(), 0xD800));
    try testing.expect(contains(c.items(), 0x10FFFF));
    try complement(c.items(), &cc);
    try expectRanges(a.items(), cc.items());
    // Complement of the empty set is the whole surrogate-free universe.
    try complement(&.{}, &c);
    try expectRanges(&.{ .{ .lo = 0, .hi = 0xD7FF }, .{ .lo = 0xE000, .hi = 0x10FFFF } }, c.items());
}

test "intersect / difference / symmetricDifference" {
    var out = TBuf.init(testing.allocator);
    defer out.deinit();
    var scratch = TBuf.init(testing.allocator);
    defer scratch.deinit();
    const a = [_]R{ .{ .lo = 0, .hi = 10 }, .{ .lo = 20, .hi = 30 } };
    const b = [_]R{ .{ .lo = 5, .hi = 25 }, .{ .lo = 28, .hi = 28 } };
    try intersect(&a, &b, &out);
    try expectRanges(&.{ .{ .lo = 5, .hi = 10 }, .{ .lo = 20, .hi = 25 }, .{ .lo = 28, .hi = 28 } }, out.items());
    try difference(&a, &b, &out);
    try expectRanges(&.{ .{ .lo = 0, .hi = 4 }, .{ .lo = 26, .hi = 27 }, .{ .lo = 29, .hi = 30 } }, out.items());
    try difference(&b, &a, &out);
    try expectRanges(&.{.{ .lo = 11, .hi = 19 }}, out.items());
    try symmetricDifference(&a, &b, &out, &scratch);
    try expectRanges(&.{ .{ .lo = 0, .hi = 4 }, .{ .lo = 11, .hi = 19 }, .{ .lo = 26, .hi = 27 }, .{ .lo = 29, .hi = 30 } }, out.items());
    // Difference where b fully covers a range of a.
    try difference(&.{.{ .lo = 5, .hi = 6 }}, &.{.{ .lo = 0, .hi = 100 }}, &out);
    try testing.expectEqual(@as(usize, 0), out.len());
}

test "foldSimple closes a set under simple case folding" {
    var b = TBuf.init(testing.allocator);
    defer b.deinit();
    try b.setFrom(&.{.{ .lo = 'k', .hi = 'k' }});
    try foldSimple(&b);
    try expectRanges(&.{ .{ .lo = 'K', .hi = 'K' }, .{ .lo = 'k', .hi = 'k' }, .{ .lo = 0x212A, .hi = 0x212A } }, b.items());

    try b.setFrom(&.{.{ .lo = 0x3C2, .hi = 0x3C2 }}); // ς
    try foldSimple(&b);
    try testing.expect(contains(b.items(), 0x3A3)); // Σ
    try testing.expect(contains(b.items(), 0x3C3)); // σ
    try testing.expectEqual(@as(u32, 3), count(b.items()));

    // Idempotent and a superset.
    try b.setFrom(&.{.{ .lo = 'a', .hi = 'z' }});
    try foldSimple(&b);
    const n1 = count(b.items());
    try foldSimple(&b);
    try testing.expectEqual(n1, count(b.items()));
    try testing.expect(contains(b.items(), 'Q'));
    try testing.expect(contains(b.items(), 0x17F)); // ſ (long s) folds to s
}

test "isAscii / asciiBitmap / lead bytes / utf8 lengths" {
    const asc = [_]R{ .{ .lo = 'a', .hi = 'c' }, .{ .lo = '0', .hi = '0' } };
    try testing.expect(isAscii(&asc));
    const bm = asciiBitmap(&asc);
    try testing.expect(common.hasBit(&bm, 'b'));
    try testing.expect(!common.hasBit(&bm, 'd'));
    try testing.expectEqual(@as(u3, 1), minUtf8Len(&asc));
    try testing.expectEqual(@as(u3, 1), maxUtf8Len(&asc));

    const wide = [_]R{ .{ .lo = 'a', .hi = 'a' }, .{ .lo = 0xE9, .hi = 0x4E2D }, .{ .lo = 0x1F600, .hi = 0x1F600 } };
    try testing.expect(!isAscii(&wide));
    try testing.expectEqual(@as(u3, 1), minUtf8Len(&wide));
    try testing.expectEqual(@as(u3, 4), maxUtf8Len(&wide));
    var lead: [32]u8 = @splat(0);
    leadBytes(&wide, &lead);
    try testing.expect(common.hasBit(&lead, 'a'));
    try testing.expect(common.hasBit(&lead, 0xC3)); // é
    try testing.expect(common.hasBit(&lead, 0xDF)); // 2-byte range up to 0x7FF
    try testing.expect(common.hasBit(&lead, 0xE0)); // 3-byte from 0x800
    try testing.expect(common.hasBit(&lead, 0xE4)); // 中
    try testing.expect(!common.hasBit(&lead, 0xE5));
    try testing.expect(common.hasBit(&lead, 0xF0)); // 😀
    try testing.expect(!common.hasBit(&lead, 0x80)); // never a continuation byte
    try testing.expect(!common.hasBit(&lead, 'b'));
}

test "comptime RangeBuf works inside comptime" {
    const r = comptime blk: {
        var b = RangeBuf(16).init(undefined);
        b.appendSlice(&.{ .{ .lo = 5, .hi = 9 }, .{ .lo = 0, .hi = 4 } }) catch unreachable;
        normalize(&b) catch unreachable;
        break :blk b.items()[0];
    };
    try testing.expectEqual(@as(u21, 0), r.lo);
    try testing.expectEqual(@as(u21, 9), r.hi);
    // Capacity overflow is a typed error.
    var tiny = RangeBuf(1).init(undefined);
    try tiny.append(.{ .lo = 0, .hi = 0 });
    try testing.expectError(Error.TooComplex, tiny.append(.{ .lo = 2, .hi = 2 }));
}
