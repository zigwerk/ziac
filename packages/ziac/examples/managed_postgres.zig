const std = @import("std");
const ziac = @import("ziac");

fn build(allocator: std.mem.Allocator) !ziac.gcp.ManagedPostgres {
    return ziac.gcp.ManagedPostgres.build(allocator, .{
        .project_id = "example-project",
        .primary_region = "europe-west1",
    }, .{
        .name = "postgres",
        .primary = .{
            .instance_id = "postgres-primary",
            .database_version = .postgres_17,
            .region = "europe-west1",
            .tier = "db-custom-2-4096",
            .availability = .regional,
            .point_in_time_recovery = true,
            .private_network = "projects/example-project/global/networks/platform",
        },
        .private_connectivity_dependency = ziac.PublicOutput([]const u8).known("projects/example-project/global/networks/platform"),
        .databases = &.{.{ .name = "app" }},
        .builtin_users = &.{.{
            .name = "app",
            .password = ziac.SecretOutput(ziac.value.SecretReference).known(.{
                .provider = "gcp-secret-manager",
                .resource = "projects/example-project/secrets/postgres-app-password",
                .version = "1",
            }),
        }},
        .iam_users = &.{.{
            .name = "api@example-project.iam",
            .user_type = .cloud_iam_service_account,
            .member = "serviceAccount:api@example-project.iam.gserviceaccount.com",
            .client = true,
        }},
        .replicas = &.{.{
            .instance_id = "postgres-us-replica",
            .region = "us-central1",
            .tier = "db-custom-2-4096",
            .private_network = "projects/example-project/global/networks/platform",
        }},
        .client_certificate = .{
            .common_name = "api-client",
            .secret_id = "postgres-client-key",
        },
    });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var database = try build(allocator);
    defer database.deinit();
    var requirements = try ziac.gcp.intelligence.synthesizePermissionPlan(allocator, &database.graph);
    defer requirements.deinit(allocator);
    std.debug.print("managed postgres: {d} resources, {d} deployer permissions\n", .{
        database.graph.resources.items.len,
        requirements.deployer_permissions.len,
    });
}

test "managed postgres example compiles an explicit private PostgreSQL data plane" {
    var database = try build(std.testing.allocator);
    defer database.deinit();
    try database.graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 9), database.graph.resources.items.len);
}
