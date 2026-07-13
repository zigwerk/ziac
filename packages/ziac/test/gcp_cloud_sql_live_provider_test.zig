const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;

test "live Cloud SQL instance resumes operations and uses settings version" {
    const before = instanceJson("7", "db-custom-2-7680");
    const after = instanceJson("8", "db-custom-4-15360");
    const responses = [_]zstd.Http.Response{
        notFound(),
        ok("{\"name\":\"op-create\",\"status\":\"PENDING\"}"),
        ok("{\"name\":\"op-create\",\"status\":\"DONE\"}"),
        ok(before),
        ok(before),
        ok("{\"name\":\"op-update\",\"status\":\"PENDING\"}"),
        ok("{\"name\":\"op-update\",\"status\":\"DONE\"}"),
        ok(after),
        ok("{\"name\":\"op-delete\",\"status\":\"PENDING\"}"),
        ok("{\"name\":\"op-delete\",\"status\":\"DONE\"}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var instance = try buildInstance("db-custom-2-7680");
    defer instance.deinit(std.testing.allocator);
    var changed = try buildInstance("db-custom-4-15360");
    defer changed.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var absent = try live.readWithContext(&context, instance.node);
    defer absent.deinit();
    try std.testing.expect(absent == .absent);
    var pending = try live.createWithContext(&context, instance.node);
    defer pending.deinit();
    try std.testing.expect(!pending.completed);
    try std.testing.expectEqualStrings("op-create", pending.operation_handle.?);
    context.operation_handle = pending.operation_handle;
    var created = try live.readWithContext(&context, instance.node);
    defer created.deinit();
    context.operation_handle = null;
    try std.testing.expectEqualStrings("ziac-dev:europe-west1:orders-primary", outputString(created.present, "connection_name"));
    try std.testing.expectEqual(@as(i64, 7), outputInteger(created.present, "settings_version"));
    var read = try live.readWithContext(&context, instance.node);
    defer read.deinit();
    var diff = try live.diffWithContext(&context, changed.node, &read.present);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, diff.kind);
    var update = try live.updateWithContext(&context, changed.node, &read.present);
    defer update.deinit();
    context.operation_handle = update.operation_handle;
    var updated = try live.readWithContext(&context, changed.node);
    defer updated.deinit();
    context.operation_handle = null;
    try live.deleteWithContext(&context, changed.node, updated.present.physical_id);

    try std.testing.expectEqualStrings("POST", harness.transport.requests.items[1].method);
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[1].url, "/v1/projects/ziac-dev/instances"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"databaseVersion\":\"POSTGRES_17\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[5].body, "\"settingsVersion\":\"7\"") != null);
    try std.testing.expectEqualStrings("https://sqladmin.example.test/v1/projects/ziac-dev/operations/op-delete", harness.transport.requests.items[9].url);
}

test "live Cloud SQL provider manages databases and password-backed IAM users" {
    const database = "{\"name\":\"orders\",\"instance\":\"orders-primary\",\"project\":\"ziac-dev\",\"charset\":\"UTF8\",\"collation\":\"en_US.UTF8\",\"selfLink\":\"https://sqladmin.googleapis.com/v1/projects/ziac-dev/instances/orders-primary/databases/orders\"}";
    const user = "{\"name\":\"app\",\"instance\":\"orders-primary\",\"project\":\"ziac-dev\",\"type\":\"BUILT_IN\"}";
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"op-db\",\"status\":\"PENDING\"}"),
        ok("{\"name\":\"op-db\",\"status\":\"DONE\"}"),
        ok(database),
        ok(database),
        ok("{\"name\":\"op-user\",\"status\":\"PENDING\"}"),
        ok("{\"name\":\"op-user\",\"status\":\"DONE\"}"),
        ok(user),
        ok(user),
        ok("{\"name\":\"op-user-delete\",\"status\":\"DONE\"}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var source = FixedSecretSource{};
    harness.live.secret_source = source.secretSource();
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var database_resource = try ziac.gcp.sql.Database.build(std.testing.allocator, config(), .{
        .instance_id = "orders-primary",
        .name = "orders",
        .retain_on_delete = false,
    });
    defer database_resource.deinit(std.testing.allocator);
    var database_pending = try live.createWithContext(&context, database_resource.node);
    defer database_pending.deinit();
    context.operation_handle = database_pending.operation_handle;
    var database_created = try live.readWithContext(&context, database_resource.node);
    defer database_created.deinit();
    context.operation_handle = null;
    var database_imported = try live.importWithContext(&context, database_resource.node, "projects/ziac-dev/instances/orders-primary/databases/orders");
    defer database_imported.deinit();

    var user_resource = try ziac.gcp.sql.User.build(std.testing.allocator, config(), .{
        .instance_id = "orders-primary",
        .name = "app",
        .password = ziac.SecretOutput(ziac.value.SecretReference).known(.{
            .provider = "gcp-secret-manager",
            .resource = "projects/ziac-dev/secrets/orders-password",
            .version = "4",
        }),
    });
    defer user_resource.deinit(std.testing.allocator);
    var user_pending = try live.createWithContext(&context, user_resource.node);
    defer user_pending.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[4].body, "s3cr3t-password") != null);
    context.operation_handle = user_pending.operation_handle;
    var user_created = try live.readWithContext(&context, user_resource.node);
    defer user_created.deinit();
    context.operation_handle = null;
    var user_imported = try live.importWithContext(&context, user_resource.node, "projects/ziac-dev/instances/orders-primary/users/BUILT_IN/app");
    defer user_imported.deinit();
    try live.deleteWithContext(&context, user_resource.node, user_imported.physical_id);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[7].url, "/users/app?host=") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[8].url, "name=app") != null);
}

test "live Cloud SQL client certificates persist private keys only in Secret Manager" {
    const cert = "{\"certInfo\":{\"cert\":\"PUBLIC-CERT\",\"commonName\":\"orders-api\",\"expirationTime\":\"2027-07-13T00:00:00Z\",\"sha1Fingerprint\":\"AABBCC\"},\"certPrivateKey\":\"PRIVATE-KEY-PEM\"}";
    const responses = [_]zstd.Http.Response{
        ok("{\"operation\":{\"name\":\"op-cert\",\"status\":\"PENDING\"},\"clientCert\":" ++ cert ++ "}"),
        ok("{\"name\":\"projects/ziac-dev/secrets/orders-client-key/versions/9\"}"),
        ok("{\"name\":\"op-cert\",\"status\":\"DONE\"}"),
        ok("{\"cert\":\"PUBLIC-CERT\",\"commonName\":\"orders-api\",\"expirationTime\":\"2027-07-13T00:00:00Z\",\"sha1Fingerprint\":\"AABBCC\"}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var certificate = try ziac.gcp.sql.ClientCertificate.build(std.testing.allocator, config(), .{
        .instance_id = "orders-primary",
        .common_name = "orders-api",
        .private_key_secret = ziac.PublicOutput([]const u8).known("projects/ziac-dev/secrets/orders-client-key"),
    });
    defer certificate.deinit(std.testing.allocator);
    var pending = try live.createWithContext(&context, certificate.node);
    defer pending.deinit();
    try std.testing.expect(!pending.completed);
    try std.testing.expectEqualStrings("AABBCC", outputString(pending, "sha1_fingerprint"));
    try std.testing.expect(outputValue(pending, "private_key_version") == .secret_ref);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].url, "/v1/projects/ziac-dev/secrets/orders-client-key:addVersion") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "PRIVATE-KEY-PEM") == null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "UFJJVkFURS1LRVktUEVN") != null);
    try std.testing.expect(std.mem.indexOf(u8, pending.physical_id, "AABBCC") != null);
}

test "Cloud SQL certificate persistence failure surfaces redacted recovery identity" {
    const responses = [_]zstd.Http.Response{
        ok("{\"operation\":{\"name\":\"op-cert-recover\",\"status\":\"PENDING\"},\"clientCert\":{\"certInfo\":{\"cert\":\"PUBLIC-CERT\",\"sha1Fingerprint\":\"DDEEFF\"},\"certPrivateKey\":\"PRIVATE-KEY-PEM\"}}"),
        .{ .status = 503, .body = "{\"error\":{\"code\":503,\"status\":\"UNAVAILABLE\"}}" },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var diagnostics = ziac.provider.ProviderDiagnosticRecorder.init(std.testing.allocator);
    defer diagnostics.deinit();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    context.diagnostics = &diagnostics;
    var certificate = try ziac.gcp.sql.ClientCertificate.build(std.testing.allocator, config(), .{
        .instance_id = "orders-primary",
        .common_name = "orders-api",
        .private_key_secret = ziac.PublicOutput([]const u8).known("projects/ziac-dev/secrets/orders-client-key"),
    });
    defer certificate.deinit(std.testing.allocator);

    try std.testing.expectError(error.TransientFailure, harness.live.provider().createWithContext(&context, certificate.node));
    const maybe_diagnostic = try diagnostics.snapshotAlloc(std.testing.allocator);
    try std.testing.expect(maybe_diagnostic != null);
    var diagnostic = maybe_diagnostic.?;
    defer diagnostic.deinit();
    try std.testing.expectEqualStrings("op-cert-recover", diagnostic.request_id.?);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message.?, "DDEEFF") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message.?, "PRIVATE-KEY-PEM") == null);
}

const Harness = struct {
    source: FixedTokenSource,
    cache: auth.TokenCache,
    transport: @import("gcp_client_test.zig").RecordingTransport,
    client: gclient.Client,
    live: ziac.gcp.live_provider.LiveProvider,

    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.source = .{};
        self.cache = auth.TokenCache.init(self.source.tokenSource(), 300);
        self.transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{
            .sql_admin = "https://sqladmin.example.test",
            .secret_manager = "https://secretmanager.example.test",
        });
        self.live = ziac.gcp.live_provider.LiveProvider.init(&self.client);
        self.live.operation_policy.poll_interval_millis = 0;
    }

    fn deinit(self: *Harness) void {
        self.transport.deinit();
        self.cache.deinit(std.testing.allocator);
    }
};

const FixedTokenSource = struct {
    fn tokenSource(self: *FixedTokenSource) auth.TokenSource {
        return .{ .ptr = self, .fetchFn = fetch };
    }

    fn fetch(_: *anyopaque, allocator: std.mem.Allocator, now: u64) auth.AuthError!auth.AccessToken {
        return auth.AccessToken.initOwned(allocator, .{ .access_token = "token", .token_type = "Bearer", .expires_at_seconds = now + 3600 });
    }
};

const FixedSecretSource = struct {
    fn secretSource(self: *FixedSecretSource) ziac.secret.SecretSource {
        return .{ .ptr = self, .resolveFn = resolve };
    }

    fn resolve(_: *anyopaque, _: *ziac.provider.OperationContext, allocator: std.mem.Allocator, _: ziac.value.SecretReference) ziac.provider.ProviderError!ziac.secret.SecretPayload {
        return ziac.secret.SecretPayload.initOwned(allocator, "s3cr3t-password", null);
    }
};

fn buildInstance(tier: []const u8) !ziac.gcp.sql.Instance {
    return ziac.gcp.sql.Instance.build(std.testing.allocator, config(), .{
        .instance_id = "orders-primary",
        .database_version = .postgres_17,
        .region = "europe-west1",
        .tier = tier,
        .availability = .regional,
        .point_in_time_recovery = true,
        .private_network = "projects/host/global/networks/platform",
        .allocated_ip_range = "cloudsql-range",
        .deletion_protection = false,
        .protect = false,
        .retain_on_delete = false,
    });
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
}

fn instanceJson(comptime settings_version: []const u8, comptime tier: []const u8) []const u8 {
    return "{\"name\":\"orders-primary\",\"connectionName\":\"ziac-dev:europe-west1:orders-primary\",\"databaseVersion\":\"POSTGRES_17\",\"region\":\"europe-west1\",\"state\":\"RUNNABLE\",\"deletionProtectionEnabled\":false,\"settings\":{\"settingsVersion\":\"" ++ settings_version ++ "\",\"tier\":\"" ++ tier ++ "\",\"edition\":\"ENTERPRISE\",\"availabilityType\":\"REGIONAL\",\"dataDiskType\":\"PD_SSD\",\"dataDiskSizeGb\":\"20\",\"storageAutoResize\":true,\"backupConfiguration\":{\"enabled\":true,\"startTime\":\"03:00\",\"pointInTimeRecoveryEnabled\":true,\"backupRetentionSettings\":{\"retainedBackups\":7},\"transactionLogRetentionDays\":7},\"databaseFlags\":[],\"ipConfiguration\":{\"ipv4Enabled\":false,\"privateNetwork\":\"projects/host/global/networks/platform\",\"allocatedIpRange\":\"cloudsql-range\",\"enablePrivatePathForGoogleCloudServices\":false,\"sslMode\":\"ENCRYPTED_ONLY\",\"authorizedNetworks\":[]},\"connectorEnforcement\":\"NOT_REQUIRED\"},\"ipAddresses\":[{\"type\":\"PRIVATE\",\"ipAddress\":\"10.20.0.3\"}],\"serverCaCert\":{\"cert\":\"SERVER-CA\"}}";
}

fn outputValue(result: ziac.provider.ResourceResult, name: []const u8) ziac.value.Value {
    for (result.outputs) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value;
    unreachable;
}

fn outputString(result: ziac.provider.ResourceResult, name: []const u8) []const u8 {
    return switch (outputValue(result, name)) {
        .string => |text| text,
        else => unreachable,
    };
}

fn outputInteger(result: ziac.provider.ResourceResult, name: []const u8) i64 {
    return switch (outputValue(result, name)) {
        .integer => |integer| integer,
        else => unreachable,
    };
}

fn ok(body: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = body };
}

fn notFound() zstd.Http.Response {
    return .{ .status = 404, .body = "{\"error\":{\"code\":404,\"status\":\"NOT_FOUND\"}}" };
}
