const std = @import("std");
const ziac = @import("ziac");

test "existing Cockroach cluster builds retained resource and typed outputs" {
    var cluster = try ziac.cockroach.existing_cluster.ExistingCluster.build(std.testing.allocator, .{}, .{
        .name = "production",
        .cluster_id = "cluster-1",
        .plan = .standard,
        .regions = &.{ "us-central1", "europe-west1" },
    });
    defer cluster.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("cockroach.Cluster.Existing.production", cluster.node.id);
    try std.testing.expectEqual(ziac.resource.ProviderId.cockroach, cluster.node.provider);
    try std.testing.expectEqualStrings("cockroach.Cluster.Existing", cluster.node.type_name);
    try std.testing.expect(cluster.node.lifecycle.retain_on_delete);
    try std.testing.expect(cluster.cluster_id == .resource_ref);
    try std.testing.expectEqualStrings("cluster_id", cluster.cluster_id.resource_ref.field);
    try std.testing.expectEqualStrings("sql_dns", cluster.sql_dns.resource_ref.field);
    try std.testing.expectEqualStrings("primary_sql_dns", cluster.primary_sql_dns.resource_ref.field);

    const inputs = try cluster.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(inputs);
    try std.testing.expectEqualStrings(
        "{\"cloud_provider\":\"GCP\",\"cluster_id\":\"cluster-1\",\"plan\":\"STANDARD\",\"regions\":[\"europe-west1\",\"us-central1\"]}",
        inputs,
    );
}

test "existing Cockroach cluster validates identity and exact topology" {
    try std.testing.expectError(error.MissingName, ziac.cockroach.existing_cluster.ExistingCluster.build(std.testing.allocator, .{}, .{
        .name = "",
        .cluster_id = "cluster-1",
        .plan = .standard,
        .regions = &.{"europe-west1"},
    }));
    try std.testing.expectError(error.MissingClusterId, ziac.cockroach.existing_cluster.ExistingCluster.build(std.testing.allocator, .{}, .{
        .name = "production",
        .cluster_id = "",
        .plan = .standard,
        .regions = &.{"europe-west1"},
    }));
    try std.testing.expectError(error.InvalidClusterId, ziac.cockroach.existing_cluster.ExistingCluster.build(std.testing.allocator, .{}, .{
        .name = "production",
        .cluster_id = "cluster-1/sql-users",
        .plan = .standard,
        .regions = &.{"europe-west1"},
    }));
    try std.testing.expectError(error.DuplicateRegion, ziac.cockroach.existing_cluster.ExistingCluster.build(std.testing.allocator, .{}, .{
        .name = "production",
        .cluster_id = "cluster-1",
        .plan = .standard,
        .regions = &.{ "europe-west1", "europe-west1" },
    }));
}
