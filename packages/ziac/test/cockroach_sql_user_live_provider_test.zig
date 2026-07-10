const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const cockroach = ziac.cockroach.client;

test "Cockroach SQL user lifecycle creates resets and deletes idempotently" {
    const responses = [_]zstd.Http.Response{
        users(&.{}),
        users(&.{}),
        ok(),
        users(&.{"app_user"}),
        users(&.{"app_user"}),
        ok(),
        okNoContent(),
        notFound(),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var source = FixedSecretSource{};
    harness.live.secret_source = source.secretSource();
    var user = try userResource();
    defer user.deinit(std.testing.allocator);
    var store = try secretState();
    defer store.deinit();
    const provider = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    context.state = &store;

    var before = try provider.readWithContext(&context, user.node);
    defer before.deinit();
    try std.testing.expect(before == .absent);
    var created = try provider.createWithContext(&context, user.node);
    defer created.deinit();
    try std.testing.expectEqualStrings("clusters/cluster-1/sql-users/app_user", created.physical_id);
    try std.testing.expectEqualStrings("app_user", created.outputs[0].value.string);
    var present = try provider.readWithContext(&context, user.node);
    defer present.deinit();
    try std.testing.expect(present == .present);

    var converged = try provider.createWithContext(&context, user.node);
    defer converged.deinit();
    try std.testing.expectEqual(user.node.inputs_hash, converged.observed_hash);
    try std.testing.expectEqual(@as(usize, 2), source.resolves);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[5].url, "/password") != null);

    try provider.deleteWithContext(&context, user.node, converged.physical_id);
    try provider.deleteWithContext(&context, user.node, converged.physical_id);
    try std.testing.expectEqualStrings("DELETE", harness.transport.requests.items[6].method);

    const observed = try converged.observed_inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(observed);
    try std.testing.expect(std.mem.indexOf(u8, observed, "p@ss") == null);
}

test "Cockroach SQL user retry converges from an already persisted secret version" {
    const responses = [_]zstd.Http.Response{
        users(&.{}),
        .{ .status = 503, .body = "{\"message\":\"temporarily unavailable\"}" },
        users(&.{}),
        ok(),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var source = FixedSecretSource{};
    harness.live.secret_source = source.secretSource();
    var user = try userResource();
    defer user.deinit(std.testing.allocator);
    var store = try secretState();
    defer store.deinit();
    const provider = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    context.state = &store;

    try std.testing.expectError(error.TransientFailure, provider.createWithContext(&context, user.node));
    var converged = try provider.createWithContext(&context, user.node);
    defer converged.deinit();

    try std.testing.expectEqualStrings("clusters/cluster-1/sql-users/app_user", converged.physical_id);
    try std.testing.expectEqual(@as(usize, 2), source.resolves);
    try std.testing.expectEqualStrings("POST", harness.transport.requests.items[1].method);
    try std.testing.expectEqualStrings("POST", harness.transport.requests.items[3].method);
}

const Harness = struct {
    transport: @import("cockroach_client_test.zig").RecordingTransport,
    client: cockroach.Client,
    live: ziac.cockroach.live_provider.LiveProvider,

    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.transport = @import("cockroach_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = cockroach.Client.init(self.transport.client(), "dummy-key", .{});
        self.live = ziac.cockroach.live_provider.LiveProvider.init(&self.client);
    }

    fn deinit(self: *Harness) void {
        self.transport.deinit();
        self.* = undefined;
    }
};

const FixedSecretSource = struct {
    resolves: usize = 0,

    fn secretSource(self: *FixedSecretSource) ziac.secret.SecretSource {
        return .{ .ptr = self, .resolveFn = resolve };
    }

    fn resolve(
        raw: *anyopaque,
        _: *ziac.provider.OperationContext,
        allocator: std.mem.Allocator,
        reference: ziac.value.SecretReference,
    ) ziac.provider.ProviderError!ziac.secret.SecretPayload {
        const self: *FixedSecretSource = @ptrCast(@alignCast(raw));
        if (!std.mem.eql(u8, reference.provider, "gcp-secret-manager")) return error.NotFound;
        self.resolves += 1;
        return ziac.secret.SecretPayload.initOwned(
            allocator,
            "postgresql://app_user:p%40ss%3A%2F%3F%23%5B%5D@db.example:26257/app?sslmode=verify-full",
            null,
        );
    }
};

fn userResource() !ziac.cockroach.sql_user.SqlUser {
    return ziac.cockroach.sql_user.SqlUser.build(std.testing.allocator, .{}, .{
        .cluster_id = "cluster-1",
        .username = "app_user",
        .connection_secret = ziac.SecretOutput(ziac.value.SecretReference).fromResource(
            "gcp.secret.SecretVersion.database-url.initial",
            "version",
        ),
    });
}

fn secretState() !ziac.InMemoryStateStore {
    var store = ziac.InMemoryStateStore.init(std.testing.allocator);
    errdefer store.deinit();
    try store.put(.{
        .resource_id = "gcp.secret.SecretVersion.database-url.initial",
        .provider = .gcp,
        .type_name = "gcp.secret.SecretVersion",
        .logical_id = "initial",
        .physical_id = "projects/ziac-dev/secrets/database-url/versions/7",
        .desired_hash = "hash",
        .outputs = &.{.{ .name = "version", .value = .{ .secret_ref = .{
            .provider = "gcp-secret-manager",
            .resource = "projects/ziac-dev/secrets/database-url",
            .version = "7",
        } } }},
        .status = .created,
    });
    return store;
}

fn users(comptime names: []const []const u8) zstd.Http.Response {
    comptime var body: []const u8 = "{\"users\":[";
    inline for (names, 0..) |name, index| body = body ++ (if (index == 0) "" else ",") ++ "{\"name\":\"" ++ name ++ "\"}";
    return .{ .status = 200, .body = body ++ "]}" };
}

fn ok() zstd.Http.Response {
    return .{ .status = 200, .body = "{}" };
}

fn okNoContent() zstd.Http.Response {
    return .{ .status = 204, .body = "" };
}

fn notFound() zstd.Http.Response {
    return .{ .status = 404, .body = "{\"message\":\"missing\"}" };
}
