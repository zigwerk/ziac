const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ziac_dependency = b.dependency("ziac", .{ .target = target, .optimize = optimize });
    const ziac = ziac_dependency.module("ziac");

    const gcpx = b.addModule("ziac_gcpx", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    gcpx.addImport("ziac", ziac);

    const tests = b.createModule(.{
        .root_source_file = b.path("test/root_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.addImport("ziac", ziac);
    tests.addImport("ziac_gcpx", gcpx);
    tests.addImport("zigeffect_std", ziac_dependency.module("zigeffect_std"));
    const unit_tests = b.addTest(.{
        .name = "ziac-gcpx-tests",
        .root_module = tests,
        .test_runner = .{ .path = ziac_dependency.module("zigeffect_test_runner").root_source_file.?, .mode = .server },
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run Ziac GCpx Testing v2 suite");
    test_step.dependOn(&run_tests.step);

    const format = b.addSystemCommand(&.{ "zig", "fmt", "--check", "build.zig", "src", "test" });
    const check_step = b.step("check", "Compile, test and format Ziac GCpx");
    check_step.dependOn(test_step);
    check_step.dependOn(&format.step);
}
