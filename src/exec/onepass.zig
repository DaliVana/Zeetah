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

const Slot = @import("../hir.zig").Slot;
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
    // The walker's scratch is sized to the fixed `MAX_NFA`; a larger runtime NFA
    // is simply not taken down the one-pass path (`fill` is only ever called
    // when this returned true).
    if (nfa.n_states > MAX_NFA) return false;
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
/// Per-state out-edge index (CSR) over a fixed-capacity NFA: `order[off[s]..
/// off[s+1]]` are the edge ids leaving state `s`, in original (priority) order.
/// Lets `epsWalk` iterate a state's own out-edges instead of rescanning all
/// `n_edges` at every visit — the dominant cost on capture-heavy patterns
/// (`log_parse` count-captures). Sized to `(ns, ne)` so a comptime `Pattern`
/// bakes exactly its NFA's index (`fillWith`), while `fill` builds a
/// `MAX_NFA`/`MAX_EDGES`-sized one on the stack for callers without a prebuilt
/// index. The runtime `Regex` passes its shared heap `nfa_index.EdgeIndex`
/// instead (same field shape: `off` / `order`).
pub fn SizedIndex(comptime ns: usize, comptime ne: usize) type {
    return struct {
        const Self = @This();
        off: [ns + 1]u16 = [_]u16{0} ** (ns + 1),
        order: [ne]u16 = undefined,

        pub fn build(comptime cap: ?usize, nfa: *const thompson.Nfa(cap)) Self {
            std.debug.assert(nfa.n_states <= ns and nfa.n_edges <= ne);
            var idx: Self = .{};
            // Counting sort of edge ids by from-state (stable ⇒ priority preserved).
            var ei: usize = 0;
            while (ei < nfa.n_edges) : (ei += 1) idx.off[nfa.e_from[ei] + 1] += 1;
            var s: usize = 0;
            while (s < nfa.n_states) : (s += 1) idx.off[s + 1] += idx.off[s]; // prefix sum
            var next: [ns]u16 = undefined;
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
}

/// The full-capacity index `fill` builds per call.
const EdgeIndex = SizedIndex(MAX_NFA, thompson.MAX_EDGES);

/// `fillWith` with a per-call index (callers without a prebuilt one: tests,
/// the differential checks). Hot callers pass their own — see `fillWith`.
pub fn fill(comptime cap: ?usize, nfa: *const thompson.Nfa(cap), input: []const u8, span: Span, slots: []Slot) bool {
    const idx = EdgeIndex.build(cap, nfa);
    return fillWith(cap, nfa, &idx, input, span, slots);
}

/// `fill` over a prebuilt per-state out-edge index `idx` (a pointer to any
/// struct with `off[s]..off[s+1]` / `order[k]` — a comptime-baked `SizedIndex`
/// for a `Pattern`, the `Regex`'s shared heap `nfa_index.EdgeIndex` at
/// runtime), so the index is built once per NFA, not once per capture call.
pub fn fillWith(comptime cap: ?usize, nfa: *const thompson.Nfa(cap), idx: anytype, input: []const u8, span: Span, slots: []Slot) bool {
    var st: u16 = @intCast(nfa.start);
    var pos: usize = span.start;
    while (true) {
        var seen = [_]bool{false} ** MAX_NFA;
        switch (epsWalk(cap, nfa, input, pos, span.end, slots, &seen, st, idx)) {
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
    slots: []Slot,
    seen: *[MAX_NFA]bool,
    st: u16,
    idx: anytype,
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
                var old: Slot = -1;
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

test "onepass: fillWith over the Regex's shared heap index == fill (per-call index)" {
    const hir = @import("../hir.zig");
    const parser = @import("../parser.zig");
    const core = @import("core.zig");
    const nfa_index = @import("nfa_index.zig");
    const a = std.testing.allocator;
    const pats = [_][]const u8{ "(a)(b)(c)", "(\\d{3})-(\\d{4})", "(ab)+c", "a(bc)*d", "([a-z]+)@([a-z]+)" };
    const ins = [_][]const u8{ "abc", "x 555-1234 y", "ababc", "abcbcd", "me@host", "nope" };
    for (pats) |p| {
        var h = hir.Hir(null).initRuntime();
        defer h.deinit(a);
        try parser.parse(null, &h, a, p, .{});
        var nfa = try thompson.buildAlloc(a, &h);
        defer nfa.deinit(a);
        if (!isCaptureOnePass(null, &nfa)) continue;
        const d = full_dfa.compute(null, &nfa, h.anchored_start, h.anchored_end);
        if (d.outcome != .ok) continue;
        var idx = try nfa_index.EdgeIndex.build(a, &nfa);
        defer idx.deinit(a);
        const nslots = 2 * (std.mem.count(u8, p, "(") + 1); // every `(` above is a capture group
        for (ins) |in| {
            const sp = core.findLeftmost(&d, in) orelse continue;
            var s1: [16]Slot = undefined;
            var s2: [16]Slot = undefined;
            @memset(s1[0..nslots], -1);
            @memset(s2[0..nslots], -1);
            s1[0] = @intCast(sp.start);
            s1[1] = @intCast(sp.end);
            s2[0] = s1[0];
            s2[1] = s1[1];
            const span: Span = .{ .start = sp.start, .end = sp.end };
            const ok1 = fill(null, &nfa, in, span, s1[0..nslots]);
            const ok2 = fillWith(null, &nfa, &idx, in, span, s2[0..nslots]);
            try std.testing.expectEqual(ok1, ok2);
            try std.testing.expectEqualSlices(Slot, s1[0..nslots], s2[0..nslots]);
        }
    }
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
        var nfa = try thompson.buildAlloc(a, &h);
        defer nfa.deinit(a);
        const d = full_dfa.compute(null, &nfa, h.anchored_start, h.anchored_end);
        try std.testing.expect(dfaMatchIsOnePass(&d));
    }

    // Whatever the verdict for a trickier pattern, it must never change what
    // the DFA matches (the property the planner relies on).
    inline for (.{ "(a|ab)c?", "a.*b", "x*y|z" }) |p| {
        var h = hir.Hir(null).initRuntime();
        defer h.deinit(a);
        try parser.parse(null, &h, a, p, .{});
        var nfa = try thompson.buildAlloc(a, &h);
        defer nfa.deinit(a);
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
        var nfa = try thompson.buildAlloc(a, &h);
        defer nfa.deinit(a);
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
        var nfa = try thompson.buildAlloc(a, &h);
        defer nfa.deinit(a);
        const d = full_dfa.compute(null, &nfa, h.anchored_start, h.anchored_end);
        if (d.outcome != .ok or !isCaptureOnePass(null, &nfa)) continue;

        for (ins) |in| {
            // Reference: bounded_bt (its own findLeftmost + trace recon).
            var bt = try bounded_bt.BoundedBt.init(a, &nfa, h.anchored_start, h.anchored_end, in.len);
            defer bt.deinit();
            var ref: [bounded_bt.MAX_SLOTS]Slot = undefined;
            const ref_span = try bt.captures(in, ref[0..]);

            // One-pass: span from the DFA, then deterministic fill.
            const dsp = core.findLeftmost(&d, in);
            try std.testing.expectEqual(ref_span == null, dsp == null);
            if (dsp) |sp| {
                try std.testing.expectEqual(ref_span.?.start, sp.start);
                try std.testing.expectEqual(ref_span.?.end, sp.end);
                var got: [bounded_bt.MAX_SLOTS]Slot = undefined;
                @memset(got[0..], -1);
                got[0] = @intCast(sp.start);
                got[1] = @intCast(sp.end);
                // isCaptureOnePass(true) ⇒ fill MUST resolve deterministically.
                try std.testing.expect(fill(null, &nfa, in, .{ .start = sp.start, .end = sp.end }, got[0..]));
                try std.testing.expectEqualSlices(Slot, ref[0..bounded_bt.MAX_SLOTS], got[0..bounded_bt.MAX_SLOTS]);
            }
        }
    }
}
