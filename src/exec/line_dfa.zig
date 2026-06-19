//! Line-anchored regular fast path for `(?m)^body$` / `(?m)^body` with a
//! regular, `\n`-free body (`properties.lineAnchoredRegular`). Instead of the
//! per-line NFA `matchAt` (the `bt_look` line scan) or the comptime tree
//! backtracker, enumerate line starts (`\n` memchr), reject non-matching lines
//! with a one-byte first-byte filter, and run ONE looks-stripped body-DFA pass
//! per line.
//!
//! Soundness: the body is `\n`-free, so a determinized DFA's longest accept
//! from a line start can never cross the line terminator — it is `≤` the line
//! end. Hence "longest accept lands on the line end" is exactly "body fills the
//! line", which makes `$` an O(1) edge check and keeps this correct even with
//! alternation (unlike `edge_look`, whose priority cut forces it to reject
//! `.alt`). `^` is enforced structurally by only starting at line starts.
//!
//! `dfa` is `anytype` so the single walker drives both the runtime
//! `full_dfa.Dfa256` and the comptime-baked compressed `comptime_dfa.Dfa(ns,nk)`
//! — both expose `start`/`accepting`/`class_of` and `step(state, cls)`, with
//! state 0 the DEAD sink (mirrors `edge_look.nextFrom`).

const std = @import("std");
const search = @import("search.zig");

pub const Span = search.Span;

inline fn bitsetHas(set: *const [32]u8, c: u8) bool {
    return (set[c >> 3] & (@as(u8, 1) << @as(u3, @intCast(c & 7)))) != 0;
}

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

/// Leftmost line match at/after absolute `from`. `has_dollar` ⇒ the body must
/// reach the line terminator (`\n`/EOF); otherwise any body end is accepted.
/// `first` (the body's non-nullable leading-byte set, or `null`) rejects a line
/// with one byte test before the DFA pass.
pub fn nextFrom(dfa: anytype, has_dollar: bool, first: ?*const [32]u8, input: []const u8, from: usize) ?Span {
    var s = from;
    // Advance to the first line start at/after `from`.
    if (!(s == 0 or (s <= input.len and s > 0 and input[s - 1] == '\n'))) {
        const nl = std.mem.indexOfScalarPos(u8, input, s, '\n') orelse return null;
        s = nl + 1;
    }
    while (s <= input.len) {
        const skip = if (first) |set|
            (s < input.len and !bitsetHas(set, input[s]))
        else
            false;
        if (!skip) {
            if (matchEnd(dfa, input, s)) |e| {
                if (!has_dollar or e == input.len or (e < input.len and input[e] == '\n'))
                    return .{ .start = s, .end = e };
            }
        }
        const nl = std.mem.indexOfScalarPos(u8, input, s, '\n') orelse return null;
        s = nl + 1;
    }
    return null;
}
