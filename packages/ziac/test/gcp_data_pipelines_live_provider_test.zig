const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

test "Data Pipeline reconciliation uses CRUD masks and never run or stop actions" {
    const current = "{\"name\":\"projects/analytics-prod/locations/europe-west1/pipelines/daily-orders\",\"displayName\":\"old_name\",\"type\":\"PIPELINE_TYPE_BATCH\",\"state\":\"STATE_ACTIVE\",\"workload\":{\"dataflowFlexTemplateRequest\":{\"launchParameter\":{\"containerSpecGcsPath\":\"gs://templates/spec.json\"}}}}";
    const desired = "{\"name\":\"projects/analytics-prod/locations/europe-west1/pipelines/daily-orders\",\"displayName\":\"daily_orders\",\"type\":\"PIPELINE_TYPE_BATCH\",\"state\":\"STATE_ACTIVE\",\"workload\":{\"dataflowFlexTemplateRequest\":{\"launchParameter\":{\"containerSpecGcsPath\":\"gs://templates/spec.json\"}}}}";
    const responses = [_]zstd.Http.Response{ ok(desired), ok(current), ok(desired), ok("{}") };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.data_pipelines_provider.Handler{ .client = &harness.client };
    var pipeline = try buildPipeline(.delete);
    defer pipeline.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try handler.create(&context, pipeline.node);
    defer created.deinit();
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[0].url, "/v1/projects/analytics-prod/locations/europe-west1/pipelines"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "\"dataflowFlexTemplateRequest\"") != null);
    var observed = try handler.read(&context, pipeline.node, created.physical_id);
    defer observed.deinit();
    var updated = try handler.update(&context, pipeline.node, &observed.present);
    defer updated.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[2].url, "updateMask=displayName") != null);
    try std.testing.expectError(error.DestructiveConfirmationRequired, handler.delete(&context, pipeline.node, updated.physical_id));
    context.destructive_confirmation = true;
    try handler.delete(&context, pipeline.node, updated.physical_id);
    for (harness.transport.requests.items) |request| {
        try std.testing.expect(std.mem.indexOf(u8, request.url, ":run") == null);
        try std.testing.expect(std.mem.indexOf(u8, request.url, ":stop") == null);
    }
}

fn buildPipeline(removal_policy: ziac.gcp.data_pipelines.RemovalPolicy) !ziac.gcp.data_pipelines.Pipeline {
    return ziac.gcp.data_pipelines.Pipeline.build(std.testing.allocator, config(), .{
        .name = "daily-orders",
        .location = "europe-west1",
        .display_name = "daily_orders",
        .pipeline_type = .batch,
        .workload = .{ .flex_template = .{ .container_spec_gcs_path = "gs://templates/spec.json" } },
        .removal_policy = removal_policy,
    });
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "analytics-prod", .primary_region = "europe-west1" };
}

const Harness = struct {
    source: FixedTokenSource,
    cache: ziac.gcp.auth.TokenCache,
    transport: @import("gcp_client_test.zig").RecordingTransport,
    client: ziac.gcp.client.Client,
    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.source = .{};
        self.cache = ziac.gcp.auth.TokenCache.init(self.source.tokenSource(), 300);
        self.transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = ziac.gcp.client.Client.init(self.transport.client(), &self.cache, .{ .data_pipelines = "https://datapipelines.example.test" });
    }
    fn deinit(self: *Harness) void {
        self.transport.deinit();
        self.cache.deinit(std.testing.allocator);
    }
};
const FixedTokenSource = struct {
    fn tokenSource(self: *FixedTokenSource) ziac.gcp.auth.TokenSource {
        return .{ .ptr = self, .fetchFn = fetch };
    }
    fn fetch(_: *anyopaque, allocator: std.mem.Allocator, now: u64) ziac.gcp.auth.AuthError!ziac.gcp.auth.AccessToken {
        return ziac.gcp.auth.AccessToken.initOwned(allocator, .{ .access_token = "token", .token_type = "Bearer", .expires_at_seconds = now + 3600 });
    }
};
fn ok(body: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = body };
}
