const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;

test "live Firestore database provider resumes LROs and preserves etag preconditions" {
    const database_before =
        "{\"name\":\"projects/ziac-dev/databases/global-app\",\"uid\":\"db-uid\",\"locationId\":\"eur3\",\"type\":\"FIRESTORE_NATIVE\",\"concurrencyMode\":\"PESSIMISTIC\",\"pointInTimeRecoveryEnablement\":\"POINT_IN_TIME_RECOVERY_ENABLED\",\"deleteProtectionState\":\"DELETE_PROTECTION_DISABLED\",\"cmekConfig\":{\"kmsKeyName\":\"projects/ziac-dev/locations/eur3/keyRings/data/cryptoKeys/firestore\"},\"etag\":\"etag-1\",\"state\":\"ACTIVE\",\"edition\":\"STANDARD\",\"realtimeUpdatesMode\":\"REALTIME_UPDATES_MODE_ENABLED\"}";
    const database_after =
        "{\"name\":\"projects/ziac-dev/databases/global-app\",\"uid\":\"db-uid\",\"locationId\":\"eur3\",\"type\":\"FIRESTORE_NATIVE\",\"concurrencyMode\":\"PESSIMISTIC\",\"pointInTimeRecoveryEnablement\":\"POINT_IN_TIME_RECOVERY_DISABLED\",\"deleteProtectionState\":\"DELETE_PROTECTION_DISABLED\",\"cmekConfig\":{\"kmsKeyName\":\"projects/ziac-dev/locations/eur3/keyRings/data/cryptoKeys/firestore\"},\"etag\":\"etag-2\",\"state\":\"ACTIVE\",\"edition\":\"STANDARD\",\"realtimeUpdatesMode\":\"REALTIME_UPDATES_MODE_ENABLED\"}";
    const responses = [_]zstd.Http.Response{
        notFound(),
        ok("{\"name\":\"projects/ziac-dev/databases/global-app/operations/create\",\"done\":false}"),
        ok("{\"name\":\"projects/ziac-dev/databases/global-app/operations/create\",\"done\":true,\"response\":" ++ database_before ++ "}"),
        ok(database_before),
        ok("{\"name\":\"projects/ziac-dev/databases/global-app/operations/update\",\"done\":false}"),
        ok("{\"name\":\"projects/ziac-dev/databases/global-app/operations/update\",\"done\":true,\"response\":" ++ database_after ++ "}"),
        ok(database_after),
        ok("{\"name\":\"projects/ziac-dev/databases/global-app/operations/delete\",\"done\":false}"),
        ok("{\"name\":\"projects/ziac-dev/databases/global-app/operations/delete\",\"done\":true,\"response\":{}}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var database = try buildDatabase(true);
    defer database.deinit(std.testing.allocator);
    var changed = try buildDatabase(false);
    defer changed.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var absent = try live.readWithContext(&context, database.node);
    defer absent.deinit();
    try std.testing.expect(absent == .absent);
    var pending = try live.createWithContext(&context, database.node);
    defer pending.deinit();
    try std.testing.expect(!pending.completed);
    context.operation_handle = pending.operation_handle;
    var created = try live.readWithContext(&context, database.node);
    defer created.deinit();
    context.operation_handle = null;
    try std.testing.expectEqualStrings("etag-1", outputString(created.present, "etag"));
    var read = try live.readWithContext(&context, database.node);
    defer read.deinit();
    var diff = try live.diffWithContext(&context, changed.node, &read.present);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, diff.kind);
    var update = try live.updateWithContext(&context, changed.node, &read.present);
    defer update.deinit();
    try std.testing.expect(!update.completed);
    context.operation_handle = update.operation_handle;
    var updated = try live.readWithContext(&context, changed.node);
    defer updated.deinit();
    context.operation_handle = null;
    try std.testing.expectEqualStrings("etag-2", outputString(updated.present, "etag"));
    try live.deleteWithContext(&context, changed.node, updated.present.physical_id);

    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].url, "databaseId=global-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[4].url, "updateMask=concurrencyMode,pointInTimeRecoveryEnablement,deleteProtectionState,realtimeUpdatesMode") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[4].body, "\"etag\":\"etag-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[7].url, "etag=etag-2") != null);
}

test "live Firestore provider manages indexes field overrides and backup schedules" {
    const index_json =
        "{\"name\":\"projects/ziac-dev/databases/global-app/collectionGroups/matches/indexes/CICAgOjXh4EK\",\"queryScope\":\"COLLECTION_GROUP\",\"apiScope\":\"ANY_API\",\"fields\":[{\"fieldPath\":\"status\",\"order\":\"ASCENDING\"}],\"state\":\"READY\"}";
    const field_with_ttl =
        "{\"name\":\"projects/ziac-dev/databases/global-app/collectionGroups/sessions/fields/expires_at\",\"indexConfig\":{\"indexes\":[{\"order\":\"ASCENDING\",\"queryScope\":\"COLLECTION_GROUP\"}]},\"ttlConfig\":{\"state\":\"ACTIVE\"}}";
    const field_without_ttl =
        "{\"name\":\"projects/ziac-dev/databases/global-app/collectionGroups/sessions/fields/expires_at\",\"indexConfig\":{\"indexes\":[{\"order\":\"ASCENDING\",\"queryScope\":\"COLLECTION_GROUP\"}]}}";
    const backup_before =
        "{\"name\":\"projects/ziac-dev/databases/global-app/backupSchedules/1e3c4d5f\",\"retention\":\"4838400s\",\"dailyRecurrence\":{},\"createTime\":\"2026-07-13T10:00:00Z\"}";
    const backup_after =
        "{\"name\":\"projects/ziac-dev/databases/global-app/backupSchedules/1e3c4d5f\",\"retention\":\"6048000s\",\"dailyRecurrence\":{},\"createTime\":\"2026-07-13T10:00:00Z\"}";
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"projects/ziac-dev/databases/global-app/operations/create-index\",\"done\":false}"),
        ok("{\"name\":\"projects/ziac-dev/databases/global-app/operations/create-index\",\"done\":true,\"response\":" ++ index_json ++ "}"),
        ok(index_json),
        ok("{}"),
        ok("{\"name\":\"projects/ziac-dev/databases/global-app/operations/update-field\",\"done\":false}"),
        ok("{\"name\":\"projects/ziac-dev/databases/global-app/operations/update-field\",\"done\":true,\"response\":" ++ field_with_ttl ++ "}"),
        ok("{\"name\":\"projects/ziac-dev/databases/global-app/operations/disable-ttl\",\"done\":false}"),
        ok("{\"name\":\"projects/ziac-dev/databases/global-app/operations/disable-ttl\",\"done\":true,\"response\":" ++ field_without_ttl ++ "}"),
        ok("{\"name\":\"projects/ziac-dev/databases/global-app/operations/revert-field\",\"done\":false}"),
        ok("{\"name\":\"projects/ziac-dev/databases/global-app/operations/revert-field\",\"done\":true,\"response\":" ++ field_without_ttl ++ "}"),
        ok(backup_before),
        ok(backup_before),
        ok(backup_after),
        ok("{}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    const database = ziac.PublicOutput([]const u8).known("projects/ziac-dev/databases/global-app");

    var index = try ziac.gcp.firestore.Index.build(std.testing.allocator, config(), .{
        .database = database,
        .database_id = "global-app",
        .collection_group = "matches",
        .query_scope = .collection_group,
        .fields = &.{.{ .field_path = "status", .mode = .ascending }},
    });
    defer index.deinit(std.testing.allocator);
    var index_absent = try live.readWithContext(&context, index.node);
    defer index_absent.deinit();
    try std.testing.expect(index_absent == .absent);
    var index_pending = try live.createWithContext(&context, index.node);
    defer index_pending.deinit();
    context.operation_handle = index_pending.operation_handle;
    var index_created = try live.readWithContext(&context, index.node);
    defer index_created.deinit();
    context.operation_handle = null;
    var imported_index = try live.importWithContext(&context, index.node, index_created.present.physical_id);
    defer imported_index.deinit();
    try live.deleteWithContext(&context, index.node, imported_index.physical_id);

    var field = try buildField(true);
    defer field.deinit(std.testing.allocator);
    var changed_field = try buildField(false);
    defer changed_field.deinit(std.testing.allocator);
    var field_pending = try live.createWithContext(&context, field.node);
    defer field_pending.deinit();
    context.operation_handle = field_pending.operation_handle;
    var field_created = try live.readWithContext(&context, field.node);
    defer field_created.deinit();
    context.operation_handle = null;
    var field_diff = try live.diffWithContext(&context, changed_field.node, &field_created.present);
    defer field_diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, field_diff.kind);
    var field_update = try live.updateWithContext(&context, changed_field.node, &field_created.present);
    defer field_update.deinit();
    context.operation_handle = field_update.operation_handle;
    var field_updated = try live.readWithContext(&context, changed_field.node);
    defer field_updated.deinit();
    context.operation_handle = null;
    try live.deleteWithContext(&context, changed_field.node, field_updated.present.physical_id);

    var backup = try buildBackup(8 * 7 * 24 * 60 * 60);
    defer backup.deinit(std.testing.allocator);
    var changed_backup = try buildBackup(10 * 7 * 24 * 60 * 60);
    defer changed_backup.deinit(std.testing.allocator);
    var backup_created = try live.createWithContext(&context, backup.node);
    defer backup_created.deinit();
    context.physical_id = backup_created.physical_id;
    var backup_read = try live.readWithContext(&context, backup.node);
    defer backup_read.deinit();
    var backup_diff = try live.diffWithContext(&context, changed_backup.node, &backup_read.present);
    defer backup_diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, backup_diff.kind);
    var backup_updated = try live.updateWithContext(&context, changed_backup.node, &backup_read.present);
    defer backup_updated.deinit();
    try live.deleteWithContext(&context, changed_backup.node, backup_updated.physical_id);
    context.physical_id = null;

    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[0].url, "/v1/projects/ziac-dev/databases/global-app/collectionGroups/matches/indexes"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[4].url, "updateMask=indexConfig,ttlConfig") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[8].body, "indexConfig") == null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[12].url, "updateMask=retention,recurrence") != null);
}

test "live Firestore reads expose remote subordinate drift and database IAM uses Firestore policy RPCs" {
    const index_remote =
        "{\"name\":\"projects/ziac-dev/databases/global-app/collectionGroups/matches/indexes/remote\",\"queryScope\":\"COLLECTION_GROUP\",\"apiScope\":\"ANY_API\",\"fields\":[{\"fieldPath\":\"status\",\"order\":\"DESCENDING\"}],\"state\":\"READY\"}";
    const field_remote =
        "{\"name\":\"projects/ziac-dev/databases/global-app/collectionGroups/sessions/fields/expires_at\",\"indexConfig\":{\"indexes\":[{\"order\":\"ASCENDING\",\"queryScope\":\"COLLECTION_GROUP\"}]}}";
    const backup_remote =
        "{\"name\":\"projects/ziac-dev/databases/global-app/backupSchedules/remote\",\"retention\":\"2419200s\",\"dailyRecurrence\":{},\"createTime\":\"2026-07-13T10:00:00Z\"}";
    const responses = [_]zstd.Http.Response{
        ok(index_remote),
        ok(field_remote),
        ok(backup_remote),
        ok("{\"version\":3,\"bindings\":[],\"etag\":\"BwY=\"}"),
        ok("{\"version\":3,\"bindings\":[{\"role\":\"roles/datastore.viewer\",\"members\":[\"serviceAccount:api@ziac-dev.iam.gserviceaccount.com\"]}],\"etag\":\"BwZ=\"}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    const database = ziac.PublicOutput([]const u8).known("projects/ziac-dev/databases/global-app");

    var index = try ziac.gcp.firestore.Index.build(std.testing.allocator, config(), .{
        .database = database,
        .database_id = "global-app",
        .collection_group = "matches",
        .query_scope = .collection_group,
        .fields = &.{.{ .field_path = "status", .mode = .ascending }},
    });
    defer index.deinit(std.testing.allocator);
    context.physical_id = "projects/ziac-dev/databases/global-app/collectionGroups/matches/indexes/remote";
    var index_read = try live.readWithContext(&context, index.node);
    defer index_read.deinit();
    var index_diff = try live.diffWithContext(&context, index.node, &index_read.present);
    defer index_diff.deinit();
    if (index_diff.kind != .replace) return error.IndexDriftNotDetected;

    var field = try buildField(true);
    defer field.deinit(std.testing.allocator);
    context.physical_id = null;
    var field_read = try live.readWithContext(&context, field.node);
    defer field_read.deinit();
    var field_diff = try live.diffWithContext(&context, field.node, &field_read.present);
    defer field_diff.deinit();
    if (field_diff.kind != .update) return error.FieldDriftNotDetected;

    var backup = try buildBackup(8 * 7 * 24 * 60 * 60);
    defer backup.deinit(std.testing.allocator);
    context.physical_id = "projects/ziac-dev/databases/global-app/backupSchedules/remote";
    var backup_read = try live.readWithContext(&context, backup.node);
    defer backup_read.deinit();
    var backup_diff = try live.diffWithContext(&context, backup.node, &backup_read.present);
    defer backup_diff.deinit();
    if (backup_diff.kind != .update) return error.BackupDriftNotDetected;

    var member = try ziac.gcp.firestore.DatabaseIamMember.build(std.testing.allocator, config(), .{
        .name = "api-reader",
        .database = database,
        .database_id = "global-app",
        .role = "roles/datastore.viewer",
        .member = "serviceAccount:api@ziac-dev.iam.gserviceaccount.com",
    });
    defer member.deinit(std.testing.allocator);
    context.physical_id = null;
    var created = try live.createWithContext(&context, member.node);
    defer created.deinit();
    try std.testing.expectEqualStrings("https://firestore.example.test/v1/projects/ziac-dev/databases/global-app:getIamPolicy", harness.transport.requests.items[3].url);
    try std.testing.expectEqualStrings("https://firestore.example.test/v1/projects/ziac-dev/databases/global-app:setIamPolicy", harness.transport.requests.items[4].url);
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
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{ .firestore = "https://firestore.example.test" });
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

fn buildDatabase(point_in_time_recovery: bool) !ziac.gcp.firestore.Database {
    return ziac.gcp.firestore.Database.build(std.testing.allocator, .{ .project_id = "ziac-dev", .primary_region = "europe-west1" }, .{
        .database_id = "global-app",
        .location = "eur3",
        .point_in_time_recovery = point_in_time_recovery,
        .delete_protection = false,
        .kms_key_name = "projects/ziac-dev/locations/eur3/keyRings/data/cryptoKeys/firestore",
        .protect = false,
        .retain_on_delete = false,
    });
}

fn buildField(ttl_enabled: bool) !ziac.gcp.firestore.Field {
    return ziac.gcp.firestore.Field.build(std.testing.allocator, config(), .{
        .database = ziac.PublicOutput([]const u8).known("projects/ziac-dev/databases/global-app"),
        .database_id = "global-app",
        .collection_group = "sessions",
        .field_path = "expires_at",
        .ttl_enabled = ttl_enabled,
        .index_modes = &.{.ascending},
    });
}

fn buildBackup(retention_seconds: u64) !ziac.gcp.firestore.BackupSchedule {
    return ziac.gcp.firestore.BackupSchedule.build(std.testing.allocator, config(), .{
        .name = "daily",
        .database = ziac.PublicOutput([]const u8).known("projects/ziac-dev/databases/global-app"),
        .database_id = "global-app",
        .recurrence = .daily,
        .retention_seconds = retention_seconds,
    });
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
}

fn outputString(result: ziac.provider.ResourceResult, name: []const u8) []const u8 {
    for (result.outputs) |entry| if (std.mem.eql(u8, entry.name, name)) return switch (entry.value) {
        .string => |text| text,
        else => unreachable,
    };
    unreachable;
}

fn ok(body: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = body };
}

fn notFound() zstd.Http.Response {
    return .{ .status = 404, .body = "{\"error\":{\"code\":404,\"status\":\"NOT_FOUND\"}}" };
}
