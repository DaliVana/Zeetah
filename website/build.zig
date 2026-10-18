const std = @import("std");

// The zeetah.dev website: the engine compiled to wasm32 plus a static site
// (the regex tester, a usage guide and a how-it-works page), built from the
// enclosing Zeetah checkout and deployed by .github/workflows/pages.yml.
//
//   zig build           → zig-out/web/ (index.html, zeetah.wasm, …)
//   zig build serve     → also serves zig-out/web on http://localhost:8080
//   zig build test      → Node smoke test of the wasm ABI + JS binding
//
// The page also opens straight from disk (file://): the build emits an
// inline base64 copy of the module (`zeetah-wasm.js`) the loader falls back
// to when it cannot fetch the `.wasm`.

/// Files in web/ that carry `%SITE_URL%` (filled by src/site.zig).
const templates = [_][]const u8{
    "index.html",
    "guide.html",
    "how-it-works.html",
    "sitemap.xml",
    "robots.txt",
    "llms.txt",
};

pub fn build(b: *std.Build) void {
    // The page measures throughput, so default to the engine's release mode.
    const optimize = b.option(std.builtin.Optimize, "optimize", "Wasm optimize mode: debug, safe, fast, small (default: fast)") orelse .fast;
    const port = b.option([]const u8, "port", "Port for `zig build serve` (default: 8080)") orelse "8080";
    // Public base URL, for canonical links, social cards and the sitemap.
    const site_url = b.option([]const u8, "site-url", "Public URL the site is hosted at (default: https://zeetah.dev/)") orelse "https://zeetah.dev/";

    // simd128 lets Zeetah's portable @Vector scans lower to Wasm SIMD
    // (Chrome 91+, Firefox 89+, Safari 16.4+).
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_features_add = std.Target.wasm.featureSet(&.{.simd128}),
    });

    const zeetah = b.dependency("zeetah", .{ .target = wasm_target, .optimize = optimize });

    const wasm = b.addExecutable(.{
        .name = "zeetah",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = wasm_target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zeetah", .module = zeetah.module("zeetah") }},
        }),
    });
    wasm.root_module.strip = true;
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    // `Regex.compile` builds its DFA tables on the stack (~1.5 MiB peak); the
    // freestanding default of 1 MiB traps on the first compile.
    wasm.stack_size = 8 * 1024 * 1024;

    const embed = b.addExecutable(.{
        .name = "embed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/embed.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        }),
    });
    embed.root_module.addAnonymousImport("zeetah_wasm", .{ .root_source_file = wasm.getEmittedBin() });
    const embed_run = b.addRunArtifact(embed);
    const wasm_js = embed_run.addOutputFileArg("zeetah-wasm.js");

    const site_gen = b.addExecutable(.{
        .name = "site",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/site.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        }),
    });
    const site_run = b.addRunArtifact(site_gen);
    site_run.addArg(site_url);

    // The whole site as one generated directory, installed to zig-out/web:
    // static assets copied as-is, templates filled, plus the wasm module.
    const site = b.addWriteFiles();
    _ = site.addCopyDirectory(b.path("web"), "", .{ .exclude_extensions = &.{ ".html", ".xml", ".txt" } });
    for (templates) |name| {
        site_run.addFileArg(b.path(b.fmt("web/{s}", .{name})));
        _ = site.addCopyFile(site_run.addOutputFileArg(name), name);
    }
    _ = site.addCopyFile(wasm.getEmittedBin(), "zeetah.wasm");
    _ = site.addCopyFile(wasm_js, "zeetah-wasm.js");
    // GitHub Pages custom domain. The Actions deployment takes the domain from
    // the repo's Pages settings; the file matters when publishing a branch.
    if (customDomain(site_url)) |host| _ = site.add("CNAME", b.fmt("{s}\n", .{host}));

    const install = b.getInstallStep();
    install.dependOn(&b.addInstallDirectory(.{
        .source_dir = site.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "web",
    }).step);

    // Serves the installed copy (default prefix) so a later `zig build` in
    // another terminal shows up on reload without restarting the server.
    const serve = b.addSystemCommand(&.{ "python3", "-m", "http.server", port, "--bind", "127.0.0.1", "--directory", "zig-out/web" });
    serve.setCwd(b.path("."));
    serve.step.dependOn(install);
    b.step("serve", "Build, then serve zig-out/web on http://localhost:8080").dependOn(&serve.step);

    const smoke = b.addSystemCommand(&.{"node"});
    smoke.addFileArg(b.path("test/smoke.mjs"));
    smoke.addFileArg(wasm.getEmittedBin());
    smoke.addFileArg(b.path("web/zeetah.js"));
    smoke.addFileArg(b.path("web/explain.js"));
    smoke.addFileArg(b.path("web/library.js"));
    b.step("test", "Run the Node smoke test against the wasm module").dependOn(&smoke.step);
}

/// Host of `url` when it is a custom domain (not a `*.github.io` address).
fn customDomain(url: []const u8) ?[]const u8 {
    var rest = url;
    if (std.mem.indexOf(u8, rest, "://")) |i| rest = rest[i + 3 ..];
    const host = rest[0 .. std.mem.indexOfAny(u8, rest, "/:") orelse rest.len];
    if (host.len == 0 or std.mem.endsWith(u8, host, ".github.io")) return null;
    return host;
}
