const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const deploy = ziac.gcp.cloud_deploy;
const gclient = ziac.gcp.client;

test "Cloud Deploy target create checkpoints and resumes the Google operation" {
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/target-create\",\"done\":false}"),
        ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/target-create\",\"done\":true}"),
        ok(targetJson("projects/ziac-dev/locations/us-central1", "etag-a")),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.cloud_deploy_provider.Handler{ .client = &harness.client, .operation_policy = .{ .poll_interval_millis = 0 } };
    var target = try cloudRunTarget("us", "us-central1", false);
    defer target.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.create(&context, target.node);
    defer pending.deinit();
    try std.testing.expect(!pending.completed);
    try std.testing.expectEqualStrings("projects/ziac-dev/locations/europe-west1/operations/target-create", pending.operation_handle.?);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].url, "/v1/projects/ziac-dev/locations/europe-west1/targets?targetId=us&requestId=") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "\"run\":{\"location\":\"projects/ziac-dev/locations/us-central1\"}") != null);

    context.operation_handle = pending.operation_handle;
    var read = try handler.read(&context, target.node, null);
    defer read.deinit();
    try std.testing.expect(read == .present);
    try std.testing.expectEqualStrings("etag-a", outputString(read.present, "etag"));
}

test "Cloud Deploy pipeline refresh detects canary drift and patches exact fields with etag" {
    const remote =
        "{\"name\":\"projects/ziac-dev/locations/europe-west1/deliveryPipelines/api\",\"description\":\"old\",\"annotations\":{},\"labels\":{},\"serialPipeline\":{\"stages\":[{\"targetId\":\"us\",\"profiles\":[],\"deployParameters\":[],\"strategy\":{\"canary\":{\"canaryDeployment\":{\"percentages\":[10,25],\"verify\":true}}}}]},\"suspended\":false,\"condition\":{\"pipelineReadyCondition\":{\"status\":true}},\"etag\":\"etag-live\"}";
    const responses = [_]zstd.Http.Response{
        ok(remote),
        ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/pipeline-update\",\"done\":false}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.cloud_deploy_provider.Handler{ .client = &harness.client };
    var pipeline = try canaryPipeline("new", &.{ 10, 50 });
    defer pipeline.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var observed = try handler.read(&context, pipeline.node, null);
    defer observed.deinit();
    var diff = try ziac.gcp.cloud_deploy_provider.Handler.diff(&context, pipeline.node, &observed.present);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, diff.kind);

    var pending = try handler.update(&context, pipeline.node, &observed.present);
    defer pending.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].url, "updateMask=description%2CserialPipeline") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"etag\":\"etag-live\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"percentages\":[10,50]") != null);
}

test "Cloud Deploy imports canonical identities and replaces a changed target runtime" {
    const responses = [_]zstd.Http.Response{
        ok(targetJson("projects/ziac-dev/locations/us-central1", "etag-a")),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.cloud_deploy_provider.Handler{ .client = &harness.client };
    var target = try cloudRunTarget("us", "us-central1", false);
    defer target.deinit(std.testing.allocator);
    var moved = try cloudRunTarget("us", "europe-west1", false);
    defer moved.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var imported = try handler.importResource(&context, target.node, "projects/ziac-dev/locations/europe-west1/targets/us");
    defer imported.deinit();
    var noop = try ziac.gcp.cloud_deploy_provider.Handler.diff(&context, target.node, &imported);
    defer noop.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.noop, noop.kind);
    var replace = try ziac.gcp.cloud_deploy_provider.Handler.diff(&context, moved.node, &imported);
    defer replace.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.replace, replace.kind);
    try std.testing.expectError(error.InvalidConfiguration, handler.importResource(&context, target.node, "targets/us"));
}

test "Cloud Deploy delete refreshes and sends the current etag" {
    const physical = "projects/ziac-dev/locations/europe-west1/targets/us";
    const responses = [_]zstd.Http.Response{
        ok(targetJson("projects/ziac-dev/locations/us-central1", "etag-delete")),
        ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/target-delete\",\"done\":false}"),
        ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/target-delete\",\"done\":true}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.cloud_deploy_provider.Handler{ .client = &harness.client, .operation_policy = .{ .poll_interval_millis = 0 } };
    var target = try cloudRunTarget("us", "us-central1", false);
    defer target.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    try handler.delete(&context, target.node, physical);

    try std.testing.expectEqualStrings("GET", harness.transport.requests.items[0].method);
    try std.testing.expectEqualStrings("DELETE", harness.transport.requests.items[1].method);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].url, "etag=etag-delete") != null);
}

fn config() ziac.gcp.ProviderConfig {
    return .{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
        .service_regions = &.{ "europe-west1", "us-central1" },
        .network_tier = .premium,
    };
}

fn cloudRunTarget(name: []const u8, region: []const u8, approval: bool) !deploy.Target {
    return deploy.Target.build(std.testing.allocator, config(), .{
        .name = name,
        .location = "europe-west1",
        .runtime = .{ .cloud_run = .{ .location = region } },
        .require_approval = approval,
    });
}

fn canaryPipeline(description: []const u8, percentages: []const u8) !deploy.DeliveryPipeline {
    return deploy.DeliveryPipeline.build(std.testing.allocator, config(), .{
        .name = "api",
        .location = "europe-west1",
        .description = description,
        .stages = &.{.{
            .target = ziac.PublicOutput([]const u8).known("projects/ziac-dev/locations/europe-west1/targets/us"),
            .strategy = .{ .canary = .{ .percentages = percentages, .verify = true } },
        }},
    });
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
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{ .cloud_deploy = "https://clouddeploy.example.test" });
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

fn targetJson(location: []const u8, etag: []const u8) []const u8 {
    if (std.mem.eql(u8, location, "projects/ziac-dev/locations/us-central1") and std.mem.eql(u8, etag, "etag-a"))
        return "{\"name\":\"projects/ziac-dev/locations/europe-west1/targets/us\",\"description\":\"\",\"annotations\":{},\"labels\":{},\"deployParameters\":{},\"executionConfigs\":[],\"requireApproval\":false,\"run\":{\"location\":\"projects/ziac-dev/locations/us-central1\"},\"etag\":\"etag-a\"}";
    if (std.mem.eql(u8, location, "projects/ziac-dev/locations/us-central1") and std.mem.eql(u8, etag, "etag-delete"))
        return "{\"name\":\"projects/ziac-dev/locations/europe-west1/targets/us\",\"description\":\"\",\"annotations\":{},\"labels\":{},\"deployParameters\":{},\"executionConfigs\":[],\"requireApproval\":false,\"run\":{\"location\":\"projects/ziac-dev/locations/us-central1\"},\"etag\":\"etag-delete\"}";
    unreachable;
}

fn outputString(result: ziac.provider.ResourceResult, name: []const u8) []const u8 {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name)) return item.value.string;
    unreachable;
}

fn ok(body: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = body };
}
