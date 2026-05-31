//! Guard: the library's exported `version` must equal the package version
//! declared in build.zig.zon. build.zig reads the manifest's `.version` and
//! feeds it in via build options, so bumping one without the other fails CI
//! instead of letting `zeetah.version` silently disagree with the package.

const std = @import("std");
const zeetah = @import("zeetah");
const build_opts = @import("build_opts");

test "zeetah.version matches build.zig.zon .version" {
    var buf: [64]u8 = undefined;
    const code_ver = try std.fmt.bufPrint(&buf, "{d}.{d}.{d}", .{
        zeetah.version.major,
        zeetah.version.minor,
        zeetah.version.patch,
    });
    try std.testing.expectEqualStrings(build_opts.zon_version, code_ver);
}
