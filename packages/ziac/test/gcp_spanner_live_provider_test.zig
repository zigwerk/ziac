const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;

test "Spanner instance lifecycle resumes LRO and normalizes autoscaling" {
    const before = instanceJson(5_000);
    const after = instanceJson(8_000);
    const responses = [_]zstd.Http.Response{
        notFound(),
        ok("{\"name\":\"projects/ziac-dev/instances/global-app/operations/create-1\",\"done\":false}"),
        ok("{\"name\":\"projects/ziac-dev/instances/global-app/operations/create-1\",\"done\":true}"),
        ok(before),
        ok(before),
        ok("{\"name\":\"projects/ziac-dev/instances/global-app/operations/update-1\",\"done\":false}"),
        ok("{\"name\":\"projects/ziac-dev/instances/global-app/operations/update-1\",\"done\":true}"),
        ok(after),
        ok("{\"name\":\"projects/ziac-dev/instances/global-app/operations/delete-1\",\"done\":false}"),
        ok("{\"name\":\"projects/ziac-dev/instances/global-app/operations/delete-1\",\"done\":true}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.spanner_provider.Handler{ .client = &harness.client, .operation_policy = .{ .poll_interval_millis = 0 } };
    var initial = try buildInstance(5_000);
    defer initial.deinit(std.testing.allocator);
    var changed = try buildInstance(8_000);
    defer changed.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var absent = try handler.read(&context, initial.node, null);
    defer absent.deinit();
    try std.testing.expect(absent == .absent);
    var pending = try handler.create(&context, initial.node);
    defer pending.deinit();
    try std.testing.expect(!pending.completed);
    context.operation_handle = pending.operation_handle;
    var created = try handler.read(&context, initial.node, null);
    defer created.deinit();
    context.operation_handle = null;
    try std.testing.expectEqualStrings("READY", outputString(created.present, "state"));
    var current = try handler.read(&context, initial.node, null);
    defer current.deinit();
    var diff = try ziac.gcp.spanner_provider.Handler.diff(&context, changed.node, &current.present);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, diff.kind);
    var update = try handler.update(&context, changed.node, &current.present);
    defer update.deinit();
    context.operation_handle = update.operation_handle;
    var updated = try handler.read(&context, changed.node, null);
    defer updated.deinit();
    context.operation_handle = null;
    try handler.delete(&context, changed.node, updated.present.physical_id);

    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[1].url, "/v1/projects/ziac-dev/instances"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"instanceId\":\"global-app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"maxProcessingUnits\":5000") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[5].url, "updateMask=autoscalingConfig") != null);
    try std.testing.expectEqualStrings("https://spanner.example.test/v1/projects/ziac-dev/instances/global-app/operations/delete-1", harness.transport.requests.items[9].url);
}

test "Spanner database lifecycle reads server DDL and updates it explicitly" {
    const database = "{\"name\":\"projects/ziac-dev/instances/global-app/databases/app\",\"state\":\"READY\",\"databaseDialect\":\"GOOGLE_STANDARD_SQL\",\"enableDropProtection\":true,\"versionRetentionPeriod\":\"7d\"}";
    const ddl_one = "{\"statements\":[\"CREATE TABLE users (id STRING(36) NOT NULL) PRIMARY KEY (id)\"]}";
    const ddl_two = "{\"statements\":[\"CREATE TABLE users (id STRING(36) NOT NULL) PRIMARY KEY (id)\",\"CREATE INDEX users_by_id ON users(id)\"]}";
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"projects/ziac-dev/instances/global-app/databaseOperations/create-db\",\"done\":false}"),
        ok("{\"name\":\"projects/ziac-dev/instances/global-app/databaseOperations/create-db\",\"done\":true}"),
        ok(database),
        ok(ddl_one),
        ok(database),
        ok(ddl_one),
        ok("{\"name\":\"projects/ziac-dev/instances/global-app/databaseOperations/update-ddl\",\"done\":false}"),
        ok("{\"name\":\"projects/ziac-dev/instances/global-app/databaseOperations/update-ddl\",\"done\":true}"),
        ok(database),
        ok(ddl_two),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.spanner_provider.Handler{ .client = &harness.client, .operation_policy = .{ .poll_interval_millis = 0 } };
    var first = try buildDatabase(&.{"CREATE TABLE users (id STRING(36) NOT NULL) PRIMARY KEY (id)"});
    defer first.deinit(std.testing.allocator);
    var second = try buildDatabase(&.{
        "CREATE TABLE users (id STRING(36) NOT NULL) PRIMARY KEY (id)",
        "CREATE INDEX users_by_id ON users(id)",
    });
    defer second.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.create(&context, first.node);
    defer pending.deinit();
    context.operation_handle = pending.operation_handle;
    var created = try handler.read(&context, first.node, null);
    defer created.deinit();
    context.operation_handle = null;
    var current = try handler.read(&context, first.node, null);
    defer current.deinit();
    var diff = try ziac.gcp.spanner_provider.Handler.diff(&context, second.node, &current.present);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, diff.kind);
    var changed = try handler.update(&context, second.node, &current.present);
    defer changed.deinit();
    context.operation_handle = changed.operation_handle;
    var updated = try handler.read(&context, second.node, null);
    defer updated.deinit();

    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "CREATE DATABASE `app`") != null);
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[3].url, "/v1/projects/ziac-dev/instances/global-app/databases/app/ddl"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[6].body, "CREATE INDEX users_by_id") != null);
}

test "Spanner database IAM member uses additive etag-safe policy updates" {
    const empty = "{\"version\":1,\"etag\":\"etag-a\",\"bindings\":[]}";
    const updated = "{\"version\":1,\"etag\":\"etag-b\",\"bindings\":[{\"role\":\"roles/spanner.databaseUser\",\"members\":[\"serviceAccount:api@ziac-dev.iam.gserviceaccount.com\"]}]}";
    const responses = [_]zstd.Http.Response{ ok(empty), ok(updated) };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var live = ziac.gcp.live_provider.LiveProvider.init(&harness.client);
    const provider = live.provider();
    var member = try ziac.gcp.spanner.DatabaseIamMember.build(std.testing.allocator, config(), .{
        .name = "api-database-user",
        .database = ziac.PublicOutput([]const u8).known("projects/ziac-dev/instances/global-app/databases/app"),
        .instance_id = "global-app",
        .database_id = "app",
        .role = "roles/spanner.databaseUser",
        .member = "serviceAccount:api@ziac-dev.iam.gserviceaccount.com",
    });
    defer member.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try provider.createWithContext(&context, member.node);
    defer created.deinit();

    try std.testing.expectEqualStrings(
        "https://spanner.example.test/v1/projects/ziac-dev/instances/global-app/databases/app:getIamPolicy",
        harness.transport.requests.items[0].url,
    );
    try std.testing.expectEqualStrings(
        "https://spanner.example.test/v1/projects/ziac-dev/instances/global-app/databases/app:setIamPolicy",
        harness.transport.requests.items[1].url,
    );
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"etag\":\"etag-a\"") != null);
}

test "Spanner backup CMEK uses the create query and remote encryption drives drift" {
    const remote = "{\"name\":\"projects/ziac-dev/instances/global-app/backups/app-release\",\"database\":\"projects/ziac-dev/instances/global-app/databases/app\",\"expireTime\":\"2027-07-13T12:00:00Z\",\"versionTime\":\"2026-07-13T12:00:00Z\",\"state\":\"READY\",\"sizeBytes\":\"4096\",\"encryptionInformation\":[{\"kmsKeyVersion\":\"projects/ziac-dev/locations/global/keyRings/data/cryptoKeys/remote/cryptoKeyVersions/1\"}]}";
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"projects/ziac-dev/instances/global-app/backups/app-release/operations/create-backup\",\"done\":false}"),
        ok(remote),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.spanner_provider.Handler{ .client = &harness.client };
    var backup = try buildBackup("projects/ziac-dev/locations/global/keyRings/data/cryptoKeys/desired");
    defer backup.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.create(&context, backup.node);
    defer pending.deinit();
    var observed = try handler.read(&context, backup.node, null);
    defer observed.deinit();
    var diff = try ziac.gcp.spanner_provider.Handler.diff(&context, backup.node, &observed.present);
    defer diff.deinit();

    const create_url = harness.transport.requests.items[0].url;
    try std.testing.expect(std.mem.indexOf(u8, create_url, "encryptionConfig.encryptionType=CUSTOMER_MANAGED_ENCRYPTION") != null);
    try std.testing.expect(std.mem.indexOf(u8, create_url, "encryptionConfig.kmsKeyNames=projects%2Fziac-dev%2Flocations%2Fglobal%2FkeyRings%2Fdata%2FcryptoKeys%2Fdesired") != null);
    try std.testing.expectEqual(ziac.provider.DiffKind.replace, diff.kind);
}

test "Spanner backup schedule sends CMEK and refresh detects remote key drift" {
    const remote = "{\"name\":\"projects/ziac-dev/instances/global-app/databases/app/backupSchedules/daily\",\"spec\":{\"cronSpec\":{\"text\":\"0 2 * * *\"}},\"retentionDuration\":\"1209600s\",\"fullBackupSpec\":{},\"encryptionConfig\":{\"encryptionType\":\"CUSTOMER_MANAGED_ENCRYPTION\",\"kmsKeyNames\":[\"projects/ziac-dev/locations/global/keyRings/data/cryptoKeys/remote\"]},\"updateTime\":\"2026-07-13T12:00:00Z\"}";
    const responses = [_]zstd.Http.Response{ ok(remote), ok(remote) };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.spanner_provider.Handler{ .client = &harness.client };
    var schedule = try buildSchedule("projects/ziac-dev/locations/global/keyRings/data/cryptoKeys/desired");
    defer schedule.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try handler.create(&context, schedule.node);
    defer created.deinit();
    var observed = try handler.read(&context, schedule.node, null);
    defer observed.deinit();
    var diff = try ziac.gcp.spanner_provider.Handler.diff(&context, schedule.node, &observed.present);
    defer diff.deinit();

    const create_body = harness.transport.requests.items[0].body;
    try std.testing.expect(std.mem.indexOf(u8, create_body, "\"encryptionType\":\"CUSTOMER_MANAGED_ENCRYPTION\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, create_body, "\"kmsKeyNames\":[\"projects/ziac-dev/locations/global/keyRings/data/cryptoKeys/desired\"]") != null);
    try std.testing.expectEqual(ziac.provider.DiffKind.update, diff.kind);
}

const Harness = struct {
    source: FixedTokenSource,
    cache: auth.TokenCache,
    transport: @import("gcp_client_test.zig").RecordingTransport,
    client: gclient.Client,

    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.source = .{};
        self.cache = auth.TokenCache.init(self.source.tokenSource(), 300);
        self.transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{ .spanner = "https://spanner.example.test" });
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

fn buildInstance(max: u32) !ziac.gcp.spanner.Instance {
    return ziac.gcp.spanner.Instance.build(std.testing.allocator, config(), .{
        .instance_id = "global-app",
        .config = "nam-eur-asia1",
        .display_name = "Global application",
        .edition = .enterprise_plus,
        .capacity = .{ .autoscaling_processing_units = .{ .min = 1_000, .max = max } },
        .labels = &.{
            .{ .key = "environment", .value = "prod" },
            .{ .key = "team", .value = "platform" },
        },
        .protect = false,
        .retain_on_delete = false,
    });
}

fn buildDatabase(ddl: []const []const u8) !ziac.gcp.spanner.Database {
    return ziac.gcp.spanner.Database.build(std.testing.allocator, config(), .{
        .database_id = "app",
        .instance = ziac.PublicOutput([]const u8).known("projects/ziac-dev/instances/global-app"),
        .instance_id = "global-app",
        .ddl = ddl,
        .version_retention_period = "7d",
        .drop_protection = true,
        .protect = false,
        .retain_on_delete = false,
    });
}

fn buildBackup(kms_key_name: []const u8) !ziac.gcp.spanner.Backup {
    return ziac.gcp.spanner.Backup.build(std.testing.allocator, config(), .{
        .backup_id = "app-release",
        .database = ziac.PublicOutput([]const u8).known("projects/ziac-dev/instances/global-app/databases/app"),
        .instance_id = "global-app",
        .database_id = "app",
        .expire_time = "2027-07-13T12:00:00Z",
        .version_time = "2026-07-13T12:00:00Z",
        .kms_key_name = kms_key_name,
        .protect = false,
        .retain_on_delete = false,
    });
}

fn buildSchedule(kms_key_name: []const u8) !ziac.gcp.spanner.BackupSchedule {
    return ziac.gcp.spanner.BackupSchedule.build(std.testing.allocator, config(), .{
        .schedule_id = "daily",
        .database = ziac.PublicOutput([]const u8).known("projects/ziac-dev/instances/global-app/databases/app"),
        .instance_id = "global-app",
        .database_id = "app",
        .cron = "0 2 * * *",
        .retention_seconds = 14 * 24 * 60 * 60,
        .kms_key_name = kms_key_name,
        .retain_on_delete = false,
    });
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
}

fn instanceJson(comptime max: u32) []const u8 {
    return std.fmt.comptimePrint("{{\"name\":\"projects/ziac-dev/instances/global-app\",\"config\":\"projects/ziac-dev/instanceConfigs/nam-eur-asia1\",\"displayName\":\"Global application\",\"state\":\"READY\",\"edition\":\"ENTERPRISE_PLUS\",\"defaultBackupScheduleType\":\"AUTOMATIC\",\"labels\":{{\"team\":\"platform\",\"environment\":\"prod\"}},\"autoscalingConfig\":{{\"autoscalingLimits\":{{\"minProcessingUnits\":1000,\"maxProcessingUnits\":{d}}},\"autoscalingTargets\":{{\"highPriorityCpuUtilizationPercent\":65,\"storageUtilizationPercent\":90}}}}}}", .{max});
}

fn outputString(result: ziac.provider.ResourceResult, name: []const u8) []const u8 {
    for (result.outputs) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value.string;
    unreachable;
}

fn ok(body: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = body };
}
fn notFound() zstd.Http.Response {
    return .{ .status = 404, .body = "{\"error\":{\"code\":404,\"status\":\"NOT_FOUND\"}}" };
}
