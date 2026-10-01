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
const common = @import("../common.zig");
const thompson = @import("../thompson.zig");
const dfa_build = @import("dfa_build.zig");
const lazy_memo = @import("lazy_memo.zig");
const LookKind = @import("../hir.zig").LookKind;
const cc = @import("charclass.zig");
const dense_search = @import("dense_search.zig");

// Every buffer here is sized to the NFA at hand (CSR at `init`, per-search
// scratch in the memo): the lazy DFA is the runtime home of NFAs far past the
// eager `thompson.MAX_NFA`, so it has no fixed-size construction arrays.

// Mutable per-search scratch + the frozen dense form now live in their own
// files; re-exported here so consumers keep using `lazy_dfa.{LazyMemo,
// DenseSearch,Span}` and the transition-cache sentinels stay in scope.
pub const LazyMemo = lazy_memo.LazyMemo;
const Scratch = lazy_memo.Scratch;
pub const DEFAULT_CACHE_STATES = lazy_memo.DEFAULT_CACHE_STATES;
pub const DenseSearch = dense_search.DenseSearch;
pub const Span = dense_search.Span;

const UNKNOWN = lazy_memo.UNKNOWN; // transition not yet computed
const TDEAD = lazy_memo.TDEAD; // computed: no byte successor (anchored only)

const hasBit = common.hasBit;

/// Immutable program: CSR adjacency, reverse CSR, byte-equivalence classes.
/// Built once at compile; shared read-only (no mutation during search).
pub const LazyProg = struct {
    allocator: std.mem.Allocator,
    nfa: *const thompson.Nfa(null),
    a_start: bool,
    a_end: bool,
    /// Look-assertion mode (see "Look-assertions" below): the NFA carries
    /// `\b \B ^ $ (?m)^ (?m)$ \A \z` edges, evaluated as conditional ε's from
    /// the byte context around each position. Selected by `init` iff the NFA
    /// has look edges; an NFA with a look this mode cannot express (`\Z`,
    /// `!lookSupported`) is refused by `init` with `error.LookUnsupported`.
    look: bool = false,
    /// Look mode: per-ε-CSR-entry look kind (`LOOK_NONE` = plain ε), forward
    /// and reverse, parallel to `eps_to` / `reps_to`.
    eps_look: []u8 = &.{},
    reps_look: []u8 = &.{},

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

    pub const InitError = error{
        /// The NFA has a look edge this engine cannot evaluate (`\Z`: two
        /// bytes of lookahead; see `lookSupported`). Callers route such NFAs
        /// to the backtracker. A typed error in every build mode — the
        /// classic closure would otherwise reach `lookOk`'s `unreachable`.
        LookUnsupported,
        OutOfMemory,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        nfa: *const thompson.Nfa(null),
        a_start: bool,
        a_end: bool,
    ) InitError!LazyProg {
        // CSR sized to the NFA's *actual* edge/state counts (runtime NFAs can
        // be far past the eager `MAX_NFA`). Allocate into locals with
        // `errdefer` so a mid-sequence OOM frees what was already taken.
        const ne = nfa.n_edges;
        const no = nfa.n_states + 1;
        const eps_to = try allocator.alloc(u16, ne);
        errdefer allocator.free(eps_to);
        const eps_look = try allocator.alloc(u8, ne);
        errdefer allocator.free(eps_look);
        const eps_off = try allocator.alloc(usize, no);
        errdefer allocator.free(eps_off);
        const cnt_to = try allocator.alloc(u16, ne);
        errdefer allocator.free(cnt_to);
        const cnt_set = try allocator.alloc(u16, ne);
        errdefer allocator.free(cnt_set);
        const cnt_off = try allocator.alloc(usize, no);
        errdefer allocator.free(cnt_off);
        const reps_to = try allocator.alloc(u16, ne);
        errdefer allocator.free(reps_to);
        const reps_look = try allocator.alloc(u8, ne);
        errdefer allocator.free(reps_look);
        const reps_off = try allocator.alloc(usize, no);
        errdefer allocator.free(reps_off);
        const rcnt_from = try allocator.alloc(u16, ne);
        errdefer allocator.free(rcnt_from);
        const rcnt_set = try allocator.alloc(u16, ne);
        errdefer allocator.free(rcnt_set);
        const rcnt_off = try allocator.alloc(usize, no);
        errdefer allocator.free(rcnt_off);
        var self = LazyProg{
            .allocator = allocator,
            .nfa = nfa,
            .a_start = a_start,
            .a_end = a_end,
            .eps_to = eps_to,
            .eps_look = eps_look,
            .eps_off = eps_off,
            .cnt_to = cnt_to,
            .cnt_set = cnt_set,
            .cnt_off = cnt_off,
            .reps_to = reps_to,
            .reps_look = reps_look,
            .reps_off = reps_off,
            .rcnt_from = rcnt_from,
            .rcnt_set = rcnt_set,
            .rcnt_off = rcnt_off,
        };
        try self.buildCsr();
        self.classify();
        if (hasLookEdges(nfa)) {
            if (!lookSupported(nfa)) return error.LookUnsupported;
            // State ids + the trailer word share a `u16`: guaranteed by the
            // builder's ceiling (`thompson.MAX_NFA_RUNTIME < TRAILER`).
            std.debug.assert(nfa.n_states < TRAILER);
            self.look = true;
            self.refineClassesForLooks();
        }
        return self;
    }

    pub fn deinit(self: *LazyProg) void {
        self.allocator.free(self.eps_to);
        self.allocator.free(self.eps_look);
        self.allocator.free(self.eps_off);
        self.allocator.free(self.cnt_to);
        self.allocator.free(self.cnt_set);
        self.allocator.free(self.cnt_off);
        self.allocator.free(self.reps_to);
        self.allocator.free(self.reps_look);
        self.allocator.free(self.reps_off);
        self.allocator.free(self.rcnt_from);
        self.allocator.free(self.rcnt_set);
        self.allocator.free(self.rcnt_off);
    }

    /// Byte equivalence classes: two bytes share a class iff every NFA set
    /// treats them identically; `rep[c]` is a representative (the smallest
    /// member). Partition refinement — split every class by membership in each
    /// set — is O(n_sets × 256), where the pairwise definition is
    /// O(256² × n_sets) (≈ 0.3 G steps for a 9 K-set NFA). Ids are assigned in
    /// first-occurrence byte order, the same numbering as `dfa_build.classify`.
    fn classify(self: *LazyProg) void {
        var class_of = [_]u16{0} ** 256;
        var n: usize = 1;
        for (self.nfa.sets[0..self.nfa.n_sets]) |*set| {
            if (n == 256) break;
            var remap = [_]i16{-1} ** 512;
            var nn: usize = 0;
            for (&class_of, 0..) |*c, b| {
                const key = @as(usize, c.*) * 2 + @intFromBool(hasBit(set, @intCast(b)));
                if (remap[key] < 0) {
                    remap[key] = @intCast(nn);
                    nn += 1;
                }
                c.* = @intCast(remap[key]);
            }
            n = nn;
        }
        var seen = [_]bool{false} ** 256;
        for (class_of, 0..) |c, b| {
            self.class_of[b] = @intCast(c);
            if (!seen[c]) {
                seen[c] = true;
                self.rep[c] = @intCast(b);
            }
        }
        self.n_classes = n;
    }

    /// Priority-ordered ε-closure + leftmost-first accept cut of a look-free
    /// state (the classic mode): the look-aware closure with no look edges to
    /// evaluate.
    inline fn closure(self: *const LazyProg, m: *LazyMemo, seeds: []const u16, out: []u16, acc: *bool) usize {
        return self.closureL(&m.sc, seeds, CTX_EDGE, CTX_EDGE, out, acc);
    }

    /// Reverse ε-reachability (classic mode). `*hit` ⇔ the forward start is
    /// reached.
    inline fn closureRev(self: *const LazyProg, m: *LazyMemo, seeds: []const u16, out: []u16, hit: *bool) usize {
        return self.closureRevL(&m.sc, seeds, CTX_EDGE, CTX_EDGE, out, hit);
    }

    /// Size the memo's transition scratch for this NFA (every public entry).
    inline fn prep(self: *const LazyProg, m: *LazyMemo) !void {
        try m.ensureScratch(self.nfa.n_states, self.nfa.n_edges);
    }

    // --- Search entry points (operate on a borrowed mutable memo) ---------

    /// Unanchored leftmost (leftmost-first) match in a **single forward
    /// pass** resuming the search at `from` (no input re-slicing), + a
    /// memoized reverse pass for the start. `a_start` delegates to the
    /// always-correct restart (one anchored run); `a_end` to the reverse pass.
    pub fn findLeftmostFrom(self: *const LazyProg, m: *LazyMemo, input: []const u8, from: usize) !?Span {
        try self.prep(m);
        if (self.look) return self.findLeftmostFromL(m, input, from);
        if (self.a_start)
            return self.restartFrom(m, input, from);
        // `$`/`\z`-anchored: the `Σ*?` forward injection runs to `input.len`
        // and an accepting *final* state means the pattern matches a suffix
        // ending there; one reverse pass then recovers the leftmost start.
        // This replaces the per-position `restartFrom` — O(n²) on non-matching
        // `class+$` input (`a+$`, `\s+$`, `(a+)+$`, …) — with one forward + one
        // reverse pass (the anti-ReDoS fix for the `$` family).
        if (self.a_end)
            return self.findAnchoredEndFrom(m, input, from);

        // A flush (cache full) keeps the scan going: every step returns an id
        // interned in the CURRENT generation, so the walk simply continues from
        // the current position — restarting from `from` re-created the same
        // states again. Only a memo that thrashes (rust-regex heuristic, see
        // `GiveUp`) is abandoned; the caller then uses the PikeVM.
        var gu = GiveUp{ .gen = m.gen, .mark = from };
        var sid = try self.startState(m);
        var have = m.accept.items[sid];
        var end: usize = from;
        var i: usize = from;
        while (i < input.len) : (i += 1) {
            const cls = self.class_of[input[i]];
            if (!have) {
                sid = try self.uStep(m, sid, cls);
            } else {
                sid = (try self.aStep(m, sid, cls)) orelse break; // threads died
            }
            try gu.check(m, i);
            if (m.accept.items[sid]) {
                have = true;
                end = i + 1;
            }
        }
        if (!have) return null;
        const start = try self.reverseStart(m, input, end, from);
        return .{ .start = start, .end = end };
    }

    /// Classic-mode start state (the closure of the NFA start), cached in the
    /// memo for the current generation.
    fn startState(self: *const LazyProg, m: *LazyMemo) !u32 {
        if (m.fstart_gen[0] == m.gen) return m.fstart[0];
        const sseed = [_]u16{@intCast(self.nfa.start)};
        const sbuf = m.sc.buf;
        var sacc = false;
        const slen = self.closure(m, &sseed, sbuf, &sacc);
        const sid = try m.intern(sbuf[0..slen], sacc);
        m.fstart[0] = sid;
        m.fstart_gen[0] = m.gen; // after `intern` (which may have flushed)
        return sid;
    }

    /// Classic-mode reverse start (reverse closure of the NFA accept), cached.
    fn revStartState(self: *const LazyProg, m: *LazyMemo) !u32 {
        if (m.rstart_gen[0] == m.rgen) return m.rstart[0];
        var seed = [_]u16{@intCast(self.nfa.accept)};
        const rb = m.sc.buf;
        var rhit = false;
        const rlen = self.closureRev(m, &seed, rb, &rhit);
        const rsid = try m.rintern(rb[0..rlen], rhit);
        m.rstart[0] = rsid;
        m.rstart_gen[0] = m.rgen;
        return rsid;
    }

    /// The always-correct classic-mode per-position restart, for a caller with
    /// no PikeVM to fall back on after `error.LazyGaveUp`.
    pub fn findLeftmostRestart(self: *const LazyProg, m: *LazyMemo, input: []const u8, from: usize) !?Span {
        std.debug.assert(!self.look);
        try self.prep(m);
        return self.restartFrom(m, input, from);
    }

    /// Shared backward walk over the reverse memo: from `end` toward `lo`, find
    /// whether any suffix ending at `end` reaches the forward start (`exists`)
    /// and the leftmost position where it does (`start`, defaulting to `end` for
    /// the empty/nullable match). Self-healing across reverse-memo flushes (each
    /// `rStep` returns a current-generation id; the loop reassigns `rsid` before
    /// the `rhas_start` read). The single core of `findAnchoredEndFrom`
    /// (existence + start at `end == input.len`) and `reverseStart` (start only,
    /// caller guarantees existence).
    const RevScan = struct { exists: bool, start: usize };
    fn reverseScan(self: *const LazyProg, m: *LazyMemo, input: []const u8, end: usize, lo: usize) !RevScan {
        // The reverse memo has its own cap and can thrash independently of
        // the forward one (`GiveUp` in reverse mode: same fallback).
        var gu = GiveUp{ .gen = m.rgen, .mark = end, .rev = true };
        var rsid = try self.revStartState(m);
        var out = RevScan{ .exists = m.rhas_start.items[rsid], .start = end }; // empty/nullable match at `end`
        var pos: usize = end;
        while (pos > lo) {
            const next = try self.rStep(m, rsid, self.class_of[input[pos - 1]]) orelse break;
            rsid = next;
            pos -= 1;
            try gu.check(m, pos);
            if (m.rhas_start.items[rsid]) {
                out.exists = true;
                out.start = pos; // descending pos => last write is the leftmost
            }
        }
        return out;
    }

    /// Single-pass `$`/`\z`-anchored leftmost match: a match must end exactly at
    /// `input.len`, so this is a pure reverse-reachability pass (`reverseScan`)
    /// from `input.len` back toward `from`. Reverse — not the `Σ*?` forward pass
    /// — because the forward leftmost-first accept-cut drops a later-starting
    /// thread once an earlier one accepts mid-string, but for `$` only an accept
    /// at the very end counts (`ab$` on `"ababab"`: the match is the *last* `ab`).
    /// One O(n) pass, replacing the per-position `restartFrom` (O(n²) on
    /// `class+$` input).
    fn findAnchoredEndFrom(self: *const LazyProg, m: *LazyMemo, input: []const u8, from: usize) !?Span {
        const r = try self.reverseScan(m, input, input.len, from);
        if (!r.exists) return null;
        return .{ .start = r.start, .end = input.len };
    }

    /// Memoized single-pass existence check (stops at the first accept; no
    /// greedy extend, no reverse pass). With `$`/`\z` only an accept *at*
    /// `input.len` counts, so existence reduces to the reverse-reachability
    /// pass (`findAnchoredEndFrom`) — still one O(n) pass.
    pub fn isMatchFast(self: *const LazyProg, m: *LazyMemo, input: []const u8) !bool {
        try self.prep(m);
        if (self.look) return self.isMatchL(m, input);
        if (self.a_start)
            return (try self.restartFrom(m, input, 0)) != null;
        if (self.a_end)
            return (try self.findAnchoredEndFrom(m, input, 0)) != null;
        var gu = GiveUp{ .gen = m.gen, .mark = 0 };
        var sid = try self.startState(m);
        if (m.accept.items[sid]) return true;
        var i: usize = 0;
        while (i < input.len) : (i += 1) {
            sid = try self.uStep(m, sid, self.class_of[input[i]]);
            try gu.check(m, i);
            if (m.accept.items[sid]) return true;
        }
        return false;
    }

    /// Memoized anchored leftmost via per-position restart (Stage-1
    /// coverage for patterns the eager DFA could not hold; also the
    /// always-correct fallback). Flush-immune (a forward pass per `sp`).
    pub fn findLeftmost(self: *const LazyProg, m: *LazyMemo, input: []const u8) !?Span {
        try self.prep(m);
        if (self.look) return self.findLeftmostFromL(m, input, 0);
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
        const buf = m.sc.buf;
        var acc = false;
        var sid = try self.startState(m);
        var last: ?usize = if (m.accept.items[sid]) start_pos else null;
        var i = start_pos;
        while (i < input.len) : (i += 1) {
            const next = try self.step(m, sid, input[i], buf, &acc) orelse break;
            sid = next;
            if (m.accept.items[sid]) last = i + 1;
        }
        if (self.a_end) {
            if (last) |e| if (e == input.len) return e;
            return null;
        }
        return last;
    }

    /// Gather the consume-edge targets out of `src`'s NFA states that fire on
    /// `byte` into `seeds` (returns the count). The CSR triple (`off`/`set`/
    /// `target`) selects the forward (`cnt_*`) or reverse (`rcnt_*`) adjacency, so
    /// the four transition builders (`step`/`aStep`/`uStep`/`rStep`) share ONE
    /// gather instead of four hand-synced copies. Bounded by the NFA's total
    /// consume edges ≤ `seeds.len` (asserted before each accumulating write).
    inline fn collectSeeds(
        self: *const LazyProg,
        src: []const u16,
        off: []const usize,
        set: []const u16,
        target: []const u16,
        byte: u8,
        seeds: []u16,
    ) usize {
        var ns: usize = 0;
        for (src) |nst| {
            var cj = off[nst];
            while (cj < off[nst + 1]) : (cj += 1) {
                if (hasBit(&self.nfa.sets[set[cj]], byte)) {
                    std.debug.assert(ns < seeds.len); // ≤ n_edges consume edges
                    seeds[ns] = target[cj];
                    ns += 1;
                }
            }
        }
        return ns;
    }

    fn step(self: *const LazyProg, m: *LazyMemo, state_id: u32, byte: u8, buf: []u16, acc: *bool) !?u32 {
        const list = m.states.items[state_id];
        const src = m.sc.src;
        @memcpy(src[0..list.len], list);
        const seeds = m.sc.seeds;
        const ns = self.collectSeeds(src[0..list.len], self.cnt_off, self.cnt_set, self.cnt_to, byte, seeds);
        if (ns == 0) return null;
        const len = self.closure(m, seeds[0..ns], buf, acc);
        return try m.intern(buf[0..len], acc.*);
    }

    /// Anchored transition (byte successors only), memoized. `null` ⇒ DEAD.
    fn aStep(self: *const LazyProg, m: *LazyMemo, sid: u32, cls: usize) !?u32 {
        try m.ensureTrans(&m.atrans, m.states.items.len, self.n_classes);
        const idx = @as(usize, sid) * self.n_classes + cls;
        const c = m.atrans.items[idx];
        if (c == TDEAD) return null;
        if (c != UNKNOWN) return @intCast(c);
        const src = m.sc.src;
        const list = m.states.items[sid];
        @memcpy(src[0..list.len], list);
        const sym = self.rep[cls];
        const seeds = m.sc.seeds;
        const ns = self.collectSeeds(src[0..list.len], self.cnt_off, self.cnt_set, self.cnt_to, sym, seeds);
        if (ns == 0) {
            m.atrans.items[idx] = TDEAD;
            return null;
        }
        const buf = m.sc.buf;
        var acc = false;
        const g0 = m.gen;
        const len = self.closure(m, seeds[0..ns], buf, &acc);
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
        const src = m.sc.src;
        const list = m.states.items[sid];
        @memcpy(src[0..list.len], list);
        const sym = self.rep[cls];
        const seeds = m.sc.seeds;
        var ns = self.collectSeeds(src[0..list.len], self.cnt_off, self.cnt_set, self.cnt_to, sym, seeds);
        std.debug.assert(ns < seeds.len); // + the lowest-priority start injection
        seeds[ns] = @intCast(self.nfa.start); // lowest priority (last)
        ns += 1;
        const buf = m.sc.buf;
        var acc = false;
        const g0 = m.gen;
        const len = self.closure(m, seeds[0..ns], buf, &acc);
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
        const src = m.sc.src;
        const list = m.rstates.items[rsid];
        @memcpy(src[0..list.len], list);
        const sym = self.rep[cls];
        const seeds = m.sc.seeds;
        const rs = self.collectSeeds(src[0..list.len], self.rcnt_off, self.rcnt_set, self.rcnt_from, sym, seeds);
        if (rs == 0) {
            m.rtrans.items[idx] = TDEAD;
            return null;
        }
        const buf = m.sc.buf;
        var hit = false;
        const g0 = m.rgen;
        const len = self.closureRev(m, seeds[0..rs], buf, &hit);
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
        // The caller (`findLeftmostFrom`) already proved a match ends at `end`,
        // so only the leftmost start is needed — `reverseScan`'s `exists` is moot.
        return (try self.reverseScan(m, input, end, lo)).start;
    }

    // --- Look-assertions ----------------------------------------------------
    //
    // A look-assertion at position `p` is a function of the byte BEFORE `p`
    // and the byte AT `p`. A DFA state therefore carries the class of the
    // byte it was entered on (`before`: start-of-text / `\n` / word / other),
    // and its ε-closure is computed only when the NEXT byte arrives (`after`),
    // inside the transition — so matches are reported one byte late
    // (rust-regex `hybrid` shape). Concretely a forward state is
    //
    //   (K, before, mflag)
    //
    // `K` = the ordered kernel: threads waiting at `p` before their closure
    // (consume targets of the previous byte ++ the lowest-priority start
    // injection); `mflag` = "a match ended at `p-1`" (the closure computed by
    // the transition INTO this state accepted). A transition on byte `b` at
    // `p`: close `K` with every look evaluated from (`before`, class(`b`)),
    // apply the leftmost-first accept cut, consume `b`, and — unless that
    // closure already accepted (no later starts once a match is in hand) —
    // inject `start`. End of input is one extra closure with `after` = EOI.
    // The reverse pass for the start mirrors it with (R, after, hflag).
    //
    // Encoding: the memo interns `[]u16` lists; the context + flag ride in one
    // trailing word ≥ `TRAILER` (NFA ids are < `TRAILER`, so it stays last
    // under the reverse memo's canonicalising sort). Byte classes are refined
    // so every class has one `ctxOf`. Contexts are absolute: a search from
    // `from > 0` starts with `before = ctxOf(input[from-1])`.

    const LOOK_NONE: u8 = 0xFF;
    const TRAILER: u16 = 0x8000;
    const CTX_EDGE: u2 = 0; // start of text (before) / end of text (after)
    const CTX_NL: u2 = 1;
    const CTX_WORD: u2 = 2;
    const CTX_OTHER: u2 = 3;

    inline fn ctxOf(b: u8) u2 {
        if (b == '\n') return CTX_NL;
        return if (cc.isWord(b)) CTX_WORD else CTX_OTHER;
    }

    inline fn trailer(ctx: u2, flag: bool) u16 {
        return TRAILER | (@as(u16, ctx) << 1) | @intFromBool(flag);
    }

    inline fn trailerCtx(t: u16) u2 {
        return @intCast((t >> 1) & 3);
    }

    /// Truth of look `kind` between a byte of class `before` and one of class
    /// `after` (`CTX_EDGE` = the text edge on that side). Mirrors
    /// `charclass.lookHolds`.
    fn lookOk(kind: u8, before: u2, after: u2) bool {
        return switch (@as(LookKind, @enumFromInt(kind))) {
            .word_boundary => (before == CTX_WORD) != (after == CTX_WORD),
            .non_word_boundary => (before == CTX_WORD) == (after == CTX_WORD),
            .start_text => before == CTX_EDGE,
            .end_text => after == CTX_EDGE,
            .start_line => before == CTX_EDGE or before == CTX_NL,
            .end_line => after == CTX_EDGE or after == CTX_NL,
            .end_text_before_nl => unreachable, // `lookSupported` excludes `\Z`
        };
    }

    pub fn hasLookEdges(nfa: *const thompson.Nfa(null)) bool {
        for (nfa.e_kind[0..nfa.n_edges]) |k| if (k == .look) return true;
        return false;
    }

    /// Every look edge is expressible with one byte of context on each side —
    /// all but `\Z` (end of text OR a final `\n`: two bytes of lookahead).
    pub fn lookSupported(nfa: *const thompson.Nfa(null)) bool {
        var ei: usize = 0;
        while (ei < nfa.n_edges) : (ei += 1) {
            if (nfa.e_kind[ei] == .look and
                @as(LookKind, @enumFromInt(nfa.e_look[ei])) == .end_text_before_nl) return false;
        }
        return true;
    }

    /// The CSRs (both modes): ε AND look edges share one priority-ordered
    /// ε-CSR (`eps_look` tags the look ones, `LOOK_NONE` otherwise) — a state's
    /// out-edges must interleave in NFA emission order for the leftmost-first
    /// closure — and the byte CSRs hold only `.consume` edges. Forward and
    /// reverse. For a look-free NFA this is exactly the eager construction's CSR.
    fn buildCsr(self: *LazyProg) !void {
        const nfa = self.nfa;
        const n = nfa.n_states;
        // Count into `off[s+1]`, prefix-sum, then place each edge through a
        // per-state fill cursor (heap: a runtime NFA can be far past `MAX_NFA`).
        @memset(self.eps_off, 0);
        @memset(self.cnt_off, 0);
        @memset(self.reps_off, 0);
        @memset(self.rcnt_off, 0);
        var ei: usize = 0;
        while (ei < nfa.n_edges) : (ei += 1) {
            if (nfa.e_kind[ei] == .consume) {
                self.cnt_off[nfa.e_from[ei] + 1] += 1;
                self.rcnt_off[nfa.e_to[ei] + 1] += 1;
            } else {
                self.eps_off[nfa.e_from[ei] + 1] += 1;
                self.reps_off[nfa.e_to[ei] + 1] += 1;
            }
        }
        var s: usize = 0;
        while (s < n) : (s += 1) {
            self.eps_off[s + 1] += self.eps_off[s];
            self.cnt_off[s + 1] += self.cnt_off[s];
            self.reps_off[s + 1] += self.reps_off[s];
            self.rcnt_off[s + 1] += self.rcnt_off[s];
        }
        const cur = try self.allocator.alloc(usize, 4 * n);
        defer self.allocator.free(cur);
        const ef = cur[0..n];
        const cf = cur[n .. 2 * n];
        const rf = cur[2 * n .. 3 * n];
        const rcf = cur[3 * n .. 4 * n];
        @memcpy(ef, self.eps_off[0..n]);
        @memcpy(cf, self.cnt_off[0..n]);
        @memcpy(rf, self.reps_off[0..n]);
        @memcpy(rcf, self.rcnt_off[0..n]);
        ei = 0;
        while (ei < nfa.n_edges) : (ei += 1) {
            const f = nfa.e_from[ei];
            const t = nfa.e_to[ei];
            switch (nfa.e_kind[ei]) {
                .consume => {
                    self.cnt_to[cf[f]] = t;
                    self.cnt_set[cf[f]] = nfa.e_set[ei];
                    cf[f] += 1;
                    self.rcnt_from[rcf[t]] = f;
                    self.rcnt_set[rcf[t]] = nfa.e_set[ei];
                    rcf[t] += 1;
                },
                .eps, .look => {
                    const lk: u8 = if (nfa.e_kind[ei] == .look) nfa.e_look[ei] else LOOK_NONE;
                    self.eps_to[ef[f]] = t;
                    self.eps_look[ef[f]] = lk;
                    ef[f] += 1;
                    self.reps_to[rf[t]] = f;
                    self.reps_look[rf[t]] = lk;
                    rf[t] += 1;
                },
            }
        }
    }

    /// Split every byte class so all members share one `ctxOf` (word-ness and
    /// `\n`), making a transition's look evaluation a function of the class.
    fn refineClassesForLooks(self: *LazyProg) void {
        var map = [_]i16{-1} ** (256 * 4);
        var n: usize = 0;
        var b: usize = 0;
        while (b < 256) : (b += 1) {
            const key = @as(usize, self.class_of[b]) * 4 + ctxOf(@intCast(b));
            if (map[key] < 0) {
                map[key] = @intCast(n);
                self.rep[n] = @intCast(b);
                n += 1;
            }
            self.class_of[b] = @intCast(map[key]);
        }
        self.n_classes = n;
    }

    /// Priority-ordered ε-closure of kernel `seeds` with looks evaluated from
    /// (`before`, `after`), + the leftmost-first accept cut (the look-mode peer
    /// of `dfa_build.closure`).
    fn closureL(self: *const LazyProg, sc: *Scratch, seeds: []const u16, before: u2, after: u2, out: []u16, acc: *bool) usize {
        const ep = sc.nextEpoch();
        const mark = sc.mark;
        var len: usize = 0;
        const stack = sc.stack;
        for (seeds) |sd| {
            var sp: usize = 1;
            stack[0] = sd;
            while (sp > 0) {
                sp -= 1;
                const n = stack[sp];
                if (mark[n] == ep) continue;
                mark[n] = ep;
                out[len] = n;
                len += 1;
                var c = self.eps_off[n + 1];
                while (c > self.eps_off[n]) {
                    c -= 1;
                    const lk = self.eps_look[c];
                    if (lk != LOOK_NONE and !lookOk(lk, before, after)) continue;
                    stack[sp] = self.eps_to[c];
                    sp += 1;
                }
            }
        }
        const accept: u16 = @intCast(self.nfa.accept);
        acc.* = false;
        for (out[0..len], 0..) |st, i| {
            if (st == accept) {
                acc.* = true;
                return i + 1;
            }
        }
        return len;
    }

    /// Reverse ε/look reachability of `seeds` at a position between a byte of
    /// class `before` and one of class `after`. `*hit` ⇔ the forward start is
    /// reached (a match can begin here).
    fn closureRevL(self: *const LazyProg, sc: *Scratch, seeds: []const u16, before: u2, after: u2, out: []u16, hit: *bool) usize {
        const ep = sc.nextEpoch();
        const mark = sc.mark;
        var len: usize = 0;
        const stack = sc.stack;
        const fwd_start: u16 = @intCast(self.nfa.start);
        var h = false;
        for (seeds) |sd| {
            var sp: usize = 1;
            stack[0] = sd;
            while (sp > 0) {
                sp -= 1;
                const n = stack[sp];
                if (mark[n] == ep) continue;
                mark[n] = ep;
                out[len] = n;
                len += 1;
                if (n == fwd_start) h = true;
                var c = self.reps_off[n + 1];
                while (c > self.reps_off[n]) {
                    c -= 1;
                    const lk = self.reps_look[c];
                    if (lk != LOOK_NONE and !lookOk(lk, before, after)) continue;
                    stack[sp] = self.reps_to[c];
                    sp += 1;
                }
            }
        }
        hit.* = h;
        return len;
    }

    /// Drop repeated state ids keeping the first (= highest-priority) one, so
    /// equal kernels intern to one state.
    fn dedupe(sc: *Scratch, list: []u16) usize {
        const ep = sc.nextEpoch();
        const mark = sc.mark;
        var n: usize = 0;
        for (list) |st| {
            if (mark[st] == ep) continue;
            mark[st] = ep;
            list[n] = st;
            n += 1;
        }
        return n;
    }

    /// Forward look-mode transition on class `cls`, memoized. `inject` ⇒ the
    /// unanchored table (lowest-priority start injection while no match is in
    /// hand); otherwise the anchored one. `null` ⇒ dead (no thread, no match).
    fn stepL(self: *const LazyProg, m: *LazyMemo, sid: u32, cls: usize, inject: bool) !?u32 {
        const table = if (inject) &m.utrans else &m.atrans;
        try m.ensureTrans(table, m.states.items.len, self.n_classes);
        const idx = @as(usize, sid) * self.n_classes + cls;
        const c = table.items[idx];
        if (c == TDEAD) return null;
        if (c != UNKNOWN) return @intCast(c);
        const list = m.states.items[sid];
        const src = m.sc.src;
        @memcpy(src[0..list.len], list); // `intern` below may flush `list`
        const k = src[0 .. list.len - 1];
        const before = trailerCtx(src[list.len - 1]);
        const sym = self.rep[cls];
        const cbuf = m.sc.buf;
        var acc = false;
        const clen = self.closureL(&m.sc, k, before, ctxOf(sym), cbuf, &acc);
        const seeds = m.sc.seeds;
        var ns = self.collectSeeds(cbuf[0..clen], self.cnt_off, self.cnt_set, self.cnt_to, sym, seeds[0 .. seeds.len - 2]);
        if (inject and !acc) {
            seeds[ns] = @intCast(self.nfa.start);
            ns += 1;
        }
        ns = dedupe(&m.sc, seeds[0..ns]);
        if (ns == 0 and !acc) {
            table.items[idx] = TDEAD;
            return null;
        }
        seeds[ns] = trailer(ctxOf(sym), acc);
        const g0 = m.gen;
        const nid = try m.intern(seeds[0 .. ns + 1], acc);
        if (m.gen == g0) {
            try m.ensureTrans(table, m.states.items.len, self.n_classes);
            table.items[idx] = @intCast(nid);
        }
        return nid;
    }

    /// Does forward state `sid` accept at end of input (closure with
    /// `after` = EOI)?
    fn eoiAccept(self: *const LazyProg, m: *LazyMemo, sid: u32) bool {
        const list = m.states.items[sid];
        var acc = false;
        _ = self.closureL(&m.sc, list[0 .. list.len - 1], trailerCtx(list[list.len - 1]), CTX_EDGE, m.sc.buf, &acc);
        return acc;
    }

    fn startStateL(m: *LazyMemo, start: u16, before: u2) !u32 {
        if (m.fstart_gen[before] == m.gen) return m.fstart[before];
        const k = [_]u16{ start, trailer(before, false) };
        const sid = try m.intern(&k, false);
        m.fstart[before] = sid;
        m.fstart_gen[before] = m.gen;
        return sid;
    }

    inline fn beforeCtx(input: []const u8, pos: usize) u2 {
        return if (pos == 0) CTX_EDGE else ctxOf(input[pos - 1]);
    }

    inline fn afterCtx(input: []const u8, pos: usize) u2 {
        return if (pos == input.len) CTX_EDGE else ctxOf(input[pos]);
    }

    /// Cache-thrash give-up (rust-regex `hybrid` heuristic): after ≥3 flushes,
    /// if fewer than ~10 bytes were searched per state since the last flush the
    /// memo is not paying for itself — the caller falls back to the PikeVM.
    /// One per scan direction: the forward (`gen`) and reverse (`rgen`) memos
    /// flush independently, and a reverse walk that rebuilds a state per byte
    /// is the same O(n × closure) slow path the forward give-up escapes.
    const GiveUp = struct {
        gen: u64,
        flushes: usize = 0,
        mark: usize,
        /// Watch the reverse memo (`rgen`; `pos` descends) instead of the forward one.
        rev: bool = false,

        fn check(self: *GiveUp, m: *const LazyMemo, pos: usize) error{LazyGaveUp}!void {
            const cur = if (self.rev) m.rgen else m.gen;
            if (cur == self.gen) return;
            self.gen = cur;
            self.flushes += 1;
            const progress = if (pos >= self.mark) pos - self.mark else self.mark - pos;
            self.mark = pos;
            if (self.flushes >= 3 and progress < 10 * m.cap) return error.LazyGaveUp;
        }
    };

    /// Look-mode leftmost-first search at/after absolute `from`.
    fn findLeftmostFromL(self: *const LazyProg, m: *LazyMemo, input: []const u8, from: usize) !?Span {
        if (self.a_end) {
            // Every match ends at `input.len`: pure reverse reachability (an
            // end filter the forward accept cut cannot model; see
            // `findAnchoredEndFrom`), leftmost start ≥ `from` (0 under `^`).
            const r = try self.reverseScanL(m, input, input.len, from);
            if (!r.exists) return null;
            if (self.a_start and r.start != 0) return null;
            return .{ .start = r.start, .end = input.len };
        }
        if (self.a_start and from != 0) return null;
        var gu = GiveUp{ .gen = m.gen, .mark = from };
        var sid = try startStateL(m, @intCast(self.nfa.start), beforeCtx(input, from));
        var have = false;
        var end: usize = from;
        var i: usize = from;
        const inject = !self.a_start;
        const dead = while (i < input.len) : (i += 1) {
            const cls = self.class_of[input[i]];
            sid = (try self.stepL(m, sid, cls, inject and !have)) orelse break true;
            try gu.check(m, i);
            if (m.accept.items[sid]) {
                have = true;
                end = i; // delayed: the closure at `i` accepted
            }
        } else false;
        if (!dead and self.eoiAccept(m, sid)) {
            have = true;
            end = input.len;
        }
        if (!have) return null;
        if (self.a_start) return .{ .start = 0, .end = end };
        const r = try self.reverseScanL(m, input, end, from);
        std.debug.assert(r.exists);
        return .{ .start = r.start, .end = end };
    }

    /// Look-mode existence check (stops at the first accept).
    fn isMatchL(self: *const LazyProg, m: *LazyMemo, input: []const u8) !bool {
        if (self.a_end) return (try self.findLeftmostFromL(m, input, 0)) != null;
        var gu = GiveUp{ .gen = m.gen, .mark = 0 };
        var sid = try startStateL(m, @intCast(self.nfa.start), CTX_EDGE);
        var i: usize = 0;
        while (i < input.len) : (i += 1) {
            sid = (try self.stepL(m, sid, self.class_of[input[i]], !self.a_start)) orelse return false;
            try gu.check(m, i);
            if (m.accept.items[sid]) return true;
        }
        return self.eoiAccept(m, sid);
    }

    /// Reverse look-mode transition consuming class `cls` (the byte BEFORE the
    /// current position), memoized. The flag of the resulting state says the
    /// closure at the current position reached the forward start.
    fn rStepL(self: *const LazyProg, m: *LazyMemo, rsid: u32, cls: usize) !?u32 {
        try m.ensureTrans(&m.rtrans, m.rstates.items.len, self.n_classes);
        const idx = @as(usize, rsid) * self.n_classes + cls;
        const c = m.rtrans.items[idx];
        if (c == TDEAD) return null;
        if (c != UNKNOWN) return @intCast(c);
        const list = m.rstates.items[rsid];
        const src = m.sc.src;
        @memcpy(src[0..list.len], list);
        const r = src[0 .. list.len - 1];
        const after = trailerCtx(src[list.len - 1]);
        const sym = self.rep[cls];
        const cbuf = m.sc.buf;
        var hit = false;
        const clen = self.closureRevL(&m.sc, r, ctxOf(sym), after, cbuf, &hit);
        const seeds = m.sc.seeds;
        var ns = self.collectSeeds(cbuf[0..clen], self.rcnt_off, self.rcnt_set, self.rcnt_from, sym, seeds[0 .. seeds.len - 2]);
        ns = dedupe(&m.sc, seeds[0..ns]);
        if (ns == 0 and !hit) {
            m.rtrans.items[idx] = TDEAD;
            return null;
        }
        seeds[ns] = trailer(ctxOf(sym), hit);
        const g0 = m.rgen;
        const nid = try m.rintern(seeds[0 .. ns + 1], hit);
        if (m.rgen == g0) {
            try m.ensureTrans(&m.rtrans, m.rstates.items.len, self.n_classes);
            m.rtrans.items[idx] = @intCast(nid);
        }
        return nid;
    }

    /// Look-mode peer of `reverseScan`: walk back from `end` toward `lo`; the
    /// last position whose closure reaches the forward start is the leftmost
    /// start. The final closure at `lo` uses the real byte before it.
    fn reverseScanL(self: *const LazyProg, m: *LazyMemo, input: []const u8, end: usize, lo: usize) !RevScan {
        const actx = afterCtx(input, end);
        var rsid: u32 = undefined;
        if (m.rstart_gen[actx] == m.rgen) {
            rsid = m.rstart[actx];
        } else {
            var k = [_]u16{ @intCast(self.nfa.accept), trailer(actx, false) };
            rsid = try m.rintern(&k, false);
            m.rstart[actx] = rsid;
            m.rstart_gen[actx] = m.rgen;
        }
        var gu = GiveUp{ .gen = m.rgen, .mark = end, .rev = true }; // see `reverseScan`
        var out = RevScan{ .exists = false, .start = end };
        var pos: usize = end;
        const dead = while (pos > lo) : (pos -= 1) {
            rsid = (try self.rStepL(m, rsid, self.class_of[input[pos - 1]])) orelse break true;
            try gu.check(m, pos - 1);
            if (m.rhas_start.items[rsid]) {
                out.exists = true;
                out.start = pos; // descending ⇒ the last write is the leftmost
            }
        } else false;
        if (!dead) {
            const list = m.rstates.items[rsid];
            var hit = false;
            _ = self.closureRevL(&m.sc, list[0 .. list.len - 1], beforeCtx(input, lo), trailerCtx(list[list.len - 1]), m.sc.buf, &hit);
            if (hit) {
                out.exists = true;
                out.start = lo;
            }
        }
        return out;
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
    /// classic-mode unanchored-start shape (`findLeftmostFrom`'s single pass,
    /// or its `a_end` reverse pass); `a_start` / look mode ⇒ `null` (caller
    /// falls back).
    pub const MAX_DENSE_STATES: usize = 4096;

    pub fn freezeDense(self: *LazyProg, allocator: std.mem.Allocator) !?*DenseSearch {
        if (self.a_start or self.look) return null;
        const nc = self.n_classes;

        var m = LazyMemo.init(allocator);
        defer m.deinit();
        m.cap = std.math.maxInt(usize); // never flush during materialisation
        m.byte_cap = std.math.maxInt(usize);
        try self.prep(&m);

        // --- forward state space (uStep ++ aStep to fixpoint) ---
        // `$`-anchored patterns use a pure reverse pass (`DenseSearch.findFrom`
        // with `a_end`), so the forward tables are dead — skip the fixpoint
        // (it can explode where the reverse is tiny, e.g. `[a-z]*z[a-z]{10}$`)
        // and bake a 1-state dummy.
        var nf: usize = 1;
        var start_fwd: u32 = 0;
        if (!self.a_end) {
            const sbuf = m.sc.buf;
            var sacc = false;
            const slen = self.closure(&m, &[_]u16{@intCast(self.nfa.start)}, sbuf, &sacc);
            start_fwd = try m.intern(sbuf[0..slen], sacc);
            var head: usize = 0;
            while (head < m.states.items.len) : (head += 1) {
                if (m.states.items.len > MAX_DENSE_STATES) return null;
                var cls: usize = 0;
                while (cls < nc) : (cls += 1) {
                    _ = try self.uStep(&m, @intCast(head), cls);
                    _ = try self.aStep(&m, @intCast(head), cls);
                }
            }
            nf = m.states.items.len;
        }

        // --- reverse state space (rStep to fixpoint) ---
        const rbuf = m.sc.buf;
        var rhit = false;
        const rlen = self.closureRev(&m, &[_]u16{@intCast(self.nfa.accept)}, rbuf, &rhit);
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
            .a_end = self.a_end,
            .utrans = try allocator.alloc(u16, nf * nc),
            .atrans = try allocator.alloc(u16, nf * nc),
            .accept = try allocator.alloc(bool, nf),
            .rtrans = try allocator.alloc(u16, nr * nc),
            .rhas_start = try allocator.alloc(bool, nr),
        };
        errdefer ds.freeArrays();
        if (self.a_end) {
            // Forward tables are dead for the reverse-only `$` path; bake a
            // benign 1-state dummy (DEAD self-loop, non-accepting).
            @memset(ds.utrans, 0);
            @memset(ds.atrans, DenseSearch.DEAD);
            @memset(ds.accept, false);
        } else {
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
        }
        var ri: usize = 0;
        while (ri < nr) : (ri += 1) {
            ds.rhas_start[ri] = m.rhas_start.items[ri];
            var c: usize = 0;
            while (c < nc) : (c += 1) {
                const r = m.rtrans.items[ri * nc + c];
                ds.rtrans[ri * nc + c] = if (r == TDEAD) DenseSearch.DEAD else @intCast(r);
            }
        }
        return ds;
    }
};

// --- Tests -----------------------------------------------------------------

test "lazy_dfa: an NFA with `\\Z` is refused with a typed error (never `unreachable`)" {
    const hir = @import("../hir.zig");
    const parser = @import("../parser.zig");
    const a = std.testing.allocator;
    var h = hir.Hir(null).initRuntime();
    defer h.deinit(a);
    try parser.parse(null, &h, a, "ab\\Z", .{});
    var nfa = try thompson.buildAlloc(a, &h);
    defer nfa.deinit(a);
    try std.testing.expect(LazyProg.hasLookEdges(&nfa));
    try std.testing.expect(!LazyProg.lookSupported(&nfa));
    try std.testing.expectError(error.LookUnsupported, LazyProg.init(a, &nfa, h.anchored_start, h.anchored_end));
}

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
        var nfa = try thompson.buildAlloc(a, &h);
        defer nfa.deinit(a);
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
        var nfa = thompson.buildAlloc(a, &h) catch continue;
        defer nfa.deinit(a);
        const fd = full_dfa.compute(null, &nfa, h.anchored_start, h.anchored_end);
        if (fd.outcome != .ok) continue;

        var prog = try LazyProg.init(a, &nfa, h.anchored_start, h.anchored_end);
        defer prog.deinit();
        var memo = LazyMemo.init(a);
        defer memo.deinit();
        memo.cap = 3; // tiny cap: exercise continue-after-flush + the thrash give-up
        // A give-up is handled as `Regex` does for a look-free program: the
        // always-correct per-position restart.
        const Drive = struct {
            fn find(pg: *const LazyProg, mm: *LazyMemo, in: []const u8, from: usize) !?Span {
                return pg.findLeftmostFrom(mm, in, from) catch |e| switch (e) {
                    error.LazyGaveUp => return pg.findLeftmostRestart(mm, in, from),
                    else => return e,
                };
            }
            fn isMatch(pg: *const LazyProg, mm: *LazyMemo, in: []const u8) !bool {
                return pg.isMatchFast(mm, in) catch |e| switch (e) {
                    error.LazyGaveUp => return (try pg.findLeftmostRestart(mm, in, 0)) != null,
                    else => return e,
                };
            }
        };

        for (ins) |in| {
            const f = core.findLeftmost(&fd, in);
            const l = try Drive.find(&prog, &memo, in, 0);
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

            try std.testing.expectEqual(f != null, try Drive.isMatch(&prog, &memo, in));

            var from: usize = 0;
            while (from <= in.len) : (from += 1) {
                const want = core.findLeftmost(&fd, in[from..]);
                const got = try Drive.find(&prog, &memo, in, from);
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
            const s = (try Drive.find(&prog, &memo, big, pos)) orelse break;
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
        var nfa = thompson.buildAlloc(a, &h) catch continue;
        defer nfa.deinit(a);
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
