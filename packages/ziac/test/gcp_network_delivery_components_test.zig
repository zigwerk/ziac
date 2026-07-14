const std = @import("std");
const ziac = @import("ziac");

const delivery = ziac.gcp.network_delivery;

test "NetworkPolicy composes explicit firewall and route ownership" {
    var policy = try ziac.gcp.NetworkPolicy.build(std.testing.allocator, config(), .{
        .network = known("projects/ziac-dev/global/networks/api"),
        .firewalls = &.{.{
            .name = "allow-health",
            .direction = .ingress,
            .action = .{ .allow = &.{.{ .protocol = "tcp", .ports = &.{"8080"} }} },
            .source_ranges = &.{"35.191.0.0/16"},
            .target_tags = &.{"api"},
        }},
        .routes = &.{.{
            .name = "private-egress",
            .destination_range = "10.80.0.0/16",
            .next_hop = .{ .ip_address = "10.0.0.1" },
        }},
    });
    defer policy.deinit();

    try std.testing.expectEqual(@as(usize, 2), policy.graph.resources.items.len);
    try std.testing.expectEqualStrings("gcp.compute.Firewall", policy.graph.resources.items[0].type_name);
    try std.testing.expectEqualStrings("gcp.compute.Route", policy.graph.resources.items[1].type_name);
}

test "InternalPassthroughLoadBalancer composes private L4 delivery" {
    var load_balancer = try ziac.gcp.InternalPassthroughLoadBalancer.build(std.testing.allocator, config(), .{
        .name = "api-l4",
        .region = "europe-west1",
        .network = known("projects/ziac-dev/global/networks/api"),
        .subnetwork = known("projects/ziac-dev/regions/europe-west1/subnetworks/api"),
        .backend_group = known("projects/ziac-dev/regions/europe-west1/instanceGroups/api"),
        .health_port = 8080,
        .protocol = .tcp,
        .ports = &.{"443"},
        .allow_global_access = true,
    });
    defer load_balancer.deinit();

    try std.testing.expectEqual(@as(usize, 4), load_balancer.graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 3), load_balancer.graph.dependencies.items.len);
    try std.testing.expect(load_balancer.address.referenceOrNull() != null);
}

test "RegionalInternalApplicationLoadBalancer composes L7 and records proxy subnet dependency" {
    var base = ziac.ResourceGraph.init(std.testing.allocator);
    defer base.deinit();
    var network = try ziac.gcp.network.Network.build(std.testing.allocator, config(), .{ .name = "api" });
    defer network.deinit(std.testing.allocator);
    try base.addResource(network.node);
    const network_id = base.resources.items[0].id;
    var app_subnet = try ziac.gcp.network.Subnetwork.build(std.testing.allocator, config(), .{
        .name = "api",
        .region = "europe-west1",
        .ip_cidr_range = "10.42.0.0/24",
        .network = ziac.gcp.network.Network.Outputs.SelfLink.fromResource(network_id),
    });
    defer app_subnet.deinit(std.testing.allocator);
    try base.addResource(app_subnet.node);
    const app_subnet_id = base.resources.items[1].id;
    var proxy_subnet = try ziac.gcp.network.Subnetwork.build(std.testing.allocator, config(), .{
        .name = "proxy-only",
        .region = "europe-west1",
        .ip_cidr_range = "10.42.1.0/24",
        .network = ziac.gcp.network.Network.Outputs.SelfLink.fromResource(network_id),
    });
    defer proxy_subnet.deinit(std.testing.allocator);
    try base.addResource(proxy_subnet.node);
    const proxy_subnet_id = base.resources.items[2].id;

    var load_balancer = try ziac.gcp.RegionalInternalApplicationLoadBalancer.build(std.testing.allocator, config(), .{
        .base_graph = &base,
        .name = "api-l7",
        .region = "europe-west1",
        .network = ziac.gcp.network.Network.Outputs.SelfLink.fromResource(network_id),
        .subnetwork = ziac.gcp.network.Subnetwork.Outputs.SelfLink.fromResource(app_subnet_id),
        .proxy_only_subnet = ziac.gcp.network.Subnetwork.Outputs.SelfLink.fromResource(proxy_subnet_id),
        .backend_group = known("projects/ziac-dev/regions/europe-west1/instanceGroups/api"),
        .health_port = 8080,
        .backend_port_name = "http",
        .frontend_port = 80,
    });
    defer load_balancer.deinit();

    try std.testing.expectEqual(@as(usize, 9), load_balancer.graph.resources.items.len);
    const forwarding_id = load_balancer.graph.resources.items[8].id;
    try std.testing.expect(hasDependency(&load_balancer.graph, forwarding_id, proxy_subnet_id));
}

fn hasDependency(graph: *const ziac.ResourceGraph, from: []const u8, to: []const u8) bool {
    for (graph.dependencies.items) |edge| if (std.mem.eql(u8, edge.from, from) and std.mem.eql(u8, edge.to, to)) return true;
    return false;
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
}

fn known(text: []const u8) ziac.PublicOutput([]const u8) {
    return ziac.PublicOutput([]const u8).known(text);
}
