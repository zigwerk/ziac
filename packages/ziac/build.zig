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

    const proto_codegen_module = b.createModule(.{
        .root_source_file = b.path("src/gcp/proto_codegen_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const proto_codegen = b.addExecutable(.{
        .name = "ziac-google-proto-contract",
        .root_module = proto_codegen_module,
    });
    const run_proto_codegen = b.addRunArtifact(proto_codegen);
    const proto_snapshot_step = b.step("proto-snapshot", "Print the pinned Google API semantic contract snapshot");
    proto_snapshot_step.dependOn(&run_proto_codegen.step);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const receipt_check_module = b.createModule(.{
        .root_source_file = b.path("test/verify_suite_receipt.zig"),
        .target = target,
        .optimize = optimize,
    });
    receipt_check_module.addImport("ziac", ziac);
    const receipt_check = b.addExecutable(.{
        .name = "ziac-verify-suite-receipt",
        .root_module = receipt_check_module,
    });
    const run_receipt_check = b.addRunArtifact(receipt_check);
    run_receipt_check.step.dependOn(&run_unit_tests.step);

    const dev_fixture_module = b.createModule(.{
        .root_source_file = b.path("test/dev_fixture_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dev_fixture = b.addExecutable(.{
        .name = "ziac-dev-fixture",
        .root_module = dev_fixture_module,
    });
    const dev_e2e_module = b.createModule(.{
        .root_source_file = b.path("test/dev_native_e2e_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    dev_e2e_module.addImport("ziac", ziac);
    const dev_e2e = b.addExecutable(.{
        .name = "ziac-dev-native-e2e",
        .root_module = dev_e2e_module,
    });
    const run_dev_e2e = b.addRunArtifact(dev_e2e);
    run_dev_e2e.addArtifactArg(dev_fixture);

    const test_step = b.step("test", "Run Ziac tests");
    test_step.dependOn(&run_receipt_check.step);
    test_step.dependOn(&run_dev_e2e.step);
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
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "local-cli", "examples/local_cli.zig");
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "global-container-service", "examples/global_container_service.zig");
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "zig-service", "examples/zig_service.zig");
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "cockroach-application-database", "examples/cockroach_application_database.zig");
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "cockroach-cluster", "examples/cockroach_cluster.zig");
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "cockroach-private-service-connect", "examples/cockroach_private_service_connect.zig");
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "production-global-service", "examples/production_global_service.zig");
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "gcp-specialization", "examples/gcp_specialization.zig");

    const visual_sample_module = b.createModule(.{
        .root_source_file = b.path("examples/visual_artifact.zig"),
        .target = target,
        .optimize = optimize,
    });
    visual_sample_module.addImport("ziac", ziac);
    const visual_sample_executable = b.addExecutable(.{
        .name = "ziac-visual-artifact",
        .root_module = visual_sample_module,
    });
    const run_visual_sample = b.addRunArtifact(visual_sample_executable);
    const visual_sample_step = b.step("visual-sample", "Print the representative Ziac visual artifact");
    visual_sample_step.dependOn(&run_visual_sample.step);
    examples_step.dependOn(&visual_sample_executable.step);

    const format_check = b.addSystemCommand(&.{ "zig", "fmt", "--check", "build.zig", "src", "test", "examples" });
    const release_checks = b.addSystemCommand(&.{"bash"});
    release_checks.addFileArg(b.path("scripts/release-checks.sh"));
    const release_gate = b.step("release-gate", "Run the complete credential-free Ziac release gate");
    release_gate.dependOn(&format_check.step);
    release_gate.dependOn(&release_checks.step);
    release_gate.dependOn(examples_step);
    release_gate.dependOn(&executable.step);
    release_gate.dependOn(&container_e2e_command.step);
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
