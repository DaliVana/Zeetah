//! Differential fuzz over the NFA tier: random patterns (look-assertions,
//! alternation, greedy/lazy repetition, captures, `(?m)`) × random inputs,
//! checked at every start offset across independently implemented engines:
//!
//!   * `bounded_bt`  — priority-ordered DFS with a `(state,pos)` memo;
//!   * `pikevm`      — breadth-first thread simulation;
//!   * `lazy_dfa`    — subset construction (look mode when the NFA has looks);
//!   * `Regex`       — the public API through its real engine routing
//!                     (count / findAll / captures).
//!
//! All must agree on leftmost-first spans (and the NFA engines on every
//! capture slot). Deterministic seed; sizes kept small for the Debug suite.

const std = @import("std");
const hir = @import("../hir.zig");
const parser = @import("../parser.zig");
const thompson = @import("../thompson.zig");
const bounded_bt = @import("bounded_bt.zig");
const pikevm = @import("pikevm.zig");
const lazy_dfa = @import("lazy_dfa.zig");
const EdgeIndex = @import("nfa_index.zig").EdgeIndex;
const Regex = @import("../regex.zig").Regex;

const Gen = struct {
    rng: std.Random,
    buf: std.ArrayList(u8) = .empty,
    a: std.mem.Allocator,
    groups: usize = 0,

    fn put(self: *Gen, s: []const u8) !void {
        try self.buf.appendSlice(self.a, s);
    }

    fn atom(self: *Gen) !void {
        const atoms = [_][]const u8{ "a", "b", " ", "[ab]", "\\w", "\\s", ".", "[^a]", "\\W", "a", "b" };
        const looks = [_][]const u8{ "\\b", "\\B", "^", "$", "\\A", "\\z", "\\Z" };
        if (self.rng.uintLessThan(u8, 4) == 0) {
            try self.put(looks[self.rng.uintLessThan(usize, looks.len)]);
        } else {
            try self.put(atoms[self.rng.uintLessThan(usize, atoms.len)]);
        }
    }

    fn node(self: *Gen, depth: usize) anyerror!void {
        const k = if (depth == 0) 0 else self.rng.uintLessThan(u8, 7);
        switch (k) {
            0, 1 => try self.atom(),
            2 => { // concat
                try self.node(depth - 1);
                try self.node(depth - 1);
            },
            3 => { // alternation
                try self.put("(?:");
                try self.node(depth - 1);
                try self.put("|");
                try self.node(depth - 1);
                try self.put(")");
            },
            4 => { // capture group
                if (self.groups < 6) {
                    self.groups += 1;
                    try self.put("(");
                    try self.node(depth - 1);
                    try self.put(")");
                } else try self.node(depth - 1);
            },
            else => { // repetition
                try self.put("(?:");
                try self.node(depth - 1);
                try self.put(")");
                const reps = [_][]const u8{ "*", "+", "?", "{0,2}", "{1,3}", "{2}" };
                try self.put(reps[self.rng.uintLessThan(usize, reps.len)]);
                if (self.rng.boolean()) try self.put("?");
            },
        }
    }
};

fn randInput(rng: std.Random, buf: []u8) []u8 {
    const alpha = "ab \n";
    const n = rng.uintLessThan(usize, buf.len + 1);
    for (buf[0..n]) |*c| c.* = alpha[rng.uintLessThan(usize, alpha.len)];
    return buf[0..n];
}

fn spanEq(x: ?bounded_bt.Span, y: ?bounded_bt.Span) bool {
    if (x == null or y == null) return x == null and y == null;
    return x.?.start == y.?.start and x.?.end == y.?.end;
}

fn report(pat: []const u8, in: []const u8, from: usize, what: []const u8, want: ?bounded_bt.Span, got: ?bounded_bt.Span) void {
    std.debug.print("\nnfa_fuzz MISMATCH [{s}] pattern=\"{f}\" input=\"{f}\" from={d}: bt={?} other={?}\n", .{
        what, std.zig.fmtString(pat), std.zig.fmtString(in), from, want, got,
    });
}

test "nfa_fuzz: backtracker, PikeVM, lazy DFA and Regex agree (leftmost-first, looks, captures)" {
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed_100c);
    const rng = prng.random();
    var checked_lazy_look: usize = 0;
    var n_pat: usize = 0;
    while (n_pat < 1500) : (n_pat += 1) {
        var g = Gen{ .rng = rng, .a = a };
        defer g.buf.deinit(a);
        if (rng.uintLessThan(u8, 4) == 0) try g.put("(?m)");
        try g.node(4);
        const pat = g.buf.items;

        var h = hir.Hir(null).initRuntime();
        defer h.deinit(a);
        parser.parse(null, &h, a, pat, .{}) catch continue;
        const props = @import("../properties.zig").analyze(null, &h);
        if (props.requires_backtracking) continue;
        const nfa = try a.create(thompson.Nfa(null));
        defer a.destroy(nfa);
        nfa.* = thompson.buildAlloc(a, &h) catch continue;
        defer nfa.deinit(a);
        var idx = try EdgeIndex.build(a, nfa);
        defer idx.deinit(a);

        var rx = Regex.compile(a, pat) catch continue;
        defer rx.deinit();

        const has_look = lazy_dfa.LazyProg.hasLookEdges(nfa);
        const lazy_ok = !has_look or lazy_dfa.LazyProg.lookSupported(nfa);
        var lz: ?lazy_dfa.LazyProg = if (lazy_ok) try lazy_dfa.LazyProg.init(a, nfa, h.anchored_start, h.anchored_end) else null;
        defer if (lz) |*p| p.deinit();
        var memo = lazy_dfa.LazyMemo.init(a);
        defer memo.deinit();
        var psc = pikevm.PikeScratch.init(a);
        defer psc.deinit();
        const nsl: usize = 2 * (g.groups + 1);

        var ibuf: [10]u8 = undefined;
        var k: usize = 0;
        while (k < 6) : (k += 1) {
            const in = randInput(rng, &ibuf);
            var bt = try bounded_bt.BoundedBt.init(a, nfa, h.anchored_start, h.anchored_end, in.len);
            defer bt.deinit();
            var from: usize = 0;
            while (from <= in.len) : (from += 1) {
                var want_slots: [14]hir.Slot = undefined;
                const want = try bt.capturesFrom(in, from, want_slots[0..nsl]);
                // PikeVM: span + every slot.
                var vm = try pikevm.PikeVm.init(nfa, idx, h.anchored_start, h.anchored_end, &psc, nsl);
                var got_slots: [14]hir.Slot = undefined;
                const got = try vm.search(in, from, .{}, got_slots[0..nsl]);
                if (!spanEq(want, got)) report(pat, in, from, "pikevm", want, got);
                try std.testing.expect(spanEq(want, got));
                if (want != null) try std.testing.expectEqualSlices(hir.Slot, want_slots[0..nsl], got_slots[0..nsl]);
                // Plain search must equal the capturing one.
                const want2 = try bt.findLeftmostFrom(in, from);
                try std.testing.expect(spanEq(want, want2));
                // Lazy DFA (look mode when the NFA has looks).
                if (lz) |*p| {
                    const lg = p.findLeftmostFrom(&memo, in, from) catch |e| switch (e) {
                        error.LazyGaveUp => want, // thrash give-up is allowed
                        else => return e,
                    };
                    if (!spanEq(want, lg)) report(pat, in, from, "lazy_dfa", want, lg);
                    try std.testing.expect(spanEq(want, lg));
                    if (has_look) checked_lazy_look += 1;
                }
            }
            if (lz) |*p| {
                const im = p.isMatchFast(&memo, in) catch true;
                const want0 = (try bt.findLeftmostFrom(in, 0)) != null;
                if (im != want0) report(pat, in, 0, "lazy isMatch", if (want0) .{ .start = 0, .end = 0 } else null, if (im) .{ .start = 0, .end = 0 } else null);
                try std.testing.expectEqual(want0, im);
            }
            // Regex API through its real routing: non-overlapping iteration.
            var pos: usize = 0;
            var n: usize = 0;
            while (pos <= in.len) {
                const w = (try bt.findLeftmostFrom(in, pos)) orelse break;
                const r = try rx.findFrom(in, pos);
                const rs: ?bounded_bt.Span = if (r) |mm| .{ .start = mm.start, .end = mm.end } else null;
                if (!spanEq(w, rs)) report(pat, in, pos, "Regex.findFrom", w, rs);
                try std.testing.expect(spanEq(w, rs));
                n += 1;
                pos = if (w.end > w.start) w.end else w.end + 1;
            }
            const rc = try rx.count(in);
            if (rc != n) std.debug.print("\nnfa_fuzz MISMATCH [count] pattern=\"{f}\" input=\"{f}\" ref={d} Regex.count={d} kind={s}\n", .{ std.zig.fmtString(pat), std.zig.fmtString(in), n, rc, @tagName(rx.kind) });
            try std.testing.expectEqual(n, rc);
            try std.testing.expectEqual(n > 0, try rx.isMatch(in));
            // Captures of the first match.
            var c = try rx.captures(a, in);
            defer if (c) |*x| x.deinit(a);
            var ws: [14]hir.Slot = undefined;
            const w0 = try bt.capturesFrom(in, 0, ws[0..nsl]);
            try std.testing.expectEqual(w0 == null, c == null);
            if (c) |cm| if (cm.groups.len > 0) {
                var gi: usize = 1;
                while (gi <= g.groups) : (gi += 1) {
                    const gs = ws[2 * gi];
                    const ge = ws[2 * gi + 1];
                    const cg = cm.groups[gi];
                    if (gs >= 0 and ge >= 0) {
                        try std.testing.expect(cg != null);
                        try std.testing.expectEqual(@as(usize, @intCast(gs)), cg.?.start);
                        try std.testing.expectEqual(@as(usize, @intCast(ge)), cg.?.end);
                    } else try std.testing.expect(cg == null);
                }
            };
        }
    }
    // The generator must actually exercise the look-mode lazy DFA.
    try std.testing.expect(checked_lazy_look > 1000);
}
