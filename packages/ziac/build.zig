const std = @import("std");

fn addV2Test(b: *std.Build, runner: std.Build.LazyPath, options: std.Build.TestOptions) *std.Build.Step.Compile {
    var configured = options;
    configured.test_runner = .{ .path = runner, .mode = .server };
    return b.addTest(configured);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zig_webui = b.dependency("zig_webui", .{
        .target = target,
        .optimize = optimize,
        .enable_tls = false,
        .is_static = true,
    });

    const zigeffect_std_dependency = b.dependency("zigeffect_std", .{});
    const zigeffect_std = zigeffect_std_dependency.module("zigeffect_std");
    const testing_runner = zigeffect_std_dependency.module("zigeffect_test_runner").root_source_file.?;
    _ = b.addModule("zigeffect_test_runner", .{
        .root_source_file = testing_runner,
        .target = target,
        .optimize = optimize,
    });
    const zigeffect_postgres = b.dependency("zigeffect_postgres", .{
        .openssl_include_path = b.option(std.Build.LazyPath, "openssl_include_path", "OpenSSL include directory for hosted Linux builds"),
    }).module("zigeffect_postgres");

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
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "package_root", b.pathFromRoot("."));
    main_module.addOptions("build_options", build_options);
    main_module.addImport("ziac", ziac);
    main_module.addImport("zigeffect_std", zigeffect_std);

    const executable = b.addExecutable(.{
        .name = "ziac",
        .root_module = main_module,
    });
    b.installArtifact(executable);

    const dashboard_host_module = b.createModule(.{
        .root_source_file = b.path("src/dashboard_host_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    dashboard_host_module.addImport("ziac", ziac);
    dashboard_host_module.addImport("webui", zig_webui.module("webui"));
    const dashboard_options = b.addOptions();
    dashboard_options.addOption([]const u8, "dashboard_root", b.pathFromRoot("dashboard/dist"));
    dashboard_host_module.addOptions("dashboard_options", dashboard_options);
    const dashboard_host_executable = b.addExecutable(.{
        .name = "ziac-dashboard-host",
        .root_module = dashboard_host_module,
    });
    b.installArtifact(dashboard_host_executable);

    const mcp_server_module = b.createModule(.{
        .root_source_file = b.path("src/mcp_server_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mcp_server_module.addImport("ziac", ziac);
    const mcp_server_executable = b.addExecutable(.{
        .name = "ziac-mcp",
        .root_module = mcp_server_module,
    });
    b.installArtifact(mcp_server_executable);

    const estate_control_plane_module = b.createModule(.{
        .root_source_file = b.path("src/estate_control_plane_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    estate_control_plane_module.addImport("ziac", ziac);
    const estate_control_plane_executable = b.addExecutable(.{
        .name = "ziac-estate-control-plane",
        .root_module = estate_control_plane_module,
    });
    b.installArtifact(estate_control_plane_executable);
    const billing_worker_module = b.createModule(.{
        .root_source_file = b.path("src/billing_worker_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    billing_worker_module.addImport("ziac", ziac);
    const billing_worker_executable = b.addExecutable(.{
        .name = "ziac-billing-worker",
        .root_module = billing_worker_module,
    });
    b.installArtifact(billing_worker_executable);
    const dashboard_ui_build = b.addSystemCommand(&.{ "bun", "run", "ziac:dashboard:build" });
    dashboard_ui_build.setCwd(.{ .cwd_relative = "../.." });
    installClientDistribution(b, &dashboard_ui_build.step);
    const run_dashboard_host = b.addRunArtifact(dashboard_host_executable);
    run_dashboard_host.step.dependOn(&dashboard_ui_build.step);
    if (b.args) |args| run_dashboard_host.addArgs(args);
    const dashboard_host_step = b.step("dashboard-host", "Open the standalone Ziac dashboard host");
    dashboard_host_step.dependOn(&run_dashboard_host.step);

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
    const scaffold_e2e = b.addSystemCommand(&.{"bash"});
    scaffold_e2e.addFileArg(b.path("test/scaffold_e2e.sh"));
    scaffold_e2e.addArg(b.getInstallPath(.bin, "ziac"));
    scaffold_e2e.addArg(b.getInstallPath(.bin, "ziac-mcp"));
    scaffold_e2e.addArg(b.getInstallPath(.bin, "ziac-dashboard-host"));
    scaffold_e2e.step.dependOn(b.getInstallStep());
    test_step.dependOn(&scaffold_e2e.step);
    test_step.dependOn(&dashboard_host_executable.step);
    test_step.dependOn(&mcp_server_executable.step);
    test_step.dependOn(&estate_control_plane_executable.step);
    test_step.dependOn(&billing_worker_executable.step);

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
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "application-platform", "examples/application_platform.zig");
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "application-services", "examples/application_services.zig");
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "compute-workloads", "examples/compute_workloads.zig");
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "network-delivery", "examples/network_delivery.zig");
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "secure-edge", "examples/secure_edge.zig");
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "connectivity", "examples/connectivity.zig");
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "container-platform", "examples/container_platform.zig");
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "monitoring", "examples/monitoring.zig");
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "logging", "examples/logging.zig");
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "build-delivery", "examples/build_delivery.zig");
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "cloud-deploy", "examples/cloud_deploy.zig");
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "kms-secret-lifecycle", "examples/kms_secret_lifecycle.zig");
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "project-foundation", "examples/project_foundation.zig");
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "governed-project-boundary", "examples/governed_project_boundary.zig");
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "security-foundation", "examples/security_foundation.zig");
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "data-engineering", "examples/data_engineering.zig");
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "event-integration", "examples/event_integration.zig");
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "vertex-ai", "examples/vertex_ai.zig");
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "analytics-warehouse", "examples/analytics_warehouse.zig");
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "document-store", "examples/document_store.zig");
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "managed-postgres", "examples/managed_postgres.zig");
    addExample(b, examples_step, target, optimize, testing_runner, ziac, zigeffect_std, "data-services-platform", "examples/data_services_platform.zig");

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
    release_gate.dependOn(&dashboard_host_executable.step);
    release_gate.dependOn(&mcp_server_executable.step);
    release_gate.dependOn(&estate_control_plane_executable.step);
    release_gate.dependOn(&billing_worker_executable.step);
    release_gate.dependOn(&dashboard_ui_build.step);
    release_gate.dependOn(&container_e2e_command.step);

    const self_host_gate = b.step("self-host-gate", "Compile and verify the external Ziac Cloud bootstrap workspace");
    self_host_gate.dependOn(test_step);
    self_host_gate.dependOn(&format_check.step);
    self_host_gate.dependOn(&dashboard_ui_build.step);
    self_host_gate.dependOn(&estate_control_plane_executable.step);
    self_host_gate.dependOn(&billing_worker_executable.step);

    const self_host_binaries = b.step("self-host-binaries", "Build the Ziac Cloud hosted service binaries");
    const install_estate_control_plane = b.addInstallArtifact(estate_control_plane_executable, .{});
    const install_billing_worker = b.addInstallArtifact(billing_worker_executable, .{});
    self_host_binaries.dependOn(&install_estate_control_plane.step);
    self_host_binaries.dependOn(&install_billing_worker.step);
}

fn installClientDistribution(b: *std.Build, dashboard_build: *std.Build.Step) void {
    installPackage(b, "ziac", ".", &.{
        "README.md",
        "build.zig",
        "build.zig.zon",
        "Dockerfile.self-host",
        "cloudbuild.self-host.yaml",
    }, &.{ "docs", "examples", "migrations", "proto", "scripts", "src", "test" });
    installPackage(b, "zigeffect", "../zigeffect", &.{
        "CHANGELOG.md",
        "README.md",
        "build.zig",
        "build.zig.zon",
    }, &.{ "conformance", "examples", "scripts", "src", "test", "tools", "workbench" });
    installPackage(b, "zigeffect-std", "../zigeffect-std", &.{
        "README.md",
        "build.zig",
        "build.zig.zon",
    }, &.{ "conformance", "examples", "src" });
    installPackage(b, "zigeffect-postgres", "../zigeffect-postgres", &.{
        "README.md",
        "build.zig",
        "build.zig.zon",
    }, &.{ "examples", "scripts", "src" });
    const dashboard_install = b.addInstallDirectory(.{
        .source_dir = b.path("dashboard"),
        .install_dir = .prefix,
        .install_subdir = "share/ziac/dashboard",
    });
    dashboard_install.step.dependOn(dashboard_build);
    b.getInstallStep().dependOn(&dashboard_install.step);
}

fn installPackage(
    b: *std.Build,
    name: []const u8,
    root: []const u8,
    files: []const []const u8,
    directories: []const []const u8,
) void {
    for (files) |file| {
        const source = if (std.mem.eql(u8, root, ".")) b.path(file) else b.path(b.pathJoin(&.{ root, file }));
        const destination = b.pathJoin(&.{ "share", name, file });
        const install = b.addInstallFileWithDir(source, .prefix, destination);
        b.getInstallStep().dependOn(&install.step);
    }
    for (directories) |directory| {
        const source = if (std.mem.eql(u8, root, ".")) b.path(directory) else b.path(b.pathJoin(&.{ root, directory }));
        const install = b.addInstallDirectory(.{
            .source_dir = source,
            .install_dir = .prefix,
            .install_subdir = b.pathJoin(&.{ "share", name, directory }),
        });
        b.getInstallStep().dependOn(&install.step);
    }
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
