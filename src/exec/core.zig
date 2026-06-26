//! The runtime "core" executor over the meta engine's runtime DFA table
//! (`full_dfa.Dfa256`) plus the planner's literal / prefix-prefilter fast
//! paths. The table-walk semantics are the same algorithm as the comptime
//! `comptime_dfa.Dfa(...)` executor (`runFrom`/`findLeftmost`/`isMatch`), only here
//! the table dimensions are runtime values instead of comptime type
//! parameters; the comptime↔runtime agreement is guarded by
//! `tests/feat_api.zig`'s `Pattern`⇄`Regex` differential.
//!
//! The lazy-DFA fallback lives in `exec/lazy_dfa.zig`; capture
//! reconstruction in `exec/bounded_bt.zig` / `exec/backtrack.zig`.

const std = @import("std");
const full_dfa = @import("full_dfa.zig");
const seq_extract = @import("seq_extract.zig");
const pf = @import("../prefilter.zig");
const planner = @import("../planner.zig");
const search = @import("search.zig");

const Dfa = full_dfa.Dfa256;
const Seq = seq_extract.Seq;

/// Re-export the canonical `Span` so callers keep using `core.Span` while the
/// shared `search.*` helpers and this executor agree on one nominal type.
pub const Span = search.Span;

const DEAD: u16 = 0;

inline fn isAccepting(d: *const Dfa, state: u16) bool {
    return d.accepting[state];
}

/// Anchored leftmost-longest end of a match that begins **exactly** at
/// `start_pos`, or null. Public accessor over `Dfa256.runFrom` for the
/// backtracker's regular-island delegation (see `exec/delegate.zig`).
pub fn matchEndFrom(d: *const Dfa, input: []const u8, start_pos: usize) ?usize {
    return d.runFrom(input, start_pos);
}

/// Verbatim port of `comptime_dfa.Dfa.skipToStart` (the unanchored leading-region
/// prefilter). Only sound when `start` is non-accepting.
inline fn skipToStart(d: *const Dfa, input: []const u8, from: usize) ?usize {
    const n = d.n_start_bytes;
    if (n == 0) return null;
    if (n == 1) return std.mem.indexOfScalarPos(u8, input, from, d.start_bytes[0]);
    if (n <= 8) return std.mem.indexOfAnyPos(u8, input, from, d.start_bytes[0..n]);
    if (from >= input.len) return null;
    const probe_end = @min(from + 16, input.len);
    var i = from;
    while (i < probe_end) : (i += 1) {
        if (pf.inSet(&d.start_byte_set, input[i])) return i;
    }
    if (i >= input.len) return null;
    return pf.nextCandidate(&d.start_byte_set, input, i);
}

/// Selective-literal-prefix leftmost search (the planner's `.prefix_prefilter`
/// / `.lit_prefix`). Thin wrapper over the shared, table-type-agnostic
/// `search.litPrefixFind` (which both this runtime `Dfa256` and the comptime
/// `comptime_dfa.Dfa(ns,nk)` drive). Caller guarantees `!d.a_start` (`runFrom` does not
/// enforce `^`).
pub fn litPrefixFind(d: *const Dfa, t: *const pf.Teddy, input: []const u8) ?Span {
    return search.litPrefixFind(d, t, input);
}

pub fn litPrefixIsMatch(d: *const Dfa, t: *const pf.Teddy, input: []const u8) bool {
    return search.litPrefixIsMatch(d, t, input);
}

/// Verbatim port of `comptime_dfa.Dfa.findLeftmost`.
pub fn findLeftmost(d: *const Dfa, input: []const u8) ?Span {
    // Necessary-condition prefilter: a byte every accepting path must consume.
    // Absent ⇒ no match, proved in one memchr — this is what collapses the
    // unanchored DFA-restart O(n²) (the required tail/inner literal of
    // `a.*…X` / `.*.*=.*` / `(a|ab)*c` never appears in adversarial input).
    if (search.requiredAbsent(d.required, input)) return null;
    if (d.a_start) {
        if (d.runFrom(input, 0)) |e| return .{ .start = 0, .end = e };
        return null;
    }
    // Necessary-literal-anywhere: memchr a rare mandatory byte and recover
    // the match start from it (fixed offset, or a leading set-run), instead
    // of restarting the DFA at every position behind a broad first-byte set.
    if (d.req_lit) |*rl| return search.findViaReqLit(d, input, rl);
    const can_skip = !isAccepting(d, @intCast(d.start));
    var sp: usize = 0;
    while (sp <= input.len) : (sp += 1) {
        if (can_skip) sp = skipToStart(d, input, sp) orelse return null;
        if (d.runFrom(input, sp)) |e| return .{ .start = sp, .end = e };
    }
    return null;
}

inline fn acceptsFrom(d: *const Dfa, input: []const u8, start_pos: usize) bool {
    var state: u16 = @intCast(d.start);
    if (isAccepting(d, state)) return true;
    var i: usize = start_pos;
    while (i < input.len) : (i += 1) {
        state = d.trans[state][d.class_of[input[i]]];
        if (state == DEAD) return false;
        if (isAccepting(d, state)) return true;
    }
    return false;
}

pub fn isMatch(d: *const Dfa, input: []const u8) bool {
    if (search.requiredAbsent(d.required, input)) return false;
    if (d.a_end) return findLeftmost(d, input) != null;
    if (isAccepting(d, @intCast(d.start))) return true;
    if (d.a_start) return acceptsFrom(d, input, 0);
    if (d.req_lit) |*rl| return search.findViaReqLit(d, input, rl) != null;
    const can_skip = !isAccepting(d, @intCast(d.start));
    var sp: usize = 0;
    while (sp <= input.len) : (sp += 1) {
        if (can_skip) sp = skipToStart(d, input, sp) orelse return false;
        if (acceptsFrom(d, input, sp)) return true;
    }
    return false;
}

/// Non-overlapping leftmost spans (zero-width advances by one byte) — mirrors
/// the runtime `findAll` / comptime `Pattern.findAll` semantics.
pub fn findAll(d: *const Dfa, allocator: std.mem.Allocator, input: []const u8) ![]Span {
    var list: std.ArrayList(Span) = .empty;
    errdefer list.deinit(allocator);
    var pos: usize = 0;
    while (pos <= input.len) {
        const sp = findLeftmost(d, input[pos..]) orelse break;
        const abs_start = pos + sp.start;
        const abs_end = pos + sp.end;
        try list.append(allocator, .{ .start = abs_start, .end = abs_end });
        pos = if (abs_end == abs_start) abs_end + 1 else abs_end;
    }
    return list.toOwnedSlice(allocator);
}

// --- Literal / prefilter fast paths (planner strategies 1 & 3) -------------

/// Build the Teddy automaton for `seq` once (call at compile/`compile` time,
/// not per search). `null` if the seq cannot be represented.
pub fn buildLiteral(seq: *const Seq) ?pf.Teddy {
    var bufs: [seq_extract.MAX_ALTS][]const u8 = undefined;
    var n: usize = 0;
    while (n < seq.n) : (n += 1) bufs[n] = seq.lits[n][0..seq.lens[n]];
    return pf.Teddy.build(bufs[0..seq.n]);
}

/// Search with a prebuilt Teddy (no per-call automaton construction). The
/// span end is `start + needle length` — Teddy carries the matched needle's
/// length, so no `Seq` is needed here.
pub fn literalFindT(t: *const pf.Teddy, input: []const u8, from: usize) ?Span {
    const hit = t.find(input, from) orelse return null;
    return .{ .start = hit.start, .end = hit.start + t.len[hit.which] };
}

pub fn literalIsMatchT(t: *const pf.Teddy, input: []const u8) bool {
    return t.find(input, 0) != null;
}

test "core: DFA bounds equal a hand-checked example" {
    const hir = @import("../hir.zig");
    const parser = @import("../parser.zig");
    const thompson = @import("../thompson.zig");

    const H = hir.Hir(256);
    var h = H.initComptime();
    try parser.parse(256, &h, undefined, "ab*c", .{});
    var nfa = try thompson.build(256, &h);
    const d = full_dfa.compute(256, &nfa, h.anchored_start, h.anchored_end);

    try std.testing.expect(isMatch(&d, "ac"));
    try std.testing.expect(isMatch(&d, "abbbc"));
    try std.testing.expect(!isMatch(&d, "ab"));
    const sp = findLeftmost(&d, "xxabbcyy").?;
    try std.testing.expectEqual(@as(usize, 2), sp.start);
    try std.testing.expectEqual(@as(usize, 6), sp.end);
}

test "core: reverse-inner req_lit on/off agree on findAll (differential)" {
    const hir = @import("../hir.zig");
    const parser = @import("../parser.zig");
    const thompson = @import("../thompson.zig");
    const a = std.testing.allocator;

    // Patterns whose only selective literal is INNER (no usable prefix/suffix),
    // so `requiredLiteralBack` returns a multi-byte anchor located via class-back.
    const pats = [_][]const u8{
        "[a-z]+/api/v2/[a-z]+",
        "[a-z]+://[a-z]+",
        "[a-z]+CONNECT[a-z]+",
        "[a-z]*MIDDLE[a-z]*",
    };
    var prng = std.Random.DefaultPrng.init(0xABCDEF1234);
    const rnd = prng.random();
    var saw_multi = false;

    for (pats) |p| {
        var h = hir.Hir(null).initRuntime();
        defer h.deinit(a);
        parser.parse(null, &h, a, p, .{}) catch continue;
        var nfa = thompson.build(null, &h) catch continue;
        var d = full_dfa.compute(null, &nfa, h.anchored_start, h.anchored_end);
        if (d.outcome != .ok) continue;
        const rl = seq_extract.requiredLiteralBack(null, &h) orelse continue;
        if (rl.len >= 2) saw_multi = true;
        const lit = rl.lit[0..rl.len];

        var iter: usize = 0;
        while (iter < 80) : (iter += 1) {
            const len = rnd.intRangeAtMost(usize, 0, 160);
            const buf = try a.alloc(u8, len);
            defer a.free(buf);
            for (buf) |*c| c.* = 'a' + @as(u8, @intCast(rnd.uintLessThan(u8, 8))); // a..h
            // Inject the anchor a few times to force real matches and near-misses.
            var inj: usize = 0;
            while (inj < 3 and len >= lit.len + 2) : (inj += 1) {
                if (rnd.boolean()) {
                    const at = rnd.uintLessThan(usize, len - lit.len);
                    @memcpy(buf[at..][0..lit.len], lit);
                }
            }
            // anchor ON (findViaReqLit) vs OFF (brute-force skipToStart) must match.
            d.req_lit = rl;
            const wa = try findAll(&d, a, buf);
            defer a.free(wa);
            d.req_lit = null;
            const wo = try findAll(&d, a, buf);
            defer a.free(wo);
            std.testing.expectEqualSlices(Span, wo, wa) catch |e| {
                std.debug.print("MISMATCH pat=\"{s}\" buf=\"{s}\"\n", .{ p, buf });
                return e;
            };
        }
    }
    try std.testing.expect(saw_multi); // the test must exercise the multi-byte path
}

test "core: literal strategy via prebuilt Teddy" {
    var seq = Seq{};
    seq.lits[0][0] = 'f';
    seq.lits[0][1] = 'o';
    seq.lits[0][2] = 'o';
    seq.lens[0] = 3;
    seq.n = 1;
    seq.exact = true;
    // The live path: build the Teddy once (compile time) then search with it.
    const t = buildLiteral(&seq).?;
    const sp = literalFindT(&t, "a foo b", 0).?;
    try std.testing.expectEqual(@as(usize, 2), sp.start);
    try std.testing.expectEqual(@as(usize, 5), sp.end);
    try std.testing.expect(literalIsMatchT(&t, "a foo b"));
    try std.testing.expect(!literalIsMatchT(&t, "nope"));
}
