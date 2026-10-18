//! Build helper: fill `%SITE_URL%` in the site's templates (HTML pages,
//! sitemap.xml, robots.txt, llms.txt). Canonical links, Open Graph cards and
//! the sitemap need absolute URLs, and the public URL depends on where the
//! site is hosted (`zig build -Dsite-url=…`).
//!
//! Usage: site <site-url> <in> <out> [<in> <out> …]

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4 or (args.len - 2) % 2 != 0) return error.Usage;

    // Always end the base URL with exactly one '/' so templates can append paths.
    const raw = std.mem.trimEnd(u8, args[1], "/");
    const url = try std.mem.concat(arena, u8, &.{ raw, "/" });

    const cwd = std.Io.Dir.cwd();
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        const src = try cwd.readFileAlloc(init.io, args[i], arena, .limited(16 << 20));
        const out = try std.mem.replaceOwned(u8, arena, src, "%SITE_URL%", url);
        try cwd.writeFile(init.io, .{ .sub_path = args[i + 1], .data = out });
    }
}
