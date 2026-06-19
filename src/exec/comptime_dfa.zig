//! Static, allocation-free DFA representation and executor.
//!
//! A `Dfa(n_states, n_classes)` value is produced at compile time by
//! `exec/full_dfa.zig` `compute` (subset construction + Moore-style
//! partition-refinement minimization), via the comptime entry `pattern.zig`,
//! and baked into `.rodata`. Matching is
//! then a pure table walk: O(n) in the input length with no allocation, no
//! per-call setup, and no per-byte sparse-set/epsilon work.
//!
//! State `0` is always the DEAD sink (no outgoing live transitions, never
//! accepting). The alphabet is compressed into byte *equivalence classes*: two
//! bytes share a class iff every transition in the source NFA treats them
//! identically, so the transition table is `[n_states][n_classes]` rather than
//! `[n_states][256]`.
//!
//! Semantics: leftmost-first (Perl/PCRE/RE2 thread-priority order),
//! *not* leftmost-longest. The priority cut is baked into the DFA at
//! construction time by `exec/full_dfa.zig`'s subset construction: once a
//! higher-priority NFA thread reaches the accept state, all lower-priority
//! threads in that DFA state are dropped. By the time a machine reaches this
//! file the leftmost-first boundary is therefore just "the last accepting
//! position the surviving (>= priority) lineage reaches" — which is what the
//! table walk below tracks. This comptime executor and the runtime one
//! (`exec/core.zig`) must agree; `tests/feat_api.zig` asserts
//! `Pattern`⇄`Regex.compile` equivalence.

const std = @import("std");
const pf = @import("../prefilter.zig");
const search = @import("search.zig");
const seq_extract = @import("seq_extract.zig");

/// State 0 is the DEAD sink: unreachable-as-live, never accepting.
/// Untyped so it coerces to whichever width the transition table uses
/// (`u8` when the minimized DFA fits in 256 states, else `u16`).
pub const DEAD = 0;

/// A span of the input `[start, end)` for a successful match. Canonical type
/// shared with the runtime executor via `exec/search.zig`.
pub const Span = search.Span;

pub fn Dfa(comptime n_states: usize, comptime n_classes: usize) type {
    return struct {
        const Self = @This();

        pub const NumStates = n_states;
        pub const NumClasses = n_classes;

        /// State-id storage. `MAX_DFA` (the construction ceiling) is 256, so a
        /// minimized DFA's ids always fit in `u8` in practice; the table is the
        /// hottest piece of memory in the inner loop, so halving each cell from
        /// `u16` to `u8` keeps roughly twice as much of it resident in L1/L2.
        pub const StateInt = if (n_states <= 256) u8 else u16;

        /// Physical row stride of `transitions`, the logical `n_classes` rounded
        /// **up to a power of two**. Indexing is unchanged (`[state][cls]` with
        /// `cls < n_classes <= Stride`); columns `[n_classes..Stride)` are
        /// unreachable padding because `class_of` only ever emits `0..n_classes`.
        ///
        /// Why pad: `runFrom`'s inner loop is a loop-carried *pointer chase*
        /// (`state -> addr -> load -> state`; the `class_of[input[i]]` lookup is
        /// off the critical path), so the row-base computation `state * stride`
        /// sits on the recurrence. A power-of-two stride lowers to a single
        /// `lsl` (strength-reduced); an awkward `n_classes` (11, 13, 14, 19, …)
        /// makes LLVM emit a hardware `mul`/`madd`/`umaddl` whose latency lands
        /// directly on the recurrence — measured ~+32% ns/byte on Apple
        /// M-series (asm + microbench). The runtime `Dfa256` never pays this
        /// because its stride is the constant 256 (always a power of two); this
        /// gives the comptime table the same property for a few `.rodata` bytes.
        /// See [[dfa-table-layout-finding]] / [[comptime-runtime-prefilter-parity]].
        pub const Stride = std.math.ceilPowerOfTwoAssert(usize, @max(1, n_classes));

        /// byte -> equivalence-class id in `0..n_classes`.
        class_of: [256]u8,
        /// `transitions[state][class]` -> next state (`DEAD` if none). The row
        /// is `Stride` wide (>= `n_classes`, padded to a power of two — see
        /// `Stride`); only `[0..n_classes)` per row is ever indexed.
        transitions: [n_states][Stride]StateInt,
        /// `accepting[i]` => state `i` is accepting. A flat `bool` array (not a
        /// packed bitset): the accepting check runs on *every* `runFrom` step,
        /// so a single byte load beats a bitset decode (shift+mask) per byte —
        /// matching the runtime `Dfa256.accepting` representation. The extra
        /// `.rodata` (≤ n_states bytes vs ⌈n_states/8⌉) is negligible and pays
        /// for itself on verify-heavy searches (e.g. required-literal patterns).
        accepting: [n_states]bool,
        /// Unanchored-search prefilter: the distinct input bytes that take
        /// `start` to a live (non-DEAD) state — i.e. every byte a non-empty
        /// match's first byte *could* be. `start_bytes[0..n_start_bytes]` is
        /// valid. `n_start_bytes == 0` means no byte leaves `start` live, so a
        /// non-empty match is impossible (empty matches are handled by the
        /// start-accepting check). A spread set (`> 8`) disables the skip — the
        /// cost of locating a viable byte then ≈ the cost of just matching.
        start_bytes: [256]u8,
        n_start_bytes: usize,
        /// Same membership as `start_bytes[0..n_start_bytes]`, as a 256-bit
        /// set, so the start-skip can use the fully vectorized
        /// `prefilter.nextCandidatePF` (single / multi / range / bitset SIMD)
        /// instead of the limited scalar `std.mem` path — in particular it
        /// removes the old ">8 distinct bytes => no skip" cliff and adds
        /// vectorized range scanning for class-led starts (`[0-9]`, `\w`, …).
        start_byte_set: [32]u8,
        /// `start_byte_set` classified once at comptime, so the start-skip
        /// pays only the vector scan per call — not a 256-bit re-`fromBitset`
        /// on every match (which `nextCandidate` would do).
        start_pf: pf.Prefilter,
        /// Start state (post-minimization renumbering).
        start: u16,
        /// Pattern is anchored at input start (`^` / `\A`): a match may only
        /// begin at position 0, so `findLeftmost` does not slide the start.
        anchored_start: bool,
        /// Pattern is anchored at input end (`$` / `\z` / `\Z`): an accepting
        /// prefix only counts if it reaches `input.len`.
        anchored_end: bool,
        /// Necessary-condition prefilters, baked from the same `seq_extract`
        /// analysis the runtime `Dfa256` uses (see `exec/search.zig`):
        /// `required` is a byte every accepting path must consume (absent ⇒ no
        /// match in one `memchr`); `req_lit` is a rare mandatory literal with a
        /// start-recovery recipe. These keep the comptime `Pattern`'s unanchored
        /// search **linear** (no O(n²) per-position restart) — parity with the
        /// runtime `Regex`. `null` ⇒ that prefilter does not apply.
        required: ?u8 = null,
        req_lit: ?seq_extract.ReqLit = null,

        pub inline fn isAccepting(self: *const Self, s: u16) bool {
            return self.accepting[s];
        }

        /// Next state from `state` on byte-class `cls`. Mirrors
        /// `full_dfa.Dfa256.step` (whose table field is `trans`) so generic
        /// walkers — e.g. `edge_look.nextFrom` — drive either representation
        /// uniformly. Widens the (possibly `u8`) cell to `u16`.
        pub inline fn step(self: *const Self, state: u16, cls: u8) u16 {
            return self.transitions[state][cls];
        }

        /// Anchored run from `start_pos`: walk the table consuming input until
        /// the DEAD state or end of input, tracking the last accepting
        /// position reached. Because the lower-priority threads were already
        /// dropped at construction time (see the file header), that position
        /// is the leftmost-first match end for the surviving lineage. Returns
        /// its end index, or null.
        ///
        /// With `anchored_end`, only an accepting prefix that consumes through
        /// `input.len` qualifies.
        // `inline`: this is the innermost loop body driven by `findLeftmost`
        // and the shared `search.findViaReqLit`/`litPrefixFind` (which can call
        // it tens of thousands of times — once per required-literal candidate).
        // The runtime `Dfa256.runFrom` is `inline` for the same reason; keeping
        // both inline avoids a comptime/runtime asymmetry where the verify call
        // is inlined on one front-end but not the other.
        pub inline fn runFrom(self: *const Self, input: []const u8, start_pos: usize) ?usize {
            var state: u16 = self.start;
            var last_accept: ?usize = if (self.isAccepting(state)) start_pos else null;
            var i: usize = start_pos;
            while (i < input.len) : (i += 1) {
                const cls = self.class_of[input[i]];
                state = self.transitions[state][cls];
                if (state == DEAD) break;
                if (self.isAccepting(state)) last_accept = i + 1;
            }
            if (self.anchored_end) {
                if (last_accept) |e| {
                    if (e == input.len) return e;
                }
                return null;
            }
            return last_accept;
        }

        /// Next position `>= from` whose byte can leave `start` live, or
        /// `null` if no non-empty match can begin at/after `from`.
        ///
        /// Hybrid dispatch (measured): the single-byte (`memchr`) and ≤8-byte
        /// (`indexOfAnyPos`) paths were already optimal and inlining-friendly
        /// — calling through the generic prefilter regressed them (extra
        /// call + union-by-value + per-call vector setup), so they are kept
        /// verbatim. Only the spread case (`> 8` distinct bytes), where the
        /// old code did *no* skip at all, now uses the comptime-classified
        /// SIMD prefilter (`.ranges`/`.bitset`), guarded by a one-byte
        /// membership check so dense-match patterns (e.g. `\w+`, `[0-9]+`)
        /// don't pay vector setup per call when `from` is already a member.
        ///
        /// Only sound to call when `start` is *not* accepting: a non-empty
        /// match's first consumed byte must take a live transition out of
        /// `start`, so skipping bytes that don't cannot skip a real match.
        inline fn skipToStart(self: *const Self, input: []const u8, from: usize) ?usize {
            const n = self.n_start_bytes;
            if (n == 0) return null; // no live exit from start => no match
            if (n == 1) return std.mem.indexOfScalarPos(u8, input, from, self.start_bytes[0]);
            if (n <= 8) return std.mem.indexOfAnyPos(u8, input, from, self.start_bytes[0..n]);
            // Spread set (`> 8`): out-of-line so the hot single-byte / ≤8-byte
            // returns above stay a tiny inlined body (keeping `findLeftmost`'s
            // codegen tight); the old code did no skip at all here.
            return self.skipSpread(input, from);
        }

        /// Spread-set (`> 8` distinct start bytes) skip: comptime-classified
        /// SIMD prefilter, guarded by a bounded scalar probe so dense matches
        /// / small token separators (`\w+`, `[0-9]+` over space-delimited
        /// text) don't pay per-call vector setup for a ≤few-byte gap.
        fn skipSpread(self: *const Self, input: []const u8, from: usize) ?usize {
            if (from >= input.len) return null;
            const probe_end = @min(from + 16, input.len);
            var i = from;
            while (i < probe_end) : (i += 1) {
                if (pf.inSet(&self.start_byte_set, input[i])) return i;
            }
            if (i >= input.len) return null;
            return pf.nextCandidatePF(self.start_pf, &self.start_byte_set, input, i);
        }

        /// Leftmost match: try start positions left-to-right (a single
        /// position when `anchored_start`). Returns the first `{start,end}`.
        /// Boundaries are leftmost-first (the construction-time priority cut).
        /// When unanchored and `start` is non-accepting, dead leading regions
        /// are vector-skipped via the `start_bytes` prefilter.
        pub fn findLeftmost(self: *const Self, input: []const u8) ?Span {
            // Necessary-condition prefilters (shared with the runtime
            // `core.findLeftmost` via `exec/search.zig`): a mandatory byte
            // absent ⇒ no match in one `memchr`; a rare mandatory literal
            // drives `memchr`-to-candidate instead of a per-position restart.
            // This is what gives the comptime path the same O(n) guarantee as
            // the runtime on `a.*X`-style adversarial input.
            if (search.requiredAbsent(self.required, input)) return null;
            if (self.anchored_start) {
                if (self.runFrom(input, 0)) |e| return .{ .start = 0, .end = e };
                return null;
            }
            if (self.req_lit) |rl| return search.findViaReqLit(self, input, rl);
            const can_skip = !self.isAccepting(self.start);
            var sp: usize = 0;
            while (sp <= input.len) : (sp += 1) {
                if (can_skip) sp = self.skipToStart(input, sp) orelse return null;
                if (self.runFrom(input, sp)) |e| return .{ .start = sp, .end = e };
            }
            return null;
        }

        /// Does *some* accepting state become reachable from `start_pos`?
        /// Unlike `runFrom`, this returns at the first accept (no need to
        /// find the longest end), so `isMatch` is a true early-out.
        inline fn acceptsFrom(self: *const Self, input: []const u8, start_pos: usize) bool {
            var state: u16 = self.start;
            if (self.isAccepting(state)) return true;
            var i: usize = start_pos;
            while (i < input.len) : (i += 1) {
                state = self.transitions[state][self.class_of[input[i]]];
                if (state == DEAD) return false;
                if (self.isAccepting(state)) return true;
            }
            return false;
        }

        pub fn isMatch(self: *const Self, input: []const u8) bool {
            if (search.requiredAbsent(self.required, input)) return false;
            // `anchored_end` needs the accepting prefix to reach `input.len`,
            // which only `runFrom` tracks — defer to the full leftmost walk.
            if (self.anchored_end) return self.findLeftmost(input) != null;
            // Empty match (start accepts) succeeds anywhere when the end is
            // not pinned.
            if (self.isAccepting(self.start)) return true;
            if (self.anchored_start) return self.acceptsFrom(input, 0);
            if (self.req_lit) |rl| return search.findViaReqLit(self, input, rl) != null;
            var sp: usize = 0;
            while (sp <= input.len) : (sp += 1) {
                sp = self.skipToStart(input, sp) orelse return false;
                if (self.acceptsFrom(input, sp)) return true;
            }
            return false;
        }
    };
}

// --- Inline tests: hand-built DFAs, no comptime front end involved. ---------

test "Dfa: literal-ish two-class machine" {
    // Class 0 = byte 'a', class 1 = everything else.
    // States: 0 DEAD, 1 start, 2 accept. 1 --'a'--> 2, 2 --'a'--> 2.
    const D = Dfa(3, 2);
    var class_of = [_]u8{1} ** 256;
    class_of['a'] = 0;
    const d = D{
        .class_of = class_of,
        .transitions = .{
            .{ DEAD, DEAD }, // 0 DEAD
            .{ 2, DEAD }, // 1: 'a'->2, other->DEAD
            .{ 2, DEAD }, // 2: 'a'->2, other->DEAD
        },
        .accepting = blk: {
            var a = [_]bool{false} ** 3;
            a[2] = true; // state 2 accepting
            break :blk a;
        },
        .start_bytes = blk: {
            var s = [_]u8{0} ** 256;
            s[0] = 'a'; // only 'a' leaves start live
            break :blk s;
        },
        .n_start_bytes = 1,
        .start_byte_set = blk: {
            var s = [_]u8{0} ** 32;
            s['a' >> 3] |= 1 << ('a' & 7);
            break :blk s;
        },
        .start_pf = .{ .single = 'a' },
        .start = 1,
        .anchored_start = false,
        .anchored_end = false,
    };

    try std.testing.expect(d.isMatch("a"));
    try std.testing.expect(d.isMatch("aaa"));
    try std.testing.expect(d.isMatch("xxaaa")); // leftmost slide finds run
    try std.testing.expect(!d.isMatch("xyz"));
    try std.testing.expect(!d.isMatch(""));

    const m = d.findLeftmost("xxaaab").?;
    try std.testing.expectEqual(@as(usize, 2), m.start);
    try std.testing.expectEqual(@as(usize, 5), m.end); // longest run of 'a'
}

test "Dfa: anchored_start does not slide" {
    const D = Dfa(3, 2);
    var class_of = [_]u8{1} ** 256;
    class_of['a'] = 0;
    const d = D{
        .class_of = class_of,
        .transitions = .{ .{ DEAD, DEAD }, .{ 2, DEAD }, .{ 2, DEAD } },
        .accepting = blk: {
            var a = [_]bool{false} ** 3;
            a[2] = true;
            break :blk a;
        },
        .start_bytes = blk: {
            var s = [_]u8{0} ** 256;
            s[0] = 'a';
            break :blk s;
        },
        .n_start_bytes = 1,
        .start_byte_set = blk: {
            var s = [_]u8{0} ** 32;
            s['a' >> 3] |= 1 << ('a' & 7);
            break :blk s;
        },
        .start_pf = .{ .single = 'a' },
        .start = 1,
        .anchored_start = true,
        .anchored_end = false,
    };
    try std.testing.expect(d.isMatch("aaa"));
    try std.testing.expect(!d.isMatch("xaaa")); // cannot slide past x
}

test "Dfa: anchored_end requires consuming to input end" {
    const D = Dfa(3, 2);
    var class_of = [_]u8{1} ** 256;
    class_of['a'] = 0;
    const d = D{
        .class_of = class_of,
        .transitions = .{ .{ DEAD, DEAD }, .{ 2, DEAD }, .{ 2, DEAD } },
        .accepting = blk: {
            var a = [_]bool{false} ** 3;
            a[2] = true;
            break :blk a;
        },
        .start_bytes = blk: {
            var s = [_]u8{0} ** 256;
            s[0] = 'a';
            break :blk s;
        },
        .n_start_bytes = 1,
        .start_byte_set = blk: {
            var s = [_]u8{0} ** 32;
            s['a' >> 3] |= 1 << ('a' & 7);
            break :blk s;
        },
        .start_pf = .{ .single = 'a' },
        .start = 1,
        .anchored_start = false,
        .anchored_end = true,
    };
    try std.testing.expect(d.isMatch("aaa"));
    try std.testing.expect(d.isMatch("xxaaa")); // slide start, run to end
    try std.testing.expect(!d.isMatch("aaab")); // accepting prefix not at end
}
