const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;
const logging = ziac.gcp.logging;

test "log bucket creation checkpoints and resumes the Logging operation" {
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"projects/ziac-dev/locations/global/operations/create-bucket\",\"done\":false}"),
        ok("{\"name\":\"projects/ziac-dev/locations/global/operations/create-bucket\",\"done\":true}"),
        ok(bucketJson(30, false, false)),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.logging_provider.Handler{ .client = &harness.client, .operation_policy = .{ .poll_interval_millis = 0 } };
    var bucket = try buildBucket(30, false, false);
    defer bucket.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.create(&context, bucket.node);
    defer pending.deinit();
    try std.testing.expect(!pending.completed);
    try std.testing.expectEqualStrings("projects/ziac-dev/locations/global/operations/create-bucket", pending.operation_handle.?);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].url, "/v2/projects/ziac-dev/locations/global/buckets:createAsync?bucketId=application-logs") != null);

    context.operation_handle = pending.operation_handle;
    var read = try handler.read(&context, bucket.node, null);
    defer read.deinit();
    try std.testing.expect(read == .present);
    try std.testing.expectEqualStrings("projects/ziac-dev/locations/global/buckets/application-logs", read.present.physical_id);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].url, "/v2/projects/ziac-dev/locations/global/operations/create-bucket") != null);
}

test "log bucket updates use exact masks and preserve one-way settings" {
    const responses = [_]zstd.Http.Response{ok("{\"name\":\"projects/ziac-dev/locations/global/operations/update-bucket\",\"done\":false}")};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.logging_provider.Handler{ .client = &harness.client, .operation_policy = .{} };
    var desired = try buildBucket(90, true, true);
    defer desired.deinit(std.testing.allocator);
    var current = try buildBucket(30, false, false);
    defer current.deinit(std.testing.allocator);
    var observed = try resultFor(current.node, "projects/ziac-dev/locations/global/buckets/application-logs");
    defer observed.deinit();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var diff = try ziac.gcp.logging_provider.Handler.diff(&context, desired.node, &observed);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, diff.kind);
    var pending = try handler.update(&context, desired.node, &observed);
    defer pending.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].url, "updateMask=analyticsEnabled%2CcmekSettings.kmsKeyName%2Cdescription%2CindexConfigs%2Clocked%2CretentionDays%2CrestrictedFields") != null);

    var illegal_desired = try buildBucket(60, false, false);
    defer illegal_desired.deinit(std.testing.allocator);
    var locked_remote = try buildBucket(30, true, true);
    defer locked_remote.deinit(std.testing.allocator);
    var locked_observed = try resultFor(locked_remote.node, "projects/ziac-dev/locations/global/buckets/application-logs");
    defer locked_observed.deinit();
    try std.testing.expectError(error.InvalidConfiguration, ziac.gcp.logging_provider.Handler.diff(&context, illegal_desired.node, &locked_observed));
}

test "log sink creation returns the generated writer identity" {
    const responses = [_]zstd.Http.Response{ok("{\"name\":\"security-archive\",\"destination\":\"logging.googleapis.com/projects/ziac-dev/locations/global/buckets/security-archive\",\"filter\":\"severity>=WARNING\",\"description\":\"\",\"disabled\":false,\"writerIdentity\":\"serviceAccount:service-123@gcp-sa-logging.iam.gserviceaccount.com\"}")};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.logging_provider.Handler{ .client = &harness.client, .operation_policy = .{} };
    var sink = try logging.Sink.build(std.testing.allocator, config(), .{
        .name = "security-archive",
        .destination = .{ .logging_bucket = known("projects/ziac-dev/locations/global/buckets/security-archive") },
        .filter = "severity>=WARNING",
    });
    defer sink.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try handler.create(&context, sink.node);
    defer created.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].url, "/v2/projects/ziac-dev/sinks?uniqueWriterIdentity=true") != null);
    try std.testing.expectEqualStrings("serviceAccount:service-123@gcp-sa-logging.iam.gserviceaccount.com", outputValue(created, "writer_identity").string);
}

test "log metric descriptor changes require replacement" {
    var counter = try logging.Metric.build(std.testing.allocator, config(), .{
        .name = "error-count",
        .filter = "severity>=ERROR",
        .labels = &.{.{ .key = "region" }},
        .label_extractors = &.{.{ .key = "region", .extractor = "EXTRACT(resource.labels.location)" }},
    });
    defer counter.deinit(std.testing.allocator);
    var distribution = try logging.Metric.build(std.testing.allocator, config(), .{
        .name = "error-count",
        .filter = "severity>=ERROR",
        .mode = .{ .distribution = .{
            .value_extractor = "EXTRACT(jsonPayload.latency_ms)",
            .buckets = .{ .linear = .{ .count = 10, .width_micros = 100_000 } },
        } },
        .labels = &.{.{ .key = "region" }},
        .label_extractors = &.{.{ .key = "region", .extractor = "EXTRACT(resource.labels.location)" }},
    });
    defer distribution.deinit(std.testing.allocator);
    var observed = try resultFor(counter.node, "projects/ziac-dev/metrics/error-count");
    defer observed.deinit();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var diff = try ziac.gcp.logging_provider.Handler.diff(&context, distribution.node, &observed);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.replace, diff.kind);
}

fn buildBucket(retention_days: u16, analytics_enabled: bool, locked: bool) !logging.Bucket {
    return logging.Bucket.build(std.testing.allocator, config(), .{
        .name = "application-logs",
        .location = "global",
        .retention_days = retention_days,
        .analytics_enabled = analytics_enabled,
        .locked = locked,
    });
}

fn resultFor(node: ziac.ResourceNode, physical_id: []const u8) !ziac.provider.ResourceResult {
    return ziac.provider.ResourceResult.init(std.testing.allocator, physical_id, node.inputs, &.{}, null);
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
}

fn known(text: []const u8) ziac.PublicOutput([]const u8) {
    return .known(text);
}

fn bucketJson(retention_days: u16, analytics_enabled: bool, locked: bool) []const u8 {
    if (retention_days == 30 and !analytics_enabled and !locked) return "{\"name\":\"projects/ziac-dev/locations/global/buckets/application-logs\",\"description\":\"\",\"retentionDays\":30,\"analyticsEnabled\":false,\"locked\":false,\"restrictedFields\":[],\"indexConfigs\":[],\"lifecycleState\":\"ACTIVE\"}";
    unreachable;
}

fn outputValue(result: ziac.provider.ResourceResult, name: []const u8) ziac.value.Value {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name)) return item.value;
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
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{ .logging = "https://logging.example.test" });
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

fn ok(body: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = @constCast(body) };
}
