//! Frozen dense form of a lazy DFA (`exec/lazy_dfa.zig`): flat transition
//! tables + a lean single-pass driver. Built by `LazyProg.freezeDense` from
//! the same gate-verified transition oracle, so a `DenseSearch` is
//! behaviourally identical to `LazyProg.findLeftmostFrom` by construction
//! (the lazy differential test pins it). Lever A: the same O(n) single
//! forward pass + reverse start, but the per-byte cost is one array index —
//! no `intern`, `gen`, `ensureTrans` or closure on the hot path.

const std = @import("std");

/// Match span shared by the lazy/dense engines (`lazy_dfa` re-exports this as
/// `lazy_dfa.Span`).
pub const Span = struct { start: usize, end: usize };

/// Frozen dense form of a `LazyProg`: flat transition tables + a lean
/// single-pass driver. Behaviourally identical to `LazyProg.findLeftmostFrom`
/// (built from the same oracle) but the per-byte cost is one array index —
/// no `intern`, `gen`, `ensureTrans` or closure on the hot path. Lever A.
pub const DenseSearch = struct {
    /// State-id sentinel for "no successor" (DEAD). `freezeDense` guarantees
    /// the real state counts stay below this.
    pub const DEAD: u16 = std.math.maxInt(u16);

    allocator: std.mem.Allocator,
    class_of: [256]u8,
    n_classes: usize,
    n_fwd: usize,
    n_rev: usize,
    start_fwd: u16,
    start_rev: u16,
    utrans: []u16, // [sid*nc + cls]; never DEAD (the `.*?` re-injection)
    atrans: []u16, // [sid*nc + cls]; DEAD ⇒ leftmost-first lineage died
    accept: []bool, // [sid]
    rtrans: []u16, // [rsid*nc + cls]; DEAD ⇒ no reverse predecessor
    rhas_start: []bool, // [rsid] ⇒ forward start reachable (a match start)

    /// Free the owned transition arrays. `pub` so `LazyProg.freezeDense` can
    /// use it as an `errdefer` while populating a freshly-created instance.
    pub fn freeArrays(self: *DenseSearch) void {
        self.allocator.free(self.utrans);
        self.allocator.free(self.atrans);
        self.allocator.free(self.accept);
        self.allocator.free(self.rtrans);
        self.allocator.free(self.rhas_start);
    }

    pub fn deinit(self: *DenseSearch) void {
        self.freeArrays();
    }

    /// Leftmost (leftmost-first) match starting at/after `from`, in absolute
    /// `input` coordinates, or `null`. Mirrors `findLeftmostFrom` +
    /// `reverseStart` exactly (`lo == from`), as raw table indexing.
    pub fn findFrom(self: *const DenseSearch, input: []const u8, from: usize) ?Span {
        const nc = self.n_classes;
        var sid: u16 = self.start_fwd;
        var have = self.accept[sid];
        var end: usize = from;
        var i: usize = from;
        while (i < input.len) : (i += 1) {
            const cls = self.class_of[input[i]];
            if (!have) {
                sid = self.utrans[@as(usize, sid) * nc + cls];
            } else {
                const n = self.atrans[@as(usize, sid) * nc + cls];
                if (n == DEAD) break; // leftmost-first lineage exhausted
                sid = n;
            }
            if (self.accept[sid]) {
                have = true;
                end = i + 1;
            }
        }
        if (!have) return null;

        // Reverse pass: leftmost start of the match ending at `end`, ≥ `from`.
        var rsid: u16 = self.start_rev;
        var start: usize = end;
        var pos: usize = end;
        while (pos > from) {
            const cls = self.class_of[input[pos - 1]];
            const n = self.rtrans[@as(usize, rsid) * nc + cls];
            if (n == DEAD) break;
            rsid = n;
            pos -= 1;
            if (self.rhas_start[rsid]) start = pos;
        }
        return .{ .start = start, .end = end };
    }

    pub fn isMatch(self: *const DenseSearch, input: []const u8) bool {
        return self.findFrom(input, 0) != null;
    }
};
