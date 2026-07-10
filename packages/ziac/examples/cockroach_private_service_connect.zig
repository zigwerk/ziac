const std = @import("std");
const ziac = @import("ziac");

const service_regions = [_][]const u8{ "europe-west1", "us-central1" };
const google = ziac.gcp.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
    .service_regions = &service_regions,
    .network_tier = .premium,
};
const policies = [_]ziac.cockroach.private_service_connect.RegionPolicy{
    .{ .region = "europe-west1", .subnet_cidr = "10.42.0.0/24" },
    .{ .region = "us-central1", .subnet_cidr = "10.42.1.0/24" },
};

pub fn buildStack(allocator: std.mem.Allocator) !ziac.ResourceGraph {
    var cluster = try ziac.cockroach.cluster.Cluster.build(allocator, .{}, .{
        .name = "ziac-prod",
        .plan = .{ .standard = .{
            .regions = &.{
                .{ .name = "europe-west1", .primary = true },
                .{ .name = "us-central1" },
            },
            .provisioned_virtual_cpus = 4,
        } },
    });
    defer cluster.deinit(allocator);

    var private = try ziac.cockroach.private_service_connect.PrivateServiceConnect.build(
        allocator,
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
    defer private.deinit();

    var regional_vpc: [service_regions.len]ziac.gcp.global.RegionalDirectVpc = undefined;
    for (private.regions, 0..) |binding, index| regional_vpc[index] = .{
        .region = binding.region,
        .config = binding.direct_vpc,
    };

    var application = try ziac.gcp.global.ContainerService.build(allocator, google, .{
        .base_graph = &private.graph,
        .name = "api",
        .image = "europe-west1-docker.pkg.dev/ziac-dev/apps/api@sha256:0123456789abcdef",
        .regions = &service_regions,
        .domain = "api.example.com",
        .regional_direct_vpc = &regional_vpc,
    });
    defer application.deinit();
    return application.takeGraph();
}

pub fn main() !void {
    var graph = try buildStack(std.heap.page_allocator);
    defer graph.deinit();
    std.debug.print("global private stack resources: {d}\n", .{graph.resources.items.len});
}

test "PSC example wires regional Cloud Run without a public Cockroach allowlist" {
    var graph = try buildStack(std.testing.allocator);
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 34), graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 2), countType(&graph, "gcp.run.Service"));
    try std.testing.expectEqual(@as(usize, 2), countType(&graph, "cockroach.PrivateEndpointConnection"));
    try std.testing.expectEqual(@as(usize, 0), countType(&graph, "cockroach.AuthorizedNetwork"));
    try graph.validateAcyclic();
}

fn countType(graph: *const ziac.ResourceGraph, type_name: []const u8) usize {
    var count: usize = 0;
    for (graph.resources.items) |node| {
        if (std.mem.eql(u8, node.type_name, type_name)) count += 1;
    }
    return count;
}
