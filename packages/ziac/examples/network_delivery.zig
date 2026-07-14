const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{
    .project_id = "example-project",
    .primary_region = "europe-west1",
};

fn build(allocator: std.mem.Allocator) !ziac.gcp.RegionalInternalApplicationLoadBalancer {
    var base = ziac.ResourceGraph.init(allocator);
    defer base.deinit();
    var network = try ziac.gcp.network.Network.build(allocator, provider, .{ .name = "platform" });
    defer network.deinit(allocator);
    try base.addResource(network.node);
    const network_id = base.resources.items[0].id;

    var application_subnet = try ziac.gcp.network.Subnetwork.build(allocator, provider, .{
        .name = "application",
        .region = "europe-west1",
        .ip_cidr_range = "10.42.0.0/24",
        .network = ziac.gcp.network.Network.Outputs.SelfLink.fromResource(network_id),
    });
    defer application_subnet.deinit(allocator);
    try base.addResource(application_subnet.node);
    const application_subnet_id = base.resources.items[1].id;

    var proxy_subnet = try ziac.gcp.network.Subnetwork.build(allocator, provider, .{
        .name = "proxy-only",
        .region = "europe-west1",
        .ip_cidr_range = "10.42.1.0/24",
        .network = ziac.gcp.network.Network.Outputs.SelfLink.fromResource(network_id),
    });
    defer proxy_subnet.deinit(allocator);
    try base.addResource(proxy_subnet.node);
    const proxy_subnet_id = base.resources.items[2].id;

    var policy = try ziac.gcp.NetworkPolicy.build(allocator, provider, .{
        .base_graph = &base,
        .network = ziac.gcp.network.Network.Outputs.SelfLink.fromResource(network_id),
        .firewalls = &.{.{
            .name = "allow-proxy-health",
            .direction = .ingress,
            .action = .{ .allow = &.{.{ .protocol = "tcp", .ports = &.{"8080"} }} },
            .source_ranges = &.{ "10.42.1.0/24", "35.191.0.0/16", "130.211.0.0/22" },
            .target_tags = &.{"api"},
        }},
    });
    defer policy.deinit();

    return ziac.gcp.RegionalInternalApplicationLoadBalancer.build(allocator, provider, .{
        .base_graph = &policy.graph,
        .name = "private-api",
        .region = "europe-west1",
        .network = ziac.gcp.network.Network.Outputs.SelfLink.fromResource(network_id),
        .subnetwork = ziac.gcp.network.Subnetwork.Outputs.SelfLink.fromResource(application_subnet_id),
        .proxy_only_subnet = ziac.gcp.network.Subnetwork.Outputs.SelfLink.fromResource(proxy_subnet_id),
        .backend_group = ziac.PublicOutput([]const u8).known("projects/example-project/regions/europe-west1/instanceGroups/api"),
        .health_port = 8080,
        .health_request_path = "/ready",
        .backend_port_name = "http",
        .frontend_port = 80,
        .allow_global_access = true,
    });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var topology = try build(allocator);
    defer topology.deinit();
    var permissions = try ziac.gcp.intelligence.synthesizePermissionPlan(allocator, &topology.graph);
    defer permissions.deinit(allocator);
    std.debug.print("Private delivery: {d} resources, {d} causal edges, {d} exact permissions\n", .{
        topology.graph.resources.items.len,
        topology.graph.dependencies.items.len,
        permissions.deployer_permissions.len,
    });
}

test "network-delivery example compiles an explicit internal L7 topology" {
    var topology = try build(std.testing.allocator);
    defer topology.deinit();
    try topology.graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 10), topology.graph.resources.items.len);
}
