//! Strict UTF-8 helpers for codepoint mode (`(?u)` / `.unicode`).
//!
//! * `decodeAt` / `decodeBefore` — decode the scalar value starting at, or
//!   ending just before, a byte offset. Strict per RFC 3629: truncated,
//!   overlong, surrogate and > U+10FFFF sequences are **not** scalars (`null`),
//!   so an invalid byte never matches a codepoint construct and a `\b` next to
//!   one sees a non-word neighbour — Rust `regex` / RE2 behaviour.
//! * `encode` / `encodedLen` — the inverse.
//! * `isWordCp` — the UTS #18 Annex C `\w` membership behind Unicode `\b`.
//! * `foldCanon` / `foldOrbit` / `eqlFold` — simple case folding (CaseFolding
//!   C + S) as orbits, for `(?iu)` backreferences.
//! * `SeqIter` — the Thompson/Cox UTF-8 range splitter as an allocation-free
//!   iterator: a scalar range → the byte-range sequences whose concatenation
//!   matches exactly its UTF-8 encodings, in ascending order.
//!
//! Everything here is pure and comptime-evaluable (no allocator).

const std = @import("std");
const tables = @import("unicode_tables.zig");

pub const Decoded = struct { cp: u21, len: u3 };

/// Decode the scalar value whose first byte is `s[i]`. `null` when `s[i]` does
/// not begin a complete, valid, shortest-form encoding of a non-surrogate
/// scalar value (or `i >= s.len`).
pub fn decodeAt(s: []const u8, i: usize) ?Decoded {
    if (i >= s.len) return null;
    const b0 = s[i];
    if (b0 < 0x80) return .{ .cp = b0, .len = 1 };
    if (b0 < 0xC2) return null; // stray continuation byte or overlong 2-byte lead
    if (b0 < 0xE0) {
        if (i + 1 >= s.len) return null;
        const b1 = s[i + 1];
        if (b1 & 0xC0 != 0x80) return null;
        return .{ .cp = (@as(u21, b0 & 0x1F) << 6) | (b1 & 0x3F), .len = 2 };
    }
    if (b0 < 0xF0) {
        if (i + 2 >= s.len) return null;
        const b1 = s[i + 1];
        const b2 = s[i + 2];
        if (b1 & 0xC0 != 0x80 or b2 & 0xC0 != 0x80) return null;
        if (b0 == 0xE0 and b1 < 0xA0) return null; // overlong
        if (b0 == 0xED and b1 >= 0xA0) return null; // surrogate D800..DFFF
        return .{ .cp = (@as(u21, b0 & 0x0F) << 12) | (@as(u21, b1 & 0x3F) << 6) | (b2 & 0x3F), .len = 3 };
    }
    if (b0 < 0xF5) {
        if (i + 3 >= s.len) return null;
        const b1 = s[i + 1];
        const b2 = s[i + 2];
        const b3 = s[i + 3];
        if (b1 & 0xC0 != 0x80 or b2 & 0xC0 != 0x80 or b3 & 0xC0 != 0x80) return null;
        if (b0 == 0xF0 and b1 < 0x90) return null; // overlong
        if (b0 == 0xF4 and b1 >= 0x90) return null; // > U+10FFFF
        return .{ .cp = (@as(u21, b0 & 0x07) << 18) | (@as(u21, b1 & 0x3F) << 12) | (@as(u21, b2 & 0x3F) << 6) | (b3 & 0x3F), .len = 4 };
    }
    return null;
}

/// Decode the scalar value that ends exactly at `i` (the last codepoint of
/// `s[0..i]`). `null` when the bytes before `i` do not end a valid scalar.
pub fn decodeBefore(s: []const u8, i: usize) ?Decoded {
    if (i == 0 or i > s.len) return null;
    var k: usize = 1;
    while (k <= 4 and k <= i) : (k += 1) {
        const b = s[i - k];
        if (b & 0xC0 != 0x80) { // a lead byte (or ASCII): decode forward from it
            const d = decodeAt(s, i - k) orelse return null;
            return if (d.len == k) d else null; // must end exactly at `i`
        }
    }
    return null;
}

/// Encoded length of a scalar value (never a surrogate — callers hold
/// surrogate-free sets).
pub fn encodedLen(cp: u21) u3 {
    if (cp < 0x80) return 1;
    if (cp < 0x800) return 2;
    if (cp < 0x10000) return 3;
    return 4;
}

/// Encode `cp` into `out`; returns the byte count.
pub fn encode(cp: u21, out: *[4]u8) u3 {
    const n = encodedLen(cp);
    switch (n) {
        1 => out[0] = @intCast(cp),
        2 => {
            out[0] = @intCast(0xC0 | (cp >> 6));
            out[1] = @intCast(0x80 | (cp & 0x3F));
        },
        3 => {
            out[0] = @intCast(0xE0 | (cp >> 12));
            out[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
            out[2] = @intCast(0x80 | (cp & 0x3F));
        },
        else => {
            out[0] = @intCast(0xF0 | (cp >> 18));
            out[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
            out[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
            out[3] = @intCast(0x80 | (cp & 0x3F));
        },
    }
    return n;
}

/// Binary search over any sorted, non-overlapping `{lo, hi}` range slice.
pub fn inRanges(ranges: anytype, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (cp < r.lo) {
            hi = mid;
        } else if (cp > r.hi) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

/// Unicode `\w` membership (UTS #18 Annex C: Alphabetic ∪ M ∪ Nd ∪ Pc ∪
/// Join_Control) — the predicate behind `word_boundary_unicode`.
pub fn isWordCp(cp: u21) bool {
    if (cp < 0x80) {
        const c: u8 = @intCast(cp);
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
    }
    return inRanges(&tables.perl_word, cp);
}

// --- Simple case folding -----------------------------------------------------

/// Index of `cp` in `tables.case_fold`, when `cp` has a non-trivial orbit.
fn foldIndex(cp: u21) ?usize {
    const t = &tables.case_fold;
    var lo: usize = 0;
    var hi: usize = t.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < t[mid].cp) {
            hi = mid;
        } else if (cp > t[mid].cp) {
            lo = mid + 1;
        } else return mid;
    }
    return null;
}

/// The other members of `cp`'s simple-fold orbit (empty when trivial).
pub fn foldOrbit(cp: u21) []const u21 {
    const i = foldIndex(cp) orelse return &.{};
    const e = &tables.case_fold[i];
    return e.others[0..e.n];
}

/// Canonical representative of `cp`'s orbit: its smallest member (`cp` itself
/// for a trivial orbit). Two scalars are case-equivalent iff their canons agree.
pub fn foldCanon(cp: u21) u21 {
    var best = cp;
    for (foldOrbit(cp)) |o| if (o < best) {
        best = o;
    };
    return best;
}

/// Does the text at `input[pos..]` begin with `group` under simple case
/// folding? Scalars are compared by `foldCanon`; an undecodable byte on either
/// side must match byte-for-byte. Returns the end offset of the matched text in
/// `input` (its byte length may differ from `group`'s: `K` vs `K`).
pub fn eqlFold(group: []const u8, input: []const u8, pos: usize) ?usize {
    var g: usize = 0;
    var p = pos;
    while (g < group.len) {
        if (p >= input.len) return null;
        const a = decodeAt(group, g);
        const b = decodeAt(input, p);
        if (a == null or b == null) {
            if (group[g] != input[p]) return null;
            g += 1;
            p += 1;
            continue;
        }
        if (a.?.cp != b.?.cp and foldCanon(a.?.cp) != foldCanon(b.?.cp)) return null;
        g += a.?.len;
        p += b.?.len;
    }
    return p;
}

// --- UTF-8 byte-range sequences ----------------------------------------------

/// One inclusive byte range of a UTF-8 sequence step.
pub const ByteRange = struct { lo: u8, hi: u8 };

/// A sequence of 1–4 byte ranges: the concatenation matches exactly the UTF-8
/// encodings of one contiguous scalar sub-range.
pub const Seq = struct {
    parts: [4]ByteRange = undefined,
    len: u3 = 0,

    pub fn slice(self: *const Seq) []const ByteRange {
        return self.parts[0..self.len];
    }
};

fn maxScalar(nbytes: u3) u32 {
    return switch (nbytes) {
        1 => 0x7F,
        2 => 0x7FF,
        3 => 0xFFFF,
        else => 0x10FFFF,
    };
}

/// Iterator over the UTF-8 byte-range sequences of a scalar range (Thompson's
/// `utf8ranges` as ported from Russ Cox's RE2 / Rust `regex-syntax`). Yields
/// sequences in lexicographic order of their byte ranges, which is what the
/// incremental minimal-automaton construction in `thompson.zig` requires.
/// Surrogates inside the range are skipped (they have no encoding).
pub const SeqIter = struct {
    const Pending = struct { lo: u32, hi: u32 };
    // Each split pops one range and pushes two; processing the lower half first
    // keeps at most one deferred upper half per split level (≤ 3 length splits
    // + 3 continuation splits), so 16 is ample.
    stack: [16]Pending = undefined,
    sp: usize = 0,

    pub fn init(lo: u21, hi: u21) SeqIter {
        std.debug.assert(lo <= hi);
        var it = SeqIter{};
        it.stack[0] = .{ .lo = lo, .hi = hi };
        it.sp = 1;
        return it;
    }

    fn push(self: *SeqIter, lo: u32, hi: u32) void {
        std.debug.assert(self.sp < self.stack.len);
        self.stack[self.sp] = .{ .lo = lo, .hi = hi };
        self.sp += 1;
    }

    pub fn next(self: *SeqIter) ?Seq {
        outer: while (self.sp > 0) {
            self.sp -= 1;
            const r = self.stack[self.sp];
            const start = r.lo;
            const end = r.hi;

            // Carve out the surrogate block (never encoded; a normalized set
            // has no surrogates, but `\p{Any}`-style callers may pass the
            // whole universe).
            if (start <= 0xDFFF and end >= 0xD800) {
                if (end > 0xDFFF) self.push(0xE000, end);
                if (start < 0xD800) self.push(start, 0xD7FF);
                continue :outer;
            }

            // Split across UTF-8 length boundaries (upper half deferred).
            var i: u3 = 1;
            while (i < 4) : (i += 1) {
                const m = maxScalar(i);
                if (start <= m and m < end) {
                    self.push(m + 1, end);
                    self.push(start, m);
                    continue :outer;
                }
            }
            // Split so each continuation-byte position spans a clean range.
            i = 1;
            while (i < 4) : (i += 1) {
                const mask: u32 = (@as(u32, 1) << (6 * @as(u5, i))) - 1;
                if ((start & ~mask) != (end & ~mask)) {
                    if ((start & mask) != 0) {
                        self.push((start | mask) + 1, end);
                        self.push(start, start | mask);
                        continue :outer;
                    }
                    if ((end & mask) != mask) {
                        self.push(end & ~mask, end);
                        self.push(start, (end & ~mask) - 1);
                        continue :outer;
                    }
                }
            }
            // [start, end] now forms a single sequence of independent byte ranges.
            var sb: [4]u8 = undefined;
            var eb: [4]u8 = undefined;
            const n = encode(@intCast(start), &sb);
            const n2 = encode(@intCast(end), &eb);
            std.debug.assert(n == n2);
            var seq: Seq = .{ .len = n };
            for (0..n) |j| seq.parts[j] = .{ .lo = sb[j], .hi = eb[j] };
            return seq;
        }
        return null;
    }
};

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

test "decodeAt: valid scalars of every length" {
    const s = "a\xC3\xA9\xE4\xB8\xAD\xF0\x9F\x98\x80";
    try testing.expectEqual(Decoded{ .cp = 'a', .len = 1 }, decodeAt(s, 0).?);
    try testing.expectEqual(Decoded{ .cp = 0xE9, .len = 2 }, decodeAt(s, 1).?);
    try testing.expectEqual(Decoded{ .cp = 0x4E2D, .len = 3 }, decodeAt(s, 3).?);
    try testing.expectEqual(Decoded{ .cp = 0x1F600, .len = 4 }, decodeAt(s, 6).?);
    try testing.expect(decodeAt(s, 10) == null);
}

test "decodeAt: rejects continuation, truncated, overlong, surrogate, too large" {
    try testing.expect(decodeAt("\x80", 0) == null); // stray continuation
    try testing.expect(decodeAt("\xC3", 0) == null); // truncated
    try testing.expect(decodeAt("\xC3\x41", 0) == null); // bad continuation
    try testing.expect(decodeAt("\xC0\xAF", 0) == null); // overlong '/'
    try testing.expect(decodeAt("\xE0\x80\xAF", 0) == null); // overlong 3-byte
    try testing.expect(decodeAt("\xED\xA0\x80", 0) == null); // U+D800
    try testing.expect(decodeAt("\xF4\x90\x80\x80", 0) == null); // U+110000
    try testing.expect(decodeAt("\xF5\x80\x80\x80", 0) == null);
    try testing.expect(decodeAt("\xFF", 0) == null);
}

test "decodeBefore mirrors decodeAt and rejects partial sequences" {
    const s = "a\xC3\xA9\xE4\xB8\xAD";
    try testing.expectEqual(Decoded{ .cp = 0x4E2D, .len = 3 }, decodeBefore(s, s.len).?);
    try testing.expectEqual(Decoded{ .cp = 0xE9, .len = 2 }, decodeBefore(s, 3).?);
    try testing.expectEqual(Decoded{ .cp = 'a', .len = 1 }, decodeBefore(s, 1).?);
    try testing.expect(decodeBefore(s, 0) == null);
    try testing.expect(decodeBefore(s, 2) == null); // ends mid-sequence
    try testing.expect(decodeBefore("\x80\x80", 2) == null); // no lead byte
}

test "encode round-trips" {
    for ([_]u21{ 0, 0x7F, 0x80, 0x7FF, 0x800, 0xD7FF, 0xE000, 0xFFFF, 0x10000, 0x10FFFF }) |cp| {
        var buf: [4]u8 = undefined;
        const n = encode(cp, &buf);
        try testing.expectEqual(n, encodedLen(cp));
        const d = decodeAt(buf[0..n], 0).?;
        try testing.expectEqual(cp, d.cp);
        try testing.expectEqual(n, d.len);
    }
}

test "isWordCp: ASCII, letters of other scripts, marks, digits, not punctuation" {
    try testing.expect(isWordCp('a'));
    try testing.expect(isWordCp('_'));
    try testing.expect(isWordCp(0xE9)); // é
    try testing.expect(isWordCp(0x4E2D)); // 中
    try testing.expect(isWordCp(0x0301)); // combining acute (Mn)
    try testing.expect(isWordCp(0x0661)); // Arabic-Indic one (Nd)
    try testing.expect(isWordCp(0x203F)); // undertie (Pc)
    try testing.expect(isWordCp(0x200D)); // ZWJ (Join_Control)
    try testing.expect(!isWordCp(' '));
    try testing.expect(!isWordCp(0x2014)); // em dash
    try testing.expect(!isWordCp(0x1F600)); // emoji
}

test "simple case folding orbits" {
    try testing.expectEqual(@as(u21, 'A'), foldCanon('a'));
    try testing.expectEqual(@as(u21, 'A'), foldCanon('A'));
    try testing.expectEqual(@as(u21, 'K'), foldCanon(0x212A)); // Kelvin sign
    try testing.expectEqual(@as(u21, 'S'), foldCanon(0x17F)); // long s
    try testing.expectEqual(foldCanon(0x3C3), foldCanon(0x3C2)); // σ ς
    try testing.expectEqual(foldCanon(0x3C3), foldCanon(0x3A3)); // Σ
    try testing.expectEqual(@as(usize, 2), foldOrbit('k').len);
    try testing.expectEqual(@as(usize, 0), foldOrbit('1').len);
    try testing.expectEqual(@as(usize, 3), foldOrbit(0x3B8).len); // θ ϑ Θ ϴ
    // ß folds simply only to/from ẞ (U+1E9E); the full fold to "ss" is not simple.
    try testing.expectEqual(@as(usize, 1), foldOrbit(0xDF).len);
    try testing.expectEqual(@as(u21, 0xDF), foldCanon(0x1E9E));
}

test "eqlFold compares codepoint-wise with differing byte lengths" {
    try testing.expectEqual(@as(?usize, 4), eqlFold("abc", "xABCy", 1));
    try testing.expectEqual(@as(?usize, 4), eqlFold("k", "x\xE2\x84\xAA", 1)); // Kelvin (3 bytes)
    try testing.expectEqual(@as(?usize, 2), eqlFold("\xE2\x84\xAA", "xK", 1)); // reverse (1 byte)
    try testing.expect(eqlFold("abc", "abd", 0) == null);
    try testing.expect(eqlFold("abc", "ab", 0) == null);
    // Invalid bytes compare bytewise.
    try testing.expectEqual(@as(?usize, 1), eqlFold("\xFF", "\xFF", 0));
    try testing.expect(eqlFold("\xFF", "\xFE", 0) == null);
}

fn seqMatches(seq: Seq, bytes: []const u8) bool {
    if (bytes.len != seq.len) return false;
    for (seq.slice(), bytes) |r, b| if (b < r.lo or b > r.hi) return false;
    return true;
}

test "SeqIter: full scalar range yields the classic 9 sequences" {
    var it = SeqIter.init(0, 0x10FFFF);
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    try testing.expectEqual(@as(usize, 9), n);
}

test "SeqIter: membership round-trip on sampled codepoints" {
    const Cases = struct { lo: u21, hi: u21 };
    const cases = [_]Cases{
        .{ .lo = 0x80, .hi = 0x10FFFF },
        .{ .lo = 0xE9, .hi = 0xE9 },
        .{ .lo = 0x370, .hi = 0x3FF },
        .{ .lo = 0x4E00, .hi = 0x9FFF },
        .{ .lo = 0x1F300, .hi = 0x1F5FF },
        .{ .lo = 0, .hi = 0x10FFFF },
    };
    for (cases) |c| {
        var cp: u32 = 0;
        while (cp <= 0x10FFFF) : (cp += 97) { // stride through the space
            if (cp >= 0xD800 and cp <= 0xDFFF) continue;
            var buf: [4]u8 = undefined;
            const n = encode(@intCast(cp), &buf);
            var it = SeqIter.init(c.lo, c.hi);
            var hit = false;
            while (it.next()) |seq| {
                if (seqMatches(seq, buf[0..n])) hit = true;
            }
            try testing.expectEqual(cp >= c.lo and cp <= c.hi, hit);
        }
    }
}

test "SeqIter: sequences come out in ascending lexicographic order" {
    var it = SeqIter.init(0x80, 0x10FFFF);
    var prev: ?Seq = null;
    while (it.next()) |seq| {
        if (prev) |p| {
            // Compare by first byte range lo (strictly increasing across sequences
            // of the same length, non-decreasing overall).
            try testing.expect(p.parts[0].lo <= seq.parts[0].lo);
        }
        prev = seq;
    }
}
