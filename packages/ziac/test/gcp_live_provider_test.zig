const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;

const provider_config = ziac.gcp.config.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
};

test "live GCP provider enables reads and disables project services through LRO" {
    const responses = [_]zstd.Http.Response{
        .{ .status = 200, .body = "{\"name\":\"projects/ziac-dev/services/run.googleapis.com\",\"state\":\"DISABLED\"}" },
        .{ .status = 200, .body = "{\"name\":\"operations/enable-run\"}" },
        .{ .status = 200, .body = "{\"name\":\"operations/enable-run\",\"done\":false}" },
        .{ .status = 200, .body = "{\"name\":\"operations/enable-run\",\"done\":true}" },
        .{ .status = 200, .body = "{\"name\":\"projects/ziac-dev/services/run.googleapis.com\",\"state\":\"ENABLED\"}" },
        .{ .status = 200, .body = "{\"name\":\"operations/disable-run\"}" },
        .{ .status = 200, .body = "{\"name\":\"operations/disable-run\",\"done\":true}" },
        .{ .status = 200, .body = "{\"name\":\"projects/ziac-dev/services/run.googleapis.com\",\"state\":\"DISABLED\"}" },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var service = try ziac.gcp.project_service.Service.build(std.testing.allocator, provider_config, .{
        .service = "run.googleapis.com",
    });
    defer service.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    context.clock = &harness.clock;

    var before = try live.readWithContext(&context, service.node);
    defer before.deinit();
    try std.testing.expect(before == .absent);

    var created = try live.createWithContext(&context, service.node);
    defer created.deinit();
    try std.testing.expectEqualStrings("projects/ziac-dev/services/run.googleapis.com", created.physical_id);
    try std.testing.expectEqualStrings("operations/enable-run", created.operation_handle.?);
    try std.testing.expectEqualStrings("resource_name", created.outputs[0].name);

    var present = try live.readWithContext(&context, service.node);
    defer present.deinit();
    try std.testing.expect(present == .present);
    var diff = try live.diffWithContext(&context, service.node, &present.present);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.noop, diff.kind);

    try live.deleteWithContext(&context, service.node, created.physical_id);
    var gone = try live.readWithContext(&context, service.node);
    defer gone.deinit();
    try std.testing.expect(gone == .absent);

    try std.testing.expectEqualStrings(
        "https://serviceusage.example.test/v1/projects/ziac-dev/services/run.googleapis.com:enable",
        harness.transport.requests.items[1].url,
    );
    try std.testing.expectEqualStrings(
        "https://serviceusage.example.test/v1/operations/enable-run",
        harness.transport.requests.items[2].url,
    );
    try std.testing.expectEqual(@as(u64, 10), harness.clock.nowMs());
}

test "live GCP provider manages and imports IAM service accounts" {
    const responses = [_]zstd.Http.Response{
        .{ .status = 404, .body = "{\"error\":{\"code\":404,\"status\":\"NOT_FOUND\",\"message\":\"missing\"}}" },
        .{ .status = 200, .body = serviceAccountJson("Old name", "old description") },
        .{ .status = 200, .body = serviceAccountJson("Old name", "old description") },
        .{ .status = 200, .body = serviceAccountJson("New name", "new description") },
        .{ .status = 200, .body = "{}" },
        .{ .status = 404, .body = "{\"error\":{\"code\":404,\"status\":\"NOT_FOUND\",\"message\":\"missing\"}}" },
        .{ .status = 200, .body = serviceAccountJson("New name", "new description") },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var account = try ziac.gcp.iam.ServiceAccount.build(std.testing.allocator, provider_config, .{
        .account_id = "ziac-runtime",
        .display_name = "Old name",
        .description = "old description",
    });
    defer account.deinit(std.testing.allocator);
    var changed = try ziac.gcp.iam.ServiceAccount.build(std.testing.allocator, provider_config, .{
        .account_id = "ziac-runtime",
        .display_name = "New name",
        .description = "new description",
    });
    defer changed.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var before = try live.readWithContext(&context, account.node);
    defer before.deinit();
    try std.testing.expect(before == .absent);
    var created = try live.createWithContext(&context, account.node);
    defer created.deinit();
    try std.testing.expectEqualStrings("ziac-runtime@ziac-dev.iam.gserviceaccount.com", created.outputs[0].value.string);

    var present = try live.readWithContext(&context, account.node);
    defer present.deinit();
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

    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"accountId\":\"ziac-runtime\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].body, "\"updateMask\":\"displayName,description\"") != null);
}

test "live GCP project member preserves IAM policy etags and retries conflicts" {
    const without_member_a =
        "{\"version\":1,\"etag\":\"etag-a\",\"bindings\":[{\"role\":\"roles/viewer\",\"members\":[\"user:viewer@example.com\"]}]}";
    const without_member_b =
        "{\"version\":1,\"etag\":\"etag-b\",\"bindings\":[{\"role\":\"roles/viewer\",\"members\":[\"user:viewer@example.com\"]}]}";
    const with_member =
        "{\"version\":1,\"etag\":\"etag-c\",\"bindings\":[{\"role\":\"roles/viewer\",\"members\":[\"user:viewer@example.com\"]},{\"role\":\"roles/artifactregistry.reader\",\"members\":[\"serviceAccount:ziac-runtime@ziac-dev.iam.gserviceaccount.com\"]}]}";
    const responses = [_]zstd.Http.Response{
        .{ .status = 200, .body = without_member_a },
        .{ .status = 200, .body = without_member_a },
        .{ .status = 409, .body = "{\"error\":{\"code\":409,\"status\":\"ABORTED\",\"message\":\"etag conflict\"}}" },
        .{ .status = 200, .body = without_member_b },
        .{ .status = 200, .body = with_member },
        .{ .status = 200, .body = with_member },
        .{ .status = 200, .body = with_member },
        .{ .status = 200, .body = without_member_b },
        .{ .status = 200, .body = without_member_b },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    harness.live.iam_conflict_retries = 1;
    var member = try ziac.gcp.iam.ProjectMember.build(std.testing.allocator, provider_config, .{
        .name = "runtime-artifact-reader",
        .role = "roles/artifactregistry.reader",
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
    try std.testing.expectEqualStrings("binding_id", created.outputs[0].name);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[2].body, "\"etag\":\"etag-a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[4].body, "\"etag\":\"etag-b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[4].body, "roles/viewer") != null);

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
    clock: ziac.fx.Clock,

    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.token_source = .{};
        self.cache = auth.TokenCache.init(self.token_source.tokenSource(), 300);
        self.transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{
            .service_usage = "https://serviceusage.example.test",
            .iam = "https://iam.example.test",
            .resource_manager = "https://resourcemanager.example.test",
        });
        self.live = ziac.gcp.live_provider.LiveProvider.init(&self.client);
        self.live.operation_policy = .{ .poll_interval_millis = 10 };
        self.clock = ziac.fx.Clock.fake(0);
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

fn serviceAccountJson(comptime display_name: []const u8, comptime description: []const u8) []const u8 {
    return "{\"name\":\"projects/ziac-dev/serviceAccounts/ziac-runtime@ziac-dev.iam.gserviceaccount.com\",\"projectId\":\"ziac-dev\",\"uniqueId\":\"123456789\",\"email\":\"ziac-runtime@ziac-dev.iam.gserviceaccount.com\",\"displayName\":\"" ++ display_name ++ "\",\"description\":\"" ++ description ++ "\"}";
}
