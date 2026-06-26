//! "Seek" prefilter for the non-regular (`.backtrack`) tier — a zig port of
//! fancy-regex's idea of *deriving a regular approximation of the pattern*
//! and using the fast linear engine to skip ahead before paying for the
//! tree backtracker.
//!
//! We build a **regular over-approximation** of the `.backtrack` HIR by
//! replacing every non-regular / zero-width assertion node
//! (`look`, `look_around`, `backref`) with `empty`. Dropping a constraint
//! only *enlarges* the language, so `L(true) ⊆ L(approx)`: the leftmost
//! position where the approximation can begin a match is always `≤` any
//! real-match start. Skipping the proven-dead prefix therefore never drops
//! a real match (soundness), while collapsing long no-candidate stretches
//! from a per-byte recursive tree-walk to a linear DFA scan.
//!
//! The locator is, in preference order:
//!   1. a frozen **`DenseSearch`** (lever A) over the approximation — an
//!      O(n) single-pass unanchored search, the same dense engine the
//!      `.dense_search` tier uses. The over-approximations of the
//!      backtracker tier (e.g. `lookbehind_amount` → `[0-9]+…`,
//!      `backref_word` → `[A-Za-z]+ [A-Za-z]+`) are exactly the
//!      broad-first-byte shape where the old `core.findLeftmost` locator
//!      degenerated to O(n·m) — the reason this tier was the slow floor.
//!   2. else a heap `full_dfa.Dfa256` driven by `core.findLeftmost`
//!      (incl. the `seq_extract.requiredByte` memchr) — the prior behaviour,
//!      kept verbatim as the fallback (anchored / DFA-too-large for the
//!      dense freeze).
//! Any construction failure — or an approximation that is *nullable* (start
//! state accepting ⇒ matches everywhere ⇒ can never skip) — yields `null`:
//! the backtracker then falls back to its plain `start += 1` scan (still
//! correct, just unfiltered).

const std = @import("std");
const hir = @import("../hir.zig");
const thompson = @import("../thompson.zig");
const full_dfa = @import("full_dfa.zig");
const lazy_dfa = @import("lazy_dfa.zig");
const core = @import("core.zig");
const search = @import("search.zig");
const seq_extract = @import("seq_extract.zig");
const properties = @import("../properties.zig");
const class_span = @import("class_span.zig");

const H = hir.Hir(null);
const NodeRef = hir.NodeRef;

/// Regular over-approximation copy: `look`/`look_around`/`backref` → `ε`
/// (a sound, language-enlarging relaxation), everything else faithful, sets
/// re-interned. Thin alias over `hir.cloneSubtree(…, true)`.
inline fn lowerApprox(dst: *H, a: std.mem.Allocator, src: *const H, ref: NodeRef) hir.Error!NodeRef {
    return hir.cloneSubtree(null, null, dst, a, src, ref, true);
}

/// Type-erased compressed over-approximation DFA for the **comptime** path.
/// The comptime `Pattern` bakes its seek DFA as a class-width
/// `comptime_dfa.Dfa(ns,nk)` (a few hundred `.rodata` bytes) instead of a full
/// 131 KB `Dfa256`; `ptr` points at that baked const and `locate_fn` is its
/// monomorphized `findLeftmost`-based locator (`pattern.zig` supplies both as a
/// pair). `locate` returns the same absolute candidate start the runtime `dfa`
/// path would (it wraps the differential-pinned `findLeftmost`). Bundling the
/// pointer + function in one optional encodes the both-or-neither invariant —
/// mirrors `delegate.Island`.
pub const Cdfa = struct {
    ptr: *const anyopaque,
    locate_fn: *const fn (*const anyopaque, []const u8, usize) ?usize,
    inline fn locate(self: Cdfa, input: []const u8, from: usize) ?usize {
        return self.locate_fn(self.ptr, input, from);
    }
};

/// Over-approximation prefilter for the backtracker tier. Locates the next
/// position where the regular relaxation can begin a match; the tree
/// backtracker only runs there. Prefers the lever-A `DenseSearch` (O(n));
/// falls back to the prior `Dfa256` + `core.findLeftmost` path.
pub const Seek = struct {
    allocator: std.mem.Allocator,
    dense: ?*lazy_dfa.DenseSearch = null,
    dfa: ?*full_dfa.Dfa256 = null,
    /// Comptime-path compressed over-approximation DFA (see `Cdfa`). Runtime
    /// `build` leaves this `null` and uses `dense`/`dfa`.
    cdfa: ?Cdfa = null,
    /// Leading positive single-byte look-behind `(?<=X)` ⇒ `X`. Every match
    /// is immediately preceded by `X`, so the only candidate starts are
    /// `{X_pos + 1}`. Strictly the most selective sound filter when present
    /// (`X` is typically rare, e.g. `$`), and it captures the very
    /// constraint the over-approximation *drops* — so it takes precedence.
    lb_byte: ?u8 = null,
    /// Leading positive look-behind over a *multi-byte* class `(?<=[?&])` ⇒ the
    /// class as `Ranges`. The set generalization of `lb_byte`: candidate starts
    /// are `{m_pos + 1 : input[m_pos] ∈ class}`, found by a SIMD class search
    /// (`Ranges.firstMember`). Same precedence rationale as `lb_byte` (it is the
    /// exact dropped constraint); only one of `lb_byte`/`lb_set` is ever set.
    lb_set: ?class_span.Ranges = null,
    /// `$`/`\z`-anchored over-approximation only: the REVERSE DFA
    /// (`full_dfa.computeReverse`) of the relaxation. Drives `rejectsAnchoredEnd`
    /// — ONE O(n) reverse pass that proves "no suffix of the over-approx ends at
    /// `input.len`", hence (by `L(true) ⊆ L(approx)`) no real `$`-match anywhere
    /// ⇒ the tree backtracker returns null without the per-offset scan. Replaces
    /// the per-offset `Dfa256` locate, which for `a_end` is O(n²)/call. Only set
    /// for a NON-nullable approximation (a nullable one matches the empty suffix
    /// at end, so it could never reject). When set, the other locators are not.
    rev_neg: ?*full_dfa.Dfa256 = null,

    /// `$`-anchored fast-negative: true ⇒ no suffix of the regular
    /// over-approximation ends at `input.len` at/after `from`, so the real
    /// `$`-anchored backref/lookaround pattern cannot match — the caller returns
    /// null in this one O(n) pass instead of burning the step budget (`(a+)\1$`).
    pub fn rejectsAnchoredEnd(self: *const Seek, input: []const u8, from: usize) bool {
        const rev = self.rev_neg orelse return false;
        return search.reverseSearch(rev, input, from, input.len) == null;
    }

    /// Smallest absolute position `≥ from` where a match can begin, or
    /// `null` (⇒ no candidate ahead ⇒ no real match either; every branch
    /// here is a sound necessary condition, so it never drops a match).
    pub fn locate(self: *const Seek, input: []const u8, from: usize) ?usize {
        if (self.lb_byte) |b| {
            // Match start s ⇒ input[s-1]==b. Search from `from-1` (clamped)
            // so the first qualifying s is ≥ from; s = b_pos + 1.
            const sq = if (from == 0) 0 else from - 1;
            const q = std.mem.indexOfScalarPos(u8, input, sq, b) orelse return null;
            return q + 1;
        }
        if (self.lb_set) |r| {
            // As `lb_byte`, but the preceding byte must be any class member:
            // SIMD-scan for the leftmost member at/after `from-1`; s = m_pos + 1.
            const sq = if (from == 0) 0 else from - 1;
            const q = r.firstMember(input, sq) orelse return null;
            return q + 1;
        }
        if (self.dense) |ds| {
            const sp = ds.findFrom(input, from) orelse return null;
            return sp.start;
        }
        if (self.cdfa) |c| return c.locate(input, from);
        // `rev_neg`-only Seek (the `$`-anchored fast-negative): no per-offset
        // locator, so don't skip — the caller already ran `rejectsAnchoredEnd`
        // once; here just hand back `from` (a sound, no-skip candidate).
        const d = self.dfa orelse return from;
        const sp = core.findLeftmost(d, input[from..]) orelse return null;
        return from + sp.start;
    }

    pub fn deinit(self: *Seek) void {
        if (self.dense) |p| {
            p.deinit();
            self.allocator.destroy(p);
        }
        if (self.dfa) |p| self.allocator.destroy(p);
        if (self.rev_neg) |p| self.allocator.destroy(p);
    }
};

/// Build the over-approximation prefilter for backtracker HIR `h`. Never
/// errors: returns `null` (⇒ no prefilter, plain scan) on any
/// allocation/ceiling failure, a DFA blow-up, or a nullable approximation.
pub fn build(allocator: std.mem.Allocator, h: *const H) ?*Seek {
    if (h.root == hir.none) return null;

    // Lazy + end-anchor (`a+?$`): the over-approximation DFA inherits the same
    // lazy-against-`$` accept-cut flaw as the main construction, so its
    // `locate` is *unsound* — it can skip past the true leftmost start (e.g.
    // `a+?$` on "aaa" → 2 instead of 0). Skip the prefilter entirely; the
    // backtracker's plain `start += 1` scan is correct (and these patterns
    // are niche). The `a*?$` family already dodged this via the nullable-
    // approximation drop below.
    if (h.saw_lazy and h.anchored_end) return null;

    // Leading positive single-byte look-behind: the most selective sound
    // locator (a `memchr` for a typically-rare byte that is exactly the
    // constraint the over-approximation drops). When present it is the
    // complete prefilter — skip the dense/Dfa over-approx entirely (also
    // saves its construction cost).
    if (seq_extract.requiredLeadingLookbehindByte(null, h)) |b| {
        const sk = allocator.create(Seek) catch return null;
        sk.* = .{ .allocator = allocator, .lb_byte = b };
        return sk;
    }
    // Multi-byte leading look-behind `(?<=[?&])`: same most-selective filter,
    // a SIMD class search instead of a `memchr`. Skipped if the class needs
    // >16 ranges (`fromBitmap` ⇒ null) — then fall through to the over-approx.
    if (seq_extract.requiredLeadingLookbehindSet(null, h)) |bm| {
        if (class_span.Ranges.fromBitmap(bm)) |r| {
            const sk = allocator.create(Seek) catch return null;
            sk.* = .{ .allocator = allocator, .lb_set = r };
            return sk;
        }
    }

    var oh = H.initRuntime();
    defer oh.deinit(allocator);
    oh.root = lowerApprox(&oh, allocator, h, h.root) catch return null;
    oh.anchored_start = h.anchored_start;
    oh.anchored_end = h.anchored_end;
    oh.saw_lazy = h.saw_lazy;

    // Non-selective over-approximation guard. When the relaxation is
    // `Σ*`-shaped — every `set` in it matches (near-)all bytes, so it is only a
    // length constraint with no selective byte anywhere — *no* regular
    // prefilter can skip: every position is a candidate. Building and running
    // one (the O(n) dense pass, or the Dfa256 + reverse-start) is then pure
    // overhead layered on the tree-walk, so drop it; the backtracker's plain
    // `start += 1` scan is correct and far cheaper. The canonical case is a
    // multiline lookaround validator like `(?m)^(?=.*[a-z])(?=.*\d).{8,}$`,
    // whose relaxation collapses to `.{8,}` — measured at ~80% of that
    // pattern's run time spent in a prefilter that never skipped. A single
    // selective set (a literal, a digit/letter/punct class — tokenizer,
    // modsec) keeps the filter, where the dense engine genuinely skips.
    if (properties.nonSelectiveApprox(null, &oh, oh.root)) return null;

    var nfa = thompson.build(null, &oh) catch return null;

    // `$`/`\z`-anchored over-approximation: every real match must end at
    // `input.len`, so a single O(n) REVERSE pass over the relaxation is a sound
    // fast-negative — "no suffix of the over-approx ends at `input.len` ⇒ no real
    // `$`-match anywhere". This replaces the per-offset `Dfa256` locate (which
    // for `a_end` is O(n²)/call — the very thing that made `(a*)\1$`/`(a+)\1$`
    // pay un-ticked quadratic seek work). Only a NON-nullable approximation can
    // ever reject (a nullable one matches the empty suffix at end), so a nullable
    // / exploded reverse build yields no prefilter — the backtracker's
    // step-budgeted scan is then the only (correct) bound. Mutually exclusive
    // with the dense/Dfa256 locators below (which never run for `a_end`).
    if (oh.anchored_end) {
        const rd = full_dfa.computeReverse(null, &nfa);
        if (rd.outcome != .ok or rd.start >= rd.n_states or rd.accepting[rd.start]) return null;
        const heap = allocator.create(full_dfa.Dfa256) catch return null;
        heap.* = rd;
        const sk = allocator.create(Seek) catch {
            allocator.destroy(heap);
            return null;
        };
        sk.* = .{ .allocator = allocator, .rev_neg = heap };
        return sk;
    }

    // --- preferred: frozen DenseSearch (lever A, O(n) single pass) --------
    // freezeDense returns null for anchored / conditional / state-cap; that
    // is exactly when we want the Dfa256 fallback below (no regression).
    var dense: ?*lazy_dfa.DenseSearch = null;
    dense_blk: {
        var prog = lazy_dfa.LazyProg.init(allocator, &nfa, oh.anchored_start, oh.anchored_end) catch
            break :dense_blk;
        const ds_opt = prog.freezeDense(allocator) catch {
            prog.deinit();
            break :dense_blk;
        };
        prog.deinit();
        const ds = ds_opt orelse break :dense_blk;
        // Nullable approximation: start accepts ⇒ `findFrom` returns `from`
        // at every position ⇒ can never skip. Useless prefilter — drop it.
        if (ds.accept[ds.start_fwd]) {
            ds.deinit();
            allocator.destroy(ds);
            break :dense_blk;
        }
        dense = ds;
    }

    // --- fallback: Dfa256 + core.findLeftmost (prior behaviour) -----------
    var dfa: ?*full_dfa.Dfa256 = null;
    if (dense == null) {
        var d = full_dfa.compute(null, &nfa, oh.anchored_start, oh.anchored_end);
        if (d.outcome != .ok) return null;
        if (d.start < d.n_states and d.accepting[d.start]) return null; // nullable
        d.required = seq_extract.requiredByte(null, &oh);
        const heap = allocator.create(full_dfa.Dfa256) catch return null;
        heap.* = d;
        dfa = heap;
    }

    const sk = allocator.create(Seek) catch {
        if (dense) |p| {
            p.deinit();
            allocator.destroy(p);
        }
        if (dfa) |p| allocator.destroy(p);
        return null;
    };
    sk.* = .{ .allocator = allocator, .dense = dense, .dfa = dfa };
    return sk;
}
