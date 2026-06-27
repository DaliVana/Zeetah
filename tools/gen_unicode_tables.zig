//! Build-time code generator for Unicode general-category codepoint tables.
//!
//! Reads the UCD `DerivedGeneralCategory.txt` data file and emits a Zig source
//! file (`src/unicode_tables.zig`) containing, for every two-letter general
//! category, a sorted/merged list of inclusive codepoint ranges.
//!
//! This is run once when bumping the pinned Unicode version; the generated
//! output is committed so normal builds stay hermetic and network-free. The
//! raw UCD file itself is NOT committed.
//!
//! Usage (run from the repository root):
//!   1. Download the pinned UCD file:
//!        mkdir -p tools/ucd
//!        curl -o tools/ucd/DerivedGeneralCategory.txt \
//!          https://www.unicode.org/Public/<VER>/ucd/extracted/DerivedGeneralCategory.txt
//!   2. Set `unicode_version` below to match <VER>.
//!   3. zig run tools/gen_unicode_tables.zig
//!   4. Commit the regenerated src/unicode_tables.zig.

const std = @import("std");

/// Pinned Unicode version. Bump this together with the downloaded UCD file.
const unicode_version = "17.0.0";
const out_path = "src/unicode_tables.zig";

/// The UCD source, embedded at compile time so the generator needs no file IO
/// for input. Place the downloaded file at tools/ucd/DerivedGeneralCategory.txt.
const ucd_data = @embedFile("ucd/DerivedGeneralCategory.txt");

const categories = [_][]const u8{
    "Lu", "Ll", "Lt", "Lm", "Lo",
    "Mn", "Mc", "Me",
    "Nd", "Nl", "No",
    "Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po",
    "Sm", "Sc", "Sk", "So",
    "Zs", "Zl", "Zp",
    "Cc", "Cf", "Cs", "Co", "Cn",
};

const Range = struct { lo: u32, hi: u32 };

fn lessThan(_: void, a: Range, b: Range) bool {
    return a.lo < b.lo;
}

fn catIndex(name: []const u8) ?usize {
    for (categories, 0..) |c, i| {
        if (std.mem.eql(u8, c, name)) return i;
    }
    return null;
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var buckets: [categories.len]std.ArrayList(Range) = undefined;
    for (&buckets) |*b| b.* = .empty;

    var lines = std.mem.splitScalar(u8, ucd_data, '\n');
    while (lines.next()) |raw_line| {
        const hash = std.mem.indexOfScalar(u8, raw_line, '#');
        const line = trim(if (hash) |h| raw_line[0..h] else raw_line);
        if (line.len == 0) continue;

        var parts = std.mem.splitScalar(u8, line, ';');
        const cp_field = trim(parts.next() orelse continue);
        const cat_field = trim(parts.next() orelse continue);
        const idx = catIndex(cat_field) orelse continue;

        var lo: u32 = undefined;
        var hi: u32 = undefined;
        if (std.mem.indexOf(u8, cp_field, "..")) |dot| {
            lo = try std.fmt.parseInt(u32, trim(cp_field[0..dot]), 16);
            hi = try std.fmt.parseInt(u32, trim(cp_field[dot + 2 ..]), 16);
        } else {
            lo = try std.fmt.parseInt(u32, cp_field, 16);
            hi = lo;
        }
        try buckets[idx].append(a, .{ .lo = lo, .hi = hi });
    }

    var out: std.ArrayList(u8) = .empty;

    try out.appendSlice(a, "//! GENERATED FILE — do not edit by hand.\n");
    try out.appendSlice(a, "//!\n//! Source: Unicode Character Database, DerivedGeneralCategory.txt\n");
    try out.appendSlice(a, try std.fmt.allocPrint(a, "//! Unicode version: {s}\n", .{unicode_version}));
    try out.appendSlice(a, "//! Regenerate with: zig run tools/gen_unicode_tables.zig\n");
    // Hand-written module overview, emitted here so a regeneration preserves it
    // (the committed header must round-trip through this generator unchanged).
    try out.appendSlice(a,
        "//!\n" ++
        "//! Exports, per Unicode General_Category, a sorted slice of inclusive codepoint\n" ++
        "//! `Range`s named `gc_<Category>` — the two-letter categories `gc_Lu`, `gc_Ll`,\n" ++
        "//! `gc_Lt`, `gc_Lm`, `gc_Lo`, `gc_Mn`, … through `gc_Cn`. Consumed by\n" ++
        "//! `unicode_class.zig` to resolve `\\p{…}` / `\\P{…}` property classes. (Byte-mode\n" ++
        "//! matching uses only the Latin-1 slice of these — see the Unicode note in the\n" ++
        "//! README.)\n\n");
    try out.appendSlice(a, try std.fmt.allocPrint(a, "pub const unicode_version = \"{s}\";\n\n", .{unicode_version}));
    try out.appendSlice(a, "/// Inclusive codepoint range.\npub const Range = struct { lo: u21, hi: u21 };\n\n");

    for (categories, 0..) |cat, i| {
        const items = buckets[i].items;
        std.mem.sort(Range, items, {}, lessThan);

        var merged: std.ArrayList(Range) = .empty;
        for (items) |r| {
            if (merged.items.len > 0) {
                const last = &merged.items[merged.items.len - 1];
                if (r.lo <= last.hi + 1) {
                    if (r.hi > last.hi) last.hi = r.hi;
                    continue;
                }
            }
            try merged.append(a, r);
        }

        try out.appendSlice(a, try std.fmt.allocPrint(a, "pub const gc_{s} = [_]Range{{", .{cat}));
        for (merged.items, 0..) |r, k| {
            if (k % 4 == 0) try out.appendSlice(a, "\n    ");
            try out.appendSlice(a, try std.fmt.allocPrint(a, ".{{ .lo = 0x{X}, .hi = 0x{X} }}, ", .{ r.lo, r.hi }));
        }
        try out.appendSlice(a, "\n};\n\n");
    }

    try out.appendSlice(a, "pub const Category = enum {\n");
    for (categories) |cat| try out.appendSlice(a, try std.fmt.allocPrint(a, "    {s},\n", .{cat}));
    try out.appendSlice(a, "};\n\n");

    try out.appendSlice(a, "pub fn rangesFor(cat: Category) []const Range {\n    return switch (cat) {\n");
    for (categories) |cat| try out.appendSlice(a, try std.fmt.allocPrint(a, "        .{s} => &gc_{s},\n", .{ cat, cat }));
    try out.appendSlice(a, "    };\n}\n");

    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = out.items });

    std.debug.print("wrote {s} ({d} bytes, Unicode {s})\n", .{ out_path, out.items.len, unicode_version });
}
