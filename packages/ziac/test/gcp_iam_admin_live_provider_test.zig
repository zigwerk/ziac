const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;

const provider_config = ziac.gcp.config.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
};

test "IAM admin provider manages custom roles with etags and explicit masks" {
    const old_role = roleJson("Old title", "old-etag");
    const new_role = roleJson("New title", "new-etag");
    const responses = [_]zstd.Http.Response{
        .{ .status = 404, .body = "{\"error\":{\"code\":404,\"status\":\"NOT_FOUND\",\"message\":\"missing\"}}" },
        .{ .status = 200, .body = old_role },
        .{ .status = 200, .body = old_role },
        .{ .status = 200, .body = new_role },
        .{ .status = 200, .body = "{}" },
        .{ .status = 404, .body = "{\"error\":{\"code\":404,\"status\":\"NOT_FOUND\",\"message\":\"missing\"}}" },
        .{ .status = 200, .body = new_role },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var role = try ziac.gcp.iam.ProjectCustomRole.build(std.testing.allocator, provider_config, .{
        .role_id = "ziacDeployer",
        .title = "Old title",
        .included_permissions = &.{ "run.services.get", "run.services.update" },
    });
    defer role.deinit(std.testing.allocator);
    var changed = try ziac.gcp.iam.ProjectCustomRole.build(std.testing.allocator, provider_config, .{
        .role_id = "ziacDeployer",
        .title = "New title",
        .included_permissions = &.{ "run.services.get", "run.services.update" },
    });
    defer changed.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var before = try live.readWithContext(&context, role.node);
    defer before.deinit();
    try std.testing.expect(before == .absent);
    var created = try live.createWithContext(&context, role.node);
    defer created.deinit();
    var present = try live.readWithContext(&context, role.node);
    defer present.deinit();
    var diff = try live.diffWithContext(&context, changed.node, &present.present);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, diff.kind);
    var updated = try live.updateWithContext(&context, changed.node, &present.present);
    defer updated.deinit();
    try live.deleteWithContext(&context, changed.node, updated.physical_id);
    var gone = try live.readWithContext(&context, changed.node);
    defer gone.deinit();
    try std.testing.expect(gone == .absent);
    var imported = try live.importWithContext(&context, changed.node, updated.physical_id);
    defer imported.deinit();

    try std.testing.expectEqualStrings(
        "https://iam.example.test/v1/projects/ziac-dev/roles?roleId=ziacDeployer",
        harness.transport.requests.items[1].url,
    );
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].url, "updateMask=title%2Cdescription%2CincludedPermissions%2Cstage") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].body, "\"etag\":\"old-etag\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[4].url, "etag=\"") == null);
}

test "IAM admin provider recovers a soft-deleted custom role before reconciling it" {
    const restored_role = roleJson("Old title", "restored-etag");
    const desired_role = roleJson("New title", "desired-etag");
    const responses = [_]zstd.Http.Response{
        .{ .status = 409, .body = "{\"error\":{\"code\":409,\"status\":\"ALREADY_EXISTS\",\"message\":\"soft deleted\"}}" },
        .{ .status = 200, .body = restored_role },
        .{ .status = 200, .body = desired_role },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var role = try ziac.gcp.iam.ProjectCustomRole.build(std.testing.allocator, provider_config, .{
        .role_id = "ziacDeployer",
        .title = "New title",
        .included_permissions = &.{ "run.services.get", "run.services.update" },
    });
    defer role.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try live.createWithContext(&context, role.node);
    defer created.deinit();
    const observed = try created.observed_inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(observed);
    try std.testing.expect(std.mem.indexOf(u8, observed, "\"title\":\"New title\"") != null);
    try std.testing.expectEqualStrings(
        "https://iam.example.test/v1/projects/ziac-dev/roles/ziacDeployer:undelete",
        harness.transport.requests.items[1].url,
    );
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[2].body, "\"etag\":\"restored-etag\"") != null);
}

test "IAM admin provider resumes Workload Identity Pool creation" {
    const pool_json =
        "{\"name\":\"projects/123456789012/locations/global/workloadIdentityPools/github-actions\"," ++
        "\"displayName\":\"GitHub Actions\",\"description\":\"Keyless CI identities\",\"state\":\"ACTIVE\",\"disabled\":false}";
    const responses = [_]zstd.Http.Response{
        .{ .status = 404, .body = "{\"error\":{\"code\":404,\"status\":\"NOT_FOUND\",\"message\":\"missing\"}}" },
        .{ .status = 200, .body = "{\"name\":\"operations/create-pool\"}" },
        .{ .status = 200, .body = "{\"name\":\"operations/create-pool\",\"done\":false}" },
        .{ .status = 200, .body = "{\"name\":\"operations/create-pool\",\"done\":true,\"response\":" ++ pool_json ++ "}" },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    harness.live.operation_policy = .{ .poll_interval_millis = 5 };
    var pool = try ziac.gcp.iam.WorkloadIdentityPool.build(std.testing.allocator, provider_config, .{
        .project_number = "123456789012",
        .pool_id = "github-actions",
        .display_name = "GitHub Actions",
        .description = "Keyless CI identities",
    });
    defer pool.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    context.clock = &harness.clock;

    var before = try live.readWithContext(&context, pool.node);
    defer before.deinit();
    try std.testing.expect(before == .absent);
    var created = try live.createWithContext(&context, pool.node);
    defer created.deinit();
    try std.testing.expect(!created.completed);
    context.operation_handle = created.operation_handle;
    var present = try live.readWithContext(&context, pool.node);
    defer present.deinit();
    try std.testing.expect(present == .present);
    try std.testing.expectEqualStrings("ACTIVE", present.present.outputs[1].value.string);

    try std.testing.expectEqualStrings(
        "https://iam.example.test/v1/projects/123456789012/locations/global/workloadIdentityPools?workloadIdentityPoolId=github-actions",
        harness.transport.requests.items[1].url,
    );
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"displayName\":\"GitHub Actions\"") != null);
    try std.testing.expectEqualStrings("https://iam.example.test/v1/operations/create-pool", harness.transport.requests.items[2].url);
    try std.testing.expectEqual(@as(u64, 5), harness.clock.nowMs());
}

test "IAM admin provider creates OIDC federation providers with canonical mappings" {
    const provider_json =
        "{\"name\":\"projects/123456789012/locations/global/workloadIdentityPools/github-actions/providers/github-oidc\"," ++
        "\"displayName\":\"GitHub OIDC\",\"state\":\"ACTIVE\",\"disabled\":false," ++
        "\"attributeMapping\":{\"google.subject\":\"assertion.sub\"}," ++
        "\"oidc\":{\"issuerUri\":\"https://token.actions.githubusercontent.com\",\"allowedAudiences\":[]}}";
    const responses = [_]zstd.Http.Response{
        .{ .status = 200, .body = "{\"name\":\"operations/create-provider\"}" },
        .{ .status = 200, .body = "{\"name\":\"operations/create-provider\",\"done\":true,\"response\":" ++ provider_json ++ "}" },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var provider = try ziac.gcp.iam.WorkloadIdentityPoolProvider.build(std.testing.allocator, provider_config, .{
        .provider_id = "github-oidc",
        .pool = .{ .value = "projects/123456789012/locations/global/workloadIdentityPools/github-actions" },
        .display_name = "GitHub OIDC",
        .issuer_uri = "https://token.actions.githubusercontent.com",
        .attribute_mapping = &.{.{ .key = "google.subject", .expression = "assertion.sub" }},
    });
    defer provider.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try live.createWithContext(&context, provider.node);
    defer created.deinit();
    context.operation_handle = created.operation_handle;
    var present = try live.readWithContext(&context, provider.node);
    defer present.deinit();
    try std.testing.expect(present == .present);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "\"google.subject\":\"assertion.sub\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "\"issuerUri\":\"https://token.actions.githubusercontent.com\"") != null);
}

test "IAM admin provider resumes soft-deleted federation resources and reconciles desired state" {
    const restored_pool =
        "{\"name\":\"projects/123456789012/locations/global/workloadIdentityPools/github-actions\"," ++
        "\"displayName\":\"Old name\",\"description\":\"\",\"state\":\"ACTIVE\",\"disabled\":false}";
    const responses = [_]zstd.Http.Response{
        .{ .status = 409, .body = "{\"error\":{\"code\":409,\"status\":\"ALREADY_EXISTS\",\"message\":\"soft deleted\"}}" },
        .{ .status = 200, .body = "{\"name\":\"operations/undelete-pool\"}" },
        .{ .status = 200, .body = "{\"name\":\"operations/undelete-pool\",\"done\":true,\"response\":" ++ restored_pool ++ "}" },
        .{ .status = 200, .body = "{\"name\":\"operations/reconcile-pool\"}" },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var pool = try ziac.gcp.iam.WorkloadIdentityPool.build(std.testing.allocator, provider_config, .{
        .project_number = "123456789012",
        .pool_id = "github-actions",
        .display_name = "GitHub Actions",
    });
    defer pool.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try live.createWithContext(&context, pool.node);
    defer created.deinit();
    context.operation_handle = created.operation_handle;
    var reconciling = try live.readWithContext(&context, pool.node);
    defer reconciling.deinit();
    try std.testing.expect(reconciling == .present);
    try std.testing.expect(!reconciling.present.completed);
    try std.testing.expectEqualStrings("operations/reconcile-pool", reconciling.present.operation_handle.?);
    try std.testing.expectEqualStrings(
        "https://iam.example.test/v1/projects/123456789012/locations/global/workloadIdentityPools/github-actions:undelete",
        harness.transport.requests.items[1].url,
    );
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].url, "updateMask=displayName%2Cdescription%2Cdisabled") != null);
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
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{ .iam = "https://iam.example.test" });
        self.live = ziac.gcp.live_provider.LiveProvider.init(&self.client);
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

fn roleJson(comptime title: []const u8, comptime etag: []const u8) []const u8 {
    return "{\"name\":\"projects/ziac-dev/roles/ziacDeployer\",\"title\":\"" ++ title ++ "\",\"description\":\"\",\"includedPermissions\":[\"run.services.get\",\"run.services.update\"],\"stage\":\"GA\",\"etag\":\"" ++ etag ++ "\",\"deleted\":false}";
}
