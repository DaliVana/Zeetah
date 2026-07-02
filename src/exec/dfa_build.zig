//! Shared low-level DFA-construction primitives used by BOTH the eager
//! `full_dfa.compute` (comptime *and* runtime) and the lazy
//! `lazy_dfa.LazyProg`. These were previously copy-pasted ("verbatim") in
//! both files; the duplication is now removed without changing behavior.
//!
//! Everything here is **pure, allocator-free and comptime-evaluable**: the
//! functions operate on caller-provided buffers so the eager path can pass
//! fixed comptime/stack arrays and the lazy path its heap slices, and they
//! are generic over the `thompson.Nfa(cap)` cap so the comptime pipeline
//! (`pattern.zig`) keeps evaluating the whole construction at compile time.
//! The comptime↔runtime DFA agreement is guarded by `tests/feat_api.zig`'s
//! `Pattern`⇄`Regex` differential and the `lazy_dfa` differential test.

const std = @import("std");
const common = @import("../common.zig");
const thompson = @import("../thompson.zig");

const MAX_NFA = thompson.MAX_NFA;
const MAX_EDGES = thompson.MAX_EDGES;

const hasBit = common.hasBit;

/// State-count capacity for a given NFA cap: comptime (`cap == N`) NFAs are
/// sized to the small `MAX_NFA`, the runtime (`cap == null`) NFA to the larger
/// `MAX_NFA_RUNTIME` (see `thompson`'s `MAX_*_RUNTIME` note). Callers that size
/// per-state scratch by this stay correct for both fronts.
fn statesCap(comptime cap: ?usize) usize {
    return if (cap == null) thompson.MAX_NFA_RUNTIME else MAX_NFA;
}

/// Byte equivalence classes + per-class representative byte.
pub const Classes = struct {
    class_of: [256]u8 = [_]u8{0} ** 256,
    rep: [256]u8 = [_]u8{0} ** 256,
    n_classes: usize = 1,
};

/// Two bytes share a class iff every NFA set treats them identically, so the
/// transition fan-out is `n_classes` instead of 256. `rep[c]` is a
/// representative member of class `c` (used to test set membership).
pub fn classify(comptime cap: ?usize, nfa: *const thompson.Nfa(cap)) Classes {
    var r = Classes{ .n_classes = 0 };
    var assigned = [_]bool{false} ** 256;
    var c: usize = 0;
    while (c < 256) : (c += 1) {
        if (assigned[c]) continue;
        const id: u8 = @intCast(r.n_classes);
        r.class_of[c] = id;
        assigned[c] = true;
        var d = c + 1;
        while (d < 256) : (d += 1) {
            if (assigned[d]) continue;
            var same = true;
            var s: usize = 0;
            while (s < nfa.n_sets) : (s += 1) {
                if (hasBit(&nfa.sets[s], @intCast(c)) != hasBit(&nfa.sets[s], @intCast(d))) {
                    same = false;
                    break;
                }
            }
            if (same) {
                r.class_of[d] = id;
                assigned[d] = true;
            }
        }
        r.n_classes += 1;
    }
    var seen = [_]bool{false} ** 256;
    c = 0;
    while (c < 256) : (c += 1) {
        const cl = r.class_of[c];
        if (!seen[cl]) {
            seen[cl] = true;
            r.rep[cl] = @intCast(c);
        }
    }
    return r;
}

/// Forward CSR adjacency over the NFA edges. `eps_off`/`cnt_off` have length
/// `MAX_NFA + 1`; `eps_to`/`cnt_to`/`cnt_set` have length `MAX_EDGES`.
/// Epsilon edges are `e_kind == 0`; byte-set edges otherwise (their set
/// index goes to `cnt_set`). Output entries beyond the per-state run are
/// left untouched (never read by the consumers).
pub fn buildForwardCsr(
    comptime cap: ?usize,
    nfa: *const thompson.Nfa(cap),
    eps_to: []u16,
    eps_off: []usize,
    cnt_to: []u16,
    cnt_set: []u16,
    cnt_off: []usize,
) void {
    const NCAP = comptime statesCap(cap);
    var ecount = [_]usize{0} ** NCAP;
    var ccount = [_]usize{0} ** NCAP;
    var ei: usize = 0;
    while (ei < nfa.n_edges) : (ei += 1) {
        if (nfa.e_kind[ei] == .eps) ecount[nfa.e_from[ei]] += 1 else ccount[nfa.e_from[ei]] += 1;
    }
    var acc: usize = 0;
    var s: usize = 0;
    while (s < nfa.n_states) : (s += 1) {
        eps_off[s] = acc;
        acc += ecount[s];
    }
    eps_off[nfa.n_states] = acc;
    acc = 0;
    s = 0;
    while (s < nfa.n_states) : (s += 1) {
        cnt_off[s] = acc;
        acc += ccount[s];
    }
    cnt_off[nfa.n_states] = acc;
    var efill: [NCAP + 1]usize = undefined;
    var cfill: [NCAP + 1]usize = undefined;
    for (0..nfa.n_states + 1) |k| {
        efill[k] = eps_off[k];
        cfill[k] = cnt_off[k];
    }
    ei = 0;
    while (ei < nfa.n_edges) : (ei += 1) {
        const f = nfa.e_from[ei];
        if (nfa.e_kind[ei] == .eps) {
            eps_to[efill[f]] = nfa.e_to[ei];
            efill[f] += 1;
        } else {
            cnt_to[cfill[f]] = nfa.e_to[ei];
            cnt_set[cfill[f]] = nfa.e_set[ei];
            cfill[f] += 1;
        }
    }
}

/// Priority-ordered epsilon closure of `seeds` + the leftmost-first accept
/// cut: walk eps edges in CSR order (highest priority first), then truncate
/// at the first occurrence of `accept_state` so lower-priority threads are
/// dropped. Writes the ordered NFA-state list to `out`, returns its length;
/// `acc.*` ⇔ the closure is accepting.
/// `nmax`/`emax` size the internal `seen`/`stack` scratch: the eager path
/// passes the small `MAX_NFA`/`MAX_EDGES`, the lazy path the larger runtime
/// ceilings. Only `seen[0..n_states]` is cleared (n_states = `eps_off.len - 1`),
/// so a larger capacity costs no extra per-call memset — the hot lazy path over
/// a small NFA is byte-identical to the old fixed-256 version.
pub fn closure(
    comptime nmax: usize,
    comptime emax: usize,
    eps_to: []const u16,
    eps_off: []const usize,
    accept_state: u16,
    seeds: []const u16,
    out: []u16,
    acc: *bool,
) usize {
    var seen: [nmax]bool = undefined;
    @memset(seen[0 .. eps_off.len - 1], false);
    var len: usize = 0;
    var stack: [emax]u16 = undefined;
    for (seeds) |sd| {
        var sp: usize = 0;
        stack[0] = sd;
        sp = 1;
        while (sp > 0) {
            sp -= 1;
            const n = stack[sp];
            if (seen[n]) continue;
            seen[n] = true;
            std.debug.assert(len < out.len); // ≤ MAX_NFA distinct states
            out[len] = n;
            len += 1;
            var c = eps_off[n + 1];
            while (c > eps_off[n]) {
                c -= 1;
                std.debug.assert(sp < stack.len); // ≤ MAX_EDGES eps edges
                stack[sp] = eps_to[c];
                sp += 1;
            }
        }
    }
    var i: usize = 0;
    var a = false;
    while (i < len) : (i += 1) {
        if (out[i] == accept_state) {
            a = true;
            len = i + 1;
            break;
        }
    }
    acc.* = a;
    return len;
}
