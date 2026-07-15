const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

test "Vertex AI provider uses regional origin and resumes endpoint creation" {
    const operation_name = "projects/ml-prod/locations/europe-west4/operations/create-endpoint";
    const endpoint_json = "{\"name\":\"projects/ml-prod/locations/europe-west4/endpoints/orders-online\",\"displayName\":\"Orders online\",\"description\":\"Production predictions\",\"labels\":{},\"etag\":\"etag-1\"}";
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"" ++ operation_name ++ "\"}"),
        ok("{\"name\":\"" ++ operation_name ++ "\",\"done\":true,\"response\":" ++ endpoint_json ++ "}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.vertex_ai_provider.Handler{ .client = &harness.client, .operation_policy = .{ .poll_interval_millis = 0 } };
    var endpoint = try buildEndpoint("Production predictions");
    defer endpoint.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.create(&context, endpoint.node);
    defer pending.deinit();
    try std.testing.expect(!pending.completed);
    try std.testing.expectEqualStrings(operation_name, pending.operation_handle.?);
    try std.testing.expect(std.mem.startsWith(u8, harness.transport.requests.items[0].url, "https://europe-west4-aiplatform.example.test/v1/projects/ml-prod/locations/europe-west4/endpoints?endpointId=orders-online&requestId="));
    context.operation_handle = pending.operation_handle;
    var observed = try handler.read(&context, endpoint.node, pending.physical_id);
    defer observed.deinit();
    try std.testing.expectEqualStrings("etag-1", outputString(observed.present, "etag"));
}

test "Vertex AI provider sends exact mutable mask and observed etag" {
    const current = "{\"name\":\"projects/ml-prod/locations/europe-west4/endpoints/orders-online\",\"displayName\":\"Orders online\",\"description\":\"Old\",\"labels\":{},\"etag\":\"etag-old\"}";
    const responses = [_]zstd.Http.Response{ ok(current), ok("{\"name\":\"projects/ml-prod/locations/europe-west4/endpoints/orders-online\",\"displayName\":\"Orders online\",\"description\":\"New\",\"labels\":{},\"etag\":\"etag-new\"}") };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.vertex_ai_provider.Handler{ .client = &harness.client };
    var endpoint = try buildEndpoint("New");
    defer endpoint.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var observed = try handler.read(&context, endpoint.node, null);
    defer observed.deinit();
    var updated = try handler.update(&context, endpoint.node, &observed.present);
    defer updated.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].url, "updateMask=description") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"etag\":\"etag-old\"") != null);
}

test "Vertex AI provider replaces immutable endpoint connectivity" {
    var desired = try buildEndpoint("Production predictions");
    defer desired.deinit(std.testing.allocator);
    var original = try ziac.gcp.vertex_ai.Endpoint.build(std.testing.allocator, config(), .{
        .name = "orders-online",
        .location = "europe-west4",
        .display_name = "Orders online",
        .description = "Production predictions",
        .connectivity = .{ .vpc = .{ .value = "projects/123456789/global/networks/ml" } },
    });
    defer original.deinit(std.testing.allocator);
    const outputs = [_]ziac.state.StateOutput{
        .{ .name = "__remote_spec", .value = .{ .string = "{\"displayName\":\"Orders online\",\"description\":\"Production predictions\",\"labels\":{},\"network\":\"projects/123456789/global/networks/ml\"}" } },
        .{ .name = "etag", .value = .{ .string = "etag-old" } },
    };
    var observed = try ziac.provider.ResourceResult.init(std.testing.allocator, "projects/ml-prod/locations/europe-west4/endpoints/orders-online", original.node.inputs, &outputs, null);
    defer observed.deinit();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var diff = try ziac.gcp.vertex_ai_provider.Handler.diff(&context, desired.node, &observed);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.replace, diff.kind);
}

fn buildEndpoint(description: []const u8) !ziac.gcp.vertex_ai.Endpoint {
    return ziac.gcp.vertex_ai.Endpoint.build(std.testing.allocator, config(), .{
        .name = "orders-online",
        .location = "europe-west4",
        .display_name = "Orders online",
        .description = description,
    });
}
fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "ml-prod", .primary_region = "europe-west4" };
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
