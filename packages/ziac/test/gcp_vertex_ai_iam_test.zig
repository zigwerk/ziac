const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

test "Vertex AI IAM preserves unrelated policy-v3 bindings on the regional endpoint" {
    const policy = "{\"version\":3,\"etag\":\"iam-etag\",\"bindings\":[{\"role\":\"roles/viewer\",\"members\":[\"user:owner@example.com\"]}]}";
    const updated = "{\"version\":3,\"etag\":\"iam-next\",\"bindings\":[{\"role\":\"roles/viewer\",\"members\":[\"user:owner@example.com\"]},{\"role\":\"roles/aiplatform.user\",\"members\":[\"serviceAccount:api@ml-prod.iam.gserviceaccount.com\"]}]}";
    const responses = [_]zstd.Http.Response{ ok(policy), ok(updated) };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.vertex_ai_iam_provider.Handler{ .client = &harness.client };
    var member = try ziac.gcp.vertex_ai.ModelIamMember.build(std.testing.allocator, config(), .{
        .location = "europe-west4",
        .model = .{ .value = "projects/ml-prod/locations/europe-west4/models/123456" },
        .role = "roles/aiplatform.user",
        .member = "serviceAccount:api@ml-prod.iam.gserviceaccount.com",
    });
    defer member.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var created = try handler.create(&context, member.node);
    defer created.deinit();

    try std.testing.expect(std.mem.startsWith(u8, harness.transport.requests.items[0].url, "https://europe-west4-aiplatform.example.test/v1/"));
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[0].url, ":getIamPolicy?options.requestedPolicyVersion=3"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "roles/viewer") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "roles/aiplatform.user") != null);
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "ml-prod", .primary_region = "europe-west4" };
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
