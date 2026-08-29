const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const segmented_list = b.addModule("segmented_list", .{
        .root_source_file = b.path("src/segmented_list.zig"),
    });

    const segmented_list_tests = b.addTest(.{
        .name = "segmented-list",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/segmented_list.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "segmented_list", .module = segmented_list }},
        }),
    });
    const compatibility_tests = b.addTest(.{
        .name = "compatibility",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/compatibility.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "segmented_list", .module = segmented_list }},
        }),
    });
    const fuzz_tests = b.addTest(.{
        .name = "fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "segmented_list", .module = segmented_list }},
        }),
    });

    const invalid_inline_capacity = b.addTest(.{
        .name = "reject invalid inline capacity",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/compile_errors/invalid_inline_capacity.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "segmented_list", .module = segmented_list }},
        }),
    });
    invalid_inline_capacity.expect_errors = .{
        .contains = "inline_capacity must be zero or a power of two",
    };

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(segmented_list_tests).step);
    test_step.dependOn(&b.addRunArtifact(compatibility_tests).step);
    test_step.dependOn(&b.addRunArtifact(fuzz_tests).step);
    test_step.dependOn(&invalid_inline_capacity.step);

    const benchmark = b.addExecutable(.{
        .name = "segmented-list-benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/benchmark.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "segmented_list", .module = segmented_list }},
        }),
    });
    const bench_step = b.step("bench", "Run benchmark");
    bench_step.dependOn(&b.addRunArtifact(benchmark).step);
}
