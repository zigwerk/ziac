const std = @import("std");
const ziac = @import("ziac");

const connection = ziac.SecretOutput(ziac.value.SecretReference).fromResource(
    "gcp.secretmanager.SecretVersion.database.initial",
    "version",
);

test "Cockroach SQL helpers quote identifiers and literals without accepting NUL" {
    const identifier = try ziac.cockroach.sql.quoteIdentifierAlloc(std.testing.allocator, "odd\"database");
    defer std.testing.allocator.free(identifier);
    try std.testing.expectEqualStrings("\"odd\"\"database\"", identifier);

    const literal = try ziac.cockroach.sql.quoteLiteralAlloc(std.testing.allocator, "migration's checksum");
    defer std.testing.allocator.free(literal);
    try std.testing.expectEqualStrings("'migration''s checksum'", literal);

    try std.testing.expectError(error.InvalidIdentifier, ziac.cockroach.sql.quoteIdentifierAlloc(
        std.testing.allocator,
        "bad\x00name",
    ));
    try std.testing.expectError(error.InvalidLiteral, ziac.cockroach.sql.quoteLiteralAlloc(
        std.testing.allocator,
        "bad\x00value",
    ));
}

test "Cockroach SQL diagnostics retain only SQLSTATE and outcome" {
    var diagnostic = ziac.cockroach.sql.Diagnostic{};
    try diagnostic.setSqlstate("40001");
    try std.testing.expectEqualStrings("40001", diagnostic.sqlstateSlice().?);
    try std.testing.expectEqual(ziac.cockroach.sql.Outcome.definite, diagnostic.outcome);
    diagnostic.outcome = .ambiguous;
    diagnostic.reset();
    try std.testing.expect(diagnostic.sqlstateSlice() == null);
    try std.testing.expectEqual(ziac.cockroach.sql.Outcome.definite, diagnostic.outcome);
    try std.testing.expectError(error.InvalidSqlstate, diagnostic.setSqlstate("4000"));
}

test "Cockroach database is protected and retains a typed connection secret" {
    var database = try ziac.cockroach.database.Database.build(std.testing.allocator, .{}, .{
        .cluster_id = "cluster-1",
        .name = "app-data",
        .connection_secret = connection,
    });
    defer database.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("cockroach.Database.cluster-1.app-data", database.node.id);
    try std.testing.expect(database.node.lifecycle.protect);
    try std.testing.expect(input(database.node, "connection_secret") == .output_ref);
    try std.testing.expectEqualStrings("app-data", database.name.referenceOrNull().?.resource_id["cockroach.Database.cluster-1.".len..]);
}

test "Cockroach grants canonicalize privileges and reject duplicates" {
    var grants = try ziac.cockroach.grants.Grants.build(std.testing.allocator, .{}, .{
        .cluster_id = "cluster-1",
        .database = "app-data",
        .grantee = "app_user",
        .privileges = &.{ .drop, .connect, .create },
        .connection_secret = connection,
    });
    defer grants.deinit(std.testing.allocator);

    const privileges = input(grants.node, "privileges").list;
    try std.testing.expectEqual(@as(usize, 3), privileges.len);
    try std.testing.expectEqualStrings("CONNECT", privileges[0].string);
    try std.testing.expectEqualStrings("CREATE", privileges[1].string);
    try std.testing.expectEqualStrings("DROP", privileges[2].string);
    try std.testing.expectError(error.DuplicatePrivilege, ziac.cockroach.grants.Grants.build(std.testing.allocator, .{}, .{
        .cluster_id = "cluster-1",
        .database = "app-data",
        .grantee = "app_user",
        .privileges = &.{ .connect, .connect },
        .connection_secret = connection,
    }));
}

test "Cockroach migrations hash SQL and derive a strict dependency chain" {
    const known_connection = ziac.SecretOutput(ziac.value.SecretReference).known(.{
        .provider = "gcp-secret-manager",
        .resource = "projects/ziac-dev/secrets/database-url",
        .version = "7",
    });
    const migrations = [_]ziac.cockroach.migration.Spec{
        .{ .id = "001_init", .sql = "create table projects(id uuid primary key)" },
        .{ .id = "002_name", .sql = "alter table projects add column name text" },
        .{ .id = "003_index", .sql = "create index projects_name_idx on projects(name)" },
    };
    var set = try ziac.cockroach.migration.Migrations.build(std.testing.allocator, .{}, .{
        .cluster_id = "cluster-1",
        .database = "app-data",
        .connection_secret = known_connection,
        .migrations = &migrations,
    });
    defer set.deinit();

    try std.testing.expectEqual(@as(usize, 3), set.graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 2), set.graph.dependencies.items.len);
    try std.testing.expect(set.last_applied != null);
    const first = set.graph.resources.items[0];
    try std.testing.expectEqual(@as(usize, 64), input(first, "checksum").string.len);
    try std.testing.expect(input(first, "previous") == .string);
    try std.testing.expect(input(set.graph.resources.items[1], "previous") == .output_ref);
    try set.graph.validateAcyclic();

    const out_of_order = [_]ziac.cockroach.migration.Spec{
        .{ .id = "002_second", .sql = "select 2" },
        .{ .id = "001_first", .sql = "select 1" },
    };
    try std.testing.expectError(error.MigrationsOutOfOrder, ziac.cockroach.migration.Migrations.build(
        std.testing.allocator,
        .{},
        .{
            .cluster_id = "cluster-1",
            .database = "app-data",
            .connection_secret = known_connection,
            .migrations = &out_of_order,
        },
    ));
}

fn input(node: ziac.ResourceNode, name: []const u8) ziac.value.Value {
    for (node.inputs.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    unreachable;
}
