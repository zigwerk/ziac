const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{ .project_id = "ziac-dev", .primary_region = "europe-west1" };

test "connectivity topology synthesizes exact Compute and NCC permissions" {
    var topology = try buildTopology();
    defer topology.deinit();
    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &topology.graph);
    defer requirements.deinit(std.testing.allocator);

    try std.testing.expect(contains(requirements.apis, "compute.googleapis.com"));
    try std.testing.expect(contains(requirements.apis, "networkconnectivity.googleapis.com"));
    try std.testing.expect(requirements.hasPermission("compute.vpnGateways.create"));
    try std.testing.expect(requirements.hasPermission("compute.externalVpnGateways.create"));
    try std.testing.expect(requirements.hasPermission("compute.vpnTunnels.create"));
    try std.testing.expect(requirements.hasPermission("compute.routers.update"));
    try std.testing.expect(requirements.hasPermission("compute.networks.addPeering"));
    try std.testing.expect(requirements.hasPermission("compute.networks.updatePeering"));
    try std.testing.expect(requirements.hasPermission("compute.networks.removePeering"));
    try std.testing.expect(requirements.hasPermission("networkconnectivity.hubs.create"));
    try std.testing.expect(requirements.hasPermission("networkconnectivity.spokes.create"));
    try std.testing.expect(requirements.hasPermission("networkconnectivity.serviceConnectionPolicies.create"));
}

test "connectivity canvas exposes VPN BGP peering hub and PSC semantics" {
    var topology = try buildTopology();
    defer topology.deinit();
    var artifact = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &topology.graph, null, .{
        .stack = "connectivity",
        .stage = "prod",
        .created_at_millis = 7,
    });
    defer artifact.deinit();

    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"connectivity\":{\"kind\":\"ha_vpn_gateway\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"connectivity\":{\"kind\":\"vpn_tunnel\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"connectivity\":{\"kind\":\"bgp_peer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"connectivity\":{\"kind\":\"hub\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"connectivity\":{\"kind\":\"service_connection_policy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"vpn_attachment\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"bgp_session\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"hub_membership\"") != null);
}

test "estate scan maps official VPN and Network Connectivity assets" {
    var client = ziac.estate.ScriptedClient.init(std.testing.allocator);
    defer client.deinit();
    try client.addPage(
        \\{"results":[
        \\{"name":"//compute.googleapis.com/projects/acme-prod/regions/europe-west1/vpnGateways/office","assetType":"compute.googleapis.com/VpnGateway","project":"projects/123","location":"europe-west1"},
        \\{"name":"//compute.googleapis.com/projects/acme-prod/global/externalVpnGateways/office-peer","assetType":"compute.googleapis.com/ExternalVpnGateway","project":"projects/123","location":"global"},
        \\{"name":"//compute.googleapis.com/projects/acme-prod/regions/europe-west1/vpnTunnels/office-0","assetType":"compute.googleapis.com/VpnTunnel","project":"projects/123","location":"europe-west1"},
        \\{"name":"//compute.googleapis.com/projects/acme-prod/regions/europe-west1/routers/office","assetType":"compute.googleapis.com/Router","project":"projects/123","location":"europe-west1"},
        \\{"name":"//networkconnectivity.googleapis.com/projects/acme-prod/locations/global/hubs/global-mesh","assetType":"networkconnectivity.googleapis.com/Hub","project":"projects/123","location":"global"},
        \\{"name":"//networkconnectivity.googleapis.com/projects/acme-prod/locations/europe-west1/spokes/office","assetType":"networkconnectivity.googleapis.com/Spoke","project":"projects/123","location":"europe-west1"},
        \\{"name":"//networkconnectivity.googleapis.com/projects/acme-prod/locations/europe-west1/serviceConnectionPolicies/alloydb","assetType":"networkconnectivity.googleapis.com/ServiceConnectionPolicy","project":"projects/123","location":"europe-west1"}
        \\]}
    );
    var scan = try ziac.estate.scanAlloc(std.testing.allocator, client.client(), .{
        .identity = .{ .provider = .google, .verified = true, .subject = "subject" },
        .entitlement = .pro,
        .connection = .{ .status = .connected, .project_id = "acme-prod" },
        .observed_at_millis = 1_783_764_000_000,
    });
    defer scan.deinit();

    try std.testing.expectEqual(@as(usize, 7), scan.resource_count);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.compute.HaVpnGateway") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.compute.ExternalVpnGateway") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.compute.VpnTunnel") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.networkconnectivity.Hub") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.networkconnectivity.ServiceConnectionPolicy") != null);
}

test "connectivity estimate keeps VPN NCC spokes and data transfer explicit" {
    const prices = [_]ziac.cost.SkuPrice{
        .{ .sku_id = "vpn-tunnel", .region = "global", .unit = "tunnel hour", .unit_quantity = 1, .unit_price_micros = 50_000 },
        .{ .sku_id = "ncc-hybrid", .region = "global", .unit = "hybrid spoke hour", .unit_quantity = 1, .unit_price_micros = 75_000 },
        .{ .sku_id = "ncc-vpc", .region = "global", .unit = "vpc spoke hour", .unit_quantity = 1, .unit_price_micros = 100_000 },
        .{ .sku_id = "ncc-transfer", .region = "global", .unit = "GiB", .unit_quantity = 1, .unit_price_micros = 20_000 },
    };
    const estimate = try ziac.cost.connectivityConfigurationEstimate(&prices, .{
        .resource_id = "gcp.networkconnectivity.Hub.global-mesh",
        .vpn_tunnel_sku_id = "vpn-tunnel",
        .ncc_hybrid_spoke_sku_id = "ncc-hybrid",
        .ncc_vpc_spoke_sku_id = "ncc-vpc",
        .ncc_data_transfer_sku_id = "ncc-transfer",
        .vpn_tunnel_hours = 1_460,
        .ncc_hybrid_spoke_hours = 730,
        .ncc_vpc_spoke_hours = 730,
        .ncc_data_transfer_gib = 100,
        .observed_at_millis = 7,
    });
    try std.testing.expectEqual(@as(?i64, 202_750_000), estimate.amount_micros);
    try std.testing.expectEqual(ziac.cost.Origin.configuration_estimate, estimate.origin);
    try std.testing.expect(!estimate.provenance.is_billing_export);
}

test "connectivity topology imports refreshes no-op and emits local evidence" {
    var topology = try buildTopology();
    defer topology.deinit();
    var remote = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer remote.deinit();
    var providers = ziac.provider.ProviderRegistry{};
    providers.register(.gcp, remote.provider());
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    var create_plan = try ziac.plan.buildPlan(std.testing.allocator, &topology.graph, &state);
    defer create_plan.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &create_plan, &state, providers, .{});

    var imported_remote = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer imported_remote.deinit();
    var imported_providers = ziac.provider.ProviderRegistry{};
    imported_providers.register(.gcp, imported_remote.provider());
    var imported_state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer imported_state.deinit();
    for (topology.graph.resources.items) |node| {
        const record = state.get(node.id) orelse return error.MissingRecord;
        try ziac.importer.importResource(std.testing.allocator, node, record.physical_id orelse return error.MissingRecord, &imported_state, imported_providers, null);
    }
    var refreshed = try ziac.plan.buildRefreshedPlan(std.testing.allocator, &topology.graph, &imported_state, imported_providers);
    defer refreshed.deinit();
    for (refreshed.operations) |item| try std.testing.expectEqual(ziac.plan.OperationKind.noop, item.kind);
    var destroy = try ziac.plan.buildDestroyPlan(std.testing.allocator, &state);
    defer destroy.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &destroy, &state, providers, .{ .destructive_confirmation = true });

    var receipt = try ziac.gcp.connectivity_qualification.serializeLocalAlloc(std.testing.allocator, &topology.graph, .{
        .created = remote.creates,
        .imported = imported_remote.imports,
        .no_op = refreshed.operations.len,
        .deleted = remote.deletes,
    });
    defer receipt.deinit();
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"schema\":\"ziac.gcp.connectivity-qualification.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"authenticated\":false") != null);
}

const Topology = struct {
    graph: ziac.ResourceGraph,
    fn deinit(self: *Topology) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

fn buildTopology() !Topology {
    var vpn = try ziac.gcp.HaVpnConnection.build(std.testing.allocator, provider, .{
        .name = "office",
        .region = "europe-west1",
        .network = known("projects/ziac-dev/global/networks/platform"),
        .local_asn = 64_520,
        .peer_asn = 64_530,
        .peer_gateway_ips = .{ "203.0.113.10", "203.0.113.11" },
        .interface_cidrs = .{ "169.254.10.1/30", "169.254.20.1/30" },
        .local_bgp_ips = .{ "169.254.10.1", "169.254.20.1" },
        .peer_bgp_ips = .{ "169.254.10.2", "169.254.20.2" },
        .shared_secrets = .{ secret("vpn-0"), secret("vpn-1") },
        .protect = false,
    });
    defer vpn.deinit();
    var mesh = try ziac.gcp.VpcConnectivityMesh.build(std.testing.allocator, provider, .{
        .base_graph = &vpn.graph,
        .name = "global-mesh",
        .spokes = &.{
            .{ .name = "platform", .location = "global", .link = .{ .vpc_network = known("projects/ziac-dev/global/networks/platform") } },
            .{ .name = "office", .location = "europe-west1", .link = .{ .vpn_tunnels = &vpn.tunnels } },
        },
        .protect = false,
    });
    defer mesh.deinit();
    const subnetworks = [_]ziac.PublicOutput([]const u8){known("projects/ziac-dev/regions/europe-west1/subnetworks/psc")};
    var policy = try ziac.gcp.PrivateServiceConnectivityPolicy.build(std.testing.allocator, provider, .{
        .base_graph = &mesh.graph,
        .name = "alloydb",
        .location = "europe-west1",
        .network = known("projects/ziac-dev/global/networks/platform"),
        .service_class = "gcp-alloydb",
        .subnetworks = &subnetworks,
        .protect = false,
    });
    defer policy.deinit();
    var peering = try ziac.gcp.BidirectionalVpcPeering.build(std.testing.allocator, provider, .{
        .base_graph = &policy.graph,
        .name = "platform-data",
        .left = .{ .network_name = "platform", .network = known("projects/ziac-dev/global/networks/platform") },
        .right_provider = .{ .project_id = "data-prod", .primary_region = "europe-west1" },
        .right = .{ .network_name = "data", .network = known("projects/data-prod/global/networks/data") },
        .protect = false,
    });
    defer peering.deinit();
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    errdefer graph.deinit();
    try graph.appendGraph(&peering.graph);
    return .{ .graph = graph };
}

fn known(text: []const u8) ziac.PublicOutput([]const u8) {
    return .known(text);
}

fn secret(name: []const u8) ziac.SecretOutput(ziac.value.SecretReference) {
    return .known(.{ .provider = "gcp-secret-manager", .resource = name, .version = "1" });
}

fn contains(values: []const []const u8, expected: []const u8) bool {
    for (values) |present| if (std.mem.eql(u8, present, expected)) return true;
    return false;
}
