const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
};

test "PrivateServiceAccess composes one protected range and connection" {
    var access = try ziac.gcp.PrivateServiceAccess.build(std.testing.allocator, provider, .{
        .name = "managed-services",
        .network = "projects/ziac-dev/global/networks/platform",
        .prefix_length = 16,
    });
    defer access.deinit();

    try std.testing.expectEqual(@as(usize, 2), access.graph.resources.items.len);
    try std.testing.expectEqualStrings("gcp.compute.PrivateServiceRange", access.graph.resources.items[0].type_name);
    try std.testing.expectEqualStrings("gcp.servicenetworking.Connection", access.graph.resources.items[1].type_name);
    try std.testing.expect(hasDependency(&access.graph, access.graph.resources.items[1].id, access.graph.resources.items[0].id));
    try std.testing.expect(access.graph.resources.items[0].lifecycle.protect);
    try std.testing.expect(access.graph.resources.items[1].lifecycle.retain_on_delete);
}

test "SpannerDatabase composes protected data backup and least privilege IAM" {
    var database = try ziac.gcp.SpannerDatabase.build(std.testing.allocator, provider, .{
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
        .backups = &.{.{
            .backup_id = "release",
            .expire_time = "2027-07-13T12:00:00Z",
        }},
        .instance_members = &.{.{
            .name = "platform-admin",
            .role = "roles/spanner.viewer",
            .member = "group:platform@example.com",
        }},
        .database_members = &.{.{
            .name = "api-runtime",
            .role = "roles/spanner.databaseUser",
            .member = "serviceAccount:api@ziac-dev.iam.gserviceaccount.com",
        }},
    });
    defer database.deinit();

    try std.testing.expectEqual(@as(usize, 6), database.graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 1), database.backup_names.len);
    try std.testing.expect(database.backup_schedule_name != null);
    const instance_id = findType(&database.graph, "gcp.spanner.Instance");
    const database_id = findType(&database.graph, "gcp.spanner.Database");
    try std.testing.expect(hasDependency(&database.graph, database_id, instance_id));
    try std.testing.expect(hasDependency(&database.graph, findType(&database.graph, "gcp.spanner.Backup"), database_id));
    try std.testing.expect(hasDependency(&database.graph, findType(&database.graph, "gcp.spanner.BackupSchedule"), database_id));
    try std.testing.expect(hasDependency(&database.graph, findType(&database.graph, "gcp.spanner.DatabaseIamMember"), database_id));
}

test "MemorystoreCache keeps classic and cluster topology disjoint" {
    var classic = try ziac.gcp.MemorystoreCache.build(std.testing.allocator, provider, .{
        .name = "sessions",
        .cache = .{ .classic = .{
            .instance_id = "sessions",
            .location = "europe-west1",
            .tier = .standard_ha,
            .memory_size_gb = 8,
            .network = "projects/ziac-dev/global/networks/platform",
            .connect_mode = .private_service_access,
            .connectivity_dependency = ziac.PublicOutput([]const u8).known("services/servicenetworking.googleapis.com/connections/managed-services"),
            .auth_secret = ziac.PublicOutput([]const u8).known("projects/ziac-dev/secrets/redis-auth"),
        } },
    });
    defer classic.deinit();
    try std.testing.expectEqual(@as(usize, 1), classic.graph.resources.items.len);
    try std.testing.expect(classic.host != null);
    try std.testing.expect(classic.discovery_endpoint == null);

    const acl_rule = ziac.SecretOutput(ziac.value.SecretReference).known(.{
        .provider = "gcp-secret-manager",
        .resource = "projects/ziac-dev/secrets/redis-acl",
        .version = "1",
    });
    var cluster = try ziac.gcp.MemorystoreCache.build(std.testing.allocator, provider, .{
        .name = "global-cache",
        .cache = .{ .cluster = .{
            .cluster = .{
                .cluster_id = "global-cache",
                .location = "us-central1",
                .shard_count = 3,
                .network = "projects/ziac-dev/global/networks/platform",
            },
            .acl_policy = .{
                .policy_id = "application",
                .rules = &.{.{ .username = "api", .rule = acl_rule }},
            },
        } },
    });
    defer cluster.deinit();
    try std.testing.expectEqual(@as(usize, 2), cluster.graph.resources.items.len);
    try std.testing.expect(cluster.host == null);
    try std.testing.expect(cluster.discovery_endpoint != null);
    try std.testing.expect(hasDependency(&cluster.graph, findType(&cluster.graph, "gcp.redis.Cluster"), findType(&cluster.graph, "gcp.redis.AclPolicy")));
}

test "components reject duplicate backups and conflicting managed ACL policy" {
    try std.testing.expectError(error.DuplicateBackup, ziac.gcp.SpannerDatabase.build(std.testing.allocator, provider, .{
        .name = "duplicate",
        .instance = .{ .instance_id = "duplicate", .config = "regional-europe-west1", .display_name = "Duplicate database" },
        .database_id = "app",
        .backups = &.{
            .{ .backup_id = "same", .expire_time = "2027-07-13T12:00:00Z" },
            .{ .backup_id = "same", .expire_time = "2027-07-14T12:00:00Z" },
        },
    }));

    const external_acl = ziac.PublicOutput([]const u8).known("projects/ziac-dev/locations/us-central1/aclPolicies/external");
    try std.testing.expectError(error.ConflictingAclPolicy, ziac.gcp.MemorystoreCache.build(std.testing.allocator, provider, .{
        .name = "conflict",
        .cache = .{ .cluster = .{
            .cluster = .{
                .cluster_id = "conflict",
                .location = "us-central1",
                .shard_count = 3,
                .network = "projects/ziac-dev/global/networks/platform",
                .acl_policy = external_acl,
            },
            .acl_policy = .{ .policy_id = "managed", .rules = &.{} },
        } },
    }));
}

fn hasDependency(graph: *const ziac.ResourceGraph, from: []const u8, to: []const u8) bool {
    for (graph.dependencies.items) |edge| if (std.mem.eql(u8, edge.from, from) and std.mem.eql(u8, edge.to, to)) return true;
    return false;
}

fn findType(graph: *const ziac.ResourceGraph, type_name: []const u8) []const u8 {
    for (graph.resources.items) |node| if (std.mem.eql(u8, node.type_name, type_name)) return node.id;
    unreachable;
}
