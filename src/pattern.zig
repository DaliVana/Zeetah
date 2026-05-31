//! `Pattern(src, opts)` — the comptime path of the meta engine, built on the
//! unified `parser`→`hir`→`thompson`→`exec/full_dfa` pipeline. The whole
//! pipeline (parse → HIR → NFA → subset-construct/minimize) runs at compile
//! time and the minimized DFA is monomorphized into a baked `dfa.Dfa(ns,nk)`
//! in `.rodata`; the planner's `.literal` strategy short-circuits to a
//! comptime Teddy with no DFA table. Same `has_dfa` split / method
//! signatures / `Options` + explosion semantics as the runtime `Regex`;
//! the two are differential-tested in `tests/feat_api.zig`.

const std = @import("std");
const dfa = @import("exec/comptime_dfa.zig");
const pf = @import("prefilter.zig");
const hir = @import("hir.zig");
const parser = @import("parser.zig");
const thompson = @import("thompson.zig");
const full_dfa = @import("exec/full_dfa.zig");
const properties = @import("properties.zig");
const planner = @import("planner.zig");
const core = @import("exec/core.zig");
const search = @import("exec/search.zig");
const seq_extract = @import("exec/seq_extract.zig");

const Match = @import("match.zig").Match;
const Group = @import("match.zig").Group;
const wholeMatch = @import("match.zig").wholeMatch;
const advanceEmpty = @import("match.zig").advanceEmpty;

/// Comptime build budget for the shared IR store (exceeding it routes to
/// `Error.TooComplex` -> explosion).
const HIR_CAP: usize = 2048;

/// Compile-time configuration (same shape/semantics as the runtime flags).
pub const Options = struct {
    /// Soft budget on the minimized DFA's state count. A buildable pattern
    /// whose DFA exceeds this is handled per `on_oversize`. This budget is
    /// independent of — and capped by — the fixed internal construction
    /// ceiling (raising it has no effect past that ceiling).
    max_dfa_states: usize = 256,
    /// What to do when the minimized DFA builds successfully but has more than
    /// `max_dfa_states` states: `.compile_error` rejects it at compile time;
    /// `.allow_oversized` bakes the larger table anyway (still bounded by the
    /// internal ceiling). This does NOT rescue patterns that blow the internal
    /// ceiling or use an unsupported feature — those are always a compile error
    /// (the comptime path has no runtime fallback; reach for the runtime
    /// `Regex.compile` instead).
    on_oversize: enum { compile_error, allow_oversized } = .compile_error,
    case_insensitive: bool = false,
};

const MAX_NFA = thompson.MAX_NFA;
const MAX_EDGES = thompson.MAX_EDGES;
const MAX_DFA: usize = 256;

const Outcome = enum { ok, unsupported, exploded };

/// §6/(c) monomorphization: which planner strategy the baked matcher emits.
/// `.literal` skips the DFA table entirely (Teddy only); the other three bake
/// the DFA and differ only in the per-position prefilter wrapped around it.
const Strat = enum { literal, reverse_suffix, lit_prefix, dfa };

/// Search mode for the baked-DFA matcher (everything except `.literal`). A
/// comptime constant, so the `switch (mode)` in each method folds to the one
/// chosen branch — only the picked strategy's code is instantiated.
const Mode = enum { dfa, reverse_suffix, lit_prefix };

const Built = struct {
    dfa: full_dfa.Dfa256,
    outcome: Outcome,
    strat: Strat = .dfa,
    /// The strategy's literal `Seq`: the exact literal (`.literal`), the
    /// trailing literal (`.reverse_suffix`), or the leading literal prefix
    /// (`.lit_prefix`). Unused for `.dfa`. For `.literal` the DFA is never
    /// instantiated — only this `Seq` + a Teddy scan are emitted.
    seq: seq_extract.Seq = .{},
};

/// Run the whole pipeline at comptime: parse -> Hir -> Thompson NFA ->
/// subset construction + minimization. `unsupported` -> runtime fallback;
/// `exploded` -> the explosion guard; `ok` -> bake the DFA.
fn buildAll(comptime pattern: []const u8, comptime ci: bool) Built {
    @setEvalBranchQuota(8_000_000);
    var h = hir.Hir(HIR_CAP).initComptime();
    parser.parse(HIR_CAP, &h, undefined, pattern, .{ .ci = ci }) catch |e| {
        return .{
            .dfa = full_dfa.emptyDfa256(.ok),
            .outcome = switch (e) {
                hir.Error.Unsupported => .unsupported,
                hir.Error.TooComplex => .exploded,
            },
        };
    };
    var nfa = thompson.build(HIR_CAP, &h) catch {
        return .{ .dfa = full_dfa.emptyDfa256(.ok), .outcome = .exploded };
    };
    var d = full_dfa.compute(HIR_CAP, &nfa, h.anchored_start, h.anchored_end);
    if (d.outcome == .exploded) return .{ .dfa = d, .outcome = .exploded };

    // (a) Bake the necessary-condition prefilters into the DFA, exactly as the
    // runtime `regex.zig` does (`d.required` / `d.req_lit`). This is what keeps
    // the comptime `Pattern`'s unanchored search linear instead of O(n²) — and
    // gives the email/uri/ssn-style required-literal speedup at comptime too.
    d.required = seq_extract.requiredByte(HIR_CAP, &h);
    d.req_lit = seq_extract.requiredLiteralBack(HIR_CAP, &h);

    // §6/(c): pure planner decision at comptime. A `.literal` strategy needs no
    // DFA at all (Teddy only); `.reverse_suffix` / `.lit_prefix` bake the DFA
    // plus a literal prefilter. The strategy → concrete-route mapping (incl. the
    // ≥3-byte / unanchored `.lit_prefix` gate) is shared with the runtime
    // `regex.zig` via `planner.resolve`, so the two front-ends pick the same
    // strategy *by construction* (the `tests/feat_api.zig` differential is now a
    // backstop on materialization, not the primary guard on routing).
    const props = properties.analyze(HIR_CAP, &h);
    const strat = planner.plan(props, .{ .case_insensitive = ci });
    return switch (planner.resolve(strat, h.anchored_start)) {
        .literal => |seq| .{ .dfa = d, .outcome = .ok, .strat = .literal, .seq = seq },
        .reverse_suffix => |sfx| .{ .dfa = d, .outcome = .ok, .strat = .reverse_suffix, .seq = sfx },
        .lit_prefix => |pp| .{ .dfa = d, .outcome = .ok, .strat = .lit_prefix, .seq = pp },
        // `.core`, plus the `.backtrack` sentinel (never reached — non-regular
        // patterns `@compileError` upstream): plain baked DFA.
        .dfa, .backtrack => .{ .dfa = d, .outcome = .ok, .strat = .dfa },
    };
}

/// Build a regex from a comptime-known `pattern`. See the old `ComptimeRegex`
/// doc comment — the `has_dfa`-dependent signatures and `Match` ownership
/// contract are preserved exactly so callers/tests need no changes.
pub fn Pattern(comptime pattern: []const u8, comptime opts: Options) type {
    const built = comptime buildAll(pattern, opts.case_insensitive);
    const m = built.dfa;

    // Blowing the internal construction ceiling is unrepresentable — there is
    // no oversized DFA to bake, so `on_oversize` cannot rescue it. Always a
    // hard compile error.
    if (built.outcome == .exploded) {
        @compileError(std.fmt.comptimePrint(
            "regex \"{s}\": too complex for the compile-time DFA — it blew a " ++
                "fixed internal construction ceiling ({d} NFA states / {d} " ++
                "edges / {d} raw DFA states). This ceiling is independent of " ++
                "Options.max_dfa_states (and is not relaxed by " ++
                "Options.on_oversize). Simplify the pattern, or use the runtime " ++
                "Regex.compile.",
            .{ pattern, MAX_NFA, MAX_EDGES, MAX_DFA },
        ));
    }

    const use_dfa = built.outcome == .ok and
        (m.n_states <= opts.max_dfa_states or opts.on_oversize == .allow_oversized);

    if (built.outcome == .ok and m.n_states > opts.max_dfa_states and opts.on_oversize == .compile_error) {
        @compileError(std.fmt.comptimePrint(
            "regex \"{s}\": minimized DFA has {d} states, over the " ++
                "Options.max_dfa_states budget of {d}. Raise " ++
                "Options.max_dfa_states (effective only up to the internal " ++
                "ceiling of {d}), set Options.on_oversize = .allow_oversized to " ++
                "bake the larger table anyway, simplify the pattern, or use the " ++
                "runtime Regex.compile.",
            .{ pattern, m.n_states, opts.max_dfa_states, MAX_DFA },
        ));
    }

    // §6 monomorphized literal arm: no DFA table is referenced, so the
    // baked `.rodata` is dead-code-eliminated. Boundaries are identical to
    // the DFA/VM for pure literals & exact literal alternation (Teddy is
    // leftmost, earliest-declared on a tie == leftmost-first).
    if (built.strat == .literal) {
        const seq = built.seq;
        // Build the Teddy automaton once, at comptime — the §6 win is a
        // literal pattern compiling to a prebuilt scan, no per-call setup.
        const teddy = comptime core.buildLiteral(&seq).?;
        return struct {
            pub const has_dfa = true;
            const t = teddy;

            pub fn isMatch(input: []const u8) bool {
                return core.literalIsMatchT(&t, input);
            }

            pub fn find(input: []const u8) ?Match {
                const sp = core.literalFindT(&t, input, 0) orelse return null;
                return wholeMatch(input, sp.start, sp.end);
            }

            pub fn count(input: []const u8) usize {
                var n: usize = 0;
                var pos: usize = 0;
                while (pos <= input.len) {
                    const sp = core.literalFindT(&t, input, pos) orelse break;
                    n += 1;
                    pos = advanceEmpty(sp.start, sp.end);
                }
                return n;
            }

            pub fn findAll(allocator: std.mem.Allocator, input: []const u8) ![]Match {
                var list: std.ArrayList(Match) = .empty;
                errdefer list.deinit(allocator);
                var pos: usize = 0;
                while (pos <= input.len) {
                    const sp = core.literalFindT(&t, input, pos) orelse break;
                    try list.append(allocator, wholeMatch(input, sp.start, sp.end));
                    pos = advanceEmpty(sp.start, sp.end);
                }
                return list.toOwnedSlice(allocator);
            }
        };
    }

    if (use_dfa) {
        const ns = m.n_states;
        const nk = m.n_classes;
        const T = dfa.Dfa(ns, nk);
        const baked: T = comptime blk: {
            var t: T = undefined;
            t.class_of = m.class_of;
            t.start = @intCast(m.start);
            t.anchored_start = m.a_start;
            t.anchored_end = m.a_end;
            var i: usize = 0;
            while (i < ns) : (i += 1) {
                t.accepting[i] = m.accepting[i];
                var k: usize = 0;
                while (k < nk) : (k += 1) t.transitions[i][k] = @intCast(m.trans[i][k]);
                // Padding columns `[nk..Stride)` are never indexed (`class_of`
                // emits only `0..nk`), but must be defined so the baked `.rodata`
                // is fully initialized rather than `undefined`.
                while (k < T.Stride) : (k += 1) t.transitions[i][k] = dfa.DEAD;
            }
            t.start_bytes = m.start_bytes;
            t.n_start_bytes = m.n_start_bytes;
            t.start_byte_set = m.start_byte_set;
            t.start_pf = pf.Prefilter.fromBitset(&m.start_byte_set);
            // (a): carry the necessary-condition prefilters into the baked
            // table so the comptime walk consults them just like the runtime.
            t.required = m.required;
            t.req_lit = m.req_lit;
            break :blk t;
        };
        // (c): bake the planner's literal prefilter. `.reverse_suffix` uses the
        // trailing literal as a Teddy fast-negative before the forward DFA;
        // `.lit_prefix` Teddy-locates the leading literal then verifies anchored
        // with `runFrom` (via the shared `search.litPrefixFind`). Either falls
        // back to the plain DFA when the literal can't be Teddy-compiled — same
        // as the runtime `regex.zig`. The Teddy is built once, at comptime.
        const want_teddy = built.strat == .reverse_suffix or built.strat == .lit_prefix;
        const maybe_teddy: ?pf.Teddy = if (want_teddy) comptime core.buildLiteral(&built.seq) else null;
        const mode: Mode = if (maybe_teddy != null)
            (if (built.strat == .reverse_suffix) Mode.reverse_suffix else Mode.lit_prefix)
        else
            Mode.dfa;
        return struct {
            pub const has_dfa = true;
            const table = baked;
            // Only referenced in the `.reverse_suffix` / `.lit_prefix` switch
            // prongs; for `.dfa` `mode` is comptime-known so those prongs are
            // never analyzed and the `undefined` placeholder is harmless.
            const t: pf.Teddy = maybe_teddy orelse undefined;

            /// Next leftmost span at/after `from`, absolute coords. The single
            /// source of truth `find`/`count`/`findAll` share; the `switch
            /// (mode)` folds to the one strategy at comptime.
            fn nextSpan(input: []const u8, from: usize) ?search.Span {
                return switch (mode) {
                    .dfa => blk: {
                        const r = table.findLeftmost(input[from..]) orelse break :blk null;
                        break :blk .{ .start = from + r.start, .end = from + r.end };
                    },
                    .reverse_suffix => blk: {
                        // Teddy fast-negative gate: no trailing-literal
                        // occurrence at/after `from` ⇒ no match (the DFA then
                        // decides the actual leftmost span).
                        if (core.literalFindT(&t, input, from) == null) break :blk null;
                        const r = table.findLeftmost(input[from..]) orelse break :blk null;
                        break :blk .{ .start = from + r.start, .end = from + r.end };
                    },
                    .lit_prefix => blk: {
                        const r = search.litPrefixFind(&table, &t, input[from..]) orelse break :blk null;
                        break :blk .{ .start = from + r.start, .end = from + r.end };
                    },
                };
            }

            pub fn isMatch(input: []const u8) bool {
                return switch (mode) {
                    .dfa => table.isMatch(input),
                    .reverse_suffix => core.literalIsMatchT(&t, input) and table.isMatch(input),
                    .lit_prefix => search.litPrefixIsMatch(&table, &t, input),
                };
            }

            pub fn find(input: []const u8) ?Match {
                const sp = nextSpan(input, 0) orelse return null;
                return wholeMatch(input, sp.start, sp.end);
            }

            pub fn count(input: []const u8) usize {
                var n: usize = 0;
                var pos: usize = 0;
                while (pos <= input.len) {
                    const sp = nextSpan(input, pos) orelse break;
                    n += 1;
                    pos = advanceEmpty(sp.start, sp.end);
                }
                return n;
            }

            pub fn findAll(allocator: std.mem.Allocator, input: []const u8) ![]Match {
                var list: std.ArrayList(Match) = .empty;
                errdefer list.deinit(allocator);
                var pos: usize = 0;
                while (pos <= input.len) {
                    const sp = nextSpan(input, pos) orelse break;
                    try list.append(allocator, wholeMatch(input, sp.start, sp.end));
                    pos = advanceEmpty(sp.start, sp.end);
                }
                return list.toOwnedSlice(allocator);
            }
        };
    }

    // Unsupported feature: a comptime pattern the DFA path cannot represent is
    // a hard compile error (the comptime path has no runtime fallback — the
    // exploded/oversized cases are already handled above).
    @compileError(std.fmt.comptimePrint(
        "regex \"{s}\": uses a feature the comptime DFA path does not support " ++
            "(captures with submatch extraction, lookaround, backreferences, " ++
            "word boundary / multiline look-assertions, \\p under (?i)). The " ++
            "comptime path has no runtime fallback; use the runtime " ++
            "Regex.compile for these patterns.",
        .{pattern},
    ));
}
