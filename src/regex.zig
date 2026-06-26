//! Runtime regex — the meta engine.
//!
//! Built on the unified front-end `parser → hir → thompson → exec/*`.
//! `compileWithFlags` picks one of eleven engines (`MetaKind`): the regular
//! tier is `planner.plan`-driven (`literal`/`lit_prefix`/`reverse_suffix`/
//! `dfa`, with `lazy_dfa` for DFA-explosion, `dense_search` for the
//! frozen-dense unanchored single pass, `class_span` for trivial `class+`,
//! and `boundary_lits` for `\b(?:lit|lit|…)\b` keyword alternations);
//! captures resolve via a one-pass fast path or `exec/bounded_bt.zig`; the
//! non-regular tier (lookaround / backref) runs on `exec/backtrack.zig`
//! (whole-pattern `backtrack`, per-segment `split_alt`, or `bt_look` for
//! plain assertions) under a step budget that surfaces as
//! `RegexError.MatchBudgetExceeded`. Still-unmodelled surface
//! (Unicode `\b`, POSIX classes, `(?m)`/`(?s)` interactions) is reported as
//! `RegexError.NotImplemented` rather than silently mis-handled.

const std = @import("std");
const common = @import("common.zig");
const RegexError = @import("errors.zig").RegexError;

const hir = @import("hir.zig");
const parser = @import("parser.zig");
const thompson = @import("thompson.zig");
const full_dfa = @import("exec/full_dfa.zig");
const core = @import("exec/core.zig");
const cc = @import("exec/charclass.zig");
const line_dfa_mod = @import("exec/line_dfa.zig");
const planner = @import("planner.zig");
const properties = @import("properties.zig");
const prefilter = @import("prefilter.zig");
const seq_extract = @import("exec/seq_extract.zig");
const bounded_bt = @import("exec/bounded_bt.zig");
const backtrack = @import("exec/backtrack.zig");
const seek_mod = @import("exec/seek.zig");
const split_alt = @import("exec/split_alt.zig");
const edge_look = @import("exec/edge_look.zig");
const delegate = @import("exec/delegate.zig");
const dupword = @import("exec/dupword.zig");
const lazy_dfa = @import("exec/lazy_dfa.zig");
const class_span = @import("exec/class_span.zig");
const onepass = @import("exec/onepass.zig");
const cache_mod = @import("cache.zig");

pub const Match = @import("match.zig").Match;
pub const Group = @import("match.zig").Group;
const wholeMatch = @import("match.zig").wholeMatch;
const advanceEmpty = @import("match.zig").advanceEmpty;

const MetaKind = enum { literal, dfa, lit_prefix, reverse_suffix, bt_look, backtrack, split_alt, lazy_dfa, dense_search, class_span, boundary_lits, dup_word, dfa_edge_look };

/// `.boundary_lits` engine: `\b(?:lit|lit|…)\b` (a word-boundary-bracketed
/// pure literal alternation). The naive NFA of a big keyword list blows
/// `MAX_NFA`; here Aho-Corasick locates the next keyword occurrence in one
/// linear pass and an O(1) `\b` check verifies the two span edges — no NFA,
/// no `bt_look` `visited` array. See memory
/// `deep-alternation-reject-is-architectural`.
/// The matcher (AC locate + O(1) `\b` verify) lives in `seq_extract` as a
/// node-budget-generic `BoundaryMatcher`, so the runtime engine here and the
/// comptime `Pattern.boundary_lits` arm share one implementation. Runtime uses
/// the 1024-node `prefilter.AhoCorasick`; the comptime arm trims the table.
const BLits = seq_extract.BoundaryMatcher(prefilter.AhoCorasick);

/// Capture-group numbering + `(?<name>)` names, in source order. Lifted to
/// `parser.zig` as the single source of truth so the runtime and comptime
/// (`pattern.zig`) `.backtrack` paths agree by construction; aliased here so the
/// existing call site reads unchanged.
const scanGroups = parser.scanGroups;

/// Shift every set capture slot (`>= 0`) and leave unset slots (`-1`) alone,
/// converting offsets that were computed over `input[pos..]` back to absolute
/// `input` coordinates. A no-op when `pos == 0`.
fn shiftSlots(slots: []i32, pos: usize) void {
    if (pos == 0) return;
    const p: i32 = @intCast(pos);
    for (slots) |*s| {
        if (s.* >= 0) s.* += p;
    }
}

/// Parse a leading run of ASCII digits as a group index, saturating well
/// below `usize` overflow (a 7-digit run already dwarfs `MAX_GROUPS`, so it
/// resolves to "out of range" → empty). Returns the value and the count of
/// digits consumed.
fn parseGroupNum(s: []const u8) struct { num: usize, len: usize } {
    var num: usize = 0;
    var i: usize = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        if (num < 1_000_000) num = num * 10 + (s[i] - '0');
    }
    return .{ .num = num, .len = i };
}

/// Append capture group `idx` of `m` to `out`. Index `0` is the whole match;
/// an out-of-range or non-participating group expands to the empty string.
fn appendGroupByIndex(out: *std.ArrayList(u8), allocator: std.mem.Allocator, m: *const Match, idx: usize) !void {
    if (idx == 0) return out.appendSlice(allocator, m.slice); // whole match
    if (idx < m.groups.len) {
        if (m.groups[idx]) |g| try out.appendSlice(allocator, g.slice);
    }
}

/// Append the named group `name` of `m` to `out`. An all-digit name is treated
/// as a numbered reference; an empty or unknown name expands to the empty
/// string.
fn appendGroupByName(out: *std.ArrayList(u8), allocator: std.mem.Allocator, m: *const Match, name: []const u8) !void {
    if (name.len == 0) return; // ${} -> empty
    const g = parseGroupNum(name);
    if (g.len == name.len) return appendGroupByIndex(out, allocator, m, g.num); // all digits
    if (m.groupByName(name)) |grp| try out.appendSlice(allocator, grp.slice);
}

/// Append `template` to `out`, expanding `$`-references against match `m`:
///
///   - `$$`              → a literal `$`
///   - `$&`, `$0`, `${0}`→ the whole match
///   - `$N` (max digit run) → capture group N (empty if out of range / unset)
///   - `${name}`         → named group (all-digit name ⇒ numbered); empty if missing
///   - `$` + anything else (or end of template) → a literal `$`
///
/// Unknown, out-of-range, or non-participating references expand to the empty
/// string. `$12` is group 12; write `${1}2` for "group 1 then a literal 2".
fn appendExpanded(out: *std.ArrayList(u8), allocator: std.mem.Allocator, template: []const u8, m: *const Match) !void {
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] != '$') {
            try out.append(allocator, template[i]);
            i += 1;
            continue;
        }
        // template[i] == '$'
        if (i + 1 >= template.len) { // trailing '$' is literal
            try out.append(allocator, '$');
            i += 1;
            continue;
        }
        switch (template[i + 1]) {
            '$' => {
                try out.append(allocator, '$');
                i += 2;
            },
            '&' => {
                try out.appendSlice(allocator, m.slice);
                i += 2;
            },
            '0'...'9' => {
                const g = parseGroupNum(template[i + 1 ..]);
                try appendGroupByIndex(out, allocator, m, g.num);
                i += 1 + g.len;
            },
            '{' => {
                if (std.mem.indexOfScalarPos(u8, template, i + 2, '}')) |close| {
                    try appendGroupByName(out, allocator, m, template[i + 2 .. close]);
                    i = close + 1;
                } else { // no closing '}' -> the '$' is literal
                    try out.append(allocator, '$');
                    i += 1;
                }
            },
            else => { // '$' not starting a valid reference -> literal '$'
                try out.append(allocator, '$');
                i += 1;
            },
        }
    }
}

pub const Regex = struct {
    allocator: std.mem.Allocator,
    pattern: []const u8,
    flags: common.CompileFlags,

    kind: MetaKind,
    dfa: ?*full_dfa.Dfa256 = null,
    teddy: ?prefilter.Teddy = null,
    /// Owned NFA for the `.bt_look` path (look-assertion patterns run on the
    /// bounded backtracker — the DFA does not fold look-assertions).
    nfa: ?*thompson.Nfa(null) = null,
    /// Prescan anchors carried into the `.bt_look` backtracker (a leading
    /// `^`/`\A` or trailing `$`/`\z` can still be folded while the body also
    /// has a `\b`/`\Z`/`(?m)` look).
    bt_a_start: bool = false,
    bt_a_end: bool = false,
    /// `.bt_look` only: the pattern is unconditionally prefixed by a multiline
    /// `^` (`start_line`), so every match begins at a line start. Enables the
    /// line-start-enumeration fast path (`btLookLineScan`) — a `\n` memchr
    /// instead of trying every byte position.
    bt_line_anchor: bool = false,
    /// `.bt_look` + `bt_line_anchor` only: the body's leading-byte set, used to
    /// reject a line start with one byte test before the full `matchAt` (see
    /// `properties.line_first`). `null` ⇒ no filter (nullable body).
    bt_line_first: ?[32]u8 = null,
    /// `.bt_look` + `bt_line_anchor` only: a looks-stripped DFA for the regular
    /// `\n`-free body of `(?m)^body$` / `(?m)^body` (no captures). When set, the
    /// line scan runs ONE DFA pass per line (`matchEndFrom`) instead of the NFA
    /// `matchAt` — the dominant per-line cost. `$` is verified by the longest
    /// body end landing on a line terminator (sound: a `\n`-free body's longest
    /// accept never crosses the line). See `properties.lineAnchoredRegular`.
    line_dfa: ?*full_dfa.Dfa256 = null,
    line_has_dollar: bool = false,
    /// Capture metadata (set when the pattern has groups). `nfa` doubles as
    /// the capture engine's automaton. `gnames[g]` is group g's `(?<name>)`
    /// name (aliases `pattern`), or null.
    n_groups: usize = 0,
    gnames: [hir.MAX_GROUPS + 1]?[]const u8 = [_]?[]const u8{null} ** (hir.MAX_GROUPS + 1),
    /// Owned HIR for the `.backtrack` path (backref / lookaround run on the
    /// tree backtracker, which walks the HIR, not the NFA).
    bt_hir: ?*hir.Hir(null) = null,
    /// Owned "Seek" prefilter for `.backtrack`/`.split_alt`: a regular
    /// over-approximation DFA used to skip proven-dead prefixes (see
    /// `exec/seek.zig`). `null` ⇒ unfiltered per-byte scan (still correct).
    seek: ?*seek_mod.Seek = null,
    /// Owned segment plan for `.split_alt` (top-level alternation with a
    /// mix of regular and non-regular branches — see `exec/split_alt.zig`).
    split_plan: ?*split_alt.SplitAlt = null,
    /// Owned concat-internal regular-island delegation plan for
    /// `.backtrack`/`.bt_look` (see `exec/delegate.zig`). `null` ⇒ pure
    /// tree-walk.
    del: ?*delegate.Plan = null,
    /// `.class_span`: the whole unanchored pattern is one greedy `class+`
    /// / `class*` — matched by a SIMD member-run scan, no automaton.
    cs_ranges: class_span.Ranges = .{},
    cs_star: bool = false,
    /// Owned lazy DFA for `.lazy_dfa`: patterns whose eager `full_dfa` table
    /// blows `MAX_DFA` run here on demand instead of being rejected. Same
    /// construction, evaluated incrementally (bit-identical to `full_dfa`).
    /// References `self.nfa` (kept alive for the engine's lifetime).
    lazy: ?*lazy_dfa.LazyProg = null,
    /// Pooled mutable per-search scratch for the lazy engine. The compiled
    /// `Regex` is an immutable shareable value; the lazy memo races if
    /// shared, so each search borrows a `LazyMemo` from this thread-safe
    /// pool (per-`Regex`, so reuse keeps the learned states — same
    /// program ⇒ valid amortization).
    lazy_pool: ?*cache_mod.Pool(lazy_dfa.LazyMemo) = null,

    /// `.bt_look`: pooled visited-bitset scratch for the bounded backtracker,
    /// reused across the whole `findAll` loop (same rationale as `lazy_pool`).
    /// Without it, `nextSpanFrom` re-allocated + re-zeroed an
    /// `O(n_states·input.len)` bitset per match, making unanchored look-pattern
    /// search O(n²) (a multiline `^…$` ran at ~0.1 MB/s).
    bt_pool: ?*cache_mod.Pool(bounded_bt.BtScratch) = null,

    /// `.dense_search`: lever-A frozen dense unanchored search DFA (the
    /// gate-verified lazy automaton materialised to flat tables — O(n)
    /// single pass + dense reverse start, one array index/byte).
    dsearch: ?*lazy_dfa.DenseSearch = null,
    /// `.boundary_lits`: owned Aho-Corasick + literal set for the
    /// `\b(?:lit|lit|…)\b` engine (a regular pattern a naive NFA rejects).
    blits: ?*BLits = null,
    /// `.dup_word`: owned linear recogniser for the `(\b CLASS+ \b) SEP \1`
    /// adjacent-duplicate-token shape (see `exec/dupword.zig`).
    dw: ?*dupword.DupWord = null,
    /// `.dfa_edge_look`: verify spec for the peeled trailing width-1 look.
    /// The regular `core` runs on `self.dfa` (a normal `Dfa256`); this is the
    /// O(1) edge check applied to each candidate end (see `exec/edge_look.zig`).
    el_spec: edge_look.Spec = .{ .set = [_]u8{0} ** 32, .behind = false, .neg = false },
    /// Captures fast path: when the pattern is one-pass (decided at compile by
    /// the pure `onepass.isOnePass` over the DFA), `captures()` resolves slots
    /// via a single allocation-free deterministic forward pass instead of the
    /// `bounded_bt` memoized double-search. Pure speed — `bounded_bt` is the
    /// always-correct fallback if the deterministic walk bails.
    op_onepass: bool = false,

    /// Build the regular-`core` DFA for the `.dfa_edge_look` strategy: point
    /// the HIR root at `core_ref`, build NFA → `Dfa256` (unanchored at the end —
    /// the trailing look is handled by the O(1) edge verify, not the DFA),
    /// then restore the root. Returns `null` (caller falls back) on any build
    /// failure. The `required`-byte prefilter is computed over the core.
    fn buildEdgeLookDfa(allocator: std.mem.Allocator, h: *hir.Hir(null), core_ref: hir.NodeRef) ?*full_dfa.Dfa256 {
        const saved = h.root;
        h.root = core_ref;
        defer h.root = saved;
        var nfa = thompson.build(null, h) catch return null;
        var d = full_dfa.compute(null, &nfa, h.anchored_start, false);
        if (d.outcome != .ok) return null;
        d.required = seq_extract.requiredByte(null, h);
        const heap = allocator.create(full_dfa.Dfa256) catch return null;
        heap.* = d;
        return heap;
    }

    /// Build a `.lazy_dfa` engine over `nfa_local` (single-pass unanchored
    /// + reverse-start; also the eager-DFA-blowup fallback). Reuses an
    /// existing heap NFA (`nheap`, kept for captures) or makes its own.
    fn buildLazyRegex(
        allocator: std.mem.Allocator,
        nfa_local: *thompson.Nfa(null),
        nheap: ?*thompson.Nfa(null),
        owned: []const u8,
        flags: common.CompileFlags,
        a_start: bool,
        a_end: bool,
        ng: usize,
        gnames: [hir.MAX_GROUPS + 1]?[]const u8,
    ) !Regex {
        const nh = nheap orelse blk: {
            const p = try allocator.create(thompson.Nfa(null));
            p.* = nfa_local.*;
            break :blk p;
        };
        errdefer if (nheap == null) allocator.destroy(nh);
        const lz = try makeLazyProg(allocator, nh, a_start, a_end);
        errdefer {
            lz.prog.deinit();
            allocator.destroy(lz.prog);
            lz.pool.deinit();
            allocator.destroy(lz.pool);
        }
        return Regex{
            .allocator = allocator,
            .pattern = owned,
            .flags = flags,
            .kind = .lazy_dfa,
            .nfa = nh,
            .lazy = lz.prog,
            .lazy_pool = lz.pool,
            .bt_a_start = a_start,
            .bt_a_end = a_end,
            .n_groups = ng,
            .gnames = gnames,
        };
    }

    /// Lever A: build a `.dense_search` engine (the gate-verified lazy
    /// automaton frozen to flat tables — O(n) single pass + dense reverse
    /// start, one array index/byte). Falls back to the plain `.lazy_dfa`
    /// engine if the dense form exceeds `DenseSearch.MAX_DENSE_STATES`
    /// (== the current shipped behaviour, so a blow-up is never a
    /// regression). `nh` (kept for captures via the bounded-bt path) is
    /// reused from `nheap` or freshly heap-copied.
    fn buildDenseRegex(
        allocator: std.mem.Allocator,
        nfa_local: *thompson.Nfa(null),
        nheap: ?*thompson.Nfa(null),
        owned: []const u8,
        flags: common.CompileFlags,
        a_start: bool,
        a_end: bool,
        ng: usize,
        gnames: [hir.MAX_GROUPS + 1]?[]const u8,
    ) !Regex {
        const nh = nheap orelse blk: {
            const p = try allocator.create(thompson.Nfa(null));
            p.* = nfa_local.*;
            break :blk p;
        };
        errdefer if (nheap == null) allocator.destroy(nh);

        // Preserve the one-pass capture fast path (mirrors the eager `.dfa`
        // build's `op_ok`): a one-pass capture pattern reconstructs slots with a
        // single allocation-free `onepass.fill` over the span `nextSpanFrom`
        // returns — here the O(n) dense/lazy single pass. Without this, the
        // `$`-reroute would silently demote `([0-9]+)$` / `(cat|dog)$` / `(\w+)$`
        // captures to the slower bounded backtracker. `capturesFrom` gates on it.
        const op_onepass = ng > 0 and onepass.isOnePassNfa(null, nh);

        // Materialise via a temporary LazyProg (only its CSR/oracle is
        // needed to freeze; the DenseSearch is self-contained afterwards).
        var tmp = try lazy_dfa.LazyProg.init(allocator, nh, a_start, a_end);
        const ds_opt = tmp.freezeDense(allocator) catch |e| {
            tmp.deinit();
            return e;
        };
        tmp.deinit();

        if (ds_opt) |ds| {
            errdefer {
                ds.deinit();
                allocator.destroy(ds);
            }
            return Regex{
                .allocator = allocator,
                .pattern = owned,
                .flags = flags,
                .kind = .dense_search,
                .nfa = nh,
                .dsearch = ds,
                .bt_a_start = a_start,
                .bt_a_end = a_end,
                .n_groups = ng,
                .gnames = gnames,
                .op_onepass = op_onepass,
            };
        }

        // Too many states for the dense table — keep the plain lazy engine.
        const lz = try makeLazyProg(allocator, nh, a_start, a_end);
        errdefer {
            lz.prog.deinit();
            allocator.destroy(lz.prog);
            lz.pool.deinit();
            allocator.destroy(lz.pool);
        }
        return Regex{
            .allocator = allocator,
            .pattern = owned,
            .flags = flags,
            .kind = .lazy_dfa,
            .nfa = nh,
            .lazy = lz.prog,
            .lazy_pool = lz.pool,
            .bt_a_start = a_start,
            .bt_a_end = a_end,
            .n_groups = ng,
            .gnames = gnames,
            .op_onepass = op_onepass,
        };
    }

    /// Heap-allocate the immutable `LazyProg` + its thread-safe `LazyMemo`
    /// pool over `nh` (kept alive for their lifetime by the caller).
    fn makeLazyProg(
        allocator: std.mem.Allocator,
        nh: *thompson.Nfa(null),
        a_start: bool,
        a_end: bool,
    ) !struct { prog: *lazy_dfa.LazyProg, pool: *cache_mod.Pool(lazy_dfa.LazyMemo) } {
        const prog = try allocator.create(lazy_dfa.LazyProg);
        errdefer allocator.destroy(prog);
        prog.* = try lazy_dfa.LazyProg.init(allocator, nh, a_start, a_end);
        errdefer prog.deinit();
        const pool = try allocator.create(cache_mod.Pool(lazy_dfa.LazyMemo));
        errdefer allocator.destroy(pool);
        pool.* = cache_mod.Pool(lazy_dfa.LazyMemo).init(allocator);
        return .{ .prog = prog, .pool = pool };
    }

    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) !Regex {
        return compileWithFlags(allocator, pattern, .{});
    }

    pub fn compileWithFlags(
        allocator: std.mem.Allocator,
        pattern: []const u8,
        flags: common.CompileFlags,
    ) !Regex {
        if (pattern.len == 0) return RegexError.EmptyPattern;
        // `case_insensitive`/`dot_all`/`extended`/`multiline` are scoped mode
        // flags fully handled by the parser — the struct forms are exact peers
        // of the inline `(?i)`/`(?s)`/`(?x)`/`(?m)` groups (see
        // `parser.ParseFlags`); `multiline` just routes `^`/`$` to
        // `start_line`/`end_line` look nodes and disables the anchored prescan.
        // `unicode` (codepoint-aware classes) is a later phase the
        // byte-oriented DFA does not model yet.
        if (flags.unicode)
            return RegexError.NotImplemented;

        var h = hir.Hir(null).initRuntime();
        var h_owned = true; // false once ownership is transferred to a heap copy
        defer if (h_owned) h.deinit(allocator);
        parser.parse(null, &h, allocator, pattern, .{
            .ci = flags.case_insensitive,
            .dot_all = flags.dot_all,
            .extended = flags.extended,
            .multiline = flags.multiline,
        }) catch |e| {
            return switch (e) {
                hir.Error.Invalid => RegexError.InvalidPattern,
                hir.Error.Unsupported => RegexError.NotImplemented,
                hir.Error.TooComplex => RegexError.PatternTooComplex,
            };
        };

        const props = properties.analyze(null, &h);

        const owned = try allocator.dupe(u8, pattern);
        errdefer allocator.free(owned);

        var gnames0 = [_]?[]const u8{null} ** (hir.MAX_GROUPS + 1);
        const ng0 = scanGroups(owned, &gnames0);

        // Non-regular tier (backreferences / lookaround): the tree
        // backtracker owns the HIR (transfer it off the local stack so the
        // deferred deinit is a no-op). .NET model: compiles and runs,
        // step-budget → MatchBudgetExceeded (never a hang).
        if (props.requires_backtracking) {
            // Edge-look peel: `concat(regular_greedy_core, trailing_width1_look)`
            // runs `core` on the linear DFA + an O(1) edge verify, instead of
            // demoting the whole pattern to the tree backtracker (the lookaround
            // analogue of `bt_look`). Capture-free only. See `exec/edge_look.zig`.
            if (ng0 == 0) {
                if (edge_look.recognize(null, &h)) |rec| {
                    if (buildEdgeLookDfa(allocator, &h, rec.core)) |coredfa| {
                        return Regex{
                            .allocator = allocator,
                            .pattern = owned,
                            .flags = flags,
                            .kind = .dfa_edge_look,
                            .dfa = coredfa,
                            .el_spec = rec.spec,
                            .n_groups = 0,
                            .gnames = gnames0,
                        };
                    }
                }
            }

            // Per-segment delegation: a top-level alternation with no capture
            // groups and a mix of regular / non-regular branches runs each
            // regular run on an anchored DFA and only the non-regular
            // branches on the tree backtracker (leftmost-first preserved by
            // source order). `build` returns null when not applicable/safe,
            // and we fall through to the whole-pattern `.backtrack` path.
            if (ng0 == 0) {
                if (split_alt.build(allocator, &h, h.anchored_end)) |sa| {
                    return Regex{
                        .allocator = allocator,
                        .pattern = owned,
                        .flags = flags,
                        .kind = .split_alt,
                        .split_plan = sa,
                        .seek = seek_mod.build(allocator, &h),
                        .bt_a_start = h.anchored_start,
                        .bt_a_end = h.anchored_end,
                        .n_groups = 0,
                        .gnames = gnames0,
                    };
                }
            }

            // `(\b CLASS+ \b) SEP \1` adjacent-duplicate-token shape: one
            // O(n) forward scan instead of the per-position tree
            // backtracker. Narrow recogniser; any miss falls through to the
            // `.backtrack` path below unchanged (no regression, no semantic
            // risk — it is differential-tested against that backtracker).
            if (ng0 == 1) {
                if (dupword.build(&h)) |d| {
                    const e = try allocator.create(dupword.DupWord);
                    e.* = d;
                    return Regex{
                        .allocator = allocator,
                        .pattern = owned,
                        .flags = flags,
                        .kind = .dup_word,
                        .dw = e,
                        .n_groups = 1,
                        .gnames = gnames0,
                    };
                }
            }

            const hh = try allocator.create(hir.Hir(null));
            hh.* = h;
            h.nodes = .empty;
            h.sets = .empty;
            h_owned = false; // hh owns the buffers now
            return Regex{
                .allocator = allocator,
                .pattern = owned,
                .flags = flags,
                .kind = .backtrack,
                .bt_hir = hh,
                .seek = seek_mod.build(allocator, hh),
                .del = delegate.build(allocator, hh),
                .bt_a_start = hh.anchored_start,
                .bt_a_end = hh.anchored_end,
                .n_groups = ng0,
                .gnames = gnames0,
            };
        }

        // `\b(?:lit|lit|…)\b`: a word-boundary-bracketed pure literal
        // alternation. Regular, but a big keyword list blows the naive NFA's
        // `MAX_NFA` ⇒ a typed `PatternTooComplex` for a trivial language.
        // Run it as Aho-Corasick locate + O(1) `\b` verify instead (no NFA,
        // no `bt_look` `visited` array). Tight recogniser + AC node budget;
        // any miss falls through to the unchanged path below (no regression).
        // `n_groups == 0` only (this engine reports no submatches).
        if (ng0 == 0) {
            if (seq_extract.boundaryLiterals(null, &h)) |bl| {
                var needles: [seq_extract.MAX_BL][]const u8 = undefined;
                for (0..bl.n) |i| needles[i] = bl.alt(i);
                if (prefilter.AhoCorasick.build(needles[0..bl.n])) |ac| {
                    const e = try allocator.create(BLits);
                    e.* = BLits.init(ac, bl);
                    return Regex{
                        .allocator = allocator,
                        .pattern = owned,
                        .flags = flags,
                        .kind = .boundary_lits,
                        .blits = e,
                        .n_groups = 0,
                        .gnames = gnames0,
                    };
                }
            }
        }

        var nfa = thompson.build(null, &h) catch return RegexError.PatternTooComplex;

        const gnames = gnames0;
        const ng = ng0;

        // The capture reconstructor and the look engine both need the live
        // NFA; keep one heap copy when either applies.
        const need_nfa = props.needs_captures or props.has_look;
        const nheap: ?*thompson.Nfa(null) = if (need_nfa)
            try allocator.create(thompson.Nfa(null))
        else
            null;
        errdefer if (nheap) |p| allocator.destroy(p);
        if (nheap) |p| p.* = nfa;

        // Look-assertion patterns (\b \B, mid ^ $, (?m), mid \A \z \Z) run on
        // the bounded backtracker (it evaluates conditional epsilons with
        // (prev,next) byte context); the DFA does not fold look-assertions.
        if (props.has_look) {
            const bt_pool = try allocator.create(cache_mod.Pool(bounded_bt.BtScratch));
            errdefer allocator.destroy(bt_pool);
            bt_pool.* = cache_mod.Pool(bounded_bt.BtScratch).init(allocator);
            // Line-anchored regular fast path: `(?m)^body$` with a regular,
            // `\n`-free body matches each line with a single looks-stripped DFA
            // pass instead of the per-line NFA `matchAt`. Captures are fine —
            // the DFA locates the whole-match span (span-only models read it
            // directly; the one-pass capture path fills group slots over that
            // span via `onepass.fill`), so no `ng==0` restriction is needed.
            var line_dfa: ?*full_dfa.Dfa256 = null;
            var line_has_dollar = false;
            errdefer if (line_dfa) |p| allocator.destroy(p);
            if (props.leading_line_anchor) {
                if (properties.lineAnchoredRegular(null, &h)) |shape| {
                    if (buildLineDfa(allocator, &h)) |d| {
                        line_dfa = d;
                        line_has_dollar = shape.has_dollar;
                    }
                }
            }
            return Regex{
                .allocator = allocator,
                .pattern = owned,
                .flags = flags,
                .kind = .bt_look,
                .nfa = nheap,
                .bt_a_start = h.anchored_start,
                .bt_a_end = h.anchored_end,
                .bt_line_anchor = props.leading_line_anchor,
                .bt_line_first = props.line_first,
                .line_dfa = line_dfa,
                .line_has_dollar = line_has_dollar,
                .n_groups = ng,
                .gnames = gnames,
                .bt_pool = bt_pool,
            };
        }

        // Trivial `class+` / `class*` (whole unanchored pattern, greedy, no
        // groups): the match is just a maximal class run — a SIMD member
        // scan, no automaton. Orders faster than the DFA + per-position
        // restart for `[0-9]+`, `\w+`, `.+`, `[^…]+`.
        if (!h.anchored_start and !h.anchored_end and ng == 0 and !h.saw_lazy) {
            const rootn = h.node(h.root);
            if ((rootn.tag == .plus or rootn.tag == .star) and rootn.greedy) {
                const child = h.node(rootn.a);
                if (child.tag == .set) {
                    // Single contiguous range only. The chunk-skip scan wins
                    // only when the class is *sparse with long gaps* (e.g.
                    // `[0-9]+` — numbers amid prose: +118%, reproduced).
                    // For a dense/short-run class (`\w+` — word chars are
                    // most of the text, runs/gaps <16B) the per-chunk scalar
                    // boundary fallback is pure overhead and it *loses* to
                    // the DFA's tight per-byte loop (−51%). That is
                    // structural, not a codegen bug — the NEON-correct
                    // memberVec (`cmhs`+`bsl`+`orr`+`@reduce`) did not
                    // change it. So gate to single-range and let everything
                    // else keep the DFA. (multi-range = future: a tight
                    // first-member memchr, not chunk-skip.)
                    if (class_span.Ranges.fromBitmap(h.setBitmap(child.set_idx))) |rg| {
                        if (rg.n == 1) return Regex{
                            .allocator = allocator,
                            .pattern = owned,
                            .flags = flags,
                            .kind = .class_span,
                            .cs_ranges = rg,
                            .cs_star = rootn.tag == .star,
                            .n_groups = 0,
                            .gnames = gnames,
                        };
                    }
                }
            }
        }

        var d = full_dfa.compute(null, &nfa, h.anchored_start, h.anchored_end);
        if (d.outcome != .ok) {
            // Eager DFA blew the `MAX_DFA` ceiling. Fall back to the lazy
            // DFA: the *identical* subset construction evaluated on demand
            // (bit-for-bit agreement with `full_dfa` is pinned by
            // `lazy_dfa`'s differential test), so this only adds correct
            // coverage for patterns the eager table could not hold —
            // never a wrong answer, never a rejection. Captures (if any)
            // still resolve via `nfa` in `captures()` (bounded-bt path).
            return try buildLazyRegex(allocator, &nfa, nheap, owned, flags, h.anchored_start, h.anchored_end, ng, gnames);
        }
        // Necessary-condition memchr prefilter (keeps unanchored "required
        // literal absent" inputs linear instead of O(n²)). Carried into every
        // heap copy below.
        d.required = seq_extract.requiredByte(null, &h);
        // Necessary-literal-anywhere prefilter: memchr a rare mandatory
        // byte to candidate regions instead of the broad-first-byte
        // per-position restart (email `@`, uri `://`, ssn `-`).
        d.req_lit = seq_extract.requiredLiteralBack(null, &h);

        const strat = planner.plan(props, .{ .case_insensitive = flags.case_insensitive });
        // The strategy → concrete-route mapping (incl. the ≥3-byte / unanchored
        // `.lit_prefix` gate) is shared with the comptime `pattern.zig` via
        // `planner.resolve` — one source of truth for strategy selection.
        const route = planner.resolve(strat, h.anchored_start);

        // --- Lever A: targeted single-pass routing for the O(n·m) floor ---
        //
        // The blanket "route the whole `.dfa` tier through the lazy memo"
        // was reverted because it regresses every pattern that *has* a
        // usable eager dense DFA: the dense `Dfa256` is one O(1) array
        // index/byte; the lazy memo is a closure-backed transition + a
        // reverse pass per match (word 45→1.9, nltk 36→0.9, modsec 57→13;
        // the rest −10–20%). See `lazy-dfa-stage-status`.
        //
        // But for the *floor cluster* the eager path is not O(n) — it is
        // the O(n·m) broad-first-byte per-position restart (`semver`,
        // `phone_us`, `credit_card`, `ipv4`: ~40 MB/s). There the
        // already-tested lazy single pass (`lazy_dfa.findLeftmostFrom`:
        // lowest-priority `.*?` injection + memoized reverse start, O(n),
        // differential-tested bit-for-bit vs `full_dfa`, persistent memo
        // across `findAll`/`count`) wins by a wide margin. Route ONLY that
        // shape; the regressing patterns are excluded *by construction*:
        //   • selective prefilter present (`.literal`/`.reverse_suffix`/
        //     `.lit_prefix`, or a rare necessary literal `req_lit`) ⇒ eager
        //     is already linear and per-byte faster — keep it;
        //   • near-universal-accept ⇒ eager restart is effectively O(n)
        //     and the lazy per-byte cost loses badly (the prior revert:
        //     word/nltk collapsed). Two complementary guards:
        //       – `min_len ≥ 4`     excludes `nltk`/`float_sci` (min 1);
        //       – `n_start_bytes ≤ 16` excludes the broad-alphabet kind
        //         (`base64` 64-byte start set, `\w`-like) that `min_len`
        //         alone misses (base64 `min_len`=4 but matches everywhere
        //         → 54→3 MB/s under lazy). The true floor cluster has a
        //         narrow start set (semver/phone ≈11, credit_card/ipv4 10);
        //   • `.*?`-bearing (`modsec_sqli`) ⇒ excluded by `!saw_lazy`;
        //   • anchored ⇒ no restart problem anyway; excluded.
        // `d.required` is intentionally NOT a guard: it is only a
        // *negative* (absent ⇒ no match) filter, so a present-but-common
        // required byte (semver's `.`) leaves the eager path fully O(n·m).
        // "Plain eager DFA, no selective literal prefilter" — the planner's
        // `.core`, or a `.prefix_prefilter` that didn't clear the `.lit_prefix`
        // gate. `route == .dfa` is exactly that classification: under the
        // `!h.anchored_start` guard below the gate's anchor term is moot, so
        // this matches the old `strat`-based predicate bit-for-bit.
        const bare_dfa = route == .dfa;
        if (bare_dfa and
            !h.anchored_start and !h.anchored_end and
            !props.saw_lazy and props.min_len >= 4 and
            d.n_start_bytes <= 16 and
            d.req_lit == null)
        {
            return try buildDenseRegex(allocator, &nfa, nheap, owned, flags, h.anchored_start, h.anchored_end, ng, gnames);
        }

        // --- Lever A (anti-ReDoS): the unanchored `$`-anchored bare-DFA class.
        //
        // An *unanchored* pattern with a trailing `$`/`\z` and no usable literal
        // prefilter re-runs the eager `core.findLeftmost` from O(n) start
        // offsets — each scanning the whole class-run before the `a_end` accept
        // check fails — so it is O(n²) on non-matching `class+$` input (`a+$`,
        // `\s+$`, `\d+$`, `(a+)+$`, `a*a*$`, `.*a$`, …; the polynomial ReDoS the
        // `tests/security.zig` marker tracks). The `required`/`req_lit`
        // prefilters cannot gate this out: `a+$` *has* required byte `a`, but
        // it is present in the adversarial input, so the negative filter never
        // fires. The lazy engine's single forward `Σ*?` pass + reverse start
        // (now `a_end`-capable, `lazy_dfa.findAnchoredEndFrom`) is O(n) for the
        // whole class. Route it there; eager keeps every other shape.
        //
        // `.lit_prefix` is included too: a literal-prefixed `$` pattern
        // (`abc.*x$`, `abc[0-9]+$`) otherwise stays on `search.litPrefixFind`,
        // which loops over every Teddy hit of the prefix and `runFrom`s — O(n²)
        // when the prefix recurs (`abcabc…`). The reverse engine is O(n); we give
        // up the prefix Teddy locate (the reverse pass dies on its own at the
        // first non-suffix byte) for the linearity guarantee.
        if ((bare_dfa or route == .lit_prefix) and !h.anchored_start and h.anchored_end) {
            return try buildDenseRegex(allocator, &nfa, nheap, owned, flags, h.anchored_start, h.anchored_end, ng, gnames);
        }
        // Everything else with an eager dense table stays on the O(1)/byte
        // `core.findLeftmost` (the lazy single-pass is for `.lazy_dfa` —
        // exploded patterns with no dense table — where it cannot regress).

        // Captures one-pass gate (pure, comptime-evaluable for the `Pattern`
        // path): a one-pass pattern with groups can reconstruct slots in a
        // single allocation-free forward pass. No look/backref here (those
        // returned to bt_look/backtrack above). `nfa` is retained because
        // `need_nfa = needs_captures or has_look`.
        const op_ok = props.needs_captures and onepass.isOnePassNfa(null, &nfa);

        var self = Regex{
            .allocator = allocator,
            .pattern = owned,
            .flags = flags,
            .kind = .dfa,
            .nfa = nheap,
            .bt_a_start = h.anchored_start,
            .bt_a_end = h.anchored_end,
            .n_groups = ng,
            .gnames = gnames,
            .op_onepass = op_ok,
        };
        switch (route) {
            .literal => |seq| {
                self.kind = .literal;
                self.teddy = core.buildLiteral(&seq) orelse {
                    // Fall back to the DFA strategy (still correct).
                    const heap = try allocator.create(full_dfa.Dfa256);
                    heap.* = d;
                    self.kind = .dfa;
                    self.dfa = heap;
                    return self;
                };
            },
            .reverse_suffix => |seq| {
                const td = core.buildLiteral(&seq) orelse {
                    const heap = try allocator.create(full_dfa.Dfa256);
                    heap.* = d;
                    self.kind = .dfa;
                    self.dfa = heap;
                    return self;
                };
                const heap = try allocator.create(full_dfa.Dfa256);
                heap.* = d;
                self.kind = .reverse_suffix;
                self.dfa = heap;
                self.teddy = td;
            },
            .backtrack => return RegexError.NotImplemented, // errdefers free owned/nheap
            // A selective multi-byte literal *prefix*: Teddy-locate the
            // prefix, then anchored DFA `runFrom` verify there (exact
            // symmetry with `.reverse_suffix`, which Teddy-locates a
            // suffix). The ≥3-byte / unanchored gate already cleared in
            // `planner.resolve`; only Teddy-compilability remains (a literal
            // Teddy can't represent keeps the plain eager DFA). Measured
            // tradeoff (kept by request): big wins where the prefix is rare
            // (aws_eni +61%, href +18%, html +5%) at the cost of a corpus
            // where it is frequent (apache_post −17%); net ≈ flat.
            .lit_prefix => |seq| {
                const heap = try allocator.create(full_dfa.Dfa256);
                heap.* = d;
                self.dfa = heap;
                if (core.buildLiteral(&seq)) |td| {
                    self.kind = .lit_prefix;
                    self.teddy = td;
                } else self.kind = .dfa;
            },
            // NOTE: routing `.core` to the single-pass lazy engine
            // regressed those workloads ~100× / and again as a memoized
            // dense single-pass (see `lazy-dfa-stage-status`). Eager DFA.
            // (`.prefix_prefilter` that missed the gate resolves here too.)
            .dfa => {
                const heap = try allocator.create(full_dfa.Dfa256);
                heap.* = d;
                self.kind = .dfa;
                self.dfa = heap;
            },
        }
        return self;
    }

    pub fn deinit(self: *Regex) void {
        self.allocator.free(self.pattern);
        if (self.dfa) |p| self.allocator.destroy(p);
        if (self.line_dfa) |p| self.allocator.destroy(p);
        if (self.nfa) |p| self.allocator.destroy(p);
        if (self.bt_hir) |p| {
            p.deinit(self.allocator);
            self.allocator.destroy(p);
        }
        if (self.seek) |p| {
            p.deinit();
            self.allocator.destroy(p);
        }
        if (self.split_plan) |p| p.deinit();
        if (self.del) |p| p.deinit();
        if (self.lazy_pool) |p| {
            p.deinit(); // frees all pooled LazyMemo
            self.allocator.destroy(p);
        }
        if (self.bt_pool) |p| {
            p.deinit(); // frees all pooled BtScratch
            self.allocator.destroy(p);
        }
        if (self.lazy) |p| {
            p.deinit();
            self.allocator.destroy(p);
        }
        if (self.dsearch) |p| {
            p.deinit();
            self.allocator.destroy(p);
        }
        if (self.blits) |p| self.allocator.destroy(p);
        if (self.dw) |p| self.allocator.destroy(p);
    }

    /// `.bt_look` leftmost span. The visited bitset is borrowed from a
    /// per-`Regex` pool and reused across the whole non-overlapping iteration
    /// (`nextSpanFrom` calls this once per match): the buffer is zeroed once
    /// and each `matchAt` clears only the words it touched, so the full
    /// `findAll`/`count` is O(n·m), not the O(n²) the old per-match
    /// allocate-and-`@memset` produced. ReDoS-proof (still O(n·m) worst case).
    fn btLook(self: *const Regex, input: []const u8) !?core.Span {
        const pool = self.bt_pool.?;
        const sc = try pool.get();
        defer pool.put(sc);
        const n_pos1 = input.len + 1;
        try sc.ensure((self.nfa.?.n_states * n_pos1 + 63) / 64);
        var bt = bounded_bt.BoundedBt.initWith(self.nfa.?, self.bt_a_start, self.bt_a_end, sc, n_pos1);
        const s = (try bt.findLeftmost(input)) orelse return null;
        return core.Span{ .start = s.start, .end = s.end };
    }

    /// `.bt_look` leftmost span at/after absolute `from`, for a pattern with a
    /// leading multiline `^` (`bt_line_anchor`). Runs over the FULL `input`
    /// (absolute coordinates — so `lookHolds(.start_line)` sees the true
    /// preceding byte) and only attempts line starts. Returns an absolute span.
    /// This is what turns multiline `^…$` from O(n) start attempts into one
    /// `\n` memchr pass plus a match per matching line.
    fn btLookLineScan(self: *const Regex, input: []const u8, from: usize) !?core.Span {
        // Fast path FIRST: the line-DFA scan needs none of the NFA scratch, so
        // take it before paying the O(n) `(state,pos)` bitset `ensure` below.
        if (self.line_dfa) |dfa| return self.lineDfaScan(dfa, input, from);
        const pool = self.bt_pool.?;
        const sc = try pool.get();
        defer pool.put(sc);
        const n_pos1 = input.len + 1;
        try sc.ensure((self.nfa.?.n_states * n_pos1 + 63) / 64);
        var bt = bounded_bt.BoundedBt.initWith(self.nfa.?, self.bt_a_start, self.bt_a_end, sc, n_pos1);
        const s = (try bt.findLineStart(input, from, if (self.bt_line_first) |*set| set else null)) orelse return null;
        return core.Span{ .start = s.start, .end = s.end };
    }

    /// Line-anchored regular fast path (`line_dfa` set): the shared
    /// `line_dfa.nextFrom` walker (also used by the comptime `Pattern`) runs one
    /// looks-stripped body-DFA pass per line over the FULL input (absolute
    /// coords). See `exec/line_dfa.zig` for the soundness argument.
    fn lineDfaScan(self: *const Regex, dfa: *const full_dfa.Dfa256, input: []const u8, from: usize) ?core.Span {
        return line_dfa_mod.nextFrom(dfa, self.line_has_dollar, if (self.bt_line_first) |*set| set else null, input, from);
    }

    /// Build the looks-stripped body DFA for a `lineAnchoredRegular` pattern:
    /// clone the HIR relaxing every look to `ε` (the body, since the only looks
    /// are the line anchors handled by the scan), Thompson-build, and
    /// determinize. `null` on any build/ceiling failure ⇒ caller keeps the NFA
    /// line scan. The DFA is unanchored (`runFrom` anchors at each line start).
    fn buildLineDfa(allocator: std.mem.Allocator, h: *const hir.Hir(null)) ?*full_dfa.Dfa256 {
        var oh = hir.Hir(null).initRuntime();
        defer oh.deinit(allocator);
        oh.root = hir.cloneSubtree(null, null, &oh, allocator, h, h.root, true) catch return null;
        var nfa = thompson.build(null, &oh) catch return null;
        const d = full_dfa.compute(null, &nfa, false, false);
        if (d.outcome != .ok) return null;
        const heap = allocator.create(full_dfa.Dfa256) catch return null;
        heap.* = d;
        return heap;
    }

    /// `.backtrack` leftmost span (backref/lookaround tree backtracker). The
    /// step budget surfaces as `RegexError.MatchBudgetExceeded` (.NET model).
    fn btRun(self: *const Regex, input: []const u8) !?core.Span {
        var bt = backtrack.Backtracker.init(self.bt_hir.?, self.bt_a_start, self.bt_a_end, self.n_groups, self.seek, self.del);
        var slots: [bounded_bt.MAX_SLOTS]i32 = undefined;
        const sp = bt.run(input, slots[0 .. 2 * (self.n_groups + 1)]) catch
            return RegexError.MatchBudgetExceeded;
        const s = sp orelse return null;
        return core.Span{ .start = s.start, .end = s.end };
    }

    /// `.split_alt` leftmost span (top-level alternation: regular runs on
    /// anchored DFAs, non-regular branches on the tree backtracker, source
    /// order preserved). Budget surfaces as `MatchBudgetExceeded` (.NET model).
    fn splitRun(self: *const Regex, input: []const u8) !?core.Span {
        return self.split_plan.?.run(input, self.bt_a_start, self.bt_a_end, self.seek) catch
            return RegexError.MatchBudgetExceeded;
    }

    /// `.lazy_dfa` leftmost span (eager DFA blew `MAX_DFA`; same automaton
    /// evaluated incrementally). The lazy memo lives in the (heap) engine,
    /// so this needs a mutable `LazyDfa`.
    fn lazyRun(self: *const Regex, input: []const u8) !?core.Span {
        return self.lazyRunFrom(input, 0);
    }

    fn lazyIsMatch(self: *const Regex, input: []const u8) !bool {
        const pool = self.lazy_pool.?;
        const m = try pool.get();
        defer pool.put(m);
        return self.lazy.?.isMatchFast(m, input);
    }

    /// `.lazy_dfa` leftmost span resuming at absolute `from` — the memoized
    /// single pass (lever A). The eager DFA could not hold this pattern;
    /// the memo lives on the heap engine and persists across `findAll`
    /// calls, so the whole `findAll` is O(n), not O(n·matches).
    fn lazyRunFrom(self: *const Regex, input: []const u8, from: usize) !?core.Span {
        const pool = self.lazy_pool.?;
        const m = try pool.get();
        defer pool.put(m);
        const s = (try self.lazy.?.findLeftmostFrom(m, input, from)) orelse return null;
        return core.Span{ .start = s.start, .end = s.end };
    }

    /// `.class_span` leftmost span (greedy `class+`/`class*`). `class*` is
    /// nullable: the leftmost match is the (possibly empty) run at offset 0.
    fn csFind(self: *const Regex, input: []const u8) ?core.Span {
        if (self.cs_star)
            return core.Span{ .start = 0, .end = self.cs_ranges.runEnd(input, 0) };
        const i = self.cs_ranges.firstMember(input, 0) orelse return null;
        return core.Span{ .start = i, .end = self.cs_ranges.runEnd(input, i) };
    }

    fn csIsMatch(self: *const Regex, input: []const u8) bool {
        return self.cs_star or self.cs_ranges.firstMember(input, 0) != null;
    }

    pub fn isMatch(self: *const Regex, input: []const u8) !bool {
        return switch (self.kind) {
            .literal => core.literalIsMatchT(&self.teddy.?, input),
            .dfa => core.isMatch(self.dfa.?, input),
            .lit_prefix => core.litPrefixIsMatch(self.dfa.?, &self.teddy.?, input),
            .reverse_suffix => core.literalIsMatchT(&self.teddy.?, input) and
                core.isMatch(self.dfa.?, input),
            .bt_look => if (self.bt_line_anchor)
                (try self.btLookLineScan(input, 0)) != null
            else
                (try self.btLook(input)) != null,
            .backtrack => (try self.btRun(input)) != null,
            .split_alt => (try self.splitRun(input)) != null,
            .lazy_dfa => try self.lazyIsMatch(input),
            .dense_search => self.dsearch.?.isMatch(input),
            .class_span => self.csIsMatch(input),
            .boundary_lits => self.blits.?.find(input, 0) != null,
            .dup_word => self.dw.?.find(input, 0) != null,
            .dfa_edge_look => edge_look.nextFrom(self.dfa.?, &self.el_spec, input, 0) != null,
        };
    }

    /// Leftmost whole-match span anywhere in `input` (capture-free; `groups`
    /// stays empty — use `captures` for submatches). Convenience for
    /// `findFrom(input, 0)`.
    pub fn find(self: *const Regex, input: []const u8) !?Match {
        return self.findFrom(input, 0);
    }

    /// `find`, but for the leftmost whole-match span at/after absolute `pos`
    /// (capture-free). The positional-resume peer of `find` — mirrors
    /// `capturesFrom` for the capture-bearing path. `pos` must be
    /// `<= input.len`; the returned span is in absolute `input` coordinates.
    /// (As with `findAll`, a leading `^`/`\b`/look-behind on the slice-based
    /// engines treats `pos` as start-of-text.)
    pub fn findFrom(self: *const Regex, input: []const u8, pos: usize) !?Match {
        const s = (try self.nextSpanFrom(input, pos)) orelse return null;
        return wholeMatch(input, s.start, s.end);
    }

    /// Leftmost match with capture-group submatches (opt-in; `find`/`isMatch`
    /// stay on the fast DFA path and ignore groups). `Match.groups[0]` is the
    /// whole match; `groups[g]` is group g (or `null` if it did not
    /// participate). Caller owns the result — `defer m.?.deinit(allocator)`.
    pub fn captures(self: *const Regex, allocator: std.mem.Allocator, input: []const u8) !?Match {
        return self.capturesFrom(allocator, input, 0);
    }

    /// `captures`, but for the leftmost match at/after absolute `pos`. Backs
    /// the capture-bearing iteration surface (`capturesAll`,
    /// `CapturesIterator`) and the template-expanding `replace`/`replaceAll`.
    /// `pos` must be `<= input.len`. Caller owns the result —
    /// `defer m.?.deinit(allocator)`.
    ///
    /// The slice-based engines (`backtrack`, `bounded_bt` fallback) run over
    /// `input[pos..]` and have their span/slots shifted back to absolute
    /// coordinates — exactly the offset convention `nextSpanFrom` already uses
    /// for non-overlapping iteration, so capture iteration and `findAll` see
    /// the same match set. (Consequence: as with `findAll`, a leading `^`/`\b`/
    /// look-behind sees `pos` as start-of-text on those engines.)
    pub fn capturesFrom(self: *const Regex, allocator: std.mem.Allocator, input: []const u8, pos: usize) !?Match {
        const nslots = 2 * (self.n_groups + 1);
        var slots: [bounded_bt.MAX_SLOTS]i32 = undefined;
        var span: core.Span = undefined;
        if (self.kind == .dup_word) {
            var gs: usize = 0;
            var ge: usize = 0;
            const sp = self.dw.?.findCap(input, pos, &gs, &ge) orelse return null; // absolute
            @memset(slots[0..nslots], -1);
            slots[0] = @intCast(sp.start);
            slots[1] = @intCast(sp.end);
            const g = self.dw.?.group;
            if (2 * g + 1 < nslots) {
                slots[2 * g] = @intCast(gs);
                slots[2 * g + 1] = @intCast(ge);
            }
            span = .{ .start = sp.start, .end = sp.end };
        } else if (self.kind == .backtrack) {
            var bt = backtrack.Backtracker.init(self.bt_hir.?, self.bt_a_start, self.bt_a_end, self.n_groups, self.seek, self.del);
            const sp = (bt.run(input[pos..], slots[0..nslots]) catch return RegexError.MatchBudgetExceeded) orelse return null;
            span = .{ .start = sp.start + pos, .end = sp.end + pos };
            shiftSlots(slots[0..nslots], pos);
        } else if (self.nfa != null and self.n_groups > 0) {
            // One-pass fast path: span from the DFA (O(n)), slots via a single
            // allocation-free deterministic pass. `bounded_bt` is the
            // always-correct fallback if the pattern is not truly one-pass
            // (the deterministic walk bails ⇒ `fill` returns false).
            done: {
                // Line-anchored capture pattern: the line-DFA (via
                // `nextSpanFrom`) locates the whole-match span fast — skipping
                // non-matching lines — then capture slots are reconstructed
                // with the bounded backtracker over JUST that line span (scratch
                // sized to one line, not the whole input — the latter is what
                // makes the generic fallback O(n) per match). The span is a line
                // (a line start `s` and `$`/EOF end), so both-anchoring the
                // backtracker on the slice reproduces the same leftmost-first
                // captures. `nextSpanFrom` is exact ⇒ no span ahead ⇒ no match.
                if (self.line_dfa != null) {
                    const sp = (try self.nextSpanFrom(input, pos)) orelse return null; // absolute
                    var bt = try bounded_bt.BoundedBt.init(allocator, self.nfa.?, true, true, sp.end - sp.start);
                    defer bt.deinit();
                    _ = (try bt.captures(input[sp.start..sp.end], slots[0..nslots])) orelse return null;
                    shiftSlots(slots[0..nslots], sp.start);
                    slots[0] = @intCast(sp.start);
                    slots[1] = @intCast(sp.end);
                    span = sp;
                    break :done;
                }
                if (self.op_onepass) {
                    const sp = (try self.nextSpanFrom(input, pos)) orelse return null; // absolute
                    @memset(slots[0..nslots], -1);
                    slots[0] = @intCast(sp.start);
                    slots[1] = @intCast(sp.end);
                    if (onepass.fill(null, self.nfa.?, input, .{ .start = sp.start, .end = sp.end }, slots[0..nslots])) {
                        span = sp;
                        break :done;
                    }
                }
                // Reverse-pass engines (`.dense_search`/`.lazy_dfa` — the
                // unanchored `$` class + the floor cluster): `nextSpanFrom`
                // already finds the whole-match span in ONE O(n) pass (the
                // reverse `findAnchoredEnd` for `$`), so reconstruct slots over
                // JUST that span — like the line-DFA path above. Without this a
                // non-one-pass `(a+)+$`-with-groups capture would drop to the
                // whole-input bounded backtracker below and stay O(n²) (worse,
                // catastrophic) on adversarial input, even though `find`/`isMatch`
                // are O(n). The span is the exact match, so both-anchoring the
                // backtracker over the slice reproduces the leftmost-first slots.
                if (self.kind == .dense_search or self.kind == .lazy_dfa) {
                    const sp = (try self.nextSpanFrom(input, pos)) orelse return null; // absolute
                    var bt = try bounded_bt.BoundedBt.init(allocator, self.nfa.?, true, true, sp.end - sp.start);
                    defer bt.deinit();
                    _ = (try bt.captures(input[sp.start..sp.end], slots[0..nslots])) orelse return null;
                    shiftSlots(slots[0..nslots], sp.start);
                    slots[0] = @intCast(sp.start);
                    slots[1] = @intCast(sp.end);
                    span = sp;
                    break :done;
                }
                var bt = try bounded_bt.BoundedBt.init(allocator, self.nfa.?, self.bt_a_start, self.bt_a_end, input.len);
                defer bt.deinit();
                const sp = (try bt.captures(input[pos..], slots[0..nslots])) orelse return null;
                span = .{ .start = sp.start + pos, .end = sp.end + pos };
                shiftSlots(slots[0..nslots], pos);
            }
        } else {
            // No capture groups: only the whole-match span is meaningful.
            const sp = (try self.nextSpanFrom(input, pos)) orelse return null;
            return wholeMatch(input, sp.start, sp.end);
        }

        const groups = try allocator.alloc(?Group, self.n_groups + 1);
        errdefer allocator.free(groups);
        groups[0] = .{ .slice = input[span.start..span.end], .start = span.start, .end = span.end, .name = null };
        var g: usize = 1;
        while (g <= self.n_groups) : (g += 1) {
            const s = slots[2 * g];
            const e = slots[2 * g + 1];
            if (s >= 0 and e >= 0 and s <= e) {
                const su: usize = @intCast(s);
                const eu: usize = @intCast(e);
                groups[g] = .{ .slice = input[su..eu], .start = su, .end = eu, .name = self.gnames[g] };
            } else groups[g] = null;
        }
        return Match{
            .slice = input[span.start..span.end],
            .start = span.start,
            .end = span.end,
            .groups = groups,
        };
    }

    /// The next leftmost match span at/after absolute `pos`, in absolute
    /// `input` coordinates, or `null` if none. This is the single source of
    /// truth for non-overlapping iteration — `findAll`, the `MatchIterator`
    /// and `count` all dispatch through it, so their semantics cannot drift.
    fn nextSpanFrom(self: *const Regex, input: []const u8, pos: usize) !?core.Span {
        return switch (self.kind) {
            .literal => core.literalFindT(&self.teddy.?, input, pos),
            .reverse_suffix => blk: {
                // The suffix Teddy is a sound fast-negative gate (no
                // occurrence ⇒ no match); the DFA decides the actual span.
                if (core.literalFindT(&self.teddy.?, input, pos) == null) break :blk null;
                const fm = core.findLeftmost(self.dfa.?, input[pos..]) orelse break :blk null;
                break :blk core.Span{ .start = pos + fm.start, .end = pos + fm.end };
            },
            .dfa => blk: {
                const r = core.findLeftmost(self.dfa.?, input[pos..]) orelse break :blk null;
                break :blk core.Span{ .start = pos + r.start, .end = pos + r.end };
            },
            .lit_prefix => blk: {
                const r = core.litPrefixFind(self.dfa.?, &self.teddy.?, input[pos..]) orelse break :blk null;
                break :blk core.Span{ .start = pos + r.start, .end = pos + r.end };
            },
            .bt_look => blk: {
                // Leading multiline `^`: enumerate line starts over the FULL
                // input (absolute coords) instead of every position.
                if (self.bt_line_anchor) break :blk try self.btLookLineScan(input, pos);
                const r = (try self.btLook(input[pos..])) orelse break :blk null;
                break :blk core.Span{ .start = pos + r.start, .end = pos + r.end };
            },
            .backtrack => blk: {
                const r = (try self.btRun(input[pos..])) orelse break :blk null;
                break :blk core.Span{ .start = pos + r.start, .end = pos + r.end };
            },
            .split_alt => blk: {
                const r = (try self.splitRun(input[pos..])) orelse break :blk null;
                break :blk core.Span{ .start = pos + r.start, .end = pos + r.end };
            },
            .lazy_dfa => try self.lazyRunFrom(input, pos), // already absolute
            .dense_search => blk: {
                const r = self.dsearch.?.findFrom(input, pos) orelse break :blk null;
                break :blk core.Span{ .start = r.start, .end = r.end }; // absolute
            },
            .class_span => blk: {
                const r = self.csFind(input[pos..]) orelse break :blk null;
                break :blk core.Span{ .start = pos + r.start, .end = pos + r.end };
            },
            .boundary_lits => self.blits.?.find(input, pos), // already absolute
            .dup_word => blk: {
                const r = self.dw.?.find(input, pos) orelse break :blk null;
                break :blk core.Span{ .start = r.start, .end = r.end }; // absolute
            },
            .dfa_edge_look => edge_look.nextFrom(self.dfa.?, &self.el_spec, input, pos), // absolute
        };
    }

    pub fn findAll(self: *const Regex, allocator: std.mem.Allocator, input: []const u8) ![]Match {
        var list: std.ArrayList(Match) = .empty;
        errdefer list.deinit(allocator);
        var pos: usize = 0;
        while (pos <= input.len) {
            const s = (try self.nextSpanFrom(input, pos)) orelse break;
            try list.append(allocator, wholeMatch(input, s.start, s.end));
            pos = advanceEmpty(s.start, s.end);
        }
        return list.toOwnedSlice(allocator);
    }

    /// `findAll` with capture-group submatches: every non-overlapping leftmost
    /// match, each carrying its own allocator-owned `groups` (same advance
    /// rule as `findAll`/`count`). The capture-bearing analogue of `findAll`.
    ///
    /// Ownership: **each** returned `Match` owns its `groups`, plus the outer
    /// slice is owned. Free with:
    /// ```zig
    /// const ms = try re.capturesAll(a, input);
    /// defer { for (ms) |*m| m.deinit(a); a.free(ms); }
    /// ```
    /// For large inputs prefer `capturesIterator` (free each `Match` as you go
    /// — lower peak memory) over materialising the whole slice.
    pub fn capturesAll(self: *const Regex, allocator: std.mem.Allocator, input: []const u8) ![]Match {
        var list: std.ArrayList(Match) = .empty;
        errdefer {
            for (list.items) |*m| m.deinit(allocator);
            list.deinit(allocator);
        }
        var pos: usize = 0;
        while (pos <= input.len) {
            var m = (try self.capturesFrom(allocator, input, pos)) orelse break;
            const s = m.start;
            const e = m.end;
            list.append(allocator, m) catch |err| {
                m.deinit(allocator);
                return err;
            };
            pos = advanceEmpty(s, e);
        }
        return list.toOwnedSlice(allocator);
    }

    /// Count all non-overlapping leftmost matches. Semantically identical to
    /// `(try findAll(a, input)).len` but **allocation-free** — no per-match
    /// `Match` is materialised on the heap (the measurement-fair analogue of
    /// RE2/Rust `find_iter().count()`).
    ///
    /// For the `class+` family (`[0-9]+`, `\w+`, … — the *whole* unanchored
    /// pattern is one non-nullable single-class repetition) it is a single
    /// forward sweep over the member-run boundaries: no `Match`, no per-run
    /// engine re-entry, no sub-slicing. (`class*` is nullable, so it keeps
    /// the shared per-match path to preserve the empty-match semantics.)
    pub fn count(self: *const Regex, input: []const u8) !usize {
        if (self.kind == .class_span and !self.cs_star) {
            var n: usize = 0;
            var i: usize = 0;
            while (self.cs_ranges.firstMember(input, i)) |s| : (n += 1) {
                i = self.cs_ranges.runEnd(input, s);
            }
            return n;
        }
        var n: usize = 0;
        var pos: usize = 0;
        while (pos <= input.len) {
            const s = (try self.nextSpanFrom(input, pos)) orelse break;
            n += 1;
            pos = advanceEmpty(s.start, s.end);
        }
        return n;
    }

    /// Replace the first match, expanding `$`-references in `template` against
    /// the match's capture groups (`$1`, `${name}`, `$0`/`$&` = whole match,
    /// `$$` = literal `$`; see `appendExpanded`). Caller owns the result. For
    /// a byte-for-byte literal replacement use `replaceLiteral`.
    pub fn replace(self: *const Regex, allocator: std.mem.Allocator, input: []const u8, template: []const u8) ![]u8 {
        if (std.mem.indexOfScalar(u8, template, '$') == null)
            return self.replaceLiteral(allocator, input, template);
        var m = (try self.capturesFrom(allocator, input, 0)) orelse return allocator.dupe(u8, input);
        defer m.deinit(allocator);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, input[0..m.start]);
        try appendExpanded(&out, allocator, template, &m);
        try out.appendSlice(allocator, input[m.end..]);
        return out.toOwnedSlice(allocator);
    }

    /// Replace every non-overlapping match, expanding `$`-references in
    /// `template` (see `replace`). Caller owns the result. For a byte-for-byte
    /// literal replacement use `replaceAllLiteral`.
    pub fn replaceAll(self: *const Regex, allocator: std.mem.Allocator, input: []const u8, template: []const u8) ![]u8 {
        // No `$` ⇒ nothing to expand: take the allocation-light literal path
        // (span-only, no per-match group materialisation).
        if (std.mem.indexOfScalar(u8, template, '$') == null)
            return self.replaceAllLiteral(allocator, input, template);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var pos: usize = 0;
        var last: usize = 0;
        while (pos <= input.len) {
            var m = (try self.capturesFrom(allocator, input, pos)) orelse break;
            defer m.deinit(allocator);
            try out.appendSlice(allocator, input[last..m.start]);
            try appendExpanded(&out, allocator, template, &m);
            last = m.end;
            pos = advanceEmpty(m.start, m.end);
        }
        try out.appendSlice(allocator, input[last..]);
        return out.toOwnedSlice(allocator);
    }

    /// Replace the first match with `replacement` inserted **verbatim** (no
    /// `$`-substitution). Caller owns the result.
    pub fn replaceLiteral(self: *const Regex, allocator: std.mem.Allocator, input: []const u8, replacement: []const u8) ![]u8 {
        const m = (try self.find(input)) orelse return allocator.dupe(u8, input);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, input[0..m.start]);
        try out.appendSlice(allocator, replacement);
        try out.appendSlice(allocator, input[m.end..]);
        return out.toOwnedSlice(allocator);
    }

    /// Replace every non-overlapping match with `replacement` inserted
    /// **verbatim** (no `$`-substitution). Caller owns the result.
    pub fn replaceAllLiteral(self: *const Regex, allocator: std.mem.Allocator, input: []const u8, replacement: []const u8) ![]u8 {
        const ms = try self.findAll(allocator, input);
        defer allocator.free(ms);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var last: usize = 0;
        for (ms) |m| {
            try out.appendSlice(allocator, input[last..m.start]);
            try out.appendSlice(allocator, replacement);
            last = m.end;
        }
        try out.appendSlice(allocator, input[last..]);
        return out.toOwnedSlice(allocator);
    }

    /// Split `input` around matches. Caller owns the slice (not the elements,
    /// which alias `input`).
    pub fn split(self: *const Regex, allocator: std.mem.Allocator, input: []const u8) ![][]const u8 {
        const ms = try self.findAll(allocator, input);
        defer allocator.free(ms);
        var parts: std.ArrayList([]const u8) = .empty;
        errdefer parts.deinit(allocator);
        var last: usize = 0;
        for (ms) |m| {
            if (m.end == m.start) continue; // don't split on zero-width
            try parts.append(allocator, input[last..m.start]);
            last = m.end;
        }
        try parts.append(allocator, input[last..]);
        return parts.toOwnedSlice(allocator);
    }

    /// Lazy iterator over successive non-overlapping whole-match spans — the
    /// capture-free peer of `capturesIterator`. Borrows `self` and `input`
    /// (both must outlive it); each yielded `Match` has empty `groups`.
    pub fn iterator(self: *const Regex, input: []const u8) MatchIterator {
        return .{ .regex = self, .input = input, .pos = 0 };
    }

    pub const MatchIterator = struct {
        regex: *const Regex,
        input: []const u8,
        pos: usize,

        pub fn next(self: *MatchIterator, allocator: std.mem.Allocator) !?Match {
            _ = allocator;
            if (self.pos > self.input.len) return null;
            const s = (try self.regex.nextSpanFrom(self.input, self.pos)) orelse return null;
            self.pos = advanceEmpty(s.start, s.end);
            return wholeMatch(self.input, s.start, s.end);
        }

        pub fn deinit(self: *MatchIterator) void {
            _ = self;
        }
    };

    /// Streaming capture-bearing iteration: the capture-aware sibling of
    /// `iterator`. Each `next` returns the next leftmost match (same advance
    /// rule as `findAll`) carrying its own allocator-owned `groups` — the
    /// caller must `deinit` each returned `Match`.
    pub fn capturesIterator(self: *const Regex, input: []const u8) CapturesIterator {
        return .{ .regex = self, .input = input, .pos = 0 };
    }

    pub const CapturesIterator = struct {
        regex: *const Regex,
        input: []const u8,
        pos: usize,

        /// The next match with submatches, or `null` when exhausted. The
        /// returned `Match` owns its `groups`; `defer m.deinit(allocator)`.
        pub fn next(self: *CapturesIterator, allocator: std.mem.Allocator) !?Match {
            if (self.pos > self.input.len) return null;
            const m = (try self.regex.capturesFrom(allocator, self.input, self.pos)) orelse return null;
            self.pos = advanceEmpty(m.start, m.end);
            return m;
        }

        /// No shared state to release (each yielded `Match` is owned by the
        /// caller); present for API parity with `MatchIterator`.
        pub fn deinit(self: *CapturesIterator) void {
            _ = self;
        }
    };
};

test "regex(meta): count == findAll().len across engine kinds" {
    const a = std.testing.allocator;
    const Case = struct { pat: []const u8, hay: []const u8 };
    const cases = [_]Case{
        .{ .pat = "hello", .hay = "hello a hello b hellos" }, // .literal
        .{ .pat = "[0-9]+", .hay = "12 a34 5 b 6789 c" }, // .class_span (class+)
        .{ .pat = "\\w+", .hay = "  foo_Bar 12  baz! qux" }, // .class_span (class+)
        .{ .pat = "v?[0-9]+\\.[0-9]+\\.[0-9]+", .hay = "v1.2.3 x 10.20.30 9.9 4.5.6" }, // .dfa restart
        .{ .pat = "cat|dog|bird", .hay = "a cat dog x bird cat" }, // literal-alt
        .{ .pat = "[A-Za-z]+://[^ ]+", .hay = "see http://a.b/c and ftp://x.y/z end" }, // prefilter
        .{ .pat = "a.*b.*c", .hay = "axbyc and a__b__c tail" }, // wildcard
        .{ .pat = "(\\w+) \\1", .hay = "the the quick fox fox jumps" }, // .backtrack (backref)
    };
    for (cases) |c| {
        var r = try Regex.compile(a, c.pat);
        defer r.deinit();
        const ms = try r.findAll(a, c.hay);
        defer a.free(ms);
        try std.testing.expectEqual(ms.len, try r.count(c.hay));
    }
}

test "regex(meta): literal + dfa + findAll/replace/split" {
    const a = std.testing.allocator;

    var r1 = try Regex.compile(a, "hello");
    defer r1.deinit();
    try std.testing.expect(try r1.isMatch("say hello now"));
    try std.testing.expect(!try r1.isMatch("nope"));

    var r2 = try Regex.compile(a, "\\d+");
    defer r2.deinit();
    const ms = try r2.findAll(a, "a12 b3 c456");
    defer a.free(ms);
    try std.testing.expectEqual(@as(usize, 3), ms.len);
    try std.testing.expectEqualStrings("12", ms[0].slice);

    const rep = try r2.replaceAll(a, "x1y22z", "#");
    defer a.free(rep);
    try std.testing.expectEqualStrings("x#y#z", rep);

    var r3 = try Regex.compile(a, "cat|dog|bird");
    defer r3.deinit();
    const m = (try r3.find("a dog ran")).?;
    try std.testing.expectEqualStrings("dog", m.slice);

    // Backref / lookaround now compile and run on the tree backtracker
    // (Phase E, .NET model) instead of being rejected.
    var rb = try Regex.compile(a, "(a)\\1");
    defer rb.deinit();
    try std.testing.expect(try rb.isMatch("aa"));
    try std.testing.expect(!try rb.isMatch("ab"));
    var rl = try Regex.compile(a, "a(?=b)");
    defer rl.deinit();
    try std.testing.expect(try rl.isMatch("ab"));
    try std.testing.expect(!try rl.isMatch("ac"));
}
