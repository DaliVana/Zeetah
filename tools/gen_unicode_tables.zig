//! Build-time code generator for the Unicode codepoint tables.
//!
//! Reads the UCD data files below and emits one Zig source file
//! (`src/unicode_tables.zig`) containing, as sorted/merged lists of inclusive
//! codepoint ranges:
//!   * every two-letter General_Category (`gc_Lu` …),
//!   * every Script and its Script_Extensions set,
//!   * every (non-contributory) binary property of PropList /
//!     DerivedCoreProperties / emoji-data,
//!   * the derived Perl classes `\w` / `\s` / `\d` (UTS #18 Annex C),
//!   * the simple case-folding orbits (CaseFolding.txt statuses C + S),
//!   * normalised alias → id name tables for scripts and binary properties
//!     (PropertyValueAliases.txt / PropertyAliases.txt).
//!
//! This is run once when bumping the pinned Unicode version; the generated
//! output is committed so normal builds stay hermetic and network-free. The
//! raw UCD files themselves are NOT committed (`tools/ucd/` is git-ignored).
//!
//! Usage (run from the repository root):
//!   1. Download the pinned UCD files into tools/ucd/:
//!        V=17.0.0; B=https://www.unicode.org/Public/$V/ucd
//!        mkdir -p tools/ucd && cd tools/ucd
//!        curl -O $B/extracted/DerivedGeneralCategory.txt
//!        curl -O $B/Scripts.txt -O $B/ScriptExtensions.txt -O $B/PropList.txt
//!        curl -O $B/DerivedCoreProperties.txt -O $B/CaseFolding.txt
//!        curl -O $B/PropertyValueAliases.txt -O $B/PropertyAliases.txt
//!        curl -O $B/emoji/emoji-data.txt
//!   2. Set `unicode_version` below to match.
//!   3. zig run tools/gen_unicode_tables.zig && zig fmt src/unicode_tables.zig
//!   4. Commit the regenerated src/unicode_tables.zig.

const std = @import("std");

/// Pinned Unicode version. Bump this together with the downloaded UCD files.
const unicode_version = "17.0.0";
const out_path = "src/unicode_tables.zig";

// The UCD sources, embedded at compile time so the generator needs no file IO
// for input.
const gc_data = @embedFile("ucd/DerivedGeneralCategory.txt");
const scripts_data = @embedFile("ucd/Scripts.txt");
const scx_data = @embedFile("ucd/ScriptExtensions.txt");
const proplist_data = @embedFile("ucd/PropList.txt");
const dcp_data = @embedFile("ucd/DerivedCoreProperties.txt");
const emoji_data = @embedFile("ucd/emoji-data.txt");
const casefold_data = @embedFile("ucd/CaseFolding.txt");
const pva_data = @embedFile("ucd/PropertyValueAliases.txt");
const pa_data = @embedFile("ucd/PropertyAliases.txt");

const MAX_CP: u32 = 0x10FFFF;

const categories = [_][]const u8{
    "Lu", "Ll", "Lt", "Lm", "Lo",
    "Mn", "Mc", "Me", "Nd", "Nl",
    "No", "Pc", "Pd", "Ps", "Pe",
    "Pi", "Pf", "Po", "Sm", "Sc",
    "Sk", "So", "Zs", "Zl", "Zp",
    "Cc", "Cf", "Cs", "Co", "Cn",
};

const Range = struct { lo: u32, hi: u32 };
const RangeList = std.ArrayList(Range);
/// Insertion-ordered name → ranges map (deterministic output).
const NamedRanges = std.StringArrayHashMapUnmanaged(RangeList);

fn lessThan(_: void, a: Range, b: Range) bool {
    return a.lo < b.lo;
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// Strip a `# …` comment and surrounding whitespace; empty ⇒ null.
fn dataLine(raw: []const u8) ?[]const u8 {
    const hash = std.mem.indexOfScalar(u8, raw, '#');
    const line = trim(if (hash) |h| raw[0..h] else raw);
    return if (line.len == 0) null else line;
}

/// `XXXX` or `XXXX..YYYY` → inclusive range.
fn parseCpField(field: []const u8) !Range {
    const f = trim(field);
    if (std.mem.indexOf(u8, f, "..")) |dot| {
        return .{
            .lo = try std.fmt.parseInt(u32, trim(f[0..dot]), 16),
            .hi = try std.fmt.parseInt(u32, trim(f[dot + 2 ..]), 16),
        };
    }
    const v = try std.fmt.parseInt(u32, f, 16);
    return .{ .lo = v, .hi = v };
}

/// Append `r`, extending the last range when contiguous (keeps per-codepoint
/// appends from producing a million singletons).
fn addRange(list: *RangeList, a: std.mem.Allocator, r: Range) !void {
    if (list.items.len > 0) {
        const last = &list.items[list.items.len - 1];
        if (r.lo <= last.hi + 1 and r.lo >= last.lo) {
            if (r.hi > last.hi) last.hi = r.hi;
            return;
        }
    }
    try list.append(a, r);
}

/// Sort + merge adjacent/overlapping ranges in place.
fn normalize(list: *RangeList, a: std.mem.Allocator) !void {
    std.mem.sort(Range, list.items, {}, lessThan);
    var merged: RangeList = .empty;
    for (list.items) |r| try addRange(&merged, a, r);
    list.clearRetainingCapacity();
    try list.appendSlice(a, merged.items);
    merged.deinit(a);
}

/// Complement within [0, MAX_CP] (surrogates are NOT removed here — the
/// consumer does that; these are raw property tables).
fn complement(list: *const RangeList, a: std.mem.Allocator) !RangeList {
    var out: RangeList = .empty;
    var expected: u32 = 0;
    for (list.items) |r| {
        if (r.lo > expected) try out.append(a, .{ .lo = expected, .hi = r.lo - 1 });
        expected = r.hi + 1;
    }
    if (expected <= MAX_CP) try out.append(a, .{ .lo = expected, .hi = MAX_CP });
    return out;
}

fn bucket(map: *NamedRanges, a: std.mem.Allocator, name: []const u8) !*RangeList {
    const gop = try map.getOrPut(a, name);
    if (!gop.found_existing) {
        gop.key_ptr.* = try a.dupe(u8, name);
        gop.value_ptr.* = .empty;
    }
    return gop.value_ptr;
}

/// Parse a `cp ; Name # …` property file into `map` (one bucket per Name).
/// `skip_valued`: ignore lines with a third field (`cp ; Prop ; Value`, e.g.
/// InCB in DerivedCoreProperties). `skip_prefix`: drop names with this prefix
/// (the contributory `Other_*` properties of PropList).
fn parseNamed(data: []const u8, map: *NamedRanges, a: std.mem.Allocator, skip_valued: bool, skip_prefix: ?[]const u8) !void {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = dataLine(raw) orelse continue;
        var parts = std.mem.splitScalar(u8, line, ';');
        const cp_field = parts.next() orelse continue;
        const name = trim(parts.next() orelse continue);
        if (skip_valued and parts.next() != null) continue;
        if (skip_prefix) |pfx| if (std.mem.startsWith(u8, name, pfx)) continue;
        const r = try parseCpField(cp_field);
        try (try bucket(map, a, name)).append(a, r);
    }
}

/// Lower-case, drop `_`, `-`, space (UAX #44 LM3 loose matching).
fn normName(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (name) |c| switch (c) {
        ' ', '_', '-', '\t' => {},
        else => try out.append(a, std.ascii.toLower(c)),
    };
    return out.toOwnedSlice(a);
}

const NameEntry = struct { name: []const u8, id: []const u8 };

fn nameLess(_: void, x: NameEntry, y: NameEntry) bool {
    return std.mem.order(u8, x.name, y.name) == .lt;
}

fn strLess(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

const Out = struct {
    buf: std.ArrayList(u8) = .empty,
    a: std.mem.Allocator,

    fn w(self: *Out, s: []const u8) !void {
        try self.buf.appendSlice(self.a, s);
    }
    fn p(self: *Out, comptime fmt: []const u8, args: anytype) !void {
        try self.buf.appendSlice(self.a, try std.fmt.allocPrint(self.a, fmt, args));
    }
    fn ranges(self: *Out, name: []const u8, items: []const Range) !void {
        try self.p("pub const {s} = [_]Range{{", .{name});
        for (items, 0..) |r, k| {
            if (k % 4 == 0) try self.w("\n    ");
            try self.p(".{{ .lo = 0x{X}, .hi = 0x{X} }}, ", .{ r.lo, r.hi });
        }
        try self.w("\n};\n\n");
    }
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // ── General_Category ──────────────────────────────────────────────────
    var gc: NamedRanges = .empty;
    try parseNamed(gc_data, &gc, a, false, null);
    for (gc.values()) |*l| try normalize(l, a);

    // ── Scripts (+ Unknown = complement) ──────────────────────────────────
    var sc: NamedRanges = .empty;
    try parseNamed(scripts_data, &sc, a, false, null);
    for (sc.values()) |*l| try normalize(l, a);
    {
        var all: RangeList = .empty;
        for (sc.values()) |l| try all.appendSlice(a, l.items);
        try normalize(&all, a);
        const unk = try complement(&all, a);
        try (try bucket(&sc, a, "Unknown")).appendSlice(a, unk.items);
    }
    const script_names_sorted: [][]const u8 = blk: {
        const keys = try a.dupe([]const u8, sc.keys());
        std.mem.sort([]const u8, keys, {}, strLess);
        break :blk keys;
    };
    if (script_names_sorted.len > 255) return error.TooManyScripts;
    var script_index: std.StringArrayHashMapUnmanaged(u8) = .empty;
    for (script_names_sorted, 0..) |n, i| try script_index.put(a, n, @intCast(i));

    // ── Script_Extensions ─────────────────────────────────────────────────
    // scx(cp) = the explicit ScriptExtensions.txt list, else {sc(cp)}.
    // Per script S: every cp with S ∈ scx(cp).
    const n_scripts = script_names_sorted.len;
    const sc_of = try a.alloc(u8, MAX_CP + 1);
    @memset(sc_of, script_index.get("Unknown").?);
    for (sc.keys(), sc.values()) |name, l| {
        const id = script_index.get(name).?;
        for (l.items) |r| @memset(sc_of[r.lo .. r.hi + 1], id);
    }
    const has_scx = try a.alloc(bool, MAX_CP + 1);
    @memset(has_scx, false);
    const scx_lists = try a.alloc(RangeList, n_scripts);
    for (scx_lists) |*l| l.* = .empty;
    // Short-code → script id, from PropertyValueAliases `sc ;` lines.
    var sc_alias: std.StringArrayHashMapUnmanaged(u8) = .empty; // normalised alias → id
    var pa_lines = std.mem.splitScalar(u8, pva_data, '\n');
    while (pa_lines.next()) |raw| {
        const line = dataLine(raw) orelse continue;
        var parts = std.mem.splitScalar(u8, line, ';');
        const prop = trim(parts.next() orelse continue);
        if (!std.mem.eql(u8, prop, "sc")) continue;
        const short = trim(parts.next() orelse continue);
        const long = trim(parts.next() orelse continue);
        const id = script_index.get(long) orelse {
            std.debug.print("warning: PropertyValueAliases script {s} not in Scripts.txt\n", .{long});
            continue;
        };
        try sc_alias.put(a, try normName(a, short), id);
        try sc_alias.put(a, try normName(a, long), id);
        while (parts.next()) |extra| try sc_alias.put(a, try normName(a, trim(extra)), id);
    }
    // Explicit scx entries.
    var scx_lines = std.mem.splitScalar(u8, scx_data, '\n');
    while (scx_lines.next()) |raw| {
        const line = dataLine(raw) orelse continue;
        var parts = std.mem.splitScalar(u8, line, ';');
        const r = try parseCpField(parts.next() orelse continue);
        const codes = trim(parts.next() orelse continue);
        @memset(has_scx[r.lo .. r.hi + 1], true);
        var it = std.mem.tokenizeScalar(u8, codes, ' ');
        while (it.next()) |code| {
            const id = sc_alias.get(try normName(a, code)) orelse return error.UnknownScriptCode;
            try addRange(&scx_lists[id], a, r);
        }
    }
    // Default scx = sc for every cp without an explicit entry.
    {
        var cp: u32 = 0;
        while (cp <= MAX_CP) : (cp += 1) {
            if (has_scx[cp]) continue;
            try addRange(&scx_lists[sc_of[cp]], a, .{ .lo = cp, .hi = cp });
        }
    }
    for (scx_lists) |*l| try normalize(l, a);

    // ── Binary properties ─────────────────────────────────────────────────
    var bp: NamedRanges = .empty;
    try parseNamed(proplist_data, &bp, a, true, "Other_");
    try parseNamed(dcp_data, &bp, a, true, null);
    try parseNamed(emoji_data, &bp, a, true, null);
    for (bp.values()) |*l| try normalize(l, a);
    const bp_names_sorted: [][]const u8 = blk: {
        const keys = try a.dupe([]const u8, bp.keys());
        std.mem.sort([]const u8, keys, {}, strLess);
        break :blk keys;
    };
    if (bp_names_sorted.len > 255) return error.TooManyProperties;
    // Aliases from PropertyAliases.txt (every line whose long name is one of ours).
    var bp_aliases: std.ArrayList(NameEntry) = .empty;
    {
        var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (bp_names_sorted) |n| {
            const nn = try normName(a, n);
            try bp_aliases.append(a, .{ .name = nn, .id = n });
            try seen.put(a, nn, {});
        }
        var lines = std.mem.splitScalar(u8, pa_data, '\n');
        while (lines.next()) |raw| {
            const line = dataLine(raw) orelse continue;
            var parts = std.mem.splitScalar(u8, line, ';');
            const short = trim(parts.next() orelse continue);
            const long = trim(parts.next() orelse continue);
            if (!bp.contains(long)) continue;
            const cands = [_][]const u8{ short, trim(parts.next() orelse "") };
            for (cands) |c| {
                if (c.len == 0) continue;
                const nn = try normName(a, c);
                if (seen.contains(nn)) continue;
                try seen.put(a, nn, {});
                try bp_aliases.append(a, .{ .name = nn, .id = long });
            }
        }
        std.mem.sort(NameEntry, bp_aliases.items, {}, nameLess);
    }
    // Script alias table (short code, long name, extras), plus the long names
    // themselves (every script in Scripts.txt has a PVA line, but be safe).
    var sc_aliases: std.ArrayList(NameEntry) = .empty;
    {
        var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (script_names_sorted) |n| {
            const nn = try normName(a, n);
            try sc_aliases.append(a, .{ .name = nn, .id = n });
            try seen.put(a, nn, {});
        }
        for (sc_alias.keys(), sc_alias.values()) |nn, id| {
            if (seen.contains(nn)) continue;
            try seen.put(a, nn, {});
            try sc_aliases.append(a, .{ .name = nn, .id = script_names_sorted[id] });
        }
        std.mem.sort(NameEntry, sc_aliases.items, {}, nameLess);
    }

    // ── Perl classes (UTS #18 Annex C) ────────────────────────────────────
    var perl_word: RangeList = .empty;
    for ([_][]const u8{ "Alphabetic", "Join_Control" }) |n| try perl_word.appendSlice(a, bp.get(n).?.items);
    for ([_][]const u8{ "Mn", "Mc", "Me", "Nd", "Pc" }) |n| try perl_word.appendSlice(a, gc.get(n).?.items);
    try normalize(&perl_word, a);
    const perl_space = bp.get("White_Space").?;
    const perl_digit = gc.get("Nd").?;

    // ── Simple case folding orbits ────────────────────────────────────────
    const Fold = struct { cp: u32, others: [3]u32, n: u8 };
    var fold_entries: std.ArrayList(Fold) = .empty;
    {
        // target → members (target included)
        var orbits: std.AutoArrayHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty;
        var lines = std.mem.splitScalar(u8, casefold_data, '\n');
        while (lines.next()) |raw| {
            const line = dataLine(raw) orelse continue;
            var parts = std.mem.splitScalar(u8, line, ';');
            const cp = try std.fmt.parseInt(u32, trim(parts.next() orelse continue), 16);
            const status = trim(parts.next() orelse continue);
            if (!(std.mem.eql(u8, status, "C") or std.mem.eql(u8, status, "S"))) continue;
            const target = try std.fmt.parseInt(u32, trim(parts.next() orelse continue), 16);
            const gop = try orbits.getOrPut(a, target);
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
                try gop.value_ptr.append(a, target);
            }
            try gop.value_ptr.append(a, cp);
        }
        for (orbits.values()) |members| {
            std.mem.sort(u32, members.items, {}, std.sort.asc(u32));
            if (members.items.len > 4) return error.OrbitTooLarge;
            for (members.items) |m| {
                var e: Fold = .{ .cp = m, .others = .{ 0, 0, 0 }, .n = 0 };
                for (members.items) |o| {
                    if (o == m) continue;
                    e.others[e.n] = o;
                    e.n += 1;
                }
                try fold_entries.append(a, e);
            }
        }
        std.mem.sort(Fold, fold_entries.items, {}, struct {
            fn lt(_: void, x: Fold, y: Fold) bool {
                return x.cp < y.cp;
            }
        }.lt);
    }

    // ── Emit ──────────────────────────────────────────────────────────────
    var out = Out{ .a = a };
    try out.w("//! GENERATED FILE — do not edit by hand.\n//!\n");
    try out.w("//! Source: Unicode Character Database (DerivedGeneralCategory, Scripts,\n");
    try out.w("//! ScriptExtensions, PropList, DerivedCoreProperties, emoji-data, CaseFolding,\n");
    try out.w("//! PropertyValueAliases, PropertyAliases).\n");
    try out.p("//! Unicode version: {s}\n", .{unicode_version});
    try out.w("//! Regenerate with: zig run tools/gen_unicode_tables.zig && zig fmt src/unicode_tables.zig\n");
    try out.w("//!\n" ++
        "//! Every table is a sorted, merged slice of inclusive codepoint `Range`s:\n" ++
        "//!   * `gc_<Cat>` / `Category` / `rangesFor` — General_Category;\n" ++
        "//!   * `Script` / `scriptRanges` / `scxRanges` — Script and Script_Extensions\n" ++
        "//!     (a codepoint's scx defaults to its Script when ScriptExtensions.txt has\n" ++
        "//!     no entry), `script_names` — normalised alias → `Script`;\n" ++
        "//!   * `BinaryProp` / `binaryRanges` / `binary_names` — the non-contributory\n" ++
        "//!     binary properties of PropList, DerivedCoreProperties and emoji-data;\n" ++
        "//!   * `perl_word` / `perl_space` / `perl_digit` — the UTS #18 Annex C `\\w \\s \\d`;\n" ++
        "//!   * `case_fold` — simple case-folding orbits (CaseFolding.txt C + S), sorted\n" ++
        "//!     by `cp`; `others` are the other members of `cp`'s orbit.\n" ++
        "//! Consumed by `unicode_class.zig` / `unicode_set.zig` / `utf8.zig`. Byte-mode\n" ++
        "//! matching uses only the Latin-1 slice of the gc tables — see the README.\n\n");
    try out.p("pub const unicode_version = \"{s}\";\n\n", .{unicode_version});
    try out.w("/// Inclusive codepoint range.\npub const Range = struct { lo: u21, hi: u21 };\n\n");

    // gc
    for (categories) |cat| {
        const l = gc.get(cat) orelse return error.MissingCategory;
        try out.ranges(try std.fmt.allocPrint(a, "gc_{s}", .{cat}), l.items);
    }
    try out.w("pub const Category = enum(u8) {\n");
    for (categories) |cat| try out.p("    {s},\n", .{cat});
    try out.w("};\n\n");
    try out.w("pub fn rangesFor(cat: Category) []const Range {\n    return switch (cat) {\n");
    for (categories) |cat| try out.p("        .{s} => &gc_{s},\n", .{ cat, cat });
    try out.w("    };\n}\n\n");

    // scripts
    for (script_names_sorted) |n| try out.ranges(try std.fmt.allocPrint(a, "sc_{s}", .{n}), sc.get(n).?.items);
    for (script_names_sorted, 0..) |n, i| try out.ranges(try std.fmt.allocPrint(a, "scx_{s}", .{n}), scx_lists[i].items);
    try out.w("pub const Script = enum(u8) {\n");
    for (script_names_sorted) |n| try out.p("    {s},\n", .{n});
    try out.w("};\n\n");
    try out.w("/// Script property ranges.\npub fn scriptRanges(s: Script) []const Range {\n    return switch (s) {\n");
    for (script_names_sorted) |n| try out.p("        .{s} => &sc_{s},\n", .{ n, n });
    try out.w("    };\n}\n\n");
    try out.w("/// Script_Extensions ranges: every codepoint whose scx list contains `s`.\npub fn scxRanges(s: Script) []const Range {\n    return switch (s) {\n");
    for (script_names_sorted) |n| try out.p("        .{s} => &scx_{s},\n", .{ n, n });
    try out.w("    };\n}\n\n");
    try out.w("pub const ScriptName = struct { name: []const u8, id: Script };\n");
    try out.w("/// Normalised (lower-case, no `_`/`-`/space) script aliases, sorted by `name`.\n");
    try out.w("pub const script_names = [_]ScriptName{\n");
    for (sc_aliases.items) |e| try out.p("    .{{ .name = \"{s}\", .id = .{s} }},\n", .{ e.name, e.id });
    try out.w("};\n\n");

    // binary properties
    for (bp_names_sorted) |n| try out.ranges(try std.fmt.allocPrint(a, "bp_{s}", .{n}), bp.get(n).?.items);
    try out.w("pub const BinaryProp = enum(u8) {\n");
    for (bp_names_sorted) |n| try out.p("    {s},\n", .{n});
    try out.w("};\n\n");
    try out.w("pub fn binaryRanges(p: BinaryProp) []const Range {\n    return switch (p) {\n");
    for (bp_names_sorted) |n| try out.p("        .{s} => &bp_{s},\n", .{ n, n });
    try out.w("    };\n}\n\n");
    try out.w("pub const BinaryName = struct { name: []const u8, id: BinaryProp };\n");
    try out.w("/// Normalised binary-property aliases, sorted by `name`.\n");
    try out.w("pub const binary_names = [_]BinaryName{\n");
    for (bp_aliases.items) |e| try out.p("    .{{ .name = \"{s}\", .id = .{s} }},\n", .{ e.name, e.id });
    try out.w("};\n\n");

    // perl classes
    try out.w("/// `\\w` in Unicode mode: Alphabetic ∪ M ∪ Nd ∪ Pc ∪ Join_Control (UTS #18 Annex C).\n");
    try out.ranges("perl_word", perl_word.items);
    try out.w("/// `\\s` in Unicode mode: White_Space.\n");
    try out.ranges("perl_space", perl_space.items);
    try out.w("/// `\\d` in Unicode mode: Nd.\n");
    try out.ranges("perl_digit", perl_digit.items);

    // case folding
    try out.w("/// One codepoint of a non-trivial simple case-folding orbit: `others[0..n]`\n");
    try out.w("/// are the orbit's other members (orbits have at most 4 members).\n");
    try out.w("pub const CaseFold = struct { cp: u21, n: u8, others: [3]u21 };\n");
    try out.w("pub const case_fold = [_]CaseFold{");
    for (fold_entries.items, 0..) |e, k| {
        if (k % 2 == 0) try out.w("\n    ");
        try out.p(".{{ .cp = 0x{X}, .n = {d}, .others = .{{ 0x{X}, 0x{X}, 0x{X} }} }}, ", .{ e.cp, e.n, e.others[0], e.others[1], e.others[2] });
    }
    try out.w("\n};\n");

    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = out.buf.items });

    var n_ranges: usize = 0;
    for (gc.values()) |l| n_ranges += l.items.len;
    for (sc.values()) |l| n_ranges += l.items.len;
    for (scx_lists) |l| n_ranges += l.items.len;
    for (bp.values()) |l| n_ranges += l.items.len;
    n_ranges += perl_word.items.len + perl_space.items.len + perl_digit.items.len;
    std.debug.print(
        "wrote {s} ({d} bytes, Unicode {s}): {d} scripts, {d} binary props, {d} ranges, {d} fold entries\n",
        .{ out_path, out.buf.items.len, unicode_version, n_scripts, bp_names_sorted.len, n_ranges, fold_entries.items.len },
    );
}
