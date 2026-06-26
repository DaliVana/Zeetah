//! Full-DFA construction: byte-equivalence-class compression + leftmost-first
//! subset construction (with the leftmost-first accept cut) + Moore
//! partition-refinement minimization + the unanchored-search start-byte
//! prefilter.
//!
//! This is the trusted DFA core. It reads the flat NFA produced by
//! `thompson.zig` (from the unified `parser`→`hir` front-end); the NFA's
//! state numbering and epsilon priority order are deterministic, so the
//! construction is reproducible. The comptime path (`pattern.zig` →
//! `comptime_dfa.Dfa`) and this runtime path (`exec/core.zig` over `Dfa256`) must
//! agree — guarded by `tests/feat_api.zig`'s `Pattern`⇄`Regex` differential.

const std = @import("std");
const pf = @import("../prefilter.zig");
const thompson = @import("../thompson.zig");
const seq_extract = @import("seq_extract.zig");
const dfa_build = @import("dfa_build.zig");

const MAX_NFA = thompson.MAX_NFA;
const MAX_EDGES = thompson.MAX_EDGES;
const MAX_DFA: usize = 256; // internal array ceiling (explosion sentinel)

const E = error{TooComplex};

pub const Outcome = enum { ok, exploded };

inline fn hasBit(set: *const [32]u8, c: u8) bool {
    return (set[c >> 3] & (@as(u8, 1) << @as(u3, @intCast(c & 7)))) != 0;
}

pub const Dfa256 = struct {
    class_of: [256]u8,
    n_classes: usize,
    n_states: usize,
    start: usize,
    a_start: bool,
    a_end: bool,
    accepting: [MAX_DFA]bool,
    /// Dense transition table, `[state][byte-class] → next state`. The runtime
    /// `Dfa256` is a pre-sized table at the `MAX_DFA` (256-state) ceiling and
    /// keeps every cell `u16`-wide unconditionally — it does **not** specialize
    /// the cell width to the minimized state count the way the comptime
    /// `comptime_dfa.Dfa(ns, nk)` does (that one narrows `StateInt` to `u8` when
    /// `ns ≤ 256`). The fixed-size table trades a wider cell for not having to
    /// monomorphize a table type per pattern on the runtime path.
    trans: [MAX_DFA][256]u16,
    start_bytes: [256]u8,
    n_start_bytes: usize,
    start_byte_set: [32]u8,
    outcome: Outcome,
    /// Optional necessary-condition prefilter: a single byte that *every*
    /// accepting path must consume (a mandatory single-byte set on the root
    /// concat spine). When set and absent from the haystack, the search can
    /// answer "no match" in one `memchr` pass — this is what keeps unanchored
    /// patterns whose required tail/inner literal never appears (e.g.
    /// `a.*…X`, `.*.*=.*`, `(a|ab)*c`) linear instead of O(n²). Populated by
    /// the caller via `seq_extract.requiredByte`; `null` ⇒ no prefilter.
    required: ?u8 = null,
    /// Necessary-literal-anywhere prefilter: a rare mandatory byte + a
    /// recipe to recover the match start from its position. Drives
    /// `core.findLeftmost` to `memchr` candidate regions instead of the
    /// broad-first-byte per-position restart. `null` ⇒ not applicable.
    req_lit: ?seq_extract.ReqLit = null,

    /// Anchored leftmost-first run from `start_pos`: walk the table consuming
    /// input until the DEAD sink (state 0) or end of input, tracking the last
    /// accepting position reached (the leftmost-first end for the surviving
    /// lineage — the priority cut is baked in at construction). With `a_end`,
    /// only an accepting prefix that consumes through `input.len` qualifies.
    ///
    /// This is the single search primitive the generic prefilter layer
    /// (`exec/search.zig`) drives; it mirrors the comptime `comptime_dfa.Dfa.runFrom`,
    /// and the two are pinned equal by `tests/feat_api.zig`'s differential.
    ///
    /// `inline`: this is the innermost loop body of `core.findLeftmost` /
    /// `isMatch`, which previously inlined a file-private `runFrom`. Forcing
    /// inline keeps the cross-file method call zero-cost (no throughput
    /// regression on the DFA hot path).
    /// Next state from `state` on byte-class `cls`. The table-access primitive
    /// shared with the comptime `comptime_dfa.Dfa` (whose field is named
    /// `transitions`, not `trans`) so generic walkers — e.g. `edge_look.nextFrom`
    /// — drive either representation uniformly.
    pub inline fn step(self: *const Dfa256, state: u16, cls: u8) u16 {
        return self.trans[state][cls];
    }

    pub inline fn runFrom(self: *const Dfa256, input: []const u8, start_pos: usize) ?usize {
        var state: u16 = @intCast(self.start);
        var last_accept: ?usize = if (self.accepting[state]) start_pos else null;
        var i: usize = start_pos;
        while (i < input.len) : (i += 1) {
            const cls = self.class_of[input[i]];
            state = self.trans[state][cls];
            if (state == 0) break; // DEAD sink
            if (self.accepting[state]) last_accept = i + 1;
        }
        if (self.a_end) {
            if (last_accept) |e| {
                if (e == input.len) return e;
            }
            return null;
        }
        return last_accept;
    }
};

/// Subset-construction state interner shared by `compute` and `computeReverse`:
/// the id of the NFA-set `want[0..want_len]` (DEAD sink `0` for the empty set),
/// added if new. `E.TooComplex` once the `MAX_DFA` ceiling is reached. Both
/// callers key by the raw `want` slice, so each must hand it in a canonical
/// order (the cut for `compute`, a sort for `computeReverse`).
fn findOrAdd(lists: *[MAX_DFA][MAX_NFA]u16, lens: *[MAX_DFA]usize, n: *usize, want: *const [MAX_NFA]u16, want_len: usize) E!usize {
    if (want_len == 0) return 0; // DEAD
    var k: usize = 0;
    while (k < n.*) : (k += 1) {
        if (lens[k] != want_len) continue;
        if (std.mem.eql(u16, lists[k][0..want_len], want[0..want_len])) return k;
    }
    if (n.* >= MAX_DFA) return E.TooComplex;
    const id = n.*;
    var j: usize = 0;
    while (j < want_len) : (j += 1) lists[id][j] = want[j];
    lens[id] = want_len;
    n.* += 1;
    return id;
}

/// Build the **reverse** DFA for the comptime `$`/`\z`-anchored single-pass
/// search (`comptime_dfa.Dfa.findAnchoredEnd`), the compile-time peer of the
/// runtime `lazy_dfa.findAnchoredEndFrom` / `DenseSearch`(a_end) reverse pass.
///
/// A `$`-anchored match must end at `input.len`, so the search reads the input
/// BACKWARD from `input.len`: the pattern matches a suffix ending there iff the
/// reverse automaton (the subset construction of the *reversed* NFA — every
/// edge flipped, `start`↔`accept` swapped) reaches the forward start, with the
/// leftmost such position as the match start. Two deviations from `compute`:
///   1. **No leftmost-first accept-cut.** `closure` is called with a sentinel
///      accept so it never truncates: the reverse pass needs *pure* reachability
///      (the cut would drop a lower-priority thread that leads to an earlier
///      start — the very bug the forward `Σ*?` pass hits on `ab$` over "ababab").
///   2. **`accepting[s]` is redefined** as "this NFA set contains the FORWARD
///      start" (i.e. a match starts here), not "contains the forward accept".
///
/// No minimization (the reverse DFA of a `$`-validator is tiny; an oversized one
/// returns `.exploded` and the caller keeps the forward per-offset path — no
/// regression, just no speed-up). Patterns with conditional `look` edges
/// (`e_kind == 2`) are rejected here (they never reach the regular `.dfa` arm
/// anyway). The prefilter / start-byte fields are left empty: the reverse walk
/// uses only `transitions` / `accepting` / `start` / `class_of`.
pub fn computeReverse(comptime cap: ?usize, nfa: *const thompson.Nfa(cap)) Dfa256 {
    @setEvalBranchQuota(4_000_000);

    // Reversed NFA: flip every edge and swap start↔accept. A conditional `look`
    // edge has no meaningful reverse here — bail (caller keeps the forward path).
    var rev = nfa.*;
    {
        var ei: usize = 0;
        while (ei < rev.n_edges) : (ei += 1) {
            if (rev.e_kind[ei] == 2) return emptyDfa256(.exploded);
            const f = rev.e_from[ei];
            rev.e_from[ei] = rev.e_to[ei];
            rev.e_to[ei] = f;
        }
        const t = rev.start;
        rev.start = rev.accept;
        rev.accept = t;
    }
    const fwd_start: u16 = @intCast(rev.accept); // == original nfa.start

    const cls = dfa_build.classify(cap, &rev);
    const class_of = cls.class_of;
    const n_classes = cls.n_classes;
    const rep = cls.rep;

    var eps_to = [_]u16{0} ** MAX_EDGES;
    var eps_off = [_]usize{0} ** (MAX_NFA + 1);
    var cnt_to = [_]u16{0} ** MAX_EDGES;
    var cnt_set = [_]u16{0} ** MAX_EDGES;
    var cnt_off = [_]usize{0} ** (MAX_NFA + 1);
    dfa_build.buildForwardCsr(cap, &rev, &eps_to, &eps_off, &cnt_to, &cnt_set, &cnt_off);

    var dfa_list: [MAX_DFA][MAX_NFA]u16 = undefined;
    var dfa_len = [_]usize{0} ** MAX_DFA;
    var trans = [_][256]usize{[_]usize{0} ** 256} ** MAX_DFA;
    var accepting = [_]bool{false} ** MAX_DFA;
    dfa_len[0] = 0; // state 0 = DEAD sink
    var dfa_n: usize = 1;

    const SENTINEL: u16 = std.math.maxInt(u16); // never a real state ⇒ no cut

    const containsStart = struct {
        fn run(list: []const u16, target: u16) bool {
            for (list) |s| if (s == target) return true;
            return false;
        }
    }.run;

    // `findOrAdd` is the shared file-level interner (above).

    var start_buf: [MAX_NFA]u16 = undefined;
    var dummy_acc = false;
    const start_seeds = [_]u16{@intCast(rev.start)};
    const start_len = dfa_build.closure(&eps_to, &eps_off, SENTINEL, &start_seeds, &start_buf, &dummy_acc);
    // Canonical key for `findOrAdd`: the no-cut closure is pure reachability, so
    // the same NFA-set can arrive in different DFS orders — sort to dedup it to
    // ONE reverse-DFA state (mirrors `lazy_memo.rintern`). Without this, spurious
    // distinct-but-equivalent states inflate the count and can trip `MAX_DFA`
    // (→ `.exploded` → the caller keeps the O(n²) forward path) needlessly.
    std.mem.sort(u16, start_buf[0..start_len], {}, std.sort.asc(u16));
    const start_id = findOrAdd(&dfa_list, &dfa_len, &dfa_n, &start_buf, start_len) catch {
        return emptyDfa256(.exploded);
    };
    accepting[start_id] = containsStart(start_buf[0..start_len], fwd_start);

    var work_head: usize = 1;
    while (work_head < dfa_n) : (work_head += 1) {
        const cur_len = dfa_len[work_head];
        var cl: usize = 0;
        while (cl < n_classes) : (cl += 1) {
            const sym = rep[cl];
            var seeds: [MAX_EDGES]u16 = undefined;
            var n_seeds: usize = 0;
            var li: usize = 0;
            while (li < cur_len) : (li += 1) {
                const nstate = dfa_list[work_head][li];
                var cj: usize = cnt_off[nstate];
                while (cj < cnt_off[nstate + 1]) : (cj += 1) {
                    if (hasBit(&rev.sets[cnt_set[cj]], sym)) {
                        seeds[n_seeds] = cnt_to[cj];
                        n_seeds += 1;
                    }
                }
            }
            if (n_seeds == 0) {
                trans[work_head][cl] = 0; // DEAD
                continue;
            }
            var tgt_buf: [MAX_NFA]u16 = undefined;
            var tacc = false;
            const tgt_len = dfa_build.closure(&eps_to, &eps_off, SENTINEL, seeds[0..n_seeds], &tgt_buf, &tacc);
            std.mem.sort(u16, tgt_buf[0..tgt_len], {}, std.sort.asc(u16)); // canonical key (see start)
            const id = findOrAdd(&dfa_list, &dfa_len, &dfa_n, &tgt_buf, tgt_len) catch {
                return emptyDfa256(.exploded);
            };
            trans[work_head][cl] = id;
            if (id != 0) accepting[id] = containsStart(tgt_buf[0..tgt_len], fwd_start);
        }
    }
    accepting[0] = false; // DEAD never accepts

    if (dfa_n > MAX_DFA) return emptyDfa256(.exploded);

    var out = emptyDfa256(.ok);
    out.class_of = class_of;
    out.n_classes = n_classes;
    out.n_states = dfa_n;
    out.start = start_id;
    out.a_start = false;
    out.a_end = false;
    {
        var s: usize = 0;
        while (s < dfa_n) : (s += 1) {
            out.accepting[s] = accepting[s];
            var cl: usize = 0;
            while (cl < n_classes) : (cl += 1) out.trans[s][cl] = @intCast(trans[s][cl]);
        }
    }
    out.accepting[0] = false;
    return out;
}

pub fn emptyDfa256(outcome: Outcome) Dfa256 {
    return .{
        .class_of = [_]u8{0} ** 256,
        .n_classes = 1,
        .n_states = 1,
        .start = 0,
        .a_start = false,
        .a_end = false,
        .accepting = [_]bool{false} ** MAX_DFA,
        .trans = [_][256]u16{[_]u16{0} ** 256} ** MAX_DFA,
        .start_bytes = [_]u8{0} ** 256,
        .n_start_bytes = 0,
        .start_byte_set = [_]u8{0} ** 32,
        .outcome = outcome,
    };
}

/// Subset-construct and Moore-minimize the DFA for `nfa`. Returns
/// `.exploded` if the internal `MAX_DFA` ceiling is hit. Minimization is
/// always run: the compile-time cost is small even on throwaway recogniser
/// DFAs (measured ~2% on `tokenizer`), and the resulting compact table keeps
/// the runtime walk cache-friendly for *all* callers uniformly.
pub fn compute(comptime cap: ?usize, nfa: *const thompson.Nfa(cap), a_start: bool, a_end: bool) Dfa256 {
    @setEvalBranchQuota(4_000_000);

    const nfa_start = nfa.start;
    const nfa_accept = nfa.accept;

    // --- Byte equivalence classes (shared with the lazy engine) -----------
    const cls = dfa_build.classify(cap, nfa);
    const class_of = cls.class_of;
    const n_classes = cls.n_classes;
    const rep = cls.rep;

    // --- Leftmost-first subset construction (CSR adjacency) ----------------
    var eps_to = [_]u16{0} ** MAX_EDGES;
    var eps_off = [_]usize{0} ** (MAX_NFA + 1);
    var cnt_to = [_]u16{0} ** MAX_EDGES;
    var cnt_set = [_]u16{0} ** MAX_EDGES;
    var cnt_off = [_]usize{0} ** (MAX_NFA + 1);
    dfa_build.buildForwardCsr(cap, nfa, &eps_to, &eps_off, &cnt_to, &cnt_set, &cnt_off);

    var dfa_list: [MAX_DFA][MAX_NFA]u16 = undefined;
    var dfa_len = [_]usize{0} ** MAX_DFA;
    var trans = [_][256]usize{[_]usize{0} ** 256} ** MAX_DFA;
    var accepting = [_]bool{false} ** MAX_DFA;

    dfa_len[0] = 0; // state 0 = DEAD sink
    var dfa_n: usize = 1;

    // Priority-ordered ε-closure + accept cut: shared with the lazy engine
    // (`exec/dfa_build.zig`). Local alias keeps the call sites terse.
    const Cl = struct {
        inline fn build(
            eps_to_: *const [MAX_EDGES]u16,
            eps_off_: *const [MAX_NFA + 1]usize,
            accept: u16,
            seeds: []const u16,
            out_list: *[MAX_NFA]u16,
            accept_flag: *bool,
        ) usize {
            return dfa_build.closure(eps_to_, eps_off_, accept, seeds, out_list, accept_flag);
        }
    };

    // `findOrAdd` is the shared file-level interner (above).

    var start_buf: [MAX_NFA]u16 = undefined;
    var start_acc = false;
    const start_seeds = [_]u16{@intCast(nfa_start)};
    const start_len = Cl.build(&eps_to, &eps_off, @intCast(nfa_accept), &start_seeds, &start_buf, &start_acc);
    const start_id = findOrAdd(&dfa_list, &dfa_len, &dfa_n, &start_buf, start_len) catch {
        return emptyDfa256(.exploded);
    };
    accepting[start_id] = start_acc;

    var work_head: usize = 1;
    while (work_head < dfa_n) : (work_head += 1) {
        const cur_len = dfa_len[work_head];
        var cl: usize = 0;
        while (cl < n_classes) : (cl += 1) {
            const sym = rep[cl];
            var seeds: [MAX_EDGES]u16 = undefined;
            var n_seeds: usize = 0;
            var li: usize = 0;
            while (li < cur_len) : (li += 1) {
                const nstate = dfa_list[work_head][li];
                var cj: usize = cnt_off[nstate];
                while (cj < cnt_off[nstate + 1]) : (cj += 1) {
                    if (hasBit(&nfa.sets[cnt_set[cj]], sym)) {
                        seeds[n_seeds] = cnt_to[cj];
                        n_seeds += 1;
                    }
                }
            }
            if (n_seeds == 0) {
                trans[work_head][cl] = 0; // DEAD
                continue;
            }
            var tgt_buf: [MAX_NFA]u16 = undefined;
            var tgt_acc = false;
            const tgt_len = Cl.build(&eps_to, &eps_off, @intCast(nfa_accept), seeds[0..n_seeds], &tgt_buf, &tgt_acc);
            const id = findOrAdd(&dfa_list, &dfa_len, &dfa_n, &tgt_buf, tgt_len) catch {
                return emptyDfa256(.exploded);
            };
            trans[work_head][cl] = id;
            if (id != 0) accepting[id] = tgt_acc;
        }
    }
    accepting[0] = false; // DEAD never accepts

    // --- Minimization: Moore partition refinement ------------------------
    // Initial partition: accepting vs non-accepting.
    var part = [_]usize{0} ** MAX_DFA;
    {
        var s: usize = 0;
        while (s < dfa_n) : (s += 1) part[s] = if (accepting[s]) 1 else 0;
    }

    var changed = true;
    while (changed) {
        changed = false;
        var s: usize = 0;
        while (s < dfa_n) : (s += 1) {
            var t = s + 1;
            while (t < dfa_n) : (t += 1) {
                if (part[s] != part[t]) continue;
                var split = false;
                var cl: usize = 0;
                while (cl < n_classes) : (cl += 1) {
                    if (part[trans[s][cl]] != part[trans[t][cl]]) {
                        split = true;
                        break;
                    }
                }
                if (split) {
                    const old = part[t];
                    const fresh = blk: {
                        var mx: usize = 0;
                        var z: usize = 0;
                        while (z < dfa_n) : (z += 1) mx = @max(mx, part[z]);
                        break :blk mx + 1;
                    };
                    var z: usize = 0;
                    while (z < dfa_n) : (z += 1) {
                        if (part[z] != old) continue;
                        var diff = false;
                        var c2: usize = 0;
                        while (c2 < n_classes) : (c2 += 1) {
                            if (part[trans[z][c2]] != part[trans[s][c2]]) {
                                diff = true;
                                break;
                            }
                        }
                        if (diff) part[z] = fresh;
                    }
                    changed = true;
                }
            }
        }
    }

    var block_id = [_]usize{0} ** MAX_DFA;
    var block_seen = [_]bool{false} ** MAX_DFA;
    var n_min: usize = 0;
    const dead_block = part[0];
    block_id[dead_block] = 0;
    block_seen[dead_block] = true;
    n_min = 1;
    {
        var s: usize = 0;
        while (s < dfa_n) : (s += 1) {
            const bl = part[s];
            if (!block_seen[bl]) {
                block_seen[bl] = true;
                block_id[bl] = n_min;
                n_min += 1;
            }
        }
    }

    var out = emptyDfa256(.ok);
    out.class_of = class_of;
    out.n_classes = n_classes;
    out.n_states = n_min;
    out.start = block_id[part[start_id]];
    out.a_start = a_start;
    out.a_end = a_end;
    {
        var s: usize = 0;
        while (s < dfa_n) : (s += 1) {
            const mid = block_id[part[s]];
            if (accepting[s]) out.accepting[mid] = true;
            var cl: usize = 0;
            while (cl < n_classes) : (cl += 1) {
                out.trans[mid][cl] = @intCast(block_id[part[trans[s][cl]]]);
            }
        }
    }
    out.accepting[0] = false;

    {
        var cnt: usize = 0;
        var c: usize = 0;
        while (c < 256) : (c += 1) {
            if (out.trans[out.start][class_of[c]] != 0) {
                out.start_bytes[cnt] = @intCast(c);
                cnt += 1;
                pf.setBit(&out.start_byte_set, @intCast(c));
            }
        }
        out.n_start_bytes = cnt;
    }

    if (n_min > MAX_DFA) return emptyDfa256(.exploded);
    return out;
}

test "computeReverse + reverseSearch == forward core.findLeftmost ($-anchored oracle)" {
    const parser = @import("../parser.zig");
    const hir = @import("../hir.zig");
    const core = @import("core.zig");
    const search = @import("search.zig");
    const a = std.testing.allocator;

    // Independent oracle: the forward eager DFA (`core.findLeftmost`, a_end-aware,
    // O(n²) but correct) vs the reverse single pass. The `Pattern`⇄`Regex`
    // differential only compares reverse-vs-reverse; this pins the reverse
    // ALGORITHM against the pre-existing forward semantics.
    const pats = [_][]const u8{
        "a+$",        "[a-z]+$",  "\\s+$",       "a*a*$",
        "(a+)+$",     ".*a$",     "ab$",         "(cat|dog)$",
        "[0-9]{2,4}$", "abc.*x$", "a*$",         "[ab]+c?$",
    };
    const ins = [_][]const u8{
        "",       "a",        "aaa",      "aaa!",     "  ",       "  x",
        "xyz",    "ababab",   "cat",      "dog cat",  "12",       "1234",
        "12345",  "abczzx",   "abcabcx",  "no",       " a a a ",  "ababx",
        "cc",     "abcabc",
    };
    for (pats) |p| {
        var h = hir.Hir(null).initRuntime();
        defer h.deinit(a);
        parser.parse(null, &h, a, p, .{}) catch continue;
        var nfa = thompson.build(null, &h) catch continue;
        const fd = compute(null, &nfa, h.anchored_start, h.anchored_end);
        if (fd.outcome != .ok) continue;
        const rd = computeReverse(null, &nfa);
        if (rd.outcome != .ok) continue;
        for (ins) |in| {
            const want = core.findLeftmost(&fd, in); // forward oracle (handles a_end)
            const got = search.reverseSearch(&rd, in, 0, in.len);
            std.testing.expectEqual(want == null, got == null) catch |e| {
                std.debug.print("MISMATCH exists pat=\"{s}\" in=\"{s}\"\n", .{ p, in });
                return e;
            };
            if (want) |w| {
                std.testing.expectEqual(w.start, got.?.start) catch |e| {
                    std.debug.print("MISMATCH start pat=\"{s}\" in=\"{s}\" fwd={d} rev={d}\n", .{ p, in, w.start, got.?.start });
                    return e;
                };
                std.testing.expectEqual(w.end, got.?.end) catch |e| {
                    std.debug.print("MISMATCH end pat=\"{s}\" in=\"{s}\" fwd={d} rev={d}\n", .{ p, in, w.end, got.?.end });
                    return e;
                };
            }
        }
    }
}
