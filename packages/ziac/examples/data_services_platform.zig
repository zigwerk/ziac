const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{
    .project_id = "example-project",
    .primary_region = "europe-west1",
};

fn build(allocator: std.mem.Allocator) !ziac.gcp.MemorystoreCache {
    var private_access = try ziac.gcp.PrivateServiceAccess.build(allocator, provider, .{
        .name = "managed-services",
        .network = "projects/example-project/global/networks/platform",
        .prefix_length = 16,
    });
    defer private_access.deinit();

    var database = try ziac.gcp.SpannerDatabase.build(allocator, provider, .{
        .base_graph = &private_access.graph,
        .name = "global-app",
        .instance = .{
            .instance_id = "global-app",
            .config = "nam-eur-asia1",
            .display_name = "Global application",
            .edition = .enterprise_plus,
            .capacity = .{ .autoscaling_processing_units = .{ .min = 1_000, .max = 5_000 } },
            .default_backup_schedule = .none,
        },
        .database_id = "app",
        .ddl = &.{"CREATE TABLE users (id STRING(36) NOT NULL) PRIMARY KEY (id)"},
        .backup_schedule = .{
            .schedule_id = "daily",
            .cron = "0 2 * * *",
            .retention_seconds = 14 * 24 * 60 * 60,
        },
        .database_members = &.{.{
            .name = "api-runtime",
            .role = "roles/spanner.databaseUser",
            .member = "serviceAccount:api@example-project.iam.gserviceaccount.com",
        }},
    });
    defer database.deinit();

    return ziac.gcp.MemorystoreCache.build(allocator, provider, .{
        .base_graph = &database.graph,
        .name = "sessions",
        .cache = .{ .classic = .{
            .instance_id = "sessions",
            .location = "europe-west1",
            .tier = .standard_ha,
            .memory_size_gb = 8,
            .network = "projects/example-project/global/networks/platform",
            .connect_mode = .private_service_access,
            .connectivity_dependency = private_access.connection_name,
            .auth_secret = ziac.PublicOutput([]const u8).known("projects/example-project/secrets/redis-auth"),
            .read_replicas = 1,
            .persistence = .{ .rdb = .twelve_hours },
        } },
    });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var platform = try build(allocator);
    defer platform.deinit();
    var permissions = try ziac.gcp.intelligence.synthesizePermissionPlan(allocator, &platform.graph);
    defer permissions.deinit(allocator);
    std.debug.print("data services: {d} resources, {d} deployer permissions\n", .{
        platform.graph.resources.items.len,
        permissions.deployer_permissions.len,
    });
}

test "data services example compiles explicit private connectivity and runtime access" {
    var platform = try build(std.testing.allocator);
    defer platform.deinit();
    try platform.graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 7), platform.graph.resources.items.len);
}
