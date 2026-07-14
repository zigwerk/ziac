const std = @import("std");
const ziac = @import("ziac");

const connectivity = ziac.gcp.connectivity;

test "HA VPN declarations preserve typed topology and secret references" {
    var gateway = try connectivity.HaVpnGateway.build(std.testing.allocator, config(), .{
        .name = "corp-ha",
        .region = "europe-west1",
        .network = known("projects/ziac-dev/global/networks/platform"),
    });
    defer gateway.deinit(std.testing.allocator);
    var peer = try connectivity.ExternalVpnGateway.build(std.testing.allocator, config(), .{
        .name = "corp-peer",
        .redundancy = .two_ips,
        .interfaces = &.{
            .{ .id = 0, .ip_address = "203.0.113.10" },
            .{ .id = 1, .ip_address = "203.0.113.11" },
        },
    });
    defer peer.deinit(std.testing.allocator);
    var tunnel = try connectivity.VpnTunnel.build(std.testing.allocator, config(), .{
        .name = "corp-0",
        .region = "europe-west1",
        .vpn_gateway = gateway.self_link,
        .vpn_gateway_interface = 0,
        .peer = .{ .external = .{ .gateway = peer.self_link, .interface = 0 } },
        .router = known("projects/ziac-dev/regions/europe-west1/routers/corp"),
        .shared_secret = secret("projects/ziac-dev/secrets/vpn-psk-0"),
    });
    defer tunnel.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.compute.HaVpnGateway", gateway.node.type_name);
    try std.testing.expect(!hasInput(gateway.node.inputs, "interface_count"));
    try std.testing.expectEqualStrings("gcp.compute.ExternalVpnGateway", peer.node.type_name);
    try std.testing.expect(input(tunnel.node.inputs, "shared_secret") == .secret_ref);
    try std.testing.expect(input(tunnel.node.inputs, "vpn_gateway") == .output_ref);
    try std.testing.expectEqualStrings("EXTERNAL", input(tunnel.node.inputs, "peer_kind").string);
}

test "external VPN gateway rejects a redundancy shape that Google cannot accept" {
    try std.testing.expectError(error.InvalidInterfaces, connectivity.ExternalVpnGateway.build(std.testing.allocator, config(), .{
        .name = "corp-peer",
        .redundancy = .two_ips,
        .interfaces = &.{.{ .id = 0, .ip_address = "203.0.113.10" }},
    }));
}

test "router BGP children validate private ASNs and link-local address pairs" {
    var router = try ziac.gcp.network.Router.build(std.testing.allocator, config(), .{
        .name = "corp",
        .region = "europe-west1",
        .network = known("projects/ziac-dev/global/networks/platform"),
        .bgp_asn = 64_521,
        .advertise_mode = .custom,
        .advertised_groups = &.{"ALL_SUBNETS"},
    });
    defer router.deinit(std.testing.allocator);
    var router_interface = try connectivity.RouterInterface.build(std.testing.allocator, config(), .{
        .name = "corp-0",
        .region = "europe-west1",
        .router_name = "corp",
        .router = known("projects/ziac-dev/regions/europe-west1/routers/corp"),
        .vpn_tunnel = known("projects/ziac-dev/regions/europe-west1/vpnTunnels/corp-0"),
        .ip_range = "169.254.10.1/30",
    });
    defer router_interface.deinit(std.testing.allocator);
    var peer = try connectivity.RouterBgpPeer.build(std.testing.allocator, config(), .{
        .name = "corp-0",
        .region = "europe-west1",
        .router_name = "corp",
        .router = known("projects/ziac-dev/regions/europe-west1/routers/corp"),
        .interface_name = "corp-0",
        .interface = router_interface.resource_id,
        .peer_asn = 64_520,
        .ip_address = "169.254.10.1",
        .peer_ip_address = "169.254.10.2",
        .bfd = .{ .min_transmit_ms = 1000, .min_receive_ms = 1000, .multiplier = 5 },
    });
    defer peer.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.compute.RouterInterface", router_interface.node.type_name);
    try std.testing.expectEqualStrings("gcp.compute.RouterBgpPeer", peer.node.type_name);
    try std.testing.expectEqual(@as(i64, 64_521), input(router.node.inputs, "bgp_asn").integer);
    try std.testing.expectEqual(@as(i64, 64_520), input(peer.node.inputs, "peer_asn").integer);
    try std.testing.expectError(error.InvalidAsn, connectivity.RouterBgpPeer.build(std.testing.allocator, config(), .{
        .name = "public-asn",
        .region = "europe-west1",
        .router_name = "corp",
        .router = known("router"),
        .interface_name = "corp-0",
        .interface = known("interface"),
        .peer_asn = 15_133,
        .ip_address = "169.254.10.1",
        .peer_ip_address = "169.254.10.2",
    }));
}

test "network peering models route exchange without owning either network" {
    var peering = try connectivity.NetworkPeering.build(std.testing.allocator, config(), .{
        .name = "platform-to-data",
        .network_name = "platform",
        .network = known("projects/ziac-dev/global/networks/platform"),
        .peer_network = known("projects/data-prod/global/networks/data"),
        .export_custom_routes = true,
        .import_custom_routes = true,
        .stack_type = .ipv4_ipv6,
        .update_strategy = .consensus,
    });
    defer peering.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.compute.NetworkPeering", peering.node.type_name);
    try std.testing.expectEqualStrings("CONSENSUS", input(peering.node.inputs, "update_strategy").string);
    try std.testing.expect(input(peering.node.inputs, "peer_network") == .string);
}

test "NCC declarations use a one-of spoke link and explicit PSC policy" {
    var hub = try connectivity.Hub.build(std.testing.allocator, config(), .{
        .name = "global-mesh",
        .description = "application VPC mesh",
        .topology = .mesh,
        .export_psc = true,
        .labels = &.{.{ .key = "environment", .value = "prod" }},
    });
    defer hub.deinit(std.testing.allocator);
    var spoke = try connectivity.Spoke.build(std.testing.allocator, config(), .{
        .name = "platform",
        .location = "global",
        .hub = hub.name,
        .link = .{ .vpc_network = known("projects/ziac-dev/global/networks/platform") },
    });
    defer spoke.deinit(std.testing.allocator);
    var policy = try connectivity.ServiceConnectionPolicy.build(std.testing.allocator, config(), .{
        .name = "managed-services",
        .location = "europe-west1",
        .network = known("projects/ziac-dev/global/networks/platform"),
        .service_class = "gcp-memorystore-redis",
        .subnetworks = &.{known("projects/ziac-dev/regions/europe-west1/subnetworks/services")},
        .producer_location = .custom,
        .allowed_producer_hierarchy = &.{"projects/producer-prod"},
    });
    defer policy.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.networkconnectivity.Hub", hub.node.type_name);
    try std.testing.expectEqualStrings("VPC_NETWORK", input(spoke.node.inputs, "link_kind").string);
    try std.testing.expectEqualStrings("CUSTOM_RESOURCE_HIERARCHY_LEVELS", input(policy.node.inputs, "producer_location").string);
    try std.testing.expectError(error.InvalidSpoke, connectivity.Spoke.build(std.testing.allocator, config(), .{
        .name = "empty",
        .location = "global",
        .hub = hub.name,
        .link = .{ .vpn_tunnels = &.{} },
    }));
}

test "router appliance spokes retain VM and peering IP as one typed link" {
    var spoke = try connectivity.Spoke.build(std.testing.allocator, config(), .{
        .name = "router-appliance",
        .location = "europe-west1",
        .hub = known("projects/ziac-dev/locations/global/hubs/global-mesh"),
        .link = .{ .router_appliances = &.{.{
            .virtual_machine = known("projects/ziac-dev/zones/europe-west1-b/instances/router-0"),
            .ip_address = "10.42.0.10",
        }} },
    });
    defer spoke.deinit(std.testing.allocator);

    const links = input(spoke.node.inputs, "links").list;
    try std.testing.expectEqual(@as(usize, 1), links.len);
    try std.testing.expectEqualStrings("10.42.0.10", input(links[0], "ip_address").string);
    try std.testing.expectEqualStrings("projects/ziac-dev/zones/europe-west1-b/instances/router-0", input(links[0], "virtual_machine").string);
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
}

fn known(text: []const u8) ziac.PublicOutput([]const u8) {
    return .known(text);
}

fn secret(name: []const u8) ziac.SecretOutput(ziac.value.SecretReference) {
    return .known(.{ .provider = "gcp-secret-manager", .resource = name, .version = "1" });
}

fn input(inputs: ziac.value.Value, name: []const u8) ziac.value.Value {
    for (inputs.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    unreachable;
}

fn hasInput(inputs: ziac.value.Value, name: []const u8) bool {
    for (inputs.object) |field| if (std.mem.eql(u8, field.name, name)) return true;
    return false;
}
