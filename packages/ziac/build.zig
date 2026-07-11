const std = @import("std");

fn addV2Test(b: *std.Build, runner: std.Build.LazyPath, options: std.Build.TestOptions) *std.Build.Step.Compile {
    var configured = options;
    configured.test_runner = .{ .path = runner, .mode = .server };
    return b.addTest(configured);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigeffect_std_dependency = b.dependency("zigeffect_std", .{});
    const zigeffect_std = zigeffect_std_dependency.module("zigeffect_std");
    const testing_runner = zigeffect_std_dependency.module("zigeffect_test_runner").root_source_file.?;

    const ziac = b.addModule("ziac", .{
        .root_source_file = b.path("src/ziac.zig"),
        .target = target,
        .optimize = optimize,
    });
    ziac.addImport("zigeffect_std", zigeffect_std);

    const tests = b.createModule(.{
        .root_source_file = b.path("test/all_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.addImport("ziac", ziac);
    tests.addImport("zigeffect_std", zigeffect_std);

    const unit_tests = addV2Test(b, testing_runner, .{
        .name = "ziac-tests",
        .root_module = tests,
    });

    const main_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_module.addImport("ziac", ziac);
    main_module.addImport("zigeffect_std", zigeffect_std);

    const executable = b.addExecutable(.{
        .name = "ziac",
        .root_module = main_module,
    });
    b.installArtifact(executable);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run Ziac tests");
    test_step.dependOn(&run_unit_tests.step);

    const examples_step = b.step("examples", "Build Ziac examples");
    examples_step.dependOn(test_step);
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "local-cli", "examples/local_cli.zig");
}

fn addExample(
    b: *std.Build,
    examples_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    testing_runner: std.Build.LazyPath,
    ziac: *std.Build.Module,
    zigeffect_std: *std.Build.Module,
    name: []const u8,
    path: []const u8,
) void {
    const module = b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("ziac", ziac);
    module.addImport("zigeffect_std", zigeffect_std);

    const executable = b.addExecutable(.{
        .name = b.fmt("ziac-{s}", .{name}),
        .root_module = module,
    });
    const tests = addV2Test(b, testing_runner, .{
        .name = b.fmt("ziac-{s}-tests", .{name}),
        .root_module = module,
    });
    const run_tests = b.addRunArtifact(tests);

    examples_step.dependOn(&executable.step);
    examples_step.dependOn(&run_tests.step);
}
