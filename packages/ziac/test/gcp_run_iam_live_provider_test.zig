const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;

test "live Cloud Run IAM preserves unrelated bindings while managing one invoker" {
    const before = "{\"version\":3,\"etag\":\"BwA=\",\"bindings\":[{\"role\":\"roles/run.invoker\",\"members\":[\"user:operator@example.com\"]}]}";
    const after = "{\"version\":3,\"etag\":\"BwB=\",\"bindings\":[{\"role\":\"roles/run.invoker\",\"members\":[\"user:operator@example.com\",\"serviceAccount:orders-push@ziac-dev.iam.gserviceaccount.com\"]}]}";
    const responses = [_]zstd.Http.Response{
        ok(before),
        ok(after),
        ok(after),
        ok(after),
        ok(before),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var member = try ziac.gcp.cloud_run.ServiceIamMember.build(std.testing.allocator, providerConfig(), .{
        .name = "orders-push-invoker",
        .service = ziac.PublicOutput([]const u8).known("projects/ziac-dev/locations/europe-west1/services/orders-worker"),
        .role = "roles/run.invoker",
        .member = "serviceAccount:orders-push@ziac-dev.iam.gserviceaccount.com",
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

    try std.testing.expectEqualStrings("GET", harness.transport.requests.items[0].method);
    try std.testing.expectEqualStrings(
        "https://run.example.test/v2/projects/ziac-dev/locations/europe-west1/services/orders-worker:getIamPolicy?options.requestedPolicyVersion=3",
        harness.transport.requests.items[0].url,
    );
    try std.testing.expectEqualStrings("POST", harness.transport.requests.items[1].method);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"etag\":\"BwA=\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "operator@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "orders-push@ziac-dev") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[4].body, "operator@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[4].body, "orders-push@ziac-dev") == null);
}

test "Cloud Run IAM deletion is idempotent after the target service is gone" {
    const responses = [_]zstd.Http.Response{notFound()};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var member = try ziac.gcp.cloud_run.ServiceIamMember.build(std.testing.allocator, providerConfig(), .{
        .name = "orders-push-invoker",
        .service = ziac.PublicOutput([]const u8).known("projects/ziac-dev/locations/europe-west1/services/orders-worker"),
        .role = "roles/run.invoker",
        .member = "serviceAccount:orders-push@ziac-dev.iam.gserviceaccount.com",
    });
    defer member.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    try harness.live.provider().deleteWithContext(
        &context,
        member.node,
        "projects/ziac-dev/locations/europe-west1/services/orders-worker/iam/orders-push-invoker",
    );
    try std.testing.expectEqual(@as(usize, 1), harness.transport.requests.items.len);
}

test "Cloud Run Job IAM uses the job-scoped Google policy endpoint" {
    const policy = "{\"version\":3,\"etag\":\"BwJ=\",\"bindings\":[{\"role\":\"roles/run.invoker\",\"members\":[\"serviceAccount:nightly@ziac-dev.iam.gserviceaccount.com\"]}]}";
    const responses = [_]zstd.Http.Response{ok(policy)};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var member = try ziac.gcp.run_workloads.JobIamMember.build(std.testing.allocator, providerConfig(), .{
        .name = "nightly-invoker",
        .job = ziac.PublicOutput([]const u8).known("projects/ziac-dev/locations/europe-west1/jobs/nightly"),
        .role = "roles/run.invoker",
        .member = "serviceAccount:nightly@ziac-dev.iam.gserviceaccount.com",
    });
    defer member.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var read = try harness.live.provider().readWithContext(&context, member.node);
    defer read.deinit();

    try std.testing.expect(read == .present);
    try std.testing.expectEqualStrings(
        "https://run.example.test/v2/projects/ziac-dev/locations/europe-west1/jobs/nightly:getIamPolicy?options.requestedPolicyVersion=3",
        harness.transport.requests.items[0].url,
    );
}

const Harness = struct {
    token_source: FixedTokenSource,
    cache: auth.TokenCache,
    transport: @import("gcp_client_test.zig").RecordingTransport,
    client: gclient.Client,
    live: ziac.gcp.live_provider.LiveProvider,

    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.token_source = .{};
        self.cache = auth.TokenCache.init(self.token_source.tokenSource(), 300);
        self.transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{ .run = "https://run.example.test" });
        self.live = ziac.gcp.live_provider.LiveProvider.init(&self.client);
    }

    fn deinit(self: *Harness) void {
        self.transport.deinit();
        self.cache.deinit(std.testing.allocator);
        self.* = undefined;
    }
};

const FixedTokenSource = struct {
    fn tokenSource(self: *FixedTokenSource) auth.TokenSource {
        return .{ .ptr = self, .fetchFn = fetch };
    }

    fn fetch(_: *anyopaque, allocator: std.mem.Allocator, now_seconds: u64) auth.AuthError!auth.AccessToken {
        return auth.AccessToken.initOwned(allocator, .{
            .access_token = "dummy-google-token",
            .token_type = "Bearer",
            .expires_at_seconds = now_seconds + 3_600,
        });
    }
};

fn providerConfig() ziac.gcp.ProviderConfig {
    return .{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    };
}

fn ok(body: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = body };
}

fn notFound() zstd.Http.Response {
    return .{ .status = 404, .body = "{\"error\":{\"code\":404,\"status\":\"NOT_FOUND\",\"message\":\"missing\"}}" };
}
