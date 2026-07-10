const std = @import("std");
const ziac = @import("ziac");

const migrations = [_]ziac.cockroach.migration.Spec{
    .{
        .id = "001_accounts",
        .sql = "CREATE TABLE accounts (id UUID PRIMARY KEY, email STRING UNIQUE NOT NULL)",
    },
    .{
        .id = "002_created_at",
        .sql = "ALTER TABLE accounts ADD COLUMN created_at TIMESTAMPTZ NOT NULL DEFAULT now()",
    },
};

pub fn buildApplicationDatabase(allocator: std.mem.Allocator) !ziac.cockroach.application_database.ApplicationDatabase {
    return ziac.cockroach.application_database.ApplicationDatabase.build(
        allocator,
        .{ .project_id = "example-project", .primary_region = "europe-west1" },
        .{},
        .{
            .name = "production",
            .cluster_id = "8e9f4f46-example-cluster-id",
            .plan = .standard,
            .regions = &.{ "europe-west1", "us-central1" },
            .database = "app",
            .username = "app_user",
            .secret_id = "app-database-url",
            .accessor_member = "serviceAccount:api@example-project.iam.gserviceaccount.com",
            .admin_connection = .{
                .provider = "gcp-secret-manager",
                .resource = "projects/example-project/secrets/cockroach-admin-url",
                .version = "1",
            },
            .migrations = &migrations,
        },
    );
}

pub fn main() !void {
    var component = try buildApplicationDatabase(std.heap.page_allocator);
    defer component.deinit();
    std.debug.print("application database: {d} resources, {d} dependencies\n", .{
        component.graph.resources.items.len,
        component.graph.dependencies.items.len,
    });
}

test "Cockroach application database example is dependency complete" {
    var component = try buildApplicationDatabase(std.testing.allocator);
    defer component.deinit();
    try std.testing.expectEqual(@as(usize, 9), component.graph.resources.items.len);
    try std.testing.expect(component.connection_secret == .resource_ref);
    try std.testing.expect(component.last_migration != null);
    try component.graph.validateAcyclic();
}
