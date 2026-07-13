const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
};

test "Spanner declarations compile protected capacity database backup and IAM graph" {
    var instance = try ziac.gcp.spanner.Instance.build(std.testing.allocator, provider, .{
        .instance_id = "global-app",
        .config = "nam-eur-asia1",
        .display_name = "Global application",
        .edition = .enterprise_plus,
        .capacity = .{ .autoscaling_processing_units = .{
            .min = 1_000,
            .max = 5_000,
            .high_priority_cpu_percent = 65,
            .storage_percent = 90,
        } },
        .labels = &.{
            .{ .key = "team", .value = "platform" },
            .{ .key = "environment", .value = "prod" },
        },
    });
    defer instance.deinit(std.testing.allocator);

    var database = try ziac.gcp.spanner.Database.build(std.testing.allocator, provider, .{
        .database_id = "app",
        .instance = instance.name,
        .instance_id = "global-app",
        .dialect = .google_standard_sql,
        .ddl = &.{
            "CREATE TABLE users (id STRING(36) NOT NULL, name STRING(MAX)) PRIMARY KEY (id)",
            "CREATE INDEX users_by_name ON users(name)",
        },
        .version_retention_period = "7d",
        .drop_protection = true,
    });
    defer database.deinit(std.testing.allocator);

    var backup = try ziac.gcp.spanner.Backup.build(std.testing.allocator, provider, .{
        .backup_id = "app-release",
        .database = database.name,
        .instance_id = "global-app",
        .database_id = "app",
        .expire_time = "2027-07-13T12:00:00Z",
    });
    defer backup.deinit(std.testing.allocator);

    var schedule = try ziac.gcp.spanner.BackupSchedule.build(std.testing.allocator, provider, .{
        .schedule_id = "app-daily",
        .database = database.name,
        .instance_id = "global-app",
        .database_id = "app",
        .cron = "0 2 * * *",
        .retention_seconds = 14 * 24 * 60 * 60,
        .mode = .incremental,
    });
    defer schedule.deinit(std.testing.allocator);

    var member = try ziac.gcp.spanner.DatabaseIamMember.build(std.testing.allocator, provider, .{
        .name = "app-runtime",
        .database = database.name,
        .instance_id = "global-app",
        .database_id = "app",
        .role = "roles/spanner.databaseUser",
        .member = "serviceAccount:api@ziac-dev.iam.gserviceaccount.com",
    });
    defer member.deinit(std.testing.allocator);

    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    for ([_]ziac.ResourceNode{ instance.node, database.node, backup.node, schedule.node, member.node }) |node| try graph.addResource(node);
    try graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 5), graph.resources.items.len);
    try std.testing.expect(database.node.lifecycle.protect);
    try std.testing.expect(database.node.lifecycle.retain_on_delete);
    try std.testing.expect(backup.node.lifecycle.protect);
    try std.testing.expect(hasDependency(&graph, database.node.id, instance.node.id));
    try std.testing.expect(hasDependency(&graph, backup.node.id, database.node.id));
    try std.testing.expect(hasDependency(&graph, schedule.node.id, database.node.id));
    try std.testing.expect(hasDependency(&graph, member.node.id, database.node.id));
    try std.testing.expectEqualStrings("environment=prod\nteam=platform", stringField(instance.node.inputs, "labels"));
}

test "Spanner declarations reject ambiguous capacity unsafe DDL and backup policy" {
    try std.testing.expectError(error.InvalidCapacity, ziac.gcp.spanner.Instance.build(std.testing.allocator, provider, .{
        .instance_id = "bad",
        .config = "regional-europe-west1",
        .display_name = "Bad capacity",
        .capacity = .{ .processing_units = 150 },
    }));
    try std.testing.expectError(error.InvalidCapacity, ziac.gcp.spanner.Instance.build(std.testing.allocator, provider, .{
        .instance_id = "autoscale-standard",
        .config = "regional-europe-west1",
        .display_name = "Bad autoscale",
        .edition = .standard,
        .capacity = .{ .autoscaling_nodes = .{ .min = 1, .max = 2 } },
    }));
    const instance = ziac.PublicOutput([]const u8).known("projects/ziac-dev/instances/global-app");
    try std.testing.expectError(error.InvalidDdl, ziac.gcp.spanner.Database.build(std.testing.allocator, provider, .{
        .database_id = "app",
        .instance = instance,
        .instance_id = "global-app",
        .ddl = &.{"DROP DATABASE app"},
    }));
    const database = ziac.PublicOutput([]const u8).known("projects/ziac-dev/instances/global-app/databases/app");
    try std.testing.expectError(error.InvalidBackupSchedule, ziac.gcp.spanner.BackupSchedule.build(std.testing.allocator, provider, .{
        .schedule_id = "too-short",
        .database = database,
        .instance_id = "global-app",
        .database_id = "app",
        .cron = "*/2 * * * *",
        .retention_seconds = 60,
    }));
}

test "private services access declarations preserve explicit network ownership" {
    var range = try ziac.gcp.service_networking.PrivateServiceRange.build(std.testing.allocator, provider, .{
        .name = "managed-services",
        .network = "projects/ziac-dev/global/networks/platform",
        .prefix_length = 16,
    });
    defer range.deinit(std.testing.allocator);
    var connection = try ziac.gcp.service_networking.Connection.build(std.testing.allocator, provider, .{
        .name = "google-managed-services",
        .network = "projects/ziac-dev/global/networks/platform",
        .reserved_ranges = &.{.{ .name = "managed-services", .dependency = range.name }},
    });
    defer connection.deinit(std.testing.allocator);

    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.addResource(range.node);
    try graph.addResource(connection.node);
    try graph.validateAcyclic();
    try std.testing.expect(hasDependency(&graph, connection.node.id, range.node.id));
    try std.testing.expect(connection.node.lifecycle.protect);
    try std.testing.expect(connection.node.lifecycle.retain_on_delete);
    try std.testing.expectEqualStrings("managed-services", stringField(connection.node.inputs, "reserved_ranges"));

    try std.testing.expectError(error.InvalidPrefixLength, ziac.gcp.service_networking.PrivateServiceRange.build(std.testing.allocator, provider, .{
        .name = "tiny",
        .network = "projects/ziac-dev/global/networks/platform",
        .prefix_length = 31,
    }));
}

test "Memorystore declarations classify secrets and separate PSA from cluster PSC" {
    const connection = ziac.PublicOutput([]const u8).known("services/servicenetworking.googleapis.com/connections/servicenetworking-googleapis-com");
    var classic = try ziac.gcp.redis.Instance.build(std.testing.allocator, provider, .{
        .instance_id = "sessions",
        .location = "europe-west1",
        .tier = .standard_ha,
        .memory_size_gb = 8,
        .redis_version = .redis_7_2,
        .network = "projects/ziac-dev/global/networks/platform",
        .connect_mode = .private_service_access,
        .connectivity_dependency = connection,
        .auth_enabled = true,
        .auth_secret = ziac.PublicOutput([]const u8).known("projects/ziac-dev/secrets/redis-sessions-auth"),
        .transit_encryption = .server_authentication,
        .read_replicas = 2,
        .persistence = .{ .rdb = .six_hours },
        .configs = &.{
            .{ .key = "notify-keyspace-events", .value = "Ex" },
            .{ .key = "maxmemory-policy", .value = "allkeys-lru" },
        },
    });
    defer classic.deinit(std.testing.allocator);
    try std.testing.expectEqual(ziac.output.Secrecy.secret, @TypeOf(classic.auth_secret_version).secrecy);
    try std.testing.expectEqualStrings("maxmemory-policy=allkeys-lru\nnotify-keyspace-events=Ex", stringField(classic.node.inputs, "configs"));

    const acl_rule = ziac.SecretOutput(ziac.value.SecretReference).known(.{
        .provider = "gcp-secret-manager",
        .resource = "projects/ziac-dev/secrets/redis-acl-api",
        .version = "1",
    });
    var acl = try ziac.gcp.redis.AclPolicy.build(std.testing.allocator, provider, .{
        .policy_id = "application",
        .location = "us-central1",
        .rules = &.{.{ .username = "api", .rule = acl_rule }},
    });
    defer acl.deinit(std.testing.allocator);
    var cluster = try ziac.gcp.redis.Cluster.build(std.testing.allocator, provider, .{
        .cluster_id = "global-cache",
        .location = "us-central1",
        .shard_count = 3,
        .replica_count = 1,
        .node_type = .shared_core_nano,
        .network = "projects/ziac-dev/global/networks/platform",
        .authorization = .iam_auth,
        .transit_encryption = .server_authentication,
        .acl_policy = acl.name,
        .deletion_protection = true,
    });
    defer cluster.deinit(std.testing.allocator);

    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.addResource(classic.node);
    try graph.addResource(acl.node);
    try graph.addResource(cluster.node);
    try graph.validateAcyclic();
    try std.testing.expect(hasDependency(&graph, cluster.node.id, acl.node.id));
    try std.testing.expect(classic.node.lifecycle.protect);
    try std.testing.expect(cluster.node.lifecycle.protect);
}

test "Memorystore rejects missing connectivity invalid replicas and public ACL rules" {
    try std.testing.expectError(error.MissingPrivateConnectivityDependency, ziac.gcp.redis.Instance.build(std.testing.allocator, provider, .{
        .instance_id = "sessions",
        .location = "europe-west1",
        .tier = .standard_ha,
        .memory_size_gb = 8,
        .network = "projects/ziac-dev/global/networks/platform",
        .connect_mode = .private_service_access,
        .auth_secret = ziac.PublicOutput([]const u8).known("projects/ziac-dev/secrets/redis-sessions-auth"),
    }));
    try std.testing.expectError(error.InvalidReplicaCount, ziac.gcp.redis.Instance.build(std.testing.allocator, provider, .{
        .instance_id = "basic",
        .location = "europe-west1",
        .tier = .basic,
        .memory_size_gb = 1,
        .network = "projects/ziac-dev/global/networks/platform",
        .auth_enabled = false,
        .read_replicas = 1,
    }));
    try std.testing.expectError(error.InvalidCluster, ziac.gcp.redis.Cluster.build(std.testing.allocator, provider, .{
        .cluster_id = "bad-cluster",
        .location = "us-central1",
        .shard_count = 0,
        .network = "projects/ziac-dev/global/networks/platform",
    }));
    try std.testing.expectError(error.InvalidMaintenanceWindow, ziac.gcp.redis.Instance.build(std.testing.allocator, provider, .{
        .instance_id = "maintenance",
        .location = "europe-west1",
        .tier = .basic,
        .memory_size_gb = 1,
        .network = "projects/ziac-dev/global/networks/platform",
        .auth_enabled = false,
        .maintenance_day = "FUNDAY",
        .maintenance_hour_utc = 24,
    }));
}

fn hasDependency(graph: *const ziac.ResourceGraph, from: []const u8, to: []const u8) bool {
    for (graph.dependencies.items) |edge| if (std.mem.eql(u8, edge.from, from) and std.mem.eql(u8, edge.to, to)) return true;
    return false;
}

fn stringField(input: ziac.value.Value, name: []const u8) []const u8 {
    for (input.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value.string;
    unreachable;
}
