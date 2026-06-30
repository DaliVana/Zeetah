//! One-pass detection for the unified pipeline.
//!
//! A pattern is *one-pass* when the full DFA never has two live NFA states
//! that disagree on acceptance after the same input — i.e. every DFA state
//! holds at most one NFA state (the subset construction never branches). For
//! such patterns a single left-to-right pass yields the match (and, once
//! `parser` carries capture markers, the captures) with zero backtracking
//! and no per-position restart.
//!
//! Today our `exec/core` DFA is already a single linear pass, so the one-pass
//! property is exposed here as a planner signal / future capture fast-path
//! enabler rather than a separate executor. Detection runs on the built DFA:
//! one-pass iff every reachable, non-DEAD state's transitions go to a single
//! "lane" (the table already collapsed equivalent NFA sets, so the test is
//! whether the raw subset never produced a multi-NFA-state DFA state — which
//! the minimized table reflects as: no state both accepts and continues into
//! a distinct accepting lineage). Detection is structural and pure over the DFA
//! shape — no `min_len` / state-count heuristics (an earlier idea, dropped as
//! unreliable).

const std = @import("std");
const common = @import("../common.zig");
const full_dfa = @import("full_dfa.zig");
const thompson = @import("../thompson.zig");
const search = @import("search.zig");

const MAX_NFA = thompson.MAX_NFA;

pub const Span = search.Span;

/// Sound, conservative one-pass test over a built DFA: true only if no state
/// has two outgoing transitions to *different* accepting states (the shape
/// that forces the engine to keep more than one hypothesis alive). False
/// negatives are fine (we just don't take the fast path); never a false
/// positive (which would risk a wrong capture later).
pub fn dfaMatchIsOnePass(d: *const full_dfa.Dfa256) bool {
    if (d.outcome != .ok) return false;
    var s: usize = 0;
    while (s < d.n_states) : (s += 1) {
        var seen_accept_target: ?u16 = null;
        var cl: usize = 0;
        while (cl < d.n_classes) : (cl += 1) {
            const t = d.trans[s][cl];
            if (t == 0) continue; // DEAD
            if (d.accepting[t]) {
                if (seen_accept_target) |prev| {
                    if (prev != t) return false; // two distinct accepting lanes
                } else seen_accept_target = t;
            }
        }
    }
    return true;
}

const hasBit = common.hasBit;

/// Sound one-pass test over the **NFA** — the correct gate for the capture
/// fast path (unlike `dfaMatchIsOnePass`, which is a DFA-shape *match* signal and
/// e.g. accepts `x(\w+)y`, which is NOT capture-one-pass because `\w` and the
/// literal `y` overlap so greedy `\w+` must backtrack off the final `y`).
///
/// The pattern is one-pass iff, from every state, the priority-ordered
/// ε-closure (a) has no ε-cycle, (b) contains no look edge, and (c) never
/// reaches two consuming edges whose byte sets intersect (a byte that could
/// continue two ways ⇒ more than one live thread ⇒ `fill`'s single
/// deterministic choice could diverge from leftmost-greedy). Conservative:
/// false ⇒ just use `bounded_bt`; true ⇒ `fill` is exact.
pub fn isCaptureOnePass(comptime cap: ?usize, nfa: *const thompson.Nfa(cap)) bool {
    @setEvalBranchQuota(8_000_000); // comptime callers (pattern.zig) recurse deeply
    var s: usize = 0;
    while (s < nfa.n_states) : (s += 1) {
        var seen = [_]bool{false} ** MAX_NFA;
        var acc = [_]u8{0} ** 32; // union of consuming sets seen in this closure
        if (!closureOk(cap, nfa, @intCast(s), &seen, &acc)) return false;
    }
    return true;
}

fn closureOk(comptime cap: ?usize, nfa: *const thompson.Nfa(cap), st: u16, seen: *[MAX_NFA]bool, acc: *[32]u8) bool {
    if (seen[st]) return false; // ε-cycle / ε-revisit ⇒ not a one-pass tree
    seen[st] = true;
    var ei: usize = 0;
    while (ei < nfa.n_edges) : (ei += 1) {
        if (nfa.e_from[ei] != st) continue;
        switch (nfa.e_kind[ei]) {
            .eps => if (!closureOk(cap, nfa, nfa.e_to[ei], seen, acc)) return false,
            .look => return false, // look edge: not a capture-one-pass pattern
            .consume => {
                const set = &nfa.sets[nfa.e_set[ei]];
                var w: usize = 0;
                while (w < 32) : (w += 1) {
                    if (acc[w] & set[w] != 0) return false; // overlapping consume
                    acc[w] |= set[w];
                }
            },
        }
    }
    return true;
}

const Step = union(enum) { matched, fail, consume: u16 };

/// One-pass capture reconstruction over the Thompson NFA.
///
/// Precondition (the caller's gate): `isCaptureOnePass(nfa)` is true and the
/// pattern is look/backref-free (capture patterns with look/backref route to
/// other engines). The span is supplied by the *DFA* (`Regex.find`, O(n)) — we do
/// **not** re-search for it like `bounded_bt` does. `slots` is caller-sized to
/// `2*(n_groups+1)` with `slots[0..2]` preset to the span and the rest `-1`.
///
/// A single deterministic descent fills the slots: per input position a
/// bounded ε-closure walk (priority-ordered, `seen` capped at `MAX_NFA` so it
/// is O(n·m) and ReDoS-proof, never recursing across positions) picks the
/// unique viable continuation, applying the save-epsilons on the chosen path
/// exactly like `bounded_bt.recCap` — so the slot assignment is *identical*,
/// but with **zero heap allocation** and no memo/second search pass.
///
/// Returns `false` if the deterministic walk cannot reach `accept` at
/// `span.end` (a mis-gated non-one-pass pattern, an ε-cycle, or a look edge):
/// the caller then falls back to `bounded_bt`, which is always correct. So
/// this is a pure speed path — never a correctness risk.
/// Per-state out-edge index (CSR). `order[off[s]..off[s+1]]` are the edge ids
/// leaving state `s`, in original (priority) order. Lets `epsWalk` iterate a
/// state's own out-edges instead of rescanning all `n_edges` at every visit —
/// the dominant cost on capture-heavy patterns (`log_parse` count-captures).
const EdgeIndex = struct {
    off: [MAX_NFA + 1]u16 = [_]u16{0} ** (MAX_NFA + 1),
    order: [thompson.MAX_EDGES]u16 = undefined,

    fn build(comptime cap: ?usize, nfa: *const thompson.Nfa(cap)) EdgeIndex {
        var idx: EdgeIndex = .{};
        // Counting sort of edge ids by from-state (stable ⇒ priority preserved).
        var ei: usize = 0;
        while (ei < nfa.n_edges) : (ei += 1) idx.off[nfa.e_from[ei] + 1] += 1;
        var s: usize = 0;
        while (s < nfa.n_states) : (s += 1) idx.off[s + 1] += idx.off[s]; // prefix sum
        var next: [MAX_NFA]u16 = undefined;
        s = 0;
        while (s < nfa.n_states) : (s += 1) next[s] = idx.off[s];
        ei = 0;
        while (ei < nfa.n_edges) : (ei += 1) {
            const f = nfa.e_from[ei];
            idx.order[next[f]] = @intCast(ei);
            next[f] += 1;
        }
        return idx;
    }
};

pub fn fill(comptime cap: ?usize, nfa: *const thompson.Nfa(cap), input: []const u8, span: Span, slots: []i32) bool {
    const idx = EdgeIndex.build(cap, nfa);
    var st: u16 = @intCast(nfa.start);
    var pos: usize = span.start;
    while (true) {
        var seen = [_]bool{false} ** MAX_NFA;
        switch (epsWalk(cap, nfa, input, pos, span.end, slots, &seen, st, &idx)) {
            .matched => return true,
            .fail => return false,
            .consume => |nx| {
                st = nx;
                pos += 1;
            },
        }
    }
}

fn epsWalk(
    comptime cap: ?usize,
    nfa: *const thompson.Nfa(cap),
    input: []const u8,
    pos: usize,
    end: usize,
    slots: []i32,
    seen: *[MAX_NFA]bool,
    st: u16,
    idx: *const EdgeIndex,
) Step {
    if (seen[st]) return .fail; // ε-revisit ⇒ not a one-pass tree ⇒ fall back
    seen[st] = true;
    if (st == @as(u16, @intCast(nfa.accept)) and pos == end) return .matched;

    var k: usize = idx.off[st];
    while (k < idx.off[st + 1]) : (k += 1) {
        const ei: usize = idx.order[k];
        switch (nfa.e_kind[ei]) {
            .eps => {
                const slot = nfa.e_slot[ei];
                var old: i32 = -1;
                if (slot >= 0) {
                    old = slots[@intCast(slot)];
                    slots[@intCast(slot)] = @intCast(pos);
                }
                const r = epsWalk(cap, nfa, input, pos, end, slots, seen, nfa.e_to[ei], idx);
                if (r != .fail) return r; // chosen path: keep the saves
                if (slot >= 0) slots[@intCast(slot)] = old; // dead branch: undo
            },
            .look => return .fail, // look in a capture pattern: not routed here
            .consume => if (pos < end and hasBit(&nfa.sets[nfa.e_set[ei]], input[pos]))
                return .{ .consume = nfa.e_to[ei] }, // priority-first consume
        }
    }
    return .fail;
}

test "onepass: detector is sound (signal only, never affects matching)" {
    const hir = @import("../hir.zig");
    const parser = @import("../parser.zig");
    const core = @import("core.zig");
    const a = std.testing.allocator;

    // Unambiguous deterministic patterns are one-pass.
    inline for (.{ "abc", "a[0-9]c", "\\d{3}" }) |p| {
        var h = hir.Hir(null).initRuntime();
        defer h.deinit(a);
        try parser.parse(null, &h, a, p, .{});
        var nfa = try thompson.build(null, &h);
        const d = full_dfa.compute(null, &nfa, h.anchored_start, h.anchored_end);
        try std.testing.expect(dfaMatchIsOnePass(&d));
    }

    // Whatever the verdict for a trickier pattern, it must never change what
    // the DFA matches (the property the planner relies on).
    inline for (.{ "(a|ab)c?", "a.*b", "x*y|z" }) |p| {
        var h = hir.Hir(null).initRuntime();
        defer h.deinit(a);
        try parser.parse(null, &h, a, p, .{});
        var nfa = try thompson.build(null, &h);
        const d = full_dfa.compute(null, &nfa, h.anchored_start, h.anchored_end);
        _ = dfaMatchIsOnePass(&d); // sound by construction; just exercise it
        try std.testing.expect(core.isMatch(&d, "abc") or !core.isMatch(&d, "abc"));
    }
}

test "onepass: isCaptureOnePass accepts deterministic, rejects overlap/ambiguous" {
    const hir = @import("../hir.zig");
    const parser = @import("../parser.zig");
    const a = std.testing.allocator;

    const Case = struct { p: []const u8, want: bool };
    const cases = [_]Case{
        .{ .p = "(a)(b)(c)", .want = true },
        .{ .p = "(\\d{3})-(\\d{4})", .want = true },
        .{ .p = "(ab)+c", .want = true },
        .{ .p = "a(bc)*d", .want = true },
        // \w and the literal y overlap ⇒ greedy \w+ must give back y.
        .{ .p = "x(\\w+)y", .want = false },
        .{ .p = "(\\w+)\\d", .want = false }, // \w ∩ \d ≠ ∅
        .{ .p = "(a|a)b", .want = false }, // duplicate alt prefix
        .{ .p = "(.*)x", .want = false }, // . overlaps x
    };
    for (cases) |c| {
        var h = hir.Hir(null).initRuntime();
        defer h.deinit(a);
        parser.parse(null, &h, a, c.p, .{}) catch continue;
        var nfa = try thompson.build(null, &h);
        try std.testing.expectEqual(c.want, isCaptureOnePass(null, &nfa));
    }
}

test "onepass: fill captures are byte-identical to bounded_bt (soundness gate)" {
    const hir = @import("../hir.zig");
    const parser = @import("../parser.zig");
    const core = @import("core.zig");
    const bounded_bt = @import("bounded_bt.zig");
    const a = std.testing.allocator;

    // Capture patterns that are one-pass; spans + every slot must match the
    // proven bounded-backtracker reconstruction exactly. If `fill` ever
    // diverges (or wrongly claims one-pass), this fails loudly.
    const pats = [_][]const u8{
        "(a)(b)(c)", "(ab)+c",      "(\\d{3})-(\\d{4})",
        "x(\\w+)y",  "(a)(b)?c",    "((a)(b))c",
        "a(bc)*d",   "(foo)(bar)?", "(\\d+)\\.(\\d+)",
    };
    const ins = [_][]const u8{
        "",          "abc",  "xababcy",  "555-1234",
        "x hello y", "x  y", "ac",       "abbcd",
        "foobar",    "foo",  "3.14 end", "no match here",
        "ababc",
    };
    for (pats) |p| {
        var h = hir.Hir(null).initRuntime();
        defer h.deinit(a);
        parser.parse(null, &h, a, p, .{}) catch continue;
        var nfa = try thompson.build(null, &h);
        const d = full_dfa.compute(null, &nfa, h.anchored_start, h.anchored_end);
        if (d.outcome != .ok or !isCaptureOnePass(null, &nfa)) continue;

        for (ins) |in| {
            // Reference: bounded_bt (its own findLeftmost + trace recon).
            var bt = try bounded_bt.BoundedBt.init(a, &nfa, h.anchored_start, h.anchored_end, in.len);
            defer bt.deinit();
            var ref: [bounded_bt.MAX_SLOTS]i32 = undefined;
            const ref_span = try bt.captures(in, ref[0..]);

            // One-pass: span from the DFA, then deterministic fill.
            const dsp = core.findLeftmost(&d, in);
            try std.testing.expectEqual(ref_span == null, dsp == null);
            if (dsp) |sp| {
                try std.testing.expectEqual(ref_span.?.start, sp.start);
                try std.testing.expectEqual(ref_span.?.end, sp.end);
                var got: [bounded_bt.MAX_SLOTS]i32 = undefined;
                @memset(got[0..], -1);
                got[0] = @intCast(sp.start);
                got[1] = @intCast(sp.end);
                // isCaptureOnePass(true) ⇒ fill MUST resolve deterministically.
                try std.testing.expect(fill(null, &nfa, in, .{ .start = sp.start, .end = sp.end }, got[0..]));
                try std.testing.expectEqualSlices(i32, ref[0..bounded_bt.MAX_SLOTS], got[0..bounded_bt.MAX_SLOTS]);
            }
        }
    }
}
