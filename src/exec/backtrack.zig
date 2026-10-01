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
const class_span = @import("class_span.zig");
const search = @import("search.zig");

const NodeRef = hir.NodeRef;

pub const Span = search.Span;
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
    },
};

/// A loop state this path visited at `pos`, linked newest-first through the
/// native stack frames that visited it. Positions never decrease along a path,
/// so the visits at the current position are the list's leading run.
pub const Seen = struct { key: u32, pos: usize, prev: ?*const Seen };

/// Did this path already visit loop state `key` at `pos`? Shared with the
/// compiled backtracker (`compiled_bt.zig`), which must apply the identical rule.
pub fn seenIn(list: ?*const Seen, key: u32, pos: usize) bool {
    var it = list;
    while (it) |s| : (it = s.prev) {
        if (s.pos != pos) return false;
        if (s.key == key) return true;
    }
    return false;
}

// The loop states of a `*` / `+` (keyed by its body), mirroring the Thompson
// construction the NFA engines run (`thompson.lower`): a `*`'s entry split
// (enter or skip), the body's start, and the loop-back split after each
// iteration (loop to the body's start, or exit) — three distinct states.
comptime {
    std.debug.assert(hir.MAX_NODES_RUNTIME * 4 < std.math.maxInt(u32)); // keys can't overflow
}
pub fn entryKey(body: NodeRef) u32 {
    return body * 4;
}
pub fn bodyKey(body: NodeRef) u32 {
    return body * 4 + 1;
}
pub fn loopKey(body: NodeRef) u32 {
    return body * 4 + 2;
}

/// Anti-ReDoS step budget, scaled to the input length: `runFrom` sets
/// `budget = BUDGET_BASE + (input.len + 1) * BUDGET_PER_BYTE`. A "step"
/// is one `tick()` — charged once per matcher primitive (`m`/`cont`
/// recursion, loop iteration, look-assertion entry). The linear-in-`n`
/// term is the load-bearing lever: it caps *total* backtracking work at
/// O(n), so adversarial inputs (`(a+)\1$`, nested quantifiers) return
/// `error.Budget` in O(n) instead of hanging, while the constant base
/// covers fixed start-up work that must succeed on tiny inputs. The
/// multipliers are tuned to admit every legitimate pattern in the test
/// corpus with headroom; raising them widens the ReDoS exposure window.
/// Shared with `compiled_bt.zig` (which ticks at fewer, coarser points, so
/// the same budget admits at least as much real work there).
pub const BUDGET_BASE: u64 = 8000;
pub const BUDGET_PER_BYTE: u64 = 4000;

/// Frame sizes vary (Debug frames are several times larger, and
/// `greedySetRun` / `matchAtomic` frames are not counted), so the stack
/// actually used is bounded too: ¾ of the 16 MiB a Zig thread gets by
/// default (`std.Thread`'s `default_stack_size`, and the main thread of
/// a Zig executable), above what `MAX_DEPTH` uses in a release build.
/// A caller on a smaller stack (an 8 MB C main thread, a 512 KB macOS
/// pthread) should run deep backtracking on a 16 MiB thread.
pub const MAX_STACK_BYTES: usize = 12 << 20;
/// Checked every `STACK_CHECK_EVERY` depths (one predictable branch
/// per entry); a power of two dividing `MAX_DEPTH`.
pub const STACK_CHECK_EVERY: u32 = 64;

/// The tree backtracker, generic over the HIR store. `cap == null` is the
/// runtime (heap) HIR — the runtime `Regex`'s engine. A concrete `cap` is a
/// comptime fixed-size HIR: the comptime `Pattern` no longer runs this (it
/// compiles its HIR, `compiled_bt.zig`), but `compiled_bt`'s tests use it as
/// the oracle over the very same HIR. The body only touches
/// `h.node`/`h.setBitmap`/`h.root`, which are identical across both stores.
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
        /// Loop states visited on the current path at its current position
        /// (see `seenAt`). Saved/restored around each visit, like capture slots.
        seen: ?*const Seen = null,
        input: []const u8 = &.{},
        slots: [2 * (hir.MAX_GROUPS + 1)]hir.Slot = undefined,
        match_end: usize = 0,
        steps: u64 = 0,
        budget: u64 = 0,
        /// CPS-recursion depth across `m`/`cont`/`loopSplit`/`lookAroundMatches`
        /// (each adds a native stack frame). The step `budget` bounds *total
        /// work* (anti-ReDoS) but not stack depth; this guard surfaces deep
        /// recursion as a typed `error.Budget` (→ `MatchBudgetExceeded`)
        /// instead of a stack overflow.
        depth: u32 = 0,
        /// Frame address at depth 0 — the base `checkStack` measures from.
        stack_base: usize = 0,

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

        /// Each counted recursion is a native stack frame — ~530 B each in a
        /// ReleaseFast build (a `(?:ab)*` loop measured 6.3 MB at depth 11.9 K),
        /// so 16 K-deep needs ~9 MB. 16 K is far beyond any realistic pattern
        /// (real backtrack work is bounded by `budget` long before this trips).
        const MAX_DEPTH: u32 = 16_384;
        comptime {
            std.debug.assert(MAX_DEPTH % STACK_CHECK_EVERY == 0);
        }
        inline fn enter(self: *Self) Error!void {
            // Check-first so a refused entry leaves `depth` unchanged — the
            // matching `defer self.depth -= 1` in the caller is only registered
            // after `try self.enter()` succeeds, keeping the counter balanced
            // across re-uses of this `Backtracker`.
            if (self.depth % STACK_CHECK_EVERY == 0) {
                // Cold, out of line: inlined into every `m`/`cont` frame it
                // cost the tokenizer bench ~3% (measured).
                @branchHint(.unlikely);
                try self.checkStack();
            }
            self.depth += 1;
        }

        /// Refuse past `MAX_DEPTH`, or past `MAX_STACK_BYTES` of stack below
        /// the frame that entered at depth 0 (which records it). Not at
        /// comptime, which has no frame addresses.
        noinline fn checkStack(self: *Self) Error!void {
            if (self.depth >= MAX_DEPTH) return Error.Budget;
            if (@inComptime()) return;
            const here = @frameAddress();
            if (self.depth == 0) {
                self.stack_base = here;
                return;
            }
            const used = if (self.stack_base >= here) self.stack_base - here else here - self.stack_base;
            if (used > MAX_STACK_BYTES) return Error.Budget;
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
                            if (isl.runFrom(self.input, pos)) |e| {
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
                    // SIMD fast path: greedy repetition of a single byte class.
                    if (nd.greedy and self.h.node(nd.a).tag == .set)
                        return self.greedySetRun(nd.a, pos, k, 0);
                    const lp: Cont = .{ .loop = .{ .ref = nd.a, .next = k, .greedy = nd.greedy } };
                    return self.loopSplit(pos, &lp, entryKey(nd.a));
                },
                .plus => {
                    if (nd.greedy and self.h.node(nd.a).tag == .set)
                        return self.greedySetRun(nd.a, pos, k, 1);
                    // `x+` ≡ `x x*`: the first iteration enters the body directly.
                    const lp: Cont = .{ .loop = .{ .ref = nd.a, .next = k, .greedy = nd.greedy } };
                    return self.enterBody(nd.a, pos, &lp);
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
                    if (g > hir.MAX_GROUPS) return false; // same guard as `.cap`
                    const s = self.slots[2 * g];
                    const e = self.slots[2 * g + 1];
                    if (s < 0 or e < 0 or e < s) return self.cont(pos, k); // unset → empty
                    const su: usize = @intCast(s);
                    const w: usize = @as(usize, @intCast(e)) - su;
                    if (pos + w > self.input.len) return false;
                    const a = self.input[pos .. pos + w];
                    const b = self.input[su .. su + w];
                    // `(?i)` backref: the group's text in any (ASCII) case, the
                    // same folding `(?i)` applies to literals and classes.
                    const same = if (nd.fold) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
                    if (!same) return false;
                    return self.cont(pos + w, k);
                },
                // Out-of-line: its slot-snapshot buffer would otherwise enlarge
                // *every* `m` stack frame and eat into the `MAX_DEPTH` headroom.
                .atomic => return self.matchAtomic(nd.a, pos, k),
                .look_around => {
                    const neg = (nd.set_idx & hir.LA_NEGATIVE) != 0;
                    if (try self.lookAroundMatches(nd, pos) == !neg) return self.cont(pos, k); // zero-width
                    return false;
                },
            }
        }

        /// Does a lookaround's sub-pattern match at `pos` (ahead: starting there;
        /// behind: ending there)? An independent sub-match, so it starts with an
        /// empty `seen` list — its ε-cycles are its own.
        fn lookAroundMatches(self: *Self, nd: hir.HNode, pos: usize) Error!bool {
            try self.enter();
            defer self.depth -= 1;
            const saved = self.seen;
            self.seen = null;
            defer self.seen = saved;
            const behind = (nd.set_idx & hir.LA_BEHIND) != 0;
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
            return ok;
        }

        /// SIMD fast path for a **greedy** repetition whose body is a single
        /// byte class (`[a-z]+`, `.*`, `\w*`, the `.*` inside `(?=.*X)`, …).
        /// Instead of one recursive `m`/`cont`/`loopSplit` frame per byte (a
        /// scalar `hasBit` each), consume the maximal class run with one
        /// vectorized scan (`class_span.Ranges.runEnd`, NEON `cmhs`+`uminv`),
        /// then backtrack by trying the post-loop continuation at decreasing
        /// end positions — byte-identical to the recursive greedy order
        /// (longest first, giving back one byte at a time down to the minimum)
        /// but O(1) stack depth and full-rate run consumption. `min` is 0 for
        /// `*`, 1 for `+`. Classes needing >16 ranges (`fromBitmap` ⇒ null)
        /// fall back to the exact recursive loop. Caller guarantees
        /// `greedy and body.tag == .set`.
        fn greedySetRun(self: *Self, body: NodeRef, pos: usize, k: *const Cont, min: usize) Error!bool {
            const bm = self.h.setBitmap(self.h.node(body).set_idx);
            const r = class_span.Ranges.fromBitmap(bm) orelse {
                // Rare wide class: preserve the exact recursive semantics.
                const lp: Cont = .{ .loop = .{ .ref = body, .next = k, .greedy = true } };
                return if (min == 0) self.loopSplit(pos, &lp, entryKey(body)) else self.enterBody(body, pos, &lp);
            };
            // Entry visit: a `*` enters at its entry split, a `+` at its body.
            if (self.seenAt(if (min == 0) entryKey(body) else bodyKey(body), pos)) return false;
            const e = r.runEnd(self.input, pos); // SIMD: maximal greedy extent
            if (e - pos < min) return false; // `+` needs ≥1 member
            // Greedy give-back: try the continuation at e, e-1, …, pos+min. The
            // path leaves the loop at `p` through a split — the entry split for
            // a `*` taking zero iterations, else the loop-back split — its only
            // loop-state visit at `p`.
            const saved = self.seen;
            defer self.seen = saved;
            var p = e;
            while (true) : (p -= 1) {
                try self.tick();
                const here: Seen = .{ .key = if (p == pos) entryKey(body) else loopKey(body), .pos = p, .prev = saved };
                self.seen = &here;
                if (try self.cont(p, k)) return true;
                if (p == pos + min) break;
            }
            return false;
        }

        /// A visit of one of a loop's splits at `pos` — a `*`'s entry split
        /// (`entryKey`) or the loop-back split after an iteration (`loopKey`):
        /// iterate again or exit, in greedy / lazy order.
        fn loopSplit(self: *Self, pos: usize, lp: *const Cont, key: u32) Error!bool {
            try self.enter();
            defer self.depth -= 1;
            // Callers always pass a `.loop` variant (`m`'s `.star` and `cont`'s
            // `.loop` recursion). Destructure once for readability.
            const l = lp.loop;
            if (self.seenAt(key, pos)) return false;
            const here: Seen = .{ .key = key, .pos = pos, .prev = self.seen };
            const saved = self.seen;
            self.seen = &here;
            defer self.seen = saved;
            if (l.greedy) {
                if (try self.enterBody(l.ref, pos, lp)) return true;
                return self.cont(pos, l.next);
            }
            if (try self.cont(pos, l.next)) return true;
            return self.enterBody(l.ref, pos, lp);
        }

        /// Enter a loop's body at `pos` (from its split, or directly for a `+`'s
        /// first iteration); `lp` is the loop continuation it returns to.
        /// `inline`: it sits on the native stack under every loop iteration's
        /// continuation, so as a call it would add an uncounted frame per
        /// iteration (and cut the iterations `MAX_DEPTH` / `MAX_STACK_BYTES`
        /// admit).
        inline fn enterBody(self: *Self, body: NodeRef, pos: usize, lp: *const Cont) Error!bool {
            if (self.seenAt(bodyKey(body), pos)) return false;
            const here: Seen = .{ .key = bodyKey(body), .pos = pos, .prev = self.seen };
            const saved = self.seen;
            self.seen = &here;
            defer self.seen = saved;
            return self.m(body, pos, lp);
        }

        /// Did this path already visit loop state `key` at `pos`? That revisit
        /// closes an ε-cycle (an iteration that consumed nothing, or an outer
        /// loop re-entering an inner loop that just looped back here). The NFA
        /// engines enter each state once per position's ε-closure (RE2 / Rust
        /// semantics), so the path is dead — its span and captures never
        /// surface. PCRE instead lets one empty iteration through and keeps its
        /// captures; the DFA tier can't model that, so every tier uses this rule.
        fn seenAt(self: *const Self, key: u32, pos: usize) bool {
            return seenIn(self.seen, key, pos);
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
            var snap: [2 * (hir.MAX_GROUPS + 1)]hir.Slot = undefined;
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
                // An iteration ended: the loop-back split (an empty iteration
                // dies at the body's start: see `seenAt`).
                .loop => |l| return self.loopSplit(pos, k, loopKey(l.ref)),
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
        pub fn run(self: *Self, input: []const u8, slots_out: []hir.Slot) Error!?Span {
            return self.runFrom(input, 0, slots_out);
        }

        /// Leftmost match at/after absolute `from`, scanning the FULL `input`
        /// (not a slice) so look-assertions (`\b`, `(?m)^ $`, `\A \z \Z`) see the
        /// true preceding/following bytes at every candidate start — a slice
        /// `input[from..]` would make `from` look like start-of-text and
        /// mis-fire `start_line`/`start_text`/`\b`. This is the absolute-coord
        /// convention the runtime `.bt_look` engine uses (`btLookLineScan`), so
        /// non-overlapping iteration is correct for line/word-boundary anchors.
        /// `run` is `runFrom(…, 0, …)`. Returned span is in absolute coords.
        pub fn runFrom(self: *Self, input: []const u8, from: usize, slots_out: []hir.Slot) Error!?Span {
            self.input = input;
            self.budget = BUDGET_BASE + @as(u64, input.len + 1) * BUDGET_PER_BYTE; // O(n) work bound
            // `$`-anchored fast-negative: one O(n) reverse pass over the regular
            // over-approximation. If no suffix of it ends at `input.len`, no real
            // `$`-anchored backref/lookaround match exists (`L(true) ⊆ L(approx)`)
            // — return null here instead of burning the whole step budget on the
            // tree walk (`(a+)\1$` on adversarial input: seconds → O(n)).
            if (self.seek) |sd| {
                if (sd.rejectsAnchoredEnd(input, from)) return null;
            }
            var start: usize = from;
            while (start <= input.len) : (start += 1) {
                // Seek: skip the proven-dead prefix where the regular
                // over-approximation cannot even begin a match. `locate` returns
                // the leftmost such absolute position `≥ start`; `null` ⇒ no
                // candidate anywhere ahead ⇒ no real match either.
                if (self.seek) |sd| {
                    const next = sd.locate(input, start) orelse return null;
                    // A folded `^`/`\A` allows `from` only: a later candidate is
                    // no candidate (`^(?<=b)` must not match after a `b`).
                    if (self.a_start and next != start) return null;
                    start = next;
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
