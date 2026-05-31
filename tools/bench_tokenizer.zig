//! GPT-4 (cl100k_base) pre-tokenizer workload — correctness gate + throughput.
//!
//! tiktoken's cl100k_base pre-tokenizer regex uses possessive quantifiers
//! (`?+` / `++`), which Zeetah deliberately rejects (possessive != greedy in
//! general — see the feature table). Here they are rewritten to plain greedy
//! `?` / `+`, which is EXACTLY equivalent for THIS regex because each
//! possessive class is disjoint from whatever follows it, so the engine never
//! needs to backtrack into it:
//!
//!   * `[^\r\n\p{L}\p{N}]?+ \p{L}+`  — the optional class excludes letters and
//!     `\p{L}+` requires them                          → disjoint.
//!   * `[^\s\p{L}\p{N}]++ [\r\n]*`   — the `+` class excludes whitespace and
//!     `[\r\n]*` is whitespace                         → disjoint.
//!
//! So the greedy form produces the identical segmentation. (Zeetah's `\p` is
//! the Latin-1 byte restriction, so on ASCII / Latin-1 text the pre-token
//! boundaries match the reference cl100k exactly; multibyte UTF-8 is matched
//! per-byte — see the README Unicode note.)
//!
//!   `zig build bench-tokenizer`  → throughput (this file's `main`)
//!   `zig build test`             → correctness gate (the `test` blocks below)

const std = @import("std");
const builtin = @import("builtin");
const zeetah = @import("zeetah");

/// cl100k_base pre-tokenizer, with possessive `?+`/`++` rewritten to greedy
/// `?`/`+` (equivalent here — see the file header).
pub const CL100K =
    "'(?i:[sdmt]|ll|ve|re)|[^\\r\\n\\p{L}\\p{N}]?\\p{L}+|\\p{N}{1,3}| ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]|\\s+(?!\\S)|\\s+";

// ── correctness gate ─────────────────────────────────────────────────────────

fn expectTokens(re: *const zeetah.Regex, input: []const u8, expected: []const []const u8) !void {
    const a = std.testing.allocator;
    const toks = try re.findAll(a, input);
    defer a.free(toks);
    try std.testing.expectEqual(expected.len, toks.len);
    for (expected, toks) |want, got| try std.testing.expectEqualStrings(want, got.slice);
}

test "cl100k pre-tokenization: every branch segments as the reference does" {
    const a = std.testing.allocator;
    var re = try zeetah.Regex.compile(a, CL100K);
    defer re.deinit();

    // Contractions: '(?i:[sdmt]|ll|ve|re)
    try expectTokens(&re, "don't", &.{ "don", "'t" });
    try expectTokens(&re, "it'll", &.{ "it", "'ll" });
    try expectTokens(&re, "I've", &.{ "I", "'ve" });
    // Word = optional single leading non-letter + letters; punctuation runs.
    try expectTokens(&re, "Hello, World!", &.{ "Hello", ",", " World", "!" });
    // Numbers: 1-3 digit chunks, no leading-space attachment.
    try expectTokens(&re, "abc 123", &.{ "abc", " ", "123" });
    try expectTokens(&re, "1234", &.{ "123", "4" });
    // Two-space rule: only the last space attaches to the following word
    // (the lookahead branch `\s+(?!\S)` peels the earlier spaces off).
    try expectTokens(&re, "  hi", &.{ " ", " hi" });
    // Underscore is not \p{L}, so it starts a fresh "word".
    try expectTokens(&re, "foo_bar", &.{ "foo", "_bar" });
}

test "cl100k: a mixed line segments correctly end-to-end" {
    const a = std.testing.allocator;
    var re = try zeetah.Regex.compile(a, CL100K);
    defer re.deinit();
    try expectTokens(
        &re,
        "I don't think it'll work 42 times.",
        &.{ "I", " don", "'t", " think", " it", "'ll", " work", " ", "42", " times", "." },
    );
}

// ── throughput benchmark ─────────────────────────────────────────────────────

fn monotonicNs() u64 {
    const clk: std.c.clockid_t = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => .UPTIME_RAW,
        else => .MONOTONIC,
    };
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.c.clock_gettime(clk, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// Representative ASCII corpus (prose + code + numbers + punctuation +
/// contractions + whitespace) so every alternation branch is exercised.
const SAMPLE =
    \\The quick brown fox jumps over 13 lazy dogs; it doesn't mind. "I'll
    \\refactor this later," she said, and typed: fn parse(input: []const u8)
    \\!void { return error.NotImplemented; } // a TODO from 2024-01-15.
    \\Prices: $42.50 for 7 items, 100% done (really??). dev_name@example.com
    \\visits https://example.org/path?q=1&r=2 about 3 times a week. We've
    \\seen what they're doing; it'd work, I think. NUMS = [1, 22, 333, 4444];
    \\
;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    // Build a ~few-MB corpus by repeating the sample.
    const reps: usize = 8000;
    var corpus: std.ArrayList(u8) = .empty;
    defer corpus.deinit(a);
    try corpus.ensureTotalCapacity(a, SAMPLE.len * reps);
    var i: usize = 0;
    while (i < reps) : (i += 1) corpus.appendSliceAssumeCapacity(SAMPLE);
    const bytes = corpus.items;

    var re = try zeetah.Regex.compile(a, CL100K);
    defer re.deinit();

    _ = try re.count(bytes); // warm up

    var best_ns: u64 = std.math.maxInt(u64);
    var ntok: usize = 0;
    var k: usize = 0;
    while (k < 5) : (k += 1) {
        const t0 = monotonicNs();
        ntok = try re.count(bytes);
        const dt = monotonicNs() - t0;
        if (dt < best_ns) best_ns = dt;
    }

    const mb = @as(f64, @floatFromInt(bytes.len)) / (1024.0 * 1024.0);
    const secs = @as(f64, @floatFromInt(best_ns)) / 1e9;
    std.debug.print(
        \\GPT-4 cl100k_base pre-tokenizer (Zeetah, greedy-equivalent regex)
        \\  corpus      : {d:.2} MiB ({d} bytes)
        \\  pre-tokens  : {d}
        \\  best of 5   : {d:.3} ms
        \\  throughput  : {d:.1} MiB/s, {d:.2} M pre-tokens/s
        \\
    , .{
        mb,                  bytes.len,
        ntok,                secs * 1000.0,
        mb / secs,           (@as(f64, @floatFromInt(ntok)) / 1e6) / secs,
    });
}
