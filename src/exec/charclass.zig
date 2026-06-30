//! Shared scalar character predicates for the backtracking tier.
//!
//! These were independently re-defined in `backtrack.zig`, `bounded_bt.zig`
//! and `dupword.zig` — in particular `lookHolds` existed twice with divergent
//! signatures, two hand-written copies of the word-boundary semantics that
//! had to stay byte-identical. One definition removes that footgun.

const std = @import("std");
const hir = @import("../hir.zig");
const common = @import("../common.zig");

/// 256-bit set membership over a `[32]u8` bitmap. Re-exported from the one
/// canonical `common.hasBit` so the backtracking tier can call `cc.hasBit`
/// without a separate copy of the bit math.
pub const hasBit = common.hasBit;

/// `\w` membership: `[A-Za-z0-9_]` (ASCII; mirrors the engine's `\b` model).
pub inline fn isWord(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

/// Zero-width assertion truth at `pos` (out-of-range neighbour ⇒ non-word /
/// no newline). Mirrors Rust `nfa::thompson::Look`. THE single definition —
/// `backtrack.zig` and `bounded_bt.zig` both route here.
pub fn lookHolds(kind: u8, input: []const u8, pos: usize) bool {
    const bw = pos > 0 and isWord(input[pos - 1]);
    const aw = pos < input.len and isWord(input[pos]);
    return switch (@as(hir.LookKind, @enumFromInt(kind))) {
        .word_boundary => bw != aw,
        .non_word_boundary => bw == aw,
        .start_text => pos == 0,
        .end_text => pos == input.len,
        .end_text_before_nl => pos == input.len or
            (pos + 1 == input.len and input[pos] == '\n'),
        .start_line => pos == 0 or input[pos - 1] == '\n',
        .end_line => pos == input.len or input[pos] == '\n',
    };
}
