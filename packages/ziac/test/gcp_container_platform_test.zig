const std = @import("std");
const ziac = @import("ziac");

const platform = ziac.gcp.container_platform;

test "GKE cluster declaration models private VPC native workload identity" {
    var cluster = try platform.Cluster.build(std.testing.allocator, config(), .{
        .name = "platform",
        .location = "europe-west1",
        .mode = .autopilot,
        .network = known("projects/ziac-dev/global/networks/platform"),
        .subnetwork = known("projects/ziac-dev/regions/europe-west1/subnetworks/gke"),
        .release_channel = .regular,
        .workload_pool = "ziac-dev.svc.id.goog",
        .ip_allocation = .{ .cluster_secondary_range = "pods", .services_secondary_range = "services" },
        .private_cluster = .{
            .private_nodes = true,
            .master_ipv4_cidr = "172.16.0.0/28",
            .authorized_networks = &.{.{ .name = "office", .cidr = "203.0.113.0/24" }},
        },
        .binary_authorization = .project_singleton_policy_enforce,
        .logging_components = &.{ "SYSTEM_COMPONENTS", "WORKLOADS" },
        .monitoring_components = &.{ "SYSTEM_COMPONENTS", "POD" },
        .labels = &.{.{ .key = "environment", .value = "prod" }},
        .deletion_protection = true,
    });
    defer cluster.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.container.Cluster", cluster.node.type_name);
    try std.testing.expectEqualStrings("AUTOPILOT", input(cluster.node.inputs, "mode").string);
    try std.testing.expect(input(cluster.node.inputs, "network") == .string);
    try std.testing.expectEqualStrings("ziac-dev.svc.id.goog", input(cluster.node.inputs, "workload_pool").string);
    try std.testing.expect(cluster.node.lifecycle.protect);
}

test "GKE cluster rejects incoherent private and identity configuration" {
    try std.testing.expectError(error.InvalidWorkloadPool, platform.Cluster.build(std.testing.allocator, config(), .{
        .name = "platform",
        .location = "europe-west1",
        .mode = .autopilot,
        .network = known("network"),
        .subnetwork = known("subnetwork"),
        .workload_pool = "other-project.svc.id.goog",
    }));
    try std.testing.expectError(error.InvalidPrivateCluster, platform.Cluster.build(std.testing.allocator, config(), .{
        .name = "platform",
        .location = "europe-west1",
        .mode = .standard,
        .network = known("network"),
        .subnetwork = known("subnetwork"),
        .private_cluster = .{ .private_nodes = true, .private_endpoint = true },
    }));
}

test "GKE node pools model autoscaling identity and mutable capacity" {
    var pool = try platform.NodePool.build(std.testing.allocator, config(), .{
        .name = "general",
        .location = "europe-west1",
        .cluster_name = "platform",
        .cluster = known("projects/ziac-dev/locations/europe-west1/clusters/platform"),
        .machine_type = "e2-standard-4",
        .disk_type = "pd-balanced",
        .disk_size_gb = 100,
        .image_type = "COS_CONTAINERD",
        .service_account = known("gke-nodes@ziac-dev.iam.gserviceaccount.com"),
        .locations = &.{ "europe-west1-b", "europe-west1-c" },
        .node_count = 2,
        .autoscaling = .{ .min_nodes = 1, .max_nodes = 6 },
        .auto_repair = true,
        .auto_upgrade = true,
        .spot = false,
    });
    defer pool.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.container.NodePool", pool.node.type_name);
    try std.testing.expect(input(pool.node.inputs, "cluster") == .string);
    try std.testing.expectEqual(@as(i64, 6), input(pool.node.inputs, "max_nodes").integer);
    try std.testing.expectError(error.InvalidAutoscaling, platform.NodePool.build(std.testing.allocator, config(), .{
        .name = "bad",
        .location = "europe-west1",
        .cluster_name = "platform",
        .cluster = known("cluster"),
        .machine_type = "e2-standard-4",
        .service_account = known("nodes@ziac-dev.iam.gserviceaccount.com"),
        .autoscaling = .{ .min_nodes = 4, .max_nodes = 2 },
    }));
}

test "Fleet and membership declarations use a canonical GKE resource link" {
    var fleet = try platform.Fleet.build(std.testing.allocator, config(), .{
        .name = "default",
        .display_name = "Ziac production fleet",
        .labels = &.{.{ .key = "environment", .value = "prod" }},
    });
    defer fleet.deinit(std.testing.allocator);
    var membership = try platform.Membership.build(std.testing.allocator, config(), .{
        .name = "platform-eu",
        .location = "global",
        .cluster = known("//container.googleapis.com/projects/ziac-dev/locations/europe-west1/clusters/platform"),
        .description = "Primary European cluster",
    });
    defer membership.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.gkehub.Fleet", fleet.node.type_name);
    try std.testing.expectEqualStrings("gcp.gkehub.Membership", membership.node.type_name);
    try std.testing.expect(input(membership.node.inputs, "cluster") == .string);
    try std.testing.expectError(error.InvalidClusterLink, platform.Membership.build(std.testing.allocator, config(), .{
        .name = "bad",
        .cluster = known("projects/ziac-dev/clusters/platform"),
    }));
}

test "Functions v2 preserve Secret Manager coordinates and typed triggers" {
    var function = try platform.FunctionV2.build(std.testing.allocator, config(), .{
        .name = "thumbnail",
        .location = "europe-west1",
        .runtime = "nodejs24",
        .entry_point = "thumbnail",
        .source = .{ .bucket = "ziac-source", .object = "thumbnail/source.zip", .generation = 42 },
        .trigger = .{ .eventarc = .{
            .event_type = "google.cloud.storage.object.v1.finalized",
            .region = "europe-west1",
            .filters = &.{.{ .key = "bucket", .value = "uploads" }},
            .service_account = known("events@ziac-dev.iam.gserviceaccount.com"),
        } },
        .service_account = known("thumbnail@ziac-dev.iam.gserviceaccount.com"),
        .build_service_account = known("projects/ziac-dev/serviceAccounts/build@ziac-dev.iam.gserviceaccount.com"),
        .environment = &.{.{ .key = "STAGE", .value = "prod" }},
        .secret_environment = &.{.{ .key = "DATABASE_URL", .project_id = "ziac-dev", .secret = "database-url", .version = "1" }},
        .available_memory = "512Mi",
        .timeout_seconds = 60,
        .min_instances = 0,
        .max_instances = 20,
        .max_concurrency = 40,
        .ingress = .internal_and_gclb,
    });
    defer function.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.functions.FunctionV2", function.node.type_name);
    try std.testing.expectEqualStrings("EVENTARC", input(function.node.inputs, "trigger_kind").string);
    const canonical = try function.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(canonical);
    try std.testing.expect(std.mem.indexOf(u8, canonical, "database-url") != null);
    try std.testing.expect(std.mem.indexOf(u8, canonical, "postgres://") == null);
}

test "Function IAM is additive and rejects non-invoker roles" {
    var member = try platform.FunctionIamMember.build(std.testing.allocator, config(), .{
        .name = "thumbnail-public",
        .location = "europe-west1",
        .function_name = "thumbnail",
        .function = known("projects/ziac-dev/locations/europe-west1/functions/thumbnail"),
        .role = "roles/run.invoker",
        .member = "allUsers",
    });
    defer member.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("gcp.functions.FunctionIamMember", member.node.type_name);
    try std.testing.expectError(error.InvalidRole, platform.FunctionIamMember.build(std.testing.allocator, config(), .{
        .name = "bad",
        .location = "europe-west1",
        .function_name = "thumbnail",
        .function = known("function"),
        .role = "roles/owner",
        .member = "allUsers",
    }));
}

test "Batch jobs declare immutable parallel container execution" {
    var job = try platform.BatchJob.build(std.testing.allocator, config(), .{
        .name = "daily-rollup",
        .location = "europe-west1",
        .image = "europe-west1-docker.pkg.dev/ziac-dev/jobs/rollup@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .commands = &.{ "--date", "yesterday" },
        .environment = &.{.{ .key = "STAGE", .value = "prod" }},
        .secret_environment = &.{.{ .key = "DATABASE_URL", .secret_version = "projects/ziac-dev/secrets/database-url/versions/1" }},
        .task_count = 100,
        .parallelism = 10,
        .max_retry_count = 2,
        .max_run_seconds = 3600,
        .machine_type = "e2-standard-4",
        .provisioning_model = .spot,
        .service_account = known("batch@ziac-dev.iam.gserviceaccount.com"),
        .network = known("projects/ziac-dev/global/networks/platform"),
        .subnetwork = known("projects/ziac-dev/regions/europe-west1/subnetworks/batch"),
        .logs = .cloud_logging,
        .priority = 50,
        .labels = &.{.{ .key = "workload", .value = "rollup" }},
    });
    defer job.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.batch.Job", job.node.type_name);
    try std.testing.expectEqual(@as(i64, 100), input(job.node.inputs, "task_count").integer);
    try std.testing.expect(job.node.lifecycle.replace_before_delete);
    try std.testing.expectError(error.InvalidParallelism, platform.BatchJob.build(std.testing.allocator, config(), .{
        .name = "bad",
        .location = "europe-west1",
        .image = "example/image@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .task_count = 2,
        .parallelism = 3,
        .service_account = known("batch@ziac-dev.iam.gserviceaccount.com"),
    }));
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
}

fn known(text: []const u8) ziac.PublicOutput([]const u8) {
    return .known(text);
}

fn input(inputs: ziac.value.Value, name: []const u8) ziac.value.Value {
    for (inputs.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    unreachable;
}
