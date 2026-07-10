const std = @import("std");
const ziac = @import("ziac");

const regions = [_]ziac.cockroach.public_egress.RegionPolicy{
    .{ .region = "europe-west1", .subnet_cidr = "10.42.0.0/24" },
    .{ .region = "us-central1", .subnet_cidr = "10.42.1.0/24" },
};

test "public static egress creates one reserved address and narrow allowlist per region" {
    var component = try ziac.cockroach.public_egress.PublicStaticEgress.build(
        std.testing.allocator,
        .{
            .project_id = "ziac-dev",
            .primary_region = "europe-west1",
            .service_regions = &.{ "europe-west1", "us-central1" },
            .network_tier = .premium,
        },
        .{},
        .{
            .name = "api",
            .cluster_id = "cluster-1",
            .regions = &regions,
        },
    );
    defer component.deinit();

    try std.testing.expectEqual(@as(usize, 11), component.graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 12), component.graph.dependencies.items.len);
    try std.testing.expectEqual(@as(usize, 2), countType(&component.graph, "gcp.compute.RegionalAddress"));
    try std.testing.expectEqual(@as(usize, 2), countType(&component.graph, "gcp.compute.RouterNat"));
    try std.testing.expectEqual(@as(usize, 2), countType(&component.graph, "cockroach.AuthorizedNetwork"));
    try std.testing.expectEqual(@as(usize, 2), component.regional_vpc.len);
    for (component.graph.resources.items) |node| {
        if (!std.mem.eql(u8, node.type_name, "cockroach.AuthorizedNetwork")) continue;
        try std.testing.expect(inputValue(node, "ip_address") == .output_ref);
        try std.testing.expectEqual(@as(i64, 32), inputValue(node, "cidr_mask").integer);
    }
    for (component.regional_vpc) |regional| {
        try std.testing.expect(regional.config.network_output != null);
        try std.testing.expect(regional.config.subnetwork_output != null);
        try std.testing.expectEqual(ziac.gcp.cloud_run.VpcEgress.all_traffic, regional.config.egress);
    }
    try component.graph.validateAcyclic();
}

test "public static egress rejects duplicate regions and broad production policy" {
    const duplicate = [_]ziac.cockroach.public_egress.RegionPolicy{
        .{ .region = "europe-west1", .subnet_cidr = "10.42.0.0/24" },
        .{ .region = "europe-west1", .subnet_cidr = "10.42.1.0/24" },
    };
    try std.testing.expectError(error.DuplicateRegion, ziac.cockroach.public_egress.PublicStaticEgress.build(
        std.testing.allocator,
        .{ .project_id = "ziac-dev", .primary_region = "europe-west1", .network_tier = .premium },
        .{},
        .{ .name = "api", .cluster_id = "cluster-1", .regions = &duplicate },
    ));
}

fn countType(graph: *const ziac.ResourceGraph, type_name: []const u8) usize {
    var count: usize = 0;
    for (graph.resources.items) |node| {
        if (std.mem.eql(u8, node.type_name, type_name)) count += 1;
    }
    return count;
}

fn inputValue(node: ziac.ResourceNode, name: []const u8) ziac.value.Value {
    for (node.inputs.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    unreachable;
}
