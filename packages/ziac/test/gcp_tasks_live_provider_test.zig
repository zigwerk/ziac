const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;

test "live Cloud Tasks provider creates reads updates imports and deletes a queue" {
    const queue_json = "{\"name\":\"projects/ziac-dev/locations/europe-west1/queues/invoice-worker\",\"httpTarget\":{\"uriOverride\":{\"scheme\":\"HTTPS\",\"host\":\"invoice-worker.example.run.app\",\"pathOverride\":{\"path\":\"/tasks/invoice\"},\"uriOverrideEnforceMode\":\"ALWAYS\"},\"httpMethod\":\"POST\",\"headerOverrides\":[{\"header\":{\"key\":\"content-type\",\"value\":\"application/json\"}}],\"oidcToken\":{\"serviceAccountEmail\":\"invoice-tasks@ziac-dev.iam.gserviceaccount.com\",\"audience\":\"https://invoice-worker.example.run.app\"}},\"rateLimits\":{\"maxDispatchesPerSecond\":12.5,\"maxBurstSize\":13,\"maxConcurrentDispatches\":24},\"retryConfig\":{\"maxAttempts\":8,\"maxRetryDuration\":\"3600s\",\"minBackoff\":\"5s\",\"maxBackoff\":\"300s\",\"maxDoublings\":5},\"state\":\"RUNNING\",\"stackdriverLoggingConfig\":{\"samplingRatio\":0.25}}";
    const changed_json = "{\"name\":\"projects/ziac-dev/locations/europe-west1/queues/invoice-worker\",\"rateLimits\":{\"maxDispatchesPerSecond\":25,\"maxConcurrentDispatches\":50},\"retryConfig\":{\"maxAttempts\":8,\"maxRetryDuration\":\"3600s\",\"minBackoff\":\"5s\",\"maxBackoff\":\"300s\",\"maxDoublings\":5},\"state\":\"RUNNING\",\"stackdriverLoggingConfig\":{\"samplingRatio\":0.25}}";
    const responses = [_]zstd.Http.Response{
        notFound(), ok(queue_json), ok(queue_json), ok(changed_json), ok(changed_json), .{ .status = 200, .body = "{}" },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var queue = try buildQueue(12.5, 24);
    defer queue.deinit(std.testing.allocator);
    var changed = try buildQueue(25, 50);
    defer changed.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var absent = try live.readWithContext(&context, queue.node);
    defer absent.deinit();
    var created = try live.createWithContext(&context, queue.node);
    defer created.deinit();
    var read = try live.readWithContext(&context, queue.node);
    defer read.deinit();
    var stable = try live.diffWithContext(&context, queue.node, &read.present);
    defer stable.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.noop, stable.kind);
    var diff = try live.diffWithContext(&context, changed.node, &read.present);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, diff.kind);
    var updated = try live.updateWithContext(&context, changed.node, &read.present);
    defer updated.deinit();
    var imported = try live.importWithContext(&context, changed.node, updated.physical_id);
    defer imported.deinit();
    try live.deleteWithContext(&context, changed.node, imported.physical_id);

    try std.testing.expectEqualStrings("POST", harness.transport.requests.items[1].method);
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[1].url, "/v2/projects/ziac-dev/locations/europe-west1/queues"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"oidcToken\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].url, "updateMask=httpTarget,rateLimits,retryConfig,stackdriverLoggingConfig") != null);
    try std.testing.expectEqualStrings("DELETE", harness.transport.requests.items[5].method);
}

test "live Cloud Tasks reads normalize remote queue drift" {
    const remote = "{\"name\":\"projects/ziac-dev/locations/europe-west1/queues/invoice-worker\",\"rateLimits\":{\"maxDispatchesPerSecond\":25,\"maxConcurrentDispatches\":50},\"retryConfig\":{\"maxAttempts\":8,\"maxRetryDuration\":\"3600s\",\"minBackoff\":\"5s\",\"maxBackoff\":\"300s\",\"maxDoublings\":5},\"state\":\"RUNNING\",\"stackdriverLoggingConfig\":{\"samplingRatio\":0.25}}";
    const responses = [_]zstd.Http.Response{ok(remote)};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var desired = try buildQueue(12.5, 24);
    defer desired.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var read = try live.readWithContext(&context, desired.node);
    defer read.deinit();
    try std.testing.expectEqualStrings("25", inputString(read.present.observed_inputs, "max_dispatches_per_second"));
    var diff = try live.diffWithContext(&context, desired.node, &read.present);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, diff.kind);
}

test "live Cloud Tasks queue IAM member mutates one member without replacing a policy" {
    const empty_policy = "{\"version\":3,\"etag\":\"etag-1\",\"bindings\":[{\"role\":\"roles/viewer\",\"members\":[\"user:viewer@example.com\"]}]}";
    const responses = [_]zstd.Http.Response{ ok(empty_policy), ok("{}"), ok("{\"version\":3,\"bindings\":[{\"role\":\"roles/cloudtasks.enqueuer\",\"members\":[\"serviceAccount:api@ziac-dev.iam.gserviceaccount.com\"]}]}"), ok("{\"version\":3,\"bindings\":[{\"role\":\"roles/cloudtasks.enqueuer\",\"members\":[\"serviceAccount:api@ziac-dev.iam.gserviceaccount.com\"]}]}"), ok("{}") };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var member = try ziac.gcp.tasks.QueueIamMember.build(std.testing.allocator, .{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    }, .{
        .name = "invoice-enqueuer",
        .queue = ziac.PublicOutput([]const u8).known("projects/ziac-dev/locations/europe-west1/queues/invoice-worker"),
        .role = "roles/cloudtasks.enqueuer",
        .member = "serviceAccount:api@ziac-dev.iam.gserviceaccount.com",
    });
    defer member.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var created = try live.createWithContext(&context, member.node);
    defer created.deinit();
    var read = try live.readWithContext(&context, member.node);
    defer read.deinit();
    try std.testing.expect(read == .present);
    try live.deleteWithContext(&context, member.node, created.physical_id);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "roles/viewer") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "roles/cloudtasks.enqueuer") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"etag\":\"etag-1\"") != null);
}

const Harness = struct {
    source: FixedTokenSource,
    cache: auth.TokenCache,
    transport: @import("gcp_client_test.zig").RecordingTransport,
    client: gclient.Client,
    live: ziac.gcp.live_provider.LiveProvider,

    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.source = .{};
        self.cache = auth.TokenCache.init(self.source.tokenSource(), 300);
        self.transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{ .cloud_tasks = "https://tasks.example.test" });
        self.live = ziac.gcp.live_provider.LiveProvider.init(&self.client);
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

fn buildQueue(rate: f64, concurrency: u16) !ziac.gcp.tasks.Queue {
    return ziac.gcp.tasks.Queue.build(std.testing.allocator, .{ .project_id = "ziac-dev", .primary_region = "europe-west1" }, .{
        .name = "invoice-worker",
        .rate_limits = .{ .max_dispatches_per_second = rate, .max_concurrent_dispatches = concurrency },
        .retry_config = .{ .max_attempts = 8, .max_retry_duration_seconds = 3600, .min_backoff_seconds = 5, .max_backoff_seconds = 300, .max_doublings = 5 },
        .http_target = .{
            .uri_override = .{ .scheme = .https, .host = "invoice-worker.example.run.app", .path = "/tasks/invoice", .enforce_mode = .always },
            .method = .post,
            .headers = &.{.{ .key = "content-type", .value = "application/json" }},
            .authorization = .{ .oidc = .{ .service_account_email = "invoice-tasks@ziac-dev.iam.gserviceaccount.com", .audience = "https://invoice-worker.example.run.app" } },
        },
        .logging_sample_ratio = 0.25,
        .retain_on_delete = false,
    });
}

fn ok(body: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = body };
}
fn notFound() zstd.Http.Response {
    return .{ .status = 404, .body = "{\"error\":{\"code\":404,\"status\":\"NOT_FOUND\"}}" };
}

fn inputString(input: ziac.value.Value, name: []const u8) []const u8 {
    for (input.object) |field| if (std.mem.eql(u8, field.name, name)) return switch (field.value) {
        .string => |text| text,
        else => unreachable,
    };
    unreachable;
}
