const std = @import("std");
const ziac = @import("ziac");

const component_mod = ziac.cockroach.private_service_connect;
const policies = [_]component_mod.RegionPolicy{
    .{ .region = "europe-west1", .subnet_cidr = "10.42.0.0/24" },
    .{ .region = "us-central1", .subnet_cidr = "10.42.1.0/24" },
};
const google = ziac.gcp.config.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
    .service_regions = &.{ "europe-west1", "us-central1" },
    .network_tier = .premium,
};

test "private service connect builds complete typed multi-region topology" {
    var cluster = try managedCluster();
    defer cluster.deinit(std.testing.allocator);
    var component = try component_mod.PrivateServiceConnect.build(
        std.testing.allocator,
        google,
        .{},
        .{
            .name = "api-db",
            .cluster_resource = cluster.node,
            .cluster_id = cluster.cluster_id,
            .plan = .standard,
            .regions = &policies,
        },
    );
    defer component.deinit();

    try std.testing.expectEqual(@as(usize, 21), component.graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 3), countType(&component.graph, "gcp.project.Service"));
    try std.testing.expectEqual(@as(usize, 2), countType(&component.graph, "gcp.compute.Subnetwork"));
    try std.testing.expectEqual(@as(usize, 2), countType(&component.graph, "cockroach.PrivateEndpointService"));
    try std.testing.expectEqual(@as(usize, 2), countType(&component.graph, "cockroach.ClusterRegion"));
    try std.testing.expectEqual(@as(usize, 2), countType(&component.graph, "gcp.compute.PscAddress"));
    try std.testing.expectEqual(@as(usize, 2), countType(&component.graph, "gcp.compute.PscEndpoint"));
    try std.testing.expectEqual(@as(usize, 2), countType(&component.graph, "cockroach.PrivateEndpointConnection"));
    try std.testing.expectEqual(@as(usize, 2), countType(&component.graph, "gcp.dns.ManagedZone"));
    try std.testing.expectEqual(@as(usize, 2), countType(&component.graph, "gcp.dns.RecordSet"));
    try std.testing.expectEqual(@as(usize, 0), countType(&component.graph, "cockroach.AuthorizedNetwork"));
    try std.testing.expectEqual(@as(usize, 2), component.regions.len);
    for (component.regions) |regional| {
        try std.testing.expectEqual(ziac.gcp.cloud_run.VpcEgress.private_ranges_only, regional.direct_vpc.egress);
        try std.testing.expect(regional.direct_vpc.network_output != null);
        try std.testing.expect(regional.direct_vpc.subnetwork_output != null);
        try std.testing.expectEqualStrings("private_endpoint_dns", regional.private_dns.resource_ref.field);
        try std.testing.expectEqualStrings("psc_connection_id", regional.psc_connection_id.resource_ref.field);
        try std.testing.expectEqualStrings("status", regional.connection_status.resource_ref.field);
    }

    try std.testing.expect(hasEdge(
        &component.graph,
        "cockroach.ClusterRegion.api-db.europe-west1",
        "cockroach.PrivateEndpointService.api-db.europe-west1",
    ));
    try std.testing.expect(hasEdge(
        &component.graph,
        "cockroach.PrivateEndpointConnection.api-db.europe-west1",
        "gcp.compute.PscEndpoint.europe-west1.api-db-europe-west1",
    ));
    try std.testing.expect(hasEdge(
        &component.graph,
        "gcp.dns.RecordSet.api-db-europe-west1.A.europe-west1",
        "cockroach.PrivateEndpointConnection.api-db.europe-west1",
    ));
    try component.graph.validateAcyclic();

    var regional_vpc: [2]ziac.gcp.global.container_service.RegionalDirectVpc = undefined;
    for (component.regions, 0..) |binding, index| regional_vpc[index] = .{
        .region = binding.region,
        .config = binding.direct_vpc,
    };
    var application = try ziac.gcp.global.ContainerService.build(std.testing.allocator, google, .{
        .base_graph = &component.graph,
        .name = "api",
        .image = "europe-west1-docker.pkg.dev/ziac-dev/apps/api@sha256:abc",
        .regions = &.{ "europe-west1", "us-central1" },
        .domain = "api.example.com",
        .http_redirect = false,
        .regional_direct_vpc = &regional_vpc,
    });
    defer application.deinit();
    try std.testing.expectEqual(@as(usize, 31), application.graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 2), countType(&application.graph, "gcp.run.Service"));
    try application.graph.validateAcyclic();
}

test "private service connect validates graph ownership and exact regions" {
    var cluster = try managedCluster();
    defer cluster.deinit(std.testing.allocator);
    try std.testing.expectError(error.MissingClusterResource, component_mod.PrivateServiceConnect.build(
        std.testing.allocator,
        google,
        .{},
        .{
            .name = "api-db",
            .cluster_id = cluster.cluster_id,
            .plan = .standard,
            .regions = &policies,
        },
    ));
    try std.testing.expectError(error.ClusterResourceMismatch, component_mod.PrivateServiceConnect.build(
        std.testing.allocator,
        google,
        .{},
        .{
            .name = "api-db",
            .cluster_resource = cluster.node,
            .cluster_id = cluster.name,
            .plan = .standard,
            .regions = &policies,
        },
    ));
    const duplicate = [_]component_mod.RegionPolicy{
        .{ .region = "europe-west1", .subnet_cidr = "10.42.0.0/24" },
        .{ .region = "europe-west1", .subnet_cidr = "10.42.1.0/24" },
    };
    try std.testing.expectError(error.DuplicateRegion, component_mod.PrivateServiceConnect.build(
        std.testing.allocator,
        google,
        .{},
        .{
            .name = "api-db",
            .cluster_resource = cluster.node,
            .cluster_id = cluster.cluster_id,
            .plan = .standard,
            .regions = &duplicate,
        },
    ));
    const incomplete = [_]component_mod.RegionPolicy{
        .{ .region = "europe-west1", .subnet_cidr = "10.42.0.0/24" },
    };
    try std.testing.expectError(error.RegionPolicyMismatch, component_mod.PrivateServiceConnect.build(
        std.testing.allocator,
        google,
        .{},
        .{
            .name = "api-db",
            .cluster_resource = cluster.node,
            .cluster_id = cluster.cluster_id,
            .plan = .standard,
            .regions = &incomplete,
        },
    ));
}

fn managedCluster() !ziac.cockroach.cluster.Cluster {
    return ziac.cockroach.cluster.Cluster.build(std.testing.allocator, .{}, .{
        .name = "ziac-prod",
        .plan = .{ .standard = .{
            .regions = &.{
                .{ .name = "europe-west1", .primary = true },
                .{ .name = "us-central1" },
            },
            .provisioned_virtual_cpus = 4,
        } },
    });
}

fn countType(graph: *const ziac.ResourceGraph, type_name: []const u8) usize {
    var count: usize = 0;
    for (graph.resources.items) |node| {
        if (std.mem.eql(u8, node.type_name, type_name)) count += 1;
    }
    return count;
}

fn hasEdge(graph: *const ziac.ResourceGraph, from: []const u8, to: []const u8) bool {
    for (graph.dependencies.items) |edge| {
        if (std.mem.eql(u8, edge.from, from) and std.mem.eql(u8, edge.to, to)) return true;
    }
    return false;
}
