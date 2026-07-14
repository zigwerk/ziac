const std = @import("std");
const config_mod = @import("config.zig");
const connectivity = @import("connectivity.zig");
const network = @import("network.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = connectivity.BuildError || network.BuildError || resource.ResourceGraphError || std.mem.Allocator.Error;

pub const HaVpnConnectionArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    region: []const u8,
    network: output.Output([]const u8, .public),
    local_asn: u32,
    peer_asn: u32,
    peer_gateway_ips: [2][]const u8,
    interface_cidrs: [2][]const u8,
    local_bgp_ips: [2][]const u8,
    peer_bgp_ips: [2][]const u8,
    shared_secrets: [2]output.Output(value.SecretReference, .secret),
    route_priority: u16 = 100,
    bfd: ?connectivity.BfdConfig = null,
    protect: bool = true,
};

pub const HaVpnConnection = struct {
    graph: resource.ResourceGraph,
    router: output.Output([]const u8, .public),
    gateway: output.Output([]const u8, .public),
    peer_gateway: output.Output([]const u8, .public),
    tunnels: [2]output.Output([]const u8, .public),

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: HaVpnConnectionArgs) BuildError!HaVpnConnection {
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);

        const router_name = try childNameAlloc(allocator, args.name, "router", null);
        defer allocator.free(router_name);
        const router_index = graph.resources.items.len;
        var router = try network.Router.build(allocator, provider, .{
            .name = router_name,
            .region = args.region,
            .network = args.network,
            .bgp_asn = args.local_asn,
        });
        defer router.deinit(allocator);
        router.node.lifecycle.protect = args.protect;
        try graph.addResource(router.node);
        const router_id = graph.resources.items[router_index].id;
        const router_output = network.Router.Outputs.SelfLink.fromResource(router_id);

        const gateway_name = try childNameAlloc(allocator, args.name, "gateway", null);
        defer allocator.free(gateway_name);
        const gateway_index = graph.resources.items.len;
        var gateway = try connectivity.HaVpnGateway.build(allocator, provider, .{
            .name = gateway_name,
            .region = args.region,
            .network = args.network,
            .protect = args.protect,
        });
        defer gateway.deinit(allocator);
        try graph.addResource(gateway.node);
        const gateway_id = graph.resources.items[gateway_index].id;
        const gateway_output = connectivity.HaVpnGateway.Outputs.SelfLink.fromResource(gateway_id);

        const peer_name = try childNameAlloc(allocator, args.name, "peer", null);
        defer allocator.free(peer_name);
        const peer_index = graph.resources.items.len;
        var peer = try connectivity.ExternalVpnGateway.build(allocator, provider, .{
            .name = peer_name,
            .redundancy = .two_ips,
            .interfaces = &.{
                .{ .id = 0, .ip_address = args.peer_gateway_ips[0] },
                .{ .id = 1, .ip_address = args.peer_gateway_ips[1] },
            },
            .protect = args.protect,
        });
        defer peer.deinit(allocator);
        try graph.addResource(peer.node);
        const peer_id = graph.resources.items[peer_index].id;
        const peer_output = connectivity.ExternalVpnGateway.Outputs.SelfLink.fromResource(peer_id);

        var tunnels: [2]output.Output([]const u8, .public) = undefined;
        var tunnel_ids: [2][]const u8 = undefined;
        for (0..2) |index| {
            const tunnel_name = try childNameAlloc(allocator, args.name, "tunnel", index);
            defer allocator.free(tunnel_name);
            const tunnel_index = graph.resources.items.len;
            var tunnel = try connectivity.VpnTunnel.build(allocator, provider, .{
                .name = tunnel_name,
                .region = args.region,
                .vpn_gateway = gateway_output,
                .vpn_gateway_interface = @intCast(index),
                .peer = .{ .external = .{ .gateway = peer_output, .interface = @intCast(index) } },
                .router = router_output,
                .shared_secret = args.shared_secrets[index],
                .protect = args.protect,
            });
            defer tunnel.deinit(allocator);
            try graph.addResource(tunnel.node);
            tunnel_ids[index] = graph.resources.items[tunnel_index].id;
            tunnels[index] = connectivity.VpnTunnel.Outputs.SelfLink.fromResource(tunnel_ids[index]);
        }

        for (0..2) |index| {
            const interface_name = try childNameAlloc(allocator, args.name, "interface", index);
            defer allocator.free(interface_name);
            const interface_index = graph.resources.items.len;
            var interface = try connectivity.RouterInterface.build(allocator, provider, .{
                .name = interface_name,
                .region = args.region,
                .router_name = router_name,
                .router = router_output,
                .vpn_tunnel = tunnels[index],
                .ip_range = args.interface_cidrs[index],
            });
            defer interface.deinit(allocator);
            interface.node.lifecycle.protect = args.protect;
            try graph.addResource(interface.node);
            const interface_id = graph.resources.items[interface_index].id;

            const peer_name_child = try childNameAlloc(allocator, args.name, "bgp", index);
            defer allocator.free(peer_name_child);
            var bgp_peer = try connectivity.RouterBgpPeer.build(allocator, provider, .{
                .name = peer_name_child,
                .region = args.region,
                .router_name = router_name,
                .router = router_output,
                .interface_name = interface_name,
                .interface = connectivity.RouterInterface.Outputs.ResourceId.fromResource(interface_id),
                .peer_asn = args.peer_asn,
                .ip_address = args.local_bgp_ips[index],
                .peer_ip_address = args.peer_bgp_ips[index],
                .route_priority = args.route_priority,
                .bfd = args.bfd,
            });
            defer bgp_peer.deinit(allocator);
            bgp_peer.node.lifecycle.protect = args.protect;
            try graph.addResource(bgp_peer.node);
        }

        try graph.validateAcyclic();
        return .{
            .graph = graph,
            .router = router_output,
            .gateway = gateway_output,
            .peer_gateway = peer_output,
            .tunnels = tunnels,
        };
    }

    pub fn deinit(self: *HaVpnConnection) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

pub const PeeringSide = struct {
    network_name: []const u8,
    network: output.Output([]const u8, .public),
};

pub const BidirectionalVpcPeeringArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    left: PeeringSide,
    right_provider: config_mod.ProviderConfig,
    right: PeeringSide,
    import_custom_routes: bool = false,
    export_custom_routes: bool = false,
    import_subnet_routes_with_public_ip: bool = false,
    export_subnet_routes_with_public_ip: bool = false,
    stack_type: connectivity.PeeringStackType = .ipv4_only,
    update_strategy: connectivity.PeeringUpdateStrategy = .consensus,
    protect: bool = true,
};

pub const BidirectionalVpcPeering = struct {
    graph: resource.ResourceGraph,
    left: output.Output([]const u8, .public),
    right: output.Output([]const u8, .public),

    pub fn build(allocator: std.mem.Allocator, left_provider: config_mod.ProviderConfig, args: BidirectionalVpcPeeringArgs) BuildError!BidirectionalVpcPeering {
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);

        const left_name = try childNameAlloc(allocator, args.name, "left", null);
        defer allocator.free(left_name);
        const left_index = graph.resources.items.len;
        var left = try connectivity.NetworkPeering.build(allocator, left_provider, .{
            .name = left_name,
            .network_name = args.left.network_name,
            .network = args.left.network,
            .peer_network = args.right.network,
            .import_custom_routes = args.import_custom_routes,
            .export_custom_routes = args.export_custom_routes,
            .import_subnet_routes_with_public_ip = args.import_subnet_routes_with_public_ip,
            .export_subnet_routes_with_public_ip = args.export_subnet_routes_with_public_ip,
            .stack_type = args.stack_type,
            .update_strategy = args.update_strategy,
        });
        defer left.deinit(allocator);
        left.node.lifecycle.protect = args.protect;
        try graph.addResource(left.node);
        const left_id = graph.resources.items[left_index].id;

        const right_name = try childNameAlloc(allocator, args.name, "right", null);
        defer allocator.free(right_name);
        const right_index = graph.resources.items.len;
        var right = try connectivity.NetworkPeering.build(allocator, args.right_provider, .{
            .name = right_name,
            .network_name = args.right.network_name,
            .network = args.right.network,
            .peer_network = args.left.network,
            .import_custom_routes = args.import_custom_routes,
            .export_custom_routes = args.export_custom_routes,
            .import_subnet_routes_with_public_ip = args.import_subnet_routes_with_public_ip,
            .export_subnet_routes_with_public_ip = args.export_subnet_routes_with_public_ip,
            .stack_type = args.stack_type,
            .update_strategy = args.update_strategy,
        });
        defer right.deinit(allocator);
        right.node.lifecycle.protect = args.protect;
        try graph.addResource(right.node);
        const right_id = graph.resources.items[right_index].id;

        try graph.validateAcyclic();
        return .{
            .graph = graph,
            .left = connectivity.NetworkPeering.Outputs.ResourceId.fromResource(left_id),
            .right = connectivity.NetworkPeering.Outputs.ResourceId.fromResource(right_id),
        };
    }

    pub fn deinit(self: *BidirectionalVpcPeering) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

pub const ConnectivitySpoke = struct {
    name: []const u8,
    location: []const u8,
    link: connectivity.SpokeLink,
    group: ?output.Output([]const u8, .public) = null,
    description: []const u8 = "",
    labels: []const connectivity.Label = &.{},
    site_to_site_data_transfer: bool = false,
};

pub const VpcConnectivityMeshArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    description: []const u8 = "",
    topology: connectivity.HubTopology = .mesh,
    export_psc: bool = false,
    labels: []const connectivity.Label = &.{},
    spokes: []const ConnectivitySpoke,
    protect: bool = true,
};

pub const VpcConnectivityMesh = struct {
    graph: resource.ResourceGraph,
    hub: output.Output([]const u8, .public),

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: VpcConnectivityMeshArgs) BuildError!VpcConnectivityMesh {
        if (args.spokes.len == 0) return error.InvalidSpoke;
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);

        const hub_index = graph.resources.items.len;
        var hub = try connectivity.Hub.build(allocator, provider, .{
            .name = args.name,
            .description = args.description,
            .topology = args.topology,
            .export_psc = args.export_psc,
            .labels = args.labels,
            .protect = args.protect,
        });
        defer hub.deinit(allocator);
        try graph.addResource(hub.node);
        const hub_id = graph.resources.items[hub_index].id;
        const hub_output = connectivity.Hub.Outputs.Name.fromResource(hub_id);

        for (args.spokes) |spoke_args| {
            var spoke = try connectivity.Spoke.build(allocator, provider, .{
                .name = spoke_args.name,
                .location = spoke_args.location,
                .hub = hub_output,
                .link = spoke_args.link,
                .group = spoke_args.group,
                .description = spoke_args.description,
                .labels = spoke_args.labels,
                .site_to_site_data_transfer = spoke_args.site_to_site_data_transfer,
                .protect = args.protect,
            });
            defer spoke.deinit(allocator);
            try graph.addResource(spoke.node);
        }

        try graph.validateAcyclic();
        return .{ .graph = graph, .hub = hub_output };
    }

    pub fn deinit(self: *VpcConnectivityMesh) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

pub const PrivateServiceConnectivityPolicyArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    location: []const u8,
    network: output.Output([]const u8, .public),
    service_class: []const u8,
    subnetworks: []const output.Output([]const u8, .public),
    producer_location: connectivity.ProducerLocation = .automatic,
    allowed_producer_hierarchy: []const []const u8 = &.{},
    description: []const u8 = "",
    labels: []const connectivity.Label = &.{},
    protect: bool = true,
};

pub const PrivateServiceConnectivityPolicy = struct {
    graph: resource.ResourceGraph,
    policy: output.Output([]const u8, .public),
    connection_limit: output.Output(i64, .public),

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: PrivateServiceConnectivityPolicyArgs) BuildError!PrivateServiceConnectivityPolicy {
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);
        const policy_index = graph.resources.items.len;
        var policy = try connectivity.ServiceConnectionPolicy.build(allocator, provider, .{
            .name = args.name,
            .location = args.location,
            .network = args.network,
            .service_class = args.service_class,
            .subnetworks = args.subnetworks,
            .producer_location = args.producer_location,
            .allowed_producer_hierarchy = args.allowed_producer_hierarchy,
            .description = args.description,
            .labels = args.labels,
            .protect = args.protect,
        });
        defer policy.deinit(allocator);
        try graph.addResource(policy.node);
        const policy_id = graph.resources.items[policy_index].id;
        try graph.validateAcyclic();
        return .{
            .graph = graph,
            .policy = connectivity.ServiceConnectionPolicy.Outputs.Name.fromResource(policy_id),
            .connection_limit = connectivity.ServiceConnectionPolicy.Outputs.PscConnectionLimit.fromResource(policy_id),
        };
    }

    pub fn deinit(self: *PrivateServiceConnectivityPolicy) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

fn childNameAlloc(allocator: std.mem.Allocator, base: []const u8, kind: []const u8, index: ?usize) std.mem.Allocator.Error![]const u8 {
    return if (index) |present|
        std.fmt.allocPrint(allocator, "{s}-{s}-{d}", .{ base, kind, present })
    else
        std.fmt.allocPrint(allocator, "{s}-{s}", .{ base, kind });
}
