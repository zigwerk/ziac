const std = @import("std");
const ziac = @import("ziac");
const support = @import("cockroach_sql_test_support.zig");

test "Cockroach database provider is read-before-write and lifecycle complete" {
    const responses = [_]support.Response{
        .{ .query = support.boolRows(false) },
        .{ .query = support.boolRows(false) },
        .{ .execute = .{} },
        .{ .query = support.boolRows(true) },
        .{ .query = support.boolRows(true) },
        .{ .execute = .{} },
        .{ .query = support.boolRows(false) },
        .{ .query = support.boolRows(true) },
    };
    var harness: support.Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var database = try databaseResource();
    defer database.deinit(std.testing.allocator);
    var store = try support.secretState();
    defer store.deinit();
    var context = support.contextWithState(&store);
    const provider = harness.live.provider();

    var before = try provider.readWithContext(&context, database.node);
    defer before.deinit();
    try std.testing.expect(before == .absent);
    var created = try provider.createWithContext(&context, database.node);
    defer created.deinit();
    try std.testing.expectEqualStrings("clusters/cluster-1/databases/app-data", created.physical_id);
    var present = try provider.readWithContext(&context, database.node);
    defer present.deinit();
    try std.testing.expectEqual(database.node.inputs_hash, present.present.observed_hash);
    var noop = try provider.diffWithContext(&context, database.node, &present.present);
    defer noop.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.noop, noop.kind);
    try provider.deleteWithContext(&context, database.node, created.physical_id);
    var gone = try provider.readWithContext(&context, database.node);
    defer gone.deinit();
    try std.testing.expect(gone == .absent);
    var imported = try provider.importWithContext(&context, database.node, created.physical_id);
    defer imported.deinit();

    try std.testing.expect(std.mem.indexOf(u8, harness.executor.operations.items[0].statement, "pg_database") != null);
    try std.testing.expectEqualStrings("CREATE DATABASE \"app-data\"", harness.executor.operations.items[2].statement);
    try std.testing.expectEqualStrings("DROP DATABASE \"app-data\"", harness.executor.operations.items[5].statement);
}

test "Cockroach grants provider reconciles exact direct database privileges" {
    const responses = [_]support.Response{
        .{ .query = support.empty_rows },
        .{ .query = support.empty_rows },
        .{ .execute = .{} },
        .{ .query = support.grantRows(&.{"CONNECT"}) },
        .{ .query = support.grantRows(&.{"CONNECT"}) },
        .{ .execute = .{} },
        .{ .query = support.grantRows(&.{ "CONNECT", "CREATE" }) },
        .{ .execute = .{} },
        .{ .query = support.empty_rows },
        .{ .query = support.grantRows(&.{ "CONNECT", "CREATE" }) },
    };
    var harness: support.Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var original = try grantsResource(&.{.connect});
    defer original.deinit(std.testing.allocator);
    var changed = try grantsResource(&.{ .connect, .create });
    defer changed.deinit(std.testing.allocator);
    var store = try support.secretState();
    defer store.deinit();
    var context = support.contextWithState(&store);
    const provider = harness.live.provider();

    var before = try provider.readWithContext(&context, original.node);
    defer before.deinit();
    try std.testing.expect(before == .absent);
    var created = try provider.createWithContext(&context, original.node);
    defer created.deinit();
    var current = try provider.readWithContext(&context, original.node);
    defer current.deinit();
    var diff = try provider.diffWithContext(&context, changed.node, &current.present);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, diff.kind);
    var updated = try provider.updateWithContext(&context, changed.node, &current.present);
    defer updated.deinit();
    try provider.deleteWithContext(&context, changed.node, updated.physical_id);
    var gone = try provider.readWithContext(&context, changed.node);
    defer gone.deinit();
    try std.testing.expect(gone == .absent);
    var imported = try provider.importWithContext(&context, changed.node, updated.physical_id);
    defer imported.deinit();

    try std.testing.expect(std.mem.indexOf(u8, harness.executor.operations.items[2].statement, "GRANT CONNECT") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.executor.operations.items[5].statement, "GRANT CREATE") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.executor.operations.items[7].statement, "REVOKE CONNECT, CREATE") != null);
}

test "Cockroach migration retries 40001 and stops on ambiguous 40003" {
    const retry_responses = [_]support.Response{
        .{ .query = support.boolRows(false) },
        .{ .failure = .{ .err = error.QueryFailed, .sqlstate = "40001" } },
        .{ .execute = .{} },
    };
    var retry_harness: support.Harness = undefined;
    retry_harness.init(&retry_responses);
    defer retry_harness.deinit();
    var migration = try migrationResource();
    defer migration.deinit(std.testing.allocator);
    var store = try support.secretState();
    defer store.deinit();
    var context = support.contextWithState(&store);
    var created = try retry_harness.live.provider().createWithContext(&context, migration.node);
    defer created.deinit();
    try std.testing.expectEqual(@as(usize, 3), retry_harness.executor.operations.items.len);
    const transaction = retry_harness.executor.operations.items[1].statement;
    try std.testing.expect(std.mem.indexOf(u8, transaction, "FOR UPDATE") != null);
    try std.testing.expect(std.mem.indexOf(u8, transaction, "create table projects") != null);

    const ambiguous_responses = [_]support.Response{
        .{ .query = support.boolRows(false) },
        .{ .failure = .{ .err = error.QueryFailed, .sqlstate = "40003", .outcome = .ambiguous } },
    };
    var ambiguous_harness: support.Harness = undefined;
    ambiguous_harness.init(&ambiguous_responses);
    defer ambiguous_harness.deinit();
    try std.testing.expectError(
        error.Conflict,
        ambiguous_harness.live.provider().createWithContext(&context, migration.node),
    );
    try std.testing.expectEqual(@as(usize, 2), ambiguous_harness.executor.operations.items.len);
}

test "Cockroach migration refresh verifies table existence and immutable checksum" {
    var migration = try migrationResource();
    defer migration.deinit(std.testing.allocator);
    const checksum = input(migration.node, "checksum").string;
    const checksum_cells = [_]support.sql.Cell{.{ .name = "checksum", .value = checksum }};
    const checksum_rows = [_]support.sql.Row{.{ .cells = &checksum_cells }};
    const responses = [_]support.Response{
        .{ .query = support.boolRows(false) },
        .{ .query = support.boolRows(false) },
        .{ .execute = .{} },
        .{ .query = support.boolRows(true) },
        .{ .query = &checksum_rows },
        .{ .query = support.boolRows(true) },
        .{ .query = &checksum_rows },
    };
    var harness: support.Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var store = try support.secretState();
    defer store.deinit();
    var context = support.contextWithState(&store);
    const provider = harness.live.provider();

    var before = try provider.readWithContext(&context, migration.node);
    defer before.deinit();
    try std.testing.expect(before == .absent);
    var created = try provider.createWithContext(&context, migration.node);
    defer created.deinit();
    var present = try provider.readWithContext(&context, migration.node);
    defer present.deinit();
    try std.testing.expectEqual(migration.node.inputs_hash, present.present.observed_hash);
    try provider.deleteWithContext(&context, migration.node, created.physical_id);
    var imported = try provider.importWithContext(&context, migration.node, created.physical_id);
    defer imported.deinit();

    try std.testing.expect(std.mem.indexOf(u8, harness.executor.operations.items[0].statement, "information_schema.tables") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.executor.operations.items[4].statement, "SELECT checksum") != null);

    const conflict_cells = [_]support.sql.Cell{.{ .name = "checksum", .value = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" }};
    const conflict_rows = [_]support.sql.Row{.{ .cells = &conflict_cells }};
    const conflict_responses = [_]support.Response{
        .{ .query = support.boolRows(true) },
        .{ .query = &conflict_rows },
    };
    var conflict_harness: support.Harness = undefined;
    conflict_harness.init(&conflict_responses);
    defer conflict_harness.deinit();
    try std.testing.expectError(error.Conflict, conflict_harness.live.provider().readWithContext(&context, migration.node));
}

test "Cockroach migration provider serializes concurrent callers" {
    const allocator = std.heap.smp_allocator;
    var executor = SerializationExecutor{};
    var secret_source = ConcurrentSecretSource{};
    var transport = @import("cockroach_client_test.zig").RecordingTransport.init(allocator, &.{});
    defer transport.deinit();
    var client = ziac.cockroach.client.Client.init(transport.client(), "dummy-key", .{});
    var live = ziac.cockroach.live_provider.LiveProvider.init(&client);
    live.secret_source = secret_source.secretSource();
    live.sql_executor = executor.executor();
    const provider = live.provider();
    var migration = try ziac.cockroach.migration.Migration.build(allocator, .{}, .{
        .cluster_id = "cluster-1",
        .database = "app-data",
        .id = "001_concurrent",
        .sql_text = "CREATE TABLE concurrent_gate (id UUID PRIMARY KEY)",
        .connection_secret = ziac.SecretOutput(ziac.value.SecretReference).known(.{
            .provider = "gcp-secret-manager",
            .resource = "projects/ziac-dev/secrets/database-url",
            .version = "7",
        }),
    });
    defer migration.deinit(allocator);

    var first = MigrationWorker{ .provider = provider, .node = &migration.node };
    var second = MigrationWorker{ .provider = provider, .node = &migration.node };
    const first_thread = try std.Thread.spawn(.{}, runMigrationWorker, .{&first});
    while (!executor.first_query_entered.load(.acquire)) std.atomic.spinLoopHint();
    const second_thread = std.Thread.spawn(.{}, runMigrationWorker, .{&second}) catch |err| {
        executor.release_first_query.store(true, .release);
        first_thread.join();
        return err;
    };
    std.testing.io.sleep(.fromMilliseconds(10), .awake) catch |err| {
        executor.release_first_query.store(true, .release);
        first_thread.join();
        second_thread.join();
        return err;
    };
    const query_calls_before_release = executor.query_calls.load(.acquire);
    const max_active_before_release = executor.max_active.load(.acquire);
    executor.release_first_query.store(true, .release);
    first_thread.join();
    second_thread.join();

    try std.testing.expectEqual(@as(usize, 1), query_calls_before_release);
    try std.testing.expectEqual(@as(usize, 1), max_active_before_release);
    try std.testing.expect(first.err == null);
    try std.testing.expect(second.err == null);
    try std.testing.expectEqual(@as(usize, 1), executor.max_active.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), executor.execute_calls.load(.acquire));
}

test "native executor applies SQL resources against explicitly configured CockroachDB" {
    var environment = try std.testing.environ.createMap(std.testing.allocator);
    defer environment.deinit();
    const admin_url = environment.get("ZIAC_COCKROACH_ADMIN_LIVE_URL") orelse return error.SkipZigTest;
    const app_url = environment.get("ZIAC_COCKROACH_APP_LIVE_URL") orelse return error.SkipZigTest;

    var executor = ziac.cockroach.native_executor.NativeExecutor.init(
        std.testing.allocator,
        std.testing.io,
        .{ .size = 2, .idle_validation_millis = 1 },
    );
    defer executor.deinit();
    var secrets = NativeLiveSecretSource{ .admin_url = admin_url, .app_url = app_url };
    var transport = @import("cockroach_client_test.zig").RecordingTransport.init(std.testing.allocator, &.{});
    defer transport.deinit();
    var client = ziac.cockroach.client.Client.init(transport.client(), "dummy-key", .{});
    var live = ziac.cockroach.live_provider.LiveProvider.init(&client);
    live.secret_source = secrets.secretSource();
    live.sql_executor = executor.executor();
    const provider = live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    const admin_connection = ziac.SecretOutput(ziac.value.SecretReference).known(.{
        .provider = "ziac-live-test",
        .resource = "admin",
    });
    const app_connection = ziac.SecretOutput(ziac.value.SecretReference).known(.{
        .provider = "ziac-live-test",
        .resource = "app",
    });
    var database = try ziac.cockroach.database.Database.build(std.testing.allocator, .{}, .{
        .cluster_id = "cluster-1",
        .name = "ziac_native_gate",
        .connection_secret = admin_connection,
        .protect = false,
    });
    defer database.deinit(std.testing.allocator);
    var grants = try ziac.cockroach.grants.Grants.build(std.testing.allocator, .{}, .{
        .cluster_id = "cluster-1",
        .database = "ziac_native_gate",
        .grantee = "app_user",
        .privileges = &.{ .connect, .create },
        .connection_secret = admin_connection,
    });
    defer grants.deinit(std.testing.allocator);
    var migration = try ziac.cockroach.migration.Migration.build(std.testing.allocator, .{}, .{
        .cluster_id = "cluster-1",
        .database = "ziac_native_gate",
        .id = "001_native_gate",
        .sql_text = "CREATE TABLE native_gate (id UUID PRIMARY KEY)",
        .connection_secret = app_connection,
    });
    defer migration.deinit(std.testing.allocator);

    var database_result = try provider.createWithContext(&context, database.node);
    defer database_result.deinit();
    var grants_result = try provider.createWithContext(&context, grants.node);
    defer grants_result.deinit();
    var migration_result = try provider.createWithContext(&context, migration.node);
    defer migration_result.deinit();
    var refreshed = try provider.readWithContext(&context, migration.node);
    defer refreshed.deinit();
    try std.testing.expect(refreshed == .present);

    try provider.deleteWithContext(&context, migration.node, migration_result.physical_id);
    try provider.deleteWithContext(&context, grants.node, grants_result.physical_id);
    try provider.deleteWithContext(&context, database.node, database_result.physical_id);
}

const SerializationExecutor = struct {
    active: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    max_active: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    query_calls: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    execute_calls: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    first_query_entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    release_first_query: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn executor(self: *SerializationExecutor) support.sql.Executor {
        return .{ .ptr = self, .queryFn = query, .executeFn = execute };
    }

    fn query(
        raw: *anyopaque,
        context: *ziac.provider.OperationContext,
        _: []const u8,
        _: []const u8,
        _: *support.sql.Diagnostic,
    ) support.sql.Error!support.sql.QueryResult {
        const self: *SerializationExecutor = @ptrCast(@alignCast(raw));
        self.enter();
        defer self.leave();
        const call = self.query_calls.fetchAdd(1, .acq_rel);
        if (call == 0) {
            self.first_query_entered.store(true, .release);
            while (!self.release_first_query.load(.acquire)) std.atomic.spinLoopHint();
        }
        const cells = [_]support.sql.Cell{.{ .name = "exists", .value = "false" }};
        const rows = [_]support.sql.Row{.{ .cells = &cells }};
        return support.sql.QueryResult.initOwned(context.allocator, &rows);
    }

    fn execute(
        raw: *anyopaque,
        _: *ziac.provider.OperationContext,
        _: []const u8,
        _: []const u8,
        _: *support.sql.Diagnostic,
    ) support.sql.Error!support.sql.ExecuteResult {
        const self: *SerializationExecutor = @ptrCast(@alignCast(raw));
        self.enter();
        defer self.leave();
        _ = self.execute_calls.fetchAdd(1, .acq_rel);
        return .{};
    }

    fn enter(self: *SerializationExecutor) void {
        const current = self.active.fetchAdd(1, .acq_rel) + 1;
        var observed = self.max_active.load(.acquire);
        while (current > observed) {
            observed = self.max_active.cmpxchgWeak(observed, current, .acq_rel, .acquire) orelse break;
        }
    }

    fn leave(self: *SerializationExecutor) void {
        _ = self.active.fetchSub(1, .acq_rel);
    }
};

const ConcurrentSecretSource = struct {
    fn secretSource(self: *ConcurrentSecretSource) ziac.secret.SecretSource {
        return .{ .ptr = self, .resolveFn = resolve };
    }

    fn resolve(
        _: *anyopaque,
        _: *ziac.provider.OperationContext,
        allocator: std.mem.Allocator,
        _: ziac.value.SecretReference,
    ) ziac.provider.ProviderError!ziac.secret.SecretPayload {
        return ziac.secret.SecretPayload.initOwned(
            allocator,
            "postgresql://app_user:sentinel-secret@db.example:26257/app-data?sslmode=verify-full",
            null,
        );
    }
};

const NativeLiveSecretSource = struct {
    admin_url: []const u8,
    app_url: []const u8,

    fn secretSource(self: *NativeLiveSecretSource) ziac.secret.SecretSource {
        return .{ .ptr = self, .resolveFn = resolve };
    }

    fn resolve(
        raw: *anyopaque,
        _: *ziac.provider.OperationContext,
        allocator: std.mem.Allocator,
        reference: ziac.value.SecretReference,
    ) ziac.provider.ProviderError!ziac.secret.SecretPayload {
        const self: *NativeLiveSecretSource = @ptrCast(@alignCast(raw));
        if (!std.mem.eql(u8, reference.provider, "ziac-live-test")) return error.NotFound;
        const url = if (std.mem.eql(u8, reference.resource, "admin"))
            self.admin_url
        else if (std.mem.eql(u8, reference.resource, "app"))
            self.app_url
        else
            return error.NotFound;
        return ziac.secret.SecretPayload.initOwned(allocator, url, null);
    }
};

const MigrationWorker = struct {
    provider: ziac.provider.Provider,
    node: *const ziac.ResourceNode,
    err: ?anyerror = null,
};

fn runMigrationWorker(worker: *MigrationWorker) void {
    var context = ziac.provider.OperationContext.init(std.heap.smp_allocator);
    var result = worker.provider.createWithContext(&context, worker.node.*) catch |err| {
        worker.err = err;
        return;
    };
    result.deinit();
}

fn databaseResource() !ziac.cockroach.database.Database {
    return ziac.cockroach.database.Database.build(std.testing.allocator, .{}, .{
        .cluster_id = "cluster-1",
        .name = "app-data",
        .connection_secret = support.connectionOutput(),
        .protect = false,
    });
}

fn grantsResource(privileges: []const ziac.cockroach.grants.Privilege) !ziac.cockroach.grants.Grants {
    return ziac.cockroach.grants.Grants.build(std.testing.allocator, .{}, .{
        .cluster_id = "cluster-1",
        .database = "app-data",
        .grantee = "app_user",
        .privileges = privileges,
        .connection_secret = support.connectionOutput(),
    });
}

fn migrationResource() !ziac.cockroach.migration.Migration {
    return ziac.cockroach.migration.Migration.build(std.testing.allocator, .{}, .{
        .cluster_id = "cluster-1",
        .database = "app-data",
        .id = "001_init",
        .sql_text = "create table projects(id uuid primary key)",
        .connection_secret = support.connectionOutput(),
    });
}

fn input(node: ziac.ResourceNode, name: []const u8) ziac.value.Value {
    for (node.inputs.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    unreachable;
}
