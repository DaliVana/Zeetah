//! `Pattern(src, opts)` — the comptime path of the meta engine, built on the
//! unified `parser`→`hir`→`thompson`→`exec/full_dfa` pipeline. The whole
//! pipeline (parse → HIR → NFA → subset-construct/minimize) runs at compile
//! time and the minimized DFA is monomorphized into a baked `comptime_dfa.Dfa(ns,nk)`
//! in `.rodata`; the planner's `.literal` strategy short-circuits to a
//! comptime Teddy with no DFA table. Same `has_dfa` split / method
//! signatures / `Options` + explosion semantics as the runtime `Regex`;
//! the two are differential-tested in `tests/feat_api.zig`.

const std = @import("std");
const comptime_dfa = @import("exec/comptime_dfa.zig");
const pf = @import("prefilter.zig");
const hir = @import("hir.zig");
const parser = @import("parser.zig");
const thompson = @import("thompson.zig");
const full_dfa = @import("exec/full_dfa.zig");
const onepass = @import("exec/onepass.zig");
const properties = @import("properties.zig");
const planner = @import("planner.zig");
const core = @import("exec/core.zig");
const search = @import("exec/search.zig");
const seq_extract = @import("exec/seq_extract.zig");
const edge_look = @import("exec/edge_look.zig");
const backtrack = @import("exec/backtrack.zig");
const seek_mod = @import("exec/seek.zig");
const class_span = @import("exec/class_span.zig");
const delegate = @import("exec/delegate.zig");

const Match = @import("match.zig").Match;
const Group = @import("match.zig").Group;
const Captures = @import("match.zig").Captures;
const wholeMatch = @import("match.zig").wholeMatch;
const advanceEmpty = @import("match.zig").advanceEmpty;

/// A comptime-known placeholder `Allocator` for the seek/delegate `Plan` fields
/// on the **comptime** path. Those plans bake their DFAs into `.rodata` and
/// never allocate (no `deinit`, no `realloc`, no `locate` path touches the
/// allocator), so the field only needs a well-typed value. Crucially — unlike
/// `std.heap.page_allocator` — this references no OS page-size machinery, so the
/// comptime `Pattern` compiles for **freestanding / bare-metal** targets. On
/// e.g. `thumb-freestanding` (no `page_size_min`), naming `page_allocator` here
/// is a hard `@compileError`, which previously made every seek/delegate-using
/// pattern (`\w+`, atomic groups, required-literal patterns) fail to build for
/// embedded. `alloc` returns null and resize/remap/free are no-ops; if the
/// comptime path ever did allocate through this, it would fail safe rather than
/// touch the OS.
const placeholder_allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = struct {
            fn f(_: *anyopaque, _: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
                return null;
            }
        }.f,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = std.mem.Allocator.noFree,
    },
};

/// The compact, class-width comptime DFA type for a given `full_dfa.Dfa256`
/// value: `comptime_dfa.Dfa(ns, nk)`, whose table is `[ns][⌈nk⌉₂]` `u8`/`u16`
/// cells (see `comptime_dfa.zig`) — not the fixed `[256][256]u16` (~131 KB) of
/// `Dfa256`. `m` is a comptime value, so reading it here costs no `.rodata`.
fn Compressed(comptime m: full_dfa.Dfa256) type {
    return comptime_dfa.Dfa(m.n_states, m.n_classes);
}

/// Compress a comptime `full_dfa.Dfa256` into its `Compressed(m)` form for
/// baking into `.rodata`. Used for the seek and delegate prefilter DFAs on the
/// comptime path: each would otherwise bake a full 131 KB `Dfa256` (the
/// dominant flash cost for backtracker-tier patterns — atomic groups, look-
/// around, back-references — on embedded targets). The main matcher table bakes
/// the same shape inline in the `use_dfa` arm below. Field-for-field identical
/// to that inline bake; the padding columns `[nk..Stride)` are filled with
/// `DEAD` so the baked `.rodata` is fully initialized.
/// Exact-fit compression: bake `m` into `comptime_dfa.Dfa(m.n_states,
/// m.n_classes)`. The single source of truth for turning a `full_dfa.Dfa256`
/// into a baked comptime table — used for the main matcher DFA and (via
/// `compressTo`) the seek / edge-look prefilter DFAs. Thin wrapper over
/// `compressTo` so all bake sites share ONE field-mapping implementation.
fn compress(comptime m: full_dfa.Dfa256) Compressed(m) {
    return compressTo(Compressed(m), m);
}

/// Like `compress`, but into a CALLER-CHOSEN (possibly larger) target type
/// `T = comptime_dfa.Dfa(NS, NK)` with `NS ≥ m.n_states`, `NK ≥ m.n_classes`.
/// Used for delegate islands: a `Pattern` may have several islands of differing
/// minimized dimensions, so they are all baked into one homogeneous `[N]T`
/// array sized to the per-pattern max — letting a single `delegate.Plan` /
/// matcher serve them all while still costing `[NS][NK]` `.rodata` instead of
/// a 131 KB `Dfa256` each. Surplus states/classes are filled with `DEAD` (never
/// reached: each island's own `class_of` emits only its `0..n_classes`, and its
/// live states are `0..n_states`). This is the ONE place the `Dfa256`→baked
/// field mapping lives; the decompressors (`comptime_dfa.Dfa.runFrom` /
/// `findLeftmost` / `step`) read those fields back identically.
fn compressTo(comptime T: type, comptime m: full_dfa.Dfa256) T {
    @setEvalBranchQuota(4_000_000);
    var t: T = undefined;
    t.class_of = m.class_of;
    t.start = @intCast(m.start);
    t.anchored_start = m.a_start;
    t.anchored_end = m.a_end;
    var i: usize = 0;
    while (i < T.NumStates) : (i += 1) {
        t.accepting[i] = i < m.n_states and m.accepting[i];
        var k: usize = 0;
        while (k < T.Stride) : (k += 1) {
            t.transitions[i][k] = if (i < m.n_states and k < m.n_classes)
                @intCast(m.trans[i][k])
            else
                comptime_dfa.DEAD;
        }
    }
    t.start_bytes = m.start_bytes;
    t.n_start_bytes = m.n_start_bytes;
    t.start_byte_set = m.start_byte_set;
    t.start_pf = pf.Prefilter.fromBitset(&m.start_byte_set);
    t.required = m.required;
    t.req_lit = m.req_lit;
    return t;
}

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
    /// Multiline mode: `^`/`$` match at line boundaries (`start_line`/`end_line`
    /// looks) instead of only start/end-of-text. Equivalent to a leading inline
    /// `(?m)`. Such patterns route to the comptime tree-backtracker (looks can't
    /// fold into the DFA), same as `(?m)…` does. Mirrors the runtime
    /// `CompileFlags.multiline`.
    multiline: bool = false,
};

const MAX_NFA = thompson.MAX_NFA;
const MAX_EDGES = thompson.MAX_EDGES;
const MAX_DFA: usize = 256;

const Outcome = enum { ok, unsupported, exploded, invalid };

/// §6/(c) monomorphization: which planner strategy the baked matcher emits.
/// `.literal` skips the DFA table entirely (Teddy only); the other three bake
/// the DFA and differ only in the per-position prefilter wrapped around it.
const Strat = enum { literal, reverse_suffix, lit_prefix, dfa, backtrack, edge_look, boundary_lits };

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
    /// `.backtrack` arm only: the parsed comptime HIR (the oversized `HIR_CAP`
    /// store) plus its capture metadata. `Pattern` copies the live prefix into
    /// an exact-sized `Hir(node_count)` before baking, so this 2048-slot
    /// intermediate is comptime-only and never reaches `.rodata`; its tail is
    /// `undefined` (parser writes only the live prefix) and is never read.
    hir: hir.Hir(HIR_CAP) = undefined,
    /// Capture-group count + `(?<name>)` names, from `parser.scanGroups` over
    /// the source (NOT the HIR) — the same call the runtime `.backtrack` path
    /// uses, so the two agree by construction (incl. groups inside a lookaround,
    /// which are HIR-non-capturing but still reserve a numbered, named slot).
    n_groups: usize = 0,
    gnames: [hir.MAX_GROUPS + 1]?[]const u8 = [_]?[]const u8{null} ** (hir.MAX_GROUPS + 1),
    /// `.edge_look` arm: verify spec for the peeled trailing width-1 look.
    /// `dfa` holds the regular core's DFA; this is the O(1) edge check.
    el_spec: edge_look.Spec = .{ .set = [_]u8{0} ** 32, .behind = false, .neg = false },
    /// `.boundary_lits` arm: the `\b(?:lit|…)\b` literal set. Comptime-only —
    /// the Aho-Corasick automaton is rebuilt + node-trimmed in `Pattern` (not
    /// stored here) so `Built` stays small. Empty (`n == 0`) for other strats.
    bl: seq_extract.BoundaryLits = .{},
    /// `.backtrack` arm: a regular over-approximation DFA used as the seek
    /// prefilter (skip proven-dead prefixes). Built at comptime by the SAME
    /// zero-allocator `full_dfa.compute` the regular arm uses, over a relaxed
    /// HIR (`look`/`backref`→ε, `atomic` cut dropped). `seek_ok` gates it:
    /// false ⇒ no usable prefilter (anchored / nullable / build failure / no
    /// non-regular constraint to exploit), and the backtracker falls back to
    /// its plain per-byte scan (still correct). Mirrors runtime `seek.build`'s
    /// Dfa256 path; the cheaper `lb_byte` memchr seek is layered on top of this
    /// in `Pattern` (it takes precedence when present, exactly as runtime does).
    seek_dfa: full_dfa.Dfa256 = undefined,
    seek_ok: bool = false,
};

/// Regular OVER-APPROXIMATION DFA for the `.backtrack` seek prefilter, or
/// `null` when none is usable/sound (⇒ the backtracker uses its plain per-byte
/// scan). Replaces every non-regular / zero-width node
/// (`look`/`look_around`/`backref`→ε, `atomic` drops its cut): the relaxation
/// only *enlarges* the language, so the leftmost position the approx DFA can
/// begin a match is `≤` any real-match start — skipping the proven-dead prefix
/// never drops a match (soundness). Built with the SAME zero-allocator
/// `thompson.build`/`full_dfa.compute` the regular arm uses, so it bakes a
/// `Dfa256` value at comptime — the heap-free analogue of runtime
/// `seek.build`'s Dfa256 path (same guard set):
///   * `lazy && anchored_end` — the over-approx inherits the lazy-vs-`$`
///     accept-cut flaw ⇒ `locate` could skip past the true start (unsound);
///   * anchored — nothing to skip to;
///   * nullable approximation (start state accepts) — matches everywhere ⇒
///     can never skip;
///   * build failure / DFA blow-up.
fn overApproxDfa(h: *const hir.Hir(HIR_CAP)) ?full_dfa.Dfa256 {
    @setEvalBranchQuota(8_000_000); // deep alternations recurse clone/build
    if (h.saw_lazy and h.anchored_end) return null;
    var oh = hir.Hir(HIR_CAP).initComptime();
    oh.anchored_start = h.anchored_start;
    oh.anchored_end = h.anchored_end;
    oh.saw_lazy = h.saw_lazy;
    oh.root = hir.cloneSubtree(HIR_CAP, HIR_CAP, &oh, undefined, h, h.root, true) catch return null;
    // Non-selective relaxation (`Σ*`-shaped, e.g. `.{8,}`): a match can begin
    // anywhere, so this prefilter could never skip — baking and running it is
    // pure overhead. Mirrors the runtime `seek.build` guard (shared helper).
    if (properties.nonSelectiveApprox(HIR_CAP, &oh, oh.root)) return null;
    var onfa = thompson.build(HIR_CAP, &oh) catch return null;
    var od = full_dfa.compute(HIR_CAP, &onfa, oh.anchored_start, oh.anchored_end);
    if (od.outcome != .ok) return null;
    if (od.a_start) return null; // anchored ⇒ nothing to skip to
    if (od.start < od.n_states and od.accepting[od.start]) return null; // nullable
    // Necessary-byte memchr fast-negative (same as the runtime seek DFA).
    od.required = seq_extract.requiredByte(HIR_CAP, &oh);
    return od;
}

/// Comptime analogue of `seek.build`'s `lb_set` branch: a leading positive
/// multi-byte look-behind `(?<=[?&])` ⇒ its class as `Ranges`, baked into the
/// seek so `locate` runs the SIMD class search. `null` (⇒ fall through to the
/// over-approx DFA) when there is no such look-behind or the class needs >16
/// ranges. The single-byte case routes through `requiredLeadingLookbehindByte`.
fn lbSet(comptime cap: ?usize, h: *const hir.Hir(cap)) ?class_span.Ranges {
    const bm = seq_extract.requiredLeadingLookbehindSet(cap, h) orelse return null;
    return class_span.Ranges.fromBitmap(bm);
}

/// Max delegated islands baked per comptime `.backtrack` pattern (mirrors
/// `delegate.MAX_ISLANDS`; surplus islands just stay on the tree-walk path).
const MAX_DELEGATE: usize = 32;

/// Result of the comptime delegate scan: `n` regular-island anchored DFAs
/// (`dfas[0..n]`) rooted at HIR refs `refs[0..n]`. Baked as a `Pattern`-struct
/// const so each `&dfas[i]` is a stable `.rodata` pointer the baked
/// `delegate.Plan` can hold (mirroring the runtime heap `Plan`, but value-baked).
const DelegateBake = struct {
    refs: [MAX_DELEGATE]hir.NodeRef = [_]hir.NodeRef{hir.none} ** MAX_DELEGATE,
    dfas: [MAX_DELEGATE]full_dfa.Dfa256 = undefined,
    n: usize = 0,
};

/// Comptime analogue of `delegate.build`: find concat-internal regular islands
/// (the `.a` spine child that is a delegatable, unbounded-repetition,
/// ≥1-min-length subtree) and compile each to an anchored `Dfa256` with the
/// SAME zero-allocator `thompson.build`/`full_dfa.compute` the regular arm uses
/// — so the island DFAs bake into `.rodata` (no heap `Plan`). The classifier
/// (`delegate.delegatable`/`hasUnboundedRep`/`minLen`) is shared verbatim with
/// the runtime, so the soundness argument (greedy/no-alt/no-cap island ⇒ its
/// unique greedy-maximal parse == the DFA's leftmost-longest end == the
/// tree-walker's first attempt) holds identically. Island refs are in the baked
/// HIR's numbering (the bake copies nodes 1:1), so the backtracker's
/// `dfaFor(nd.a)` lookup matches. `n == 0` ⇒ no delegation, pure tree-walk.
fn delegateIslands(comptime cap: ?usize, h: *const hir.Hir(cap)) DelegateBake {
    @setEvalBranchQuota(8_000_000); // deep alternations recurse the classifiers
    var out = DelegateBake{};
    if (h.root == hir.none) return out;
    var ref: hir.NodeRef = 0;
    const n_nodes: hir.NodeRef = @intCast(h.node_count);
    while (ref < n_nodes and out.n < MAX_DELEGATE) : (ref += 1) {
        const nd = h.node(ref);
        if (nd.tag != .concat) continue;
        if (!delegate.delegatable(cap, h, nd.a)) continue;
        if (delegate.minLen(cap, h, nd.a) < 1) continue; // nullable ⇒ no work saved
        if (!delegate.hasUnboundedRep(cap, h, nd.a)) continue; // fixed run ⇒ not worth a DFA
        // Extract the island into its own anchored DFA (faithful clone — the
        // island is already regular, so relax=false). Build into a same-cap
        // comptime store with the zero-allocator pipeline; `oh` only needs to
        // hold the island, but sizing it at `HIR_CAP` keeps the type uniform.
        var oh = hir.Hir(HIR_CAP).initComptime();
        oh.root = hir.cloneSubtree(HIR_CAP, cap, &oh, undefined, h, nd.a, false) catch continue;
        var onfa = thompson.build(HIR_CAP, &oh) catch continue;
        const d = full_dfa.compute(HIR_CAP, &onfa, true, false); // anchored start
        if (d.outcome != .ok) continue;
        out.refs[out.n] = nd.a;
        out.dfas[out.n] = d;
        out.n += 1;
    }
    return out;
}

/// Run the whole pipeline at comptime: parse -> Hir -> Thompson NFA ->
/// subset construction + minimization. `unsupported` -> runtime fallback;
/// `exploded` -> the explosion guard; `ok` -> bake the DFA.
fn buildAll(comptime pattern: []const u8, comptime ci: bool, comptime ml: bool) Built {
    @setEvalBranchQuota(8_000_000);
    var h = hir.Hir(HIR_CAP).initComptime();
    parser.parse(HIR_CAP, &h, undefined, pattern, .{ .ci = ci, .multiline = ml }) catch |e| {
        return .{
            .dfa = full_dfa.emptyDfa256(.ok),
            .outcome = switch (e) {
                hir.Error.Unsupported => .unsupported,
                hir.Error.TooComplex => .exploded,
                // Malformed syntax. The comptime path has no runtime fallback,
                // so it becomes a hard `@compileError` in `Pattern` (distinct
                // message from `.unsupported`). Previously this arm was absent
                // and the switch was only exhaustive-checked when a pattern's
                // comptime parse actually failed — latent until the first such
                // pattern (e.g. one whose `\b` hits the comptime look reject).
                hir.Error.Invalid => .invalid,
            },
        };
    };
    // Route to the comptime tree backtracker BEFORE `thompson.build`. This
    // covers two groups the DFA path cannot represent:
    //   * `requires_backtracking` — backref / lookaround / atomic / possessive /
    //     `lazy && anchored_end` (mirrors the runtime `regex.zig` dispatch).
    //   * `has_look` — `\b \B`, `(?m)^ $`, `\A \z \Z`: conditional-epsilon
    //     look-assertions the DFA can't fold. The runtime sends these to a
    //     SEPARATE `.bt_look` engine (NFA + visited bitset); the comptime path
    //     has no `.bt_look`, but its baked tree-backtracker already evaluates
    //     `.look` via `cc.lookHolds`, so it handles them on the same `.backtrack`
    //     arm. (This `or props.has_look` is the comptime-only widening; the
    //     shared `properties.requires_backtracking` deliberately omits it so the
    //     runtime keeps its `.bt_look` routing — see properties.zig.)
    // `analyze` is pure and only reads the HIR, so computing it here (rather than
    // after the DFA build) is free and lets the regular path fall through.
    const props = properties.analyze(HIR_CAP, &h);

    // Capture metadata, computed once for EVERY `.ok` strat (not just
    // `.backtrack`): a regular-with-captures pattern (e.g. `(\d{4})-(\d{2})`)
    // routes to the DFA arm but still needs `n_groups`/`gnames` + the baked HIR
    // so the DFA arm can offer zero-alloc `findCaptures` (it bakes a capture-only
    // `BacktrackerG` over this HIR; the DFA still serves `find`/`count`). Group
    // count + names come from `parser.scanGroups` over the source — the single
    // source of truth shared with the runtime, so the two agree by construction.
    var gnames = [_]?[]const u8{null} ** (hir.MAX_GROUPS + 1);
    const ng = parser.scanGroups(pattern, &gnames);

    // Edge-look peel: `concat(regular_greedy_core, trailing_width1_look)` bakes
    // the core's DFA + an O(1) edge verify instead of the comptime tree
    // backtracker (the comptime peer of the runtime `.dfa_edge_look`). Shares
    // `edge_look.recognize`/`nextFrom` with the runtime path ⇒ identical
    // matches. Capture-free only (`ng == 0`); restore `h.root` before returning
    // so the baked `.hir` is the whole pattern.
    if (ng == 0) {
        if (edge_look.recognize(HIR_CAP, &h)) |rec| {
            const saved_root = h.root;
            h.root = rec.core;
            if (thompson.build(HIR_CAP, &h)) |nfa_core| {
                var nfa_c = nfa_core;
                var cd = full_dfa.compute(HIR_CAP, &nfa_c, h.anchored_start, false);
                if (cd.outcome == .ok) {
                    cd.required = seq_extract.requiredByte(HIR_CAP, &h);
                    h.root = saved_root;
                    return .{ .dfa = cd, .outcome = .ok, .strat = .edge_look, .el_spec = rec.spec, .hir = h, .n_groups = ng, .gnames = gnames };
                }
            } else |_| {}
            h.root = saved_root;
        }
    }

    // `\b(?:lit|lit|…)\b` keyword alternation: regular, but a big literal set
    // blows `MAX_NFA` so the DFA path can't build it. The runtime routes this to
    // its `.boundary_lits` engine (Aho-Corasick locate + O(1) `\b` verify); the
    // comptime path does the same, baking a node-trimmed AC into `.rodata`. Both
    // building blocks (`boundaryLiterals` + `AhoCorasick.build`) are zero-allocator
    // and comptime-evaluable. `ng == 0` only (the engine reports no submatches,
    // mirroring the runtime gate). Checked BEFORE the backtracker fallback — the
    // bracketing `\b`s would otherwise route here via `has_look`.
    if (ng == 0) {
        if (seq_extract.boundaryLiterals(HIR_CAP, &h)) |bl| {
            var needles: [seq_extract.MAX_BL][]const u8 = undefined;
            for (0..bl.n) |i| needles[i] = bl.alt(i);
            // Confirm the AC fits the build budget here so routing is decided now;
            // `Pattern` rebuilds + trims it (kept out of `Built` to stay small).
            if (pf.AhoCorasick.build(needles[0..bl.n]) != null) {
                return .{
                    .dfa = full_dfa.emptyDfa256(.ok),
                    .outcome = .ok,
                    .strat = .boundary_lits,
                    .hir = h,
                    .n_groups = ng,
                    .gnames = gnames,
                    .bl = bl,
                };
            }
        }
    }

    if (props.requires_backtracking or props.has_look) {
        // Comptime seek prefilter: a regular OVER-APPROXIMATION DFA (built by
        // `overApproxDfa` below — see its doc for the soundness/guards). When
        // present it bakes into `.rodata` and the backtracker `memchr`s/DFA-skips
        // proven-dead prefixes; when absent the backtracker's plain per-byte scan
        // is used (still correct).
        var built: Built = .{
            .dfa = full_dfa.emptyDfa256(.ok),
            .outcome = .ok,
            .strat = .backtrack,
            .hir = h,
            .n_groups = ng,
            .gnames = gnames,
        };
        if (overApproxDfa(&h)) |od| {
            built.seek_dfa = od;
            built.seek_ok = true;
        }
        return built;
    }

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
    const strat = planner.plan(props, .{ .case_insensitive = ci });
    // Carry the HIR + capture metadata into every DFA-tier `Built` too, so the
    // returned `Pattern` can bake a zero-alloc capture path (`captures`) over the
    // SAME HIR when `ng > 0`. The DFA still serves `find`/`isMatch`/`count`;
    // captures route through a baked `BacktrackerG`. That capture backtracker
    // needs its OWN seek prefilter — without it, the unanchored capture scan over
    // a `(.*)`-style pattern blows the per-call anti-ReDoS step budget hunting for
    // the next match and bails early (e.g. `log_parse` stalled at 55 of ~600
    // matches). So build the over-approximation seek here whenever the pattern
    // has groups (cheap; gated on `ng > 0` so group-less patterns pay nothing).
    var seek_dfa: full_dfa.Dfa256 = undefined;
    var seek_ok = false;
    if (ng > 0) {
        if (overApproxDfa(&h)) |od| {
            seek_dfa = od;
            seek_ok = true;
        }
    }
    return switch (planner.resolve(strat, h.anchored_start)) {
        .literal => |seq| .{ .dfa = d, .outcome = .ok, .strat = .literal, .seq = seq, .hir = h, .n_groups = ng, .gnames = gnames, .seek_dfa = seek_dfa, .seek_ok = seek_ok },
        .reverse_suffix => |sfx| .{ .dfa = d, .outcome = .ok, .strat = .reverse_suffix, .seq = sfx, .hir = h, .n_groups = ng, .gnames = gnames, .seek_dfa = seek_dfa, .seek_ok = seek_ok },
        .lit_prefix => |pp| .{ .dfa = d, .outcome = .ok, .strat = .lit_prefix, .seq = pp, .hir = h, .n_groups = ng, .gnames = gnames, .seek_dfa = seek_dfa, .seek_ok = seek_ok },
        // `.core`, plus the `.backtrack` sentinel (never reached — non-regular
        // patterns `@compileError` upstream): plain baked DFA.
        .dfa, .backtrack => .{ .dfa = d, .outcome = .ok, .strat = .dfa, .hir = h, .n_groups = ng, .gnames = gnames, .seek_dfa = seek_dfa, .seek_ok = seek_ok },
    };
}

/// Comptime predicate: does `Pattern(pattern, …)` compile (vs. hit one of its
/// `@compileError`s)? Runs the same `buildAll` and inspects `outcome`/strat
/// without instantiating the type, so callers can branch at comptime instead of
/// failing the build. `.unsupported`/`.exploded`/`.invalid` ⇒ false; `.ok`
/// (DFA / literal / backtrack arms) ⇒ true. (A `.dfa` arm over the soft
/// `max_dfa_states` budget can still be a `@compileError` in `Pattern` under the
/// default `on_oversize = .compile_error`; this predicate reports build-ability
/// at the generous benchmark budget, so pass matching opts when it matters.)
/// `ci` = case_insensitive, `ml` = multiline (same as `Options`).
pub fn compilesAtComptime(comptime pattern: []const u8, comptime ci: bool, comptime ml: bool) bool {
    const built = comptime buildAll(pattern, ci, ml);
    return built.outcome == .ok;
}

/// Whole-match verbs shared by all three `Pattern` arms (literal / DFA /
/// backtrack). Parameterized by the arm's strategy-specific leftmost scan
/// `nextSpanFrom(input, from) ?search.Span`; this layer builds the
/// **allocation-free, lazy** verbs on top — a comptime peer of the runtime
/// `MatchIterator` / `starts_with` / `split`. Each arm re-exports the members it
/// wants (`pub const iterator = V.iterator;` …) since Zig 0.16 has no
/// `usingnamespace`. Nothing here allocates; iterators are values driven with
/// `while (it.next()) |m|`.
fn WholeMatchVerbs(comptime nextSpanFrom: fn ([]const u8, usize) ?search.Span) type {
    return struct {
        /// Lazy non-overlapping match iterator — the zero-alloc comptime peer of
        /// `Regex.iterator`. Computes one match at a time (so `break`-ing early
        /// costs nothing and memory is O(1) regardless of match count), using the
        /// same `advanceEmpty` non-overlapping rule as `findAll`/`count`.
        pub const Iterator = struct {
            input: []const u8,
            pos: usize = 0,
            pub fn next(it: *Iterator) ?Match {
                if (it.pos > it.input.len) return null;
                const sp = nextSpanFrom(it.input, it.pos) orelse {
                    it.pos = it.input.len + 1; // exhausted
                    return null;
                };
                it.pos = advanceEmpty(sp.start, sp.end);
                return wholeMatch(it.input, sp.start, sp.end);
            }
        };
        pub fn iterator(input: []const u8) Iterator {
            return .{ .input = input };
        }

        /// True iff a match begins at offset 0 (anchored-prefix test), without
        /// writing `^…` into the pattern — the comptime peer of a runtime
        /// `starts_with`. Allocation-free.
        pub fn startsWith(input: []const u8) bool {
            const sp = nextSpanFrom(input, 0) orelse return false;
            return sp.start == 0;
        }

        /// Lazy split iterator: yields the substrings of `input` BETWEEN
        /// successive (non-overlapping) matches — the zero-alloc comptime peer of
        /// `Regex.split`. Each `next()` returns the next field (a slice aliasing
        /// `input`); after the last match it yields the trailing remainder, then
        /// `null`. A zero-width match advances one byte (shared `advanceEmpty`
        /// rule) so the walk always terminates. Empty fields are yielded (e.g.
        /// `,,` over `","` gives an empty middle field), matching the runtime
        /// `split`'s semantics.
        pub const SplitIterator = struct {
            input: []const u8,
            pos: usize = 0, // start of the current (pending) field
            scan: usize = 0, // where the next match search resumes
            done: bool = false,
            pub fn next(it: *SplitIterator) ?[]const u8 {
                if (it.done) return null;
                while (it.scan <= it.input.len) {
                    const sp = nextSpanFrom(it.input, it.scan) orelse break;
                    const adv = advanceEmpty(sp.start, sp.end);
                    // A zero-width match that doesn't advance the field start
                    // produces no separator here; keep scanning. Otherwise the
                    // field is `[pos, sp.start)` and the next field starts at the
                    // match end.
                    if (sp.end == sp.start) {
                        // zero-width separator: skip it, do not split (matches the
                        // common `split` convention of not emitting empties for
                        // empty matches at the cursor); advance the scan only.
                        if (adv > it.input.len) break;
                        it.scan = adv;
                        continue;
                    }
                    const field = it.input[it.pos..sp.start];
                    it.pos = sp.end;
                    it.scan = adv;
                    return field;
                }
                it.done = true;
                return it.input[it.pos..]; // trailing remainder
            }
        };
        pub fn splitIterator(input: []const u8) SplitIterator {
            return .{ .input = input };
        }

        // ── Whole-match eager verbs (the `nextSpanFrom`-driven scaffold every
        // arm shares) ──. `find`/`count`/`findAll` are identical across all arms,
        // so they live here once; an arm re-exports them (`pub const find =
        // V.find;`). `isMatch` is the GENERIC default (run a leftmost search,
        // discard) — arms with a cheaper existence check (literal Teddy / DFA
        // `table.isMatch` / edge-look) define their own `isMatch` instead of
        // re-exporting this one.
        pub fn isMatch(input: []const u8) bool {
            return nextSpanFrom(input, 0) != null;
        }

        pub fn find(input: []const u8) ?Match {
            const sp = nextSpanFrom(input, 0) orelse return null;
            return wholeMatch(input, sp.start, sp.end);
        }

        pub fn count(input: []const u8) usize {
            var n: usize = 0;
            var pos: usize = 0;
            while (pos <= input.len) {
                const sp = nextSpanFrom(input, pos) orelse break;
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
                const sp = nextSpanFrom(input, pos) orelse break;
                try list.append(allocator, wholeMatch(input, sp.start, sp.end));
                pos = advanceEmpty(sp.start, sp.end);
            }
            return list.toOwnedSlice(allocator);
        }
    };
}

/// Zero-allocation capture support, re-exported by every arm (`pub const
/// captures = C.captures;` …). It bakes a capture-only
/// tree-backtracker over the SAME baked HIR (`built.hir`, trimmed to exact node
/// count) — independent of how the arm scans for `find` (a regular pattern's
/// DFA arm still serves `find`/`count` from its DFA; captures route here because
/// the DFA is capture-transparent). The result is a `Captures(ng, gnames)`
/// value: groups live inline, **no allocator**. Slots come back absolute from
/// `runFrom` over the full input (so look-assertions see true context).
fn CaptureSupport(comptime built: Built) type {
    const src_h = built.hir;
    const NN = src_h.node_count;
    const NG = built.n_groups;
    const gnames_full = built.gnames;
    // Exact-size `gnames` for the `Captures` type parameter (`[NG+1]`).
    const gnames: [NG + 1]?[]const u8 = blk: {
        var g: [NG + 1]?[]const u8 = undefined;
        for (0..NG + 1) |i| g[i] = gnames_full[i];
        break :blk g;
    };
    const BH = hir.Hir(NN);
    const baked: BH = comptime blk: {
        var t = BH.initComptime();
        t.node_count = NN;
        t.set_count = src_h.set_count;
        t.root = src_h.root;
        t.anchored_start = src_h.anchored_start;
        t.anchored_end = src_h.anchored_end;
        t.saw_lazy = src_h.saw_lazy;
        for (0..NN) |i| t.nodes[i] = src_h.nodes[i];
        for (0..src_h.set_count) |s| t.sets[s] = src_h.sets[s];
        for (src_h.set_count..NN) |s| t.sets[s] = [_]u8{0} ** 32;
        break :blk t;
    };
    const BT = backtrack.BacktrackerG(NN);

    // ── One-pass capture fast path (mirrors the runtime `op_onepass`) ──
    // For a REGULAR capture pattern that is "one-pass" (deterministic ε-closure,
    // no overlapping consumes — `onepass.isOnePassNfa`), captures can be filled
    // by a single O(n·m) deterministic NFA walk with NO backtracking and NO step
    // budget — exactly how the runtime avoids the tree-backtracker for these. The
    // tree backtracker is budget-bounded and, on a `(.*)`-over-long-line pattern
    // like `log_parse`, would hit that budget and bail; onepass does not. We bake
    // the NFA (built at comptime from the same HIR) + a `Dfa256` (for the O(n)
    // span the fill needs) when one-pass; otherwise the path is comptime-dead and
    // `capturesFrom` uses the tree backtracker (the only option for non-regular
    // patterns — look/backref aren't one-pass anyway, by construction).
    // Build the NFA at comptime; `built` flag records whether the build
    // succeeded (a `.backtrack`-strat HIR with backref/look/atomic would error in
    // `thompson.build` — those are never one-pass, so `op_ok` stays false).
    const op_built: struct { nfa: thompson.Nfa(NN), ok: bool } = comptime blk: {
        const n = thompson.build(NN, &baked) catch break :blk .{ .nfa = undefined, .ok = false };
        break :blk .{ .nfa = n, .ok = true };
    };
    const op_nfa = op_built.nfa;
    const op_ok: bool = comptime (NG > 0 and op_built.ok and onepass.isOnePassNfa(NN, &op_nfa));
    const op_dfa: full_dfa.Dfa256 = if (op_ok) comptime blk: {
        var n = op_nfa;
        break :blk full_dfa.compute(NN, &n, baked.anchored_start, baked.anchored_end);
    } else undefined;
    const op_dfa_usable = op_ok and op_dfa.outcome == .ok;

    return struct {
        pub const Caps = Captures(NG, gnames);
        const cap_h = baked;
        const nfa = op_nfa;
        /// One-pass span DFA, baked COMPRESSED (`compress`) so it costs `[ns][nk]`
        /// `.rodata` instead of a full 131 KB `Dfa256` — the same trim the
        /// `cap_seek_cdfa` / main-DFA / edge-look / seek bakes already use. `void`
        /// when the one-pass path is unavailable (then `capturesFrom`'s reference
        /// is comptime-dead). Its `findLeftmost` is differential-pinned to the
        /// `core.findLeftmost(&Dfa256, …)` it replaces (exact-fit compression).
        const cdfa = if (op_dfa_usable) compress(op_dfa) else {};

        /// Seek prefilter for the (fallback) capture backtracker — the SAME
        /// `lb_byte` / compressed over-approximation-DFA layering the whole-match
        /// `.backtrack` arm uses (see `bt_seek`). Only consulted when the
        /// one-pass path is unavailable (non-regular patterns). The DFA is baked
        /// compressed (`compress`) and fed type-erased via `seek.Cdfa`, so it
        /// costs `[ns][nk]` `.rodata` rather than a 131 KB `Dfa256`.
        const cap_seek_cdfa = if (built.seek_ok) compress(built.seek_dfa) else {};
        const cap_seek: ?seek_mod.Seek = if (seq_extract.requiredLeadingLookbehindByte(NN, &baked)) |b|
            .{ .allocator = placeholder_allocator, .lb_byte = b }
        else if (lbSet(NN, &baked)) |r|
            .{ .allocator = placeholder_allocator, .lb_set = r }
        else if (built.seek_ok)
            .{
                .allocator = placeholder_allocator,
                .cdfa = .{
                    .ptr = &cap_seek_cdfa,
                    .locate_fn = struct {
                        fn f(p: *const anyopaque, input: []const u8, from: usize) ?usize {
                            const d: *const @TypeOf(cap_seek_cdfa) = @ptrCast(@alignCast(p));
                            const sp = d.findLeftmost(input[from..]) orelse return null;
                            return from + sp.start;
                        }
                    }.f,
                },
            }
        else
            null;
        inline fn capSeekPtr() ?*const seek_mod.Seek {
            return if (cap_seek) |*sv| sv else null;
        }

        /// Materialize a `Caps` from filled `slots` (`slots[0..2]` = whole span).
        fn slotsToCaps(input: []const u8, slots: []const i32) Caps {
            var caps: Caps = .{ .groups = undefined };
            caps.groups[0] = .{ .slice = input[@intCast(slots[0])..@intCast(slots[1])], .start = @intCast(slots[0]), .end = @intCast(slots[1]), .name = null };
            inline for (1..NG + 1) |g| {
                const s = slots[2 * g];
                const e = slots[2 * g + 1];
                caps.groups[g] = if (s >= 0 and e >= 0 and s <= e)
                    .{ .slice = input[@intCast(s)..@intCast(e)], .start = @intCast(s), .end = @intCast(e), .name = gnames[g] }
                else
                    null;
            }
            return caps;
        }

        /// Leftmost capture-bearing match at/after absolute `from`, into an
        /// inline `Captures` — **no allocator**. One-pass patterns take the O(n)
        /// DFA-span + `onepass.fill` path (no backtracking, no step budget);
        /// everything else uses the tree backtracker. `null` if no match (or, on
        /// the backtracker path only, the step budget is exceeded — the no-error
        /// comptime API can't surface that; the runtime maps it to
        /// `MatchBudgetExceeded`).
        pub fn capturesFrom(input: []const u8, from: usize) ?Caps {
            var slots: [2 * (hir.MAX_GROUPS + 1)]i32 = undefined;
            const nslots = 2 * (NG + 1);
            if (comptime op_dfa_usable) {
                // O(n) span from the baked (compressed) DFA, then a single fill.
                const r = cdfa.findLeftmost(input[from..]) orelse return null;
                const span: onepass.Span = .{ .start = from + r.start, .end = from + r.end };
                @memset(slots[0..nslots], -1);
                slots[0] = @intCast(span.start);
                slots[1] = @intCast(span.end);
                if (onepass.fill(NN, &nfa, input, span, slots[0..nslots]))
                    return slotsToCaps(input, slots[0..nslots]);
                // mis-gated (should not happen for op_ok); fall through to bt.
            }
            var bt = BT.init(&cap_h, cap_h.anchored_start, cap_h.anchored_end, NG, capSeekPtr(), null);
            const sp = (bt.runFrom(input, from, slots[0..nslots]) catch return null) orelse return null;
            slots[0] = @intCast(sp.start);
            slots[1] = @intCast(sp.end);
            return slotsToCaps(input, slots[0..nslots]);
        }

        /// Leftmost capture-bearing match — the **zero-allocation** comptime peer
        /// of the runtime `Regex.captures`. `find` returns only the whole match
        /// (a `Match`); this returns every submatch inline (a `Captures`). Use
        /// `c.get(1)` / `c.getName("year")`. No allocator, no `deinit`.
        pub fn captures(input: []const u8) ?Caps {
            return capturesFrom(input, 0);
        }

        /// Lazy non-overlapping capture iterator — zero-alloc peer of
        /// `Regex.capturesIterator`. Yields a `Captures` per match. Prefer this
        /// (or `captures` in a loop) over `capturesAll` to stay fully alloc-free.
        pub const CapturesIterator = struct {
            input: []const u8,
            pos: usize = 0,
            pub fn next(it: *CapturesIterator) ?Caps {
                if (it.pos > it.input.len) return null;
                const c = capturesFrom(it.input, it.pos) orelse {
                    it.pos = it.input.len + 1;
                    return null;
                };
                const m0 = c.groups[0].?;
                it.pos = advanceEmpty(m0.start, m0.end);
                return c;
            }
        };
        pub fn capturesIterator(input: []const u8) CapturesIterator {
            return .{ .input = input };
        }

        /// Eager: every non-overlapping match's `Captures` in one owned slice.
        /// The ONLY allocation is the `[]Captures` slice itself — each element's
        /// groups are inline (no per-match heap allocation, unlike the runtime
        /// `Regex.capturesAll` which owns a `[]?Group` per `Match`). Free with a
        /// single `allocator.free(result)`; no per-element `deinit`.
        pub fn capturesAll(allocator: std.mem.Allocator, input: []const u8) ![]Caps {
            var list: std.ArrayList(Caps) = .empty;
            errdefer list.deinit(allocator);
            var pos: usize = 0;
            while (pos <= input.len) {
                const c = capturesFrom(input, pos) orelse break;
                const m0 = c.groups[0].?;
                try list.append(allocator, c);
                pos = advanceEmpty(m0.start, m0.end);
            }
            return list.toOwnedSlice(allocator);
        }
    };
}

/// Build a regex from a comptime-known `pattern`. See the old `ComptimeRegex`
/// doc comment — the `has_dfa`-dependent signatures and `Match` ownership
/// contract are preserved exactly so callers/tests need no changes.
pub fn Pattern(comptime pattern: []const u8, comptime opts: Options) type {
    const built = comptime buildAll(pattern, opts.case_insensitive, opts.multiline);
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

    // Malformed pattern (parser `Error.Invalid`): a hard compile error, since
    // the comptime path has no runtime fallback. Distinct from `.unsupported`
    // (well-formed but unrepresentable) so the message points at syntax.
    if (built.outcome == .invalid) {
        @compileError(std.fmt.comptimePrint(
            "regex \"{s}\": malformed pattern (invalid syntax). Fix the pattern, " ++
                "or use the runtime Regex.compile for a typed InvalidPattern error.",
            .{pattern},
        ));
    }

    // Non-regular tier: backref / lookaround / atomic / possessive / `lazy$`
    // run on the comptime-baked tree backtracker — no DFA table (`has_dfa =
    // false`). Handled before the DFA-state-budget logic below: the empty
    // placeholder `built.dfa` would otherwise look "small enough" and divert
    // into the `use_dfa` arm. The HIR is trimmed to its exact node count here
    // (mirroring how the DFA arm sizes `Dfa(ns,nk)`) so a tiny pattern bakes a
    // tiny `.rodata` table rather than the 2048-slot `HIR_CAP` store.
    if (built.strat == .backtrack) {
        const src_h = built.hir;
        const NN = src_h.node_count;
        const NG = built.n_groups;
        const BH = hir.Hir(NN);
        const baked: BH = comptime blk: {
            var t = BH.initComptime();
            t.node_count = NN;
            t.set_count = src_h.set_count;
            t.root = src_h.root;
            t.anchored_start = src_h.anchored_start;
            t.anchored_end = src_h.anchored_end;
            t.saw_lazy = src_h.saw_lazy;
            for (0..NN) |i| t.nodes[i] = src_h.nodes[i];
            for (0..src_h.set_count) |s| t.sets[s] = src_h.sets[s];
            // Pad unused set slots so the baked `.rodata` is fully defined
            // (#sets ≤ #nodes, so `[set_count..NN]` is the padding range).
            for (src_h.set_count..NN) |s| t.sets[s] = [_]u8{0} ** 32;
            break :blk t;
        };
        const BT = backtrack.BacktrackerG(NN);
        return struct {
            pub const has_dfa = false;
            /// Step-2 trim proof: the baked HIR's exact node count, NOT the
            /// `HIR_CAP` = 2048 build ceiling. A tiny non-regular pattern bakes a
            /// tiny `.rodata` table (`@sizeOf(Hir(bt_node_count))`), not ~98 KB.
            pub const bt_node_count = NN;
            const h = baked;
            const n_groups = NG;
            const gnames = built.gnames;
            const a_start = baked.anchored_start;
            const a_end = baked.anchored_end;
            /// Comptime "seek" prefilter, baked from the HIR and threaded INTO
            /// the backtracker (`BT.init`'s `seek` arg) so `run`'s own scan loop
            /// applies it at *every* step — skipping interior dead regions, not
            /// just the leading prefix (the interior skip is what `count`/
            /// `findAll` need; skip-once-then-scan would leave the per-byte crawl
            /// that dominates those models). Two layered strategies, mirroring
            /// the runtime `seek.Seek` precedence exactly:
            ///   1. `lb_byte` — a leading positive single-byte look-behind
            ///      `(?<=X)` ⇒ every start `s` has `input[s-1]==X`; a `memchr`
            ///      for the (typically rare) `X` is the most selective filter
            ///      and captures the very constraint the over-approx drops. Takes
            ///      precedence when present.
            ///   2. else the baked over-approximation `Dfa256` (`built.seek_dfa`,
            ///      when `seek_ok`) — `Seek.locate`'s `dfa` path runs
            ///      `core.findLeftmost` over it to jump to the next candidate
            ///      start. This is the heap-free comptime analogue of runtime
            ///      `seek.build`'s Dfa256 path, and what lifts the atomic/token
            ///      shapes that have no leading look-behind.
            /// `null` ⇒ no usable filter, plain per-byte scan (still correct).
            ///
            /// `allocator` is set to the placeholder (comptime-known, no OS /
            /// libc dependency) only to satisfy the field; neither the `lb_byte`
            /// nor the `cdfa` `locate` path touches it, and `Seek.deinit` is
            /// never called here.
            ///
            /// The over-approximation DFA is baked **compressed** as a
            /// `comptime_dfa.Dfa(ns,nk)` (`compress`), so its `.rodata` is the
            /// minimized `[ns][nk]` table — not a full 131 KB `Dfa256`. It is
            /// fed to `Seek` type-erased via `seek.Cdfa` because each pattern's
            /// compressed type is distinct; `Cdfa.locate_fn` is that type's
            /// monomorphized `findLeftmost`-based locator, returning the same
            /// absolute candidate start the old `dfa`+`core.findLeftmost` path
            /// did (the two are differential-pinned).
            const seek_cdfa = if (built.seek_ok) compress(built.seek_dfa) else {};
            const bt_seek: ?seek_mod.Seek = if (seq_extract.requiredLeadingLookbehindByte(NN, &baked)) |b|
                .{ .allocator = placeholder_allocator, .lb_byte = b }
            else if (lbSet(NN, &baked)) |r|
                .{ .allocator = placeholder_allocator, .lb_set = r }
            else if (built.seek_ok)
                .{
                    .allocator = placeholder_allocator,
                    .cdfa = .{
                        .ptr = &seek_cdfa,
                        .locate_fn = struct {
                            fn f(p: *const anyopaque, input: []const u8, from: usize) ?usize {
                                const d: *const @TypeOf(seek_cdfa) = @ptrCast(@alignCast(p));
                                const sp = d.findLeftmost(input[from..]) orelse return null;
                                return from + sp.start;
                            }
                        }.f,
                    },
                }
            else
                null;
            inline fn seekPtr() ?*const seek_mod.Seek {
                return if (bt_seek) |*sv| sv else null;
            }

            /// Comptime-baked concat-internal regular-island DELEGATION plan,
            /// threaded into the backtracker (`BT.init`'s `del` arg). For each
            /// island (a greedy/no-alt/no-cap regular prefix of a `concat`, e.g.
            /// the `[A-Za-z0-9_]+` in `(?>…)@` after the cut is dropped, or a
            /// `\p{L}+` run in the tokenizer), `run` matches it at DFA speed via
            /// `core.matchEndFrom` instead of one CPS frame per byte, then
            /// continues the tree-walk from the island's greedy-maximal end.
            /// This is the comptime analogue of runtime `delegate.build`; the
            /// island DFAs are baked into `.rodata` (no heap `Plan`).
            ///
            /// `del_bake` (the `Dfa256` islands) is read **only at comptime** to
            /// produce the COMPRESSED `del_cdfas`, so the 131 KB-each `Dfa256`s
            /// never reach `.rodata`. The islands are baked into one homogeneous
            /// `[MAX_DELEGATE]DelIslandT` array sized to the per-pattern max
            /// dimensions (`del_dims`), so a single `delegate.Plan` / matcher
            /// serves them all. `del_plan.dfas[i]` are type-erased `&del_cdfas[i]`
            /// pointers (`.rodata` consts, read-only on the `matchEnd`/`runFrom`
            /// path; this comptime `Plan` is never `deinit`'d). `n == 0` ⇒ no
            /// delegation, plain walk.
            const del_bake = delegateIslands(NN, &baked);
            const del_dims = blk: {
                var mns: usize = 1;
                var mnk: usize = 1;
                for (0..del_bake.n) |i| {
                    mns = @max(mns, del_bake.dfas[i].n_states);
                    mnk = @max(mnk, del_bake.dfas[i].n_classes);
                }
                break :blk .{ .ns = mns, .nk = mnk };
            };
            const DelIslandT = comptime_dfa.Dfa(del_dims.ns, del_dims.nk);
            const del_cdfas: [MAX_DELEGATE]DelIslandT = blk: {
                var arr: [MAX_DELEGATE]DelIslandT = undefined;
                for (0..del_bake.n) |i| arr[i] = compressTo(DelIslandT, del_bake.dfas[i]);
                break :blk arr;
            };
            const delIslandMatch = struct {
                fn f(p: *const anyopaque, input: []const u8, pos: usize) ?usize {
                    const d: *const DelIslandT = @ptrCast(@alignCast(p));
                    return d.runFrom(input, pos);
                }
            }.f;
            const del_plan: delegate.Plan = blk: {
                var p = delegate.Plan{ .allocator = placeholder_allocator, .n = del_bake.n };
                for (0..del_bake.n) |i| {
                    p.refs[i] = del_bake.refs[i];
                    p.dfas[i] = &del_cdfas[i];
                    p.match_fns[i] = delIslandMatch;
                }
                break :blk p;
            };
            inline fn delPtr() ?*const delegate.Plan {
                return if (del_bake.n > 0) &del_plan else null;
            }

            /// Next leftmost span at/after absolute `from`. Runs the tree
            /// backtracker over the FULL `input` from absolute `from`
            /// (`runFrom`, NOT a `input[from..]` slice) so look-assertions
            /// (`\b`, `(?m)^ $`, `\A \z \Z`) see the true preceding/following
            /// bytes — slicing would make `from` look like start-of-text and
            /// mis-fire `start_line`/`\b` on resumed iterations. Span is already
            /// absolute. A budget exceed degrades to "no match" (this no-error
            /// API can't surface it); the runtime maps the same bound to
            /// `MatchBudgetExceeded`. Pick inputs well under the O(n) budget for
            /// differential parity.
            pub fn nextSpanFrom(input: []const u8, from: usize) ?search.Span {
                var bt = BT.init(&h, a_start, a_end, n_groups, seekPtr(), delPtr());
                var slots: [2 * (hir.MAX_GROUPS + 1)]i32 = undefined;
                const sp = (bt.runFrom(input, from, slots[0 .. 2 * (n_groups + 1)]) catch return null) orelse return null;
                return .{ .start = sp.start, .end = sp.end };
            }

            // Lazy whole-match verbs (zero-alloc), built on this arm's
            // `nextSpanFrom`. Re-exported individually (no `usingnamespace` in
            // Zig 0.16). See `WholeMatchVerbs`.
            const V = WholeMatchVerbs(nextSpanFrom);
            pub const Iterator = V.Iterator;
            pub const iterator = V.iterator;
            pub const startsWith = V.startsWith;
            pub const SplitIterator = V.SplitIterator;
            pub const splitIterator = V.splitIterator;
            // Zero-alloc capture verbs over an inline `Captures` (works for any
            // group count — `NG == 0` still exposes group 0 = whole match). The
            // comptime path captures with NO allocator, so — unlike the runtime
            // `Regex` — there is no `Match`-returning (allocating) `captures`
            // here: `captures`→`Captures` is the one, zero-alloc way.
            const C = CaptureSupport(built);
            pub const Captures = C.Caps;
            pub const captures = C.captures;
            pub const capturesFrom = C.capturesFrom;
            pub const capturesAll = C.capturesAll;
            pub const CapturesIterator = C.CapturesIterator;
            pub const capturesIterator = C.capturesIterator;

            // Whole-match eager verbs — generic `nextSpan`-driven scaffold (see
            // `WholeMatchVerbs`); this arm has no faster existence check.
            pub const isMatch = V.isMatch;
            pub const find = V.find;
            pub const count = V.count;
            pub const findAll = V.findAll;
        };
    }

    // Boundary-literals tier: `\b(?:lit|lit|…)\b` runs the comptime peer of the
    // runtime `.boundary_lits` engine — Aho-Corasick locate + an O(1) `\b` verify
    // (shared `seq_extract.BoundaryMatcher`). The AC is rebuilt at comptime and
    // node-TRIMMED (`trimmed`) so the baked `.rodata` is `[n_nodes][256]u16`
    // (~84 KB for a 40-keyword set) instead of the full 1024-node 516 KB build
    // table. `has_dfa = false` (no DFA table), matching the backtracker arm's
    // convention; `ng == 0` by construction (buildAll routes here capture-free).
    if (built.strat == .boundary_lits) {
        const bl = built.bl;
        // `buildAll` already built this AC once (to decide routing) and dropped
        // it; we rebuild here to trim. The rebuild is the deliberate cost of NOT
        // carrying the full 1024-node `AhoCorasickN(1024)` (~528 KB) in `Built`:
        // `Built` is one concrete type returned for EVERY pattern, so an AC field
        // would add 528 KB of comptime memory to every (non-boundary-lits) build
        // too. A second comptime build, paid only by `\b(?:lit|…)\b` patterns, is
        // the cheaper trade. (We can't trim inside `buildAll` either — the trimmed
        // `AhoCorasickN(n_nodes)` type is pattern-dependent, like the HIR trim.)
        const trimmed_ac = comptime blk: {
            @setEvalBranchQuota(50_000_000);
            var needles: [seq_extract.MAX_BL][]const u8 = undefined;
            for (0..bl.n) |i| needles[i] = bl.alt(i);
            const full = pf.AhoCorasick.build(needles[0..bl.n]).?;
            break :blk full.trimmed(full.n_nodes);
        };
        const Matcher = seq_extract.BoundaryMatcher(@TypeOf(trimmed_ac));
        const matcher: Matcher = comptime Matcher.init(trimmed_ac, bl);
        return struct {
            pub const has_dfa = false;
            /// Trim proof: the baked AC's exact node count, NOT the 1024-node
            /// build cap — a tiny keyword set bakes a tiny `.rodata` table.
            pub const ac_node_count = trimmed_ac.n_nodes;
            const mtr = matcher;

            /// Next leftmost span at/after absolute `from` (AC locate + `\b`
            /// verify). Absolute coords already — no slice, so the edge `\b`
            /// checks see true context, like the runtime engine.
            pub fn nextSpanFrom(input: []const u8, from: usize) ?search.Span {
                return mtr.find(input, from);
            }

            // Lazy whole-match verbs (zero-alloc), built on `nextSpanFrom`.
            const V = WholeMatchVerbs(nextSpanFrom);
            pub const Iterator = V.Iterator;
            pub const iterator = V.iterator;
            pub const startsWith = V.startsWith;
            pub const SplitIterator = V.SplitIterator;
            pub const splitIterator = V.splitIterator;
            // Zero-alloc captures (group 0 = whole match; `ng == 0`). Shares the
            // CaptureSupport machinery with the other arms for a uniform API.
            const C = CaptureSupport(built);
            pub const Captures = C.Caps;
            pub const captures = C.captures;
            pub const capturesFrom = C.capturesFrom;
            pub const capturesAll = C.capturesAll;
            pub const CapturesIterator = C.CapturesIterator;
            pub const capturesIterator = C.capturesIterator;

            // Whole-match eager verbs — generic `nextSpan`-driven scaffold (see
            // `WholeMatchVerbs`); the AC walk has no cheaper existence check.
            pub const isMatch = V.isMatch;
            pub const find = V.find;
            pub const count = V.count;
            pub const findAll = V.findAll;
        };
    }

    // Edge-look peel (comptime peer of runtime `.dfa_edge_look`): bake the core
    // `Dfa256` + the verify spec and drive the shared `edge_look.nextFrom`.
    // Placed before the DFA-state-budget gate so the core table is baked as-is.
    if (built.strat == .edge_look) {
        // Bake the regular core COMPRESSED (`compress`) — `edge_look.nextFrom`
        // is generic over the DFA representation, so this costs `[ns][nk]`
        // `.rodata` instead of a 131 KB `Dfa256` (the dominant flash cost for
        // trailing-look patterns like `[a-z]+(?=!)`, `\w+\b`).
        const core_dfa = compress(built.dfa);
        const spec = built.el_spec;
        return struct {
            pub const has_dfa = true;
            pub fn nextSpanFrom(input: []const u8, from: usize) ?search.Span {
                return edge_look.nextFrom(&core_dfa, &spec, input, from);
            }

            // Specialized existence check (edge verify, no match materialized);
            // find/count/findAll are the generic scaffold (see `WholeMatchVerbs`).
            pub fn isMatch(input: []const u8) bool {
                return edge_look.nextFrom(&core_dfa, &spec, input, 0) != null;
            }
            pub const find = V.find;
            pub const count = V.count;
            pub const findAll = V.findAll;
            const V = WholeMatchVerbs(nextSpanFrom);
            pub const Iterator = V.Iterator;
            pub const iterator = V.iterator;
            pub const startsWith = V.startsWith;
            pub const SplitIterator = V.SplitIterator;
            pub const splitIterator = V.splitIterator;
            const C = CaptureSupport(built);
            pub const Captures = C.Caps;
            pub const captures = C.captures;
            pub const capturesFrom = C.capturesFrom;
            pub const capturesAll = C.capturesAll;
            pub const CapturesIterator = C.CapturesIterator;
            pub const capturesIterator = C.capturesIterator;
        };
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

            /// Leftmost literal span at/after `from` (Teddy scan). The single
            /// scan the whole-match verbs share.
            pub fn nextSpanFrom(input: []const u8, from: usize) ?search.Span {
                return core.literalFindT(&t, input, from);
            }

            // Specialized existence check (Teddy, no match materialized);
            // find/count/findAll are the generic scaffold (see `WholeMatchVerbs`).
            pub fn isMatch(input: []const u8) bool {
                return core.literalIsMatchT(&t, input);
            }
            pub const find = V.find;
            pub const count = V.count;
            pub const findAll = V.findAll;

            // Lazy whole-match verbs (zero-alloc): iterator / startsWith / split.
            const V = WholeMatchVerbs(nextSpanFrom);
            pub const Iterator = V.Iterator;
            pub const iterator = V.iterator;
            pub const startsWith = V.startsWith;
            pub const SplitIterator = V.SplitIterator;
            pub const splitIterator = V.splitIterator;
            // Zero-alloc captures over the baked HIR (the `.literal` strat is an
            // exact-literal pattern, so typically `NG == 0` ⇒ group 0 only; but a
            // captured exact literal like `(abc)` still resolves correctly).
            const C = CaptureSupport(built);
            pub const Captures = C.Caps;
            pub const captures = C.captures;
            pub const capturesFrom = C.capturesFrom;
            pub const capturesAll = C.capturesAll;
            pub const CapturesIterator = C.CapturesIterator;
            pub const capturesIterator = C.capturesIterator;
        };
    }

    if (use_dfa) {
        // Bake the minimized DFA into its compact `comptime_dfa.Dfa(ns,nk)`
        // `.rodata` table via the shared `compress` (the same field mapping the
        // seek / delegate / edge-look prefilters use), so the necessary-condition
        // prefilters (`required`/`req_lit`) and start-byte filter ride along and
        // the comptime walk consults them just like the runtime `Dfa256`.
        const baked = compress(m);
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
            /// source of truth `find`/`count`/`findAll` + the lazy verbs share;
            /// the `switch (mode)` folds to the one strategy at comptime.
            pub fn nextSpanFrom(input: []const u8, from: usize) ?search.Span {
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

            // Specialized existence check (per-strategy fast `isMatch`, no match
            // materialized); find/count/findAll are the generic scaffold (see
            // `WholeMatchVerbs`).
            pub fn isMatch(input: []const u8) bool {
                return switch (mode) {
                    .dfa => table.isMatch(input),
                    .reverse_suffix => core.literalIsMatchT(&t, input) and table.isMatch(input),
                    .lit_prefix => search.litPrefixIsMatch(&table, &t, input),
                };
            }
            pub const find = V.find;
            pub const count = V.count;
            pub const findAll = V.findAll;

            // Lazy whole-match verbs (zero-alloc): iterator / startsWith / split.
            const V = WholeMatchVerbs(nextSpanFrom);
            pub const Iterator = V.Iterator;
            pub const iterator = V.iterator;
            pub const startsWith = V.startsWith;
            pub const SplitIterator = V.SplitIterator;
            pub const splitIterator = V.splitIterator;
            // Zero-alloc captures: this is the key win for regular-with-captures
            // patterns (e.g. `(\d{4})-(\d{2})-(\d{2})`) — `find`/`count` stay on
            // the fast DFA above; captures route through a baked backtracker over
            // the same HIR (the DFA is capture-transparent), no allocator.
            const C = CaptureSupport(built);
            pub const Captures = C.Caps;
            pub const captures = C.captures;
            pub const capturesFrom = C.capturesFrom;
            pub const capturesAll = C.capturesAll;
            pub const CapturesIterator = C.CapturesIterator;
            pub const capturesIterator = C.capturesIterator;
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
