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
