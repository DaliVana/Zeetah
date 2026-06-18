//! Per-feature: byte-valued escapes (`\xHH`, `\x{…}`, `\0`/octal, `\o{…}`) and
//! the whitespace/line-break shorthands (`\h \H \v \V \R \N`). These all stay
//! on the DFA path; this suite pins their match semantics and the typed
//! rejections for out-of-byte-range values. Runtime `Regex` is the reference;
//! a few cases cross-check the comptime `Pattern` for parity.

const std = @import("std");
const regex = @import("zeetah");
const Regex = regex.Regex;

fn find1(a: std.mem.Allocator, pat: []const u8, in: []const u8) !?struct { s: usize, e: usize, slice: []const u8 } {
    var rx = try Regex.compile(a, pat);
    defer rx.deinit();
    var m = try rx.find(in);
    defer if (m) |*mm| mm.deinit(a);
    if (m) |mm| return .{ .s = mm.start, .e = mm.end, .slice = mm.slice };
    return null;
}

fn isM(a: std.mem.Allocator, pat: []const u8, in: []const u8) !bool {
    var rx = try Regex.compile(a, pat);
    defer rx.deinit();
    return rx.isMatch(in);
}

test "escapes: \\xHH hex byte" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("A", (try find1(a, "\\x41", "zAz")).?.slice);
    // Two-digit; case-insensitive hex digits.
    try std.testing.expectEqualStrings("\xff", (try find1(a, "\\xFf", "a\xffb")).?.slice);
    // A control byte that has no dedicated escape.
    try std.testing.expect((try find1(a, "a\\x1Fb", "a\x1fb")) != null);
    try std.testing.expect((try find1(a, "\\x41", "B")) == null);
}

test "escapes: \\x{…} braced; > 0xFF reserved for (?u)" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("A", (try find1(a, "\\x{41}", "zAz")).?.slice);
    try std.testing.expectEqualStrings("\xff", (try find1(a, "\\x{ff}", "\xff")).?.slice);
    // > one byte → NotImplemented (the documented codepoint/`(?u)` follow-on),
    // never a silent truncation.
    try std.testing.expectError(error.NotImplemented, Regex.compile(a, "\\x{100}"));
    try std.testing.expectError(error.NotImplemented, Regex.compile(a, "\\x{1F600}"));
    // Malformed braces are InvalidPattern, not NotImplemented.
    try std.testing.expectError(error.InvalidPattern, Regex.compile(a, "\\x{}"));
    try std.testing.expectError(error.InvalidPattern, Regex.compile(a, "\\x{41"));
}

test "escapes: \\0 and octal" {
    const a = std.testing.allocator;
    // \0 alone = NUL.
    try std.testing.expect((try find1(a, "a\\0b", "a\x00b")) != null);
    // \012 = 0o12 = 0x0A = '\n'.
    try std.testing.expectEqualStrings("\n", (try find1(a, "\\012", "x\ny")).?.slice);
    // \o{101} = 0o101 = 'A'.
    try std.testing.expectEqualStrings("A", (try find1(a, "\\o{101}", "zAz")).?.slice);
    // \1..\9 stay backreferences, NOT octal: bare \1 with no group is invalid.
    try std.testing.expectError(error.InvalidPattern, Regex.compile(a, "\\1"));
    // \o{400} = 256 → out of byte range.
    try std.testing.expectError(error.NotImplemented, Regex.compile(a, "\\o{400}"));
}

test "escapes: \\h \\H horizontal whitespace (PCRE 8-bit incl. NBSP)" {
    const a = std.testing.allocator;
    try std.testing.expect(try isM(a, "\\h", "x y")); // space
    try std.testing.expect(try isM(a, "\\h", "x\ty")); // tab
    try std.testing.expect(try isM(a, "\\h", "\xa0")); // NBSP (Latin-1)
    try std.testing.expect(!try isM(a, "\\h", "abc")); // no horizontal ws
    try std.testing.expect(!try isM(a, "\\h", "a\nb")); // newline is vertical, not horizontal
    // \H = complement.
    try std.testing.expect(try isM(a, "\\H", "a"));
    try std.testing.expect(!try isM(a, "\\H", "   ")); // only spaces ⇒ no \H
}

test "escapes: \\v \\V vertical whitespace (PCRE 8-bit incl. NEL)" {
    const a = std.testing.allocator;
    try std.testing.expect(try isM(a, "\\v", "a\nb")); // LF
    try std.testing.expect(try isM(a, "\\v", "a\rb")); // CR
    try std.testing.expect(try isM(a, "\\v", "\x0b")); // VT
    try std.testing.expect(try isM(a, "\\v", "\x0c")); // FF
    try std.testing.expect(try isM(a, "\\v", "\x85")); // NEL (Latin-1)
    try std.testing.expect(!try isM(a, "\\v", "a b")); // space is horizontal
    // \V = complement.
    try std.testing.expect(try isM(a, "\\V", " "));
    try std.testing.expect(!try isM(a, "\\V", "\n"));
}

test "escapes: \\R line break (CRLF as one unit; bare CR/LF)" {
    const a = std.testing.allocator;
    // \r\n is consumed as a single unit.
    const crlf = (try find1(a, "\\R", "a\r\nb")).?;
    try std.testing.expectEqualStrings("\r\n", crlf.slice);
    try std.testing.expectEqual(@as(usize, 1), crlf.s);
    // bare LF / CR / VT.
    try std.testing.expectEqualStrings("\n", (try find1(a, "\\R", "a\nb")).?.slice);
    try std.testing.expectEqualStrings("\r", (try find1(a, "\\R", "a\rb")).?.slice);
    try std.testing.expect((try find1(a, "\\R", "abc")) == null);
}

test "escapes: \\N any byte except newline" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("axb", (try find1(a, "a\\Nb", "axb")).?.slice);
    try std.testing.expect((try find1(a, "a\\Nb", "a\nb")) == null);
    // \N is unaffected by (?s) — still excludes '\n'.
    try std.testing.expect((try find1(a, "(?s)a\\Nb", "a\nb")) == null);
}

test "escapes: byte-valued escapes inside classes and as range endpoints" {
    const a = std.testing.allocator;
    // Range with hex endpoints: [\x41-\x43]+ ⇒ A,B,C.
    try std.testing.expectEqualStrings("ABC", (try find1(a, "[\\x41-\\x43]+", "zABCz")).?.slice);
    // Octal endpoint.
    try std.testing.expectEqualStrings("A", (try find1(a, "[\\o{101}]", "A")).?.slice);
    // \h / \v as class members.
    try std.testing.expectEqualStrings("  \t ", (try find1(a, "[\\h]+", "x  \t y")).?.slice);
    try std.testing.expect(try isM(a, "[\\v]", "a\nb"));
    // Negated class with a shorthand member.
    try std.testing.expect(try isM(a, "[^\\h]", "a"));
    try std.testing.expect(!try isM(a, "[^\\h]", " "));
}

test "escapes: comptime Pattern agrees with runtime Regex" {
    const a = std.testing.allocator;
    const Cases = struct { pat: []const u8, in: []const u8 };
    const cases = [_]Cases{
        .{ .pat = "\\x41", .in = "zAz" },
        .{ .pat = "\\h+", .in = "a  \tb" },
        .{ .pat = "\\R", .in = "a\r\nb" },
        .{ .pat = "a\\Nb", .in = "axb" },
        .{ .pat = "[\\x30-\\x39]+", .in = "id 4096!" },
    };
    inline for (cases) |c| {
        const P = regex.Pattern(c.pat, .{});
        var rx = try Regex.compile(a, c.pat);
        defer rx.deinit();
        try std.testing.expectEqual(try rx.isMatch(c.in), P.isMatch(c.in));
        const pm = P.find(c.in);
        var rm = try rx.find(c.in);
        defer if (rm) |*x| x.deinit(a);
        try std.testing.expectEqual(rm == null, pm == null);
        if (pm) |p| {
            try std.testing.expectEqual(p.start, rm.?.start);
            try std.testing.expectEqual(p.end, rm.?.end);
        }
    }
}
