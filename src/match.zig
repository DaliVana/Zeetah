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

/// **Zero-allocation capture result for the comptime `Pattern` path.**
///
/// Unlike the runtime `Regex.captures` (which heap-allocates `Match.groups`),
/// a comptime `Pattern` knows its capture-group count `ng` and `(?<name>)`
/// names at compile time, so its groups live **inline** in a fixed
/// `[ng + 1]?Group` array — no allocator, the whole value is stack/`.rodata`.
/// Every `slice` aliases the haystack. This is what lets capture extraction run
/// in a hot loop or in a no-allocator (WASM / freestanding) build.
///
/// `gnames` is the comptime `[ng + 1]?[]const u8` name table (`gnames[g]` is
/// group `g`'s `(?<name>)` name, or `null`). It is a *type parameter* so the
/// compile-time-indexed accessors below can resolve and bounds-check names at
/// compile time.
pub fn Captures(comptime ng: usize, comptime gnames: [ng + 1]?[]const u8) type {
    return struct {
        const Self = @This();

        /// `groups[0]` = whole match; `groups[g]` = group `g` or `null`
        /// (did not participate). Always fully populated (no allocation).
        groups: [ng + 1]?Group,

        /// Number of capturing groups (excludes group 0, the whole match).
        pub const group_count = ng;

        /// The whole-match slice (`groups[0]` is always present on a match).
        pub fn slice(self: *const Self) []const u8 {
            return self.groups[0].?.slice;
        }

        /// Compile-time-indexed group access — `cap.get(1)`. The index is
        /// bounds-checked **at compile time**: `get(ng + 1)` is a `@compileError`,
        /// not a runtime panic or `null`. Returns `?Group` (`null` if the group
        /// did not participate in this match). Zero-cost: folds to a single
        /// array read. (Group 0 is the whole match.)
        pub fn get(self: *const Self, comptime i: usize) ?Group {
            if (i > ng) @compileError(std.fmt.comptimePrint(
                "capture group {d} is out of range — this pattern has {d} group(s) (valid indices 0..{d})",
                .{ i, ng, ng },
            ));
            return self.groups[i];
        }

        /// Compile-time-named group access — `cap.getName("year")`. The name is
        /// resolved against the pattern's `(?<name>)` table **at compile time**:
        /// an unknown name is a `@compileError` listing the available names, not
        /// a runtime miss. Returns `?Group` (`null` if it did not participate).
        pub fn getName(self: *const Self, comptime name: []const u8) ?Group {
            const idx = comptime resolveName(name);
            return self.groups[idx];
        }

        /// Runtime-indexed group access (for a dynamic `i` not known at compile
        /// time). Out-of-range ⇒ `null` (not a panic), mirroring the runtime
        /// `Match.groups` bounds behaviour. Prefer `get` when `i` is constant.
        pub fn group(self: *const Self, i: usize) ?Group {
            if (i > ng) return null;
            return self.groups[i];
        }

        /// Runtime-named group access — the zero-alloc peer of
        /// `Match.groupByName`. Linear scan over the (tiny, comptime-known) name
        /// table. Prefer `getName` when the name is a string literal.
        pub fn groupByName(self: *const Self, name: []const u8) ?Group {
            inline for (1..ng + 1) |g| {
                if (gnames[g]) |n| {
                    if (std.mem.eql(u8, n, name)) return self.groups[g];
                }
            }
            return null;
        }

        /// Comptime name → group index, or `@compileError`. Shared by `getName`.
        fn resolveName(comptime name: []const u8) usize {
            comptime {
                for (1..ng + 1) |g| {
                    if (gnames[g]) |n| {
                        if (std.mem.eql(u8, n, name)) return g;
                    }
                }
                var avail: []const u8 = "";
                for (1..ng + 1) |g| {
                    if (gnames[g]) |n| avail = avail ++ (if (avail.len == 0) "" else ", ") ++ n;
                }
                @compileError(std.fmt.comptimePrint(
                    "no capture group named \"{s}\" in this pattern (named groups: {s})",
                    .{ name, if (avail.len == 0) "<none>" else avail },
                ));
            }
        }
    };
}

/// Next scan position after a match spanning `[start, end)`: advance past the
/// match, but step one byte past a zero-width match so non-overlapping
/// iteration (`findAll`/`count`/iterators) cannot stall. Centralizes the
/// empty-match advance rule shared across every iteration loop.
pub inline fn advanceEmpty(start: usize, end: usize) usize {
    return if (end == start) end + 1 else end;
}
