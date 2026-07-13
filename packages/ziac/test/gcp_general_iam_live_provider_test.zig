const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;

const provider_config = ziac.gcp.config.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
};

test "general IAM member preserves conditional bindings and concurrent unrelated edits" {
    const initial =
        "{\"version\":3,\"etag\":\"etag-a\",\"bindings\":[" ++
        "{\"role\":\"roles/viewer\",\"members\":[\"group:existing@example.com\"]}," ++
        "{\"role\":\"roles/storage.objectViewer\",\"members\":[\"group:other@example.com\"],\"condition\":{\"title\":\"other\",\"description\":\"\",\"expression\":\"request.time < timestamp('2027-01-01T00:00:00Z')\"}}]}";
    const concurrent =
        "{\"version\":3,\"etag\":\"etag-b\",\"bindings\":[" ++
        "{\"role\":\"roles/viewer\",\"members\":[\"group:existing@example.com\"]}," ++
        "{\"role\":\"roles/logging.viewer\",\"members\":[\"user:operator@example.com\"]}," ++
        "{\"role\":\"roles/storage.objectViewer\",\"members\":[\"group:other@example.com\"],\"condition\":{\"title\":\"other\",\"description\":\"\",\"expression\":\"request.time < timestamp('2027-01-01T00:00:00Z')\"}}]}";
    const final_policy =
        "{\"version\":3,\"etag\":\"etag-c\",\"bindings\":[" ++
        "{\"role\":\"roles/viewer\",\"members\":[\"group:existing@example.com\"]}," ++
        "{\"role\":\"roles/logging.viewer\",\"members\":[\"user:operator@example.com\"]}," ++
        "{\"role\":\"roles/storage.objectViewer\",\"members\":[\"group:other@example.com\"],\"condition\":{\"title\":\"other\",\"description\":\"\",\"expression\":\"request.time < timestamp('2027-01-01T00:00:00Z')\"}}," ++
        "{\"role\":\"roles/storage.objectViewer\",\"members\":[\"group:platform@example.com\"],\"condition\":{\"title\":\"migration\",\"description\":\"Temporary\",\"expression\":\"request.time < timestamp('2026-08-01T00:00:00Z')\"}}]}";
    const responses = [_]zstd.Http.Response{
        .{ .status = 200, .body = initial },
        .{ .status = 409, .body = "{\"error\":{\"code\":409,\"status\":\"ABORTED\",\"message\":\"etag conflict\"}}" },
        .{ .status = 200, .body = concurrent },
        .{ .status = 200, .body = final_policy },
        .{ .status = 200, .body = final_policy },
        .{ .status = 200, .body = final_policy },
        .{ .status = 200, .body = concurrent },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    harness.live.iam_conflict_retries = 1;
    var member = try ziac.gcp.iam.ProjectMember.build(std.testing.allocator, provider_config, .{
        .name = "temporary-reader",
        .role = "roles/storage.objectViewer",
        .member = "group:platform@example.com",
        .condition = .{
            .title = "migration",
            .description = "Temporary",
            .expression = "request.time < timestamp('2026-08-01T00:00:00Z')",
        },
    });
    defer member.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try live.createWithContext(&context, member.node);
    defer created.deinit();
    var present = try live.readWithContext(&context, member.node);
    defer present.deinit();
    try std.testing.expect(present == .present);
    try live.deleteWithContext(&context, member.node, created.physical_id);

    try std.testing.expectEqualStrings(
        "https://resourcemanager.example.test/v3/projects/ziac-dev:getIamPolicy",
        harness.transport.requests.items[0].url,
    );
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "requestedPolicyVersion") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"etag\":\"etag-a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].body, "\"etag\":\"etag-b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].body, "roles/logging.viewer") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].body, "\"title\":\"migration\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[6].body, "group:platform@example.com") == null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[6].body, "group:other@example.com") != null);
}

test "general IAM binding replaces only its owned member set" {
    const current =
        "{\"version\":1,\"etag\":\"binding-etag\",\"bindings\":[" ++
        "{\"role\":\"roles/viewer\",\"members\":[\"group:existing@example.com\"]}," ++
        "{\"role\":\"roles/artifactregistry.reader\",\"members\":[\"user:old@example.com\"]}]}";
    const responses = [_]zstd.Http.Response{
        .{ .status = 200, .body = current },
        .{ .status = 200, .body = current },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var binding = try ziac.gcp.iam.ProjectBinding.build(std.testing.allocator, provider_config, .{
        .name = "artifact-readers",
        .role = "roles/artifactregistry.reader",
        .members = &.{ "serviceAccount:worker@ziac-dev.iam.gserviceaccount.com", "group:platform@example.com" },
    });
    defer binding.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try live.createWithContext(&context, binding.node);
    defer created.deinit();
    const body = harness.transport.requests.items[1].body;
    try std.testing.expect(std.mem.indexOf(u8, body, "user:old@example.com") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "group:existing@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "group:platform@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "serviceAccount:worker@ziac-dev.iam.gserviceaccount.com") != null);
}

test "general IAM policy replacement requires explicit policy resource" {
    const current =
        "{\"version\":1,\"etag\":\"policy-etag\",\"bindings\":[{\"role\":\"roles/viewer\",\"members\":[\"group:legacy@example.com\"]}]," ++
        "\"auditConfigs\":[{\"service\":\"allServices\"}]}";
    const responses = [_]zstd.Http.Response{
        .{ .status = 200, .body = current },
        .{ .status = 200, .body = current },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var policy = try ziac.gcp.iam.ProjectPolicy.build(std.testing.allocator, provider_config, .{
        .name = "project-access",
        .bindings = &.{.{
            .role = "roles/logging.viewer",
            .members = &.{"group:platform@example.com"},
        }},
    });
    defer policy.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try live.createWithContext(&context, policy.node);
    defer created.deinit();
    const body = harness.transport.requests.items[1].body;
    try std.testing.expect(std.mem.indexOf(u8, body, "group:legacy@example.com") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "group:platform@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "auditConfigs") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"updateMask\":\"bindings,etag\"") != null);
}

test "service account IAM uses the IAM API target exactly" {
    const empty = "{\"version\":1,\"etag\":\"sa-etag\",\"bindings\":[]}";
    const responses = [_]zstd.Http.Response{
        .{ .status = 200, .body = empty },
        .{ .status = 200, .body = empty },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var member = try ziac.gcp.iam.ServiceAccountIamMember.build(std.testing.allocator, provider_config, .{
        .name = "github-deployer",
        .service_account_email = "deploy@ziac-dev.iam.gserviceaccount.com",
        .role = "roles/iam.workloadIdentityUser",
        .member = "principalSet://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/github/attribute.repository/acme/api",
    });
    defer member.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try live.createWithContext(&context, member.node);
    defer created.deinit();
    try std.testing.expectEqualStrings(
        "https://iam.example.test/v1/projects/ziac-dev/serviceAccounts/deploy@ziac-dev.iam.gserviceaccount.com:getIamPolicy",
        harness.transport.requests.items[0].url,
    );
    try std.testing.expectEqualStrings(
        "https://iam.example.test/v1/projects/ziac-dev/serviceAccounts/deploy@ziac-dev.iam.gserviceaccount.com:setIamPolicy",
        harness.transport.requests.items[1].url,
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
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{
            .iam = "https://iam.example.test",
            .resource_manager = "https://resourcemanager.example.test",
        });
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
