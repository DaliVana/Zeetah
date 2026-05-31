//! Table-type-agnostic prefilter search, shared by the runtime `Dfa256`
//! executor (`exec/core.zig`) and the comptime baked `comptime_dfa.Dfa(ns,nk)` executor
//! (`pattern.zig`). Both DFA representations expose the same
//! `runFrom(input, start_pos) ?usize` primitive (the anchored leftmost-first
//! run); everything here is written *once* against that single method, so the
//! necessary-condition literal prefilters that keep unanchored search linear
//! are identical in both front-ends.
//!
//! This closes the comptime/runtime asymmetry noted in `docs/ARCHITECTURE.md`
//! ("Design decisions"): previously `required` / `req_lit` lived only on the
//! runtime `Dfa256`,
//! so a comptime `Pattern("a.*X")` ran the O(n²) per-position DFA restart on
//! adversarial input while the same pattern at runtime short-circuited on one
//! `memchr`. With this module both paths get the O(n) guarantee.

const std = @import("std");
const pf = @import("../prefilter.zig");
const seq_extract = @import("seq_extract.zig");

/// A matched span `[start, end)`. Canonical type re-exported by `exec/core.zig`
/// and `exec/comptime_dfa.zig` so the shared helpers below and both executors agree on
/// one nominal `Span` (no per-front-end conversions).
pub const Span = struct { start: usize, end: usize };

const ReqLit = seq_extract.ReqLit;

/// A byte every accepting path must consume is *absent* from the haystack ⇒
/// no match, proved in one `memchr`. This is what collapses the unanchored
/// DFA-restart O(n²) (the required tail/inner literal of `a.*…X`,
/// `.*.*=.*`, `(a|ab)*c` never appears in adversarial input). Returns `true`
/// when the search can immediately answer "no match".
pub inline fn requiredAbsent(required: ?u8, input: []const u8) bool {
    if (required) |req| return std.mem.indexOfScalar(u8, input, req) == null;
    return false;
}

/// Necessary-literal-driven leftmost search. `R` (`rl.byte`) is a rare byte
/// every match must contain; `rl.back` recovers the start from `R`'s position.
/// `R` cannot occur inside its own preceding prefix, so scanning `R`-occurrences
/// left-to-right and taking the first that verifies yields the leftmost match.
/// `d.runFrom` re-verifies, so this never changes an outcome.
///
/// `d` is any DFA exposing `runFrom(input, pos) ?usize` (the runtime `Dfa256`
/// or the comptime `comptime_dfa.Dfa(ns,nk)`).
pub fn findViaReqLit(d: anytype, input: []const u8, rl: ReqLit) ?Span {
    var lower: usize = 0;
    while (lower <= input.len) {
        const q = std.mem.indexOfScalarPos(u8, input, lower, rl.byte) orelse return null;
        var s: usize = undefined;
        switch (rl.back) {
            .fixed => |k| {
                if (q < k or q - k < lower) {
                    lower = q + 1;
                    continue;
                }
                s = q - k;
            },
            .class => |set| {
                s = q;
                while (s > lower and pf.inSet(&set, input[s - 1])) s -= 1;
            },
        }
        if (d.runFrom(input, s)) |e| return .{ .start = s, .end = e };
        lower = q + 1;
    }
    return null;
}

/// Selective-literal-prefix leftmost search (the planner's `.prefix_prefilter`
/// / `.lit_prefix`). The pattern must begin with the fixed literal carried by
/// Teddy `t`, so every Teddy occurrence is a candidate match start and
/// `d.runFrom` re-verifies anchored there — this never changes an outcome.
/// Scanning occurrences left-to-right and taking the first that verifies yields
/// the leftmost match (the prefix literal cannot precede its own match start).
/// Caller guarantees the pattern is not `^`-anchored (`runFrom` does not
/// enforce `a_start`).
pub fn litPrefixFind(d: anytype, t: *const pf.Teddy, input: []const u8) ?Span {
    var from: usize = 0;
    while (from <= input.len) {
        const hit = t.find(input, from) orelse return null;
        if (d.runFrom(input, hit.start)) |e| return .{ .start = hit.start, .end = e };
        from = hit.start + 1;
    }
    return null;
}

pub fn litPrefixIsMatch(d: anytype, t: *const pf.Teddy, input: []const u8) bool {
    return litPrefixFind(d, t, input) != null;
}
