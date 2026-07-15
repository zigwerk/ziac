const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ziac_dep = b.dependency("ziac", .{ .target = target, .optimize = optimize });
    const gcpx_dep = b.dependency("ziac_gcpx", .{ .target = target, .optimize = optimize });
    const stack = b.createModule(.{ .root_source_file = b.path("ziac.stack.zig"), .target = target, .optimize = optimize });
    stack.addImport("ziac", ziac_dep.module("ziac"));
    stack.addImport("ziac_gcpx", gcpx_dep.module("ziac_gcpx"));
    const compiler_module = b.createModule(.{ .root_source_file = b.path("ziac_program.zig"), .target = target, .optimize = optimize });
    compiler_module.addImport("ziac", ziac_dep.module("ziac"));
    compiler_module.addImport("stack", stack);
    const compiler = b.addExecutable(.{ .name = "ziac-program-compiler", .root_module = compiler_module });
    const run_compiler = b.addRunArtifact(compiler);
    if (b.args) |args| run_compiler.addArgs(args);
    b.step("ziac-program", "Compile the typed Ziac infrastructure program").dependOn(&run_compiler.step);
    const tests = b.addTest(.{ .name = "project-tests", .root_module = stack, .test_runner = .{ .path = ziac_dep.module("zigeffect_test_runner").root_source_file.?, .mode = .server } });
    b.step("test", "Run deterministic project tests").dependOn(&b.addRunArtifact(tests).step);
}
