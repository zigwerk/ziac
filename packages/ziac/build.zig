const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigeffect_std = b.dependency("zigeffect_std", .{}).module("zigeffect_std");
    const zigeffect_postgres = b.dependency("zigeffect_postgres", .{}).module("zigeffect_postgres");

    const ziac = b.addModule("ziac", .{
        .root_source_file = b.path("src/ziac.zig"),
        .target = target,
        .optimize = optimize,
    });
    ziac.addImport("zigeffect_std", zigeffect_std);
    ziac.addImport("zigeffect_postgres", zigeffect_postgres);

    const tests = b.createModule(.{
        .root_source_file = b.path("test/all_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.addImport("ziac", ziac);
    tests.addImport("zigeffect_std", zigeffect_std);

    const unit_tests = b.addTest(.{
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
    const compile_contracts = b.addSystemCommand(&.{"bash"});
    compile_contracts.addFileArg(b.path("test/compile_fail/run.sh"));
    test_step.dependOn(&compile_contracts.step);

    const container_e2e_command = b.addSystemCommand(&.{"bash"});
    container_e2e_command.addFileArg(b.path("test/run_zig_service_container.sh"));
    const container_e2e_step = b.step("container-e2e", "Build and probe the native ZigService container");
    container_e2e_step.dependOn(&container_e2e_command.step);

    const container_e2e_all_command = b.addSystemCommand(&.{"bash"});
    container_e2e_all_command.addFileArg(b.path("test/run_zig_service_container.sh"));
    container_e2e_all_command.addArg("--all");
    const container_e2e_all_step = b.step("container-e2e-all", "Build and probe amd64 and arm64 ZigService containers");
    container_e2e_all_step.dependOn(&container_e2e_all_command.step);

    const examples_step = b.step("examples", "Build Ziac examples");
    examples_step.dependOn(test_step);
    addExample(b, examples_step, target, optimize, ziac, zigeffect_std, "local-cli", "examples/local_cli.zig");
    addExample(b, examples_step, target, optimize, ziac, zigeffect_std, "global-container-service", "examples/global_container_service.zig");
    addExample(b, examples_step, target, optimize, ziac, zigeffect_std, "zig-service", "examples/zig_service.zig");
    addExample(b, examples_step, target, optimize, ziac, zigeffect_std, "cockroach-application-database", "examples/cockroach_application_database.zig");
    addExample(b, examples_step, target, optimize, ziac, zigeffect_std, "cockroach-cluster", "examples/cockroach_cluster.zig");
    addExample(b, examples_step, target, optimize, ziac, zigeffect_std, "cockroach-private-service-connect", "examples/cockroach_private_service_connect.zig");
}

fn addExample(
    b: *std.Build,
    examples_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
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
    const tests = b.addTest(.{
        .name = b.fmt("ziac-{s}-tests", .{name}),
        .root_module = module,
    });
    const run_tests = b.addRunArtifact(tests);

    examples_step.dependOn(&executable.step);
    examples_step.dependOn(&run_tests.step);
}
