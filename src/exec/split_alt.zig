//! Per-segment delegation for a **top-level alternation** whose continuation
//! is `accept` — a zig port of fancy-regex's core design: don't demote the
//! whole pattern to the tree backtracker just because one branch is
//! non-regular. Instead split `B1|B2|…|Bk` (source order) into contiguous
//! **segments**:
//!
//!  * a maximal run of DFA-eligible branches → one anchored `full_dfa`
//!    (leftmost-first over a regular sub-alternation — the semantics the
//!    cross-engine gate already pins for the `.dfa` path);
//!  * each non-eligible branch (look-around / backref / `\b`-style `look`)
//!    → one anchored `backtrack` sub-engine over just that branch.
//!
//! Leftmost-first is preserved **by construction**: at each start position
//! `s` (scanned upward, Seek-skipped) the segments are evaluated strictly in
//! source order and the first that matches wins — identical to evaluating
//! `B1..Bk` in order with continuation `accept`, because segments are
//! contiguous and order-preserving. So `\s+(?!\S)` still beats a later
//! `\s+`, etc.
//!
//! `build` returns `null` (⇒ caller keeps the whole-pattern `.backtrack`
//! path) on anything it cannot prove safe: not a top-level alt, has capture
//! groups, no useful split, or a run that does not compile to a clean DFA.

const std = @import("std");
const hir = @import("../hir.zig");
const thompson = @import("../thompson.zig");
const full_dfa = @import("full_dfa.zig");
const seek_mod = @import("seek.zig");
const core = @import("core.zig");
const backtrack = @import("backtrack.zig");

const H = hir.Hir(null);
const NodeRef = hir.NodeRef;
pub const Span = core.Span;
pub const Error = backtrack.Error;

const Seg = struct {
    kind: enum { dfa, bt },
    dfa: ?*full_dfa.Dfa256 = null,
    bt_hir: ?*H = null,
};

pub const SplitAlt = struct {
    allocator: std.mem.Allocator,
    segs: []Seg,

    pub fn deinit(self: *SplitAlt) void {
        const a = self.allocator;
        freeSegItems(a, self.segs);
        a.free(self.segs);
        a.destroy(self);
    }

    /// Leftmost (leftmost-first) match span within `input`. `a_start`/`a_end`
    /// are the prescan anchors of the whole pattern; `seek` is the optional
    /// full-pattern over-approximation DFA (#1) used to skip dead prefixes.
    pub fn run(
        self: *const SplitAlt,
        input: []const u8,
        a_start: bool,
        a_end: bool,
        seek: ?*const seek_mod.Seek,
    ) Error!?Span {
        // `$`-anchored fast-negative (same as `backtrack.runFrom`): one O(n)
        // reverse pass over the over-approximation rejects the whole search when
        // no suffix ends at `input.len`, before the per-start backtracker scan.
        if (a_end and !a_start) {
            if (seek) |sd| {
                if (sd.rejectsAnchoredEnd(input, 0)) return null;
            }
        }
        var s: usize = 0;
        while (s <= input.len) : (s += 1) {
            if (!a_start) {
                if (seek) |sd| {
                    s = sd.locate(input, s) orelse return null;
                    if (s > input.len) return null;
                }
            }
            for (self.segs) |*seg| {
                if (seg.kind == .dfa) {
                    if (core.findLeftmost(seg.dfa.?, input[s..])) |sp|
                        return Span{ .start = s, .end = s + sp.end };
                } else {
                    var bt = backtrack.Backtracker.init(seg.bt_hir.?, true, a_end, 0, null, null);
                    var slots: [2]i32 = undefined;
                    if (try bt.run(input[s..], slots[0..2])) |sp|
                        return Span{ .start = s, .end = s + sp.end };
                }
            }
            if (a_start) return null;
        }
        return null;
    }
};

/// Faithful subtree copy (sets re-interned) — `hir.cloneSubtree(…, false)`.
inline fn cloneExact(dst: *H, a: std.mem.Allocator, src: *const H, ref: NodeRef) hir.Error!NodeRef {
    return hir.cloneSubtree(null, null, dst, a, src, ref, false);
}

/// A branch is DFA-eligible iff it contains no non-regular / unfoldable node
/// (`look` \b-style, `look_around`, `backref`).
fn dfaEligible(h: *const H, ref: NodeRef) bool {
    const nd = h.node(ref);
    return switch (nd.tag) {
        .look, .look_around, .backref, .atomic => false,
        .empty, .set => true,
        .concat, .alt => dfaEligible(h, nd.a) and dfaEligible(h, nd.b),
        .star, .plus, .opt, .cap => dfaEligible(h, nd.a),
    };
}

/// In-order leaves of the top-level left-leaning `alt` spine.
fn collectBranches(h: *const H, ref: NodeRef, out: *std.ArrayList(NodeRef), a: std.mem.Allocator) !void {
    const nd = h.node(ref);
    if (nd.tag == .alt) {
        try collectBranches(h, nd.a, out, a);
        try collectBranches(h, nd.b, out, a);
    } else try out.append(a, ref);
}

/// Anchored DFA for the sub-alternation `branches[lo..hi]` (source order
/// preserved as a left-leaning alt chain). `null` ⇒ does not compile cleanly.
fn buildRunDfa(
    a: std.mem.Allocator,
    src: *const H,
    branches: []const NodeRef,
    a_end: bool,
) ?*full_dfa.Dfa256 {
    var dst = H.initRuntime();
    defer dst.deinit(a);
    var root: NodeRef = cloneExact(&dst, a, src, branches[0]) catch return null;
    for (branches[1..]) |br| {
        const rb = cloneExact(&dst, a, src, br) catch return null;
        root = dst.addNode(a, .{ .tag = .alt, .a = root, .b = rb }) catch return null;
    }
    dst.root = root;
    const nfa = thompson.build(null, &dst) catch return null;
    const d = full_dfa.compute(null, &nfa, true, a_end); // anchored at scan pos
    if (d.outcome != .ok) return null;
    const heap = a.create(full_dfa.Dfa256) catch return null;
    heap.* = d;
    return heap;
}

/// Free the heap children each `Seg` owns (not the backing array — the
/// caller deinits the `ArrayList`/slice). Shared by the build cleanup and
/// `SplitAlt.deinit`.
fn freeSegItems(a: std.mem.Allocator, segs: []Seg) void {
    for (segs) |*s| {
        if (s.dfa) |p| a.destroy(p);
        if (s.bt_hir) |p| {
            p.deinit(a);
            a.destroy(p);
        }
    }
}

/// Partition a top-level alternation into ordered DFA / backtracker segments.
/// Returns `null` if `.split_alt` is not applicable or not safe (caller then
/// keeps the whole-pattern `.backtrack` path).
pub fn build(allocator: std.mem.Allocator, h: *const H, a_end: bool) ?*SplitAlt {
    if (h.root == hir.none) return null;
    if (h.node(h.root).tag != .alt) return null;

    var branches: std.ArrayList(NodeRef) = .empty;
    defer branches.deinit(allocator);
    collectBranches(h, h.root, &branches, allocator) catch return null;
    if (branches.items.len < 2) return null;

    // One cleanup site: until ownership is handed to the returned `SplitAlt`,
    // any early `return null` frees every accumulated segment + the list.
    var segs: std.ArrayList(Seg) = .empty;
    var committed = false;
    defer if (!committed) {
        freeSegItems(allocator, segs.items);
        segs.deinit(allocator);
    };

    var have_dfa = false;
    var have_bt = false;
    var i: usize = 0;
    while (i < branches.items.len) {
        if (dfaEligible(h, branches.items[i])) {
            var j = i;
            while (j < branches.items.len and dfaEligible(h, branches.items[j])) : (j += 1) {}
            const d = buildRunDfa(allocator, h, branches.items[i..j], a_end) orelse return null;
            segs.append(allocator, .{ .kind = .dfa, .dfa = d }) catch {
                allocator.destroy(d); // not yet owned by `segs`
                return null;
            };
            have_dfa = true;
            i = j;
        } else {
            const hp = allocator.create(H) catch return null;
            hp.* = H.initRuntime();
            hp.root = cloneExact(hp, allocator, h, branches.items[i]) catch {
                hp.deinit(allocator);
                allocator.destroy(hp);
                return null;
            };
            segs.append(allocator, .{ .kind = .bt, .bt_hir = hp }) catch {
                hp.deinit(allocator);
                allocator.destroy(hp);
                return null;
            };
            have_bt = true;
            i += 1;
        }
    }
    // Only worth it (and only "delegation") when both kinds are present.
    if (!have_dfa or !have_bt) return null;

    const sa = allocator.create(SplitAlt) catch return null;
    const owned = segs.toOwnedSlice(allocator) catch {
        allocator.destroy(sa);
        return null;
    };
    sa.* = .{ .allocator = allocator, .segs = owned };
    committed = true; // ownership transferred; skip the cleanup defer
    return sa;
}
