//! Parser rejection contract — malformed and invalid patterns.
//!
//! These are *permanent* boundaries (not deferred features): syntactically
//! invalid patterns plus one policy rejection (duplicate group names, like
//! Python `re`). Each must yield `error.InvalidPattern` at compile (or
//! `error.EmptyPattern` for `""`) — never a silent mis-match, never a crash,
//! never a leak (std.testing.allocator is the leak oracle). `InvalidPattern`
//! is what distinguishes "your regex is broken" from `NotImplemented`
//! ("valid regex, unsupported feature"). If a future change starts silently
//! accepting one of these, the matching test fails loudly.
//!
//! Deferred-feature rejections now live next to their positive coverage:
//! Unicode `\p` scripts/binary-props/`(?i)` and the `.unicode` flag →
//! feat_unicode.zig; lazy + end-anchor (`a*?$`) is now *supported* →
//! feat_lazy.zig. Robustness/ReDoS contracts (over-ceiling repetition,
//! oversized counts, deep nesting) → security.zig.

const std = @import("std");
const regex = @import("zeetah");
const Regex = regex.Regex;

const contract = [_]anyerror{
    error.InvalidPattern,
    error.EmptyPattern,
};

fn expectRejected(a: std.mem.Allocator, pattern: []const u8) !void {
    if (Regex.compile(a, pattern)) |r| {
        var rr = r;
        rr.deinit();
        std.debug.print("UNEXPECTEDLY COMPILED: \"{s}\"\n", .{pattern});
        return error.ExpectedRejection;
    } else |e| {
        for (contract) |x| if (e == x) return;
        std.debug.print("UNEXPECTED ERROR {s} for \"{s}\"\n", .{ @errorName(e), pattern });
        return e;
    }
}

// Capture groups and named (?<n>…)/(?P<n>…) are supported (Phase D; positive
// coverage in feat_captures.zig). A duplicate group name stays a typed
// rejection — matching Python `re`, and the engine's name→index resolution
// (groupByName / \k<name>) is first-wins, so a second slot under the same name
// would be unreachable by name anyway.
test "reject: duplicate named-group" {
    const a = std.testing.allocator;
    try expectRejected(a, "(?<a>x)(?<a>y)");
    try expectRejected(a, "(?P<dup>x)(?P<dup>y)");
}

test "reject: empty pattern" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.EmptyPattern, Regex.compile(a, ""));
}

test "reject: trailing garbage / dangling quantifier / unbalanced" {
    const a = std.testing.allocator;
    try expectRejected(a, "*abc"); // quantifier with nothing to repeat
    try expectRejected(a, "abc("); // unclosed group
    try expectRejected(a, "(?m"); // unclosed inline-flag group
    try expectRejected(a, "abc["); // unclosed class
    try expectRejected(a, "a)b"); // stray close paren
}
