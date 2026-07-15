const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const actions = ziac.gcp.vertex_ai_actions;

test "Vertex AI actions reject an unbound digest before network mutation" {
    var harness: Harness = undefined;
    harness.init(&.{});
    defer harness.deinit();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    const runner = actions.Runner{ .client = &harness.client };
    const target = makeTarget("projects/ml-prod/locations/europe-west4/endpoints/orders-online");
    const payload: actions.Payload = .{ .model_deployment = modelDeployment() };
    const digest = actions.actionDigest(.model_deploy, target, payload);
    try std.testing.expectError(error.ActionDigestMismatch, runner.runAlloc(&context, capability(digest[0..]), .model_deploy, target, payload, "wrong"));
    try std.testing.expectEqual(@as(usize, 0), harness.transport.requests.items.len);
}

test "Vertex AI actions use regional explicit mutation methods" {
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"projects/ml-prod/locations/europe-west4/operations/deploy-model\"}"),
        ok("{\"name\":\"projects/ml-prod/locations/europe-west4/operations/deploy-index\"}"),
        ok("{\"name\":\"projects/ml-prod/locations/europe-west4/pipelineJobs/train-42\",\"state\":\"PIPELINE_STATE_PENDING\"}"),
        ok("{}"),
        ok("{\"name\":\"projects/ml-prod/locations/europe-west4/featureOnlineStores/customer-serving/featureViews/customer-overview/featureViewSyncs/1\"}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    const runner = actions.Runner{ .client = &harness.client };

    var model = try run(&runner, &context, .model_deploy, makeTarget("projects/ml-prod/locations/europe-west4/endpoints/orders-online"), .{ .model_deployment = modelDeployment() });
    defer model.deinit();
    var index = try run(&runner, &context, .index_deploy, makeTarget("projects/ml-prod/locations/europe-west4/indexEndpoints/products"), .{ .index_deployment = .{ .deployed_index_id = "products-v2", .display_name = "Products v2", .index = "projects/ml-prod/locations/europe-west4/indexes/987654" } });
    defer index.deinit();
    var pipeline = try run(&runner, &context, .pipeline_submit, makeTarget("projects/ml-prod/locations/europe-west4"), .{ .pipeline_job = .{ .display_name = "Train orders", .template_uri = "https://europe-west4-kfp.pkg.dev/ml-prod/pipelines/train-orders/sha256:0123456789abcdef" } });
    defer pipeline.deinit();
    var cancelled = try run(&runner, &context, .pipeline_cancel, makeTarget("projects/ml-prod/locations/europe-west4/pipelineJobs/train-42"), .none);
    defer cancelled.deinit();
    var synced = try run(&runner, &context, .feature_view_sync, makeTarget("projects/ml-prod/locations/europe-west4/featureOnlineStores/customer-serving/featureViews/customer-overview"), .none);
    defer synced.deinit();

    for (harness.transport.requests.items) |request| try std.testing.expect(std.mem.startsWith(u8, request.url, "https://europe-west4-aiplatform.example.test/v1/"));
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[0].url, ":deployModel"));
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[1].url, ":deployIndex"));
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[2].url, "/pipelineJobs"));
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[3].url, ":cancel"));
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[4].url, ":sync"));
}

fn modelDeployment() actions.ModelDeployment {
    return .{ .deployed_model_id = "orders-v3", .display_name = "Orders v3", .model = "projects/ml-prod/locations/europe-west4/models/123456", .machine_type = "n1-standard-4", .min_replicas = 1, .max_replicas = 3 };
}
fn run(runner: *const actions.Runner, context: *ziac.provider.OperationContext, action: actions.Action, target: actions.Target, payload: actions.Payload) !actions.Receipt {
    const digest = actions.actionDigest(action, target, payload);
    return runner.runAlloc(context, capability(digest[0..]), action, target, payload, digest[0..]);
}
fn makeTarget(name: []const u8) actions.Target {
    return .{ .stage = "prod", .project = "ml-prod", .resource_name = name, .now_millis = 1_000, .started_at_millis = 900 };
}
fn capability(digest: []const u8) ziac.agent_contract.CapabilityEnvelope {
    return .{ .id = "vertex-action", .stages = &.{"prod"}, .projects = &.{"ml-prod"}, .providers = &.{.gcp}, .permissions = .{ .read = true, .apply = true, .delete = true }, .budget = .{ .max_creates = 1, .max_updates = 1, .max_deletes = 1, .max_regions = 1 }, .expires_at_millis = 10_000, .approved_plan_digest = digest };
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
        self.client = ziac.gcp.client.Client.init(self.transport.client(), &self.cache, .{ .vertex_ai = "https://aiplatform.example.test" });
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
