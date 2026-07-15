const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

test "Eventarc Advanced provider checkpoints and resumes bus creation" {
    const operation_name = "projects/events-prod/locations/europe-west1/operations/create-bus";
    const bus_json = "{\"name\":\"projects/events-prod/locations/europe-west1/messageBuses/application-events\",\"uid\":\"bus-uid\",\"displayName\":\"Application events\",\"cryptoKeyName\":\"projects/events-prod/locations/europe-west1/keyRings/events/cryptoKeys/payloads\",\"loggingConfig\":{\"logSeverity\":\"INFO\"},\"labels\":{},\"annotations\":{},\"etag\":\"etag-1\"}";
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"" ++ operation_name ++ "\"}"),
        ok("{\"name\":\"" ++ operation_name ++ "\",\"done\":true,\"response\":" ++ bus_json ++ "}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.eventarc_advanced_provider.Handler{ .client = &harness.client, .operation_policy = .{ .poll_interval_millis = 0 } };
    var bus = try buildBus();
    defer bus.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.create(&context, bus.node);
    defer pending.deinit();
    try std.testing.expect(!pending.completed);
    try std.testing.expectEqualStrings(operation_name, pending.operation_handle.?);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].url, "/v1/projects/events-prod/locations/europe-west1/messageBuses?messageBusId=application-events&requestId=") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "\"cryptoKeyName\"") != null);
    context.operation_handle = pending.operation_handle;
    var observed = try handler.read(&context, bus.node, pending.physical_id);
    defer observed.deinit();
    try std.testing.expectEqualStrings("projects/events-prod/locations/europe-west1/messageBuses/application-events", observed.present.physical_id);
    try std.testing.expectEqualStrings("etag-1", outputString(observed.present, "etag"));
}

test "Eventarc Advanced pipeline update uses exact mask and observed etag" {
    const current = "{\"name\":\"projects/events-prod/locations/europe-west1/pipelines/orders\",\"destinations\":[{\"topic\":\"projects/events-prod/topics/old\"}],\"retryPolicy\":{\"maxAttempts\":5,\"minRetryDelay\":\"5s\",\"maxRetryDelay\":\"60s\"},\"etag\":\"etag-old\"}";
    const operation_name = "projects/events-prod/locations/europe-west1/operations/update-pipeline";
    const responses = [_]zstd.Http.Response{ ok(current), ok("{\"name\":\"" ++ operation_name ++ "\"}") };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.eventarc_advanced_provider.Handler{ .client = &harness.client };
    var pipeline = try ziac.gcp.eventarc_advanced.Pipeline.build(std.testing.allocator, config(), .{
        .name = "orders",
        .location = "europe-west1",
        .destination = .{ .pubsub_topic = .{ .value = "projects/events-prod/topics/new" } },
    });
    defer pipeline.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var observed = try handler.read(&context, pipeline.node, null);
    defer observed.deinit();
    var pending = try handler.update(&context, pipeline.node, &observed.present);
    defer pending.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].url, "updateMask=destinations") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"etag\":\"etag-old\"") != null);
}

fn buildBus() !ziac.gcp.eventarc_advanced.MessageBus {
    return ziac.gcp.eventarc_advanced.MessageBus.build(std.testing.allocator, config(), .{
        .name = "application-events",
        .location = "europe-west1",
        .display_name = "Application events",
        .crypto_key_name = .{ .value = "projects/events-prod/locations/europe-west1/keyRings/events/cryptoKeys/payloads" },
        .logging_severity = .info,
    });
}
fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "events-prod", .primary_region = "europe-west1" };
}
fn outputString(result: ziac.provider.ResourceResult, name: []const u8) []const u8 {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name) and item.value == .string) return item.value.string;
    return "";
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
        self.client = ziac.gcp.client.Client.init(self.transport.client(), &self.cache, .{ .eventarc = "https://eventarc.example.test" });
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
