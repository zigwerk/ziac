const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const executable = b.addExecutable(.{
        .name = "ziac-sample-api",
        .root_module = module,
    });
    b.installArtifact(executable);

    const unit_tests = b.addTest(.{
        .name = "ziac-sample-api-tests",
        .root_module = module,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run sample backend tests");
    test_step.dependOn(&run_tests.step);
}
