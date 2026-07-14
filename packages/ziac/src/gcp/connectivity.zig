const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    DuplicateValue,
    InvalidAddress,
    InvalidAsn,
    InvalidBfd,
    InvalidCidr,
    InvalidHierarchyLevel,
    InvalidInterface,
    InvalidInterfaces,
    InvalidName,
    InvalidPolicy,
    InvalidSpoke,
    InvalidValue,
    OutputNotKnown,
};

pub const Label = struct { key: []const u8, value: []const u8 };
pub const StackType = enum { ipv4_only, ipv4_ipv6 };

pub const HaVpnGatewayArgs = struct {
    name: []const u8,
    region: []const u8,
    network: output.Output([]const u8, .public),
    stack_type: StackType = .ipv4_only,
    protect: bool = false,
};

pub const HaVpnGateway = struct {
    pub const Outputs = struct {
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
        pub const Interface0Ip = output.Descriptor("interface_0_ip", []const u8, .public);
        pub const Interface1Ip = output.Descriptor("interface_1_ip", []const u8, .public);
    };
    node: resource.ResourceNode,
    self_link: Outputs.SelfLink.OutputType,
    interface_0_ip: Outputs.Interface0Ip.OutputType,
    interface_1_ip: Outputs.Interface1Ip.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: HaVpnGatewayArgs) BuildError!HaVpnGateway {
        try provider.validate();
        try validateName(args.name);
        try validateLocation(args.region);
        const fields = [_]value.Field{
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "network", .value = try publicOutputValue(args.network) },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "region", .value = .{ .string = args.region } },
            .{ .name = "stack_type", .value = .{ .string = stackText(args.stack_type) } },
        };
        const logical_id = try regionalIdAlloc(allocator, args.region, args.name);
        defer allocator.free(logical_id);
        const node = try nodeOwned(allocator, "gcp.compute.HaVpnGateway", logical_id, args.name, &fields, .{ .protect = args.protect });
        return .{
            .node = node,
            .self_link = Outputs.SelfLink.fromResource(node.id),
            .interface_0_ip = Outputs.Interface0Ip.fromResource(node.id),
            .interface_1_ip = Outputs.Interface1Ip.fromResource(node.id),
        };
    }

    pub fn deinit(self: *HaVpnGateway, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const ExternalVpnRedundancy = enum { single_ip, two_ips, four_ips };
pub const ExternalVpnInterface = struct { id: u8, ip_address: []const u8 };

pub const ExternalVpnGatewayArgs = struct {
    name: []const u8,
    redundancy: ExternalVpnRedundancy,
    interfaces: []const ExternalVpnInterface,
    description: []const u8 = "",
    protect: bool = false,
};

pub const ExternalVpnGateway = struct {
    pub const Outputs = struct {
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
    };
    node: resource.ResourceNode,
    self_link: Outputs.SelfLink.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ExternalVpnGatewayArgs) BuildError!ExternalVpnGateway {
        try provider.validate();
        try validateName(args.name);
        const expected: usize = switch (args.redundancy) {
            .single_ip => 1,
            .two_ips => 2,
            .four_ips => 4,
        };
        if (args.interfaces.len != expected) return error.InvalidInterfaces;
        var interfaces = try interfaceListValueOwned(allocator, args.interfaces);
        defer interfaces.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "interfaces", .value = interfaces },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "redundancy_type", .value = .{ .string = switch (args.redundancy) {
                .single_ip => "SINGLE_IP_INTERNALLY_REDUNDANT",
                .two_ips => "TWO_IPS_REDUNDANCY",
                .four_ips => "FOUR_IPS_REDUNDANCY",
            } } },
        };
        const node = try nodeOwned(allocator, "gcp.compute.ExternalVpnGateway", args.name, args.name, &fields, .{ .protect = args.protect });
        return .{ .node = node, .self_link = Outputs.SelfLink.fromResource(node.id) };
    }

    pub fn deinit(self: *ExternalVpnGateway, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const ExternalPeer = struct { gateway: output.Output([]const u8, .public), interface: u8 };
pub const VpnPeer = union(enum) {
    external: ExternalPeer,
    gcp_gateway: output.Output([]const u8, .public),
};

pub const VpnTunnelArgs = struct {
    name: []const u8,
    region: []const u8,
    vpn_gateway: output.Output([]const u8, .public),
    vpn_gateway_interface: u8,
    peer: VpnPeer,
    router: output.Output([]const u8, .public),
    shared_secret: output.Output(value.SecretReference, .secret),
    ike_version: u8 = 2,
    description: []const u8 = "",
    protect: bool = false,
};

pub const VpnTunnel = struct {
    pub const Outputs = struct {
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
        pub const Status = output.Descriptor("status", []const u8, .public);
        pub const DetailedStatus = output.Descriptor("detailed_status", []const u8, .public);
        pub const SharedSecretHash = output.Descriptor("shared_secret_hash", []const u8, .public);
    };
    node: resource.ResourceNode,
    self_link: Outputs.SelfLink.OutputType,
    status: Outputs.Status.OutputType,
    detailed_status: Outputs.DetailedStatus.OutputType,
    shared_secret_hash: Outputs.SharedSecretHash.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: VpnTunnelArgs) BuildError!VpnTunnel {
        try provider.validate();
        try validateName(args.name);
        try validateLocation(args.region);
        if (args.vpn_gateway_interface > 1 or args.ike_version != 2) return error.InvalidInterface;
        var peer_gateway: value.Value = undefined;
        var peer_kind: []const u8 = undefined;
        var peer_interface: i64 = -1;
        switch (args.peer) {
            .external => |peer| {
                if (peer.interface > 3) return error.InvalidInterface;
                peer_gateway = try publicOutputValue(peer.gateway);
                peer_kind = "EXTERNAL";
                peer_interface = peer.interface;
            },
            .gcp_gateway => |gateway| {
                peer_gateway = try publicOutputValue(gateway);
                peer_kind = "GCP";
            },
        }
        const fields = [_]value.Field{
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "ike_version", .value = .{ .integer = args.ike_version } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "peer_gateway", .value = peer_gateway },
            .{ .name = "peer_gateway_interface", .value = .{ .integer = peer_interface } },
            .{ .name = "peer_kind", .value = .{ .string = peer_kind } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "region", .value = .{ .string = args.region } },
            .{ .name = "router", .value = try publicOutputValue(args.router) },
            .{ .name = "shared_secret", .value = try secretOutputValue(args.shared_secret) },
            .{ .name = "vpn_gateway", .value = try publicOutputValue(args.vpn_gateway) },
            .{ .name = "vpn_gateway_interface", .value = .{ .integer = args.vpn_gateway_interface } },
        };
        const logical_id = try regionalIdAlloc(allocator, args.region, args.name);
        defer allocator.free(logical_id);
        const node = try nodeOwned(allocator, "gcp.compute.VpnTunnel", logical_id, args.name, &fields, .{ .protect = args.protect });
        return .{
            .node = node,
            .self_link = Outputs.SelfLink.fromResource(node.id),
            .status = Outputs.Status.fromResource(node.id),
            .detailed_status = Outputs.DetailedStatus.fromResource(node.id),
            .shared_secret_hash = Outputs.SharedSecretHash.fromResource(node.id),
        };
    }

    pub fn deinit(self: *VpnTunnel, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const RouterInterfaceArgs = struct {
    name: []const u8,
    region: []const u8,
    router_name: []const u8,
    router: output.Output([]const u8, .public),
    vpn_tunnel: output.Output([]const u8, .public),
    ip_range: []const u8,
};

pub const RouterInterface = struct {
    pub const Outputs = struct {
        pub const ResourceId = output.Descriptor("resource_id", []const u8, .public);
    };
    node: resource.ResourceNode,
    resource_id: Outputs.ResourceId.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: RouterInterfaceArgs) BuildError!RouterInterface {
        try provider.validate();
        try validateName(args.name);
        try validateName(args.router_name);
        try validateLocation(args.region);
        try validateLinkLocalCidr(args.ip_range);
        const fields = [_]value.Field{
            .{ .name = "ip_range", .value = .{ .string = args.ip_range } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "region", .value = .{ .string = args.region } },
            .{ .name = "router", .value = try publicOutputValue(args.router) },
            .{ .name = "router_name", .value = .{ .string = args.router_name } },
            .{ .name = "vpn_tunnel", .value = try publicOutputValue(args.vpn_tunnel) },
        };
        const logical_id = try parentChildIdAlloc(allocator, args.region, args.router_name, args.name);
        defer allocator.free(logical_id);
        const node = try nodeOwned(allocator, "gcp.compute.RouterInterface", logical_id, args.name, &fields, .{});
        return .{ .node = node, .resource_id = Outputs.ResourceId.fromResource(node.id) };
    }

    pub fn deinit(self: *RouterInterface, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const BfdConfig = struct {
    min_transmit_ms: u32 = 1000,
    min_receive_ms: u32 = 1000,
    multiplier: u8 = 5,
};

pub const AdvertisementMode = enum { default, custom };
pub const RouterBgpPeerArgs = struct {
    name: []const u8,
    region: []const u8,
    router_name: []const u8,
    router: output.Output([]const u8, .public),
    interface_name: []const u8,
    interface: output.Output([]const u8, .public),
    peer_asn: u32,
    ip_address: []const u8,
    peer_ip_address: []const u8,
    route_priority: u16 = 100,
    advertisement_mode: AdvertisementMode = .default,
    advertised_groups: []const []const u8 = &.{},
    bfd: ?BfdConfig = null,
};

pub const RouterBgpPeer = struct {
    pub const Outputs = struct {
        pub const ResourceId = output.Descriptor("resource_id", []const u8, .public);
        pub const Status = output.Descriptor("status", []const u8, .public);
    };
    node: resource.ResourceNode,
    resource_id: Outputs.ResourceId.OutputType,
    status: Outputs.Status.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: RouterBgpPeerArgs) BuildError!RouterBgpPeer {
        try provider.validate();
        try validateName(args.name);
        try validateName(args.router_name);
        try validateName(args.interface_name);
        try validateLocation(args.region);
        try validatePrivateAsn(args.peer_asn);
        try validateLinkLocalAddress(args.ip_address);
        try validateLinkLocalAddress(args.peer_ip_address);
        if (std.mem.eql(u8, args.ip_address, args.peer_ip_address)) return error.InvalidAddress;
        if (args.advertisement_mode == .default and args.advertised_groups.len > 0) return error.InvalidValue;
        if (args.bfd) |bfd| try validateBfd(bfd);
        var groups = try stringListValueOwned(allocator, args.advertised_groups);
        defer groups.deinit(allocator);
        const bfd = args.bfd orelse BfdConfig{};
        const fields = [_]value.Field{
            .{ .name = "advertise_mode", .value = .{ .string = if (args.advertisement_mode == .custom) "CUSTOM" else "DEFAULT" } },
            .{ .name = "advertised_groups", .value = groups },
            .{ .name = "bfd_enabled", .value = .{ .boolean = args.bfd != null } },
            .{ .name = "bfd_min_receive_ms", .value = .{ .integer = bfd.min_receive_ms } },
            .{ .name = "bfd_min_transmit_ms", .value = .{ .integer = bfd.min_transmit_ms } },
            .{ .name = "bfd_multiplier", .value = .{ .integer = bfd.multiplier } },
            .{ .name = "interface", .value = try publicOutputValue(args.interface) },
            .{ .name = "interface_name", .value = .{ .string = args.interface_name } },
            .{ .name = "ip_address", .value = .{ .string = args.ip_address } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "peer_asn", .value = .{ .integer = args.peer_asn } },
            .{ .name = "peer_ip_address", .value = .{ .string = args.peer_ip_address } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "region", .value = .{ .string = args.region } },
            .{ .name = "route_priority", .value = .{ .integer = args.route_priority } },
            .{ .name = "router", .value = try publicOutputValue(args.router) },
            .{ .name = "router_name", .value = .{ .string = args.router_name } },
        };
        const logical_id = try parentChildIdAlloc(allocator, args.region, args.router_name, args.name);
        defer allocator.free(logical_id);
        const node = try nodeOwned(allocator, "gcp.compute.RouterBgpPeer", logical_id, args.name, &fields, .{});
        return .{ .node = node, .resource_id = Outputs.ResourceId.fromResource(node.id), .status = Outputs.Status.fromResource(node.id) };
    }

    pub fn deinit(self: *RouterBgpPeer, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const PeeringStackType = enum { ipv4_only, ipv4_ipv6 };
pub const PeeringUpdateStrategy = enum { independent, consensus };
pub const NetworkPeeringArgs = struct {
    name: []const u8,
    network_name: []const u8,
    network: output.Output([]const u8, .public),
    peer_network: output.Output([]const u8, .public),
    import_custom_routes: bool = false,
    export_custom_routes: bool = false,
    import_subnet_routes_with_public_ip: bool = false,
    export_subnet_routes_with_public_ip: bool = false,
    stack_type: PeeringStackType = .ipv4_only,
    update_strategy: PeeringUpdateStrategy = .independent,
};

pub const NetworkPeering = struct {
    pub const Outputs = struct {
        pub const ResourceId = output.Descriptor("resource_id", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
    };
    node: resource.ResourceNode,
    resource_id: Outputs.ResourceId.OutputType,
    state: Outputs.State.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: NetworkPeeringArgs) BuildError!NetworkPeering {
        try provider.validate();
        try validateName(args.name);
        try validateName(args.network_name);
        const fields = [_]value.Field{
            .{ .name = "export_custom_routes", .value = .{ .boolean = args.export_custom_routes } },
            .{ .name = "export_subnet_routes_with_public_ip", .value = .{ .boolean = args.export_subnet_routes_with_public_ip } },
            .{ .name = "import_custom_routes", .value = .{ .boolean = args.import_custom_routes } },
            .{ .name = "import_subnet_routes_with_public_ip", .value = .{ .boolean = args.import_subnet_routes_with_public_ip } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "network", .value = try publicOutputValue(args.network) },
            .{ .name = "network_name", .value = .{ .string = args.network_name } },
            .{ .name = "peer_network", .value = try publicOutputValue(args.peer_network) },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "stack_type", .value = .{ .string = stackText(args.stack_type) } },
            .{ .name = "update_strategy", .value = .{ .string = if (args.update_strategy == .consensus) "CONSENSUS" else "INDEPENDENT" } },
        };
        const logical_id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ args.network_name, args.name });
        defer allocator.free(logical_id);
        const node = try nodeOwned(allocator, "gcp.compute.NetworkPeering", logical_id, args.name, &fields, .{});
        return .{ .node = node, .resource_id = Outputs.ResourceId.fromResource(node.id), .state = Outputs.State.fromResource(node.id) };
    }

    pub fn deinit(self: *NetworkPeering, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const HubTopology = enum { mesh, star };
pub const HubArgs = struct {
    name: []const u8,
    description: []const u8 = "",
    topology: HubTopology = .mesh,
    export_psc: bool = false,
    labels: []const Label = &.{},
    protect: bool = false,
};

pub const Hub = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    state: Outputs.State.OutputType,
    etag: Outputs.Etag.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: HubArgs) BuildError!Hub {
        try provider.validate();
        try validateName(args.name);
        var labels = try labelsValueOwned(allocator, args.labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "export_psc", .value = .{ .boolean = args.export_psc } },
            .{ .name = "labels", .value = labels },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "policy_mode", .value = .{ .string = "PRESET" } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "topology", .value = .{ .string = if (args.topology == .star) "STAR" else "MESH" } },
        };
        const node = try nodeOwned(allocator, "gcp.networkconnectivity.Hub", args.name, args.name, &fields, .{ .protect = args.protect });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .state = Outputs.State.fromResource(node.id), .etag = Outputs.Etag.fromResource(node.id) };
    }

    pub fn deinit(self: *Hub, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const SpokeLink = union(enum) {
    vpc_network: output.Output([]const u8, .public),
    vpn_tunnels: []const output.Output([]const u8, .public),
    interconnect_attachments: []const output.Output([]const u8, .public),
    router_appliances: []const RouterApplianceInstance,
};
pub const RouterApplianceInstance = struct {
    virtual_machine: output.Output([]const u8, .public),
    ip_address: []const u8,
};
pub const SpokeArgs = struct {
    name: []const u8,
    location: []const u8,
    hub: output.Output([]const u8, .public),
    link: SpokeLink,
    group: ?output.Output([]const u8, .public) = null,
    description: []const u8 = "",
    labels: []const Label = &.{},
    site_to_site_data_transfer: bool = false,
    protect: bool = false,
};

pub const Spoke = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    state: Outputs.State.OutputType,
    etag: Outputs.Etag.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: SpokeArgs) BuildError!Spoke {
        try provider.validate();
        try validateName(args.name);
        try validateLocation(args.location);
        var labels = try labelsValueOwned(allocator, args.labels);
        defer labels.deinit(allocator);
        var links: value.Value = undefined;
        const kind: []const u8 = switch (args.link) {
            .vpc_network => |network| blk: {
                if (!std.mem.eql(u8, args.location, "global")) return error.InvalidSpoke;
                links = try outputListValueOwned(allocator, &.{network});
                break :blk "VPC_NETWORK";
            },
            .vpn_tunnels => |items| blk: {
                if (items.len == 0 or std.mem.eql(u8, args.location, "global")) return error.InvalidSpoke;
                links = try outputListValueOwned(allocator, items);
                break :blk "VPN_TUNNELS";
            },
            .interconnect_attachments => |items| blk: {
                if (items.len == 0 or std.mem.eql(u8, args.location, "global")) return error.InvalidSpoke;
                links = try outputListValueOwned(allocator, items);
                break :blk "INTERCONNECT_ATTACHMENTS";
            },
            .router_appliances => |items| blk: {
                if (items.len == 0 or std.mem.eql(u8, args.location, "global")) return error.InvalidSpoke;
                links = try routerApplianceListValueOwned(allocator, items);
                break :blk "ROUTER_APPLIANCES";
            },
        };
        defer links.deinit(allocator);
        const group = if (args.group) |present| try publicOutputValue(present) else value.Value{ .string = "" };
        const fields = [_]value.Field{
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "group", .value = group },
            .{ .name = "hub", .value = try publicOutputValue(args.hub) },
            .{ .name = "labels", .value = labels },
            .{ .name = "link_kind", .value = .{ .string = kind } },
            .{ .name = "links", .value = links },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "site_to_site_data_transfer", .value = .{ .boolean = args.site_to_site_data_transfer } },
        };
        const logical_id = try regionalIdAlloc(allocator, args.location, args.name);
        defer allocator.free(logical_id);
        const node = try nodeOwned(allocator, "gcp.networkconnectivity.Spoke", logical_id, args.name, &fields, .{ .protect = args.protect });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .state = Outputs.State.fromResource(node.id), .etag = Outputs.Etag.fromResource(node.id) };
    }

    pub fn deinit(self: *Spoke, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const ProducerLocation = enum { automatic, custom };
pub const ServiceConnectionPolicyArgs = struct {
    name: []const u8,
    location: []const u8,
    network: output.Output([]const u8, .public),
    service_class: []const u8,
    subnetworks: []const output.Output([]const u8, .public),
    producer_location: ProducerLocation = .automatic,
    allowed_producer_hierarchy: []const []const u8 = &.{},
    description: []const u8 = "",
    labels: []const Label = &.{},
    protect: bool = false,
};

pub const ServiceConnectionPolicy = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
        pub const PscConnectionLimit = output.Descriptor("psc_connection_limit", i64, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    etag: Outputs.Etag.OutputType,
    psc_connection_limit: Outputs.PscConnectionLimit.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ServiceConnectionPolicyArgs) BuildError!ServiceConnectionPolicy {
        try provider.validate();
        try validateName(args.name);
        try validateLocation(args.location);
        if (args.service_class.len == 0 or args.subnetworks.len == 0) return error.InvalidPolicy;
        if (args.producer_location == .automatic and args.allowed_producer_hierarchy.len > 0) return error.InvalidPolicy;
        for (args.allowed_producer_hierarchy) |resource_name| try validateHierarchyResource(resource_name);
        var labels = try labelsValueOwned(allocator, args.labels);
        defer labels.deinit(allocator);
        var subnetworks = try outputListValueOwned(allocator, args.subnetworks);
        defer subnetworks.deinit(allocator);
        var levels = try stringListValueOwned(allocator, args.allowed_producer_hierarchy);
        defer levels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "allowed_producer_hierarchy", .value = levels },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "network", .value = try publicOutputValue(args.network) },
            .{ .name = "producer_location", .value = .{ .string = if (args.producer_location == .custom) "CUSTOM_RESOURCE_HIERARCHY_LEVELS" else "PRODUCER_INSTANCE_LOCATION_UNSPECIFIED" } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "service_class", .value = .{ .string = args.service_class } },
            .{ .name = "subnetworks", .value = subnetworks },
        };
        const logical_id = try regionalIdAlloc(allocator, args.location, args.name);
        defer allocator.free(logical_id);
        const node = try nodeOwned(allocator, "gcp.networkconnectivity.ServiceConnectionPolicy", logical_id, args.name, &fields, .{ .protect = args.protect });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .etag = Outputs.Etag.fromResource(node.id), .psc_connection_limit = Outputs.PscConnectionLimit.fromResource(node.id) };
    }

    pub fn deinit(self: *ServiceConnectionPolicy, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn nodeOwned(allocator: std.mem.Allocator, type_name: []const u8, logical_id: []const u8, name: []const u8, fields: []const value.Field, lifecycle: resource.Lifecycle) BuildError!resource.ResourceNode {
    const id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_name, logical_id });
    defer allocator.free(id);
    return resource.ResourceNode.initOwned(allocator, .{
        .id = id,
        .provider = .gcp,
        .type_name = type_name,
        .logical_id = name,
        .inputs = .{ .object = fields },
        .lifecycle = lifecycle,
    }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
    };
}

fn interfaceListValueOwned(allocator: std.mem.Allocator, interfaces: []const ExternalVpnInterface) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, interfaces.len);
    defer allocator.free(items);
    for (interfaces, 0..) |interface, index| {
        if (interface.id != index or !isIpv4(interface.ip_address)) return error.InvalidInterfaces;
        const fields = [_]value.Field{
            .{ .name = "id", .value = .{ .integer = interface.id } },
            .{ .name = "ip_address", .value = .{ .string = interface.ip_address } },
        };
        items[index] = .{ .object = &fields };
    }
    return value.Value.initOwned(allocator, .{ .list = items }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn labelsValueOwned(allocator: std.mem.Allocator, labels: []const Label) BuildError!value.Value {
    const fields = try allocator.alloc(value.Field, labels.len);
    defer allocator.free(fields);
    for (labels, 0..) |label, index| {
        try validateLabel(label);
        fields[index] = .{ .name = label.key, .value = .{ .string = label.value } };
    }
    return value.Value.initOwned(allocator, .{ .object = fields }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateValue,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn stringListValueOwned(allocator: std.mem.Allocator, strings: []const []const u8) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, strings.len);
    defer allocator.free(items);
    for (strings, 0..) |string, index| items[index] = .{ .string = string };
    return value.Value.initOwned(allocator, .{ .list = items }) catch |err| switch (err) {
        error.DuplicateField => unreachable,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn outputListValueOwned(allocator: std.mem.Allocator, outputs: []const output.Output([]const u8, .public)) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, outputs.len);
    defer allocator.free(items);
    for (outputs, 0..) |item, index| items[index] = try publicOutputValue(item);
    return value.Value.initOwned(allocator, .{ .list = items }) catch |err| switch (err) {
        error.DuplicateField => unreachable,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn routerApplianceListValueOwned(allocator: std.mem.Allocator, instances: []const RouterApplianceInstance) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, instances.len);
    defer allocator.free(items);
    for (instances, 0..) |instance, index| {
        if (!isIpv4(instance.ip_address)) return error.InvalidAddress;
        const fields = [_]value.Field{
            .{ .name = "ip_address", .value = .{ .string = instance.ip_address } },
            .{ .name = "virtual_machine", .value = try publicOutputValue(instance.virtual_machine) },
        };
        items[index] = .{ .object = &fields };
    }
    return value.Value.initOwned(allocator, .{ .list = items }) catch |err| switch (err) {
        error.DuplicateField => unreachable,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn publicOutputValue(result: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (result) {
        .value => |known| .{ .string = known },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn secretOutputValue(result: output.Output(value.SecretReference, .secret)) BuildError!value.Value {
    return switch (result) {
        .value => |known| .{ .secret_ref = known },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn regionalIdAlloc(allocator: std.mem.Allocator, region: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ region, name });
}

fn parentChildIdAlloc(allocator: std.mem.Allocator, region: []const u8, parent: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ region, parent, name });
}

fn stackText(stack: anytype) []const u8 {
    return if (stack == .ipv4_ipv6) "IPV4_IPV6" else "IPV4_ONLY";
}

fn validateName(name: []const u8) BuildError!void {
    if (name.len == 0 or name.len > 63 or !std.ascii.isLower(name[0])) return error.InvalidName;
    if (!std.ascii.isLower(name[name.len - 1]) and !std.ascii.isDigit(name[name.len - 1])) return error.InvalidName;
    for (name) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return error.InvalidName;
}

fn validateLocation(location: []const u8) BuildError!void {
    if (std.mem.eql(u8, location, "global")) return;
    try validateName(location);
}

fn validateLabel(label: Label) BuildError!void {
    if (label.key.len == 0 or label.key.len > 63 or label.value.len > 63) return error.InvalidValue;
    for (label.key) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '_' and character != '-') return error.InvalidValue;
}

fn validatePrivateAsn(asn: u32) BuildError!void {
    if (!((asn >= 64_512 and asn <= 65_534) or (asn >= 4_200_000_000 and asn <= 4_294_967_294))) return error.InvalidAsn;
}

fn validateBfd(bfd: BfdConfig) BuildError!void {
    if (bfd.min_transmit_ms < 1000 or bfd.min_transmit_ms > 30_000 or bfd.min_receive_ms < 1000 or bfd.min_receive_ms > 30_000 or bfd.multiplier < 5 or bfd.multiplier > 16) return error.InvalidBfd;
}

fn validateHierarchyResource(resource_name: []const u8) BuildError!void {
    const prefixes = [_][]const u8{ "projects/", "folders/", "organizations/" };
    for (prefixes) |prefix| if (std.mem.startsWith(u8, resource_name, prefix) and resource_name.len > prefix.len) return;
    return error.InvalidHierarchyLevel;
}

fn validateLinkLocalCidr(cidr: []const u8) BuildError!void {
    if (!std.mem.endsWith(u8, cidr, "/30")) return error.InvalidCidr;
    try validateLinkLocalAddress(cidr[0 .. cidr.len - 3]);
}

fn validateLinkLocalAddress(address: []const u8) BuildError!void {
    if (!std.mem.startsWith(u8, address, "169.254.") or !isIpv4(address)) return error.InvalidAddress;
}

fn isIpv4(address: []const u8) bool {
    var parts = std.mem.splitScalar(u8, address, '.');
    var count: usize = 0;
    while (parts.next()) |part| : (count += 1) {
        if (part.len == 0) return false;
        _ = std.fmt.parseInt(u8, part, 10) catch return false;
    }
    return count == 4;
}
