//! Internal facade — NOT part of the public package API.
//!
//! After the Phase-6 cutover the engine is the unified meta pipeline only
//! (`parser → hir → thompson → exec/* + planner`). The old AST/Pike-VM/
//! backtracker pipeline and its tooling were removed. This re-exports the
//! surviving surface for the project's own tests/benchmarks/tools under the
//! import name `regex`; the published package points at `src/root.zig`.

const std = @import("std");

// Public API (mirrors root.zig)
pub const Regex = @import("regex.zig").Regex;
pub const CompileFlags = @import("common.zig").CompileFlags;
pub const Match = @import("match.zig").Match;
pub const Group = @import("match.zig").Group;
pub const MatchIterator = @import("regex.zig").Regex.MatchIterator;
pub const CapturesIterator = @import("regex.zig").Regex.CapturesIterator;
pub const RegexError = @import("errors.zig").RegexError;
pub const Builder = @import("builder.zig").Builder;
pub const Patterns = @import("builder.zig").Patterns;
pub const Composer = @import("builder.zig").Composer;

// Thread safety (templated on the meta `Regex`)
pub const thread_safety = @import("thread_safety.zig");
pub const SharedRegex = @import("thread_safety.zig").SharedRegex(Regex);
pub const RegexCache = @import("thread_safety.zig").RegexCache(Regex);

// Internal shared modules
pub const common = @import("common.zig");
pub const prefilter = @import("prefilter.zig");
pub const comptime_dfa = @import("exec/comptime_dfa.zig");

// Unified meta-engine pipeline
pub const hir = @import("hir.zig");
pub const parser = @import("parser.zig");
pub const thompson = @import("thompson.zig");
pub const full_dfa = @import("exec/full_dfa.zig");
pub const dfa_build = @import("exec/dfa_build.zig");
pub const Pattern = @import("pattern.zig").Pattern;
pub const PatternOptions = @import("pattern.zig").Options;
pub const compilesAtComptime = @import("pattern.zig").compilesAtComptime;

pub const properties = @import("properties.zig");
pub const Properties = @import("properties.zig").Properties;
pub const seq_extract = @import("exec/seq_extract.zig");
pub const Seq = @import("exec/seq_extract.zig").Seq;

pub const planner = @import("planner.zig");
pub const Strategy = @import("planner.zig").Strategy;
pub const core = @import("exec/core.zig");

pub const cache = @import("cache.zig");
pub const Cache = @import("cache.zig").Cache;
pub const Pool = @import("cache.zig").Pool;
pub const lazy_dfa = @import("exec/lazy_dfa.zig");
pub const bounded_bt = @import("exec/bounded_bt.zig");
pub const onepass = @import("exec/onepass.zig");

// Single source of truth: the public `version` in root.zig (kept in lockstep
// with build.zig.zon by tests/version_sync.zig).
pub const version = @import("root.zig").version;

test {
    std.testing.refAllDecls(@This());
}
