//! Edge-look peel: a pattern that is `concat(regular_core, trailing_look)`,
//! where the trailing look-around is a **width-1 single class** (e.g.
//! `…(?<![,.])`, `…(?!\d)`), is matched on a linear DFA instead of demoting the
//! whole pattern to the tree backtracker.
//!
//! This moves a fixed-width edge look-around out of the `requires_backtracking`
//! tier into the same "regular core + cheap assertion" class zeetah already
//! uses for `\b` (`bt_look`/`boundary_lits`). It is shared verbatim by the
//! runtime (`regex.zig`) and the comptime (`pattern.zig`) front-ends — both
//! build the DFA with `buildDfa` and drive `nextFrom` here, so they agree by
//! construction.
//!
//! The look is folded INTO the DFA, not checked after it. A DFA built with
//! the leftmost-first priority cut drops every lower-priority thread once the
//! highest-priority one reaches the accept; if the look then rejected that end,
//! a lower-priority path whose end passes it would already be gone
//! (`(?:.|..)(?=x)` on `"abx"`, `(?:ab)*(?=x)`, `a*(?:ab)*(?<!a)` on `"ab"`).
//! The look holds or fails for every thread ending at the same position, so the
//! cut is right exactly when it only fires where the look holds (`lower`):
//!  * lookahead — the core is followed by one byte of the look's class (or its
//!    complement, negated), and the match end is reported one byte back; a
//!    negative lookahead also holds at end of input (`nextFrom` probes it);
//!  * lookbehind — the NFA tracks whether the last consumed byte is in the
//!    class (two copies of every state), and only the passing copy of the
//!    core's final state reaches the accept; a leading state consumes the byte
//!    before the match (offset 0 counts as outside the class), so an empty
//!    core sees the right context too — `nextFrom` starts in the state it
//!    leads to (`Spec.begin_in` / `begin_out`).
//!
//! Scope:
//!  * the look is the LAST factor of a top-level `concat` (trailing only);
//!  * its sub-expression is a single `.set` (width 1);
//!  * the core is regular, all-greedy and alternation-free (`regularGreedy`).
//!    The folded DFA is exact for any regular core; the narrower shape only
//!    keeps routing where it was (wider cores keep their existing engines).
//! Anything outside this shape returns `null` from `recognize` and the caller
//! keeps its existing path.

const std = @import("std");
const hir = @import("../hir.zig");
const common = @import("../common.zig");
const thompson = @import("../thompson.zig");
const full_dfa = @import("full_dfa.zig");
const core = @import("core.zig");

pub const Span = core.Span;

/// Config for a width-1 trailing look-assertion folded into a regular core.
pub const Spec = struct {
    set: [32]u8, // the single-byte class inside the look
    behind: bool, // (?<=)/(?<!) vs (?=)/(?!)
    neg: bool, // negative vs positive
    /// A folded `^`/`\A`: a match may only start at the search origin.
    anchored: bool = false,
    /// A byte outside `set`: the context byte `begin_out` is built from, and
    /// the byte a negative lookahead's end-of-input probe steps on.
    /// `recognize` declines a look whose `set` is every byte, so it exists.
    absent: u8 = 0,
    // Filled by `buildDfa` from the folded DFA (state ids survive packing and
    // the comptime compression unchanged):
    /// The bytes that can begin a match (the first-byte skip in `nextFrom`).
    first: [32]u8 = @splat(0),
    /// Lookbehind: whether the empty core can match in some context (then
    /// nothing is skipped). A lookahead match always consumes the look byte or
    /// reaches end of input, so it needs no nullable flag.
    nullable: bool = false,
    /// Lookbehind: the state a match walk begins in, after a byte in `set` /
    /// after any other byte (or none). Equal when the context can't matter —
    /// a core that can't match empty (minimization merges the two).
    begin_in: u16 = 0,
    begin_out: u16 = 0,
    /// The accepting state every byte leads out of (minimization leaves at
    /// most one; `no_state` if none): reaching it ends the walk without one
    /// more step.
    terminal: u16 = no_state,
};

/// Never a state id (`MAX_DFA` = 256), unlike 0, the DEAD sink.
const no_state: u16 = std.math.maxInt(u16);

const bitsetHas = common.hasBit;

fn setBit(set: *[32]u8, c: u8) void {
    set[c >> 3] |= @as(u8, 1) << @intCast(c & 7);
}

fn isEmpty(set: [32]u8) bool {
    for (set) |w| if (w != 0) return false;
    return true;
}

/// Regular, all-greedy, AND alternation-free? (`.look`/`.look_around`/
/// `.backref`/`.atomic`, an alternation or any lazy quantifier ⇒ false.)
/// Generic over `cap` so runtime and comptime share it. `.cap` never reaches
/// here (callers gate `ng == 0`).
fn regularGreedy(comptime cap: ?usize, h: *const hir.Hir(cap), ref: hir.NodeRef) bool {
    const nd = h.node(ref);
    return switch (nd.tag) {
        .alt, .backref, .look_around, .look, .atomic => false,
        .empty, .set => true,
        .star, .plus, .opt => nd.greedy and regularGreedy(cap, h, nd.a),
        .cap => regularGreedy(cap, h, nd.a),
        .concat => regularGreedy(cap, h, nd.a) and regularGreedy(cap, h, nd.b),
    };
}

pub const Recognized = struct { core: hir.NodeRef, spec: Spec };

/// Recognize `concat(regular_greedy_core, trailing_width1_look)`. Returns the
/// core node to DFA-compile and the look's spec (finished by `buildDfa`), or
/// null if the shape/scope does not apply. Generic over `cap` (runtime: null,
/// comptime: NN).
pub fn recognize(comptime cap: ?usize, h: *const hir.Hir(cap)) ?Recognized {
    if (h.root == hir.none) return null;
    const root = h.node(h.root);
    if (root.tag != .concat) return null; // parseConcat is left-leaning ⇒ root.b is the last factor
    const look = h.node(root.b);
    if (look.tag != .look_around) return null;
    const sub = h.node(look.a);
    if (sub.tag != .set) return null; // width-1 single class only
    if (!regularGreedy(cap, h, root.a)) return null;
    const set = h.setBitmap(sub.set_idx);
    const absent = for (0..256) |c| {
        if (!bitsetHas(&set, @intCast(c))) break @as(u8, @intCast(c));
    } else return null; // a look over every byte: rare, keep the existing path
    return .{
        .core = root.a,
        .spec = .{
            .set = set,
            .behind = (look.set_idx & hir.LA_BEHIND) != 0,
            .neg = (look.set_idx & hir.LA_NEGATIVE) != 0,
            .anchored = h.anchored_start,
            .absent = absent,
        },
    };
}

/// Fixed-array NFA the fold writes (the eager DFA construction's ceilings).
const Folded = thompson.Nfa(thompson.MAX_NFA);

fn addEdge(n: *Folded, from: usize, to: usize, kind: thompson.EdgeKind, set: usize) bool {
    if (n.n_edges >= thompson.MAX_EDGES) return false;
    n.e_from[n.n_edges] = @intCast(from);
    n.e_to[n.n_edges] = @intCast(to);
    n.e_kind[n.n_edges] = kind;
    n.e_set[n.n_edges] = @intCast(set);
    n.e_look[n.n_edges] = 0;
    n.e_slot[n.n_edges] = -1;
    n.n_edges += 1;
    return true;
}

/// The core's NFA with the trailing look folded in (see the header), or null
/// past the eager ceilings. The core is capture- and look-free
/// (`regularGreedy`, callers gate `ng == 0`), and its accept state has no
/// out-edges (it is the root fragment's).
fn lower(comptime cap: ?usize, src: *const thompson.Nfa(cap), spec: *const Spec) ?Folded {
    var out: Folded = .{};
    const n = src.n_states;
    var not_set: [32]u8 = undefined;
    for (&not_set, spec.set) |*w, s| w.* = ~s;

    if (!spec.behind) {
        // core · class — the accept follows the look byte.
        const look_set = if (spec.neg) not_set else spec.set;
        if (isEmpty(look_set)) return null;
        if (n + 1 > thompson.MAX_NFA or src.n_sets + 1 > thompson.MAX_SETS) return null;
        for (0..src.n_sets) |k| out.sets[k] = src.sets[k];
        out.sets[src.n_sets] = look_set;
        out.n_sets = src.n_sets + 1;
        for (0..src.n_edges) |ei| {
            if (src.e_kind[ei] == .look) return null;
            if (!addEdge(&out, src.e_from[ei], src.e_to[ei], src.e_kind[ei], src.e_set[ei])) return null;
        }
        if (!addEdge(&out, src.accept, n, .consume, src.n_sets)) return null;
        out.n_states = n + 1;
        out.start = src.start;
        out.accept = n;
        return out;
    }

    // Lookbehind: states `[0, n)` are reached by a byte in the class, `[n, 2n)`
    // by any other byte; `2n` consumes the byte before the match, `2n + 1`
    // accepts. Set `2k` / `2k + 1` is source set `k` inside / outside the class.
    if (2 * n + 2 > thompson.MAX_NFA or 2 * src.n_sets + 2 > thompson.MAX_SETS) return null;
    for (0..src.n_sets) |k| {
        for (&out.sets[2 * k], &out.sets[2 * k + 1], src.sets[k], spec.set) |*in, *ex, s, c| {
            in.* = s & c;
            ex.* = s & ~c;
        }
    }
    out.sets[2 * src.n_sets] = spec.set;
    out.sets[2 * src.n_sets + 1] = not_set;
    out.n_sets = 2 * src.n_sets + 2;
    for (0..src.n_edges) |ei| {
        const u = src.e_from[ei];
        const v = src.e_to[ei];
        switch (src.e_kind[ei]) {
            .look => return null,
            // Edge order per state is kept in both copies (ε order = priority).
            .eps => for ([_]usize{ 0, n }) |off| {
                if (!addEdge(&out, u + off, v + off, .eps, 0)) return null;
            },
            .consume => {
                const k: usize = src.e_set[ei];
                for ([_]usize{ 0, n }) |off| {
                    if (!isEmpty(out.sets[2 * k]) and !addEdge(&out, u + off, v, .consume, 2 * k)) return null;
                    if (!isEmpty(out.sets[2 * k + 1]) and !addEdge(&out, u + off, v + n, .consume, 2 * k + 1)) return null;
                }
            },
        }
    }
    const pass: usize = if (spec.neg) n else 0;
    if (!addEdge(&out, src.accept + pass, 2 * n + 1, .eps, 0)) return null;
    if (!isEmpty(spec.set) and !addEdge(&out, 2 * n, src.start, .consume, 2 * src.n_sets)) return null;
    if (!addEdge(&out, 2 * n, src.start + n, .consume, 2 * src.n_sets + 1)) return null;
    out.n_states = 2 * n + 2;
    out.start = 2 * n;
    out.accept = 2 * n + 1;
    return out;
}

/// Build the folded DFA for `spec`'s look over the core's NFA and finish
/// `spec` (`first` / `nullable`). The caller sets `required` (a byte every core
/// match consumes — still necessary, since the look byte is extra). null ⇒ the
/// folded NFA or its DFA exceeds the eager ceilings.
pub fn buildDfa(comptime cap: ?usize, core_nfa: *const thompson.Nfa(cap), spec: *Spec) ?full_dfa.Dfa256 {
    var folded = lower(cap, core_nfa, spec) orelse return null;
    const d = if (cap == null) blk: {
        // A borrowed slice view, so the runtime keeps one `compute` instance.
        const view: thompson.Nfa(null) = .{
            .n_states = folded.n_states,
            .e_from = folded.e_from[0..folded.n_edges],
            .e_to = folded.e_to[0..folded.n_edges],
            .e_kind = folded.e_kind[0..folded.n_edges],
            .e_set = folded.e_set[0..folded.n_edges],
            .e_look = folded.e_look[0..folded.n_edges],
            .e_slot = folded.e_slot[0..folded.n_edges],
            .n_edges = folded.n_edges,
            .sets = folded.sets[0..folded.n_sets],
            .n_sets = folded.n_sets,
            .start = folded.start,
            .accept = folded.accept,
        };
        break :blk full_dfa.compute(null, &view, spec.anchored, false);
    } else full_dfa.compute(thompson.MAX_NFA, &folded, spec.anchored, false);
    if (d.outcome != .ok) return null;

    spec.first = @splat(0);
    spec.nullable = false;
    if (spec.behind) {
        // The walk begins after the leading state consumed the context byte.
        spec.begin_out = d.step(@intCast(d.start), d.class_of[spec.absent]);
        spec.begin_in = spec.begin_out;
        for (0..256) |c| {
            if (!bitsetHas(&spec.set, @intCast(c))) continue;
            spec.begin_in = d.step(@intCast(d.start), d.class_of[c]);
            break;
        }
        spec.nullable = d.accepting[spec.begin_in] or d.accepting[spec.begin_out];
    } else {
        spec.begin_in = @intCast(d.start);
        spec.begin_out = spec.begin_in;
    }
    for ([_]u16{ spec.begin_in, spec.begin_out }) |b| {
        for (0..256) |c| {
            if (d.step(b, d.class_of[c]) != 0) setBit(&spec.first, @intCast(c));
        }
    }
    spec.terminal = no_state;
    for (1..d.n_states) |st| {
        if (!d.accepting[st]) continue;
        const all_dead = for (0..d.n_classes) |c| {
            if (d.trans[st][c] != 0) break false;
        } else true;
        if (all_dead) {
            spec.terminal = @intCast(st);
            break;
        }
    }
    return d;
}

/// Leftmost match span at/after `from`, or null. Tries each candidate start
/// (skipping bytes that cannot begin a match) and walks the folded DFA to its
/// dead end; the last accept seen is the leftmost-first end, because the look
/// is part of the accept (see the header). Linear per start — no
/// backtracking, so no catastrophic blow-up.
/// `dfa` is `anytype` so this single walker drives both the runtime
/// `full_dfa.PackedDfa` and the comptime-baked compressed
/// `comptime_dfa.Dfa(ns,nk)` (the comptime path bakes the DFA as the compact
/// `[ns][nk]` table, not a 131 KB `Dfa256`). Both expose `start`/`accepting`/
/// `class_of`/`required` and the `step(state, cls)` table accessor used below.
pub fn nextFrom(dfa: anytype, spec: *const Spec, input: []const u8, from: usize) ?Span {
    // Whole-input fast negative: a byte every core match must consume that is
    // absent ⇒ no match anywhere.
    if (dfa.required) |rb| {
        if (std.mem.indexOfScalarPos(u8, input, from, rb) == null) return null;
    }
    // A folded `^`/`\A` tries the origin only (callers reject `from > 0`).
    const last = if (spec.anchored) @min(from, input.len) else input.len;
    return if (spec.behind) nextBehind(dfa, spec, input, from, last) else nextAhead(dfa, spec, input, from, last);
}

/// `nextFrom` for a lookbehind: starts `from..=last`.
fn nextBehind(dfa: anytype, spec: *const Spec, input: []const u8, from: usize, last: usize) ?Span {
    var s: usize = from;
    while (s <= last) : (s += 1) {
        if (!spec.nullable and (s == input.len or !bitsetHas(&spec.first, input[s]))) continue;
        // The state after the byte before the match (none at 0: outside the
        // class) — a set test, not a DFA step.
        var state = spec.begin_out;
        if (spec.begin_in != spec.begin_out and s > 0 and bitsetHas(&spec.set, input[s - 1])) state = spec.begin_in;
        var best: ?usize = if (dfa.accepting[state]) s else null;
        var i: usize = s;
        while (i < input.len) : (i += 1) {
            state = dfa.step(state, dfa.class_of[input[i]]);
            if (state == 0) break; // DEAD sink
            if (dfa.accepting[state]) {
                best = i + 1;
                // (Tested here, not first as in `nextAhead`: a lookbehind DFA
                // rarely has the state, and this measured faster.)
                if (state == spec.terminal) break;
            }
        }
        if (best) |e| return .{ .start = s, .end = e };
    }
    return null;
}

/// `nextFrom` for a lookahead: starts `from..=last`.
fn nextAhead(dfa: anytype, spec: *const Spec, input: []const u8, from: usize, last: usize) ?Span {
    // Locals, and the terminal test first: ~15-25% faster on short-token
    // workloads than testing it in the accepting branch (measured).
    const term = spec.terminal;
    const begin = spec.begin_out;
    var s: usize = from;
    while (s <= last) : (s += 1) {
        if (s < input.len and !bitsetHas(&spec.first, input[s])) continue;
        var state: u16 = begin;
        var best: ?usize = null;
        var i: usize = s;
        // The accept follows the look byte: an accept at `i` is a core end at
        // `i`. The terminal state needs no end-of-input probe (nothing lives).
        while (i < input.len) : (i += 1) {
            state = dfa.step(state, dfa.class_of[input[i]]);
            if (state == term) {
                best = i;
                break;
            }
            if (state == 0) break; // DEAD sink
            if (dfa.accepting[state]) best = i;
        } else if (spec.neg) {
            // End of input: a negative lookahead holds there. A core end at
            // `len` is a thread at the core's final state, the only one that
            // reaches the accept on a byte outside the class.
            if (dfa.accepting[dfa.step(state, dfa.class_of[spec.absent])]) best = input.len;
        }
        if (best) |e| return .{ .start = s, .end = e };
    }
    return null;
}
