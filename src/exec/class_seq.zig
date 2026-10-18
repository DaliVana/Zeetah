//! Fixed-length byte-class sequence executor (`.class_seq`).
//!
//! For a whole unanchored pattern that is a fixed sequence of byte classes —
//! `[0-9]{2}:[0-9]{2}:[0-9]{2}`, `[0-9]{4}[ -][0-9]{4}…`, `#[0-9a-fA-F]{6}`,
//! `(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}` — every match has the same length
//! `L` and is decided by `L` independent per-position class tests. That is
//! the multi-char-symbol matcher of Niles Salter's accelerated Zig tokenizer:
//!
//! * classify each 64-byte block once per **distinct** class into a `u64`
//!   membership mask (one shared load, `class_span.Class.maskRaw`);
//! * a match *ends* at byte `e` iff for every pattern position `k` the byte
//!   `e - (L-1-k)` is in class `k`, i.e. `e` is set in
//!   `AND_k (mask[class k] << (L-1-k))` — computed for all 64 ends of the
//!   block at once, the shifts pulling the previous block's bits in;
//! * a `ctz` walk over the end mask keeps the leftmost non-overlapping
//!   matches (fixed length ⇒ ascending ends are ascending starts).
//!
//! Positions are folded into **runs** of one class (`[0-9]{4}` is one run of
//! 4): "the last `r` bytes are all members" is a `log2(r)`-step doubling on
//! the mask (`m & (m << 1)`, then `& (· << 2)`, …, `runMask`), so the
//! per-block work scales with the number of runs, not with `L`. A match needs
//! at most two blocks of context (`L ≤ 64`), so the doubling works on the
//! (previous, current) block pair as a 128-bit value, in registers.
//!
//! Most blocks never get that far. The build picks a *gate* class (fewest
//! members — `-`, `:`, `#`), and each block first evaluates only the gate's
//! runs ("two `-` exactly 3 bytes apart"): a necessary condition that rejects
//! most blocks after classifying one class. The other masks are computed only
//! for surviving blocks (the previous block's lazily, if it was rejected). A
//! single-byte gate with no occurrence in the block jumps ahead by `memchr`
//! to the next one, so sparse anchors (`#[0-9a-f]{6}`) scan at memchr speed.

const std = @import("std");
const hir = @import("../hir.zig");
const common = @import("../common.zig");
const class_span = @import("class_span.zig");
const search = @import("search.zig");

/// Longest supported match. A match then spans at most two 64-byte blocks.
pub const MAX_LEN = 64;
/// Distinct classes classified per block (each costs one mask per block).
pub const MAX_CLASSES = 4;

const BLOCK = class_span.BLOCK;

/// A matched span `[start, end)` — the canonical `search.Span`.
pub const Span = search.Span;

/// `len` consecutive pattern positions of class `cls`, the last one `shift`
/// positions before the pattern's end.
const Run = struct { cls: u8, len: u8, shift: u8 };

/// The (previous, current) block pair of one class's membership masks as a
/// 128-bit value: bit `j` of `lo` ⇔ byte `p - 64 + j`, of `hi` ⇔ byte `p + j`.
const Pair = struct {
    hi: u64,
    lo: u64,

    /// Shift towards higher byte positions by `s` ∈ [0, 63] (bit j ← bit j-s).
    inline fn shl(x: Pair, s: u6) Pair {
        // `(lo >> 1) >> (63 - s)` is `lo >> (64 - s)` without the invalid
        // 64-bit shift at s = 0 (it yields 0 there, as it should).
        return .{ .hi = (x.hi << s) | ((x.lo >> 1) >> (63 - s)), .lo = x.lo << s };
    }

    /// `shl(s).hi` without computing the low half.
    inline fn shlHi(x: Pair, s: u6) u64 {
        return (x.hi << s) | ((x.lo >> 1) >> (63 - s));
    }

    inline fn @"and"(x: Pair, y: Pair) Pair {
        return .{ .hi = x.hi & y.hi, .lo = x.lo & y.lo };
    }

    const ones: Pair = .{ .hi = ~@as(u64, 0), .lo = ~@as(u64, 0) };
};

/// Bit `j` ⇔ the `len` bytes ending at byte `j` of the pair are all members
/// (`len` ∈ [1, 64]): doubling (`R_2a = R_a & (R_a << a)`) and combining the
/// powers of two in `len` (`R_{a+b} = R_a & (R_b << a)`), all in registers.
/// Only bits whose `len`-byte window lies inside the pair are exact — which
/// is every bit a match end can depend on (`L ≤ 64`).
inline fn runMask(base: Pair, len: u8) Pair {
    var x = base; // R_have
    var have: u7 = 1;
    var acc = Pair.ones;
    var off: u7 = 0;
    var r = len;
    while (true) {
        if (r & 1 != 0) {
            acc = acc.@"and"(x.shl(@intCast(off)));
            off += have;
        }
        r >>= 1;
        if (r == 0) return acc;
        x = x.@"and"(x.shl(@intCast(have)));
        have <<= 1;
    }
}

pub const ClassSeq = struct {
    len: u8,
    n_cls: u8,
    n_runs: u8,
    /// `runs[0..n_gate_runs]` are the gate class's runs (checked first).
    n_gate_runs: u8,
    /// Index of the gate class (fewest members).
    gate: u8,
    /// The gate class's only byte when it has exactly one member (`memchr`
    /// skips gate-free stretches), else `null`.
    gate_byte: ?u8,
    cls: [MAX_CLASSES]class_span.Class,
    runs: [MAX_LEN]Run,

    /// Recognise a whole pattern that is a fixed sequence of byte classes:
    /// only `set` leaves under `concat` / `cap` (and `empty`), no anchors.
    /// `null` when the HIR has any other node, the length is outside
    /// `[2, MAX_LEN]`, it is a pure literal (left to the literal engines),
    /// it needs more than `MAX_CLASSES` distinct classes, or a class cannot be
    /// classified on this target.
    pub fn fromHir(h: anytype) ?ClassSeq {
        if (h.anchored_start or h.anchored_end) return null;
        var bms: [MAX_LEN][32]u8 = undefined;
        var n: usize = 0;
        // Iterative in-order walk; concat chains are left-leaning, so the
        // stack depth tracks the sequence length and is bounded with it.
        var stack: [2 * MAX_LEN + 8]hir.NodeRef = undefined;
        var sp: usize = 0;
        stack[sp] = h.root;
        sp += 1;
        while (sp > 0) {
            sp -= 1;
            const nd = h.node(stack[sp]);
            switch (nd.tag) {
                .empty => {},
                .set => {
                    if (n == MAX_LEN) return null;
                    bms[n] = h.setBitmap(nd.set_idx);
                    n += 1;
                },
                .cap => {
                    if (sp == stack.len) return null;
                    stack[sp] = nd.a;
                    sp += 1;
                },
                .concat => {
                    if (sp + 2 > stack.len) return null;
                    stack[sp] = nd.b;
                    stack[sp + 1] = nd.a; // popped first ⇒ left-to-right
                    sp += 2;
                },
                else => return null,
            }
        }
        return fromPositions(bms[0..n]);
    }

    /// Build from per-position class bitmaps (see `fromHir` for when this is
    /// `null`).
    pub fn fromPositions(bms: []const [32]u8) ?ClassSeq {
        if (bms.len < 2 or bms.len > MAX_LEN) return null;
        var s: ClassSeq = .{
            .len = @intCast(bms.len),
            .n_cls = 0,
            .n_runs = 0,
            .n_gate_runs = 0,
            .gate = 0,
            .gate_byte = null,
            .cls = undefined,
            .runs = undefined,
        };
        var distinct: [MAX_CLASSES][32]u8 = undefined;
        var members: [MAX_CLASSES]usize = undefined;
        var runs: [MAX_LEN]Run = undefined;
        var all_single = true;
        var k: usize = 0;
        while (k < bms.len) {
            // One run: positions k..j-1 share a bitmap.
            var j = k + 1;
            while (j < bms.len and std.mem.eql(u8, &bms[j], &bms[k])) j += 1;
            const ci: usize = for (distinct[0..s.n_cls], 0..) |d, i| {
                if (std.mem.eql(u8, &d, &bms[k])) break i;
            } else blk: {
                if (s.n_cls == MAX_CLASSES) return null;
                const c = class_span.Class.fromBitmap(bms[k]) orelse return null;
                distinct[s.n_cls] = bms[k];
                s.cls[s.n_cls] = c;
                var pop: usize = 0;
                for (bms[k]) |byte| pop += @popCount(byte);
                members[s.n_cls] = pop;
                s.n_cls += 1;
                break :blk s.n_cls - 1;
            };
            if (members[ci] != 1) all_single = false;
            runs[s.n_runs] = .{ .cls = @intCast(ci), .len = @intCast(j - k), .shift = @intCast(bms.len - j) };
            s.n_runs += 1;
            k = j;
        }
        if (all_single) return null; // a literal: Teddy / memchr do better
        for (0..s.n_cls) |i| {
            if (members[i] < members[s.gate]) s.gate = @intCast(i);
        }
        if (members[s.gate] == 1) {
            for (0..256) |b| {
                if (common.hasBit(&distinct[s.gate], @intCast(b))) s.gate_byte = @intCast(b);
            }
        }
        // Gate runs first (AND is order-free).
        var w: usize = 0;
        for (runs[0..s.n_runs]) |run| if (run.cls == s.gate) {
            s.runs[w] = run;
            w += 1;
        };
        s.n_gate_runs = @intCast(w);
        for (runs[0..s.n_runs]) |run| if (run.cls != s.gate) {
            s.runs[w] = run;
            w += 1;
        };
        return s;
    }

    /// AND of `runs[lo..hi]`'s end conditions over the (prev, cur) masks.
    inline fn runEnds(self: *const ClassSeq, lo: usize, hi: usize, cur: *const [MAX_CLASSES]u64, prev: *const [MAX_CLASSES]u64) u64 {
        var e: u64 = ~@as(u64, 0);
        for (self.runs[lo..hi]) |run| {
            const base: Pair = .{ .hi = cur[run.cls], .lo = prev[run.cls] };
            e &= runMask(base, run.len).shlHi(@intCast(run.shift));
            if (e == 0) break;
        }
        return e;
    }

    /// Drive `sink.block(p, endMask) bool` over every block of `input` from
    /// `from` (no context before `from`: a match must start at/after it);
    /// bit `i` of `endMask` ⇔ a match ends at byte `p + i`. Stops early when
    /// the sink returns false.
    inline fn scan(self: *const ClassSeq, input: []const u8, from: usize, sink: anytype) void {
        const g = self.gate;
        var cur: [MAX_CLASSES]u64 = @splat(0);
        var prev: [MAX_CLASSES]u64 = @splat(0);
        // `prev[g]` is always exact; the other `prev[c]` are exact only while
        // `prev_full` (a block rejected by the gate classifies just the gate;
        // they are recomputed from it on demand).
        var prev_full = true;
        var buf: [BLOCK]u8 = undefined;
        var p = from;
        while (p < input.len) {
            // Window [p, p+64): a short tail reuses the input's last 64 bytes
            // (shifted down) or a zero-padded copy; out-of-input bits are
            // cleared, so padding never matches.
            var shift: u6 = 0;
            var valid: u64 = ~@as(u64, 0);
            const src: [*]const u8 = if (p + BLOCK <= input.len)
                input.ptr + p
            else if (input.len >= BLOCK) blk: {
                shift = @intCast(p - (input.len - BLOCK));
                break :blk input.ptr + (input.len - BLOCK);
            } else blk: {
                @memset(&buf, 0);
                @memcpy(buf[0 .. input.len - p], input[p..]);
                valid = (@as(u64, 1) << @intCast(input.len - p)) - 1;
                break :blk &buf;
            };
            const raw = class_span.loadRaw(src);
            cur[g] = (self.cls[g].maskRaw(raw) >> shift) & valid;
            // Gate filter: the gate class's runs alone are a necessary
            // condition ("two `-` exactly 3 apart"); most blocks stop here.
            const eg = self.runEnds(0, self.n_gate_runs, &cur, &prev);
            if (eg == 0) {
                if (self.gate_byte) |gb| if (cur[g] == 0 and p + BLOCK < input.len) {
                    // No gate byte here: any later match has one at/after
                    // p+64. Jump to the block holding the next one (the block
                    // before it is gate-free too, so `prev[g] = 0` holds).
                    const q = std.mem.indexOfScalarPos(u8, input, p + BLOCK, gb) orelse return;
                    p += BLOCK * ((q - p) / BLOCK);
                    prev[g] = 0;
                    prev_full = false;
                    continue;
                };
                prev[g] = cur[g];
                prev_full = false;
                p += BLOCK;
                continue;
            }
            for (0..self.n_cls) |c| {
                if (c != g) cur[c] = (self.cls[c].maskRaw(raw) >> shift) & valid;
            }
            if (!prev_full) {
                // The previous block (a full one inside the input, since a
                // rejected block is never the first) classified only the gate.
                const praw = class_span.loadRaw(input.ptr + p - BLOCK);
                for (0..self.n_cls) |c| {
                    if (c != g) prev[c] = self.cls[c].maskRaw(praw);
                }
                prev_full = true;
            }
            const e = eg & self.runEnds(self.n_gate_runs, self.n_runs, &cur, &prev);
            if (e != 0 and !sink.block(p, e)) return;
            prev = cur;
            p += BLOCK;
        }
    }

    /// Leftmost match starting at/after `from`, or `null`.
    pub fn nextFrom(self: *const ClassSeq, input: []const u8, from: usize) ?Span {
        var sink: struct {
            len: usize,
            found: ?Span = null,
            inline fn block(s: *@This(), p: usize, e: u64) bool {
                const end = p + @ctz(e) + 1;
                s.found = .{ .start = end - s.len, .end = end };
                return false;
            }
        } = .{ .len = self.len };
        self.scan(input, from, &sink);
        return sink.found;
    }

    pub fn isMatch(self: *const ClassSeq, input: []const u8) bool {
        return self.nextFrom(input, 0) != null;
    }

    /// Number of leftmost non-overlapping matches.
    pub fn count(self: *const ClassSeq, input: []const u8) usize {
        var sink: struct {
            len: usize,
            n: usize = 0,
            next_ok: usize = 0, // earliest start not overlapping the last match
            inline fn block(s: *@This(), p: usize, e0: u64) bool {
                var e = e0;
                while (e != 0) : (e &= e - 1) {
                    const end = p + @ctz(e) + 1;
                    if (end - s.len >= s.next_ok) {
                        s.n += 1;
                        s.next_ok = end;
                    }
                }
                return true;
            }
        } = .{ .len = self.len };
        self.scan(input, 0, &sink);
        return sink.n;
    }

    /// Append every leftmost non-overlapping match as `make(input, start, end)`.
    pub fn appendAll(
        self: *const ClassSeq,
        comptime T: type,
        allocator: std.mem.Allocator,
        list: *std.ArrayList(T),
        input: []const u8,
        comptime make: fn ([]const u8, usize, usize) T,
    ) !void {
        var sink: struct {
            len: usize,
            next_ok: usize = 0,
            input: []const u8,
            allocator: std.mem.Allocator,
            list: *std.ArrayList(T),
            err: ?std.mem.Allocator.Error = null,
            inline fn block(s: *@This(), p: usize, e0: u64) bool {
                var e = e0;
                while (e != 0) : (e &= e - 1) {
                    const end = p + @ctz(e) + 1;
                    if (end - s.len >= s.next_ok) {
                        s.list.append(s.allocator, make(s.input, end - s.len, end)) catch |err| {
                            s.err = err;
                            return false;
                        };
                        s.next_ok = end;
                    }
                }
                return true;
            }
        } = .{ .len = self.len, .input = input, .allocator = allocator, .list = list };
        self.scan(input, 0, &sink);
        if (sink.err) |err| return err;
    }
};

// --- tests: every query vs a naive scalar matcher ---

const Oracle = struct {
    bms: []const [32]u8,

    fn at(o: Oracle, s: []const u8, i: usize) bool {
        if (i + o.bms.len > s.len) return false;
        for (o.bms, 0..) |bm, k| {
            if (!common.hasBit(&bm, s[i + k])) return false;
        }
        return true;
    }
    fn next(o: Oracle, s: []const u8, from: usize) ?Span {
        var i = from;
        while (i + o.bms.len <= s.len) : (i += 1) {
            if (o.at(s, i)) return .{ .start = i, .end = i + o.bms.len };
        }
        return null;
    }
    fn all(o: Oracle, gpa: std.mem.Allocator, s: []const u8) !std.ArrayList(Span) {
        var out: std.ArrayList(Span) = .empty;
        var i: usize = 0;
        while (o.next(s, i)) |m| {
            try out.append(gpa, m);
            i = m.end;
        }
        return out;
    }
};

fn testSpan(_: []const u8, start: usize, end: usize) Span {
    return .{ .start = start, .end = end };
}

test "class_seq: every query == naive matcher (random sequences, lengths, offsets)" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xC1A55E9);
    const r = prng.random();
    // A small alphabet makes matches (and overlaps) frequent.
    const alphabet = "0123456789abf:- \xe9";
    const pools = [_][]const u8{ "0123456789", "abf", ":", "-", " -", "0123456789abf", "\xe9a" };
    var store: [8 + 300]u8 = undefined;
    var built: usize = 0;
    var iter: usize = 0;
    while (iter < 400) : (iter += 1) {
        // Random sequence of runs over ≤ 3 pools, total length 2..MAX_LEN.
        var bms: [MAX_LEN][32]u8 = undefined;
        var n: usize = 0;
        const target = 2 + r.uintLessThan(usize, if (iter % 4 == 0) MAX_LEN - 1 else 12);
        const p0 = r.uintLessThan(usize, pools.len);
        while (n < target) {
            const pi = if (r.boolean()) p0 else r.uintLessThan(usize, pools.len);
            var bm: [32]u8 = @splat(0);
            for (pools[pi]) |c| common.setBit(&bm, c);
            const run = @min(target - n, 1 + r.uintLessThan(usize, 6));
            for (0..run) |_| {
                bms[n] = bm;
                n += 1;
            }
        }
        const cs = ClassSeq.fromPositions(bms[0..n]) orelse continue; // > MAX_CLASSES / all literal
        built += 1;
        const o = Oracle{ .bms = bms[0..n] };
        for ([_]usize{ 0, 1, n - 1, n, n + 1, 63, 64, 65, 127, 128, 129, 200, 300 }) |len| {
            const off = r.uintLessThan(usize, 8);
            const s = store[off .. off + len];
            // Bias the haystack towards real matches: plant a few.
            for (s) |*c| c.* = alphabet[r.uintLessThan(usize, alphabet.len)];
            var plant: usize = 0;
            while (plant < 4 and len >= n) : (plant += 1) {
                const at = r.uintLessThan(usize, len - n + 1);
                for (0..n) |k| {
                    var b: u8 = 0;
                    while (!common.hasBit(&bms[k], b)) b +%= 1;
                    s[at + k] = b;
                }
            }
            for (0..len + 1) |from| try std.testing.expectEqual(o.next(s, from), cs.nextFrom(s, from));
            try std.testing.expectEqual(o.next(s, 0) != null, cs.isMatch(s));
            var want = try o.all(gpa, s);
            defer want.deinit(gpa);
            try std.testing.expectEqual(want.items.len, cs.count(s));
            var got: std.ArrayList(Span) = .empty;
            defer got.deinit(gpa);
            try cs.appendAll(Span, gpa, &got, s, testSpan);
            try std.testing.expectEqualSlices(Span, want.items, got.items);
        }
    }
    // Without a byte shuffle, sequences using the 3-range pool are refused.
    try std.testing.expect(built > if (class_span.has_shuffle) 200 else 100);
}

test "class_seq: recognition scope" {
    var digit: [32]u8 = @splat(0);
    for ('0'..'9' + 1) |c| common.setBit(&digit, @intCast(c));
    var colon: [32]u8 = @splat(0);
    common.setBit(&colon, ':');
    // dd:dd:dd → runs (digit 2)(: 1)(digit 2)(: 1)(digit 2), gate = ':'
    const t = ClassSeq.fromPositions(&.{ digit, digit, colon, digit, digit, colon, digit, digit }).?;
    try std.testing.expectEqual(@as(u8, 8), t.len);
    try std.testing.expectEqual(@as(u8, 5), t.n_runs);
    try std.testing.expectEqual(@as(u8, 2), t.n_cls);
    try std.testing.expect(t.cls[t.gate].method == .range and t.cls[t.gate].span[0] == 0);
    // pure literal / too short / empty class ⇒ not this engine
    try std.testing.expect(ClassSeq.fromPositions(&.{ colon, colon }) == null);
    try std.testing.expect(ClassSeq.fromPositions(&.{digit}) == null);
    try std.testing.expect(ClassSeq.fromPositions(&.{ digit, @as([32]u8, @splat(0)) }) == null);
}
