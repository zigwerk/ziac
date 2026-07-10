const std = @import("std");
const ziac = @import("ziac");

test "ApplicationDatabase requires a numeric GCP Secret Manager admin version" {
    try ziac.cockroach.application_database.validateAdminConnection(.{
        .provider = "gcp-secret-manager",
        .resource = "projects/ziac-dev/secrets/cockroach-admin",
        .version = "7",
    });
    try std.testing.expectError(error.InvalidAdminConnection, ziac.cockroach.application_database.validateAdminConnection(.{
        .provider = "environment",
        .resource = "DATABASE_URL",
    }));
    try std.testing.expectError(error.InvalidAdminConnection, ziac.cockroach.application_database.validateAdminConnection(.{
        .provider = "gcp-secret-manager",
        .resource = "projects/ziac-dev/secrets/cockroach-admin",
        .version = "latest",
    }));
}

test "ApplicationDatabase orders bootstrap credentials grants and migrations" {
    var component = try ziac.cockroach.application_database.ApplicationDatabase.build(
        std.testing.allocator,
        .{ .project_id = "ziac-dev", .primary_region = "europe-west1" },
        .{},
        .{
            .name = "production",
            .cluster_id = "cluster-1",
            .plan = .standard,
            .regions = &.{ "europe-west1", "us-central1" },
            .database = "app",
            .username = "app_user",
            .secret_id = "database-url",
            .admin_connection = .{
                .provider = "gcp-secret-manager",
                .resource = "projects/ziac-dev/secrets/cockroach-admin",
                .version = "7",
            },
            .migrations = &.{
                .{ .id = "001_init", .sql = "CREATE TABLE widgets (id UUID PRIMARY KEY)" },
                .{ .id = "002_name", .sql = "ALTER TABLE widgets ADD COLUMN name STRING" },
            },
        },
    );
    defer component.deinit();

    try std.testing.expectEqual(@as(usize, 8), component.graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 1), countType(&component.graph, "cockroach.Database"));
    try std.testing.expectEqual(@as(usize, 1), countType(&component.graph, "cockroach.Grants"));
    try std.testing.expectEqual(@as(usize, 2), countType(&component.graph, "cockroach.Migration"));
    try component.graph.validateAcyclic();

    try expectDependency(&component.graph, "cockroach.Database.cluster-1.app", "cockroach.Cluster.Existing.production");
    try expectDependency(&component.graph, "cockroach.Grants.cluster-1.app.app_user", "cockroach.Database.cluster-1.app");
    try expectDependency(&component.graph, "cockroach.Grants.cluster-1.app.app_user", "cockroach.SqlUser.cluster-1.app_user");
    try expectDependency(&component.graph, "cockroach.Migration.cluster-1.app.001_init", "cockroach.Database.cluster-1.app");
    try expectDependency(&component.graph, "cockroach.Migration.cluster-1.app.001_init", "cockroach.Grants.cluster-1.app.app_user");
    try expectDependency(&component.graph, "cockroach.Migration.cluster-1.app.002_name", "cockroach.Migration.cluster-1.app.001_init");

    try std.testing.expect(component.connection_secret == .resource_ref);
    try std.testing.expect(component.database_name == .resource_ref);
    try std.testing.expect(component.last_migration != null);
    try std.testing.expectEqualStrings("cockroach.ConnectionSecret.production", component.payloadSpec().source_resource);

    const database = findType(&component.graph, "cockroach.Database");
    try std.testing.expect(inputValue(database, "connection_secret") == .secret_ref);
    const migration = findResource(&component.graph, "cockroach.Migration.cluster-1.app.001_init");
    try std.testing.expect(inputValue(migration, "connection_secret") == .output_ref);
}

test "ApplicationDatabase supports an empty initial migration set" {
    var component = try ziac.cockroach.application_database.ApplicationDatabase.build(
        std.testing.allocator,
        .{ .project_id = "ziac-dev", .primary_region = "europe-west1" },
        .{},
        .{
            .name = "production",
            .cluster_id = "cluster-1",
            .plan = .standard,
            .regions = &.{"europe-west1"},
            .database = "app",
            .username = "app_user",
            .secret_id = "database-url",
            .admin_connection = .{
                .provider = "gcp-secret-manager",
                .resource = "projects/ziac-dev/secrets/cockroach-admin",
                .version = "7",
            },
        },
    );
    defer component.deinit();

    try std.testing.expectEqual(@as(usize, 6), component.graph.resources.items.len);
    try std.testing.expect(component.last_migration == null);
}

fn countType(graph: *const ziac.ResourceGraph, type_name: []const u8) usize {
    var count: usize = 0;
    for (graph.resources.items) |node| if (std.mem.eql(u8, node.type_name, type_name)) {
        count += 1;
    };
    return count;
}

fn findType(graph: *const ziac.ResourceGraph, type_name: []const u8) ziac.ResourceNode {
    for (graph.resources.items) |node| if (std.mem.eql(u8, node.type_name, type_name)) return node;
    unreachable;
}

fn findResource(graph: *const ziac.ResourceGraph, id: []const u8) ziac.ResourceNode {
    for (graph.resources.items) |node| if (std.mem.eql(u8, node.id, id)) return node;
    unreachable;
}

fn inputValue(node: ziac.ResourceNode, name: []const u8) ziac.value.Value {
    for (node.inputs.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    unreachable;
}

fn expectDependency(graph: *const ziac.ResourceGraph, from: []const u8, to: []const u8) !void {
    for (graph.dependencies.items) |edge| {
        if (std.mem.eql(u8, edge.from, from) and std.mem.eql(u8, edge.to, to)) return;
    }
    return error.TestExpectedEqual;
}
