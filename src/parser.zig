//! One recursive-descent parser, generic over the `Hir` store, shared by the
//! comptime and runtime pipelines: permissive handling of malformed input,
//! `Unsupported` routing for out-of-language constructs, `{m,n}` expansion
//! (re-parse the atom source per repetition), and ASCII case-fold applied
//! *at set-construction time*. The comptime⇄runtime agreement on the
//! resulting matches is guarded by `tests/feat_api.zig`.

const std = @import("std");
const common = @import("common.zig");
const hir = @import("hir.zig");
const unicode_class = @import("unicode_class.zig");

const Error = hir.Error;
const NodeRef = hir.NodeRef;

// --- Byte-set helpers ------------------

inline fn setBit(out: *[32]u8, c: u8) void {
    out[c >> 3] |= (@as(u8, 1) << @as(u3, @intCast(c & 7)));
}
const hasBit = common.hasBit;

/// Fold ASCII letter bits both ways (case-insensitive matching).
fn foldCaseBitmap(s: *[32]u8) void {
    var c: u8 = 'a';
    while (c <= 'z') : (c += 1) {
        const u = c - 32;
        const lo = hasBit(s, c);
        const hi = hasBit(s, u);
        if (lo or hi) {
            setBit(s, c);
            setBit(s, u);
        }
        if (c == 'z') break;
    }
}

fn singleByteSet(c: u8) [32]u8 {
    var s = [_]u8{0} ** 32;
    setBit(&s, c);
    return s;
}

fn invertSet(s: [32]u8) [32]u8 {
    var r = s;
    for (&r) |*b| b.* = ~b.*;
    return r;
}

/// PCRE 8-bit `\h` (horizontal whitespace): TAB, SPACE, and NBSP (0xA0, the
/// Latin-1 member). Higher Unicode spaces are multibyte → the `(?u)` phase.
fn horizWsSet() [32]u8 {
    var s = [_]u8{0} ** 32;
    setBit(&s, '\t');
    setBit(&s, ' ');
    setBit(&s, 0xA0);
    return s;
}

/// PCRE 8-bit `\v` and the single-char branch of `\R` (vertical whitespace):
/// LF, VT, FF, CR, and NEL (0x85, Latin-1). U+2028/U+2029 are multibyte → the
/// `(?u)` phase.
fn vertWsSet() [32]u8 {
    var s = [_]u8{0} ** 32;
    setBit(&s, '\n');
    setBit(&s, 0x0B);
    setBit(&s, 0x0C);
    setBit(&s, '\r');
    setBit(&s, 0x85);
    return s;
}

fn hexVal(c: u8) ?u32 {
    return switch (c) {
        '0'...'9' => @as(u32, c - '0'),
        'a'...'f' => @as(u32, c - 'a') + 10,
        'A'...'F' => @as(u32, c - 'A') + 10,
        else => null,
    };
}

/// An escaped ASCII punctuation byte is the literal byte, matching the Rust
/// `regex` / RE2 / PCRE rule ("`\x` is literal `x` for any ASCII punctuation").
/// Rust's exact carve-out is "all ASCII except `[0-9A-Za-z<>]`"; we follow it,
/// so `\/ \- \@ \# \: …` are literals while `\<`/`\>` and alphanumeric escapes
/// (`\y`) are NOT covered here — callers reject those as `Unsupported`.
fn escapedPunct(e: u8) ?u8 {
    if (e < 0x80 and !std.ascii.isAlphanumeric(e) and e != '<' and e != '>') return e;
    return null;
}

/// `.` without dot_all: every byte except '\n' (matches `vm.zig`).
fn anySet() [32]u8 {
    var s = [_]u8{0xFF} ** 32;
    const nl: u8 = '\n';
    s[nl >> 3] &= ~(@as(u8, 1) << @as(u3, @intCast(nl & 7)));
    return s;
}

/// `.` under dot_all / `(?s)`: every byte including '\n'.
fn allBytesSet() [32]u8 {
    return [_]u8{0xFF} ** 32;
}

/// Whitespace ignored under extended / `(?x)` mode (outside `[...]` and
/// unescaped): the ASCII blanks plus form-feed and vertical-tab.
fn isExtWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0C or c == 0x0B;
}

fn classToSet(cc: common.CharClass) [32]u8 {
    var s = [_]u8{0} ** 32;
    cc.fillBitmap(&s);
    return s;
}

const MAX_REPEAT: usize = 1000; // `{m,n}` expansion cap (bigger => fallback);
// the `hir.MAX_NODES` ceiling still bounds total expansion (oversized products
// like `(a{1000}){1000}` route to `Error.TooComplex` → `PatternTooComplex`).
const MAX_RANGES: usize = 64; // ranges per `[...]`
// Recursive-descent nesting cap. Each group body recurses one `parseAlt` level;
// non-capturing `(?:` groups do NOT consume a `MAX_GROUPS` slot, so without an
// explicit limit a deeply nested pattern (`(?:(?:(?:…)))`) overflows the native
// stack before any other ceiling trips. Exceeding it → `Error.TooComplex`.
const MAX_PARSE_DEPTH: usize = 1000;

/// Per-parse mode flags. `ci`/`dot_all`/`extended` are scoped by `(?flags)` /
/// `(?flags:..)` exactly like the legacy `(?i)` handling and inherited by the
/// `{m,n}` re-parse sub-parser. `multiline` and `unicode` are deliberately not
/// scoped flags here: `multiline` `^`/`$` line anchors are resolved by a
/// separate prescan (not threaded through this struct), and `unicode` is
/// rejected upstream as a later-phase feature.
pub const ParseFlags = struct {
    ci: bool = false,
    dot_all: bool = false,
    extended: bool = false,
    multiline: bool = false,
};

/// Lower-cased POSIX class name → byte-set class (`[[:name:]]`). Unknown names
/// signal `Error.Unsupported` at the call site.
fn posixClass(name: []const u8) ?common.CharClass {
    const C = common.CharClasses;
    const T = struct { n: []const u8, c: common.CharClass };
    const table = [_]T{
        .{ .n = "alnum", .c = C.posix_alnum }, .{ .n = "alpha", .c = C.posix_alpha },
        .{ .n = "blank", .c = C.posix_blank }, .{ .n = "cntrl", .c = C.posix_cntrl },
        .{ .n = "digit", .c = C.posix_digit }, .{ .n = "graph", .c = C.posix_graph },
        .{ .n = "lower", .c = C.posix_lower }, .{ .n = "print", .c = C.posix_print },
        .{ .n = "punct", .c = C.posix_punct }, .{ .n = "space", .c = C.posix_space },
        .{ .n = "upper", .c = C.posix_upper }, .{ .n = "xdigit", .c = C.posix_xdigit },
    };
    for (table) |e| if (std.mem.eql(u8, name, e.n)) return e.c;
    return null;
}

/// OR a `CharClass`'s post-negation membership into an accumulating bitmap.
fn orClassInto(bm: *[32]u8, cc: common.CharClass) void {
    var t = [_]u8{0} ** 32;
    cc.fillBitmap(&t);
    var k: usize = 0;
    while (k < 32) : (k += 1) bm[k] |= t[k];
}

// --- Anchored prescan ------------------

const Pre = struct { body: []const u8, a_start: bool, a_end: bool };

/// Heuristic pre-scan: does the pattern contain an inline `(?…m…)` /
/// `(?…m…:` flag group enabling multiline? Mirrors the parser's own flag
/// grammar; a rare false positive only forgoes the anchored fast path (still
/// correct — `^`/`$` then parse as look nodes).
fn containsMultilineFlag(pat: []const u8) bool {
    var i: usize = 0;
    while (i + 1 < pat.len) : (i += 1) {
        if (pat[i] != '(' or pat[i + 1] != '?') continue;
        var j = i + 2;
        var saw_m = false;
        while (j < pat.len) : (j += 1) {
            switch (pat[j]) {
                'm' => saw_m = true,
                'i', 's', 'x', '-' => {},
                ':', ')' => break,
                else => break,
            }
        }
        if (saw_m and j < pat.len and (pat[j] == ':' or pat[j] == ')')) return true;
    }
    return false;
}

fn prescan(pattern: []const u8) Pre {
    var s = pattern;
    var a_start = false;
    var a_end = false;
    if (s.len >= 1 and s[0] == '^') {
        a_start = true;
        s = s[1..];
    } else if (s.len >= 2 and s[0] == '\\' and s[1] == 'A') {
        a_start = true;
        s = s[2..];
    }
    // Only `\z` (true end-of-text) folds into the anchored fast path. `\Z`
    // (end before an optional final `\n`) is NOT the same anchor — it routes
    // to a proper `end_text_before_nl` look node (Phase C); folding it here
    // would conflate it with `\z` and mis-handle a trailing newline.
    if (s.len >= 2 and s[s.len - 2] == '\\' and s[s.len - 1] == 'z') {
        var bs: usize = 0;
        var j = s.len - 1;
        while (j > 0) {
            j -= 1;
            if (s[j] == '\\') bs += 1 else break;
        }
        if (bs % 2 == 1) {
            a_end = true;
            s = s[0 .. s.len - 2];
        }
    } else if (s.len >= 1 and s[s.len - 1] == '$') {
        var bs: usize = 0;
        if (s.len >= 2) {
            var j = s.len - 1;
            while (j > 0) {
                j -= 1;
                if (s[j] == '\\') bs += 1 else break;
            }
        }
        if (bs % 2 == 0) {
            a_end = true;
            s = s[0 .. s.len - 1];
        }
    }
    return .{ .body = s, .a_start = a_start, .a_end = a_end };
}

/// True if `pat` has a top-level (depth-0, outside `[...]`, unescaped)
/// alternation `|`. With the lowest-precedence `|`, a leading `^`/`\A` or
/// trailing `$`/`\z` then binds to a SINGLE branch (`^a|b` ≡ `(^a)|b`), so the
/// prescan must NOT fold it into the whole-pattern anchored fast path — the
/// anchors stay as look leaves and each branch is anchored on its own.
/// Conservative like `containsMultilineFlag`: a rare false positive only
/// forgoes the fast path (still correct), never a false negative.
fn hasTopLevelAlt(pat: []const u8) bool {
    var i: usize = 0;
    var depth: usize = 0;
    var in_class = false;
    while (i < pat.len) : (i += 1) {
        const c = pat[i];
        if (c == '\\') {
            i += 1; // skip the escaped byte
            continue;
        }
        if (in_class) {
            if (c == ']') in_class = false;
            continue;
        }
        switch (c) {
            '[' => in_class = true,
            '(' => depth += 1,
            ')' => {
                if (depth > 0) depth -= 1;
            },
            '|' => if (depth == 0) return true,
            else => {},
        }
    }
    return false;
}

/// Parse `src` into `h` (prescan + grammar). On success sets `h.root`,
/// `h.anchored_start/end`, `h.saw_lazy`. Mirrors the front half of the old
/// `computeDfa`: empty pattern, trailing garbage and `anchored_end && lazy`
/// all route to `Error.Unsupported`.
pub fn parse(
    comptime cap: ?usize,
    h: *hir.Hir(cap),
    allocator: std.mem.Allocator,
    src: []const u8,
    flags: ParseFlags,
) Error!void {
    return parseInner(cap, h, allocator, src, flags, null, null);
}

/// Like `parse`, but also reports the capture-group numbering — the SINGLE
/// source of truth, replacing the old standalone `scanGroups` byte-scanner that
/// re-implemented the grammar a second time and could drift from it. `out_ng.*`
/// = the number of capturing groups (group 0 = whole match, so user groups are
/// 1..N); `out_gnames.*[g]` = group `g`'s `(?<name>)` name, else `null`. Groups
/// inside a lookaround, `(?:`/`(?>`, and a `{m,n}` re-parse's repeated copies are
/// non-capturing and excluded (see `openGroup`/`lookAround`), so this matches the
/// `.cap` nodes the parser emits by construction. The name slices alias `src`, so
/// a caller that outlives the parse (the runtime `Regex`) must pass a buffer it
/// keeps alive (the owned pattern), not a transient input.
pub fn parseCaptures(
    comptime cap: ?usize,
    h: *hir.Hir(cap),
    allocator: std.mem.Allocator,
    src: []const u8,
    flags: ParseFlags,
    out_ng: *usize,
    out_gnames: *[hir.MAX_GROUPS + 1]?[]const u8,
) Error!void {
    return parseInner(cap, h, allocator, src, flags, out_ng, out_gnames);
}

fn parseInner(
    comptime cap: ?usize,
    h: *hir.Hir(cap),
    allocator: std.mem.Allocator,
    src: []const u8,
    flags: ParseFlags,
    out_ng: ?*usize,
    out_gnames: ?*[hir.MAX_GROUPS + 1]?[]const u8,
) Error!void {
    if (src.len == 0) return Error.Unsupported;

    // Extended mode: leading ignorable whitespace must not hide the `^`/`\A`
    // prescan anchor. (Trailing-whitespace-before-`$` under `(?x)` is a known
    // Phase-A edge — the inline skipper still strips it during the body parse.)
    var raw = src;
    if (flags.extended) {
        while (raw.len > 0 and isExtWs(raw[0])) raw = raw[1..];
        if (raw.len == 0) return Error.Unsupported;
    }

    // `(?m)` makes `^`/`$` line anchors, so the prescan must NOT strip a
    // leading `^` / trailing `$` into the anchored-fast-path booleans — they
    // become `start_line`/`end_line` look nodes instead. Detecting an inline
    // `m` flag (or the compile flag) disables prescan entirely; pure-anchor
    // patterns keep the boolean fast path (Q3: zero blast radius).
    // A top-level `|` makes a leading `^` / trailing `$` bind to one branch
    // only, so folding it into the whole-pattern anchored fast path is wrong
    // (`^a|b` must still match `b` anywhere). As with multiline, skip the
    // prescan in that case: `^`/`$`/`\A`/`\z` then parse as look leaves and the
    // tree backtracker anchors each branch independently.
    const ml = flags.multiline or containsMultilineFlag(raw);
    const pre: Pre = if (ml or hasTopLevelAlt(raw))
        .{ .body = raw, .a_start = false, .a_end = false }
    else
        prescan(raw);
    h.anchored_start = pre.a_start;
    h.anchored_end = pre.a_end;

    var p = Parser(cap){
        .pat = pre.body,
        .h = h,
        .alloc = allocator,
        .ci = flags.ci,
        .dot_all = flags.dot_all,
        .extended = flags.extended,
        .multiline = flags.multiline,
    };
    const root = try p.parseAlt();
    p.skipExt(); // trailing ignorable ws / `#…` comment under `(?x)`
    if (p.i != pre.body.len) return Error.Invalid;

    // Reject a numeric backreference to a group that does not exist anywhere in
    // the pattern (`(a)\2`, `\1` with no groups). Validated post-parse against
    // the final group count so forward refs to a group that *does* exist (and
    // `\1{2}`, whose re-parse sub-parser sees `n_groups == 0`) stay valid.
    // Without this the backtracker reads an uninitialized capture slot. Named
    // backrefs are already validated at parse time via `lookupName`.
    if (p.max_backref > p.n_groups) return Error.Invalid;

    // Lazy + end-anchor (`a*?$`): the leftmost-first DFA accept-cut cannot
    // honor "earliest lazy accept" *and* "accept == end-of-text" at once, so
    // the construction cut can't model it. Rather than reject, `properties`
    // flags `saw_lazy && anchored_end` as `requires_backtracking` and routes it
    // to the tree backtracker, which handles lazy (`nd.greedy`) and the
    // end-anchor (`accept_at = len`) independently and correctly.
    h.root = root;
    h.saw_lazy = p.saw_lazy;

    // Single-source-of-truth capture numbering: hand back the parser's
    // authoritative group count + `(?<name>)` names (already excludes groups
    // inside a lookaround / `(?:`/`(?>` / `{m,n}` re-parse copies). This is what
    // the standalone `scanGroups` byte-scanner used to recompute independently.
    if (out_ng) |p_ng| p_ng.* = p.n_groups;
    if (out_gnames) |g| {
        g.* = [_]?[]const u8{null} ** (hir.MAX_GROUPS + 1);
        var k: usize = 0;
        while (k < p.n_names) : (k += 1) g.*[p.name_g[k]] = p.names[k];
    }
}

fn Parser(comptime cap: ?usize) type {
    return struct {
        const Self = @This();
        const H = hir.Hir(cap);

        pat: []const u8,
        i: usize = 0,
        h: *H,
        alloc: std.mem.Allocator,
        /// Mode state, each scoped by `(?flags)` / `(?flags:..)` and inherited
        /// by the `{m,n}` re-parse sub-parser.
        ci: bool = false,
        dot_all: bool = false,
        extended: bool = false,
        multiline: bool = false,
        saw_lazy: bool = false,
        /// Capture-group numbering (group 0 = whole match, so user groups
        /// start at 1) + seen names (duplicate detection only; runtime
        /// name→index is re-derived in regex.zig).
        n_groups: usize = 0,
        capturing: bool = true,
        names: [hir.MAX_GROUPS][]const u8 = undefined,
        name_g: [hir.MAX_GROUPS]u32 = undefined,
        n_names: usize = 0,
        /// Recursive-descent nesting depth (one level per group body), guarded
        /// against stack overflow in `parseAlt`. See `MAX_PARSE_DEPTH`.
        depth: usize = 0,
        /// Highest numeric backreference seen (`\N`), validated against the final
        /// group count after parsing (see `parse`) to reject dangling refs.
        max_backref: u32 = 0,

        const Modes = struct { ci: bool, dot_all: bool, extended: bool, multiline: bool };
        fn modes(p: *const Self) Modes {
            return .{ .ci = p.ci, .dot_all = p.dot_all, .extended = p.extended, .multiline = p.multiline };
        }
        fn restore(p: *Self, m: Modes) void {
            p.ci = m.ci;
            p.dot_all = m.dot_all;
            p.extended = m.extended;
            p.multiline = m.multiline;
        }

        /// Reserve this group's number *before* its body is parsed, so nesting
        /// is numbered in opening-paren order (standard). The final `p.n_groups`
        /// + recorded names are handed back by `parseCaptures` (the single source
        /// of truth for capture numbering). Returns 0 for a non-capturing context
        /// (a `{m,n}` re-parse: repeated copies must not mis-number — that atom's
        /// captures are simply not reported, a documented Phase-D limitation).
        fn openGroup(p: *Self, name: ?[]const u8) Error!u32 {
            if (!p.capturing) return 0;
            if (p.n_groups >= hir.MAX_GROUPS) return Error.TooComplex;
            p.n_groups += 1;
            if (name) |nm| {
                if (nm.len == 0) return Error.Invalid;
                var k: usize = 0;
                while (k < p.n_names) : (k += 1)
                    if (std.mem.eql(u8, p.names[k], nm)) return Error.Invalid; // dup name
                p.names[p.n_names] = nm;
                p.name_g[p.n_names] = @intCast(p.n_groups);
                p.n_names += 1;
            }
            return @intCast(p.n_groups);
        }

        fn closeGroup(p: *Self, g: u32, inner: NodeRef) Error!NodeRef {
            if (g == 0) return inner; // non-capturing
            return p.node(.{ .tag = .cap, .a = inner, .set_idx = g });
        }

        fn lookupName(p: *const Self, nm: []const u8) ?u32 {
            var k: usize = 0;
            while (k < p.n_names) : (k += 1)
                if (std.mem.eql(u8, p.names[k], nm)) return p.name_g[k];
            return null;
        }

        /// `(?=…)`/`(?!…)`/`(?<=…)`/`(?<!…)` (caller consumed the marker;
        /// positioned at the sub-expression). Non-regular → `look_around`
        /// node for the tree backtracker. Captures inside a lookaround are
        /// not reconstructed (Phase-E limitation): parse non-capturing.
        fn lookAround(p: *Self, behind: bool, neg: bool) Error!NodeRef {
            const sub = p.capturing;
            p.capturing = false;
            const saved = p.modes();
            const inner = try p.parseAlt();
            p.restore(saved);
            p.capturing = sub;
            if (p.peek() != ')') return Error.Invalid;
            p.i += 1;
            var fl: u32 = 0;
            if (behind) fl |= hir.LA_BEHIND;
            if (neg) fl |= hir.LA_NEGATIVE;
            return p.node(.{ .tag = .look_around, .a = inner, .set_idx = fl });
        }

        fn parseBackref(p: *Self, first: u8) Error!NodeRef {
            var g: u32 = first - '0';
            while (p.peek()) |ch| {
                if (ch < '0' or ch > '9') break;
                g = g * 10 + (ch - '0');
                p.i += 1;
                if (g > hir.MAX_GROUPS) return Error.Invalid;
            }
            if (g == 0) return Error.Invalid;
            // Record the highest referenced group for a post-parse validation
            // (see `parse`). An at-site `g > n_groups` check would wrongly reject
            // `\1{2}` (the `{m,n}` re-parse sub-parser has `n_groups == 0`); the
            // post-parse check against the final group count is correct and also
            // covers backrefs inside lookarounds.
            if (g > p.max_backref) p.max_backref = g;
            return p.node(.{ .tag = .backref, .set_idx = g });
        }

        fn parseNamedBackref(p: *Self) Error!NodeRef {
            if (p.peek() != '<') return Error.Invalid;
            p.i += 1;
            const s = p.i;
            while (p.peek()) |ch| {
                if (ch == '>') break;
                p.i += 1;
            }
            if (p.peek() != '>') return Error.Invalid;
            const nm = p.pat[s..p.i];
            p.i += 1;
            const g = p.lookupName(nm) orelse return Error.Invalid;
            return p.node(.{ .tag = .backref, .set_idx = g });
        }

        /// `\xHH` (up to two hex digits; `\x` alone ⇒ NUL, like PCRE) or
        /// `\x{H…}` (braced). Byte-valued: a value > 0xFF (only reachable via
        /// the braced form) is `Unsupported`, reserved for the codepoint `(?u)`
        /// phase — never silently truncated. Caller has consumed the `x`.
        fn parseHexByte(p: *Self) Error!u8 {
            if (p.peek() == '{') {
                p.i += 1;
                var v: u32 = 0;
                var n: usize = 0;
                while (p.peek()) |ch| {
                    const d = hexVal(ch) orelse break;
                    v = v * 16 + d;
                    n += 1;
                    p.i += 1;
                    if (v > 0xFF) return Error.Unsupported; // > one byte ⇒ (?u)
                }
                if (n == 0) return Error.Invalid;
                if (p.peek() != '}') return Error.Invalid;
                p.i += 1;
                return @intCast(v);
            }
            var v: u32 = 0;
            var n: usize = 0;
            while (n < 2) : (n += 1) {
                const ch = p.peek() orelse break;
                const d = hexVal(ch) orelse break;
                v = v * 16 + d;
                p.i += 1;
            }
            return @intCast(v);
        }

        /// `\0`, `\0o`, `\0oo` — leading-zero octal, up to two further octal
        /// digits (≤ 0o77, always one byte). Caller has consumed the leading
        /// `0`. `\1`–`\9` stay backreferences, never octal (PCRE/Perl rule).
        fn parseOctalAfterZero(p: *Self) u8 {
            var v: u32 = 0;
            var n: usize = 0;
            while (n < 2) : (n += 1) {
                const ch = p.peek() orelse break;
                if (ch < '0' or ch > '7') break;
                v = v * 8 + (ch - '0');
                p.i += 1;
            }
            return @intCast(v);
        }

        /// `\o{ooo}` — braced octal. > 0xFF ⇒ `Unsupported` (the `(?u)`
        /// follow-on). Caller has consumed the `o`.
        fn parseOctalBraced(p: *Self) Error!u8 {
            if (p.peek() != '{') return Error.Invalid;
            p.i += 1;
            var v: u32 = 0;
            var n: usize = 0;
            while (p.peek()) |ch| {
                if (ch < '0' or ch > '7') break;
                v = v * 8 + (ch - '0');
                n += 1;
                p.i += 1;
                if (v > 0xFF) return Error.Unsupported;
            }
            if (n == 0) return Error.Invalid;
            if (p.peek() != '}') return Error.Invalid;
            p.i += 1;
            return @intCast(v);
        }

        /// `\R` — line break. PCRE 8-bit default: `(?:\r\n | [\n\x0B\f\r\x85])`.
        /// Kept a plain (non-atomic) alternation so it stays on the DFA path;
        /// the only divergence from PCRE's atomic `\R` is the rare overlap case
        /// (e.g. `\R\n` on "\r\n\n"), noted in PCRE_COMPATIBILITY.md.
        fn parseLineBreak(p: *Self) Error!NodeRef {
            const cr = try p.setLeaf(singleByteSet('\r'));
            const lf = try p.setLeaf(singleByteSet('\n'));
            const crlf = try p.node(.{ .tag = .concat, .a = cr, .b = lf });
            const any_nl = try p.setLeaf(vertWsSet());
            return p.node(.{ .tag = .alt, .a = crlf, .b = any_nl });
        }

        fn lookLeaf(p: *Self, kind: hir.LookKind) Error!NodeRef {
            // Look-assertions (`\b \B`, `\A \z \Z`, `(?m)^ $`) are evaluated by
            // the tree backtracker — at runtime via `.bt_look`, and at comptime
            // via the SAME `cc.lookHolds` in the comptime-baked backtracker
            // (`pattern.zig`'s `.backtrack` arm, routed by `props.has_look`). So
            // the `.look` node is built for both stores; what must NOT happen is
            // a look reaching the DFA arm (which cannot fold conditional
            // epsilons) — `properties.has_look` ⇒ `requires_backtracking`
            // guarantees it doesn't. (Pre-comptime-backtracker this was a hard
            // `cap != null` reject; the backtracker made that unnecessary.)
            return p.node(.{ .tag = .look, .set_idx = @intFromEnum(kind) });
        }

        fn peek(p: *const Self) ?u8 {
            return if (p.i < p.pat.len) p.pat[p.i] else null;
        }

        /// Extended mode: consume ignorable whitespace and `#…\n` line
        /// comments. Never called from inside `[...]` (class parsing uses
        /// `classChar`/raw `peek`), so class content is unaffected.
        fn skipExt(p: *Self) void {
            if (!p.extended) return;
            while (p.i < p.pat.len) {
                const c = p.pat[p.i];
                if (isExtWs(c)) {
                    p.i += 1;
                } else if (c == '#') {
                    p.i += 1;
                    while (p.i < p.pat.len and p.pat[p.i] != '\n') p.i += 1;
                } else break;
            }
        }

        fn node(p: *Self, n: hir.HNode) Error!NodeRef {
            return p.h.addNode(p.alloc, n);
        }

        /// A set leaf — folds case at construction time exactly like the old
        /// `Builder.addSet`, so produced bitmaps are byte-identical.
        fn setLeaf(p: *Self, set: [32]u8) Error!NodeRef {
            var s = set;
            if (p.ci) foldCaseBitmap(&s);
            const idx = try p.h.addSet(p.alloc, s);
            return p.node(.{ .tag = .set, .set_idx = idx });
        }

        fn emptyLeaf(p: *Self) Error!NodeRef {
            return p.node(.{ .tag = .empty });
        }

        fn parseAlt(p: *Self) Error!NodeRef {
            // Bound recursion: every group body re-enters here, and `(?:` groups
            // bypass the `MAX_GROUPS` ceiling, so this is the only guard against
            // a deeply nested pattern overflowing the native stack.
            p.depth += 1;
            defer p.depth -= 1;
            if (p.depth > MAX_PARSE_DEPTH) return Error.TooComplex;
            var left = try p.parseConcat();
            while (p.peek() == '|') {
                p.i += 1;
                const right = try p.parseConcat();
                left = try p.node(.{ .tag = .alt, .a = left, .b = right });
            }
            return left;
        }

        fn parseConcat(p: *Self) Error!NodeRef {
            var cur: ?NodeRef = null;
            while (true) {
                p.skipExt();
                const c = p.peek() orelse break;
                if (c == '|' or c == ')') break;
                const f = try p.parseRepeat();
                if (cur) |prev| {
                    cur = try p.node(.{ .tag = .concat, .a = prev, .b = f });
                } else cur = f;
            }
            return cur orelse try p.emptyLeaf();
        }

        fn parseRepeat(p: *Self) Error!NodeRef {
            const atom_start = p.i;
            var f = try p.parsePrimary();
            const atom_src = p.pat[atom_start..p.i];

            p.skipExt(); // `a {2}` / `a *` — ws between atom and quantifier
            const c = p.peek() orelse return f;
            switch (c) {
                '*' => {
                    p.i += 1;
                    const q = try p.quantMod();
                    f = try p.node(.{ .tag = .star, .a = f, .greedy = q != .lazy });
                    if (q == .possessive) f = try p.atomicWrap(f);
                },
                '+' => {
                    p.i += 1;
                    const q = try p.quantMod();
                    f = try p.node(.{ .tag = .plus, .a = f, .greedy = q != .lazy });
                    if (q == .possessive) f = try p.atomicWrap(f);
                },
                '?' => {
                    p.i += 1;
                    const q = try p.quantMod();
                    f = try p.node(.{ .tag = .opt, .a = f, .greedy = q != .lazy });
                    if (q == .possessive) f = try p.atomicWrap(f);
                },
                '{' => {
                    const br = try p.parseBrace();
                    const q = try p.quantMod();
                    f = try p.expand(atom_src, br.min, br.max, q != .lazy);
                    if (q == .possessive) f = try p.atomicWrap(f);
                },
                else => return f,
            }
            p.skipExt();
            if (p.peek()) |n| {
                if (n == '*' or n == '+' or n == '?' or n == '{') return Error.Invalid;
            }
            return f;
        }

        /// Greedy / lazy / possessive modifier following a quantifier.
        const Quant = enum { greedy, lazy, possessive };

        fn quantMod(p: *Self) Error!Quant {
            if (p.peek() == '?') {
                p.i += 1;
                p.saw_lazy = true;
                return .lazy;
            }
            if (p.peek() == '+') {
                // Possessive (`*+`/`++`/`?+`/`{m,n}+`): the caller wraps the
                // greedy quantifier in an `.atomic` node — `a*+` ≡ `(?>a*)`,
                // semantically exact. (The pattern is then non-regular and
                // routes to the tree backtracker.)
                p.i += 1;
                return .possessive;
            }
            return .greedy;
        }

        /// Wrap `f` in an atomic group (`(?>f)`). Shared by `(?>…)` groups and
        /// the possessive-quantifier lowering.
        fn atomicWrap(p: *Self, f: NodeRef) Error!NodeRef {
            return p.node(.{ .tag = .atomic, .a = f });
        }

        const Brace = struct { min: usize, max: ?usize };

        fn parseBrace(p: *Self) Error!Brace {
            p.i += 1; // consume '{'
            var min: usize = 0;
            var saw_min = false;
            while (p.peek()) |d| {
                if (d < '0' or d > '9') break;
                min = min * 10 + (d - '0');
                saw_min = true;
                p.i += 1;
                if (min > MAX_REPEAT) return Error.Unsupported;
            }
            if (!saw_min) return Error.Invalid;
            var max: ?usize = min;
            if (p.peek() == ',') {
                p.i += 1;
                if (p.peek()) |d0| {
                    if (d0 >= '0' and d0 <= '9') {
                        var mx: usize = 0;
                        while (p.peek()) |d| {
                            if (d < '0' or d > '9') break;
                            mx = mx * 10 + (d - '0');
                            p.i += 1;
                            if (mx > MAX_REPEAT) return Error.Unsupported;
                        }
                        max = mx;
                    } else max = null; // {m,}
                } else max = null;
            }
            if (p.peek() != '}') return Error.Invalid;
            p.i += 1;
            if (max) |mx| {
                if (min > mx) return Error.Invalid;
            }
            return .{ .min = min, .max = max };
        }

        /// Re-parse the atom source into a fresh subtree (mirrors the old
        /// `buildAtom`, which re-parsed per repetition into fresh NFA states).
        fn buildAtom(p: *Self, src: []const u8) Error!NodeRef {
            var sub = Self{
                .pat = src,
                .h = p.h,
                .alloc = p.alloc,
                .ci = p.ci,
                .dot_all = p.dot_all,
                .extended = p.extended,
                .multiline = p.multiline,
                .capturing = false,
            };
            const f = try sub.parsePrimary();
            if (sub.i != src.len) return Error.Invalid;
            if (sub.saw_lazy) p.saw_lazy = true;
            return f;
        }

        fn star(p: *Self, child: NodeRef, greedy: bool) Error!NodeRef {
            return p.node(.{ .tag = .star, .a = child, .greedy = greedy });
        }
        fn plus(p: *Self, child: NodeRef, greedy: bool) Error!NodeRef {
            return p.node(.{ .tag = .plus, .a = child, .greedy = greedy });
        }
        fn opt(p: *Self, child: NodeRef, greedy: bool) Error!NodeRef {
            return p.node(.{ .tag = .opt, .a = child, .greedy = greedy });
        }
        fn concat(p: *Self, x: NodeRef, y: NodeRef) Error!NodeRef {
            return p.node(.{ .tag = .concat, .a = x, .b = y });
        }

        /// `{m,n}` expansion — structurally identical to the old `expand`
        /// (one freshly-parsed atom copy per repetition; same opt/star tail).
        fn expand(p: *Self, src: []const u8, min: usize, max: ?usize, greedy: bool) Error!NodeRef {
            if (min == 0 and max == null) return p.star(try p.buildAtom(src), greedy);
            if (min == 1 and max == null) return p.plus(try p.buildAtom(src), greedy);
            if (min == 0) {
                const mx = max.?;
                if (mx == 0) return p.emptyLeaf();
                var cur = try p.opt(try p.buildAtom(src), greedy);
                var k: usize = 1;
                while (k < mx) : (k += 1) {
                    const o = try p.opt(try p.buildAtom(src), greedy);
                    cur = try p.concat(cur, o);
                }
                return cur;
            }
            var cur = try p.buildAtom(src);
            var k: usize = 1;
            while (k < min) : (k += 1) {
                const nx = try p.buildAtom(src);
                cur = try p.concat(cur, nx);
            }
            if (max) |mx| {
                var d: usize = 0;
                while (d < mx - min) : (d += 1) {
                    const o = try p.opt(try p.buildAtom(src), greedy);
                    cur = try p.concat(cur, o);
                }
            } else {
                const st = try p.star(try p.buildAtom(src), greedy);
                cur = try p.concat(cur, st);
            }
            return cur;
        }

        fn parsePrimary(p: *Self) Error!NodeRef {
            const c = p.peek() orelse return Error.Invalid;
            switch (c) {
                '(' => {
                    p.i += 1;
                    if (p.peek() == '?') {
                        p.i += 1;
                        const k = p.peek() orelse return Error.Invalid;
                        // Lookahead (?=…) / (?!…) (Phase E).
                        if (k == '=') {
                            p.i += 1;
                            return p.lookAround(false, false);
                        }
                        if (k == '!') {
                            p.i += 1;
                            return p.lookAround(false, true);
                        }
                        // Named capture (?<name>…)/(?P<name>…) or lookbehind
                        // (?<=…)/(?<!…) (Phase E).
                        if (k == '<' or k == 'P') {
                            p.i += 1;
                            if (k == 'P') {
                                if (p.peek() != '<') return Error.Unsupported; // (?P=… → \k handles named backref
                                p.i += 1;
                            } else {
                                const nx = p.peek() orelse return Error.Invalid;
                                if (nx == '=') {
                                    p.i += 1;
                                    return p.lookAround(true, false);
                                }
                                if (nx == '!') {
                                    p.i += 1;
                                    return p.lookAround(true, true);
                                }
                            }
                            const ns = p.i;
                            while (p.peek()) |ch| {
                                if (ch == '>') break;
                                p.i += 1;
                            }
                            if (p.peek() != '>') return Error.Invalid;
                            const name = p.pat[ns..p.i];
                            p.i += 1; // consume '>'
                            const g = try p.openGroup(name);
                            const saved = p.modes();
                            const inner = try p.parseAlt();
                            p.restore(saved);
                            if (p.peek() != ')') return Error.Invalid;
                            p.i += 1;
                            return p.closeGroup(g, inner);
                        }
                        if (k == '>') {
                            // Atomic group `(?>…)`: non-capturing + commit.
                            p.i += 1;
                            const saved = p.modes();
                            const inner = try p.parseAlt();
                            p.restore(saved);
                            if (p.peek() != ')') return Error.Invalid;
                            p.i += 1;
                            return p.atomicWrap(inner);
                        }
                        if (k == ':') {
                            p.i += 1;
                            const saved = p.modes();
                            const inner = try p.parseAlt();
                            p.restore(saved);
                            if (p.peek() != ')') return Error.Invalid;
                            p.i += 1;
                            return inner;
                        }
                        if (k == 'i' or k == 'm' or k == 's' or k == 'x' or k == '-') {
                            var want_ci = p.ci;
                            var want_dot = p.dot_all;
                            var want_ext = p.extended;
                            var want_ml = p.multiline;
                            var clearing = false;
                            while (p.peek()) |fc| {
                                switch (fc) {
                                    '-' => clearing = true,
                                    'i' => want_ci = !clearing,
                                    's' => want_dot = !clearing,
                                    'x' => want_ext = !clearing,
                                    'm' => want_ml = !clearing,
                                    else => break,
                                }
                                p.i += 1;
                            }
                            const term = p.peek() orelse return Error.Invalid;
                            if (term == ':') {
                                p.i += 1;
                                const saved = p.modes();
                                p.ci = want_ci;
                                p.dot_all = want_dot;
                                p.extended = want_ext;
                                p.multiline = want_ml;
                                const inner = try p.parseAlt();
                                p.restore(saved);
                                if (p.peek() != ')') return Error.Invalid;
                                p.i += 1;
                                return inner;
                            }
                            if (term == ')') {
                                p.i += 1;
                                p.ci = want_ci;
                                p.dot_all = want_dot;
                                p.extended = want_ext;
                                p.multiline = want_ml;
                                return p.emptyLeaf();
                            }
                            return Error.Invalid;
                        }
                        return Error.Unsupported;
                    }
                    const g = try p.openGroup(null);
                    const saved = p.modes();
                    const inner = try p.parseAlt();
                    p.restore(saved);
                    if (p.peek() != ')') return Error.Invalid;
                    p.i += 1;
                    return p.closeGroup(g, inner);
                },
                ')', '|' => return Error.Invalid,
                '*', '+', '?', '{', '}' => return Error.Invalid,
                '[' => return p.parseClass(),
                '.' => {
                    p.i += 1;
                    return p.setLeaf(if (p.dot_all) allBytesSet() else anySet());
                },
                '^' => {
                    p.i += 1;
                    return p.lookLeaf(if (p.multiline) .start_line else .start_text);
                },
                '$' => {
                    p.i += 1;
                    return p.lookLeaf(if (p.multiline) .end_line else .end_text);
                },
                '\\' => {
                    p.i += 1;
                    const e = p.peek() orelse return Error.Invalid;
                    p.i += 1;
                    return switch (e) {
                        'd' => p.setLeaf(classToSet(common.CharClasses.digit)),
                        'D' => p.setLeaf(classToSet(common.CharClasses.non_digit)),
                        'w' => p.setLeaf(classToSet(common.CharClasses.word)),
                        'W' => p.setLeaf(classToSet(common.CharClasses.non_word)),
                        's' => p.setLeaf(classToSet(common.CharClasses.whitespace)),
                        'S' => p.setLeaf(classToSet(common.CharClasses.non_whitespace)),
                        'n' => p.setLeaf(singleByteSet('\n')),
                        't' => p.setLeaf(singleByteSet('\t')),
                        'r' => p.setLeaf(singleByteSet('\r')),
                        ' ' => p.setLeaf(singleByteSet(' ')), // `\ ` literal space (extended mode)
                        'x' => p.setLeaf(singleByteSet(try p.parseHexByte())),
                        'o' => p.setLeaf(singleByteSet(try p.parseOctalBraced())),
                        '0' => p.setLeaf(singleByteSet(p.parseOctalAfterZero())),
                        'h' => p.setLeaf(horizWsSet()),
                        'H' => p.setLeaf(invertSet(horizWsSet())),
                        'v' => p.setLeaf(vertWsSet()),
                        'V' => p.setLeaf(invertSet(vertWsSet())),
                        'N' => p.setLeaf(anySet()), // any byte except '\n' (unaffected by (?s))
                        'R' => p.parseLineBreak(),
                        'p', 'P' => p.parsePropClass(e == 'P'),
                        'b' => p.lookLeaf(.word_boundary),
                        'B' => p.lookLeaf(.non_word_boundary),
                        'A' => p.lookLeaf(.start_text),
                        'z' => p.lookLeaf(.end_text),
                        'Z' => p.lookLeaf(.end_text_before_nl),
                        '1', '2', '3', '4', '5', '6', '7', '8', '9' => p.parseBackref(e),
                        'k' => p.parseNamedBackref(),
                        // Escaped ASCII punctuation (incl. `\/`) is the literal
                        // byte; alphanumerics not matched above stay unsupported.
                        else => if (escapedPunct(e)) |lit| p.setLeaf(singleByteSet(lit)) else Error.Unsupported,
                    };
                },
                else => {
                    p.i += 1;
                    return p.setLeaf(singleByteSet(c));
                },
            }
        }

        /// `\p{Name}` / `\P{Name}` / `\pL` — resolve the General_Category
        /// property to codepoint ranges, then build the **byte set** of its
        /// members ≤ 0xFF (one `.set` leaf). This is the byte-oriented engine's
        /// honest semantics (Latin-1 restriction, exactly Rust/RE2 with
        /// Unicode-mode off): a full multibyte UTF-8 `\p` automaton would blow
        /// the `MAX_NFA`/`MAX_NODES` ceilings, so codepoint-aware `\p` is the
        /// documented `(?u)` follow-on. The resolver is allocator-free, so
        /// this works on the comptime `Pattern` path too (baked like `[a-z]`);
        /// only `\p` under `(?i)` stays rejected (the simple-fold follow-on).
        fn parsePropClass(p: *Self, negated: bool) Error!NodeRef {
            const bm = try p.readPropBitmap(negated);
            return p.setLeaf(bm); // empty bitmap ⇒ matches nothing (valid)
        }

        /// Resolve `\p{Name}` / `\pL` (caller has already consumed the
        /// `p`/`P`; `negated` ⇔ `\P`) to the byte set of its members ≤ 0xFF
        /// — the Latin-1 restriction documented above. Shared by the
        /// standalone-`\p` leaf and the in-`[...]` member path so both keep
        /// byte-identical semantics.
        fn readPropBitmap(p: *Self, negated: bool) Error![32]u8 {
            if (p.ci) return Error.Unsupported; // (?i)+\p: follow-on

            var spec: []const u8 = undefined;
            if (p.peek() == '{') {
                p.i += 1;
                const s = p.i;
                while (p.peek()) |ch| {
                    if (ch == '}') break;
                    p.i += 1;
                }
                if (p.peek() != '}') return Error.Invalid;
                spec = p.pat[s..p.i];
                p.i += 1; // consume '}'
            } else {
                if (p.peek() == null) return Error.Invalid;
                spec = p.pat[p.i .. p.i + 1];
                p.i += 1;
            }

            // Allocator-free: a regular Latin-1 byte set, so this resolves at
            // comptime exactly like `[a-z]` (no heap → comptime `Pattern` bakes
            // `\p` instead of rejecting it). Byte-identical to the old
            // allocator path; see `unicode_class.resolveLatin1Bitmap`.
            // `resolveLatin1Bitmap` is allocator-free; its only errors are the
            // two property-resolution ones (both → an unsupported feature).
            return unicode_class.resolveLatin1Bitmap(spec, negated) catch |e| return switch (e) {
                error.UnknownUnicodeProperty, error.UnsupportedUnicodeProperty => Error.Unsupported,
            };
        }

        /// `[...]` accumulated straight into a 256-bit membership bitmap so it
        /// can mix literals/ranges with shorthand (`\d \D \w \W \s \S`) and
        /// POSIX (`[[:alpha:]]`, `[[:^digit:]]`). For plain-range classes the
        /// produced bitmap (positive built, inverted if negated, then
        /// case-folded by `setLeaf`) is byte-identical to the old
        /// `fillBitmap`-based path, preserving NFA parity.
        fn parseClass(p: *Self) Error!NodeRef {
            p.i += 1; // consume '['
            var negated = false;
            if (p.peek() == '^') {
                negated = true;
                p.i += 1;
            }
            var bm = [_]u8{0} ** 32;

            while (true) {
                const c = p.peek() orelse return Error.Invalid;
                if (c == ']') break;

                // POSIX `[[:name:]]` / `[[:^name:]]`.
                if (c == '[' and p.i + 1 < p.pat.len and p.pat[p.i + 1] == ':') {
                    try p.parsePosixInto(&bm);
                    continue;
                }
                // Shorthand class members `\d \D \w \W \s \S`.
                if (c == '\\' and p.i + 1 < p.pat.len) {
                    const sh: ?common.CharClass = switch (p.pat[p.i + 1]) {
                        'd' => common.CharClasses.digit,
                        'D' => common.CharClasses.non_digit,
                        'w' => common.CharClasses.word,
                        'W' => common.CharClasses.non_word,
                        's' => common.CharClasses.whitespace,
                        'S' => common.CharClasses.non_whitespace,
                        else => null,
                    };
                    if (sh) |cc| {
                        p.i += 2;
                        orClassInto(&bm, cc);
                        continue;
                    }
                }
                // Horizontal/vertical whitespace shorthands as class members
                // (`[\h\v]`). `\R`/`\N` are NOT class-legal in PCRE, so they
                // fall through to `classChar` ⇒ `Unsupported`, matching PCRE.
                if (c == '\\' and p.i + 1 < p.pat.len) {
                    const ws: ?[32]u8 = switch (p.pat[p.i + 1]) {
                        'h' => horizWsSet(),
                        'H' => invertSet(horizWsSet()),
                        'v' => vertWsSet(),
                        'V' => invertSet(vertWsSet()),
                        else => null,
                    };
                    if (ws) |set| {
                        p.i += 2;
                        var k: usize = 0;
                        while (k < 32) : (k += 1) bm[k] |= set[k];
                        continue;
                    }
                }
                // `\p{Name}` / `\P{Name}` / `\pL` as a class member: OR the
                // property's ≤0xFF byte set (its complement for `\P`) into
                // `bm`, exactly the standalone-`\p` Latin-1 semantics. An
                // outer `[^…]` is still applied by the post-loop invert, so
                // `[^\p{L}]` ⇒ ~(letters), matching Rust/RE2 Unicode-off.
                if (c == '\\' and p.i + 1 < p.pat.len and
                    (p.pat[p.i + 1] == 'p' or p.pat[p.i + 1] == 'P'))
                {
                    const neg = p.pat[p.i + 1] == 'P';
                    p.i += 2; // consume "\p" / "\P"
                    const pbm = try p.readPropBitmap(neg);
                    var k: usize = 0;
                    while (k < 32) : (k += 1) bm[k] |= pbm[k];
                    continue;
                }

                const lo = try p.classChar();
                if (p.peek() == '-' and p.i + 1 < p.pat.len and p.pat[p.i + 1] != ']') {
                    p.i += 1;
                    const hi = try p.classChar();
                    var x: usize = lo;
                    while (x <= hi) : (x += 1) setBit(&bm, @intCast(x)); // lo>hi ⇒ empty (parity)
                } else {
                    setBit(&bm, lo);
                }
            }
            if (p.peek() != ']') return Error.Invalid;
            p.i += 1;

            if (negated) {
                var k: usize = 0;
                while (k < 32) : (k += 1) bm[k] = ~bm[k];
            }
            return p.setLeaf(bm);
        }

        /// Consume `[:name:]` / `[:^name:]` (caller positioned at the inner
        /// `[`) and OR its byte set into `bm`. Unknown names → `Unsupported`.
        fn parsePosixInto(p: *Self, bm: *[32]u8) Error!void {
            p.i += 2; // consume "[:"
            var neg = false;
            if (p.peek() == '^') {
                neg = true;
                p.i += 1;
            }
            const start = p.i;
            while (p.peek()) |ch| {
                if (ch == ':') break;
                p.i += 1;
            }
            const name = p.pat[start..p.i];
            if (p.peek() != ':') return Error.Invalid;
            p.i += 1;
            if (p.peek() != ']') return Error.Invalid;
            p.i += 1;
            const cc = posixClass(name) orelse return Error.Unsupported;
            var t = [_]u8{0} ** 32;
            cc.fillBitmap(&t);
            var k: usize = 0;
            while (k < 32) : (k += 1) bm[k] |= if (neg) ~t[k] else t[k];
        }

        fn classChar(p: *Self) Error!u8 {
            const c = p.peek().?;
            if (c == '\\') {
                p.i += 1;
                const e = p.peek() orelse return Error.Invalid;
                p.i += 1;
                return switch (e) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    // Byte-valued escapes also serve as range endpoints
                    // (`[\x00-\x1F]`, `[\0-\a]`).
                    'x' => try p.parseHexByte(),
                    'o' => try p.parseOctalBraced(),
                    '0' => p.parseOctalAfterZero(),
                    // Escaped ASCII punctuation (incl. `\/` and `\-`) is literal.
                    else => escapedPunct(e) orelse Error.Unsupported,
                };
            }
            p.i += 1;
            return c;
        }
    };
}

test "parser: literal produces concat chain of set leaves" {
    const H = hir.Hir(64);
    var h = H.initComptime();
    try parse(64, &h, undefined, "abc", .{});
    // root is concat(concat(a,b),c)
    const r = h.node(h.root);
    try std.testing.expectEqual(hir.Tag.concat, r.tag);
}
