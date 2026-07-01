//! Pure literal-sequence (`Seq`) extraction over the `Hir` IR.
//!
//! A `Seq` is a small set of literal alternatives that a match's prefix /
//! suffix / a required inner span must equal. It is a *necessary condition*
//! used to pick a prefilter or a reverse strategy — the engine always
//! re-verifies, so an over-approximation is safe (never a wrong match).
//!
//! `Hir` is post-lowering: `{m,n}` is already expanded and a literal byte is
//! a `.set` node whose bitmap has exactly one bit. This module reads it
//! without allocating and is fully comptime-evaluable.

const std = @import("std");
const hir = @import("../hir.zig");
const common = @import("../common.zig");
const pf = @import("../prefilter.zig");
const cc = @import("charclass.zig");
const search = @import("search.zig");

const NodeRef = hir.NodeRef;

pub const MAX_ALTS: usize = 8;
pub const MAX_LIT: usize = 64;

/// Up to `MAX_ALTS` literal alternatives, each up to `MAX_LIT` bytes.
pub const Seq = struct {
    lits: [MAX_ALTS][MAX_LIT]u8 = [_][MAX_LIT]u8{[_]u8{0} ** MAX_LIT} ** MAX_ALTS,
    lens: [MAX_ALTS]u8 = [_]u8{0} ** MAX_ALTS,
    /// Number of populated alternatives. `0` => no sequence.
    n: u8 = 0,
    /// True when matching one of these alternatives is *sufficient* (the Seq
    /// is the whole thing it describes — e.g. the entire pattern is the
    /// literal). False => it is only a leading/trailing necessary prefix.
    exact: bool = false,

    pub fn isEmpty(s: *const Seq) bool {
        return s.n == 0;
    }

    /// The shortest alternative length — a crude selectivity proxy (longer is
    /// rarer hence better). `0` when empty.
    pub fn minLen(s: *const Seq) usize {
        if (s.n == 0) return 0;
        var m: usize = std.math.maxInt(usize);
        for (0..s.n) |i| m = @min(m, s.lens[i]);
        return m;
    }

    pub fn alt(s: *const Seq, i: usize) []const u8 {
        return s.lits[i][0..s.lens[i]];
    }

    /// True iff no alternative contains an ASCII letter. For such a literal
    /// case folding is the identity, so an exact (case-sensitive) literal
    /// search *is* a correct case-insensitive search — letting the
    /// literal/prefix/suffix fast paths run under `case_insensitive` instead
    /// of falling to the broad first-byte-set DFA (digits, punctuation, URLs
    /// like `://`, version strings, …). In practice every Seq extracted under
    /// `ci` is already letter-free — the parser folds each letter into a
    /// 2-bit set that the single-member extraction below drops — so this
    /// predicate makes that soundness condition explicit and robust rather
    /// than relying on that representational invariant.
    pub fn isCaseInvariant(s: *const Seq) bool {
        for (0..s.n) |i| {
            for (s.alt(i)) |b| if (std.ascii.isAlphabetic(b)) return false;
        }
        return true;
    }
};

const hasBit = common.hasBit;

/// If `set_idx`'s bitmap has exactly one member, return that byte.
fn singleByte(comptime cap: ?usize, h: *const hir.Hir(cap), set_idx: u32) ?u8 {
    const bm = h.setBitmap(set_idx);
    var found: ?u8 = null;
    var c: usize = 0;
    while (c < 256) : (c += 1) {
        if (hasBit(&bm, @intCast(c))) {
            if (found != null) return null; // >1 member
            found = @intCast(c);
        }
    }
    return found;
}

/// Append the *complete* literal string of `ref` to `buf` if and only if the
/// entire subtree is a fixed single-byte-set concat chain (no alternation,
/// quantifier, multi-byte class). Returns the new length, or null if not a
/// pure literal (or it would overflow `MAX_LIT`).
pub fn wholeLiteral(comptime cap: ?usize, h: *const hir.Hir(cap), ref: NodeRef, buf: *[MAX_LIT]u8, len: usize) ?usize {
    const nd = h.node(ref);
    switch (nd.tag) {
        .empty => return len,
        .set => {
            const b = singleByte(cap, h, nd.set_idx) orelse return null;
            if (len >= MAX_LIT) return null;
            buf[len] = b;
            return len + 1;
        },
        .concat => {
            const l = wholeLiteral(cap, h, nd.a, buf, len) orelse return null;
            return wholeLiteral(cap, h, nd.b, buf, l);
        },
        .cap, .atomic => return wholeLiteral(cap, h, nd.a, buf, len), // transparent
        .alt, .star, .plus, .opt, .look, .backref, .look_around => return null,
    }
}

fn trailingRun(comptime cap: ?usize, h: *const hir.Hir(cap), ref: NodeRef, buf: *[MAX_LIT]u8, len: usize, exact: *bool) usize {
    const nd = h.node(ref);
    switch (nd.tag) {
        .empty => return len,
        .set => {
            const b = singleByte(cap, h, nd.set_idx) orelse {
                exact.* = false;
                return len;
            };
            if (len >= MAX_LIT) {
                exact.* = false;
                return len;
            }
            buf[MAX_LIT - 1 - len] = b; // fill from the right
            return len + 1;
        },
        .concat => {
            var lit_only = true;
            const before = len;
            const r = trailingRun(cap, h, nd.b, buf, len, &lit_only);
            if (!lit_only or r == before) {
                exact.* = false;
                return r;
            }
            return trailingRun(cap, h, nd.a, buf, r, exact);
        },
        .cap, .atomic => return trailingRun(cap, h, nd.a, buf, len, exact), // transparent
        .alt, .star, .plus, .opt, .look, .backref, .look_around => {
            exact.* = false;
            return len;
        },
    }
}

/// Flatten a (possibly nested left-leaning) `alt` tree into branch refs.
fn collectAlts(comptime cap: ?usize, h: *const hir.Hir(cap), ref: NodeRef, out: *[MAX_ALTS]NodeRef, n: *usize) bool {
    const nd = h.node(ref);
    if (nd.tag == .alt) {
        if (!collectAlts(cap, h, nd.a, out, n)) return false;
        return collectAlts(cap, h, nd.b, out, n);
    }
    if (n.* >= MAX_ALTS) return false;
    out[n.*] = ref;
    n.* += 1;
    return true;
}

// --- Small cross-product literal expansion ----------------------------------
//
// Extends a leading literal *run* through small "wobbles" — optional groups
// (`u?`, `(?:foo)?`), small character classes (`[ae]`, `gr[ae]y`), and literal
// alternations (`(?:cat|dog)`) — into the *set* of literal strings the spine
// can produce (`colou?r` → {color, colour}; `gr[ae]y` → {gray, grey}). The set
// is a sound necessary-prefix condition, so it drives the Teddy-locate +
// DFA-verify `.lit_prefix` path: a far more selective prefilter than the single
// leading run the plain extractor stops at the first wobble. Bounded by
// `MAX_ALTS` (cross-product size) and `MAX_LIT` (per-alternative length); the
// moment either would overflow, expansion stops with the prefix collected so
// far (still sound). A multi-literal result is deliberately kept *inexact* (see
// `prefix`) so leftmost-first is always resolved by the verifying DFA, never by
// the order-sensitive pure-literal short-circuit.

/// Max members of a character class enumerated into alternatives. Tiny on
/// purpose: a class wider than this (`[0-9]`, `[a-z]`) is not a small wobble —
/// its fan-out blows `MAX_ALTS` for no selectivity gain, so it stops the run.
const SMALL_CLASS_MAX: usize = 4;

/// A bounded set of literal alternatives under construction. Mirrors `Seq`'s
/// storage but carries no `exact` flag; the expansion helpers compose these by
/// concatenation (cross-product) and union. Defaults are all-zero so an
/// untouched byte tail is `0` (never `undefined` — safe to bake at comptime).
const LitSet = struct {
    lits: [MAX_ALTS][MAX_LIT]u8 = [_][MAX_LIT]u8{[_]u8{0} ** MAX_LIT} ** MAX_ALTS,
    lens: [MAX_ALTS]u8 = [_]u8{0} ** MAX_ALTS,
    n: usize = 0,
};

/// The singleton set `{""}` — the identity for concatenation.
fn litEmpty() LitSet {
    return .{ .n = 1 };
}

/// The singleton set `{<b>}`.
fn litByte(b: u8) LitSet {
    var s = LitSet{ .n = 1 };
    s.lits[0][0] = b;
    s.lens[0] = 1;
    return s;
}

/// Cross-product concatenation `{a_i ++ b_j}`. Null if it would exceed
/// `MAX_ALTS` alternatives or any alternative would exceed `MAX_LIT` bytes.
fn concatSets(a: LitSet, b: LitSet) ?LitSet {
    if (a.n * b.n > MAX_ALTS) return null;
    var out = LitSet{};
    var k: usize = 0;
    var i: usize = 0;
    while (i < a.n) : (i += 1) {
        var j: usize = 0;
        while (j < b.n) : (j += 1) {
            const al: usize = a.lens[i];
            const bl: usize = b.lens[j];
            if (al + bl > MAX_LIT) return null;
            var m: usize = 0;
            while (m < al) : (m += 1) out.lits[k][m] = a.lits[i][m];
            while (m < al + bl) : (m += 1) out.lits[k][m] = b.lits[j][m - al];
            out.lens[k] = @intCast(al + bl);
            k += 1;
        }
    }
    out.n = k;
    return out;
}

/// Set union `a ∪ b` (no dedup — duplicate needles are harmless to a
/// prefilter). Null if it would exceed `MAX_ALTS`.
fn unionSets(a: LitSet, b: LitSet) ?LitSet {
    if (a.n + b.n > MAX_ALTS) return null;
    var out = a;
    var j: usize = 0;
    while (j < b.n) : (j += 1) {
        out.lits[out.n] = b.lits[j];
        out.lens[out.n] = b.lens[j];
        out.n += 1;
    }
    return out;
}

/// A class of `1..SMALL_CLASS_MAX` members as one-byte alternatives, else null.
fn smallClassSet(comptime cap: ?usize, h: *const hir.Hir(cap), set_idx: u32) ?LitSet {
    const bm = h.setBitmap(set_idx);
    var out = LitSet{};
    var c: usize = 0;
    while (c < 256) : (c += 1) {
        if (hasBit(&bm, @intCast(c))) {
            if (out.n >= SMALL_CLASS_MAX) return null;
            out.lits[out.n][0] = @intCast(c);
            out.lens[out.n] = 1;
            out.n += 1;
        }
    }
    if (out.n == 0) return null;
    return out;
}

/// The *complete* finite set of literal strings a subtree can match, or null if
/// it is not boundedly literal (unbounded repetition, a wide class, look,
/// backref, or an overflow of the `MAX_ALTS`/`MAX_LIT` budget).
fn expandNode(comptime cap: ?usize, h: *const hir.Hir(cap), ref: NodeRef) ?LitSet {
    const nd = h.node(ref);
    switch (nd.tag) {
        .empty => return litEmpty(),
        .set => return if (singleByte(cap, h, nd.set_idx)) |b|
            litByte(b)
        else
            smallClassSet(cap, h, nd.set_idx),
        .concat => return concatSets(
            expandNode(cap, h, nd.a) orelse return null,
            expandNode(cap, h, nd.b) orelse return null,
        ),
        .alt => return unionSets(
            expandNode(cap, h, nd.a) orelse return null,
            expandNode(cap, h, nd.b) orelse return null,
        ),
        .opt => return unionSets(litEmpty(), expandNode(cap, h, nd.a) orelse return null),
        .cap, .atomic => return expandNode(cap, h, nd.a), // transparent
        .star, .plus, .look, .look_around, .backref => return null,
    }
}

/// Accumulate the leading-spine prefix set into `acc` (cross-product), walking
/// `concat` left-to-right and through transparent `cap`/`atomic`. Returns false
/// — stopping the run — at the first factor that is not boundedly literal or
/// that would overflow the budget; `acc` then holds the longest sound prefix.
fn walkSpine(comptime cap: ?usize, h: *const hir.Hir(cap), ref: NodeRef, acc: *LitSet) bool {
    const nd = h.node(ref);
    switch (nd.tag) {
        .concat => {
            if (!walkSpine(cap, h, nd.a, acc)) return false;
            return walkSpine(cap, h, nd.b, acc);
        },
        .cap, .atomic => return walkSpine(cap, h, nd.a, acc),
        else => {
            const fs = expandNode(cap, h, ref) orelse return false;
            acc.* = concatSets(acc.*, fs) orelse return false;
            return true;
        },
    }
}

/// True if any alternative is the empty string. Such a set is not a *mandatory*
/// prefix (a match could begin with nothing — e.g. a leading optional `v?…`, or
/// a nullable pattern), so it must not be used as a selective prefilter: it
/// would match at every position and, worse, poison `Seq.isEmpty`/`minLen`.
fn hasEmptyAlt(set: LitSet) bool {
    var i: usize = 0;
    while (i < set.n) : (i += 1) if (set.lens[i] == 0) return true;
    return false;
}

fn seqFromSet(set: LitSet, exact: bool) Seq {
    var s = Seq{};
    var i: usize = 0;
    while (i < set.n) : (i += 1) {
        s.lits[i] = set.lits[i];
        s.lens[i] = set.lens[i];
    }
    s.n = @intCast(set.n);
    s.exact = exact;
    return s;
}

/// Prefix `Seq`: an alternation whose every branch is a whole literal yields
/// an *exact* multi-literal Seq (e.g. `cat|dog|bird`); otherwise the leading
/// literal run, **expanded across small optional/class/alternation wobbles**
/// into the set of possible leading literals (`colou?r` → {color, colour}).
/// `exact` is set only for a single whole-pattern literal (the pure-`.literal`
/// fast path); any multi-literal result is inexact so leftmost-first is decided
/// by the verifying DFA on the `.lit_prefix` path.
pub fn prefix(comptime cap: ?usize, h: *const hir.Hir(cap)) Seq {
    @setEvalBranchQuota(1_000_000);
    var s = Seq{};
    const root = h.node(h.root);

    if (root.tag == .alt) {
        var refs: [MAX_ALTS]NodeRef = undefined;
        var nn: usize = 0;
        if (collectAlts(cap, h, h.root, &refs, &nn)) {
            var ok = true;
            for (0..nn) |i| {
                var buf: [MAX_LIT]u8 = undefined;
                const ln = wholeLiteral(cap, h, refs[i], &buf, 0);
                if (ln == null or ln.? == 0) {
                    ok = false;
                    break;
                }
                s.lits[i] = buf;
                s.lens[i] = @intCast(ln.?);
            }
            if (ok) {
                s.n = @intCast(nn);
                s.exact = true;
                return s;
            }
            s = Seq{};
        }
    }

    // Whole pattern is a finite literal set (`hello`, `colou?r`, `gr[ae]y`):
    // exact only when it is a single literal (safe pure-`.literal` route). A set
    // with an empty alternative (nullable pattern) is not a mandatory prefix.
    if (expandNode(cap, h, h.root)) |full| {
        if (full.n >= 1 and !hasEmptyAlt(full)) return seqFromSet(full, full.n == 1);
        return Seq{};
    }
    // Otherwise the expanded leading prefix up to the first non-literal element.
    // `walkSpine` seeds `acc` with `{""}`, so a non-extending walk (leading
    // `.star`/look) or a leading optional (`v?…`) leaves an empty alternative —
    // `hasEmptyAlt` then correctly reports "no mandatory prefix".
    var acc = litEmpty();
    _ = walkSpine(cap, h, h.root, &acc);
    if (acc.n >= 1 and !hasEmptyAlt(acc)) return seqFromSet(acc, false);

    return Seq{};
}

/// Trailing literal run (a necessary suffix; exact iff whole pattern).
pub fn suffix(comptime cap: ?usize, h: *const hir.Hir(cap)) Seq {
    @setEvalBranchQuota(1_000_000);
    var s = Seq{};
    var buf: [MAX_LIT]u8 = undefined;
    var exact = true;
    const ln = trailingRun(cap, h, h.root, &buf, 0, &exact);
    if (ln == 0) return Seq{};
    // trailingRun filled from the right edge; left-align it.
    var out: [MAX_LIT]u8 = [_]u8{0} ** MAX_LIT;
    for (0..ln) |i| out[i] = buf[MAX_LIT - ln + i];
    s.lits[0] = out;
    s.lens[0] = @intCast(ln);
    s.n = 1;
    s.exact = exact;
    return s;
}

/// Walk only through nodes every accepting path must traverse (`.concat`
/// children, and a `.plus` body which runs ≥1 time), collecting mandatory
/// single-byte `.set` leaves; keep the statistically rarest (best prefilter
/// selectivity). `.star/.opt/.alt` subtrees are optional/alternative so their
/// bytes are *not* guaranteed and are skipped — keeping the result a sound
/// necessary condition.
fn scanRequired(comptime cap: ?usize, h: *const hir.Hir(cap), ref: NodeRef, best: *?u8, bestf: *u16) void {
    const nd = h.node(ref);
    switch (nd.tag) {
        .set => {
            if (singleByte(cap, h, nd.set_idx)) |b| {
                if (best.* == null or pf.FREQ[b] < bestf.*) {
                    best.* = b;
                    bestf.* = pf.FREQ[b];
                }
            }
        },
        .concat => {
            scanRequired(cap, h, nd.a, best, bestf);
            scanRequired(cap, h, nd.b, best, bestf);
        },
        .plus => scanRequired(cap, h, nd.a, best, bestf),
        .cap, .atomic => scanRequired(cap, h, nd.a, best, bestf), // transparent
        .star, .opt, .alt, .empty, .look, .backref, .look_around => {},
    }
}

/// A rare mandatory byte `R` plus a recipe to recover the match *start* from
/// `R`'s position, so the search can `memchr` to candidate regions instead
/// of restarting the DFA at every position (the broad-first-byte O(n²) case
/// — e.g. `…@…`, `…://…`, `\d{3}-\d{2}-\d{4}`). Necessary condition only;
/// the engine always re-verifies, so this never changes an outcome.
pub const MAX_REQLIT = 32;

/// How to recover a match START from an anchor-literal occurrence.
pub const ReqLitBack = union(enum) {
    /// Match start is exactly `L_pos - k` (fixed-width mandatory prefix).
    fixed: usize,
    /// Match start = walk back from `L` over bytes in this set (the pattern
    /// opens with a single `set`+/`set`* run, `L[0] ∉ set`).
    class: [32]u8,
};

pub const ReqLit = struct {
    /// The anchor literal `lit[0..len]`. `len == 1` is the original single rare
    /// byte (located by `memchr`); `len >= 2` is a selective *inner* literal
    /// (reverse-inner anchoring). A multi-byte anchor occurs far less often than
    /// any single byte, so far fewer candidate positions reach the `runFrom`
    /// verifier (e.g. `[a-z]+/api/v2/[a-z]+` keys on `/api/v2/`, not on `/`).
    lit: [MAX_REQLIT]u8 = [_]u8{0} ** MAX_REQLIT,
    len: u8 = 1,
    /// The byte `prefilter.findLiteralOcc` locates the literal by (`memchr`, or
    /// the first byte of its two-byte SIMD filter), at offset `probe_off`. Picked
    /// by `pickProbe`. Substring search (`std.mem.indexOfPos`) is deliberately
    /// NOT used — it is much slower than `memchr` when the literal is frequent
    /// (e.g. `://` in a URL-dense corpus).
    probe: u8 = 0,
    probe_off: u8 = 0,
    back: ReqLitBack,
};

const MAXI = 64;
const SpItem = struct {
    kind: enum { lit1, cls1, run, stop },
    byte: u8 = 0,
    set: [32]u8 = [_]u8{0} ** 32,
};

fn flatten(comptime cap: ?usize, h: *const hir.Hir(cap), ref: NodeRef, out: *[MAXI]SpItem, n: *usize) void {
    if (n.* >= MAXI) return;
    const nd = h.node(ref);
    switch (nd.tag) {
        .concat => {
            flatten(cap, h, nd.a, out, n);
            flatten(cap, h, nd.b, out, n);
        },
        .cap => flatten(cap, h, nd.a, out, n),
        .set => {
            if (singleByte(cap, h, nd.set_idx)) |b| {
                out[n.*] = .{ .kind = .lit1, .byte = b };
            } else {
                out[n.*] = .{ .kind = .cls1, .set = h.setBitmap(nd.set_idx) };
            }
            n.* += 1;
        },
        .plus, .star => {
            const c = h.node(nd.a);
            if (c.tag == .set) {
                out[n.*] = .{ .kind = .run, .set = h.setBitmap(c.set_idx) };
            } else out[n.*] = .{ .kind = .stop };
            n.* += 1;
        },
        else => {
            out[n.*] = .{ .kind = .stop };
            n.* += 1;
        },
    }
}

/// Per-byte "rarity": higher = occurs less often in text, so a more selective
/// anchor. Monotone-decreasing in `pf.FREQ`, so for a single byte picking the
/// max rarity is exactly the old "rarest byte by FREQ". Summed over a literal's
/// bytes it rewards both length and rare bytes, so a multi-byte literal beats a
/// single byte unless that byte is genuinely rarer than the whole run.
inline fn rarity(b: u8) u32 {
    return @as(u32, 1024) / (@as(u32, pf.FREQ[b]) + 1);
}

/// Pick the byte `prefilter.findLiteralOcc` should locate `lit` by. Prefer the
/// rarest **robustly-rare** byte (low-frequency letter / non-ASCII) at its first
/// offset — `memchr` on it is selective regardless of corpus. If the literal is
/// all-common (`://`, `-FOO-`, structural punctuation), pick the rarest byte at
/// offset ≥ 1 so `findLiteralOcc`'s two-byte SIMD filter ANDs `lit[0]` with a
/// *decorrelated* second byte (larger offset breaks FREQ ties — the same
/// decorrelation `prefilter.Teddy.build` seeks for its `b2`). Mirrors that
/// heuristic but stays separate: this prefers robust-rarity for `memchr`
/// selectivity, where Teddy optimises a fixed two-byte AND.
fn pickProbe(lit: []const u8) struct { byte: u8, off: u8 } {
    var byte: u8 = lit[0];
    var off: u8 = 0;
    // pass 1: rarest robustly-rare byte (first offset wins on tie).
    var bestf: u16 = std.math.maxInt(u16);
    var found = false;
    for (lit, 0..) |b, m| {
        if (pf.robustlyRareProbe(b) and pf.FREQ[b] < bestf) {
            found = true;
            bestf = pf.FREQ[b];
            byte = b;
            off = @intCast(m);
        }
    }
    if (found or lit.len < 2) return .{ .byte = byte, .off = off };
    // pass 2: all-common literal — rarest byte at offset ≥ 1 (larger offset wins
    // on tie, to decorrelate the two-byte filter's second probe from `lit[0]`).
    bestf = std.math.maxInt(u16);
    var m: usize = 1;
    while (m < lit.len) : (m += 1) {
        if (pf.FREQ[lit[m]] <= bestf) {
            bestf = pf.FREQ[lit[m]];
            byte = lit[m];
            off = @intCast(m);
        }
    }
    return .{ .byte = byte, .off = off };
}

/// Pick the most selective mandatory literal whose match-start is recoverable
/// (fixed-width prefix, or a leading single `set`-run), or null. Generalises the
/// single-rare-byte anchor to the **longest/rarest consecutive mandatory literal
/// run** (reverse-inner): the anchor `lit[0..len]` is necessary at a recoverable
/// offset, so locating it and recovering the start yields candidate matches that
/// `runFrom` verifies. Sound for *leftmost* search: the anchor cannot occur
/// inside its own preceding prefix, so anchor-occurrence order equals
/// match-start order. A length-1 result is byte-identical to the old behaviour.
pub fn requiredLiteralBack(comptime cap: ?usize, h: *const hir.Hir(cap)) ?ReqLit {
    @setEvalBranchQuota(1_000_000);
    var items: [MAXI]SpItem = undefined;
    var n: usize = 0;
    flatten(cap, h, h.root, &items, &n);

    var best: ?ReqLit = null;
    var best_score: u32 = 0;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (items[i].kind != .lit1) continue;
        // Maximal run of consecutive mandatory literal bytes at `i` (capped).
        var j = i;
        while (j < n and items[j].kind == .lit1 and (j - i) < MAX_REQLIT) : (j += 1) {}
        const lo = i;
        const hi = j;
        const r = items[lo].byte; // anchor's first byte — drives recoverability

        // Recoverability of the anchor START at index `lo` (mirrors the
        // single-byte rule; the run's bytes are width-1 so a recoverable middle
        // byte implies a recoverable `lo`, and anchoring the whole run dominates).
        var back: ?ReqLitBack = null;
        // fixed: every item before `lo` is a width-1 element that cannot match `r`.
        var all_fixed = true;
        var k: usize = 0;
        while (k < lo) : (k += 1) {
            const it = items[k];
            if (it.kind == .lit1 and it.byte != r) continue;
            if (it.kind == .cls1 and !hasBit(&it.set, r)) continue;
            all_fixed = false;
            break;
        }
        if (all_fixed) {
            back = .{ .fixed = lo };
        } else if (lo == 1 and items[0].kind == .run and !hasBit(&items[0].set, r)) {
            back = .{ .class = items[0].set }; // one `set`-run immediately before `L`
        }

        if (back) |bk| {
            var score: u32 = 0;
            var m: usize = lo;
            while (m < hi) : (m += 1) score += rarity(items[m].byte);
            if (score > best_score) {
                best_score = score;
                var lit: [MAX_REQLIT]u8 = [_]u8{0} ** MAX_REQLIT;
                var m2: usize = lo;
                while (m2 < hi) : (m2 += 1) lit[m2 - lo] = items[m2].byte;
                const len: u8 = @intCast(hi - lo);
                const p = pickProbe(lit[0..len]);
                best = .{ .lit = lit, .len = len, .probe = p.byte, .probe_off = p.off, .back = bk };
            }
        }
        i = hi - 1; // skip the rest of this run (loop `i += 1` resumes at `hi`)
    }
    return best;
}

/// Bitmap of a leading positive *single-`set`* look-behind `(?<=[…])` — the
/// set every match start `s` must satisfy at `input[s-1]`. The single spine
/// walk both `requiredLeadingLookbehindByte` (popcount 1 ⇒ `memchr`) and
/// `requiredLeadingLookbehindSet` (popcount ≥2 ⇒ memchr-over-set) build on.
/// Only the leading spine is walked (`concat` left, `cap` through); negative /
/// non-`set` / non-leading look-behinds and all look-aheads return `null`.
fn leadingLookbehindSet(comptime cap: ?usize, h: *const hir.Hir(cap), ref: NodeRef) ?[32]u8 {
    const nd = h.node(ref);
    return switch (nd.tag) {
        .concat => leadingLookbehindSet(cap, h, nd.a), // leftmost on the spine
        .cap => leadingLookbehindSet(cap, h, nd.a), // capture is transparent
        .look_around => blk: {
            if (nd.set_idx & hir.LA_BEHIND == 0) break :blk null; // look-ahead
            if (nd.set_idx & hir.LA_NEGATIVE != 0) break :blk null; // negative
            const sub = h.node(nd.a);
            if (sub.tag != .set) break :blk null; // not a single fixed-width class
            break :blk h.setBitmap(sub.set_idx);
        },
        else => null,
    };
}

fn popcount(bm: [32]u8) usize {
    var n: usize = 0;
    for (bm) |b| n += @popCount(b);
    return n;
}

/// If the pattern's leading mandatory element is a **positive single-byte
/// look-behind** `(?<=X)`, return `X`: every match is then immediately preceded
/// by `X`, so the match start is exactly `X_pos + 1`. A sound *necessary*
/// condition (the real candidate starts are a subset), so a prefilter using it
/// can never drop a match — it just turns a near-everywhere candidate scan into
/// a `memchr` for a rare byte. (≥2 members ⇒ the set path
/// `requiredLeadingLookbehindSet` handles it.)
pub fn requiredLeadingLookbehindByte(comptime cap: ?usize, h: *const hir.Hir(cap)) ?u8 {
    if (h.root == hir.none) return null;
    const bm = leadingLookbehindSet(cap, h, h.root) orelse return null;
    if (popcount(bm) != 1) return null; // ≥2 members ⇒ the set path handles it
    var c: usize = 0;
    while (c < 256) : (c += 1) if (hasBit(&bm, @intCast(c))) return @intCast(c);
    return null;
}

/// Leading positive look-behind over a *multi-byte* class `(?<=[?&])` — the
/// set generalization of `requiredLeadingLookbehindByte`. Returns the class
/// bitmap (≥2 members; the single-byte case routes through the `memchr` path
/// above). A match can begin only one byte past a member, so the seek scans
/// for the next member with a SIMD class search — exactly the constraint the
/// over-approximation drops, and the most selective sound filter when present.
pub fn requiredLeadingLookbehindSet(comptime cap: ?usize, h: *const hir.Hir(cap)) ?[32]u8 {
    if (h.root == hir.none) return null;
    const bm = leadingLookbehindSet(cap, h, h.root) orelse return null;
    if (popcount(bm) < 2) return null; // 1 member ⇒ `requiredLeadingLookbehindByte`
    return bm;
}

// --- `\b(lit|lit|…)\b` recogniser -------------------------------------------
//
// A word-boundary-bracketed pure literal alternation (`\b(?:break|case|…)\b`).
// It is *regular* but a naive Thompson NFA of N keywords is ~12·N states, so a
// large keyword list (e.g. 40) blows `MAX_NFA` ⇒ a typed `PatternTooComplex`
// even though the language is trivial. This recogniser pulls the literal set
// out of the HIR so the engine can run it as Aho-Corasick locate + an O(1)
// word-boundary verify at each candidate span edge — no NFA, no backtracker,
// no `bt_look` `visited` array. See memory
// `deep-alternation-reject-is-architectural`.

pub const MAX_BL: usize = 128;

pub const BoundaryLits = struct {
    lits: [MAX_BL][MAX_LIT]u8 = [_][MAX_LIT]u8{[_]u8{0} ** MAX_LIT} ** MAX_BL,
    lens: [MAX_BL]u8 = [_]u8{0} ** MAX_BL,
    n: u16 = 0,
    /// Longest alternative — the window width the search must brute-scan
    /// around an Aho-Corasick hit to stay leftmost-correct.
    maxlen: u8 = 0,

    pub fn alt(s: *const BoundaryLits, i: usize) []const u8 {
        return s.lits[i][0..s.lens[i]];
    }
};

/// The `\b(?:lit|lit|…)\b` matcher: Aho-Corasick locate + an O(1) `\b`-verify
/// walk, leftmost-first by *source order*. Generic on the AC table type so the
/// SAME logic drives the runtime `.boundary_lits` engine (`AcT` = the 1024-node
/// `pf.AhoCorasick`) and the comptime `Pattern.boundary_lits` arm (`AcT` = the
/// node-trimmed `pf.AhoCorasickN(N)` baked into `.rodata`) — no divergent copy.
/// `find` returns a `search.Span`; the recogniser that fills `bl` is
/// `boundaryLiterals` above.
pub fn BoundaryMatcher(comptime AcT: type) type {
    return struct {
        const Self = @This();
        ac: AcT,
        bl: BoundaryLits,
        /// SIMD prefilter that skips runs containing no possible keyword start,
        /// so the (scalar) Aho-Corasick automaton only runs near candidates —
        /// the prefilter every comparable AC engine (e.g. rust `aho-corasick`)
        /// carries. Chosen at `init`: `.teddy` (PSHUFB/TBL, keys on the first
        /// ~3 bytes) when the set fits Teddy's 8-needle cap and builds; else
        /// `.none` (pure AC). A union-of-first-bytes scan was tried for the
        /// >8-needle case and DROPPED: A/B showed it is input-dependent (≈2.3×
        /// on keyword-dense text but ≈0.68× on sparse text whose filler words
        /// share the keyword first-byte ranges → false positives dominate), so
        /// large sets like `deep_alternation` (40 kw) stay on pure AC — no
        /// prefilter rather than a gamble. Teddy, by contrast, keys on 3 bytes
        /// so it stays selective regardless of input (A/B: 12–16× either way).
        /// Shared runtime+comptime.
        pre: Pre = .none,

        const Pre = union(enum) {
            none,
            teddy: pf.Teddy,
        };

        /// Build the matcher and choose its prefilter from the literal set.
        pub fn init(ac: AcT, bl: BoundaryLits) Self {
            return .{ .ac = ac, .bl = bl, .pre = buildPre(&bl) };
        }

        /// Choose the prefilter (see `pre`). Pure + comptime-evaluable: `Teddy.build`
        /// is the same allocation-free scalar builder the comptime `.literal` arm
        /// bakes, so the comptime `Pattern` arm bakes the chosen prefilter into
        /// `.rodata` exactly as runtime does. Teddy needs ≤ 8 needles, each ≥ 2
        /// bytes (it returns `null` otherwise ⇒ pure AC).
        fn buildPre(bl: *const BoundaryLits) Pre {
            if (bl.n == 0 or bl.n > pf.Teddy.MAX_NEEDLES) return .none;
            var needles: [pf.Teddy.MAX_NEEDLES][]const u8 = undefined;
            for (0..bl.n) |i| needles[i] = bl.alt(i);
            if (pf.Teddy.build(needles[0..bl.n])) |t| return .{ .teddy = t };
            return .none;
        }

        /// `\b` truth at `pos`, via the canonical `charclass` definition — the
        /// same `lookHolds(.word_boundary)` the bounded/tree backtrackers use, so
        /// the contract is identical to the engine this serves (no divergent copy).
        inline fn wbAt(input: []const u8, pos: usize) bool {
            return cc.lookHolds(@intFromEnum(hir.LookKind.word_boundary), input, pos);
        }

        /// Leftmost-first match length at exactly `p`, or null. Tries the
        /// alternatives in *source order* (regex `a|b` prefers `a`), so this is
        /// independent of which needle Aho-Corasick happened to report.
        fn matchAt(self: *const Self, input: []const u8, p: usize) ?usize {
            if (!wbAt(input, p)) return null;
            var i: usize = 0;
            while (i < self.bl.n) : (i += 1) {
                const L = self.bl.alt(i);
                if (p + L.len <= input.len and
                    std.mem.eql(u8, input[p .. p + L.len], L) and
                    wbAt(input, p + L.len)) return L.len;
            }
            return null;
        }

        /// Leftmost match at/after absolute `from`. With the Teddy prefilter,
        /// locate candidate **starts** (needle occurrences) with SIMD and verify
        /// each via `matchAt` (which re-checks `\b` + tries alts in source order
        /// ⇒ leftmost-first). Every real match start IS a needle occurrence, so
        /// Teddy is a sound necessary condition — it only skips proven-non-start
        /// runs (e.g. `class` in `classy` is located, then `matchAt` rejects it
        /// on the trailing `\b`). Without a prefilter, fall back to the AC walk.
        pub fn find(self: *const Self, input: []const u8, from: usize) ?search.Span {
            switch (self.pre) {
                .none => return self.findAC(input, from),
                .teddy => |*t| {
                    var pos = from;
                    while (t.find(input, pos)) |hit| {
                        if (self.matchAt(input, hit.start)) |len|
                            return .{ .start = hit.start, .end = hit.start + len };
                        pos = hit.start + 1;
                    }
                    return null;
                },
            }
        }

        /// Prefilter-free path: AC gives the minimal needle *end* `e0 ≥ from`;
        /// any leftmost match whose needle ends at `e0` has a start in
        /// `[e0-maxlen+1, e0]` (a shorter needle ending earlier than `e0` would
        /// contradict AC minimality), so brute-scanning that window in increasing
        /// order and trying *all* alternatives is leftmost-correct; otherwise the
        /// match ends > `e0` and we advance.
        fn findAC(self: *const Self, input: []const u8, from: usize) ?search.Span {
            var pos = from;
            while (self.ac.find(input, pos)) |h| {
                const e0 = h.start + h.len - 1; // minimal needle end ≥ pos
                const ml: usize = self.bl.maxlen;
                const lo0 = if (e0 + 1 >= ml) e0 + 1 - ml else 0;
                var p = @max(lo0, from);
                while (p <= e0) : (p += 1) {
                    if (self.matchAt(input, p)) |len| return .{ .start = p, .end = p + len };
                }
                pos = e0 + 1; // every remaining match ends strictly after e0
                if (pos > input.len) break;
            }
            return null;
        }
    };
}

/// Flatten the concat/cap spine into ordered factor refs (≤ `cap_n`, else
/// fail). `.cap` is transparent (a capturing group is rejected later via
/// `n_groups`, but a non-capturing `(?:…)` produces no `.cap` node at all).
fn spineFactors(comptime cap: ?usize, h: *const hir.Hir(cap), ref: NodeRef, out: []NodeRef, n: *usize) bool {
    const nd = h.node(ref);
    switch (nd.tag) {
        .concat => {
            if (!spineFactors(cap, h, nd.a, out, n)) return false;
            return spineFactors(cap, h, nd.b, out, n);
        },
        .cap => return spineFactors(cap, h, nd.a, out, n),
        else => {
            if (n.* >= out.len) return false;
            out[n.*] = ref;
            n.* += 1;
            return true;
        },
    }
}

/// Collect every branch of a (possibly nested) `alt` as a whole literal.
/// Returns false on any non-literal branch, an empty branch, or > `MAX_BL`.
fn collectLitAlts(comptime cap: ?usize, h: *const hir.Hir(cap), ref: NodeRef, bl: *BoundaryLits) bool {
    const nd = h.node(ref);
    if (nd.tag == .alt) {
        return collectLitAlts(cap, h, nd.a, bl) and collectLitAlts(cap, h, nd.b, bl);
    }
    if (nd.tag == .cap) return collectLitAlts(cap, h, nd.a, bl); // transparent
    if (bl.n >= MAX_BL) return false;
    var buf: [MAX_LIT]u8 = undefined;
    const ln = wholeLiteral(cap, h, ref, &buf, 0) orelse return false;
    if (ln == 0) return false;
    bl.lits[bl.n] = buf;
    bl.lens[bl.n] = @intCast(ln);
    bl.n += 1;
    return true;
}

/// If the whole pattern is exactly `\b <pure-literal-alternation> \b`, return
/// its literal set (source order preserved for leftmost-first tie-break).
/// Tight by design: any other shape returns `null` and the caller falls
/// through to the existing path unchanged (so this can never regress).
pub fn boundaryLiterals(comptime cap: ?usize, h: *const hir.Hir(cap)) ?BoundaryLits {
    @setEvalBranchQuota(1_000_000);
    if (h.root == hir.none) return null;
    var fac: [4]NodeRef = undefined;
    var nf: usize = 0;
    if (!spineFactors(cap, h, h.root, &fac, &nf)) return null;
    if (nf != 3) return null;
    const wb: u32 = @intFromEnum(hir.LookKind.word_boundary);
    const f0 = h.node(fac[0]);
    const f2 = h.node(fac[2]);
    if (f0.tag != .look or f0.set_idx != wb) return null;
    if (f2.tag != .look or f2.set_idx != wb) return null;
    var bl = BoundaryLits{};
    if (!collectLitAlts(cap, h, fac[1], &bl)) return null;
    if (bl.n == 0) return null;
    var mx: u8 = 0;
    for (0..bl.n) |i| mx = @max(mx, bl.lens[i]);
    bl.maxlen = mx;
    return bl;
}

/// A byte that *every* match must contain (rarest mandatory single-byte set
/// on the root spine), or null. Necessary condition only — used purely as a
/// `memchr` short-circuit, so it never changes a match outcome, only avoids
/// the unanchored DFA-restart O(n²) when the byte is absent.
pub fn requiredByte(comptime cap: ?usize, h: *const hir.Hir(cap)) ?u8 {
    @setEvalBranchQuota(1_000_000);
    var best: ?u8 = null;
    var bestf: u16 = std.math.maxInt(u16);
    scanRequired(cap, h, h.root, &best, &bestf);
    return best;
}

test "seq_extract: requiredByte picks rarest mandatory spine literal" {
    const parser = @import("../parser.zig");
    const H = hir.Hir(256);
    inline for (.{
        .{ "a.*a.*a.*a.*a.*a.*a.*X", @as(?u8, 'X') },
        .{ ".*.*.*.*.*=.*", @as(?u8, '=') },
        .{ "(a|ab)*c", @as(?u8, 'c') },
        .{ "abc", @as(?u8, 'b') }, // rarest of a,b,c by FREQ (b=15 < c=28 < a=82)
        .{ "a*", @as(?u8, null) }, // nothing mandatory
        .{ "(a|b)+", @as(?u8, null) }, // alt body → not guaranteed
    }) |case| {
        var h = H.initComptime();
        try parser.parse(256, &h, undefined, case[0], .{});
        try std.testing.expectEqual(case[1], requiredByte(256, &h));
    }
}

test "seq_extract: requiredLiteralBack picks most selective literal (reverse-inner)" {
    const parser = @import("../parser.zig");
    const H = hir.Hir(256);
    inline for (.{
        .{ "[a-z]+/api/v2/[a-z]+", "/api/v2/" }, // inner literal, class-back
        .{ "[a-z]+://[a-z]+", "://" }, // uri-shaped: anchor on "://", not ":"
        .{ "[a-z]+CONNECT[a-z]+", "CONNECT" }, // rarer whole run beats any 1 byte
        .{ "abcdef", "abcdef" }, // leading whole literal, fixed-back
        .{ "\\d{3}-\\d{2}-\\d{4}", "-" }, // no consecutive lit run ⇒ single byte
    }) |case| {
        var h = H.initComptime();
        try parser.parse(256, &h, undefined, case[0], .{});
        const rl = requiredLiteralBack(256, &h) orelse return error.NoReqLit;
        try std.testing.expectEqualStrings(case[1], rl.lit[0..rl.len]);
    }
}

test "seq_extract: whole-literal prefix is exact" {
    const parser = @import("../parser.zig");
    const H = hir.Hir(128);
    var h = H.initComptime();
    try parser.parse(128, &h, undefined, "hello", .{});
    const p = prefix(128, &h);
    try std.testing.expectEqual(@as(u8, 1), p.n);
    try std.testing.expect(p.exact);
    try std.testing.expectEqualStrings("hello", p.alt(0));
}

test "seq_extract: leading literal of hello.*world is inexact 'hello'" {
    const parser = @import("../parser.zig");
    const H = hir.Hir(128);
    var h = H.initComptime();
    try parser.parse(128, &h, undefined, "hello.*world", .{});
    const p = prefix(128, &h);
    try std.testing.expectEqualStrings("hello", p.alt(0));
    try std.testing.expect(!p.exact);
    const sfx = suffix(128, &h);
    try std.testing.expectEqualStrings("world", sfx.alt(0));
}

test "seq_extract: \\b(lit|lit|lit)\\b recognised; other shapes rejected" {
    // `\b` is comptime-rejected by the parser (look-assertions are
    // runtime-only), so this recogniser is exercised on the runtime HIR.
    const parser = @import("../parser.zig");
    const a = std.testing.allocator;
    {
        var h = hir.Hir(null).initRuntime();
        defer h.deinit(a);
        try parser.parse(null, &h, a, "\\b(?:break|case|continue)\\b", .{});
        const bl = boundaryLiterals(null, &h).?;
        try std.testing.expectEqual(@as(u16, 3), bl.n);
        try std.testing.expectEqualStrings("break", bl.alt(0));
        try std.testing.expectEqualStrings("case", bl.alt(1));
        try std.testing.expectEqualStrings("continue", bl.alt(2));
        try std.testing.expectEqual(@as(u8, 8), bl.maxlen);
    }
    // Not bracketed by \b on both sides, or extra factor → not recognised.
    inline for (.{ "\\b(?:a|b)", "(?:a|b)\\b", "\\b(?:a|b)c\\b", "\\b(?:a|b+)\\b", "\\B(?:a|b)\\B" }) |p| {
        var h = hir.Hir(null).initRuntime();
        defer h.deinit(a);
        try parser.parse(null, &h, a, p, .{});
        try std.testing.expect(boundaryLiterals(null, &h) == null);
    }
}

test "seq_extract: alternation of literals -> exact multi Seq" {
    const parser = @import("../parser.zig");
    const H = hir.Hir(128);
    var h = H.initComptime();
    try parser.parse(128, &h, undefined, "cat|dog|bird", .{});
    const p = prefix(128, &h);
    try std.testing.expectEqual(@as(u8, 3), p.n);
    try std.testing.expect(p.exact);
    try std.testing.expectEqualStrings("cat", p.alt(0));
    try std.testing.expectEqualStrings("dog", p.alt(1));
    try std.testing.expectEqualStrings("bird", p.alt(2));
}

// 3.1 — small cross-product literal expansion. A leading run with a single
// optional / small-class / literal-alternation wobble expands into the full
// literal set, kept *inexact* (multi-literal) so it drives `.lit_prefix`.

fn expectSet(comptime src: []const u8, expected: []const []const u8, exact: bool) !void {
    const parser = @import("../parser.zig");
    const H = hir.Hir(256);
    var h = H.initComptime();
    try parser.parse(256, &h, undefined, src, .{});
    const p = prefix(256, &h);
    try std.testing.expectEqual(@as(u8, @intCast(expected.len)), p.n);
    try std.testing.expectEqual(exact, p.exact);
    for (expected, 0..) |e, i| try std.testing.expectEqualStrings(e, p.alt(i));
}

test "seq_extract: optional wobble expands (colou?r)" {
    // Whole pattern is the finite set {color, colour}; multi-literal => inexact.
    try expectSet("colou?r", &.{ "color", "colour" }, false);
}

test "seq_extract: small class wobble expands (gr[ae]y)" {
    try expectSet("gr[ae]y", &.{ "gray", "grey" }, false);
}

test "seq_extract: inner literal alternation expands ((?:cat|dog)house)" {
    try expectSet("(?:cat|dog)house", &.{ "cathouse", "doghouse" }, false);
}

test "seq_extract: leading small class produces a prefix where the plain run gave none" {
    // Leads with a class: the old single-run extractor stopped immediately and
    // yielded an empty prefix; expansion yields {xabcdef, yabcdef}.
    try expectSet("[xy]abcdef", &.{ "xabcdef", "yabcdef" }, false);
}

test "seq_extract: expansion stops at an unbounded element (colou?r.*end)" {
    // The trailing `.*end` is non-literal, so the prefix is the expanded head.
    try expectSet("colou?r.*end", &.{ "color", "colour" }, false);
}

test "seq_extract: single whole literal stays exact (pure .literal route)" {
    try expectSet("hello", &.{"hello"}, true);
}

test "seq_extract: wide class is not expanded; run stops before it (ab[0-9]cd)" {
    // `[0-9]` (10 members > SMALL_CLASS_MAX) is a hard stop; prefix is "ab".
    try expectSet("ab[0-9]cd", &.{"ab"}, false);
}

test "seq_extract: leading optional yields no mandatory prefix (v?[0-9]+...)" {
    // `v?` makes the prefix non-mandatory (a match may start with a digit), so
    // the expansion must NOT produce a `{"", "v"}` set — the Seq stays empty.
    const parser = @import("../parser.zig");
    const H = hir.Hir(256);
    var h = H.initComptime();
    try parser.parse(256, &h, undefined, "v?[0-9]+\\.[0-9]+", .{});
    try std.testing.expectEqual(@as(u8, 0), prefix(256, &h).n);
}

test "seq_extract: nullable whole pattern yields no prefix (a?)" {
    const parser = @import("../parser.zig");
    const H = hir.Hir(256);
    var h = H.initComptime();
    try parser.parse(256, &h, undefined, "a?", .{});
    try std.testing.expectEqual(@as(u8, 0), prefix(256, &h).n);
}

test "seq_extract: cross-product over budget stops with the prefix so far" {
    // [ab][cd][ef][gh] = 16 > MAX_ALTS(8): expand the first three (8 alts),
    // then the fourth would overflow, so the run stops at length 3.
    const parser = @import("../parser.zig");
    const H = hir.Hir(256);
    var h = H.initComptime();
    try parser.parse(256, &h, undefined, "[ab][cd][ef][gh]", .{});
    const p = prefix(256, &h);
    try std.testing.expectEqual(@as(u8, 8), p.n);
    try std.testing.expect(!p.exact);
    try std.testing.expectEqual(@as(usize, 3), p.minLen());
}
