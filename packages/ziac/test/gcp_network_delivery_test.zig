const std = @import("std");
const ziac = @import("ziac");

const delivery = ziac.gcp.network_delivery;

test "network delivery declarations cover policy health and both internal load balancer modes" {
    const allocator = std.testing.allocator;
    const provider = config();
    const network = known("projects/ziac-dev/global/networks/api");
    const subnet = known("projects/ziac-dev/regions/europe-west1/subnetworks/api");
    const group = known("projects/ziac-dev/regions/europe-west1/instanceGroups/api");

    var firewall = try delivery.Firewall.build(allocator, provider, .{
        .name = "allow-health",
        .network = network,
        .direction = .ingress,
        .action = .{ .allow = &.{.{ .protocol = "tcp", .ports = &.{"8080"} }} },
        .source_ranges = &.{ "35.191.0.0/16", "130.211.0.0/22" },
        .target_tags = &.{"api"},
        .logging = true,
    });
    defer firewall.deinit(allocator);
    var route = try delivery.Route.build(allocator, provider, .{
        .name = "private-egress",
        .network = network,
        .destination_range = "10.80.0.0/16",
        .next_hop = .{ .gateway = known("projects/ziac-dev/global/gateways/default-internet-gateway") },
        .priority = 900,
        .tags = &.{"api"},
    });
    defer route.deinit(allocator);
    var global_health = try delivery.HealthCheck.build(allocator, provider, .{
        .name = "api-global-health",
        .protocol = .https,
        .port = 8443,
        .request_path = "/ready",
        .logging = true,
    });
    defer global_health.deinit(allocator);
    var regional_health = try delivery.RegionHealthCheck.build(allocator, provider, .{
        .name = "api-health",
        .region = "europe-west1",
        .protocol = .http,
        .port = 8080,
        .request_path = "/ready",
    });
    defer regional_health.deinit(allocator);
    var address = try delivery.InternalAddress.build(allocator, provider, .{
        .name = "api-vip",
        .region = "europe-west1",
        .subnetwork = subnet,
        .purpose = .shared_load_balancer_vip,
    });
    defer address.deinit(allocator);
    var passthrough = try delivery.RegionBackendService.build(allocator, provider, .{
        .name = "api-l4",
        .region = "europe-west1",
        .mode = .internal_passthrough,
        .protocol = .tcp,
        .network = network,
        .health_check = regional_health.self_link,
        .backends = &.{.{ .group = group, .balancing_mode = .connection }},
    });
    defer passthrough.deinit(allocator);
    var application = try delivery.RegionBackendService.build(allocator, provider, .{
        .name = "api-l7",
        .region = "europe-west1",
        .mode = .internal_application,
        .protocol = .http,
        .network = network,
        .health_check = regional_health.self_link,
        .backends = &.{.{ .group = group, .balancing_mode = .utilization, .max_utilization = 0.8 }},
        .port_name = "http",
    });
    defer application.deinit(allocator);
    var url_map = try delivery.RegionUrlMap.build(allocator, provider, .{
        .name = "api-map",
        .region = "europe-west1",
        .default_service = application.self_link,
    });
    defer url_map.deinit(allocator);
    var proxy = try delivery.RegionTargetHttpProxy.build(allocator, provider, .{
        .name = "api-http",
        .region = "europe-west1",
        .url_map = url_map.self_link,
    });
    defer proxy.deinit(allocator);
    var forwarding = try delivery.ForwardingRule.build(allocator, provider, .{
        .name = "api-http",
        .region = "europe-west1",
        .scheme = .internal_managed,
        .network = network,
        .subnetwork = subnet,
        .address = address.address,
        .target = .{ .target_proxy = proxy.self_link },
        .protocol = .tcp,
        .ports = &.{"80"},
        .allow_global_access = true,
    });
    defer forwarding.deinit(allocator);

    try std.testing.expectEqualStrings("gcp.compute.Firewall", firewall.node.type_name);
    try std.testing.expectEqualStrings("gcp.compute.Route", route.node.type_name);
    try std.testing.expectEqualStrings("gcp.compute.HealthCheck", global_health.node.type_name);
    try std.testing.expectEqualStrings("gcp.compute.RegionHealthCheck", regional_health.node.type_name);
    try std.testing.expectEqualStrings("gcp.compute.InternalAddress", address.node.type_name);
    try std.testing.expectEqualStrings("gcp.compute.RegionBackendService", passthrough.node.type_name);
    try std.testing.expectEqualStrings("gcp.compute.RegionUrlMap", url_map.node.type_name);
    try std.testing.expectEqualStrings("gcp.compute.RegionTargetHttpProxy", proxy.node.type_name);
    try std.testing.expectEqualStrings("gcp.compute.ForwardingRule", forwarding.node.type_name);
}

test "network delivery declarations reject contradictory policy and topology" {
    const allocator = std.testing.allocator;
    const provider = config();
    const network = known("projects/ziac-dev/global/networks/api");
    const subnet = known("projects/ziac-dev/regions/europe-west1/subnetworks/api");
    const health = known("projects/ziac-dev/regions/europe-west1/healthChecks/api");
    const group = known("projects/ziac-dev/regions/europe-west1/instanceGroups/api");

    try std.testing.expectError(error.InvalidFirewallScope, delivery.Firewall.build(allocator, provider, .{
        .name = "bad-egress",
        .network = network,
        .direction = .egress,
        .action = .{ .allow = &.{.{ .protocol = "tcp" }} },
        .source_ranges = &.{"10.0.0.0/8"},
    }));
    try std.testing.expectError(error.InvalidCidr, delivery.Route.build(allocator, provider, .{
        .name = "bad-route",
        .network = network,
        .destination_range = "10.0.0.0/99",
        .next_hop = .{ .ip_address = "10.0.0.1" },
    }));
    try std.testing.expectError(error.InvalidHealthTiming, delivery.HealthCheck.build(allocator, provider, .{
        .name = "bad-health",
        .protocol = .tcp,
        .port = 8080,
        .check_interval_seconds = 5,
        .timeout_seconds = 6,
    }));
    try std.testing.expectError(error.InvalidLoadBalancerMode, delivery.RegionBackendService.build(allocator, provider, .{
        .name = "bad-backend",
        .region = "europe-west1",
        .mode = .internal_passthrough,
        .protocol = .http,
        .network = network,
        .health_check = health,
        .backends = &.{.{ .group = group }},
    }));
    try std.testing.expectError(error.InvalidLoadBalancerMode, delivery.ForwardingRule.build(allocator, provider, .{
        .name = "bad-forwarding",
        .region = "europe-west1",
        .scheme = .internal,
        .network = network,
        .subnetwork = subnet,
        .address = known("10.0.0.9"),
        .target = .{ .target_proxy = known("projects/ziac-dev/regions/europe-west1/targetHttpProxies/api") },
        .protocol = .tcp,
        .ports = &.{"80"},
    }));
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
}

fn known(text: []const u8) ziac.PublicOutput([]const u8) {
    return ziac.PublicOutput([]const u8).known(text);
}
