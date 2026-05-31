const std = @import("std");

// Post-cutover build: the engine is the unified meta pipeline only. The old
// AST/VM pipeline, its tooling, examples, and legacy/feature tests that
// exercised removed capabilities (captures, lookaround, backreferences,
// Unicode \p, POSIX classes, multiline/dotall) were deleted with it.
//
// `zig build test` runs the full internal unit suite (every surviving module's
// in-file tests via internal.zig's refAllDecls) plus the meta-phase gates.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Published package module (small stable surface).
    _ = b.addModule("zeetah", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Internal facade for the project's own tests/tools.
    const internal_mod = b.createModule(.{
        .root_source_file = b.path("src/internal.zig"),
        .target = target,
    });

    const test_step = b.step("test", "Run tests");

    // Whole-engine unit suite: internal.zig's `test { refAllDecls }` pulls in
    // every surviving module's in-file tests (parser, thompson, full_dfa,
    // core, planner, properties, seq_extract, lazy_dfa, bounded_bt,
    // onepass, cache, prefilter, regex, ...).
    const mod_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/internal.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    // Meta-phase gates.
    const meta_tests = [_][]const u8{
        // The meta_phase4/5/6 gates were dissolved into the per-feature suites
        // (perf linearity → security.zig; Cache/Pool + comptime⇄runtime →
        // feat_api.zig; known bounded boundary → feat_quantifiers.zig;
        // malformed-pattern rejections → parse_errors.zig).
        // Per-feature coverage + the rebuilt negative/security suites
        // (capture-free meta engine; see each file's header).
        "tests/feat_literals.zig",
        "tests/feat_classes.zig",
        "tests/feat_quantifiers.zig",
        "tests/feat_lazy.zig",
        "tests/feat_alternation.zig",
        "tests/feat_anchors.zig",
        "tests/feat_api.zig",
        "tests/feat_unicode.zig",
        "tests/feat_boundaries.zig",
        "tests/feat_captures.zig",
        "tests/captures_iter.zig",
        "tests/feat_lookaround.zig",
        "tests/feat_backref.zig",
        "tests/replace_template.zig",
        "tests/parse_errors.zig",
        "tests/security.zig",
    };
    for (meta_tests) |path| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zeetah", .module = internal_mod }},
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Doc-test: compile-and-run the snippets mirrored from README.md /
    // docs/EXAMPLES.md so the documented API (and the Zig allocator idiom the
    // examples show) can never silently rot. Part of `zig build test`, and also
    // exposed as a standalone `zig build doctest`.
    const doc_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/doc_examples.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zeetah", .module = internal_mod }},
        }),
    });
    const run_doc_tests = b.addRunArtifact(doc_tests);
    test_step.dependOn(&run_doc_tests.step);
    const doctest_step = b.step("doctest", "Compile & run the README/EXAMPLES code snippets");
    doctest_step.dependOn(&run_doc_tests.step);

    // Version guard: build.zig.zon is the single source of truth for the
    // package version. Feed its `.version` to tests/version_sync.zig, which
    // asserts the code's exported `version` matches — so the manifest and
    // src/root.zig can never silently drift apart.
    const zon = @import("build.zig.zon");
    const ver_opts = b.addOptions();
    ver_opts.addOption([]const u8, "zon_version", zon.version);
    const ver_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/version_sync.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zeetah", .module = internal_mod },
                .{ .name = "build_opts", .module = ver_opts.createModule() },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(ver_test).step);

    // GPT-4 (cl100k_base) pre-tokenizer workload. The correctness gate (its
    // `test` blocks) runs under `zig build test`; the throughput benchmark
    // (its `main`) runs under `zig build bench-tokenizer`. Both link libc for
    // a monotonic clock (Zig 0.16 std has no Timer/Instant).
    const tok_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench_tokenizer.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "zeetah", .module = internal_mod }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(tok_tests).step);

    const tok_bench = b.addExecutable(.{
        .name = "bench_tokenizer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench_tokenizer.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
            .imports = &.{.{ .name = "zeetah", .module = internal_mod }},
        }),
    });
    const tok_step = b.step("bench-tokenizer", "Run the GPT-4 cl100k pre-tokenizer throughput benchmark");
    tok_step.dependOn(&b.addRunArtifact(tok_bench).step);

    // Cross-engine smoke harness (now a single-engine smoke: the old oracle
    // was deleted at cutover).
    const parity = b.addExecutable(.{
        .name = "parity_harness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/parity_harness.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "zeetah", .module = internal_mod }},
        }),
    });
    b.installArtifact(parity);
    const parity_step = b.step("parity", "Run the meta-engine smoke harness");
    parity_step.dependOn(&b.addRunArtifact(parity).step);
}
