const std = @import("std");
const ziac = @import("ziac");

const agent_project_fixture = @embedFile("fixtures/agent/ziac.project.json");

fn testEnv(
    local: *ziac.state_backend.Local,
    fs: *ziac.zstd.FileSystem.MemoryFileSystem,
    console: *ziac.zstd.Console.CapturedConsole,
) ziac.cli.Env {
    local.* = ziac.state_backend.Local.init(ziac.local_state.Store.init(
        std.testing.allocator,
        ziac.local_state.memoryFiles(fs),
    ));
    return .{
        .console = console,
        .registry = ziac.stack_registry.fixtureRegistry(),
        .state = local.store(),
        .plan_files = ziac.local_state.memoryFiles(fs),
        .agent_files = ziac.local_state.memoryFiles(fs),
        .log_files = ziac.local_state.memoryFiles(fs),
    };
}

const CliEstateResolver = struct {
    fn resolver(self: *CliEstateResolver) ziac.estate_access.Resolver {
        return .{
            .ptr = self,
            .verify_identity = verifyIdentity,
            .lookup_entitlement = lookupEntitlement,
            .resolve_connection = resolveConnection,
        };
    }

    fn verifyIdentity(_: *anyopaque, _: []const u8, _: u64) anyerror!ziac.estate.Identity {
        return .{ .provider = .google, .verified = true, .subject = "google-subject-42" };
    }

    fn lookupEntitlement(_: *anyopaque, _: []const u8, _: u64) anyerror!ziac.estate_access.EntitlementRecord {
        return .{ .tier = .pro, .active = true, .expires_at_millis = 1_800_000_000_000 };
    }

    fn resolveConnection(_: *anyopaque, _: []const u8, _: []const u8, _: u64) anyerror!ziac.estate.Connection {
        return .{ .status = .connected, .project_id = "acme-prod" };
    }
};

test "cli agent commands orient persist query and hand off through JSON artifacts" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    try fs.writeFile("ziac.project.json", agent_project_fixture);
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);

    const orient_code = try ziac.cli.run(std.testing.allocator, &.{
        "agent", "orient", "--stack", "hello-global", "--stage", "dev", "--objective", "repair global API",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.success, orient_code);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "ziac.agent-status.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "planning") != null);
    try std.testing.expect(fs.exists(".ziac/agent/hello-global/dev/session.json"));

    console.stdout.clearRetainingCapacity();
    const next_code = try ziac.cli.run(std.testing.allocator, &.{
        "agent", "next", "--stack", "hello-global", "--stage", "dev",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.success, next_code);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "ziac plan --json") != null);

    console.stdout.clearRetainingCapacity();
    const query_code = try ziac.cli.run(std.testing.allocator, &.{
        "agent",      "query",                            "--stack", "hello-global", "--stage", "dev",
        "--resource", "gcp.run.Service.europe-west1.api",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.success, query_code);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "gcp.artifact.Repository.europe-west1.hello-global") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "sentinel-secret-for-tests") == null);

    console.stdout.clearRetainingCapacity();
    const handoff_code = try ziac.cli.run(std.testing.allocator, &.{
        "agent", "handoff", "--stack", "hello-global", "--stage", "dev", "--root-cause", "awaiting provider preflight",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.success, handoff_code);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "ziac.handoff.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "awaiting provider preflight") != null);
}

test "cli agent simulate and verify use the shared governed tool kernel" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    try fs.writeFile("ziac.project.json", agent_project_fixture);
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);
    var verification = ziac.agent_tools.ScriptedVerificationRunner.init("checks passed");
    env.verification_runner = verification.runner();

    const simulate_code = try ziac.cli.run(std.testing.allocator, &.{
        "agent",                                                                                                                                                                                                                           "simulate", "--stack", "hello-global", "--stage", "dev", "--arguments",
        "{\"scenario_id\":\"missing-iam\",\"kind\":\"iam_denied\",\"seed\":42,\"max_steps\":8,\"target_resource\":\"gcp.run.Service.europe-west1.api\",\"requirement\":\"global-api-healthy\",\"acceptance_check\":\"check-global-api\"}",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.success, simulate_code);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "ziac.scenario-receipt.v1") != null);

    console.stdout.clearRetainingCapacity();
    const verify_code = try ziac.cli.run(std.testing.allocator, &.{
        "agent", "verify", "--stack", "hello-global", "--stage", "dev", "--arguments", "{\"acceptance_check\":\"check-global-api\"}",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.success, verify_code);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "ziac.verification-receipt.v1") != null);
    try std.testing.expectEqual(@as(usize, 1), verification.call_count);
}

test "cli dev compiles explicit hybrid adaptations without provider mutations" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    try fs.writeFile("ziac.project.json", agent_project_fixture);
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);

    const code = try ziac.cli.run(std.testing.allocator, &.{
        "dev", "--stack", "hello-global", "--stage", "dev",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.success, code);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "ziac.dev-plan.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "local_process") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "\"provider_mutations\": 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "sentinel-secret-for-tests") == null);
}

test "cli dev watch fails closed when the native host is unavailable" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    try fs.writeFile("ziac.project.json", agent_project_fixture);
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);

    const code = try ziac.cli.run(std.testing.allocator, &.{
        "dev", "--watch", "--stack", "hello-global", "--stage", "dev",
    }, &env);

    try std.testing.expectEqual(ziac.cli.Exit.agent_error, code);
    try std.testing.expect(std.mem.indexOf(u8, console.stderrText(), "NativeDevHostUnavailable") != null);
}

test "cli estate scan resolves paid access and writes an observed artifact atomically" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);
    var access = CliEstateResolver{};
    var assets = ziac.estate.ScriptedClient.init(std.testing.allocator);
    defer assets.deinit();
    try assets.addPage(
        \\{"results":[{"name":"//run.googleapis.com/projects/acme-prod/locations/europe-west1/services/api","assetType":"run.googleapis.com/Service","location":"europe-west1","displayName":"api"}]}
    );
    env.estate_scan = .{
        .resolver = access.resolver(),
        .client = assets.client(),
        .session_assertion = "opaque-session-assertion",
        .now_millis = 1_783_764_000_000,
    };

    const code = try ziac.cli.run(std.testing.allocator, &.{
        "estate", "scan", "--connection", "gcp-connection-17", "--out", "estate.json", "--json",
    }, &env);

    try std.testing.expectEqual(ziac.cli.Exit.success, code);
    try std.testing.expect(fs.exists("estate.json"));
    const artifact = fs.readFile("estate.json").?;
    try std.testing.expect(std.mem.indexOf(u8, artifact, "\"ownership\":\"observed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "opaque-session-assertion") == null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "ziac.estate-scan-receipt.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "\"resources\":1") != null);
}

test "cli deploy watch streams timed immutable deployment events through the shared kernel" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);
    var runtime = ziac.watch_deploy.ScriptedRuntime.init();
    runtime.now_millis = 1_000;
    runtime.push_millis = 10;
    runtime.revision_millis = 20;
    runtime.readiness_millis = 30;
    runtime.traffic_millis = 10;
    env.watch_deploy = .{
        .runtime = runtime.runtime(),
        .envelope = .{
            .id = "cli-watch",
            .stages = &.{"dev"},
            .projects = &.{"project-dev"},
            .providers = &.{.gcp},
            .permissions = .{ .apply = true },
            .budget = .{ .max_updates = 1, .max_regions = 1 },
            .expires_at_millis = 20_000,
            .approved_plan_digest = "watch-plan",
        },
        .project = "project-dev",
        .now_millis = 1_000,
    };

    const code = try ziac.cli.run(std.testing.allocator, &.{
        "deploy",  "--watch",                                                                      "--stack",       "hello-global", "--stage", "dev",
        "--image", "repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "--plan-digest", "watch-plan",
    }, &env);

    try std.testing.expectEqual(ziac.cli.Exit.success, code);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "ziac.watch-deploy-event.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "\"total_millis\":70") != null);
    try std.testing.expectEqual(@as(usize, 1), runtime.traffic_count);
}

test "cli logs tail and explain read the durable causal stream" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var logs = ziac.log.Store.init(std.testing.allocator, .{});
    defer logs.deinit();
    try logs.append(.{ .event_id = "deploy", .timestamp_millis = 1, .source = .provider, .stream = .system, .severity = .info, .message = "deploy started", .resource_id = "service-api" });
    try logs.append(.{ .event_id = "failed", .parent_event_id = "deploy", .timestamp_millis = 2, .source = .cloud_run, .stream = .system, .severity = .err, .message = "revision unhealthy", .resource_id = "service-api" });
    const sessions = ziac.log.SessionStore.init(std.testing.allocator, ziac.local_state.memoryFiles(&fs), .{});
    try sessions.save("hello-global", "dev", &logs);
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);

    const logs_code = try ziac.cli.run(std.testing.allocator, &.{
        "logs", "--stack", "hello-global", "--stage", "dev", "--resource", "service-api", "--severity", "error",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.success, logs_code);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "revision unhealthy") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "deploy started") == null);

    console.stdout.clearRetainingCapacity();
    const explain_code = try ziac.cli.run(std.testing.allocator, &.{
        "log-explain", "--stack", "hello-global", "--stage", "dev", "--event", "failed",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.success, explain_code);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "deploy started") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "revision unhealthy") != null);
}

test "cli live tail ingests Cloud Logging through the shared durable stream" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);
    var cloud = ziac.log.ScriptedCloudLoggingClient.init(
        "{\"entries\":[{\"insertId\":\"cloud-live-1\",\"severity\":\"ERROR\",\"textPayload\":\"revision failed live\",\"resource\":{\"labels\":{\"location\":\"europe-west1\",\"service_name\":\"api\"}}}]}",
    );
    env.cloud_logging = .{
        .client = cloud.client(),
        .project_id = "acme-prod",
        .filter = "resource.type=\"cloud_run_revision\"",
        .session_id = "hello-global-dev",
    };

    const code = try ziac.cli.run(std.testing.allocator, &.{
        "tail", "--stack", "hello-global", "--stage", "dev", "--provider", "gcp", "--allow-live",
    }, &env);

    try std.testing.expectEqual(ziac.cli.Exit.success, code);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "revision failed live") != null);
    try std.testing.expect(fs.exists(".ziac/logs/hello-global/dev/events.jsonl"));
    try std.testing.expectEqual(@as(usize, 1), cloud.call_count);
}

test "cli plan prints deterministic create summary without writing state" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();

    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);
    const code = try ziac.cli.run(std.testing.allocator, &.{ "plan", "--stack", "hello-global", "--stage", "dev" }, &env);

    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "Plan: 2 create, 0 update, 0 delete, 0 noop") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "+ gcp.artifact.Repository hello-global") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "+ gcp.run.Service api") != null);
    try std.testing.expect(!fs.exists(".ziac/state/hello-global/dev/resources.json"));
}

test "cli derives preview stage for shell and JSON workflows" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);

    const human_code = try ziac.cli.run(std.testing.allocator, &.{
        "preview-stage", "--repository", "Acme/Platform", "--change", "42",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.success, human_code);
    try std.testing.expectEqualStrings("pr-42-9333e523\n", console.stdoutText());

    console.stdout.clearRetainingCapacity();
    const json_code = try ziac.cli.run(std.testing.allocator, &.{
        "preview-stage", "--repository", "Acme/Platform", "--change", "42", "--json",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.success, json_code);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "\"schema\":\"ziac.preview-stage.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "\"stage\":\"pr-42-9333e523\"") != null);

    console.stderr.clearRetainingCapacity();
    const invalid_code = try ziac.cli.run(std.testing.allocator, &.{
        "preview-stage", "--repository", "Acme/Platform", "--change", "0",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.usage, invalid_code);
    try std.testing.expect(std.mem.indexOf(u8, console.stderrText(), "InvalidChangeNumber") != null);
}

test "cli preview cleanup rejects production before lock acquisition" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);

    const code = try ziac.cli.run(std.testing.allocator, &.{
        "destroy",
        "--stack",
        "hello-global",
        "--stage",
        "prod",
        "--preview-cleanup",
        "--confirm",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.invalid_graph, code);
    try std.testing.expect(std.mem.indexOf(u8, console.stderrText(), "ProductionPreviewCleanupForbidden") != null);
    try std.testing.expect(!try env.state.hasLock("hello-global", "prod"));
}

test "cli canonical preview cleanup retains destructive confirmation" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);
    const stage = "pr-42-9333e523";
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    state.setLineage("hello-global/pr-42-9333e523");
    try state.put(.{
        .resource_id = "gcp.run.Service.europe-west1.api-pr-42-9333e523",
        .provider = .gcp,
        .type_name = "gcp.run.Service",
        .logical_id = "api-pr-42-9333e523",
        .desired_hash = "preview",
        .status = .created,
    });
    try ziac.local_state.Store.init(std.testing.allocator, ziac.local_state.memoryFiles(&fs)).saveResources("hello-global", stage, &state);

    const refused = try ziac.cli.run(std.testing.allocator, &.{
        "destroy", "--stack", "hello-global", "--stage", stage, "--preview-cleanup",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.provider_error, refused);
    try std.testing.expect(std.mem.indexOf(u8, console.stderrText(), "DestructiveConfirmationRequired") != null);

    console.stderr.clearRetainingCapacity();
    const confirmed = try ziac.cli.run(std.testing.allocator, &.{
        "destroy", "--stack", "hello-global", "--stage", stage, "--preview-cleanup", "--confirm",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.success, confirmed);
}

test "cli rollback requires confirmation before lock acquisition" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);

    const code = try ziac.cli.run(std.testing.allocator, &.{
        "rollback", "--stack", "hello-global", "--stage", "prod",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.provider_error, code);
    try std.testing.expect(std.mem.indexOf(u8, console.stderrText(), "DestructiveConfirmationRequired") != null);
    try std.testing.expect(!try env.state.hasLock("hello-global", "prod"));
}

test "cli rollback rejects mutable current Cloud Run images" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);
    _ = try ziac.cli.run(std.testing.allocator, &.{
        "deploy", "--stack", "hello-global", "--stage", "prod",
    }, &env);
    console.stderr.clearRetainingCapacity();

    const code = try ziac.cli.run(std.testing.allocator, &.{
        "rollback", "--stack", "hello-global", "--stage", "prod", "--confirm",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.invalid_graph, code);
    try std.testing.expect(std.mem.indexOf(u8, console.stderrText(), "RollbackImageNotImmutable") != null);
    try std.testing.expect(!try env.state.hasLock("hello-global", "prod"));
}

test "cli rollback applies the previous global image through normal state checkpoints" {
    const image_v1 = "europe-west1-docker.pkg.dev/test-ziac-disposable/apps/api@sha256:1111111111111111111111111111111111111111111111111111111111111111";
    const image_v2 = "europe-west1-docker.pkg.dev/test-ziac-disposable/apps/api@sha256:2222222222222222222222222222222222222222222222222222222222222222";
    const service_regions = [_][]const u8{ "europe-west1", "us-central1" };
    var registry = ziac.stack_registry.configuredRegistry(.{
        .project_id = "test-ziac-disposable",
        .region = service_regions[0],
        .regions = &service_regions,
        .service_account = "api@test-ziac-disposable.iam.gserviceaccount.com",
        .image = image_v2,
        .domain = "api.example.com",
        .dns_zone = "example-com",
    });
    var program = try registry.build(std.testing.allocator, .{ .stack = "global-container", .stage = "prod" });
    defer program.deinit();

    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    state.setLineage("global-container/prod");
    for (program.graph.resources.items) |node| {
        const desired_hash = std.fmt.bytesToHex(node.inputs_hash, .lower);
        const service_outputs = [_]ziac.state.StateOutput{
            .{ .name = "image_ref", .value = .{ .string = image_v2 } },
            .{ .name = "previous_image_ref", .value = .{ .string = image_v1 } },
        };
        const address_outputs = [_]ziac.state.StateOutput{
            .{ .name = "address", .value = .{ .string = "203.0.113.10" } },
        };
        const certificate_outputs = [_]ziac.state.StateOutput{
            .{ .name = "status", .value = .{ .string = "ACTIVE" } },
        };
        const outputs: []const ziac.state.StateOutput = if (std.mem.eql(u8, node.type_name, "gcp.run.Service"))
            &service_outputs
        else if (std.mem.eql(u8, node.type_name, "gcp.compute.GlobalAddress"))
            &address_outputs
        else if (std.mem.eql(u8, node.type_name, "gcp.compute.ManagedSslCertificate"))
            &certificate_outputs
        else
            &.{};
        try state.put(.{
            .resource_id = node.id,
            .provider = node.provider,
            .type_name = node.type_name,
            .schema_version = node.schema_version,
            .logical_id = node.logical_id,
            .physical_id = node.id,
            .desired_hash = desired_hash[0..],
            .observed_hash = desired_hash[0..],
            .outputs = outputs,
            .status = .updated,
        });
    }
    const local_store = ziac.local_state.Store.init(std.testing.allocator, ziac.local_state.memoryFiles(&fs));
    try local_store.saveResources("global-container", "prod", &state);
    var local = ziac.state_backend.Local.init(local_store);
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var env = ziac.cli.Env{
        .console = &console,
        .registry = registry,
        .state = local.store(),
    };

    const code = try ziac.cli.run(std.testing.allocator, &.{
        "rollback", "--stack", "global-container", "--stage", "prod", "--confirm",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.success, code);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "Rollback complete") != null);
    var loaded = try env.state.loadResources("global-container", "prod");
    defer loaded.deinit();
    for (service_regions) |region| {
        const resource_id = try std.fmt.allocPrint(std.testing.allocator, "gcp.run.Service.{s}.api", .{region});
        defer std.testing.allocator.free(resource_id);
        const record = loaded.store.get(resource_id).?;
        try std.testing.expectEqualStrings(image_v1, stateOutputString(record.outputs, "image_ref").?);
    }

    console.stdout.clearRetainingCapacity();
    console.stderr.clearRetainingCapacity();
    const repeated = try ziac.cli.run(std.testing.allocator, &.{
        "rollback", "--stack", "global-container", "--stage", "prod", "--confirm",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.invalid_graph, repeated);
    try std.testing.expect(std.mem.indexOf(u8, console.stderrText(), "RollbackUnavailable") != null);
}

fn stateOutputString(outputs: []const ziac.state.StateOutput, name: []const u8) ?[]const u8 {
    for (outputs) |provider_output| {
        if (!std.mem.eql(u8, provider_output.name, name)) continue;
        return switch (provider_output.value) {
            .string => |text| text,
            else => null,
        };
    }
    return null;
}

test "cli deploy persists state and redacted outputs" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();

    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);
    const code = try ziac.cli.run(std.testing.allocator, &.{ "deploy", "--stack", "hello-global", "--stage", "dev" }, &env);

    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(fs.exists(".ziac/state/hello-global/dev/resources.json"));
    try std.testing.expect(fs.exists(".ziac/state/hello-global/dev/outputs.json"));
    const outputs = fs.readFile(".ziac/state/hello-global/dev/outputs.json").?;
    try std.testing.expect(std.mem.indexOf(u8, outputs, "sentinel-secret-for-tests") == null);
}

test "cli migrates local state to the selected remote backend" {
    var files = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer files.deinit();
    const local_store = ziac.local_state.Store.init(std.testing.allocator, ziac.local_state.memoryFiles(&files));
    var source = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer source.deinit();
    source.setLineage("hello-global/prod");
    try source.put(.{
        .resource_id = "test.Resource.api",
        .type_name = "test.Resource",
        .logical_id = "api",
        .desired_hash = "v1",
        .status = .created,
    });
    try local_store.saveResources("hello-global", "prod", &source);

    var objects = ziac.state_backend.MemoryObjectStore.init(std.testing.allocator);
    defer objects.deinit();
    var remote = try ziac.state_backend.Remote.init(std.testing.allocator, objects.objectStore(), .{});
    defer remote.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var env = ziac.cli.Env{
        .console = &console,
        .registry = ziac.stack_registry.fixtureRegistry(),
        .state = remote.store(),
        .migration_source = local_store,
    };

    const code = try ziac.cli.run(std.testing.allocator, &.{
        "state-migrate",
        "--stack",
        "hello-global",
        "--stage",
        "prod",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.success, code);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "State migration complete") != null);
    var loaded = try env.state.loadResources("hello-global", "prod");
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u64, 1), loaded.store.serialValue());
}

test "cli deploy checkpoints resources outputs and lock through remote state" {
    var objects = ziac.state_backend.MemoryObjectStore.init(std.testing.allocator);
    defer objects.deinit();
    var remote = try ziac.state_backend.Remote.init(std.testing.allocator, objects.objectStore(), .{});
    defer remote.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var env = ziac.cli.Env{
        .console = &console,
        .registry = ziac.stack_registry.fixtureRegistry(),
        .state = remote.store(),
    };

    const code = try ziac.cli.run(std.testing.allocator, &.{
        "deploy",
        "--stack",
        "hello-global",
        "--stage",
        "remote",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.success, code);
    try std.testing.expect(objects.content("ziac/state/hello-global/remote/resources.json") != null);
    try std.testing.expect(objects.content("ziac/state/hello-global/remote/outputs.json") != null);
    try std.testing.expect(objects.content("ziac/state/hello-global/remote/lock.json") == null);
}

test "cli outputs prints redacted secret values" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);

    _ = try ziac.cli.run(std.testing.allocator, &.{ "deploy", "--stack", "hello-global", "--stage", "dev" }, &env);
    console.stdout.clearRetainingCapacity();
    const code = try ziac.cli.run(std.testing.allocator, &.{ "outputs", "--stack", "hello-global", "--stage", "dev" }, &env);

    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "service_url=https://api-europe-west1-ziac-dev.run.app") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "repository_url=europe-west1-docker.pkg.dev/ziac-dev/hello-global") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "database_url=[REDACTED]") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "sentinel-secret-for-tests") == null);
}

test "cli destroy requires explicit destructive confirmation" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);

    _ = try ziac.cli.run(std.testing.allocator, &.{ "deploy", "--stack", "hello-global", "--stage", "dev" }, &env);
    console.stdout.clearRetainingCapacity();
    const code = try ziac.cli.run(std.testing.allocator, &.{ "destroy", "--stack", "hello-global", "--stage", "dev" }, &env);

    try std.testing.expectEqual(ziac.cli.Exit.provider_error, code);
    try std.testing.expect(std.mem.indexOf(u8, console.stderrText(), "DestructiveConfirmationRequired") != null);
    const resources = fs.readFile(".ziac/state/hello-global/dev/resources.json").?;
    try std.testing.expect(std.mem.indexOf(u8, resources, "\"status\":\"deleted\"") == null);
}

test "cli destroy accepts explicit destructive confirmation" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);

    _ = try ziac.cli.run(std.testing.allocator, &.{ "deploy", "--stack", "hello-global", "--stage", "dev" }, &env);
    console.stdout.clearRetainingCapacity();
    const code = try ziac.cli.run(
        std.testing.allocator,
        &.{ "destroy", "--stack", "hello-global", "--stage", "dev", "--confirm" },
        &env,
    );

    try std.testing.expectEqual(ziac.cli.Exit.success, code);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "Destroy complete") != null);
    const resources = fs.readFile(".ziac/state/hello-global/dev/resources.json").?;
    try std.testing.expect(std.mem.indexOf(u8, resources, "\"status\":\"deleted\"") != null);
}

test "cli state prints persisted resource status" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);

    _ = try ziac.cli.run(std.testing.allocator, &.{ "deploy", "--stack", "hello-global", "--stage", "dev" }, &env);
    console.stdout.clearRetainingCapacity();
    const code = try ziac.cli.run(std.testing.allocator, &.{ "state", "--stack", "hello-global", "--stage", "dev" }, &env);

    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "gcp.artifact.Repository.europe-west1.hello-global created") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "gcp.run.Service.europe-west1.api created") != null);
}

test "cli plan emits stable JSON command output" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);

    const code = try ziac.cli.run(
        std.testing.allocator,
        &.{ "plan", "--stack", "hello-global", "--stage", "dev", "--out", "review/dev.plan.json", "--json" },
        &env,
    );

    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "\"schema\":\"ziac.command.v2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "\"command\":\"plan\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "\"create\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "\"plan_path\":\"review/dev.plan.json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "\"plan_digest\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "\"approval_required\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "Plan:") == null);
}

test "cli saves an immutable plan and deploys its exact operations" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);

    const plan_code = try ziac.cli.run(std.testing.allocator, &.{
        "plan",
        "--stack",
        "hello-global",
        "--stage",
        "review",
        "--out",
        "plans/review.json",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.success, plan_code);
    try std.testing.expect(fs.exists("plans/review.json"));
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "Plan digest:") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "Approval required: no") != null);
    console.stdout.clearRetainingCapacity();

    const deploy_code = try ziac.cli.run(std.testing.allocator, &.{
        "deploy",
        "--stack",
        "hello-global",
        "--stage",
        "review",
        "--plan",
        "plans/review.json",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.success, deploy_code);
    try std.testing.expect(fs.exists(".ziac/state/hello-global/review/resources.json"));
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "Deploy complete") != null);
    console.stderr.clearRetainingCapacity();
    const overwrite_code = try ziac.cli.run(std.testing.allocator, &.{
        "plan", "--stack", "hello-global", "--stage", "review", "--out", "plans/review.json",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.invalid_graph, overwrite_code);
    try std.testing.expect(std.mem.indexOf(u8, console.stderrText(), "PlanAlreadyExists") != null);
}

test "cli saved plan rejects changed state target and desired graph" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);
    _ = try ziac.cli.run(std.testing.allocator, &.{
        "plan", "--stack", "hello-global", "--stage", "prod", "--out", "plans/prod.json",
    }, &env);

    console.stderr.clearRetainingCapacity();
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    state.setLineage("hello-global/prod");
    try state.put(.{
        .resource_id = "test.Resource.changed",
        .type_name = "test.Resource",
        .logical_id = "changed",
        .desired_hash = "changed",
        .status = .created,
    });
    const local_store = ziac.local_state.Store.init(std.testing.allocator, ziac.local_state.memoryFiles(&fs));
    try local_store.saveResources("hello-global", "prod", &state);
    const stale_code = try ziac.cli.run(std.testing.allocator, &.{
        "deploy", "--stack", "hello-global", "--stage", "prod", "--plan", "plans/prod.json",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.provider_error, stale_code);
    try std.testing.expect(std.mem.indexOf(u8, console.stderrText(), "StalePlan") != null);

    console.stderr.clearRetainingCapacity();
    const target_code = try ziac.cli.run(std.testing.allocator, &.{
        "deploy", "--stack", "hello-global", "--stage", "other", "--plan", "plans/prod.json",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.invalid_graph, target_code);
    try std.testing.expect(std.mem.indexOf(u8, console.stderrText(), "PlanTargetMismatch") != null);

    console.stderr.clearRetainingCapacity();
    const regions = [_][]const u8{"europe-west1"};
    env.registry = ziac.stack_registry.configuredRegistry(.{
        .project_id = "ziac-dev",
        .region = regions[0],
        .regions = &regions,
        .image = "europe-west1-docker.pkg.dev/ziac-dev/apps/changed@sha256:def",
        .domain = "api.example.com",
    });
    const graph_code = try ziac.cli.run(std.testing.allocator, &.{
        "deploy", "--stack", "hello-global", "--stage", "prod", "--plan", "plans/prod.json",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.invalid_graph, graph_code);
    try std.testing.expect(std.mem.indexOf(u8, console.stderrText(), "PlanDesiredGraphMismatch") != null);
}

test "cli destructive saved plan requires its exact digest approval" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    state.setLineage("hello-global/prod");
    try state.put(.{
        .resource_id = "gcp.run.Service.retired",
        .provider = .gcp,
        .type_name = "gcp.run.Service",
        .logical_id = "retired",
        .desired_hash = "retired",
        .status = .created,
    });
    try ziac.local_state.Store.init(std.testing.allocator, ziac.local_state.memoryFiles(&fs)).saveResources("hello-global", "prod", &state);
    _ = try ziac.cli.run(std.testing.allocator, &.{
        "plan", "--stack", "hello-global", "--stage", "prod", "--out", "plans/delete.json",
    }, &env);
    var saved = try ziac.plan_format.load(ziac.local_state.memoryFiles(&fs), std.testing.allocator, "plans/delete.json", .{});
    defer saved.deinit();
    try std.testing.expect(saved.approval_required);
    const digest = saved.metadata().digestHex();

    console.stderr.clearRetainingCapacity();
    const missing_code = try ziac.cli.run(std.testing.allocator, &.{
        "deploy", "--stack", "hello-global", "--stage", "prod", "--plan", "plans/delete.json",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.invalid_graph, missing_code);
    try std.testing.expect(std.mem.indexOf(u8, console.stderrText(), "PlanApprovalRequired") != null);

    console.stderr.clearRetainingCapacity();
    const wrong_code = try ziac.cli.run(std.testing.allocator, &.{
        "deploy", "--stack", "hello-global", "--stage", "prod", "--plan", "plans/delete.json", "--approve", "wrong",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.invalid_graph, wrong_code);
    try std.testing.expect(std.mem.indexOf(u8, console.stderrText(), "PlanApprovalMismatch") != null);

    console.stderr.clearRetainingCapacity();
    const approved_code = try ziac.cli.run(std.testing.allocator, &.{
        "deploy", "--stack", "hello-global", "--stage", "prod", "--plan", "plans/delete.json", "--approve", &digest,
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.success, approved_code);
    const persisted = fs.readFile(".ziac/state/hello-global/prod/resources.json").?;
    try std.testing.expect(std.mem.indexOf(u8, persisted, "\"resource_id\":\"gcp.run.Service.retired\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, persisted, "\"status\":\"deleted\"") != null);
}

test "cli direct destructive deploy requires confirm" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    state.setLineage("hello-global/direct");
    try state.put(.{
        .resource_id = "gcp.run.Service.retired",
        .provider = .gcp,
        .type_name = "gcp.run.Service",
        .logical_id = "retired",
        .desired_hash = "retired",
        .status = .created,
    });
    try ziac.local_state.Store.init(std.testing.allocator, ziac.local_state.memoryFiles(&fs)).saveResources("hello-global", "direct", &state);

    const refused = try ziac.cli.run(std.testing.allocator, &.{
        "deploy", "--stack", "hello-global", "--stage", "direct",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.provider_error, refused);
    try std.testing.expect(std.mem.indexOf(u8, console.stderrText(), "DestructiveConfirmationRequired") != null);

    console.stderr.clearRetainingCapacity();
    const confirmed = try ziac.cli.run(std.testing.allocator, &.{
        "deploy", "--stack", "hello-global", "--stage", "direct", "--confirm",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.success, confirmed);
}

test "cli writer reports lock conflict without removing another owner lock" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);
    try env.state.acquireLock("hello-global", "dev", .{
        .owner_id = "other-writer",
        .command = "deploy",
        .acquired_at_millis = 1,
    });

    const code = try ziac.cli.run(
        std.testing.allocator,
        &.{ "deploy", "--stack", "hello-global", "--stage", "dev" },
        &env,
    );

    try std.testing.expectEqual(ziac.cli.Exit.state_error, code);
    try std.testing.expect(std.mem.indexOf(u8, console.stderrText(), "LockConflict") != null);
    try std.testing.expect(try env.state.hasLock("hello-global", "dev"));
}

test "cli import validates IDs and persists a valid imported resource" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);
    const resource_id = "gcp.run.Service.europe-west1.api";

    const invalid = try ziac.cli.run(
        std.testing.allocator,
        &.{ "import", "--stack", "hello-global", "--stage", "dev", "--resource", resource_id, "--id", "bad id" },
        &env,
    );
    try std.testing.expectEqual(ziac.cli.Exit.provider_error, invalid);
    console.stderr.clearRetainingCapacity();

    const valid = try ziac.cli.run(
        std.testing.allocator,
        &.{ "import", "--stack", "hello-global", "--stage", "dev", "--resource", resource_id, "--id", "projects/ziac-dev/locations/europe-west1/services/api" },
        &env,
    );
    try std.testing.expectEqual(@as(u8, 0), valid);
    const resources = fs.readFile(".ziac/state/hello-global/dev/resources.json").?;
    try std.testing.expect(std.mem.indexOf(u8, resources, "projects/ziac-dev/locations/europe-west1/services/api") != null);
}

test "cli refresh and lineage-checked unlock commands are available" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);

    const refresh_code = try ziac.cli.run(
        std.testing.allocator,
        &.{ "refresh", "--stack", "hello-global", "--stage", "dev" },
        &env,
    );
    try std.testing.expectEqual(@as(u8, 0), refresh_code);
    try env.state.acquireLock("hello-global", "dev", .{
        .owner_id = "stale-owner",
        .command = "deploy",
        .acquired_at_millis = 1,
    });

    const unlock_code = try ziac.cli.run(
        std.testing.allocator,
        &.{ "unlock", "--stack", "hello-global", "--stage", "dev", "--lineage", "hello-global/dev" },
        &env,
    );
    try std.testing.expectEqual(@as(u8, 0), unlock_code);
    try std.testing.expect(!try env.state.hasLock("hello-global", "dev"));
}

test "cli auth doctor reports ADC source without stack options or secrets" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    try fs.writeFile("/adc.json", @embedFile("fixtures/gcp/authorized_user.json"));
    var auth_env = ziac.zstd.Env.EnvMap.init(std.testing.allocator);
    defer auth_env.deinit();
    try auth_env.put("GOOGLE_APPLICATION_CREDENTIALS", "/adc.json");
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);
    env.auth_env = &auth_env;
    env.auth_files = ziac.gcp.auth.memoryFileReader(&fs);

    const code = try ziac.cli.run(std.testing.allocator, &.{ "auth", "doctor" }, &env);

    try std.testing.expectEqual(ziac.cli.Exit.success, code);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "ziac.gcp-auth-doctor.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "authorized_user") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "dummy-client-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "dummy-refresh-token") == null);
}

test "cli selects an injected live GCP registry only when explicitly allowed" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);
    env.registry = ziac.stack_registry.configuredRegistry(.{
        .project_id = "test-ziac-disposable",
        .image = "europe-west1-docker.pkg.dev/test-ziac-disposable/hello-global/api:v1",
    });
    var live = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer live.deinit();
    var providers = ziac.provider.ProviderRegistry{};
    providers.register(.gcp, live.provider());
    env.live_providers = providers;
    env.live_project_id = "test-ziac-disposable";

    const code = try ziac.cli.run(std.testing.allocator, &.{
        "deploy",
        "--stack",
        "hello-global",
        "--stage",
        "dev",
        "--provider",
        "gcp",
        "--allow-live",
        "--live-test",
    }, &env);

    try std.testing.expectEqual(ziac.cli.Exit.success, code);
    try std.testing.expectEqual(@as(usize, 2), live.creates);
}

test "cli live GCP selection fails before state mutation when providers are unavailable" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);
    env.live_project_id = "test-ziac-disposable";

    const code = try ziac.cli.run(std.testing.allocator, &.{
        "deploy",
        "--stack",
        "hello-global",
        "--stage",
        "dev",
        "--provider",
        "gcp",
        "--allow-live",
    }, &env);

    try std.testing.expectEqual(ziac.cli.Exit.auth_error, code);
    try std.testing.expect(std.mem.indexOf(u8, console.stderrText(), "LiveProviderUnavailable") != null);
    try std.testing.expect(!fs.exists(".ziac/state/hello-global/dev/resources.json"));
    try std.testing.expect(!try env.state.hasLock("hello-global", "dev"));
}

test "cli plans the configured global ContainerService stack" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);
    const regions = [_][]const u8{ "europe-west1", "us-central1" };
    env.registry = ziac.stack_registry.configuredRegistry(.{
        .project_id = "test-ziac-disposable",
        .region = regions[0],
        .regions = &regions,
        .image = "europe-west1-docker.pkg.dev/test-ziac-disposable/apps/api@sha256:abc",
        .domain = "api.example.com",
        .dns_zone = "example-com",
    });

    const code = try ziac.cli.run(std.testing.allocator, &.{
        "plan",
        "--stack",
        "global-container",
        "--stage",
        "smoke",
    }, &env);

    try std.testing.expectEqual(ziac.cli.Exit.success, code);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "Plan: 14 create") != null);
    try std.testing.expect(!fs.exists(".ziac/state/global-container/smoke/resources.json"));

    console.stdout.clearRetainingCapacity();
    const deploy_code = try ziac.cli.run(std.testing.allocator, &.{
        "deploy",
        "--stack",
        "global-container",
        "--stage",
        "smoke",
    }, &env);
    try std.testing.expectEqual(ziac.cli.Exit.success, deploy_code);
    const outputs = fs.readFile(".ziac/state/global-container/smoke/outputs.json").?;
    try std.testing.expect(std.mem.indexOf(u8, outputs, "\"name\":\"ip_address\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, outputs, "\"name\":\"certificate_status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, outputs, "\"name\":\"service_url_europe-west1\"") != null);
}

test "cli fail-region requires the explicit disposable live-test gate" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);

    const code = try ziac.cli.run(std.testing.allocator, &.{
        "fail-region",
        "--stack",
        "global-container",
        "--stage",
        "smoke",
        "--region",
        "europe-west1",
        "--provider",
        "gcp",
        "--allow-live",
    }, &env);

    try std.testing.expectEqual(ziac.cli.Exit.auth_error, code);
    try std.testing.expect(std.mem.indexOf(u8, console.stderrText(), "LiveTestRequired") != null);
    try std.testing.expect(!fs.exists(".ziac/state/global-container/smoke/lock.json"));
}

test "cli fail-region deletes one remote service and preserves state for restoration" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);
    const regions = [_][]const u8{ "europe-west1", "us-central1" };
    env.registry = ziac.stack_registry.configuredRegistry(.{
        .project_id = "test-ziac-disposable",
        .region = regions[0],
        .regions = &regions,
        .image = "europe-west1-docker.pkg.dev/test-ziac-disposable/apps/api@sha256:abc",
        .domain = "api.example.com",
    });
    var program = try env.registry.build(std.testing.allocator, .{ .stack = "global-container", .stage = "smoke" });
    defer program.deinit();
    const service = findResource(&program.graph, "gcp.run.Service.europe-west1.api");
    var live = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer live.deinit();
    var providers = ziac.provider.ProviderRegistry{};
    providers.register(.gcp, live.provider());
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    try ziac.importer.importResource(
        std.testing.allocator,
        service,
        "projects/test-ziac-disposable/locations/europe-west1/services/api",
        &state,
        providers,
        null,
    );
    try env.state.saveResources("global-container", "smoke", &state);
    env.live_providers = providers;
    env.live_project_id = "test-ziac-disposable";

    const code = try ziac.cli.run(std.testing.allocator, &.{
        "fail-region",
        "--stack",
        "global-container",
        "--stage",
        "smoke",
        "--region",
        "europe-west1",
        "--provider",
        "gcp",
        "--allow-live",
        "--live-test",
    }, &env);

    try std.testing.expectEqual(ziac.cli.Exit.success, code);
    try std.testing.expectEqual(@as(usize, 1), live.deletes);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "Regional failure injected: europe-west1") != null);
    const persisted = fs.readFile(".ziac/state/global-container/smoke/resources.json").?;
    try std.testing.expect(std.mem.indexOf(u8, persisted, "projects/test-ziac-disposable/locations/europe-west1/services/api") != null);
    try std.testing.expect(!try env.state.hasLock("global-container", "smoke"));
}

fn findResource(graph: *const ziac.ResourceGraph, id: []const u8) ziac.ResourceNode {
    for (graph.resources.items) |node| if (std.mem.eql(u8, node.id, id)) return node;
    unreachable;
}

test "cli live test rejects a non-disposable GCP project before mutation" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);
    var live = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer live.deinit();
    var providers = ziac.provider.ProviderRegistry{};
    providers.register(.gcp, live.provider());
    env.live_providers = providers;
    env.live_project_id = "production-project";

    const code = try ziac.cli.run(std.testing.allocator, &.{
        "deploy",
        "--stack",
        "hello-global",
        "--stage",
        "dev",
        "--provider",
        "gcp",
        "--allow-live",
        "--live-test",
    }, &env);

    try std.testing.expectEqual(ziac.cli.Exit.auth_error, code);
    try std.testing.expect(std.mem.indexOf(u8, console.stderrText(), "UnsafeLiveProject") != null);
    try std.testing.expectEqual(@as(usize, 0), live.creates);
    try std.testing.expect(!try env.state.hasLock("hello-global", "dev"));
}
