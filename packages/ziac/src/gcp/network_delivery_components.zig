const std = @import("std");
const config_mod = @import("config.zig");
const delivery = @import("network_delivery.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");

pub const BuildError = delivery.BuildError || resource.ResourceGraphError || std.mem.Allocator.Error;

pub const PolicyFirewall = struct {
    name: []const u8,
    direction: delivery.FirewallDirection,
    action: delivery.FirewallAction,
    priority: u16 = 1000,
    source_ranges: []const []const u8 = &.{},
    destination_ranges: []const []const u8 = &.{},
    source_tags: []const []const u8 = &.{},
    target_tags: []const []const u8 = &.{},
    source_service_accounts: []const []const u8 = &.{},
    target_service_accounts: []const []const u8 = &.{},
    disabled: bool = false,
    logging: bool = true,
};

pub const PolicyRoute = struct {
    name: []const u8,
    destination_range: []const u8,
    next_hop: delivery.RouteNextHop,
    priority: u16 = 1000,
    tags: []const []const u8 = &.{},
};

pub const NetworkPolicyArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    network: output.Output([]const u8, .public),
    firewalls: []const PolicyFirewall = &.{},
    routes: []const PolicyRoute = &.{},
    protect: bool = false,
    retain_on_delete: bool = false,
};

pub const NetworkPolicy = struct {
    graph: resource.ResourceGraph,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: NetworkPolicyArgs) BuildError!NetworkPolicy {
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);
        for (args.firewalls) |item| {
            var firewall = try delivery.Firewall.build(allocator, provider, .{
                .name = item.name,
                .network = args.network,
                .direction = item.direction,
                .action = item.action,
                .priority = item.priority,
                .source_ranges = item.source_ranges,
                .destination_ranges = item.destination_ranges,
                .source_tags = item.source_tags,
                .target_tags = item.target_tags,
                .source_service_accounts = item.source_service_accounts,
                .target_service_accounts = item.target_service_accounts,
                .disabled = item.disabled,
                .logging = item.logging,
                .protect = args.protect,
                .retain_on_delete = args.retain_on_delete,
            });
            defer firewall.deinit(allocator);
            try graph.addResource(firewall.node);
        }
        for (args.routes) |item| {
            var route = try delivery.Route.build(allocator, provider, .{
                .name = item.name,
                .network = args.network,
                .destination_range = item.destination_range,
                .next_hop = item.next_hop,
                .priority = item.priority,
                .tags = item.tags,
                .protect = args.protect,
                .retain_on_delete = args.retain_on_delete,
            });
            defer route.deinit(allocator);
            try graph.addResource(route.node);
        }
        try graph.validateAcyclic();
        return .{ .graph = graph };
    }

    pub fn deinit(self: *NetworkPolicy) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

pub const InternalPassthroughLoadBalancerArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    region: []const u8,
    network: output.Output([]const u8, .public),
    subnetwork: output.Output([]const u8, .public),
    backend_group: output.Output([]const u8, .public),
    health_protocol: delivery.HealthProtocol = .tcp,
    health_port: u16,
    health_request_path: []const u8 = "/",
    protocol: delivery.ForwardingProtocol,
    ports: []const []const u8 = &.{},
    all_ports: bool = false,
    allow_global_access: bool = false,
    address: []const u8 = "",
    failover: bool = false,
    connection_draining_seconds: u32 = 0,
    protect: bool = true,
    retain_address: bool = true,
};

pub const InternalPassthroughLoadBalancer = struct {
    graph: resource.ResourceGraph,
    address: output.Output([]const u8, .public),
    forwarding_rule: output.Output([]const u8, .public),
    backend_service: output.Output([]const u8, .public),
    health_check: output.Output([]const u8, .public),

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: InternalPassthroughLoadBalancerArgs) BuildError!InternalPassthroughLoadBalancer {
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);
        const names = try Names.init(allocator, args.name);
        defer names.deinit(allocator);

        const health_index = graph.resources.items.len;
        var health = try delivery.RegionHealthCheck.build(allocator, provider, .{
            .name = names.health,
            .region = args.region,
            .protocol = args.health_protocol,
            .port = args.health_port,
            .request_path = args.health_request_path,
            .logging = true,
            .protect = args.protect,
        });
        defer health.deinit(allocator);
        try graph.addResource(health.node);
        const health_id = graph.resources.items[health_index].id;

        const address_index = graph.resources.items.len;
        var address = try delivery.InternalAddress.build(allocator, provider, .{
            .name = names.vip,
            .region = args.region,
            .subnetwork = args.subnetwork,
            .address = args.address,
            .purpose = .shared_load_balancer_vip,
            .protect = args.protect,
            .retain_on_delete = args.retain_address,
        });
        defer address.deinit(allocator);
        try graph.addResource(address.node);
        const address_id = graph.resources.items[address_index].id;

        const backend_index = graph.resources.items.len;
        var backend = try delivery.RegionBackendService.build(allocator, provider, .{
            .name = names.backend,
            .region = args.region,
            .mode = .internal_passthrough,
            .protocol = switch (args.protocol) {
                .tcp => .tcp,
                .udp => .udp,
                .l3_default => .unspecified,
            },
            .network = args.network,
            .health_check = delivery.RegionHealthCheck.Outputs.SelfLink.fromResource(health_id),
            .backends = &.{.{ .group = args.backend_group, .balancing_mode = .connection, .failover = args.failover }},
            .connection_draining_seconds = args.connection_draining_seconds,
            .protect = args.protect,
        });
        defer backend.deinit(allocator);
        try graph.addResource(backend.node);
        const backend_id = graph.resources.items[backend_index].id;

        const forwarding_index = graph.resources.items.len;
        var forwarding = try delivery.ForwardingRule.build(allocator, provider, .{
            .name = args.name,
            .region = args.region,
            .scheme = .internal,
            .network = args.network,
            .subnetwork = args.subnetwork,
            .address = delivery.InternalAddress.Outputs.Address.fromResource(address_id),
            .target = .{ .backend_service = delivery.RegionBackendService.Outputs.SelfLink.fromResource(backend_id) },
            .protocol = args.protocol,
            .ports = args.ports,
            .all_ports = args.all_ports,
            .allow_global_access = args.allow_global_access,
            .protect = args.protect,
        });
        defer forwarding.deinit(allocator);
        try graph.addResource(forwarding.node);
        const forwarding_id = graph.resources.items[forwarding_index].id;
        try graph.validateAcyclic();
        return .{
            .graph = graph,
            .address = delivery.InternalAddress.Outputs.Address.fromResource(address_id),
            .forwarding_rule = delivery.ForwardingRule.Outputs.SelfLink.fromResource(forwarding_id),
            .backend_service = delivery.RegionBackendService.Outputs.SelfLink.fromResource(backend_id),
            .health_check = delivery.RegionHealthCheck.Outputs.SelfLink.fromResource(health_id),
        };
    }

    pub fn deinit(self: *InternalPassthroughLoadBalancer) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

pub const RegionalInternalApplicationLoadBalancerArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    region: []const u8,
    network: output.Output([]const u8, .public),
    subnetwork: output.Output([]const u8, .public),
    proxy_only_subnet: output.Output([]const u8, .public),
    backend_group: output.Output([]const u8, .public),
    health_protocol: delivery.HealthProtocol = .http,
    health_port: u16,
    health_request_path: []const u8 = "/ready",
    backend_protocol: delivery.BackendProtocol = .http,
    backend_port_name: []const u8,
    frontend_port: u16,
    allow_global_access: bool = false,
    address: []const u8 = "",
    protect: bool = true,
    retain_address: bool = true,
};

pub const RegionalInternalApplicationLoadBalancer = struct {
    graph: resource.ResourceGraph,
    address: output.Output([]const u8, .public),
    forwarding_rule: output.Output([]const u8, .public),
    backend_service: output.Output([]const u8, .public),

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: RegionalInternalApplicationLoadBalancerArgs) BuildError!RegionalInternalApplicationLoadBalancer {
        if (args.proxy_only_subnet.referenceOrNull() == null) return error.InvalidLoadBalancerMode;
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);
        const names = try Names.init(allocator, args.name);
        defer names.deinit(allocator);

        const health_index = graph.resources.items.len;
        var health = try delivery.RegionHealthCheck.build(allocator, provider, .{
            .name = names.health,
            .region = args.region,
            .protocol = args.health_protocol,
            .port = args.health_port,
            .request_path = args.health_request_path,
            .logging = true,
            .protect = args.protect,
        });
        defer health.deinit(allocator);
        try graph.addResource(health.node);
        const health_id = graph.resources.items[health_index].id;

        const address_index = graph.resources.items.len;
        var address = try delivery.InternalAddress.build(allocator, provider, .{
            .name = names.vip,
            .region = args.region,
            .subnetwork = args.subnetwork,
            .address = args.address,
            .purpose = .shared_load_balancer_vip,
            .protect = args.protect,
            .retain_on_delete = args.retain_address,
        });
        defer address.deinit(allocator);
        try graph.addResource(address.node);
        const address_id = graph.resources.items[address_index].id;

        const backend_index = graph.resources.items.len;
        var backend = try delivery.RegionBackendService.build(allocator, provider, .{
            .name = names.backend,
            .region = args.region,
            .mode = .internal_application,
            .protocol = args.backend_protocol,
            .network = args.network,
            .health_check = delivery.RegionHealthCheck.Outputs.SelfLink.fromResource(health_id),
            .backends = &.{.{ .group = args.backend_group, .balancing_mode = .utilization }},
            .port_name = args.backend_port_name,
            .protect = args.protect,
        });
        defer backend.deinit(allocator);
        try graph.addResource(backend.node);
        const backend_id = graph.resources.items[backend_index].id;

        const map_index = graph.resources.items.len;
        var url_map = try delivery.RegionUrlMap.build(allocator, provider, .{
            .name = names.map,
            .region = args.region,
            .default_service = delivery.RegionBackendService.Outputs.SelfLink.fromResource(backend_id),
            .protect = args.protect,
        });
        defer url_map.deinit(allocator);
        try graph.addResource(url_map.node);
        const map_id = graph.resources.items[map_index].id;

        const proxy_index = graph.resources.items.len;
        var proxy = try delivery.RegionTargetHttpProxy.build(allocator, provider, .{
            .name = names.http,
            .region = args.region,
            .url_map = delivery.RegionUrlMap.Outputs.SelfLink.fromResource(map_id),
            .protect = args.protect,
        });
        defer proxy.deinit(allocator);
        try graph.addResource(proxy.node);
        const proxy_id = graph.resources.items[proxy_index].id;

        const port = try std.fmt.allocPrint(allocator, "{d}", .{args.frontend_port});
        defer allocator.free(port);
        const forwarding_index = graph.resources.items.len;
        var forwarding = try delivery.ForwardingRule.build(allocator, provider, .{
            .name = args.name,
            .region = args.region,
            .scheme = .internal_managed,
            .network = args.network,
            .subnetwork = args.subnetwork,
            .address = delivery.InternalAddress.Outputs.Address.fromResource(address_id),
            .target = .{ .target_proxy = delivery.RegionTargetHttpProxy.Outputs.SelfLink.fromResource(proxy_id) },
            .protocol = .tcp,
            .ports = &.{port},
            .allow_global_access = args.allow_global_access,
            .protect = args.protect,
        });
        defer forwarding.deinit(allocator);
        try graph.addResource(forwarding.node);
        const forwarding_id = graph.resources.items[forwarding_index].id;
        try graph.bindOutput(forwarding_id, args.proxy_only_subnet);
        try graph.validateAcyclic();
        return .{
            .graph = graph,
            .address = delivery.InternalAddress.Outputs.Address.fromResource(address_id),
            .forwarding_rule = delivery.ForwardingRule.Outputs.SelfLink.fromResource(forwarding_id),
            .backend_service = delivery.RegionBackendService.Outputs.SelfLink.fromResource(backend_id),
        };
    }

    pub fn deinit(self: *RegionalInternalApplicationLoadBalancer) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

const Names = struct {
    health: []const u8,
    vip: []const u8,
    backend: []const u8,
    map: []const u8,
    http: []const u8,

    fn init(allocator: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error!Names {
        const health = try std.fmt.allocPrint(allocator, "{s}-health", .{name});
        errdefer allocator.free(health);
        const vip = try std.fmt.allocPrint(allocator, "{s}-vip", .{name});
        errdefer allocator.free(vip);
        const backend = try std.fmt.allocPrint(allocator, "{s}-backend", .{name});
        errdefer allocator.free(backend);
        const map = try std.fmt.allocPrint(allocator, "{s}-map", .{name});
        errdefer allocator.free(map);
        const http = try std.fmt.allocPrint(allocator, "{s}-http", .{name});
        return .{ .health = health, .vip = vip, .backend = backend, .map = map, .http = http };
    }

    fn deinit(self: Names, allocator: std.mem.Allocator) void {
        allocator.free(self.health);
        allocator.free(self.vip);
        allocator.free(self.backend);
        allocator.free(self.map);
        allocator.free(self.http);
    }
};
