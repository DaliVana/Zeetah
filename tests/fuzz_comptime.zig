//! Comptime-vs-runtime differential fuzz. Opt-in:
//! `zig build test -Dfuzz-comptime` (every pattern is a comptime `Pattern`
//! build — parse → NFA → DFA → baked tables in the comptime interpreter — so
//! it is too slow to compile for the default suite).
//!
//! A fixed corpus of patterns from the `nfa_fuzz` generator (run at comptime,
//! fixed seed, filtered by `compilesAtComptime`) is instantiated as comptime
//! `Pattern`s with `inline for`. Each is compared with the runtime `Regex`
//! compiled from the same string, on random inputs: `isMatch`, `find`,
//! non-overlapping iteration (`iterator` vs `findFrom`), `count`, and
//! `capturesFrom` (every group) at each match. The two front-ends share the
//! parser and HIR but select and build their engines through separate
//! cascades (`pattern.zig` `buildAll` vs `regex.zig` `compileWithFlags`) — the
//! place they have drifted apart before.

const std = @import("std");
const zeetah = @import("zeetah");
const fuzz = zeetah.nfa_fuzz;
const Regex = zeetah.Regex;

const N_PATTERNS = 300;

/// `N_PATTERNS` generated patterns that `Pattern` accepts.
const corpus: [N_PATTERNS][]const u8 = blk: {
    @setEvalBranchQuota(1_000_000_000);
    const shapes = fuzz.regular_shapes ++ fuzz.nonregular_shapes;
    var rng = fuzz.Rng{ .s = 0xc0_417e };
    var list: [N_PATTERNS][]const u8 = undefined;
    var n: usize = 0;
    while (n < N_PATTERNS) {
        const g = fuzz.generate(&rng, fuzz.pickShape(&rng, &shapes));
        if (g.overflow) continue;
        const pat: [g.len]u8 = g.buf[0..g.len].*;
        if (!zeetah.compilesAtComptime(&pat, false, false)) continue;
        list[n] = &pat;
        n += 1;
    }
    break :blk list;
};

const Span = struct { start: usize, end: usize };

fn span(x: anytype) ?Span {
    const v = x orelse return null;
    return .{ .start = v.start, .end = v.end };
}

fn spanEq(x: ?Span, y: ?Span) bool {
    if (x == null or y == null) return x == null and y == null;
    return x.?.start == y.?.start and x.?.end == y.?.end;
}

const SpanFmt = struct {
    s: ?Span,
    pub fn format(self: SpanFmt, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.s) |s| try w.print("[{d},{d})", .{ s.start, s.end }) else try w.writeAll("none");
    }
};

fn expectSpan(what: []const u8, pat: []const u8, in: []const u8, from: usize, comptime_s: ?Span, runtime_s: ?Span) !void {
    if (spanEq(comptime_s, runtime_s)) return;
    std.debug.print("\nfuzz_comptime MISMATCH [{s}] pattern=\"{f}\" input=\"{f}\" from={d}: comptime={f} runtime={f}\n", .{
        what, std.zig.fmtString(pat), std.zig.fmtString(in), from, SpanFmt{ .s = comptime_s }, SpanFmt{ .s = runtime_s },
    });
    return error.TestUnexpectedResult;
}

/// `P.capturesFrom` vs `Regex.capturesFrom` at `from`: whole span and every group.
fn expectCaptures(comptime P: type, a: std.mem.Allocator, pat: []const u8, in: []const u8, from: usize, rx: *const Regex) !void {
    const cc = P.capturesFrom(in, from);
    var rm = rx.capturesFrom(a, in, from) catch |e| switch (e) {
        error.MatchBudgetExceeded => return,
        else => return e,
    };
    defer if (rm) |*m| m.deinit(a);
    try expectSpan("capturesFrom", pat, in, from, if (cc) |c| span(c.groups[0]) else null, span(rm));
    const c = cc orelse return;
    const m = rm.?;
    for (1..c.groups.len) |gi| {
        const cg = span(c.groups[gi]);
        const rg = if (gi < m.groups.len) span(m.groups[gi]) else null;
        if (spanEq(cg, rg) and (gi < m.groups.len or cg == null)) continue;
        std.debug.print("\nfuzz_comptime MISMATCH [capturesFrom group {d}] pattern=\"{f}\" input=\"{f}\" from={d}: comptime={f} runtime={f} (runtime groups.len={d})\n", .{
            gi, std.zig.fmtString(pat), std.zig.fmtString(in), from, SpanFmt{ .s = cg }, SpanFmt{ .s = rg }, m.groups.len,
        });
        return error.TestUnexpectedResult;
    }
}

fn checkInput(comptime P: type, a: std.mem.Allocator, pat: []const u8, in: []const u8, rx: *const Regex) !void {
    // Non-overlapping iteration: the comptime iterator drives, the runtime
    // resumes at the same absolute offsets; captures at every match.
    var it = P.iterator(in);
    var pos: usize = 0;
    var n: usize = 0;
    while (it.next()) |cm| {
        const rm = rx.findFrom(in, pos) catch |e| switch (e) {
            error.MatchBudgetExceeded => return,
            else => return e,
        };
        try expectSpan("iterate", pat, in, pos, .{ .start = cm.start, .end = cm.end }, span(rm));
        try expectCaptures(P, a, pat, in, pos, rx);
        n += 1;
        pos = if (cm.end == cm.start) cm.end + 1 else cm.end;
    }
    if (pos <= in.len) {
        const rm = rx.findFrom(in, pos) catch |e| switch (e) {
            error.MatchBudgetExceeded => return,
            else => return e,
        };
        try expectSpan("iterate (comptime exhausted)", pat, in, pos, null, span(rm));
        try expectCaptures(P, a, pat, in, pos, rx);
    }

    const rc = rx.count(in) catch |e| switch (e) {
        error.MatchBudgetExceeded => return,
        else => return e,
    };
    const rim = rx.isMatch(in) catch |e| switch (e) {
        error.MatchBudgetExceeded => return,
        else => return e,
    };
    const rf = rx.find(in) catch |e| switch (e) {
        error.MatchBudgetExceeded => return,
        else => return e,
    };
    try expectSpan("find", pat, in, 0, span(P.find(in)), span(rf));
    const pc = P.count(in);
    const pim = P.isMatch(in);
    if (pc == n and rc == n and pim == (n > 0) and rim == (n > 0)) return;
    std.debug.print("\nfuzz_comptime MISMATCH [count/isMatch] pattern=\"{f}\" input=\"{f}\": iterated={d} comptime count={d} isMatch={} runtime count={d} isMatch={}\n", .{
        std.zig.fmtString(pat), std.zig.fmtString(in), n, pc, pim, rc, rim,
    });
    return error.TestUnexpectedResult;
}

/// Compare one pattern on a handful of inputs. False if the runtime rejects it.
fn checkPattern(comptime P: type, a: std.mem.Allocator, rng: *fuzz.Rng, pat: []const u8) !bool {
    var rx = Regex.compile(a, pat) catch return false;
    defer rx.deinit();
    var buf: [fuzz.MAX_INPUT]u8 = undefined;
    for (0..7) |k| {
        const size: fuzz.InputSize = if (k < 5) .short else if (k == 5) .medium else if (rng.oneIn(10)) .long else continue;
        try checkInput(P, a, pat, fuzz.genInput(rng, &buf, size), &rx);
    }
    return true;
}

test "fuzz_comptime: comptime Pattern agrees with runtime Regex on generated patterns" {
    const a = std.testing.allocator;
    var rng = fuzz.Rng{ .s = 0x5eed_c0de };
    var compared: usize = 0;
    inline for (corpus) |pat| {
        const P = zeetah.Pattern(pat, .{ .on_oversize = .allow_oversized });
        if (try checkPattern(P, a, &rng, pat)) compared += 1;
    }
    // The runtime must accept nearly the whole corpus, or this compares nothing.
    try std.testing.expect(compared * 10 >= corpus.len * 9);
}
