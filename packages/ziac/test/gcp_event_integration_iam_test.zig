const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

test "event integration IAM preserves unrelated version 3 bindings" {
    const policy = "{\"version\":3,\"etag\":\"iam-etag\",\"bindings\":[{\"role\":\"roles/viewer\",\"members\":[\"user:owner@example.com\"]}]}";
    const updated = "{\"version\":3,\"etag\":\"iam-new\",\"bindings\":[{\"role\":\"roles/viewer\",\"members\":[\"user:owner@example.com\"]},{\"role\":\"roles/eventarc.publisher\",\"members\":[\"serviceAccount:publisher@events-prod.iam.gserviceaccount.com\"]}]}";
    const responses = [_]zstd.Http.Response{ ok(policy), ok(updated) };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.event_integration_iam_provider.Handler{ .client = &harness.client };
    var member = try ziac.gcp.eventarc_advanced.MessageBusIamMember.build(std.testing.allocator, .{ .project_id = "events-prod", .primary_region = "europe-west1" }, .{
        .location = "europe-west1",
        .message_bus = .{ .value = "projects/events-prod/locations/europe-west1/messageBuses/application-events" },
        .role = "roles/eventarc.publisher",
        .member = "serviceAccount:publisher@events-prod.iam.gserviceaccount.com",
    });
    defer member.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var created = try handler.create(&context, member.node);
    defer created.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "roles/viewer") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "roles/eventarc.publisher") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].url, "options.requestedPolicyVersion=3") != null);
}

test "connector IAM routes policy calls to the Connectors endpoint" {
    const policy = "{\"version\":3,\"etag\":\"iam-etag\",\"bindings\":[]}";
    const updated = "{\"version\":3,\"etag\":\"iam-new\",\"bindings\":[{\"role\":\"roles/connectors.invoker\",\"members\":[\"group:operators@example.com\"]}]}";
    const responses = [_]zstd.Http.Response{ ok(policy), ok(updated) };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.event_integration_iam_provider.Handler{ .client = &harness.client };
    var member = try ziac.gcp.connectors.ConnectionIamMember.build(std.testing.allocator, .{ .project_id = "integration-prod", .primary_region = "europe-west1" }, .{
        .location = "europe-west1",
        .connection = .{ .value = "projects/integration-prod/locations/europe-west1/connections/crm" },
        .role = "roles/connectors.invoker",
        .member = "group:operators@example.com",
    });
    defer member.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var created = try handler.create(&context, member.node);
    defer created.deinit();
    try std.testing.expect(std.mem.startsWith(u8, harness.transport.requests.items[0].url, "https://connectors.example.test/"));
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
        self.client = ziac.gcp.client.Client.init(self.transport.client(), &self.cache, .{ .eventarc = "https://eventarc.example.test", .connectors = "https://connectors.example.test" });
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
