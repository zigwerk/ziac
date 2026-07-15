const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const actions = ziac.gcp.data_engineering_actions;

test "data engineering actions require payload and target bound authority" {
    var harness: Harness = undefined;
    harness.init(&.{});
    defer harness.deinit();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    const runner = actions.Runner{ .client = &harness.client };
    const target = pipelineTarget();
    const payload: actions.Payload = .none;
    const digest = actions.actionDigest(.pipeline_run, target, payload);
    try std.testing.expectError(error.ActionDigestMismatch, runner.runAlloc(&context, capability(digest[0..]), .pipeline_run, target, payload, "wrong"));
    try std.testing.expectEqual(@as(usize, 0), harness.transport.requests.items.len);
}

test "data engineering execution actions use explicit Google action methods" {
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"projects/analytics-prod/locations/europe-west1/pipelines/orders\",\"state\":\"STATE_ACTIVE\"}"),
        ok("{\"job\":{\"id\":\"job-1\",\"name\":\"orders-1\"}}"),
        ok("{\"job\":{\"id\":\"job-2\",\"name\":\"flex-1\"}}"),
        ok("{\"name\":\"projects/analytics-prod/regions/europe-west1/clusters/analytics\",\"status\":{\"state\":\"RUNNING\"}}"),
        ok("{\"name\":\"projects/analytics-prod/regions/europe-west1/operations/stop\"}"),
        ok("{\"name\":\"projects/analytics-prod/regions/europe-west1/operations/workflow\"}"),
        ok("{\"name\":\"projects/analytics-prod/locations/europe-west1/repositories/analytics/compilationResults/result-1\"}"),
        ok("{\"name\":\"projects/analytics-prod/locations/europe-west1/repositories/analytics/workflowInvocations/invocation-1\",\"state\":\"RUNNING\"}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    const runner = actions.Runner{ .client = &harness.client };

    var pipeline = try run(&runner, &context, .pipeline_run, pipelineTarget(), .none);
    defer pipeline.deinit();
    var flex = try run(&runner, &context, .dataflow_flex_launch, flexTarget(), .{ .dataflow_flex = .{ .job_name = "flex-1", .container_spec_gcs_path = "gs://templates/flex.json" } });
    defer flex.deinit();
    var stopped = try run(&runner, &context, .dataproc_cluster_stop, clusterTarget(), .none);
    defer stopped.deinit();
    var workflow = try run(&runner, &context, .dataproc_workflow_instantiate, workflowTarget(), .none);
    defer workflow.deinit();
    const compilation_target = repositoryTarget();
    var compilation = try run(&runner, &context, .dataform_compilation_create, compilation_target, .{ .dataform_compilation = .{ .git_commitish = "main" } });
    defer compilation.deinit();
    var invocation = try run(&runner, &context, .dataform_workflow_invoke, compilation_target, .{ .dataform_invocation = .{ .compilation_result = compilation.result_name } });
    defer invocation.deinit();

    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[1].url, ":run"));
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[2].url, "/v1b3/projects/analytics-prod/locations/europe-west1/flexTemplates:launch"));
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[4].url, ":stop"));
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[5].url, ":instantiate"));
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[6].url, "/compilationResults"));
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[7].url, "/workflowInvocations"));
}

fn run(runner: *const actions.Runner, context: *ziac.provider.OperationContext, action: actions.Action, target: actions.Target, payload: actions.Payload) !actions.Receipt {
    const digest = actions.actionDigest(action, target, payload);
    return runner.runAlloc(context, capability(digest[0..]), action, target, payload, digest[0..]);
}
fn pipelineTarget() actions.Target {
    return makeTarget("projects/analytics-prod/locations/europe-west1/pipelines/orders");
}
fn flexTarget() actions.Target {
    return makeTarget("projects/analytics-prod/locations/europe-west1/flexTemplates/flex-1");
}
fn clusterTarget() actions.Target {
    return makeTarget("projects/analytics-prod/regions/europe-west1/clusters/analytics");
}
fn workflowTarget() actions.Target {
    return makeTarget("projects/analytics-prod/regions/europe-west1/workflowTemplates/daily-orders");
}
fn repositoryTarget() actions.Target {
    return makeTarget("projects/analytics-prod/locations/europe-west1/repositories/analytics");
}
fn makeTarget(name: []const u8) actions.Target {
    return .{ .stage = "prod", .project = "analytics-prod", .resource_name = name, .now_millis = 1_000, .started_at_millis = 900 };
}
fn capability(digest: []const u8) ziac.agent_contract.CapabilityEnvelope {
    return .{ .id = "data-action", .stages = &.{"prod"}, .projects = &.{"analytics-prod"}, .providers = &.{.gcp}, .permissions = .{ .read = true, .apply = true, .delete = true }, .budget = .{ .max_creates = 1, .max_updates = 1, .max_deletes = 1, .max_regions = 1 }, .expires_at_millis = 10_000, .approved_plan_digest = digest };
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
        self.client = ziac.gcp.client.Client.init(self.transport.client(), &self.cache, .{ .data_pipelines = "https://datapipelines.example.test", .dataflow = "https://dataflow.example.test", .dataproc = "https://dataproc.example.test", .dataform = "https://dataform.example.test" });
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
