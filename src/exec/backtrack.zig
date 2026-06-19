//! Tree-walking backtracking matcher for the **non-regular** tier
//! (backreferences `\1`/`\k<n>` and lookaround `(?=)(?!)(?<=)(?<!)` — the
//! .NET model: these compile and run here, not rejected).
//!
//! Backtracking is NOT ReDoS-proof by construction, so an explicit step
//! budget (scaled to the input) bounds the work: exceeding it returns
//! `error.Budget`, which `regex.zig` maps to `RegexError.MatchBudgetExceeded`
//! (a typed error, never a hang). Continuations are CPS frames threaded on
//! the call stack (no per-step allocation).

const std = @import("std");
const hir = @import("../hir.zig");
const full_dfa = @import("full_dfa.zig");
const seek_mod = @import("seek.zig");
const delegate = @import("delegate.zig");
const cc = @import("charclass.zig");

const NodeRef = hir.NodeRef;

pub const Span = struct { start: usize, end: usize };
pub const Error = error{Budget};

/// CPS frame: a tagged union so each variant carries *only* its live fields
/// (the struct-of-everything form had ~24 B of dead fields per frame and made
/// the variant invariants by-convention; the union shrinks the frame ~33%
/// — ~48 B → ~32 B on Apple Silicon — and makes them type-checked).
const Cont = union(enum) {
    accept: void,
    accept_at: usize, // required end position
    seq: struct { ref: NodeRef, next: *const Cont },
    save: struct { slot: usize, next: *const Cont },
    loop: struct {
        ref: NodeRef, // body
        next: *const Cont, // post-loop continuation
        greedy: bool,
        loop_from: usize, // pos this iteration started at
    },
};

/// The tree backtracker, generic over the HIR store. `cap == null` is the
/// runtime (heap) HIR; a concrete `cap` is a comptime fixed-size HIR baked by
/// `Pattern`. The body only touches `h.node`/`h.setBitmap`/`h.root`, which are
/// identical across both stores, so the matcher is written once and the
/// `BacktrackerG(null)` alias below keeps every runtime call site unchanged.
pub fn BacktrackerG(comptime cap: ?usize) type {
    const H = hir.Hir(cap);
    return struct {
        const Self = @This();

        h: *const H,
        a_start: bool,
        a_end: bool,
        n_groups: usize,
        /// Optional regular over-approximation prefilter (see `seek.zig`). When
        /// set, the outer scan jumps over proven-dead prefixes instead of
        /// stepping one byte at a time. `null` ⇒ plain `start += 1` scan.
        seek: ?*const seek_mod.Seek = null,
        /// Optional concat-internal regular-island delegation plan (see
        /// `exec/delegate.zig`). `null` ⇒ pure tree-walk.
        del: ?*const delegate.Plan = null,
        input: []const u8 = &.{},
        slots: [2 * (hir.MAX_GROUPS + 1)]i32 = undefined,
        match_end: usize = 0,
        steps: u64 = 0,
        budget: u64 = 0,
        /// CPS-recursion depth across `m`/`cont`/`loopStep` (each adds a native
        /// stack frame). The step `budget` bounds *total work* (anti-ReDoS) but
        /// not stack depth; this guard surfaces deep recursion as a typed
        /// `error.Budget` (→ `MatchBudgetExceeded`) instead of a stack overflow.
        depth: u32 = 0,

        // `hasBit` / `isWord` / `lookHolds` now live in `charclass.zig` (`cc`).

        /// Min/max byte width a node can match. `bounded == false` means the max
        /// is unbounded (`*`/`+`/backref) — callers cap it (e.g. at `pos` for a
        /// lookbehind). Drives the variable-width lookbehind reverse scan; the
        /// fixed-width fast path is the degenerate `min == max` case.
        const WidthBounds = struct { min: usize, max: usize, bounded: bool };
        fn widthBounds(self: *Self, ref: NodeRef) WidthBounds {
            const nd = self.h.node(ref);
            return switch (nd.tag) {
                .empty, .look, .look_around => .{ .min = 0, .max = 0, .bounded = true },
                .set => .{ .min = 1, .max = 1, .bounded = true },
                .concat => {
                    const l = self.widthBounds(nd.a);
                    const r = self.widthBounds(nd.b);
                    return .{ .min = l.min + r.min, .max = l.max + r.max, .bounded = l.bounded and r.bounded };
                },
                .alt => {
                    const l = self.widthBounds(nd.a);
                    const r = self.widthBounds(nd.b);
                    return .{ .min = @min(l.min, r.min), .max = @max(l.max, r.max), .bounded = l.bounded and r.bounded };
                },
                .opt => {
                    const c = self.widthBounds(nd.a);
                    return .{ .min = 0, .max = c.max, .bounded = c.bounded };
                },
                .cap, .atomic => self.widthBounds(nd.a),
                .star => .{ .min = 0, .max = 0, .bounded = false },
                .plus => blk: {
                    const c = self.widthBounds(nd.a);
                    break :blk .{ .min = c.min, .max = 0, .bounded = false };
                },
                .backref => .{ .min = 0, .max = 0, .bounded = false },
            };
        }

        fn tick(self: *Self) Error!void {
            self.steps += 1;
            if (self.steps > self.budget) return Error.Budget;
        }

        /// Each `m`/`cont`/`loopStep` recursion is a native stack frame; ~200 B
        /// each, typical thread stack 8 MB ⇒ ~40 K-deep before overflow. 16 K
        /// leaves comfortable headroom and is far beyond any realistic pattern
        /// (real backtrack work is bounded by `budget` long before this trips).
        const MAX_DEPTH: u32 = 16_384;
        inline fn enter(self: *Self) Error!void {
            // Check-first so a refused entry leaves `depth` unchanged — the
            // matching `defer self.depth -= 1` in the caller is only registered
            // after `try self.enter()` succeeds, keeping the counter balanced
            // across re-uses of this `Backtracker`.
            if (self.depth >= MAX_DEPTH) return Error.Budget;
            self.depth += 1;
        }

        fn m(self: *Self, ref: NodeRef, pos: usize, k: *const Cont) Error!bool {
            try self.enter();
            defer self.depth -= 1;
            try self.tick();
            const nd = self.h.node(ref);
            switch (nd.tag) {
                .empty => return self.cont(pos, k),
                .set => {
                    if (pos < self.input.len and cc.hasBit(&self.h.setBitmap(nd.set_idx), self.input[pos]))
                        return self.cont(pos + 1, k);
                    return false;
                },
                .look => {
                    if (cc.lookHolds(@intCast(nd.set_idx), self.input, pos)) return self.cont(pos, k);
                    return false;
                },
                .concat => {
                    const k2: Cont = .{ .seq = .{ .ref = nd.b, .next = k } };
                    // Regular-island delegation: if `nd.a` is a registered
                    // delegatable island, run it at DFA speed. The island is
                    // greedy/no-alt/no-cap ⇒ its unique greedy-maximal parse is
                    // both the tree-walker's *first* attempt and `full_dfa`'s
                    // leftmost-longest end, and it writes no capture slots. So
                    // continuing from that end is byte-identical to pure
                    // tree-walk; if the continuation fails we fall through to the
                    // exact original `m(nd.a,…)` recursion (full enumeration).
                    if (self.del) |pl| {
                        if (pl.dfaFor(nd.a)) |isl| {
                            if (isl.matchEnd(self.input, pos)) |e| {
                                if (try self.cont(e, &k2)) return true;
                            }
                            return self.m(nd.a, pos, &k2);
                        }
                    }
                    return self.m(nd.a, pos, &k2);
                },
                .alt => {
                    if (try self.m(nd.a, pos, k)) return true;
                    return self.m(nd.b, pos, k);
                },
                .opt => {
                    if (nd.greedy) {
                        if (try self.m(nd.a, pos, k)) return true;
                        return self.cont(pos, k);
                    }
                    if (try self.cont(pos, k)) return true;
                    return self.m(nd.a, pos, k);
                },
                .star => {
                    const lp: Cont = .{ .loop = .{ .ref = nd.a, .next = k, .greedy = nd.greedy, .loop_from = pos } };
                    return self.loopStep(pos, &lp);
                },
                .plus => {
                    const lp: Cont = .{ .loop = .{ .ref = nd.a, .next = k, .greedy = nd.greedy, .loop_from = pos } };
                    return self.m(nd.a, pos, &lp);
                },
                .cap => {
                    const g: usize = nd.set_idx;
                    if (g > hir.MAX_GROUPS) return false;
                    const sslot = 2 * g;
                    const old_s = self.slots[sslot];
                    self.slots[sslot] = @intCast(pos);
                    const kc: Cont = .{ .save = .{ .slot = sslot + 1, .next = k } };
                    if (try self.m(nd.a, pos, &kc)) return true;
                    self.slots[sslot] = old_s; // restore on backtrack
                    return false;
                },
                .backref => {
                    const g: usize = nd.set_idx;
                    const s = self.slots[2 * g];
                    const e = self.slots[2 * g + 1];
                    if (s < 0 or e < 0 or e < s) return self.cont(pos, k); // unset → empty
                    const su: usize = @intCast(s);
                    const w: usize = @as(usize, @intCast(e)) - su;
                    if (pos + w > self.input.len) return false;
                    if (!std.mem.eql(u8, self.input[pos .. pos + w], self.input[su .. su + w]))
                        return false;
                    return self.cont(pos + w, k);
                },
                // Out-of-line: its slot-snapshot buffer would otherwise enlarge
                // *every* `m` stack frame and eat into the `MAX_DEPTH` headroom.
                .atomic => return self.matchAtomic(nd.a, pos, k),
                .look_around => {
                    const behind = (nd.set_idx & hir.LA_BEHIND) != 0;
                    const neg = (nd.set_idx & hir.LA_NEGATIVE) != 0;
                    var ok: bool = false;
                    if (!behind) {
                        const acc: Cont = .accept;
                        ok = try self.m(nd.a, pos, &acc);
                    } else {
                        // Lookbehind: the sub-pattern must match a span ending
                        // exactly at `pos` (enforced by `Cont.accept_at`). Scan
                        // candidate widths shortest-first so a negative lookbehind
                        // rejects on the first violating span; a fixed-width sub
                        // collapses to a single offset (byte-identical to the old
                        // fixed-only path). Unbounded `*`/`+`/backref cap at `pos`.
                        // Each `m` step ticks the same budget ⇒ bounded, no hang.
                        const wb = self.widthBounds(nd.a);
                        const hi = if (wb.bounded) @min(wb.max, pos) else pos;
                        const lo = @min(wb.min, pos);
                        var w: usize = lo;
                        while (w <= hi) : (w += 1) {
                            const acc: Cont = .{ .accept_at = pos };
                            if (try self.m(nd.a, pos - w, &acc)) {
                                ok = true;
                                break;
                            }
                        }
                    }
                    if (ok == !neg) return self.cont(pos, k); // zero-width
                    return false;
                },
            }
        }

        fn loopStep(self: *Self, pos: usize, lp: *const Cont) Error!bool {
            try self.enter();
            defer self.depth -= 1;
            // Callers always pass a `.loop` variant (`m`'s `.star`/`.plus` and
            // `cont`'s `.loop` recursion). Destructure once for readability.
            const l = lp.loop;
            const bodyk: Cont = .{ .loop = .{ .ref = l.ref, .next = l.next, .greedy = l.greedy, .loop_from = pos } };
            if (l.greedy) {
                if (try self.m(l.ref, pos, &bodyk)) return true;
                return self.cont(pos, l.next);
            }
            if (try self.cont(pos, l.next)) return true;
            return self.m(l.ref, pos, &bodyk);
        }

        /// Atomic group `(?>body)` / possessive quantifier (`a*+` ≡ `(?>a*)`).
        /// Match `body` to its single highest-priority end and *commit*: run the
        /// continuation from that end, and if it fails, fail the whole group — the
        /// body is never retried (no backtracking back into the cut). The body's
        /// first success under `.accept` is exactly its highest-priority parse
        /// (greedy/lazy order is encoded in the node edges). Kept out of `m`'s hot
        /// switch so its slot-snapshot buffer doesn't inflate every `m` frame.
        fn matchAtomic(self: *Self, body: NodeRef, pos: usize, k: *const Cont) Error!bool {
            const live = 2 * (self.n_groups + 1);
            var snap: [2 * (hir.MAX_GROUPS + 1)]i32 = undefined;
            @memcpy(snap[0..live], self.slots[0..live]);
            const acc: Cont = .accept;
            if (try self.m(body, pos, &acc)) {
                const e = self.match_end; // body's committed end
                if (try self.cont(e, k)) return true;
            }
            // No surviving match: undo any capture slots the body wrote (the cut
            // commits captures only on overall success).
            @memcpy(self.slots[0..live], snap[0..live]);
            return false;
        }

        fn cont(self: *Self, pos: usize, k: *const Cont) Error!bool {
            try self.enter();
            defer self.depth -= 1;
            try self.tick();
            switch (k.*) {
                .accept => {
                    self.match_end = pos;
                    return true;
                },
                .accept_at => |at| return pos == at,
                .seq => |s| return self.m(s.ref, pos, s.next),
                .save => |s| {
                    const old = self.slots[s.slot];
                    self.slots[s.slot] = @intCast(pos);
                    if (try self.cont(pos, s.next)) return true;
                    self.slots[s.slot] = old;
                    return false;
                },
                .loop => |l| {
                    if (pos == l.loop_from) return self.cont(pos, l.next); // anti-empty: stop
                    return self.loopStep(pos, k);
                },
            }
        }

        pub fn init(
            h: *const H,
            a_start: bool,
            a_end: bool,
            n_groups: usize,
            seek: ?*const seek_mod.Seek,
            del: ?*const delegate.Plan,
        ) Self {
            return .{ .h = h, .a_start = a_start, .a_end = a_end, .n_groups = n_groups, .seek = seek, .del = del };
        }

        /// Leftmost (leftmost-first) match + capture slots. `slots_out`
        /// (caller-sized `2*(n_groups+1)`) gets group spans (-1 = absent).
        /// `error.Budget` on step-limit (→ `MatchBudgetExceeded`).
        pub fn run(self: *Self, input: []const u8, slots_out: []i32) Error!?Span {
            return self.runFrom(input, 0, slots_out);
        }

        /// Leftmost match at/after absolute `from`, scanning the FULL `input`
        /// (not a slice) so look-assertions (`\b`, `(?m)^ $`, `\A \z \Z`) see the
        /// true preceding/following bytes at every candidate start — a slice
        /// `input[from..]` would make `from` look like start-of-text and
        /// mis-fire `start_line`/`start_text`/`\b`. This is the absolute-coord
        /// convention the runtime `.bt_look` engine uses (`btLookLineScan`); the
        /// comptime `Pattern` look path (`pattern.zig`) calls this so its
        /// non-overlapping iteration is correct for line/word-boundary anchors.
        /// `run` is `runFrom(…, 0, …)`. Returned span is in absolute coords.
        pub fn runFrom(self: *Self, input: []const u8, from: usize, slots_out: []i32) Error!?Span {
            self.input = input;
            self.budget = 8000 + @as(u64, input.len + 1) * 4000; // O(n) work bound
            var start: usize = from;
            while (start <= input.len) : (start += 1) {
                // Seek: skip the proven-dead prefix where the regular
                // over-approximation cannot even begin a match. `locate` returns
                // the leftmost such absolute position `≥ start`; `null` ⇒ no
                // candidate anywhere ahead ⇒ no real match either.
                if (self.seek) |sd| {
                    start = sd.locate(input, start) orelse return null;
                    if (start > input.len) return null;
                }
                // Only the live slot range is ever read or written: `.cap` writes
                // `slots[2*g]`/`slots[2*g+1]` for `g ≤ n_groups`, and the success
                // copy below only takes the first `2*(n_groups+1)`. Clearing all
                // 264 B at every start position was O(n) wasted memset (e.g. for
                // `n_groups==0` 8 B suffices).
                const live = 2 * (self.n_groups + 1);
                @memset(self.slots[0..live], -1);
                self.slots[0] = @intCast(start);
                const top: Cont = if (self.a_end)
                    .{ .accept_at = input.len }
                else
                    .accept;
                if (try self.m(self.h.root, start, &top)) {
                    const end = if (self.a_end) input.len else self.match_end;
                    self.slots[1] = @intCast(end);
                    if (slots_out.len >= 2 * (self.n_groups + 1))
                        @memcpy(
                            slots_out[0 .. 2 * (self.n_groups + 1)],
                            self.slots[0 .. 2 * (self.n_groups + 1)],
                        );
                    return .{ .start = start, .end = end };
                }
                if (self.a_start) return null;
            }
            return null;
        }
    };
}

/// Runtime alias: the original non-generic `Backtracker` over the heap HIR.
/// Every existing runtime call site (`regex.zig`, `exec/dupword.zig`,
/// `exec/delegate.zig`, `exec/split_alt.zig`) uses this unchanged.
pub const Backtracker = BacktrackerG(null);
