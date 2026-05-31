//! Standalone match result types for the meta engine.
//!
//! `find`/`isMatch` return the whole match only (`slice`/`start`/`end`);
//! `groups` is the empty, non-owned slice on that path. `Regex.captures`
//! opts into submatches: it populates an allocator-owned `groups` (and
//! `groupByName`). `Match.deinit` frees the groups slice iff owned, so a
//! `defer m.deinit(allocator)` is correct for both paths.

const std = @import("std");

/// A single matched capture group (populated by `Regex.captures`).
pub const Group = struct {
    slice: []const u8,
    start: usize,
    end: usize,
    name: ?[]const u8 = null,

    pub fn len(self: Group) usize {
        return self.end - self.start;
    }
};

/// The result of a successful match. `slice` aliases the input (not owned).
/// `groups` is empty on the `find`/`isMatch` path and allocator-owned on the
/// `Regex.captures` path; `deinit` frees it iff owned.
pub const Match = struct {
    slice: []const u8,
    start: usize,
    end: usize,
    /// Submatches by group index (`groups[0]` = whole match). Empty for
    /// `find`/`isMatch` (captures are opt-in via `Regex.captures`); populated
    /// and allocator-owned when produced by the capture engine. Ownership is
    /// implicit: a non-empty `groups` is always owned — the capture path always
    /// fills at least the whole-match slot — and an empty one never is, so
    /// `deinit` keys on `groups.len` (no separate ownership flag is exposed).
    groups: []const ?Group = &.{},

    /// Look a capture up by its `(?<name>…)` name, or `null`.
    pub fn groupByName(self: *const Match, name: []const u8) ?Group {
        for (self.groups) |g| {
            if (g) |grp| {
                if (grp.name) |n| {
                    if (std.mem.eql(u8, n, name)) return grp;
                }
            }
        }
        return null;
    }

    /// Frees the groups slice iff it is allocator-owned (the capture path).
    /// A no-op for `find`/`isMatch` matches (empty `groups`), so a blanket
    /// `defer m.deinit(allocator)` is correct on every path.
    pub fn deinit(self: *Match, allocator: std.mem.Allocator) void {
        if (self.groups.len > 0) {
            allocator.free(self.groups);
            self.groups = &.{};
        }
    }
};

/// Build a capture-free whole-match result spanning `[start, end)` of `input`
/// (the `find`/`findAll`/`count` path — `groups` keeps its empty default). The
/// single constructor both front-ends (`regex.zig`, `pattern.zig`) use so the
/// span→`Match` idiom lives in one place.
pub inline fn wholeMatch(input: []const u8, start: usize, end: usize) Match {
    return .{ .slice = input[start..end], .start = start, .end = end };
}

/// Next scan position after a match spanning `[start, end)`: advance past the
/// match, but step one byte past a zero-width match so non-overlapping
/// iteration (`findAll`/`count`/iterators) cannot stall. Centralizes the
/// empty-match advance rule shared across every iteration loop.
pub inline fn advanceEmpty(start: usize, end: usize) usize {
    return if (end == start) end + 1 else end;
}
