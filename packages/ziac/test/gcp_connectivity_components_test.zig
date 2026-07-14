const std = @import("std");
const ziac = @import("ziac");

test "HaVpnConnection composes a redundant two-tunnel BGP topology" {
    var connection = try ziac.gcp.HaVpnConnection.build(std.testing.allocator, config(), .{
        .name = "office",
        .region = "europe-west1",
        .network = known("projects/ziac-dev/global/networks/platform"),
        .local_asn = 64_520,
        .peer_asn = 64_530,
        .peer_gateway_ips = .{ "203.0.113.10", "203.0.113.11" },
        .interface_cidrs = .{ "169.254.10.1/30", "169.254.20.1/30" },
        .local_bgp_ips = .{ "169.254.10.1", "169.254.20.1" },
        .peer_bgp_ips = .{ "169.254.10.2", "169.254.20.2" },
        .shared_secrets = .{ secret("office-vpn-0"), secret("office-vpn-1") },
    });
    defer connection.deinit();

    try std.testing.expectEqual(@as(usize, 9), connection.graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 14), connection.graph.dependencies.items.len);
    try std.testing.expectEqualStrings("gcp.compute.Router", connection.graph.resources.items[0].type_name);
    try std.testing.expectEqualStrings("gcp.compute.HaVpnGateway", connection.graph.resources.items[1].type_name);
    try std.testing.expectEqualStrings("gcp.compute.ExternalVpnGateway", connection.graph.resources.items[2].type_name);
    try std.testing.expect(connection.gateway.referenceOrNull() != null);
    try std.testing.expect(connection.tunnels[0].referenceOrNull() != null);
    try std.testing.expect(connection.tunnels[1].referenceOrNull() != null);
}

test "BidirectionalVpcPeering owns both project-local peering entries" {
    var peering = try ziac.gcp.BidirectionalVpcPeering.build(std.testing.allocator, config(), .{
        .name = "platform-data",
        .left = .{
            .network_name = "platform",
            .network = known("projects/ziac-dev/global/networks/platform"),
        },
        .right_provider = .{ .project_id = "data-prod", .primary_region = "europe-west1" },
        .right = .{
            .network_name = "data",
            .network = known("projects/data-prod/global/networks/data"),
        },
        .import_custom_routes = true,
        .export_custom_routes = true,
    });
    defer peering.deinit();

    try std.testing.expectEqual(@as(usize, 2), peering.graph.resources.items.len);
    try std.testing.expectEqualStrings("gcp.compute.NetworkPeering", peering.graph.resources.items[0].type_name);
    try std.testing.expectEqualStrings("ziac-dev", input(peering.graph.resources.items[0].inputs, "project_id").string);
    try std.testing.expectEqualStrings("data-prod", input(peering.graph.resources.items[1].inputs, "project_id").string);
}

test "VpcConnectivityMesh composes one NCC hub and typed spokes" {
    const tunnels = [_]ziac.PublicOutput([]const u8){
        known("projects/ziac-dev/regions/europe-west1/vpnTunnels/office-0"),
        known("projects/ziac-dev/regions/europe-west1/vpnTunnels/office-1"),
    };
    var mesh = try ziac.gcp.VpcConnectivityMesh.build(std.testing.allocator, config(), .{
        .name = "global-mesh",
        .spokes = &.{
            .{ .name = "platform", .location = "global", .link = .{ .vpc_network = known("projects/ziac-dev/global/networks/platform") } },
            .{ .name = "office", .location = "europe-west1", .link = .{ .vpn_tunnels = &tunnels } },
        },
    });
    defer mesh.deinit();

    try std.testing.expectEqual(@as(usize, 3), mesh.graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 2), mesh.graph.dependencies.items.len);
    try std.testing.expectEqualStrings("gcp.networkconnectivity.Hub", mesh.graph.resources.items[0].type_name);
    try std.testing.expectEqualStrings("gcp.networkconnectivity.Spoke", mesh.graph.resources.items[2].type_name);
    try std.testing.expect(mesh.hub.referenceOrNull() != null);
}

test "PrivateServiceConnectivityPolicy exposes the managed PSC policy output" {
    const subnetworks = [_]ziac.PublicOutput([]const u8){known("projects/ziac-dev/regions/europe-west1/subnetworks/psc")};
    var policy = try ziac.gcp.PrivateServiceConnectivityPolicy.build(std.testing.allocator, config(), .{
        .name = "alloydb",
        .location = "europe-west1",
        .network = known("projects/ziac-dev/global/networks/platform"),
        .service_class = "gcp-alloydb",
        .subnetworks = &subnetworks,
    });
    defer policy.deinit();

    try std.testing.expectEqual(@as(usize, 1), policy.graph.resources.items.len);
    try std.testing.expectEqualStrings("gcp.networkconnectivity.ServiceConnectionPolicy", policy.graph.resources.items[0].type_name);
    try std.testing.expect(policy.policy.referenceOrNull() != null);
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
}

fn known(text: []const u8) ziac.PublicOutput([]const u8) {
    return ziac.PublicOutput([]const u8).known(text);
}

fn secret(name: []const u8) ziac.SecretOutput(ziac.value.SecretReference) {
    return ziac.SecretOutput(ziac.value.SecretReference).known(.{ .provider = "gcp-secret-manager", .resource = name, .version = "latest" });
}

fn input(inputs: ziac.value.Value, name: []const u8) ziac.value.Value {
    for (inputs.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    unreachable;
}
