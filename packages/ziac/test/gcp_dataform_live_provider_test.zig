const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

test "Dataform nested resources use canonical paths and exact update masks" {
    const repository_json = "{\"name\":\"projects/analytics-prod/locations/europe-west1/repositories/analytics\",\"displayName\":\"Analytics\",\"serviceAccount\":\"dataform@analytics-prod.iam.gserviceaccount.com\",\"labels\":{}}";
    const current = "{\"name\":\"projects/analytics-prod/locations/europe-west1/repositories/analytics/releaseConfigs/production\",\"gitCommitish\":\"old\",\"disabled\":false}";
    const updated_json = "{\"name\":\"projects/analytics-prod/locations/europe-west1/repositories/analytics/releaseConfigs/production\",\"gitCommitish\":\"main\",\"disabled\":false}";
    const responses = [_]zstd.Http.Response{ ok(repository_json), ok(current), ok(updated_json) };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.dataform_provider.Handler{ .client = &harness.client };
    var repository = try buildRepository();
    defer repository.deinit(std.testing.allocator);
    var release = try buildRelease(repository.name);
    defer release.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try handler.create(&context, repository.node);
    defer created.deinit();
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[0].url, "/v1beta1/projects/analytics-prod/locations/europe-west1/repositories?repositoryId=analytics"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "authenticationTokenSecretVersion") != null);
    var observed = try handler.read(&context, release.node, null);
    defer observed.deinit();
    var updated = try handler.update(&context, release.node, &observed.present);
    defer updated.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[2].url, "/releaseConfigs/production?updateMask=gitCommitish") != null);
}

test "data engineering IAM preserves unrelated policy bindings" {
    const policy = "{\"version\":3,\"etag\":\"iam-etag\",\"bindings\":[{\"role\":\"roles/viewer\",\"members\":[\"user:owner@example.com\"]}]}";
    const updated = "{\"version\":3,\"etag\":\"iam-new\",\"bindings\":[{\"role\":\"roles/viewer\",\"members\":[\"user:owner@example.com\"]},{\"role\":\"roles/dataform.editor\",\"members\":[\"group:data@example.com\"]}]}";
    const responses = [_]zstd.Http.Response{ ok(policy), ok(updated) };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.data_engineering_iam_provider.Handler{ .client = &harness.client };
    var member = try ziac.gcp.dataform.RepositoryIamMember.build(std.testing.allocator, config(), .{
        .name = "developers",
        .resource = ziac.PublicOutput([]const u8).known("projects/analytics-prod/locations/europe-west1/repositories/analytics"),
        .role = "roles/dataform.editor",
        .member = "group:data@example.com",
    });
    defer member.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var created = try handler.create(&context, member.node);
    defer created.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "roles/viewer") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "roles/dataform.editor") != null);
}

fn buildRepository() !ziac.gcp.dataform.Repository {
    return ziac.gcp.dataform.Repository.build(std.testing.allocator, config(), .{
        .name = "analytics",
        .location = "europe-west1",
        .display_name = "Analytics",
        .service_account = "dataform@analytics-prod.iam.gserviceaccount.com",
        .git_remote = .{ .url = "https://github.com/acme/analytics.git", .authentication = .{ .token_secret_version = "projects/analytics-prod/secrets/dataform-git/versions/1" } },
    });
}
fn buildRelease(repository: ziac.PublicOutput([]const u8)) !ziac.gcp.dataform.ReleaseConfig {
    return ziac.gcp.dataform.ReleaseConfig.build(std.testing.allocator, config(), .{ .name = "production", .repository = repository, .git_commitish = "main" });
}
fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "analytics-prod", .primary_region = "europe-west1" };
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
        self.client = ziac.gcp.client.Client.init(self.transport.client(), &self.cache, .{ .dataform = "https://dataform.example.test", .dataproc = "https://dataproc.example.test" });
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
