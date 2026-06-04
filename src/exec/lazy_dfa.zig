//! Lazy (incremental) DFA: on-the-fly subset construction with a bounded,
//! evictable state cache. Same automaton as `exec/full_dfa` — same priority-
//! ordered epsilon closure, same leftmost-first accept cut — only the DFA states are
//! materialized on demand and memoized, so a pattern whose *full* DFA would
//! blow `MAX_DFA` still runs in O(n·m) without the eager table.
//!
//! Split for thread-safety (the meta API contract: a compiled `Regex` is an
//! immutable shareable value; mutable per-search scratch lives in a pooled
//! cache, never on the `Regex`):
//!
//!   * `LazyProg` (this file) — immutable: CSR + reverse CSR + byte-
//!     equivalence classes, built once at compile, shared read-only across
//!     threads.
//!   * `LazyMemo` (`exec/lazy_memo.zig`) — mutable per-search scratch: the
//!     state memo + dense transition caches. Pool-compatible (`init`/
//!     `deinit`); borrowed per call so concurrent searches over one `Regex`
//!     never race. Re-exported here as `lazy_dfa.LazyMemo`.
//!   * `DenseSearch` (`exec/dense_search.zig`) — the frozen flat-table form
//!     produced by `LazyProg.freezeDense` (lever A). Re-exported here as
//!     `lazy_dfa.DenseSearch`.
//!
//! Because it is the identical construction evaluated lazily, its
//! `isMatch`/`findLeftmost` answers are bit-identical to the full DFA's
//! wherever the full DFA exists — pinned by this module's in-file differential
//! checks. On cache exhaustion it flushes and continues (correctness is
//! preserved; only the memo is rebuilt).
//!
//! Lever A (memoized single-pass): `findLeftmostFrom` is the production
//! linear core (RE2 / rust-regex `meta` / .NET NonBacktracking shape) — a
//! single forward pass (unanchored lazy-`.*?` via lowest-priority start
//! injection + the Pike accept cut for leftmost-first) plus a reverse pass
//! for the start, with **dense per-state, byte-equivalence-class-indexed
//! transition memoization**. That memo is the optimization: it turns the
//! verified-but-non-memoized closure-per-byte into one cached class-indexed
//! lookup per byte, removing the per-position DFA restart that was the
//! regular tier's O(n·m). The algorithm is unchanged, so the differential
//! test vs `core.findLeftmost` keeps it span-exact.

const std = @import("std");
const thompson = @import("../thompson.zig");
const dfa_build = @import("dfa_build.zig");
const lazy_memo = @import("lazy_memo.zig");
const dense_search = @import("dense_search.zig");

const MAX_NFA = thompson.MAX_NFA;
const MAX_EDGES = thompson.MAX_EDGES;

// Mutable per-search scratch + the frozen dense form now live in their own
// files; re-exported here so consumers keep using `lazy_dfa.{LazyMemo,
// DenseSearch,Span}` and the transition-cache sentinels stay in scope.
pub const LazyMemo = lazy_memo.LazyMemo;
pub const DEFAULT_CACHE_STATES = lazy_memo.DEFAULT_CACHE_STATES;
pub const DenseSearch = dense_search.DenseSearch;
pub const Span = dense_search.Span;

const UNKNOWN = lazy_memo.UNKNOWN; // transition not yet computed
const TDEAD = lazy_memo.TDEAD; // computed: no byte successor (anchored only)

inline fn hasBit(set: *const [32]u8, c: u8) bool {
    return (set[c >> 3] & (@as(u8, 1) << @as(u3, @intCast(c & 7)))) != 0;
}

/// Immutable program: CSR adjacency, reverse CSR, byte-equivalence classes.
/// Built once at compile; shared read-only (no mutation during search).
pub const LazyProg = struct {
    allocator: std.mem.Allocator,
    nfa: *const thompson.Nfa(null),
    a_start: bool,
    a_end: bool,
    has_cond: bool = false,

    class_of: [256]u8 = [_]u8{0} ** 256,
    rep: [256]u8 = [_]u8{0} ** 256,
    n_classes: usize = 1,

    eps_to: []u16,
    eps_off: []usize,
    cnt_to: []u16,
    cnt_set: []u16,
    cnt_off: []usize,
    reps_to: []u16,
    reps_off: []usize,
    rcnt_from: []u16,
    rcnt_set: []u16,
    rcnt_off: []usize,

    pub fn init(
        allocator: std.mem.Allocator,
        nfa: *const thompson.Nfa(null),
        a_start: bool,
        a_end: bool,
    ) !LazyProg {
        // Allocate into locals with `errdefer` so a mid-sequence OOM frees the
        // buffers already taken (a single struct-literal of `try alloc`s leaks
        // every prior allocation if a later one fails). On success the errdefers
        // are disarmed by the normal return; `buildCsr`/`classify` are infallible.
        const eps_to = try allocator.alloc(u16, MAX_EDGES);
        errdefer allocator.free(eps_to);
        const eps_off = try allocator.alloc(usize, MAX_NFA + 1);
        errdefer allocator.free(eps_off);
        const cnt_to = try allocator.alloc(u16, MAX_EDGES);
        errdefer allocator.free(cnt_to);
        const cnt_set = try allocator.alloc(u16, MAX_EDGES);
        errdefer allocator.free(cnt_set);
        const cnt_off = try allocator.alloc(usize, MAX_NFA + 1);
        errdefer allocator.free(cnt_off);
        const reps_to = try allocator.alloc(u16, MAX_EDGES);
        errdefer allocator.free(reps_to);
        const reps_off = try allocator.alloc(usize, MAX_NFA + 1);
        errdefer allocator.free(reps_off);
        const rcnt_from = try allocator.alloc(u16, MAX_EDGES);
        errdefer allocator.free(rcnt_from);
        const rcnt_set = try allocator.alloc(u16, MAX_EDGES);
        errdefer allocator.free(rcnt_set);
        const rcnt_off = try allocator.alloc(usize, MAX_NFA + 1);
        errdefer allocator.free(rcnt_off);
        var self = LazyProg{
            .allocator = allocator,
            .nfa = nfa,
            .a_start = a_start,
            .a_end = a_end,
            .eps_to = eps_to,
            .eps_off = eps_off,
            .cnt_to = cnt_to,
            .cnt_set = cnt_set,
            .cnt_off = cnt_off,
            .reps_to = reps_to,
            .reps_off = reps_off,
            .rcnt_from = rcnt_from,
            .rcnt_set = rcnt_set,
            .rcnt_off = rcnt_off,
        };
        self.buildCsr();
        self.classify();
        return self;
    }

    pub fn deinit(self: *LazyProg) void {
        self.allocator.free(self.eps_to);
        self.allocator.free(self.eps_off);
        self.allocator.free(self.cnt_to);
        self.allocator.free(self.cnt_set);
        self.allocator.free(self.cnt_off);
        self.allocator.free(self.reps_to);
        self.allocator.free(self.reps_off);
        self.allocator.free(self.rcnt_from);
        self.allocator.free(self.rcnt_set);
        self.allocator.free(self.rcnt_off);
    }

    /// Byte equivalence classes — shared with `full_dfa` via
    /// `exec/dfa_build.zig` (two bytes share a class iff every NFA set
    /// treats them identically; `rep[c]` is a representative member).
    fn classify(self: *LazyProg) void {
        const cls = dfa_build.classify(null, self.nfa);
        self.class_of = cls.class_of;
        self.rep = cls.rep;
        self.n_classes = cls.n_classes;
    }

    fn buildCsr(self: *LazyProg) void {
        const nfa = self.nfa;
        // Forward CSR is shared with `full_dfa` (`exec/dfa_build.zig`).
        dfa_build.buildForwardCsr(
            null,
            nfa,
            self.eps_to,
            self.eps_off,
            self.cnt_to,
            self.cnt_set,
            self.cnt_off,
        );
        var acc: usize = 0;
        var s: usize = 0;
        var ei: usize = 0;

        // --- Reverse CSR (edges flipped) for start recovery ---------------
        // Conditional `look` edges (kind 2) have no meaningful reverse here;
        // the regular tier never has them (look-bearing patterns route to
        // bt_look/backtrack upstream). Flag it so the unanchored path can
        // fall back to the always-correct anchored restart if one slips in.
        var recount = [_]usize{0} ** MAX_NFA;
        var rccount = [_]usize{0} ** MAX_NFA;
        ei = 0;
        while (ei < nfa.n_edges) : (ei += 1) {
            const k = nfa.e_kind[ei];
            if (k == 2) self.has_cond = true;
            if (k == 0) recount[nfa.e_to[ei]] += 1 else rccount[nfa.e_to[ei]] += 1;
        }
        acc = 0;
        s = 0;
        while (s < nfa.n_states) : (s += 1) {
            self.reps_off[s] = acc;
            acc += recount[s];
        }
        self.reps_off[nfa.n_states] = acc;
        acc = 0;
        s = 0;
        while (s < nfa.n_states) : (s += 1) {
            self.rcnt_off[s] = acc;
            acc += rccount[s];
        }
        self.rcnt_off[nfa.n_states] = acc;
        var refill: [MAX_NFA + 1]usize = undefined;
        var rcfill: [MAX_NFA + 1]usize = undefined;
        for (0..nfa.n_states + 1) |k| {
            refill[k] = self.reps_off[k];
            rcfill[k] = self.rcnt_off[k];
        }
        ei = 0;
        while (ei < nfa.n_edges) : (ei += 1) {
            const t = nfa.e_to[ei]; // reverse: index by forward target
            if (nfa.e_kind[ei] == 0) {
                self.reps_to[refill[t]] = nfa.e_from[ei];
                refill[t] += 1;
            } else {
                self.rcnt_from[rcfill[t]] = nfa.e_from[ei];
                self.rcnt_set[rcfill[t]] = nfa.e_set[ei];
                rcfill[t] += 1;
            }
        }
    }

    /// Priority-ordered epsilon closure + leftmost-first accept cut —
    /// shared with `full_dfa` via `exec/dfa_build.zig`. `inline` so the
    /// memoized search's cold-transition path keeps a flat call shape.
    inline fn closure(self: *const LazyProg, seeds: []const u16, out: []u16, acc: *bool) usize {
        return dfa_build.closure(
            self.eps_to,
            self.eps_off,
            @intCast(self.nfa.accept),
            seeds,
            out,
            acc,
        );
    }

    /// Reverse epsilon-closure over the flipped CSR. Pure reachability (no
    /// priority cut). `*hit` ⇔ forward start state reachable.
    fn closureRev(self: *const LazyProg, seeds: []const u16, out: []u16, hit: *bool) usize {
        var seen = [_]bool{false} ** MAX_NFA;
        var len: usize = 0;
        var stack: [MAX_EDGES]u16 = undefined;
        const fwd_start: u16 = @intCast(self.nfa.start);
        var h = false;
        for (seeds) |sd| {
            var sp: usize = 1;
            stack[0] = sd;
            while (sp > 0) {
                sp -= 1;
                const n = stack[sp];
                if (seen[n]) continue;
                seen[n] = true;
                out[len] = n;
                len += 1;
                if (n == fwd_start) h = true;
                var c = self.reps_off[n + 1];
                while (c > self.reps_off[n]) {
                    c -= 1;
                    stack[sp] = self.reps_to[c];
                    sp += 1;
                }
            }
        }
        hit.* = h;
        return len;
    }

    // --- Search entry points (operate on a borrowed mutable memo) ---------

    /// Unanchored leftmost (leftmost-first) match in a **single forward
    /// pass** resuming the search at `from` (no input re-slicing), + a
    /// memoized reverse pass for the start. `a_start`/`a_end`/`has_cond`
    /// delegate to the always-correct restart (zero regression).
    pub fn findLeftmostFrom(self: *const LazyProg, m: *LazyMemo, input: []const u8, from: usize) !?Span {
        if (self.a_start or self.a_end or self.has_cond)
            return self.restartFrom(m, input, from);

        var flushes: usize = 0;
        restart: while (true) {
            // Cache too small to make forward progress between flushes
            // (thrash): abandon the memo and use the always-correct,
            // flush-immune per-position restart (RE2's NFA-fallback role).
            // Span-exact: `restartFrom` (non-anchored) == core.findLeftmost.
            if (flushes > 8) return self.restartFrom(m, input, from);
            const g0 = m.gen;
            const sseed = [_]u16{@intCast(self.nfa.start)};
            var sbuf: [MAX_NFA]u16 = undefined;
            var sacc = false;
            const slen = self.closure(&sseed, &sbuf, &sacc);
            var sid = try m.intern(sbuf[0..slen], sacc);
            if (m.gen != g0) {
                flushes += 1;
                continue :restart;
            }

            var have = m.accept.items[sid];
            var end: usize = from;
            var i: usize = from;
            while (i < input.len) : (i += 1) {
                const cls = self.class_of[input[i]];
                if (!have) {
                    sid = try self.uStep(m, sid, cls);
                    if (m.gen != g0) {
                        flushes += 1;
                        continue :restart;
                    }
                } else {
                    sid = (try self.aStep(m, sid, cls)) orelse break; // threads died
                    if (m.gen != g0) {
                        flushes += 1;
                        continue :restart;
                    }
                }
                if (m.accept.items[sid]) {
                    have = true;
                    end = i + 1;
                }
            }
            if (!have) return null;
            const start = try self.reverseStart(m, input, end, from);
            return .{ .start = start, .end = end };
        }
    }

    /// Memoized single-pass existence check (stops at the first accept; no
    /// greedy extend, no reverse pass).
    pub fn isMatchFast(self: *const LazyProg, m: *LazyMemo, input: []const u8) !bool {
        if (self.a_start or self.a_end or self.has_cond)
            return (try self.restartFrom(m, input, 0)) != null;
        var flushes: usize = 0;
        restart: while (true) {
            if (flushes > 8) return (try self.restartFrom(m, input, 0)) != null;
            const g0 = m.gen;
            const sseed = [_]u16{@intCast(self.nfa.start)};
            var sbuf: [MAX_NFA]u16 = undefined;
            var sacc = false;
            const slen = self.closure(&sseed, &sbuf, &sacc);
            var sid = try m.intern(sbuf[0..slen], sacc);
            if (m.gen != g0) {
                flushes += 1;
                continue :restart;
            }
            if (m.accept.items[sid]) return true;
            var i: usize = 0;
            while (i < input.len) : (i += 1) {
                sid = try self.uStep(m, sid, self.class_of[input[i]]);
                if (m.gen != g0) {
                    flushes += 1;
                    continue :restart;
                }
                if (m.accept.items[sid]) return true;
            }
            return false;
        }
    }

    /// Memoized anchored leftmost via per-position restart (Stage-1
    /// coverage for patterns the eager DFA could not hold; also the
    /// always-correct fallback). Flush-immune (a forward pass per `sp`).
    pub fn findLeftmost(self: *const LazyProg, m: *LazyMemo, input: []const u8) !?Span {
        if (self.a_start) {
            if (try self.runFrom(m, input, 0)) |e| return .{ .start = 0, .end = e };
            return null;
        }
        var sp: usize = 0;
        while (sp <= input.len) : (sp += 1) {
            if (try self.runFrom(m, input, sp)) |e| return .{ .start = sp, .end = e };
        }
        return null;
    }

    pub fn isMatch(self: *const LazyProg, m: *LazyMemo, input: []const u8) !bool {
        return (try self.findLeftmost(m, input)) != null;
    }

    fn restartFrom(self: *const LazyProg, m: *LazyMemo, input: []const u8, from: usize) !?Span {
        if (self.a_start) {
            if (from != 0) return null;
            if (try self.runFrom(m, input, 0)) |e| return .{ .start = 0, .end = e };
            return null;
        }
        var sp: usize = from;
        while (sp <= input.len) : (sp += 1) {
            if (try self.runFrom(m, input, sp)) |e| return .{ .start = sp, .end = e };
        }
        return null;
    }

    fn runFrom(self: *const LazyProg, m: *LazyMemo, input: []const u8, start_pos: usize) !?usize {
        var buf: [MAX_NFA]u16 = undefined;
        var acc = false;
        const start_seed = [_]u16{@intCast(self.nfa.start)};
        const slen = self.closure(&start_seed, &buf, &acc);
        var sid = try m.intern(buf[0..slen], acc);
        var last: ?usize = if (m.accept.items[sid]) start_pos else null;
        var i = start_pos;
        while (i < input.len) : (i += 1) {
            const next = try self.step(m, sid, input[i], &buf, &acc) orelse break;
            sid = next;
            if (m.accept.items[sid]) last = i + 1;
        }
        if (self.a_end) {
            if (last) |e| if (e == input.len) return e;
            return null;
        }
        return last;
    }

    fn step(self: *const LazyProg, m: *LazyMemo, state_id: u32, byte: u8, buf: []u16, acc: *bool) !?u32 {
        const list = m.states.items[state_id];
        var src: [MAX_NFA]u16 = undefined;
        @memcpy(src[0..list.len], list);
        var seeds: [MAX_EDGES]u16 = undefined;
        var ns: usize = 0;
        for (src[0..list.len]) |nst| {
            var cj = self.cnt_off[nst];
            while (cj < self.cnt_off[nst + 1]) : (cj += 1) {
                if (hasBit(&self.nfa.sets[self.cnt_set[cj]], byte)) {
                    seeds[ns] = self.cnt_to[cj];
                    ns += 1;
                }
            }
        }
        if (ns == 0) return null;
        const len = self.closure(seeds[0..ns], buf, acc);
        return try m.intern(buf[0..len], acc.*);
    }

    /// Anchored transition (byte successors only), memoized. `null` ⇒ DEAD.
    fn aStep(self: *const LazyProg, m: *LazyMemo, sid: u32, cls: usize) !?u32 {
        try m.ensureTrans(&m.atrans, m.states.items.len, self.n_classes);
        const idx = @as(usize, sid) * self.n_classes + cls;
        const c = m.atrans.items[idx];
        if (c == TDEAD) return null;
        if (c != UNKNOWN) return @intCast(c);
        var src: [MAX_NFA]u16 = undefined;
        const list = m.states.items[sid];
        @memcpy(src[0..list.len], list);
        const sym = self.rep[cls];
        var seeds: [MAX_EDGES]u16 = undefined;
        var ns: usize = 0;
        for (src[0..list.len]) |nst| {
            var cj = self.cnt_off[nst];
            while (cj < self.cnt_off[nst + 1]) : (cj += 1) {
                if (hasBit(&self.nfa.sets[self.cnt_set[cj]], sym)) {
                    seeds[ns] = self.cnt_to[cj];
                    ns += 1;
                }
            }
        }
        if (ns == 0) {
            m.atrans.items[idx] = TDEAD;
            return null;
        }
        var buf: [MAX_NFA]u16 = undefined;
        var acc = false;
        const g0 = m.gen;
        const len = self.closure(seeds[0..ns], &buf, &acc);
        const nid = try m.intern(buf[0..len], acc);
        if (m.gen == g0) {
            try m.ensureTrans(&m.atrans, m.states.items.len, self.n_classes);
            m.atrans.items[idx] = @intCast(nid);
        }
        return nid;
    }

    /// Unanchored transition: byte successors ++ lowest-priority `start`
    /// (the lazy `.*?` injection). Never DEAD. Memoized.
    fn uStep(self: *const LazyProg, m: *LazyMemo, sid: u32, cls: usize) !u32 {
        try m.ensureTrans(&m.utrans, m.states.items.len, self.n_classes);
        const idx = @as(usize, sid) * self.n_classes + cls;
        const c = m.utrans.items[idx];
        if (c != UNKNOWN) return @intCast(c);
        var src: [MAX_NFA]u16 = undefined;
        const list = m.states.items[sid];
        @memcpy(src[0..list.len], list);
        const sym = self.rep[cls];
        var seeds: [MAX_EDGES]u16 = undefined;
        var ns: usize = 0;
        for (src[0..list.len]) |nst| {
            var cj = self.cnt_off[nst];
            while (cj < self.cnt_off[nst + 1]) : (cj += 1) {
                if (hasBit(&self.nfa.sets[self.cnt_set[cj]], sym)) {
                    seeds[ns] = self.cnt_to[cj];
                    ns += 1;
                }
            }
        }
        seeds[ns] = @intCast(self.nfa.start); // lowest priority (last)
        ns += 1;
        var buf: [MAX_NFA]u16 = undefined;
        var acc = false;
        const g0 = m.gen;
        const len = self.closure(seeds[0..ns], &buf, &acc);
        const nid = try m.intern(buf[0..len], acc);
        if (m.gen == g0) {
            try m.ensureTrans(&m.utrans, m.states.items.len, self.n_classes);
            m.utrans.items[idx] = @intCast(nid);
        }
        return nid;
    }

    /// Reverse transition (memoized). `null` ⇒ no reverse predecessor.
    fn rStep(self: *const LazyProg, m: *LazyMemo, rsid: u32, cls: usize) !?u32 {
        try m.ensureTrans(&m.rtrans, m.rstates.items.len, self.n_classes);
        const idx = @as(usize, rsid) * self.n_classes + cls;
        const c = m.rtrans.items[idx];
        if (c == TDEAD) return null;
        if (c != UNKNOWN) return @intCast(c);
        var src: [MAX_NFA]u16 = undefined;
        const list = m.rstates.items[rsid];
        @memcpy(src[0..list.len], list);
        const sym = self.rep[cls];
        var seeds: [MAX_EDGES]u16 = undefined;
        var rs: usize = 0;
        for (src[0..list.len]) |nst| {
            var cj = self.rcnt_off[nst];
            while (cj < self.rcnt_off[nst + 1]) : (cj += 1) {
                if (hasBit(&self.nfa.sets[self.rcnt_set[cj]], sym)) {
                    seeds[rs] = self.rcnt_from[cj];
                    rs += 1;
                }
            }
        }
        if (rs == 0) {
            m.rtrans.items[idx] = TDEAD;
            return null;
        }
        var buf: [MAX_NFA]u16 = undefined;
        var hit = false;
        const g0 = m.rgen;
        const len = self.closureRev(seeds[0..rs], &buf, &hit);
        const nid = try m.rintern(buf[0..len], hit);
        if (m.rgen == g0) {
            try m.ensureTrans(&m.rtrans, m.rstates.items.len, self.n_classes);
            m.rtrans.items[idx] = @intCast(nid);
        }
        return nid;
    }

    /// Recover the leftmost start of the match ending at `end`, not earlier
    /// than `lo`, via the memoized reverse DFA.
    fn reverseStart(self: *const LazyProg, m: *LazyMemo, input: []const u8, end: usize, lo: usize) !usize {
        var seed = [_]u16{@intCast(self.nfa.accept)};
        var rb: [MAX_NFA]u16 = undefined;
        var rhit = false;
        const rlen = self.closureRev(&seed, &rb, &rhit);
        var rsid = try m.rintern(rb[0..rlen], rhit);
        var start: usize = end;
        var pos: usize = end;
        while (pos > lo) {
            const cls = self.class_of[input[pos - 1]];
            const next = try self.rStep(m, rsid, cls) orelse break;
            rsid = next;
            pos -= 1;
            if (m.rhas_start.items[rsid]) start = pos;
        }
        return start;
    }

    /// Materialise the *entire* memoised automaton (forward unanchored
    /// `uStep`/`aStep` + reverse `rStep`) to fixpoint into flat, owned
    /// transition tables — a dense frozen form of this exact lazy program.
    /// The construction reuses the gate-verified transition oracle verbatim,
    /// so a `DenseSearch` is behaviourally identical to `findLeftmostFrom`
    /// by construction (the existing lazy differential test pins it). It is
    /// the lever-A endpoint: the same O(n) single pass + reverse start, but
    /// the hot loop is one array index/byte (no intern / gen / closure).
    ///
    /// Returns `null` if the state count exceeds `MAX_DENSE_STATES` (caller
    /// keeps the plain lazy engine — the current shipped behaviour, so a
    /// blow-up is a no-op, never a regression). Only valid for the
    /// unanchored / no-conditional shape (`findLeftmostFrom`'s fast path);
    /// `a_start`/`a_end`/`has_cond` ⇒ `null` (caller falls back).
    pub const MAX_DENSE_STATES: usize = 4096;

    pub fn freezeDense(self: *LazyProg, allocator: std.mem.Allocator) !?*DenseSearch {
        if (self.a_start or self.a_end or self.has_cond) return null;
        const nc = self.n_classes;

        var m = LazyMemo.init(allocator);
        defer m.deinit();
        m.cap = std.math.maxInt(usize); // never flush during materialisation

        // --- forward state space (uStep ++ aStep to fixpoint) ---
        var sbuf: [MAX_NFA]u16 = undefined;
        var sacc = false;
        const slen = self.closure(&[_]u16{@intCast(self.nfa.start)}, &sbuf, &sacc);
        const start_fwd = try m.intern(sbuf[0..slen], sacc);
        var head: usize = 0;
        while (head < m.states.items.len) : (head += 1) {
            if (m.states.items.len > MAX_DENSE_STATES) return null;
            var cls: usize = 0;
            while (cls < nc) : (cls += 1) {
                _ = try self.uStep(&m, @intCast(head), cls);
                _ = try self.aStep(&m, @intCast(head), cls);
            }
        }
        const nf = m.states.items.len;

        // --- reverse state space (rStep to fixpoint) ---
        var rbuf: [MAX_NFA]u16 = undefined;
        var rhit = false;
        const rlen = self.closureRev(&[_]u16{@intCast(self.nfa.accept)}, &rbuf, &rhit);
        const start_rev = try m.rintern(rbuf[0..rlen], rhit);
        var rhead: usize = 0;
        while (rhead < m.rstates.items.len) : (rhead += 1) {
            if (m.rstates.items.len > MAX_DENSE_STATES) return null;
            var cls: usize = 0;
            while (cls < nc) : (cls += 1) {
                _ = try self.rStep(&m, @intCast(rhead), cls);
            }
        }
        const nr = m.rstates.items.len;
        if (nf >= DenseSearch.DEAD or nr >= DenseSearch.DEAD) return null;

        // --- snapshot into owned flat tables (UNKNOWN cannot occur: every
        //     (state,class) was computed above; TDEAD ⇒ the DEAD sentinel) ---
        const ds = try allocator.create(DenseSearch);
        errdefer allocator.destroy(ds);
        ds.* = .{
            .allocator = allocator,
            .class_of = self.class_of,
            .n_classes = nc,
            .n_fwd = nf,
            .n_rev = nr,
            .start_fwd = @intCast(start_fwd),
            .start_rev = @intCast(start_rev),
            .utrans = try allocator.alloc(u16, nf * nc),
            .atrans = try allocator.alloc(u16, nf * nc),
            .accept = try allocator.alloc(bool, nf),
            .rtrans = try allocator.alloc(u16, nr * nc),
            .rhas_start = try allocator.alloc(bool, nr),
        };
        errdefer ds.freeArrays();
        var i: usize = 0;
        while (i < nf) : (i += 1) {
            ds.accept[i] = m.accept.items[i];
            var c: usize = 0;
            while (c < nc) : (c += 1) {
                const u = m.utrans.items[i * nc + c]; // ≥0 (uStep never DEAD)
                ds.utrans[i * nc + c] = @intCast(u);
                const a = m.atrans.items[i * nc + c];
                ds.atrans[i * nc + c] = if (a == TDEAD) DenseSearch.DEAD else @intCast(a);
            }
        }
        i = 0;
        while (i < nr) : (i += 1) {
            ds.rhas_start[i] = m.rhas_start.items[i];
            var c: usize = 0;
            while (c < nc) : (c += 1) {
                const r = m.rtrans.items[i * nc + c];
                ds.rtrans[i * nc + c] = if (r == TDEAD) DenseSearch.DEAD else @intCast(r);
            }
        }
        return ds;
    }
};

// --- Tests -----------------------------------------------------------------

test "lazy_dfa: agrees with full_dfa over a corpus" {
    const hir = @import("../hir.zig");
    const parser = @import("../parser.zig");
    const full_dfa = @import("full_dfa.zig");
    const core = @import("core.zig");
    const a = std.testing.allocator;

    const pats = [_][]const u8{ "a.*c", "ab*c", "[a-z]+@[a-z]+", "cat|dog|bird", "^a.*?b", "\\d{2,4}" };
    const ins = [_][]const u8{ "", "ac", "xxabbcyy", "a@b", "dog cat", "aXXb", "1234", "no" };

    for (pats) |p| {
        var h = hir.Hir(null).initRuntime();
        defer h.deinit(a);
        parser.parse(null, &h, a, p, .{}) catch continue;
        var nfa = try thompson.build(null, &h);
        const fd = full_dfa.compute(null, &nfa, h.anchored_start, h.anchored_end);
        if (fd.outcome != .ok) continue;

        var prog = try LazyProg.init(a, &nfa, h.anchored_start, h.anchored_end);
        defer prog.deinit();
        var memo = LazyMemo.init(a);
        defer memo.deinit();

        for (ins) |in| {
            const f = core.findLeftmost(&fd, in);
            const l = try prog.findLeftmost(&memo, in);
            try std.testing.expectEqual(f == null, l == null);
            if (f) |fs| {
                try std.testing.expectEqual(fs.start, l.?.start);
                try std.testing.expectEqual(fs.end, l.?.end);
            }
        }
    }
}

test "lazy_dfa: memoized single-pass == core.findLeftmost (findLeftmostFrom / isMatchFast / findAll / flush)" {
    const hir = @import("../hir.zig");
    const parser = @import("../parser.zig");
    const full_dfa = @import("full_dfa.zig");
    const core = @import("core.zig");
    const a = std.testing.allocator;

    // Span-exact differential vs the gate-pinned engine: classes,
    // alternation (leftmost-first vs longest), greedy/lazy quantifiers,
    // dotstar, optional/empty-capable, literals, anchored-end (delegates).
    const pats = [_][]const u8{
        "a",          "abc",         "[a-z]+",      "[0-9]{2,4}",
        "a|ab",       "ab|a",        "cat|dog|c",   "a.*b",
        "a.*?b",      "x?y",         "a*",          "(ab)+",
        "[a-z]+@[a-z]+\\.[a-z]+",    "\\d+",        "a+b+",
        "(foo|foobar)x",             "z*",          "a.b",
        "ab$",        "[^x]+",
    };
    const ins = [_][]const u8{
        "",            "a",            "xxabbcyy",      "ab",
        "the cat dog", "  abc  ",       "foobarx foox",  "a@b.com here",
        "1234 56",     "zzz",           "xyy y",         "no match here",
        "aaabbb",      "x y a.b ab",    "fin: ab",       "....abXcd",
        "ababab",      "qqqqq",         "aXbYc",         "a",
    };

    for (pats) |p| {
        var h = hir.Hir(null).initRuntime();
        defer h.deinit(a);
        parser.parse(null, &h, a, p, .{}) catch continue;
        var nfa = thompson.build(null, &h) catch continue;
        const fd = full_dfa.compute(null, &nfa, h.anchored_start, h.anchored_end);
        if (fd.outcome != .ok) continue;

        var prog = try LazyProg.init(a, &nfa, h.anchored_start, h.anchored_end);
        defer prog.deinit();
        var memo = LazyMemo.init(a);
        defer memo.deinit();
        memo.cap = 3; // tiny cap: exercise flush-restart + thrash fallback

        for (ins) |in| {
            const f = core.findLeftmost(&fd, in);
            const l = try prog.findLeftmostFrom(&memo, in, 0);
            std.testing.expectEqual(f == null, l == null) catch |e| {
                std.debug.print("MISMATCH exists pat=\"{s}\" in=\"{s}\"\n", .{ p, in });
                return e;
            };
            if (f) |fs| {
                std.testing.expectEqual(fs.start, l.?.start) catch |e| {
                    std.debug.print("MISMATCH start pat=\"{s}\" in=\"{s}\" core={d} fast={d}\n", .{ p, in, fs.start, l.?.start });
                    return e;
                };
                std.testing.expectEqual(fs.end, l.?.end) catch |e| {
                    std.debug.print("MISMATCH end pat=\"{s}\" in=\"{s}\" core={d} fast={d}\n", .{ p, in, fs.end, l.?.end });
                    return e;
                };
            }

            try std.testing.expectEqual(f != null, try prog.isMatchFast(&memo, in));

            var from: usize = 0;
            while (from <= in.len) : (from += 1) {
                const want = core.findLeftmost(&fd, in[from..]);
                const got = try prog.findLeftmostFrom(&memo, in, from);
                try std.testing.expectEqual(want == null, got == null);
                if (want) |w| {
                    try std.testing.expectEqual(w.start + from, got.?.start);
                    try std.testing.expectEqual(w.end + from, got.?.end);
                }
            }
        }

        // Single-pass findAll driver (memo persists, no per-match restart)
        // == core.findAll non-overlapping leftmost.
        const big = "aab abc 12 cat ab a@b.com xx foobarx ab$ zz aaabbb";
        const want_all = try core.findAll(&fd, a, big);
        defer a.free(want_all);
        var got_all: std.ArrayListUnmanaged(core.Span) = .empty;
        defer got_all.deinit(a);
        var pos: usize = 0;
        while (pos <= big.len) {
            const s = (try prog.findLeftmostFrom(&memo, big, pos)) orelse break;
            try got_all.append(a, .{ .start = s.start, .end = s.end });
            pos = if (s.end == s.start) s.end + 1 else s.end;
        }
        try std.testing.expectEqual(want_all.len, got_all.items.len);
        for (want_all, got_all.items) |w, g| {
            try std.testing.expectEqual(w.start, g.start);
            try std.testing.expectEqual(w.end, g.end);
        }
    }
}

test "lazy_dfa: DenseSearch (lever A) == core.findLeftmost (spans / resume / findAll)" {
    const hir = @import("../hir.zig");
    const parser = @import("../parser.zig");
    const full_dfa = @import("full_dfa.zig");
    const core = @import("core.zig");
    const a = std.testing.allocator;

    // Floor-cluster shapes + the alternation/quantifier/dotstar battery.
    const pats = [_][]const u8{
        "v?[0-9]+\\.[0-9]+\\.[0-9]+",      "[0-9]{4}-[0-9]{2}-[0-9]{2}",
        "[0-9]{4}[ -][0-9]{4}[ -][0-9]{4}[ -][0-9]{4}",
        "\\(?[0-9]{3}\\)?[ .-][0-9]{3}[ .-][0-9]{4}",
        "(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}",
        "a.*c",       "ab*c",   "[a-z]+@[a-z]+", "cat|dog|bird",
        "a|ab",       "ab|a",   "a.*?b",         "(ab)+",
        "\\d+",       "a+b+",   "(foo|foobar)x", "[^x]+",
    };
    const ins = [_][]const u8{
        "",                       "v1.2.3 x 10.20.30 9.9 4.5.6",
        "no 2026-05-18 then 99-9-9 1999-12-31 end",
        "4111 1111 1111 1111 nope 1 2 3",
        "(555) 123-4567 and 800-555-0199 x",
        "de:ad:be:ef:00:11 zz:zz",
        "xxabbcyy",  "ac",  "a@b dog cat",  "1234 56",
        "the cat dog bird", "aaabbb", "aXXb", "ababab",
        "fin: ab",   "....abXcd",  "foobarx foox", "qqqqq",
    };

    for (pats) |p| {
        var h = hir.Hir(null).initRuntime();
        defer h.deinit(a);
        parser.parse(null, &h, a, p, .{}) catch continue;
        var nfa = thompson.build(null, &h) catch continue;
        const fd = full_dfa.compute(null, &nfa, h.anchored_start, h.anchored_end);
        if (fd.outcome != .ok) continue;

        var prog = try LazyProg.init(a, &nfa, h.anchored_start, h.anchored_end);
        const ds_opt = try prog.freezeDense(a);
        prog.deinit();
        const ds = ds_opt orelse continue; // anchored/cond/too-big → skipped
        defer {
            ds.deinit();
            a.destroy(ds);
        }

        for (ins) |in| {
            // Span-exact vs the gate-pinned oracle, at every resume offset.
            var from: usize = 0;
            while (from <= in.len) : (from += 1) {
                const want = core.findLeftmost(&fd, in[from..]);
                const got = ds.findFrom(in, from);
                std.testing.expectEqual(want == null, got == null) catch |e| {
                    std.debug.print("MISMATCH exists pat=\"{s}\" in=\"{s}\" from={d}\n", .{ p, in, from });
                    return e;
                };
                if (want) |w| {
                    try std.testing.expectEqual(w.start + from, got.?.start);
                    try std.testing.expectEqual(w.end + from, got.?.end);
                }
            }
            try std.testing.expectEqual(core.findLeftmost(&fd, in) != null, ds.isMatch(in));
        }

        // Non-overlapping iteration == core.findAll.
        const big = "v1.2.3 ab 4111 1111 1111 1111 cat 2026-05-18 a@b zz 1.2.3";
        const want_all = try core.findAll(&fd, a, big);
        defer a.free(want_all);
        var got_n: usize = 0;
        var pos: usize = 0;
        while (pos <= big.len) {
            const s = ds.findFrom(big, pos) orelse break;
            if (got_n < want_all.len) {
                try std.testing.expectEqual(want_all[got_n].start, s.start);
                try std.testing.expectEqual(want_all[got_n].end, s.end);
            }
            got_n += 1;
            pos = if (s.end == s.start) s.end + 1 else s.end;
        }
        try std.testing.expectEqual(want_all.len, got_n);
    }
}
