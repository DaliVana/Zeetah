//! Line-anchored regular fast path for `(?m)^body$` / `(?m)^body` with a
//! regular, `\n`-free body (`properties.lineAnchoredRegular`). Instead of the
//! per-line NFA `matchAt` (the `bt_look` line scan) or the comptime tree
//! backtracker, enumerate line starts (`\n` memchr), reject non-matching lines
//! with a one-byte first-byte filter, and run ONE looks-stripped body-DFA pass
//! per line.
//!
//! Soundness: the body is `\n`-free, so a match starting at a line start never
//! crosses the line terminator. `^` is enforced structurally by only starting
//! at line starts. Three modes (`Mode`), picked from `properties.LineShape`:
//!   * `prefix` (`(?m)^body`): the forward body DFA's leftmost-first end.
//!   * `dollar` (`(?m)^body$`, no alternation/lazy): the forward DFA's longest
//!     accept is `≤` the line end, so "it lands on the line end" is exactly
//!     "the body fills the line" — `$` is an O(1) edge check.
//!   * `whole_line` (`(?m)^body$` with an alternation or lazy quantifier): the
//!     forward DFA's leftmost-first priority cut can stop at a shorter accept
//!     that misses the line end while a longer parse would reach it
//!     (`(?:a|aa)$` on "aa"). But with `^`, `$` and a `\n`-free body the only
//!     possible match on a line IS the whole line, so the question is plain
//!     membership — "is the line in L(body)?" — and priority is irrelevant.
//!     It is answered by the body's REVERSE DFA (`full_dfa.computeReverse`,
//!     which has no priority cut) walked from the line end back to its start.
//!
//! `dfa` is `anytype` so the single walker drives the runtime
//! `full_dfa.PackedDfa` and the comptime-baked compressed
//! `comptime_dfa.Dfa(ns,nk)` — all expose `start`/`accepting`/`class_of` and
//! `step(state, cls)`, with state 0 the DEAD sink (mirrors `edge_look.nextFrom`).

const std = @import("std");
const common = @import("../common.zig");
const properties = @import("../properties.zig");
const search = @import("search.zig");

pub const Span = search.Span;

/// How a line's DFA decides a match (see the module doc). `whole_line` takes
/// the body's REVERSE DFA; the other two take the forward body DFA.
pub const Mode = enum {
    prefix,
    dollar,
    whole_line,

    pub fn of(shape: properties.LineShape) Mode {
        if (shape.whole_line) return .whole_line;
        return if (shape.has_dollar) .dollar else .prefix;
    }
};

const bitsetHas = common.hasBit;

/// Longest body match starting exactly at `s` (anchored), or `null`. Byte-for-
/// byte the same as `full_dfa.Dfa256.runFrom(input, s)` with `a_end == false`.
inline fn matchEnd(dfa: anytype, input: []const u8, s: usize) ?usize {
    var state: u16 = @intCast(dfa.start);
    var best: ?usize = if (dfa.accepting[state]) s else null;
    var i: usize = s;
    while (i < input.len) : (i += 1) {
        state = dfa.step(state, dfa.class_of[input[i]]);
        if (state == 0) break; // DEAD sink
        if (dfa.accepting[state]) best = i + 1;
    }
    return best;
}

/// The ONE line-start enumeration shared by every `(?m)^…` scanner: the
/// line-DFA walker below, the NFA backtracker (`bounded_bt.findLineStart`),
/// the compiled backtracker (`compiled_bt.lineStartScan`) and the over-budget
/// PikeVM scan (`Regex.pikeLineScan`). Starting at `from` (itself iff it is a
/// line start, else the next byte after a `\n`), for every line start `s`
/// with line end `e` (the next `\n` or `input.len`): reject the line on its
/// first byte when `first` (the body's non-nullable leading-byte set) is
/// given — `s == input.len` (trailing empty line) has no byte to test, so it
/// falls through — then call `ctx.attempt(s, e)`; the first non-null hit is
/// returned. Line starts ascend, so that hit is the leftmost match.
///
/// `ctx.attempt` returns `?Span` or `E!?Span`; the scan's return type follows
/// it. Sound only when every match must begin at a line start (a pattern
/// unconditionally prefixed by a multiline `^`, `bounds.start == .line`).
pub fn scanLineStarts(input: []const u8, from: usize, first: ?*const [32]u8, ctx: anytype) @TypeOf(ctx.attempt(0, 0)) {
    if (from > input.len) return null;
    var s = from;
    // Advance to the first line start at/after `from`.
    if (!(s == 0 or input[s - 1] == '\n')) {
        const nl = std.mem.indexOfScalarPos(u8, input, s, '\n') orelse return null;
        s = nl + 1;
    }
    while (s <= input.len) {
        const e = std.mem.indexOfScalarPos(u8, input, s, '\n') orelse input.len;
        const skip = if (first) |set|
            (s < input.len and !bitsetHas(set, input[s]))
        else
            false;
        if (!skip) {
            const r = ctx.attempt(s, e);
            const hit = if (@typeInfo(@TypeOf(r)) == .error_union) try r else r;
            if (hit) |sp| return sp;
        }
        if (e == input.len) return null;
        s = e + 1;
    }
    return null;
}

/// Leftmost line match at/after absolute `from`. `dfa` is the forward body DFA
/// for `.prefix` / `.dollar`, the reverse body DFA for `.whole_line`. `first`
/// (the body's non-nullable leading-byte set, or `null`) rejects a line with
/// one byte test before the DFA pass.
pub fn nextFrom(dfa: anytype, mode: Mode, first: ?*const [32]u8, input: []const u8, from: usize) ?Span {
    const Line = struct {
        dfa: @TypeOf(dfa),
        mode: Mode,
        input: []const u8,

        pub fn attempt(self: @This(), s: usize, e: usize) ?Span {
            switch (self.mode) {
                .prefix => if (matchEnd(self.dfa, self.input, s)) |end| return .{ .start = s, .end = end },
                .dollar => if (matchEnd(self.dfa, self.input, s)) |end| {
                    if (end == e) return .{ .start = s, .end = end };
                },
                // The reverse walk from `e` reports the leftmost position it
                // can reach a forward start from; the line matches iff that
                // is `s`.
                .whole_line => if (search.reverseSearch(self.dfa, self.input, s, e)) |sp| {
                    if (sp.start == s) return .{ .start = s, .end = e };
                },
            }
            return null;
        }
    };
    return scanLineStarts(input, from, first, Line{ .dfa = dfa, .mode = mode, .input = input });
}
