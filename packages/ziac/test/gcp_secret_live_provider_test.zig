const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;

test "live GCP provider manages Secret Manager metadata drift and import" {
    const responses = [_]zstd.Http.Response{
        notFound(),
        .{ .status = 200, .body = secretJson("dev") },
        .{ .status = 200, .body = secretJson("dev") },
        .{ .status = 200, .body = secretJson("prod") },
        .{ .status = 200, .body = "{}" },
        notFound(),
        .{ .status = 200, .body = secretJson("prod") },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const old_labels = [_]ziac.gcp.config.Label{.{ .key = "env", .value = "dev" }};
    const new_labels = [_]ziac.gcp.config.Label{.{ .key = "env", .value = "prod" }};
    var secret = try ziac.gcp.secret_manager.Secret.build(std.testing.allocator, config(&old_labels), .{ .name = "database-url" });
    defer secret.deinit(std.testing.allocator);
    var changed = try ziac.gcp.secret_manager.Secret.build(std.testing.allocator, config(&new_labels), .{ .name = "database-url" });
    defer changed.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var before = try live.readWithContext(&context, secret.node);
    defer before.deinit();
    try std.testing.expect(before == .absent);
    var created = try live.createWithContext(&context, secret.node);
    defer created.deinit();
    try std.testing.expectEqualStrings("projects/ziac-dev/secrets/database-url", created.physical_id);
    try std.testing.expectEqualStrings("resource_name", created.outputs[0].name);
    var present = try live.readWithContext(&context, secret.node);
    defer present.deinit();
    var noop = try live.diffWithContext(&context, secret.node, &present.present);
    defer noop.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.noop, noop.kind);
    var update_diff = try live.diffWithContext(&context, changed.node, &present.present);
    defer update_diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, update_diff.kind);
    var updated = try live.updateWithContext(&context, changed.node, &present.present);
    defer updated.deinit();
    try std.testing.expectEqual(changed.node.inputs_hash, updated.observed_hash);
    try live.deleteWithContext(&context, changed.node, updated.physical_id);
    var gone = try live.readWithContext(&context, changed.node);
    defer gone.deinit();
    try std.testing.expect(gone == .absent);
    var imported = try live.importWithContext(&context, changed.node, updated.physical_id);
    defer imported.deinit();
    try std.testing.expectEqualStrings(updated.physical_id, imported.physical_id);

    try std.testing.expectEqualStrings(
        "https://secretmanager.example.test/v1/projects/ziac-dev/secrets?secretId=database-url",
        harness.transport.requests.items[1].url,
    );
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"automatic\":{}") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].url, "updateMask=labels") != null);
}

test "live GCP secret version resolves payload ephemerally and stores only references" {
    const enabled = "{\"name\":\"projects/ziac-dev/secrets/database-url/versions/7\",\"state\":\"ENABLED\"}";
    const destroyed = "{\"name\":\"projects/ziac-dev/secrets/database-url/versions/7\",\"state\":\"DESTROYED\"}";
    const responses = [_]zstd.Http.Response{
        .{ .status = 200, .body = enabled },
        .{ .status = 200, .body = enabled },
        .{ .status = 200, .body = destroyed },
        .{ .status = 200, .body = destroyed },
        .{ .status = 200, .body = enabled },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var source = FixedSecretSource{};
    harness.live.secret_source = source.secretSource();
    var version = try ziac.gcp.secret_manager.SecretVersion.build(std.testing.allocator, config(&.{}), .{
        .name = "initial",
        .secret_id = "database-url",
        .source = .{ .provider = "config", .resource = "DATABASE_URL" },
    });
    defer version.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var before = try live.readWithContext(&context, version.node);
    defer before.deinit();
    try std.testing.expect(before == .absent);
    try std.testing.expectEqual(@as(usize, 0), harness.transport.requests.items.len);
    var created = try live.createWithContext(&context, version.node);
    defer created.deinit();
    try std.testing.expect(created.outputs[0].value == .secret_ref);
    try std.testing.expectEqualStrings("projects/ziac-dev/secrets/database-url", created.outputs[0].value.secret_ref.resource);
    try std.testing.expectEqualStrings("7", created.outputs[0].value.secret_ref.version.?);
    try std.testing.expectEqual(@as(usize, 1), source.resolves);
    try std.testing.expectEqual(@as(usize, 1), source.deinits);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "sentinel-secret-for-tests") == null);

    context.physical_id = created.physical_id;
    var present = try live.readWithContext(&context, version.node);
    defer present.deinit();
    try std.testing.expect(present == .present);
    var noop = try live.diffWithContext(&context, version.node, &present.present);
    defer noop.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.noop, noop.kind);
    try live.deleteWithContext(&context, version.node, created.physical_id);
    var gone = try live.readWithContext(&context, version.node);
    defer gone.deinit();
    try std.testing.expect(gone == .absent);
    var imported = try live.importWithContext(&context, version.node, created.physical_id);
    defer imported.deinit();
    try std.testing.expect(imported.outputs[0].value == .secret_ref);

    const observed_json = try imported.observed_inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(observed_json);
    try std.testing.expect(std.mem.indexOf(u8, observed_json, "sentinel-secret-for-tests") == null);
}

test "live GCP secret IAM member preserves conditional policy fields" {
    const without_member =
        "{\"version\":3,\"etag\":\"etag-a\",\"bindings\":[{\"role\":\"roles/secretmanager.secretAccessor\",\"members\":[\"user:auditor@example.com\"],\"condition\":{\"title\":\"temporary\",\"expression\":\"request.time < timestamp('2030-01-01T00:00:00Z')\"}}]}";
    const with_member =
        "{\"version\":3,\"etag\":\"etag-b\",\"bindings\":[{\"role\":\"roles/secretmanager.secretAccessor\",\"members\":[\"user:auditor@example.com\"],\"condition\":{\"title\":\"temporary\",\"expression\":\"request.time < timestamp('2030-01-01T00:00:00Z')\"}},{\"role\":\"roles/secretmanager.secretAccessor\",\"members\":[\"serviceAccount:ziac-runtime@ziac-dev.iam.gserviceaccount.com\"]}]}";
    const responses = [_]zstd.Http.Response{
        .{ .status = 200, .body = without_member },
        .{ .status = 200, .body = without_member },
        .{ .status = 200, .body = with_member },
        .{ .status = 200, .body = with_member },
        .{ .status = 200, .body = with_member },
        .{ .status = 200, .body = without_member },
        .{ .status = 200, .body = without_member },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var member = try ziac.gcp.secret_manager.SecretIamMember.build(std.testing.allocator, config(&.{}), .{
        .name = "runtime-accessor",
        .secret_id = "database-url",
        .role = "roles/secretmanager.secretAccessor",
        .member = "serviceAccount:ziac-runtime@ziac-dev.iam.gserviceaccount.com",
    });
    defer member.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var before = try live.readWithContext(&context, member.node);
    defer before.deinit();
    try std.testing.expect(before == .absent);
    var created = try live.createWithContext(&context, member.node);
    defer created.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[2].body, "\"condition\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[2].body, "\"etag\":\"etag-a\"") != null);
    var present = try live.readWithContext(&context, member.node);
    defer present.deinit();
    try std.testing.expect(present == .present);
    try live.deleteWithContext(&context, member.node, created.physical_id);
    var gone = try live.readWithContext(&context, member.node);
    defer gone.deinit();
    try std.testing.expect(gone == .absent);
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
            .secret_manager = "https://secretmanager.example.test",
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

const FixedSecretSource = struct {
    resolves: usize = 0,
    deinits: usize = 0,

    fn secretSource(self: *FixedSecretSource) ziac.gcp.live_provider.SecretSource {
        return .{ .ptr = self, .resolveFn = resolve };
    }

    fn resolve(
        raw: *anyopaque,
        allocator: std.mem.Allocator,
        reference: ziac.value.SecretReference,
    ) ziac.provider.ProviderError!ziac.gcp.live_provider.SecretPayload {
        const self: *FixedSecretSource = @ptrCast(@alignCast(raw));
        if (!std.mem.eql(u8, reference.provider, "config") or !std.mem.eql(u8, reference.resource, "DATABASE_URL")) {
            return error.NotFound;
        }
        self.resolves += 1;
        return ziac.gcp.live_provider.SecretPayload.initOwned(
            allocator,
            "postgres://user:sentinel-secret-for-tests@db.example:26257/app",
            .{ .ptr = self, .deinitFn = payloadDeinit },
        );
    }

    fn payloadDeinit(raw: *anyopaque) void {
        const self: *FixedSecretSource = @ptrCast(@alignCast(raw));
        self.deinits += 1;
    }
};

fn config(labels: []const ziac.gcp.config.Label) ziac.gcp.config.ProviderConfig {
    return .{ .project_id = "ziac-dev", .primary_region = "europe-west1", .labels = labels };
}

fn notFound() zstd.Http.Response {
    return .{ .status = 404, .body = "{\"error\":{\"code\":404,\"status\":\"NOT_FOUND\",\"message\":\"missing\"}}" };
}

fn secretJson(comptime environment: []const u8) []const u8 {
    return "{\"name\":\"projects/ziac-dev/secrets/database-url\",\"replication\":{\"automatic\":{}},\"labels\":{\"env\":\"" ++ environment ++ "\"},\"etag\":\"etag-secret\"}";
}
