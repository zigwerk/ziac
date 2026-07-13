const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;
const actions = ziac.gcp.run_actions;

test "Cloud Run job actions require an exact approved action digest" {
    const responses = [_]zstd.Http.Response{};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var runner = actions.Runner{ .client = &harness.client, .operation_policy = .{ .poll_interval_millis = 0 } };
    const target = actionTarget("projects/ziac-dev/locations/europe-west1/jobs/nightly");
    const digest = actions.actionDigest(.run, target);
    var envelope = capability(digest[0..]);

    try std.testing.expectError(error.ActionDigestMismatch, runner.runAlloc(&context, envelope, target, "wrong"));
    envelope.permissions.apply = false;
    try std.testing.expectError(error.ActionDenied, runner.runAlloc(&context, envelope, target, digest[0..]));
    try std.testing.expectEqual(@as(usize, 0), harness.transport.requests.items.len);
}

test "Cloud Run job run inspect and cancel actions emit governed execution receipts" {
    const job = "{\"name\":\"projects/ziac-dev/locations/europe-west1/jobs/nightly\",\"etag\":\"job-etag\"}";
    const execution = "{\"name\":\"projects/ziac-dev/locations/europe-west1/jobs/nightly/executions/nightly-42\",\"uid\":\"execution-uid\",\"job\":\"projects/ziac-dev/locations/europe-west1/jobs/nightly\",\"taskCount\":4,\"runningCount\":0,\"succeededCount\":4,\"failedCount\":0,\"cancelledCount\":0,\"retriedCount\":1,\"logUri\":\"https://console.cloud.google.com/logs/query\",\"terminalCondition\":{\"state\":\"CONDITION_SUCCEEDED\"},\"reconciling\":false,\"etag\":\"execution-etag\"}";
    const run_operation = "{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/run-nightly\",\"done\":false}";
    const run_done = "{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/run-nightly\",\"done\":true,\"response\":" ++ execution ++ "}";
    const cancel_operation = "{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/cancel-nightly\",\"done\":false}";
    const cancelled_execution = "{\"name\":\"projects/ziac-dev/locations/europe-west1/jobs/nightly/executions/nightly-42\",\"uid\":\"execution-uid\",\"job\":\"projects/ziac-dev/locations/europe-west1/jobs/nightly\",\"taskCount\":4,\"runningCount\":0,\"succeededCount\":3,\"failedCount\":0,\"cancelledCount\":1,\"retriedCount\":1,\"logUri\":\"https://console.cloud.google.com/logs/query\",\"terminalCondition\":{\"state\":\"CONDITION_SUCCEEDED\"},\"reconciling\":false,\"etag\":\"execution-etag-2\"}";
    const cancel_done = "{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/cancel-nightly\",\"done\":true,\"response\":" ++ cancelled_execution ++ "}";
    const responses = [_]zstd.Http.Response{
        ok(job), ok(run_operation), ok(run_done), ok(execution), ok(execution), ok(cancel_operation), ok(cancel_done),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var runner = actions.Runner{ .client = &harness.client, .operation_policy = .{ .poll_interval_millis = 0 } };
    const job_target = actionTarget("projects/ziac-dev/locations/europe-west1/jobs/nightly");
    const run_digest = actions.actionDigest(.run, job_target);
    var run_receipt = try runner.runAlloc(&context, capability(run_digest[0..]), job_target, run_digest[0..]);
    defer run_receipt.deinit();

    try std.testing.expectEqual(actions.Status.succeeded, run_receipt.status);
    try std.testing.expectEqual(@as(i64, 4), run_receipt.succeeded_count);
    try std.testing.expectEqualStrings("projects/ziac-dev/locations/europe-west1/jobs/nightly/executions/nightly-42", run_receipt.execution_name);
    const execution_target = actionTarget(run_receipt.execution_name);
    var inspect_receipt = try runner.inspectAlloc(&context, capability(null), execution_target);
    defer inspect_receipt.deinit();
    try std.testing.expectEqual(actions.Status.succeeded, inspect_receipt.status);

    const cancel_digest = actions.actionDigest(.cancel, execution_target);
    var cancel_receipt = try runner.cancelAlloc(&context, capability(cancel_digest[0..]), execution_target, cancel_digest[0..]);
    defer cancel_receipt.deinit();
    try std.testing.expectEqual(actions.Status.cancelled, cancel_receipt.status);
    try std.testing.expectEqual(@as(i64, 1), cancel_receipt.cancelled_count);

    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].url, ":run?validateOnly=false&etag=job-etag") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[5].url, ":cancel?validateOnly=false&etag=execution-etag") != null);
}

test "Cloud Run job actions surface failed executions etag conflicts and bounded timeouts" {
    {
        const failed_execution = "{\"name\":\"projects/ziac-dev/locations/europe-west1/jobs/nightly/executions/nightly-42\",\"taskCount\":4,\"runningCount\":0,\"succeededCount\":3,\"failedCount\":1,\"cancelledCount\":0,\"reconciling\":false,\"etag\":\"execution-etag\"}";
        const responses = [_]zstd.Http.Response{ok(failed_execution)};
        var harness: Harness = undefined;
        harness.init(&responses);
        defer harness.deinit();
        var context = ziac.provider.OperationContext.init(std.testing.allocator);
        const runner = actions.Runner{ .client = &harness.client, .operation_policy = .{ .poll_interval_millis = 0 } };
        var receipt = try runner.inspectAlloc(&context, capability(null), actionTarget("projects/ziac-dev/locations/europe-west1/jobs/nightly/executions/nightly-42"));
        defer receipt.deinit();
        try std.testing.expectEqual(actions.Status.failed, receipt.status);
        try std.testing.expectEqual(@as(i64, 1), receipt.failed_count);
    }
    {
        const responses = [_]zstd.Http.Response{ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/jobs/nightly\"}")};
        var harness: Harness = undefined;
        harness.init(&responses);
        defer harness.deinit();
        var context = ziac.provider.OperationContext.init(std.testing.allocator);
        const runner = actions.Runner{ .client = &harness.client, .operation_policy = .{ .poll_interval_millis = 0 } };
        const target = actionTarget("projects/ziac-dev/locations/europe-west1/jobs/nightly");
        const digest = actions.actionDigest(.run, target);
        try std.testing.expectError(error.Conflict, runner.runAlloc(&context, capability(digest[0..]), target, digest[0..]));
        try std.testing.expectEqual(@as(usize, 1), harness.transport.requests.items.len);
    }
    {
        const responses = [_]zstd.Http.Response{
            ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/jobs/nightly\",\"etag\":\"job-etag\"}"),
            ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/run-nightly\",\"done\":false}"),
        };
        var harness: Harness = undefined;
        harness.init(&responses);
        defer harness.deinit();
        var context = ziac.provider.OperationContext.init(std.testing.allocator);
        context.deadline_millis = 1;
        const runner = actions.Runner{ .client = &harness.client, .operation_policy = .{ .poll_interval_millis = 0 } };
        const target = actionTarget("projects/ziac-dev/locations/europe-west1/jobs/nightly");
        const digest = actions.actionDigest(.run, target);
        try std.testing.expectError(error.ProviderTimeout, runner.runAlloc(&context, capability(digest[0..]), target, digest[0..]));
    }
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
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{ .run = "https://run.example.test" });
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

fn actionTarget(resource_name: []const u8) actions.Target {
    return .{ .stage = "dev", .project = "ziac-dev", .resource_name = resource_name, .now_millis = 1_000, .started_at_millis = 900 };
}

fn capability(approved_digest: ?[]const u8) ziac.agent_contract.CapabilityEnvelope {
    return .{
        .id = "run-actions",
        .stages = &.{"dev"},
        .projects = &.{"ziac-dev"},
        .providers = &.{.gcp},
        .permissions = .{ .read = true, .apply = true, .delete = true },
        .budget = .{ .max_updates = 1, .max_deletes = 1, .max_regions = 1 },
        .expires_at_millis = 10_000,
        .approved_plan_digest = approved_digest,
    };
}

fn ok(body: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = body };
}
