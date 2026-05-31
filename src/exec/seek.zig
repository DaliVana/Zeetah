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
const seq_extract = @import("seq_extract.zig");

const H = hir.Hir(null);
const NodeRef = hir.NodeRef;

/// Regular over-approximation copy: `look`/`look_around`/`backref` → `ε`
/// (a sound, language-enlarging relaxation), everything else faithful, sets
/// re-interned. Thin alias over `hir.cloneSubtree(…, true)`.
inline fn lowerApprox(dst: *H, a: std.mem.Allocator, src: *const H, ref: NodeRef) hir.Error!NodeRef {
    return hir.cloneSubtree(dst, a, src, ref, true);
}

/// Over-approximation prefilter for the backtracker tier. Locates the next
/// position where the regular relaxation can begin a match; the tree
/// backtracker only runs there. Prefers the lever-A `DenseSearch` (O(n));
/// falls back to the prior `Dfa256` + `core.findLeftmost` path.
pub const Seek = struct {
    allocator: std.mem.Allocator,
    dense: ?*lazy_dfa.DenseSearch = null,
    dfa: ?*full_dfa.Dfa256 = null,
    /// Leading positive single-byte look-behind `(?<=X)` ⇒ `X`. Every match
    /// is immediately preceded by `X`, so the only candidate starts are
    /// `{X_pos + 1}`. Strictly the most selective sound filter when present
    /// (`X` is typically rare, e.g. `$`), and it captures the very
    /// constraint the over-approximation *drops* — so it takes precedence.
    lb_byte: ?u8 = null,

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
        if (self.dense) |ds| {
            const sp = ds.findFrom(input, from) orelse return null;
            return sp.start;
        }
        const sp = core.findLeftmost(self.dfa.?, input[from..]) orelse return null;
        return from + sp.start;
    }

    pub fn deinit(self: *Seek) void {
        if (self.dense) |p| {
            p.deinit();
            self.allocator.destroy(p);
        }
        if (self.dfa) |p| self.allocator.destroy(p);
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

    var oh = H.initRuntime();
    defer oh.deinit(allocator);
    oh.root = lowerApprox(&oh, allocator, h, h.root) catch return null;
    oh.anchored_start = h.anchored_start;
    oh.anchored_end = h.anchored_end;
    oh.saw_lazy = h.saw_lazy;

    var nfa = thompson.build(null, &oh) catch return null;

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
