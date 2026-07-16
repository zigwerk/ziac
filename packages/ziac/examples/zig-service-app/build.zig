const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zstd_dependency = b.dependency("zigeffect_std", .{ .target = target, .optimize = optimize });
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zigeffect_std", .module = zstd_dependency.module("zigeffect_std") }},
    });
    const executable = b.addExecutable(.{
        .name = "ziac-sample-api",
        .root_module = module,
    });
    b.installArtifact(executable);

    const unit_tests = b.addTest(.{
        .name = "ziac-sample-api-tests",
        .root_module = module,
        .test_runner = .{
            .path = zstd_dependency.module("zigeffect_test_runner").root_source_file.?,
            .mode = .server,
        },
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run sample backend tests");
    test_step.dependOn(&run_tests.step);
}
