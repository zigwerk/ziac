const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const delivery = ziac.gcp.build_delivery;
const gclient = ziac.gcp.client;

test "Cloud Build connection checkpoints operation and requires complete installation" {
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/connection-create\",\"done\":false}"),
        ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/connection-create\",\"done\":true}"),
        ok(connectionJson("COMPLETE")),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.build_delivery_provider.Handler{ .client = &harness.client, .operation_policy = .{ .poll_interval_millis = 0 } };
    var connection = try githubConnection();
    defer connection.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.create(&context, connection.node);
    defer pending.deinit();
    try std.testing.expect(!pending.completed);
    try std.testing.expectEqualStrings("projects/ziac-dev/locations/europe-west1/operations/connection-create", pending.operation_handle.?);
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[0].url, "/v2/projects/ziac-dev/locations/europe-west1/connections?connectionId=github"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "githubConfig") != null);

    context.operation_handle = pending.operation_handle;
    var read = try handler.read(&context, connection.node, null);
    defer read.deinit();
    try std.testing.expect(read == .present);
    try std.testing.expectEqualStrings("COMPLETE", outputString(read.present, "installation_state"));
}

test "Cloud Build worker pool uses exact mask and replaces immutable network" {
    const responses = [_]zstd.Http.Response{ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/pool-update\",\"done\":false}")};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.build_delivery_provider.Handler{ .client = &harness.client, .operation_policy = .{} };
    var current = try worker("e2-medium", "10.40.0.0/24");
    defer current.deinit(std.testing.allocator);
    var scaled = try worker("e2-standard-4", "10.40.0.0/24");
    defer scaled.deinit(std.testing.allocator);
    var moved = try worker("e2-standard-4", "10.50.0.0/24");
    defer moved.deinit(std.testing.allocator);
    var observed = try resultFor(current.node, "projects/ziac-dev/locations/europe-west1/workerPools/zig-builds", "etag-a");
    defer observed.deinit();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var update_diff = try ziac.gcp.build_delivery_provider.Handler.diff(&context, scaled.node, &observed);
    defer update_diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, update_diff.kind);
    var pending = try handler.update(&context, scaled.node, &observed);
    defer pending.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].url, "updateMask=annotations%2CdisplayName%2CprivatePoolV1Config.workerConfig.diskSizeGb%2CprivatePoolV1Config.workerConfig.enableNestedVirtualization%2CprivatePoolV1Config.workerConfig.machineType") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "\"etag\":\"etag-a\"") != null);

    var replace_diff = try ziac.gcp.build_delivery_provider.Handler.diff(&context, moved.node, &observed);
    defer replace_diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.replace, replace_diff.kind);
}

test "Cloud Build worker pool refresh surfaces mutable and network drift" {
    const responses = [_]zstd.Http.Response{ok(
        "{\"name\":\"projects/ziac-dev/locations/europe-west1/workerPools/zig-builds\",\"displayName\":\"remote\",\"annotations\":{},\"privatePoolV1Config\":{\"workerConfig\":{\"machineType\":\"e2-standard-8\",\"diskSizeGb\":\"200\",\"enableNestedVirtualization\":true},\"networkConfig\":{\"peeredNetwork\":\"projects/123/global/networks/build\",\"peeredNetworkIpRange\":\"10.50.0.0/24\",\"egressOption\":\"NO_PUBLIC_EGRESS\"}},\"state\":\"RUNNING\",\"etag\":\"etag-b\"}",
    )};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.build_delivery_provider.Handler{ .client = &harness.client };
    var desired = try worker("e2-standard-4", "10.40.0.0/24");
    defer desired.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var present = try handler.read(&context, desired.node, null);
    defer present.deinit();
    var diff = try ziac.gcp.build_delivery_provider.Handler.diff(&context, desired.node, &present.present);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.replace, diff.kind);
    try std.testing.expectEqualStrings("etag-b", outputString(present.present, "etag"));
}

test "Cloud Build repository and trigger use canonical regional resources" {
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/repository-create\",\"done\":false}"),
        ok(triggerJson()),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.build_delivery_provider.Handler{ .client = &harness.client, .operation_policy = .{} };
    var repository = try sourceRepository();
    defer repository.deinit(std.testing.allocator);
    var trigger = try repositoryTrigger(ziac.PublicOutput([]const u8).known("projects/ziac-dev/locations/europe-west1/connections/github/repositories/api"));
    defer trigger.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    context.state = null;

    var repository_pending = try handler.create(&context, repository.node);
    defer repository_pending.deinit();
    try std.testing.expect(!repository_pending.completed);
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[0].url, "/v2/projects/ziac-dev/locations/europe-west1/connections/github/repositories?repositoryId=api"));

    var trigger_created = try handler.create(&context, trigger.node);
    defer trigger_created.deinit();
    try std.testing.expect(trigger_created.completed);
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[1].url, "/v1/projects/ziac-dev/locations/europe-west1/triggers"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "repositoryEventConfig") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "platform/cloudbuild.yaml") != null);
}

test "Artifact singleton settings use exact masks and reject finalized redirection reversal" {
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"projects/ziac-dev/projectSettings\",\"legacyRedirectionState\":\"REDIRECTION_FROM_GCR_IO_PARTIAL_AND_COPYING\",\"pullPercent\":25}"),
        ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/vpcscConfig\",\"vpcscPolicy\":\"DENY\"}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.build_delivery_provider.Handler{ .client = &harness.client };
    var settings = try delivery.ArtifactProjectSettings.build(std.testing.allocator, config(), .{ .redirection = .partial_and_copying, .pull_percent = 25 });
    defer settings.deinit(std.testing.allocator);
    var vpcsc = try delivery.ArtifactVpcscConfig.build(std.testing.allocator, config(), .{ .location = "europe-west1", .policy = .deny });
    defer vpcsc.deinit(std.testing.allocator);
    var current_settings = try resultFor(settings.node, "projects/ziac-dev/projectSettings", "");
    defer current_settings.deinit();
    var current_vpcsc = try resultFor(vpcsc.node, "projects/ziac-dev/locations/europe-west1/vpcscConfig", "");
    defer current_vpcsc.deinit();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var updated_settings = try handler.update(&context, settings.node, &current_settings);
    defer updated_settings.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].url, "updateMask=legacyRedirectionState%2CpullPercent") != null);
    var updated_vpcsc = try handler.update(&context, vpcsc.node, &current_vpcsc);
    defer updated_vpcsc.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].url, "updateMask=vpcscPolicy") != null);

    var finalized_inputs = try settings.node.inputs.clone(std.testing.allocator);
    defer finalized_inputs.deinit(std.testing.allocator);
    const finalized_fields: []ziac.value.Field = @constCast(finalized_inputs.object);
    for (finalized_fields) |*field| if (std.mem.eql(u8, field.name, "redirection")) {
        field.value.deinit(std.testing.allocator);
        field.value = .{ .string = try std.testing.allocator.dupe(u8, "REDIRECTION_FROM_GCR_IO_FINALIZED") };
    };
    var finalized = try ziac.provider.ResourceResult.init(std.testing.allocator, "projects/ziac-dev/projectSettings", finalized_inputs, &.{}, null);
    defer finalized.deinit();
    try std.testing.expectError(error.InvalidConfiguration, ziac.gcp.build_delivery_provider.Handler.diff(&context, settings.node, &finalized));
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
}

fn githubConnection() !delivery.Connection {
    return delivery.Connection.build(std.testing.allocator, config(), .{
        .name = "github",
        .location = "europe-west1",
        .config = .{ .github = .{ .oauth_token_secret_version = "projects/ziac-dev/secrets/github/versions/1", .app_installation_id = "123" } },
    });
}

fn sourceRepository() !delivery.Repository {
    return delivery.Repository.build(std.testing.allocator, config(), .{
        .name = "api",
        .location = "europe-west1",
        .connection_name = "github",
        .connection = ziac.PublicOutput([]const u8).known("projects/ziac-dev/locations/europe-west1/connections/github"),
        .remote_uri = "https://github.com/acme/api.git",
    });
}

fn repositoryTrigger(repository: ziac.PublicOutput([]const u8)) !delivery.Trigger {
    return delivery.Trigger.build(std.testing.allocator, config(), .{
        .name = "api-main",
        .location = "europe-west1",
        .repository = repository,
        .event = .{ .push = .{ .branch = "^main$" } },
        .filename = "platform/cloudbuild.yaml",
    });
}

fn worker(machine: []const u8, range: []const u8) !delivery.WorkerPool {
    return delivery.WorkerPool.build(std.testing.allocator, config(), .{
        .name = "zig-builds",
        .location = "europe-west1",
        .machine_type = machine,
        .network = .{ .peered = .{ .network = "projects/123/global/networks/build", .ip_range = range } },
    });
}

fn resultFor(node: ziac.resource.ResourceNode, physical: []const u8, etag: []const u8) !ziac.provider.ResourceResult {
    const outputs = if (etag.len == 0)
        &[_]ziac.state.StateOutput{}
    else
        &[_]ziac.state.StateOutput{.{ .name = "etag", .value = .{ .string = etag } }};
    return ziac.provider.ResourceResult.init(std.testing.allocator, physical, node.inputs, outputs, null);
}

fn outputString(result: ziac.provider.ResourceResult, name: []const u8) []const u8 {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name)) return item.value.string;
    unreachable;
}

const Harness = struct {
    source: FixedTokenSource,
    cache: auth.TokenCache,
    transport: @import("gcp_client_test.zig").RecordingTransport,
    client: gclient.Client,

    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.source = .{};
        self.cache = auth.TokenCache.init(self.source.tokenSource(), 300);
        self.transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{
            .cloud_build = "https://cloudbuild.example.test",
            .artifact_registry = "https://artifactregistry.example.test",
        });
    }

    fn deinit(self: *Harness) void {
        self.transport.deinit();
        self.cache.deinit(std.testing.allocator);
    }
};

const FixedTokenSource = struct {
    fn tokenSource(self: *FixedTokenSource) auth.TokenSource {
        return .{ .ptr = self, .fetchFn = fetch };
    }
    fn fetch(_: *anyopaque, allocator: std.mem.Allocator, now: u64) auth.AuthError!auth.AccessToken {
        return auth.AccessToken.initOwned(allocator, .{ .access_token = "token", .token_type = "Bearer", .expires_at_seconds = now + 3600 });
    }
};

fn connectionJson(state: []const u8) []const u8 {
    return if (std.mem.eql(u8, state, "COMPLETE"))
        "{\"name\":\"projects/ziac-dev/locations/europe-west1/connections/github\",\"githubConfig\":{\"appInstallationId\":\"123\"},\"disabled\":false,\"annotations\":{},\"installationState\":{\"stage\":\"COMPLETE\"},\"reconciling\":false,\"etag\":\"etag-a\"}"
    else
        unreachable;
}

fn triggerJson() []const u8 {
    return "{\"resourceName\":\"projects/ziac-dev/locations/europe-west1/triggers/trigger-123\",\"name\":\"api-main\",\"description\":\"\",\"filename\":\"platform/cloudbuild.yaml\",\"disabled\":false,\"serviceAccount\":\"\",\"approvalConfig\":{\"approvalRequired\":false},\"substitutions\":{},\"includedFiles\":[],\"ignoredFiles\":[],\"repositoryEventConfig\":{\"repository\":\"projects/ziac-dev/locations/europe-west1/connections/github/repositories/api\",\"push\":{\"branch\":\"^main$\"}}}";
}

fn ok(body: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = @constCast(body) };
}
