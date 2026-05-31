//! Full-DFA construction: byte-equivalence-class compression + leftmost-first
//! subset construction (with the leftmost-first accept cut) + Moore
//! partition-refinement minimization + the unanchored-search start-byte
//! prefilter.
//!
//! This is the trusted DFA core. It reads the flat NFA produced by
//! `thompson.zig` (from the unified `parser`→`hir` front-end); the NFA's
//! state numbering and epsilon priority order are deterministic, so the
//! construction is reproducible. The comptime path (`pattern.zig` →
//! `dfa.Dfa`) and this runtime path (`exec/core.zig` over `Dfa256`) must
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
    /// (`exec/search.zig`) drives; it mirrors the comptime `dfa.Dfa.runFrom`,
    /// and the two are pinned equal by `tests/feat_api.zig`'s differential.
    ///
    /// `inline`: this is the innermost loop body of `core.findLeftmost` /
    /// `isMatch`, which previously inlined a file-private `runFrom`. Forcing
    /// inline keeps the cross-file method call zero-cost (no throughput
    /// regression on the DFA hot path).
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

    const findOrAdd = struct {
        fn run(lists: *[MAX_DFA][MAX_NFA]u16, lens: *[MAX_DFA]usize, n: *usize, want: *const [MAX_NFA]u16, want_len: usize) E!usize {
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
    }.run;

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
