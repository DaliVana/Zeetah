//! Whole-word keyword matcher for `\b(?:kw1|kw2|…)\b` when every keyword is
//! made of word bytes only (`[A-Za-z0-9_]`) — the `.words` strategy of
//! `seq_extract.BoundaryMatcher`.
//!
//! With word-only keywords, `\b` on both sides forces a match to be a whole
//! maximal `\w` run: the keyword's first byte is a word byte, so `\b` before
//! it means the previous byte is not, and likewise after its last byte. So the
//! matches are exactly the `\w` runs that equal some keyword, in order — at
//! most one keyword can equal a given run, so source-order tie-breaking never
//! arises and matches never overlap.
//!
//! That turns the search into the keyword step of Niles Salter's accelerated
//! Zig tokenizer: walk the word runs straight off `class_span`'s 64-byte `\w`
//! mask (run starts `m & ~(m << 1 | carry)`, ends `~m & (m << 1 | carry)`,
//! visited with `ctz`), reject by length and by (first byte, last byte) with
//! two bit tests — together they turn away almost every ordinary word with a
//! predictable branch — and look the rest up in a small open-addressing hash
//! table keyed on (first 8 bytes, length) whose entries hold the whole keyword
//! (≤ 16 bytes) for an exact two-word compare. Cost is per *word* of input,
//! independent of how many keywords there are — unlike the Aho-Corasick walk,
//! which pays per byte.

const std = @import("std");
const class_span = @import("class_span.zig");
const cc = @import("charclass.zig");
const common = @import("../common.zig");
const search = @import("search.zig");

/// Longest keyword the table stores inline (two `u64` key words).
pub const MAX_WORD = 16;
/// Most keywords (the table stays at most half full).
pub const MAX_WORDS = 128;
const TABLE = 2 * MAX_WORDS;

/// A matched span `[start, end)` — the canonical `search.Span`.
pub const Span = search.Span;

const Entry = struct {
    /// Keyword bytes 0..8 and 8..16, little-endian, zero-padded.
    k0: u64 = 0,
    k1: u64 = 0,
    /// 0 ⇔ empty slot (keywords are non-empty).
    len: u8 = 0,
};

/// Little-endian load of `n` ∈ [1, 8] bytes at `s`, zero-padded. A full
/// 8-byte read when it stays inside `buf`, else bytewise.
inline fn loadKey(buf: []const u8, s: usize, n: usize) u64 {
    if (s + 8 <= buf.len) {
        const v = std.mem.readInt(u64, buf[s..][0..8], .little);
        return if (n == 8) v else v & ((@as(u64, 1) << @intCast(n * 8)) - 1);
    }
    var v: u64 = 0;
    for (0..n) |i| v |= @as(u64, buf[s + i]) << @intCast(i * 8);
    return v;
}

/// Index into `pair_bits` from a word's first and last byte (low 6 bits of
/// each; collisions only let a word through to the exact lookup).
inline fn pairIndex(first: u8, last: u8) usize {
    return (@as(usize, first & 63) << 6) | (last & 63);
}

inline fn hash(k0: u64, len: usize) u64 {
    return (k0 ^ (@as(u64, len) *% 0x9E3779B97F4A7C15)) *% 0xBF58476D1CE4E5B9;
}

pub const WordSet = struct {
    /// The `\w` class (`charclass.isWord`), classified 64 bytes at a time.
    word: class_span.Class,
    /// Bit `L` ⇔ some keyword has length `L` (1..MAX_WORD).
    len_bits: u32,
    /// Bit `pairIndex(first, last)` ⇔ some keyword starts with `first` and
    /// ends with `last` (low 6 bits of each byte, 512 bytes): the cheap,
    /// predictable first check that rejects almost every non-keyword word
    /// before the hash lookup.
    pair_bits: [64]u64,
    /// `hash >> shift` indexes a table of `mask + 1` slots (a power of two).
    shift: u6,
    mask: u16,
    table: [TABLE]Entry,

    /// Build the set, or `null` when this strategy does not apply: no words,
    /// more than `MAX_WORDS`, a word longer than `MAX_WORD` or containing a
    /// non-word byte, or no byte shuffle on this target to classify `\w`.
    /// Pure and comptime-evaluable (the comptime `Pattern` bakes it).
    pub fn build(words: []const []const u8) ?WordSet {
        @setEvalBranchQuota(1_000_000);
        if (words.len == 0 or words.len > MAX_WORDS) return null;
        var wbm: [32]u8 = @splat(0);
        for (0..256) |b| {
            if (cc.isWord(@intCast(b))) common.setBit(&wbm, @intCast(b));
        }
        var s: WordSet = .{
            .word = class_span.Class.fromBitmap(wbm) orelse return null,
            .len_bits = 0,
            .pair_bits = @splat(0),
            .shift = 0,
            .mask = 0,
            .table = @splat(.{}),
        };
        var size: usize = 16;
        while (size < 2 * words.len) size *= 2;
        s.mask = @intCast(size - 1);
        s.shift = @intCast(@as(usize, 64) - std.math.log2_int(usize, size));
        for (words) |w| {
            if (w.len == 0 or w.len > MAX_WORD) return null;
            for (w) |c| if (!cc.isWord(c)) return null;
            s.len_bits |= @as(u32, 1) << @intCast(w.len);
            const pi = pairIndex(w[0], w[w.len - 1]);
            s.pair_bits[pi >> 6] |= @as(u64, 1) << @intCast(pi & 63);
            const e: Entry = .{
                .k0 = loadKey(w, 0, @min(w.len, 8)),
                .k1 = if (w.len > 8) loadKey(w, 8, w.len - 8) else 0,
                .len = @intCast(w.len),
            };
            var i: usize = @intCast(hash(e.k0, w.len) >> s.shift);
            while (s.table[i].len != 0) : (i = (i + 1) & s.mask) {
                const t = s.table[i];
                if (t.len == e.len and t.k0 == e.k0 and t.k1 == e.k1) break; // duplicate
            }
            s.table[i] = e;
        }
        return s;
    }

    /// Is `input[s..e]` one of the words? (`s < e`.)
    inline fn has(self: *const WordSet, input: []const u8, s: usize, e: usize) bool {
        const len = e - s;
        if (len > MAX_WORD or (self.len_bits >> @intCast(len)) & 1 == 0) return false;
        const pi = pairIndex(input[s], input[e - 1]);
        if ((self.pair_bits[pi >> 6] >> @intCast(pi & 63)) & 1 == 0) return false;
        const k0 = loadKey(input, s, @min(len, 8));
        const k1: u64 = if (len > 8) loadKey(input, s + 8, len - 8) else 0;
        var i: usize = @intCast(hash(k0, len) >> self.shift);
        while (true) : (i = (i + 1) & self.mask) {
            const t = &self.table[i];
            if (t.len == 0) return false;
            if (t.len == len and t.k0 == k0 and t.k1 == k1) return true;
        }
    }

    /// Leftmost maximal `\w` run that starts at/after `from` with a word
    /// boundary before it and equals a keyword — the leftmost
    /// `\b(?:kw|…)\b` match — or `null`.
    pub fn find(self: *const WordSet, input: []const u8, from: usize) ?Span {
        // A run already open at `from` started before it: its suffix from
        // `from` has no `\b` in front, so it is skipped (`cur == null`).
        var carry: u64 = @intFromBool(from > 0 and from <= input.len and cc.isWord(input[from - 1]));
        var cur: ?usize = null;
        var p = from;
        while (p < input.len) : (p += class_span.BLOCK) {
            const w = self.word.windowAt(input, p);
            const prev = (w << 1) | carry; // bit k ⇔ byte k-1 is a word byte
            const starts = w & ~prev;
            // Starts and ends (first non-word byte after a run) are disjoint;
            // one ascending walk alternates them. In a short tail window the
            // bits past the input are clear, so a run reaching EOF ends there.
            var ev = starts | (~w & prev);
            while (ev != 0) : (ev &= ev - 1) {
                const b: u6 = @intCast(@ctz(ev));
                if ((starts >> b) & 1 != 0) {
                    cur = p + b;
                } else if (cur) |s| {
                    if (self.has(input, s, p + b)) return .{ .start = s, .end = p + b };
                    cur = null;
                }
            }
            carry = w >> 63;
        }
        // A run reaching EOF at the end of a full final block is still open.
        if (carry != 0) if (cur) |s| {
            if (self.has(input, s, input.len)) return .{ .start = s, .end = input.len };
        };
        return null;
    }
};

// --- tests ---

/// Leftmost `\b(?:w0|w1|…)\b` by definition: every start in order, `\b`
/// there, alternatives in source order, `\b` after.
fn naiveFind(words: []const []const u8, input: []const u8, from: usize) ?Span {
    const wb = struct {
        fn f(s: []const u8, pos: usize) bool {
            const bw = pos > 0 and cc.isWord(s[pos - 1]);
            const aw = pos < s.len and cc.isWord(s[pos]);
            return bw != aw;
        }
    }.f;
    var p = from;
    while (p <= input.len) : (p += 1) {
        if (!wb(input, p)) continue;
        for (words) |w| {
            if (p + w.len <= input.len and std.mem.eql(u8, input[p .. p + w.len], w) and wb(input, p + w.len))
                return .{ .start = p, .end = p + w.len };
        }
    }
    return null;
}

test "word_set: find == naive \\b(?:…)\\b (random keyword sets, every offset)" {
    if (!class_span.has_shuffle) return error.SkipZigTest; // `\w` needs a shuffle
    var prng = std.Random.DefaultPrng.init(0x30DD5);
    const r = prng.random();
    // Tiny alphabets so keywords recur, prefix each other ("ab" / "abc") and
    // sit inside longer words; separators include non-word bytes ≥ 0x80.
    const word_chars = "abcAB_09";
    const seps = " .-\n\xe9";
    var kw_store: [MAX_WORDS][MAX_WORD]u8 = undefined;
    var kws: [MAX_WORDS][]const u8 = undefined;
    var hay_buf: [8 + 400]u8 = undefined;
    for (0..60) |iter| {
        const n = 1 + r.uintLessThan(usize, if (iter % 3 == 0) MAX_WORDS else 12);
        for (0..n) |i| {
            const len = 1 + r.uintLessThan(usize, if (r.boolean()) 4 else MAX_WORD);
            for (kw_store[i][0..len]) |*c| c.* = word_chars[r.uintLessThan(usize, word_chars.len)];
            kws[i] = kw_store[i][0..len];
        }
        const set = WordSet.build(kws[0..n]).?;
        for (kws[0..n]) |k| try std.testing.expect(set.has(k, 0, k.len));
        for ([_]usize{ 0, 1, 7, 63, 64, 65, 128, 200, 400 }) |len| {
            const off = r.uintLessThan(usize, 8);
            const hay = hay_buf[off .. off + len];
            var i: usize = 0;
            while (i < len) {
                // Mostly keywords and near-misses, separated by 0–2 seps.
                const piece: []const u8 = if (r.uintLessThan(u8, 3) != 0) kws[r.uintLessThan(usize, n)] else "ab";
                for (piece) |c| {
                    if (i == len) break;
                    hay[i] = c;
                    i += 1;
                }
                for (0..r.uintLessThan(usize, 3)) |_| {
                    if (i == len) break;
                    hay[i] = seps[r.uintLessThan(usize, seps.len)];
                    i += 1;
                }
            }
            for (0..len + 1) |from| {
                try std.testing.expectEqual(naiveFind(kws[0..n], hay, from), set.find(hay, from));
            }
        }
    }
}

test "word_set: build scope" {
    const ok = [_][]const u8{ "if", "else", "x_1", "instanceofxyzwvu" };
    try std.testing.expectEqual(class_span.has_shuffle, WordSet.build(&ok) != null);
    try std.testing.expect(WordSet.build(&[_][]const u8{"a-b"}) == null); // non-word byte
    try std.testing.expect(WordSet.build(&[_][]const u8{"instanceofxyzwvu1"}) == null); // > MAX_WORD
    try std.testing.expect(WordSet.build(&[_][]const u8{}) == null);
}
