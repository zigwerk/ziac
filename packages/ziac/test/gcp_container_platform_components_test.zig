const std = @import("std");
const ziac = @import("ziac");

test "GkePlatform composes Standard pools Fleet membership and exact Workload Identity" {
    var platform = try ziac.gcp.GkePlatform.build(std.testing.allocator, config(), .{
        .cluster = .{
            .name = "platform",
            .location = "europe-west1",
            .mode = .standard,
            .network = known("projects/ziac-dev/global/networks/platform"),
            .subnetwork = known("projects/ziac-dev/regions/europe-west1/subnetworks/gke"),
            .ip_allocation = .{ .cluster_secondary_range = "pods", .services_secondary_range = "services" },
            .private_cluster = .{ .private_nodes = true, .master_ipv4_cidr = "172.16.0.0/28" },
        },
        .node_pools = &.{
            .{ .name = "general", .machine_type = "e2-standard-4", .autoscaling = .{ .min_nodes = 1, .max_nodes = 4 } },
            .{ .name = "jobs", .machine_type = "c4-standard-4", .spot = true },
        },
        .fleet = .{},
        .workload_identities = &.{.{ .namespace = "api", .kubernetes_service_account = "backend" }},
    });
    defer platform.deinit();

    try std.testing.expectEqual(@as(usize, 7), platform.graph.resources.items.len);
    try std.testing.expectEqualStrings("gcp.iam.ServiceAccount", platform.graph.resources.items[0].type_name);
    try std.testing.expectEqualStrings("gcp.container.Cluster", platform.graph.resources.items[1].type_name);
    try std.testing.expectEqualStrings("gcp.container.NodePool", platform.graph.resources.items[3].type_name);
    try std.testing.expectEqualStrings("gcp.gkehub.Fleet", platform.graph.resources.items[4].type_name);
    try std.testing.expectEqualStrings("gcp.gkehub.Membership", platform.graph.resources.items[5].type_name);
    try std.testing.expectEqualStrings("gcp.iam.ServiceAccountIamMember", platform.graph.resources.items[6].type_name);
    try std.testing.expectEqualStrings("roles/iam.workloadIdentityUser", input(platform.graph.resources.items[6].inputs, "role").string);
    try std.testing.expectEqualStrings("serviceAccount:ziac-dev.svc.id.goog[api/backend]", input(platform.graph.resources.items[6].inputs, "member").string);
    try std.testing.expect(platform.cluster.referenceOrNull() != null);
    try std.testing.expect(platform.service_account.referenceOrNull() != null);
}

test "GkePlatform rejects explicit node pools for Autopilot" {
    try std.testing.expectError(error.InvalidClusterMode, ziac.gcp.GkePlatform.build(std.testing.allocator, config(), .{
        .cluster = .{
            .name = "autopilot",
            .location = "europe-west1",
            .mode = .autopilot,
            .network = known("projects/ziac-dev/global/networks/platform"),
            .subnetwork = known("projects/ziac-dev/regions/europe-west1/subnetworks/gke"),
        },
        .node_pools = &.{.{ .name = "invalid", .machine_type = "e2-standard-2" }},
    }));
}

test "ZigFunction composes identity Function v2 and explicit invoker IAM" {
    var function = try ziac.gcp.ZigFunction.build(std.testing.allocator, config(), .{
        .name = "image-api",
        .location = "europe-west1",
        .runtime = "custom",
        .entry_point = "main",
        .source = .{ .bucket = "ziac-source", .object = "image-api.zip", .generation = 42 },
        .invokers = &.{"group:platform@example.com"},
    });
    defer function.deinit();

    try std.testing.expectEqual(@as(usize, 3), function.graph.resources.items.len);
    try std.testing.expectEqualStrings("gcp.iam.ServiceAccount", function.graph.resources.items[0].type_name);
    try std.testing.expectEqualStrings("gcp.functions.FunctionV2", function.graph.resources.items[1].type_name);
    try std.testing.expectEqualStrings("gcp.functions.FunctionIamMember", function.graph.resources.items[2].type_name);
    try std.testing.expectEqualStrings("roles/run.invoker", input(function.graph.resources.items[2].inputs, "role").string);
    try std.testing.expect(function.url.referenceOrNull() != null);
}

test "ZigBatchJob composes dedicated identity and immutable digest-pinned execution" {
    var job = try ziac.gcp.ZigBatchJob.build(std.testing.allocator, config(), .{
        .name = "daily-rollup",
        .location = "europe-west1",
        .image = "europe-west1-docker.pkg.dev/ziac-dev/jobs/rollup@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .commands = &.{ "./rollup", "--daily" },
        .task_count = 4,
        .parallelism = 2,
    });
    defer job.deinit();

    try std.testing.expectEqual(@as(usize, 2), job.graph.resources.items.len);
    try std.testing.expectEqualStrings("gcp.batch.Job", job.graph.resources.items[1].type_name);
    try std.testing.expect(job.graph.resources.items[1].lifecycle.replace_before_delete);
    try std.testing.expect(job.state.referenceOrNull() != null);
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
