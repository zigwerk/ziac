const std = @import("std");
const ziac = @import("ziac");

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
    };
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

test "cli destroy marks resource deleted" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var local: ziac.state_backend.Local = undefined;
    var env = testEnv(&local, &fs, &console);

    _ = try ziac.cli.run(std.testing.allocator, &.{ "deploy", "--stack", "hello-global", "--stage", "dev" }, &env);
    console.stdout.clearRetainingCapacity();
    const code = try ziac.cli.run(std.testing.allocator, &.{ "destroy", "--stack", "hello-global", "--stage", "dev" }, &env);

    try std.testing.expectEqual(@as(u8, 0), code);
    const resources = fs.readFile(".ziac/state/hello-global/dev/resources.json").?;
    try std.testing.expect(std.mem.indexOf(u8, resources, "\"status\":\"deleted\"") != null);
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
        &.{ "plan", "--stack", "hello-global", "--stage", "dev", "--json" },
        &env,
    );

    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "\"schema\":\"ziac.command.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "\"command\":\"plan\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "\"create\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "Plan:") == null);
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
