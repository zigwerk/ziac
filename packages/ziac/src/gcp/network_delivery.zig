const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    DuplicateValue,
    InvalidBackend,
    InvalidCidr,
    InvalidFirewallScope,
    InvalidHealthProtocol,
    InvalidHealthTiming,
    InvalidLoadBalancerMode,
    InvalidName,
    InvalidPort,
    InvalidPriority,
    InvalidRoute,
    InvalidValue,
    OutputNotKnown,
};

pub const ProtocolPorts = struct {
    protocol: []const u8,
    ports: []const []const u8 = &.{},
};

pub const FirewallDirection = enum { ingress, egress };
pub const FirewallAction = union(enum) {
    allow: []const ProtocolPorts,
    deny: []const ProtocolPorts,
};

pub const FirewallArgs = struct {
    name: []const u8,
    network: output.Output([]const u8, .public),
    direction: FirewallDirection,
    action: FirewallAction,
    priority: u16 = 1000,
    source_ranges: []const []const u8 = &.{},
    destination_ranges: []const []const u8 = &.{},
    source_tags: []const []const u8 = &.{},
    target_tags: []const []const u8 = &.{},
    source_service_accounts: []const []const u8 = &.{},
    target_service_accounts: []const []const u8 = &.{},
    disabled: bool = false,
    logging: bool = false,
    protect: bool = false,
    retain_on_delete: bool = false,
};

pub const Firewall = struct {
    pub const Outputs = struct {
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
        pub const Fingerprint = output.Descriptor("fingerprint", []const u8, .public);
    };
    node: resource.ResourceNode,
    self_link: Outputs.SelfLink.OutputType,
    fingerprint: Outputs.Fingerprint.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: FirewallArgs) BuildError!Firewall {
        try provider.validate();
        try validateName(args.name);
        if (args.direction == .ingress and args.destination_ranges.len > 0) return error.InvalidFirewallScope;
        if (args.direction == .egress and (args.source_ranges.len > 0 or args.source_tags.len > 0 or args.source_service_accounts.len > 0)) return error.InvalidFirewallScope;
        try validateCidrs(args.source_ranges);
        try validateCidrs(args.destination_ranges);
        var rules = switch (args.action) {
            .allow => |items| try protocolRulesValueOwned(allocator, items),
            .deny => |items| try protocolRulesValueOwned(allocator, items),
        };
        defer rules.deinit(allocator);
        var source_ranges = try stringListValueOwned(allocator, args.source_ranges);
        defer source_ranges.deinit(allocator);
        var destination_ranges = try stringListValueOwned(allocator, args.destination_ranges);
        defer destination_ranges.deinit(allocator);
        var source_tags = try stringListValueOwned(allocator, args.source_tags);
        defer source_tags.deinit(allocator);
        var target_tags = try stringListValueOwned(allocator, args.target_tags);
        defer target_tags.deinit(allocator);
        var source_accounts = try stringListValueOwned(allocator, args.source_service_accounts);
        defer source_accounts.deinit(allocator);
        var target_accounts = try stringListValueOwned(allocator, args.target_service_accounts);
        defer target_accounts.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "action", .value = .{ .string = switch (args.action) {
                .allow => "ALLOW",
                .deny => "DENY",
            } } },
            .{ .name = "destination_ranges", .value = destination_ranges },
            .{ .name = "direction", .value = .{ .string = if (args.direction == .ingress) "INGRESS" else "EGRESS" } },
            .{ .name = "disabled", .value = .{ .boolean = args.disabled } },
            .{ .name = "logging", .value = .{ .boolean = args.logging } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "network", .value = try publicOutputValue(args.network) },
            .{ .name = "priority", .value = .{ .integer = args.priority } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "rules", .value = rules },
            .{ .name = "source_ranges", .value = source_ranges },
            .{ .name = "source_service_accounts", .value = source_accounts },
            .{ .name = "source_tags", .value = source_tags },
            .{ .name = "target_service_accounts", .value = target_accounts },
            .{ .name = "target_tags", .value = target_tags },
        };
        const node = try nodeOwned(allocator, "gcp.compute.Firewall", args.name, args.name, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
        });
        return .{ .node = node, .self_link = Outputs.SelfLink.fromResource(node.id), .fingerprint = Outputs.Fingerprint.fromResource(node.id) };
    }

    pub fn deinit(self: *Firewall, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const RouteNextHop = union(enum) {
    gateway: output.Output([]const u8, .public),
    instance: output.Output([]const u8, .public),
    ip_address: []const u8,
    vpn_tunnel: output.Output([]const u8, .public),
    forwarding_rule: output.Output([]const u8, .public),
};

pub const RouteArgs = struct {
    name: []const u8,
    network: output.Output([]const u8, .public),
    destination_range: []const u8,
    next_hop: RouteNextHop,
    priority: u16 = 1000,
    tags: []const []const u8 = &.{},
    protect: bool = false,
    retain_on_delete: bool = false,
};

pub const Route = struct {
    pub const Outputs = struct {
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
        pub const Status = output.Descriptor("status", []const u8, .public);
    };
    node: resource.ResourceNode,
    self_link: Outputs.SelfLink.OutputType,
    status: Outputs.Status.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: RouteArgs) BuildError!Route {
        try provider.validate();
        try validateName(args.name);
        try validateCidr(args.destination_range);
        const hop_kind: []const u8, const hop_value: value.Value = switch (args.next_hop) {
            .gateway => |candidate| .{ "gateway", try publicOutputValue(candidate) },
            .instance => |candidate| .{ "instance", try publicOutputValue(candidate) },
            .ip_address => |candidate| .{ "ip_address", .{ .string = candidate } },
            .vpn_tunnel => |candidate| .{ "vpn_tunnel", try publicOutputValue(candidate) },
            .forwarding_rule => |candidate| .{ "forwarding_rule", try publicOutputValue(candidate) },
        };
        if (hop_value == .string and hop_value.string.len == 0) return error.InvalidRoute;
        var tags = try stringListValueOwned(allocator, args.tags);
        defer tags.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "destination_range", .value = .{ .string = args.destination_range } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "network", .value = try publicOutputValue(args.network) },
            .{ .name = "next_hop_kind", .value = .{ .string = hop_kind } },
            .{ .name = "next_hop_value", .value = hop_value },
            .{ .name = "priority", .value = .{ .integer = args.priority } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "tags", .value = tags },
        };
        const node = try nodeOwned(allocator, "gcp.compute.Route", args.name, args.name, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
            .replace_before_delete = true,
        });
        return .{ .node = node, .self_link = Outputs.SelfLink.fromResource(node.id), .status = Outputs.Status.fromResource(node.id) };
    }

    pub fn deinit(self: *Route, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const HealthProtocol = enum { http, https, http2, tcp, ssl, grpc };
pub const ProxyHeader = enum { none, proxy_v1 };

pub const HealthCheckArgs = struct {
    name: []const u8,
    protocol: HealthProtocol,
    port: u16,
    port_name: []const u8 = "",
    request_path: []const u8 = "/",
    host: []const u8 = "",
    grpc_service_name: []const u8 = "",
    proxy_header: ProxyHeader = .none,
    check_interval_seconds: u32 = 5,
    timeout_seconds: u32 = 5,
    healthy_threshold: u32 = 2,
    unhealthy_threshold: u32 = 2,
    logging: bool = false,
    protect: bool = false,
    retain_on_delete: bool = false,
};

pub const RegionHealthCheckArgs = struct {
    name: []const u8,
    region: []const u8,
    protocol: HealthProtocol,
    port: u16,
    port_name: []const u8 = "",
    request_path: []const u8 = "/",
    host: []const u8 = "",
    grpc_service_name: []const u8 = "",
    proxy_header: ProxyHeader = .none,
    check_interval_seconds: u32 = 5,
    timeout_seconds: u32 = 5,
    healthy_threshold: u32 = 2,
    unhealthy_threshold: u32 = 2,
    logging: bool = false,
    protect: bool = false,
    retain_on_delete: bool = false,
};

pub const HealthCheck = HealthCheckResource(false);
pub const RegionHealthCheck = HealthCheckResource(true);

fn HealthCheckResource(comptime regional: bool) type {
    return struct {
        pub const Outputs = struct {
            pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
            pub const Status = output.Descriptor("status", []const u8, .public);
            pub const Fingerprint = output.Descriptor("fingerprint", []const u8, .public);
        };
        node: resource.ResourceNode,
        self_link: Outputs.SelfLink.OutputType,
        status: Outputs.Status.OutputType,
        fingerprint: Outputs.Fingerprint.OutputType,

        pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: if (regional) RegionHealthCheckArgs else HealthCheckArgs) BuildError!@This() {
            try provider.validate();
            try validateName(args.name);
            if (regional) try validateRegion(args.region);
            try validateHealth(args.protocol, args.port, args.port_name, args.request_path, args.grpc_service_name, args.check_interval_seconds, args.timeout_seconds, args.healthy_threshold, args.unhealthy_threshold);
            const fields = [_]value.Field{
                .{ .name = "check_interval_seconds", .value = .{ .integer = args.check_interval_seconds } },
                .{ .name = "grpc_service_name", .value = .{ .string = args.grpc_service_name } },
                .{ .name = "healthy_threshold", .value = .{ .integer = args.healthy_threshold } },
                .{ .name = "host", .value = .{ .string = args.host } },
                .{ .name = "logging", .value = .{ .boolean = args.logging } },
                .{ .name = "name", .value = .{ .string = args.name } },
                .{ .name = "port", .value = .{ .integer = args.port } },
                .{ .name = "port_name", .value = .{ .string = args.port_name } },
                .{ .name = "project_id", .value = .{ .string = provider.project_id } },
                .{ .name = "protocol", .value = .{ .string = protocolName(args.protocol) } },
                .{ .name = "proxy_header", .value = .{ .string = if (args.proxy_header == .proxy_v1) "PROXY_V1" else "NONE" } },
                .{ .name = "region", .value = .{ .string = if (regional) args.region else "" } },
                .{ .name = "request_path", .value = .{ .string = args.request_path } },
                .{ .name = "timeout_seconds", .value = .{ .integer = args.timeout_seconds } },
                .{ .name = "unhealthy_threshold", .value = .{ .integer = args.unhealthy_threshold } },
            };
            const type_name = if (regional) "gcp.compute.RegionHealthCheck" else "gcp.compute.HealthCheck";
            const scope = if (regional) args.region else "global";
            const logical_id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ scope, args.name });
            defer allocator.free(logical_id);
            const node = try nodeOwned(allocator, type_name, logical_id, args.name, &fields, .{
                .protect = args.protect,
                .retain_on_delete = args.retain_on_delete,
            });
            return .{
                .node = node,
                .self_link = Outputs.SelfLink.fromResource(node.id),
                .status = Outputs.Status.fromResource(node.id),
                .fingerprint = Outputs.Fingerprint.fromResource(node.id),
            };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.node.deinit(allocator);
            self.* = undefined;
        }
    };
}

pub const AddressPurpose = enum { generic, shared_load_balancer_vip };
pub const InternalAddressArgs = struct {
    name: []const u8,
    region: []const u8,
    subnetwork: output.Output([]const u8, .public),
    address: []const u8 = "",
    purpose: AddressPurpose = .generic,
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const InternalAddress = struct {
    pub const Outputs = struct {
        pub const Address = output.Descriptor("address", []const u8, .public);
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
    };
    node: resource.ResourceNode,
    address: Outputs.Address.OutputType,
    self_link: Outputs.SelfLink.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: InternalAddressArgs) BuildError!InternalAddress {
        try provider.validate();
        try validateName(args.name);
        try validateRegion(args.region);
        if (args.address.len > 0) try validateIp(args.address);
        const fields = [_]value.Field{
            .{ .name = "address", .value = .{ .string = args.address } },
            .{ .name = "address_type", .value = .{ .string = "INTERNAL" } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "purpose", .value = .{ .string = if (args.purpose == .shared_load_balancer_vip) "SHARED_LOADBALANCER_VIP" else "GCE_ENDPOINT" } },
            .{ .name = "region", .value = .{ .string = args.region } },
            .{ .name = "subnetwork", .value = try publicOutputValue(args.subnetwork) },
        };
        const logical_id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ args.region, args.name });
        defer allocator.free(logical_id);
        const node = try nodeOwned(allocator, "gcp.compute.InternalAddress", logical_id, args.name, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
        });
        return .{ .node = node, .address = Outputs.Address.fromResource(node.id), .self_link = Outputs.SelfLink.fromResource(node.id) };
    }

    pub fn deinit(self: *InternalAddress, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const BackendMode = enum { internal_passthrough, internal_application };
pub const BackendProtocol = enum { unspecified, tcp, udp, http, https, http2, h2c, grpc };
pub const BalancingMode = enum { connection, utilization, rate };
pub const Backend = struct {
    group: output.Output([]const u8, .public),
    balancing_mode: BalancingMode = .connection,
    max_utilization: f64 = 0.8,
    capacity_scaler: f64 = 1,
    failover: bool = false,
};

pub const RegionBackendServiceArgs = struct {
    name: []const u8,
    region: []const u8,
    mode: BackendMode,
    protocol: BackendProtocol,
    network: output.Output([]const u8, .public),
    health_check: output.Output([]const u8, .public),
    backends: []const Backend,
    port_name: []const u8 = "",
    timeout_seconds: u32 = 30,
    connection_draining_seconds: u32 = 0,
    session_affinity: []const u8 = "NONE",
    locality_lb_policy: []const u8 = "ROUND_ROBIN",
    protect: bool = true,
    retain_on_delete: bool = false,
};

pub const RegionBackendService = struct {
    pub const Outputs = struct {
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
        pub const Fingerprint = output.Descriptor("fingerprint", []const u8, .public);
        pub const Health = output.Descriptor("health", []const u8, .public);
    };
    node: resource.ResourceNode,
    self_link: Outputs.SelfLink.OutputType,
    fingerprint: Outputs.Fingerprint.OutputType,
    health: Outputs.Health.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: RegionBackendServiceArgs) BuildError!RegionBackendService {
        try provider.validate();
        try validateName(args.name);
        try validateRegion(args.region);
        try validateBackendMode(args.mode, args.protocol, args.port_name);
        if (args.backends.len == 0 or args.timeout_seconds == 0 or args.connection_draining_seconds > 3600) return error.InvalidBackend;
        var backends = try backendsValueOwned(allocator, args.backends);
        defer backends.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "backends", .value = backends },
            .{ .name = "connection_draining_seconds", .value = .{ .integer = args.connection_draining_seconds } },
            .{ .name = "health_check", .value = try publicOutputValue(args.health_check) },
            .{ .name = "load_balancing_scheme", .value = .{ .string = if (args.mode == .internal_passthrough) "INTERNAL" else "INTERNAL_MANAGED" } },
            .{ .name = "locality_lb_policy", .value = .{ .string = args.locality_lb_policy } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "network", .value = try publicOutputValue(args.network) },
            .{ .name = "port_name", .value = .{ .string = args.port_name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "protocol", .value = .{ .string = backendProtocolName(args.protocol) } },
            .{ .name = "region", .value = .{ .string = args.region } },
            .{ .name = "session_affinity", .value = .{ .string = args.session_affinity } },
            .{ .name = "timeout_seconds", .value = .{ .integer = args.timeout_seconds } },
        };
        const logical_id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ args.region, args.name });
        defer allocator.free(logical_id);
        const node = try nodeOwned(allocator, "gcp.compute.RegionBackendService", logical_id, args.name, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
            .operation_timeout_millis = 30 * 60 * 1000,
        });
        return .{
            .node = node,
            .self_link = Outputs.SelfLink.fromResource(node.id),
            .fingerprint = Outputs.Fingerprint.fromResource(node.id),
            .health = Outputs.Health.fromResource(node.id),
        };
    }

    pub fn deinit(self: *RegionBackendService, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const RegionUrlMapArgs = struct {
    name: []const u8,
    region: []const u8,
    default_service: output.Output([]const u8, .public),
    protect: bool = true,
    retain_on_delete: bool = false,
};

pub const RegionUrlMap = struct {
    pub const Outputs = struct {
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
        pub const Fingerprint = output.Descriptor("fingerprint", []const u8, .public);
    };
    node: resource.ResourceNode,
    self_link: Outputs.SelfLink.OutputType,
    fingerprint: Outputs.Fingerprint.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: RegionUrlMapArgs) BuildError!RegionUrlMap {
        try provider.validate();
        try validateName(args.name);
        try validateRegion(args.region);
        const fields = [_]value.Field{
            .{ .name = "default_service", .value = try publicOutputValue(args.default_service) },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "region", .value = .{ .string = args.region } },
        };
        const logical_id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ args.region, args.name });
        defer allocator.free(logical_id);
        const node = try nodeOwned(allocator, "gcp.compute.RegionUrlMap", logical_id, args.name, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
        });
        return .{ .node = node, .self_link = Outputs.SelfLink.fromResource(node.id), .fingerprint = Outputs.Fingerprint.fromResource(node.id) };
    }

    pub fn deinit(self: *RegionUrlMap, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const RegionTargetHttpProxyArgs = struct {
    name: []const u8,
    region: []const u8,
    url_map: output.Output([]const u8, .public),
    protect: bool = true,
    retain_on_delete: bool = false,
};

pub const RegionTargetHttpProxy = struct {
    pub const Outputs = struct {
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
        pub const Fingerprint = output.Descriptor("fingerprint", []const u8, .public);
    };
    node: resource.ResourceNode,
    self_link: Outputs.SelfLink.OutputType,
    fingerprint: Outputs.Fingerprint.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: RegionTargetHttpProxyArgs) BuildError!RegionTargetHttpProxy {
        try provider.validate();
        try validateName(args.name);
        try validateRegion(args.region);
        const fields = [_]value.Field{
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "region", .value = .{ .string = args.region } },
            .{ .name = "url_map", .value = try publicOutputValue(args.url_map) },
        };
        const logical_id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ args.region, args.name });
        defer allocator.free(logical_id);
        const node = try nodeOwned(allocator, "gcp.compute.RegionTargetHttpProxy", logical_id, args.name, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
        });
        return .{ .node = node, .self_link = Outputs.SelfLink.fromResource(node.id), .fingerprint = Outputs.Fingerprint.fromResource(node.id) };
    }

    pub fn deinit(self: *RegionTargetHttpProxy, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const ForwardingScheme = enum { internal, internal_managed };
pub const ForwardingProtocol = enum { tcp, udp, l3_default };
pub const ForwardingTarget = union(enum) {
    backend_service: output.Output([]const u8, .public),
    target_proxy: output.Output([]const u8, .public),
};
pub const ForwardingRuleArgs = struct {
    name: []const u8,
    region: []const u8,
    scheme: ForwardingScheme,
    network: output.Output([]const u8, .public),
    subnetwork: output.Output([]const u8, .public),
    address: output.Output([]const u8, .public),
    target: ForwardingTarget,
    protocol: ForwardingProtocol,
    ports: []const []const u8 = &.{},
    all_ports: bool = false,
    allow_global_access: bool = false,
    protect: bool = true,
    retain_on_delete: bool = false,
};

pub const ForwardingRule = struct {
    pub const Outputs = struct {
        pub const Address = output.Descriptor("address", []const u8, .public);
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
    };
    node: resource.ResourceNode,
    address: Outputs.Address.OutputType,
    self_link: Outputs.SelfLink.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ForwardingRuleArgs) BuildError!ForwardingRule {
        try provider.validate();
        try validateName(args.name);
        try validateRegion(args.region);
        switch (args.target) {
            .backend_service => if (args.scheme != .internal) return error.InvalidLoadBalancerMode,
            .target_proxy => if (args.scheme != .internal_managed or args.protocol != .tcp) return error.InvalidLoadBalancerMode,
        }
        if (args.all_ports == (args.ports.len > 0) or args.ports.len > 5) return error.InvalidPort;
        if (args.protocol == .l3_default and !args.all_ports) return error.InvalidPort;
        try validatePorts(args.ports);
        var ports = try stringListValueOwned(allocator, args.ports);
        defer ports.deinit(allocator);
        const target_kind: []const u8, const target_value: value.Value = switch (args.target) {
            .backend_service => |candidate| .{ "backend_service", try publicOutputValue(candidate) },
            .target_proxy => |candidate| .{ "target_proxy", try publicOutputValue(candidate) },
        };
        const fields = [_]value.Field{
            .{ .name = "address", .value = try publicOutputValue(args.address) },
            .{ .name = "all_ports", .value = .{ .boolean = args.all_ports } },
            .{ .name = "allow_global_access", .value = .{ .boolean = args.allow_global_access } },
            .{ .name = "load_balancing_scheme", .value = .{ .string = if (args.scheme == .internal) "INTERNAL" else "INTERNAL_MANAGED" } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "network", .value = try publicOutputValue(args.network) },
            .{ .name = "ports", .value = ports },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "protocol", .value = .{ .string = switch (args.protocol) {
                .tcp => "TCP",
                .udp => "UDP",
                .l3_default => "L3_DEFAULT",
            } } },
            .{ .name = "region", .value = .{ .string = args.region } },
            .{ .name = "subnetwork", .value = try publicOutputValue(args.subnetwork) },
            .{ .name = "target_kind", .value = .{ .string = target_kind } },
            .{ .name = "target_value", .value = target_value },
        };
        const logical_id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ args.region, args.name });
        defer allocator.free(logical_id);
        const node = try nodeOwned(allocator, "gcp.compute.ForwardingRule", logical_id, args.name, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
        });
        return .{ .node = node, .address = Outputs.Address.fromResource(node.id), .self_link = Outputs.SelfLink.fromResource(node.id) };
    }

    pub fn deinit(self: *ForwardingRule, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn nodeOwned(allocator: std.mem.Allocator, type_name: []const u8, logical_scope: []const u8, logical_id: []const u8, fields: []const value.Field, lifecycle: resource.Lifecycle) BuildError!resource.ResourceNode {
    const id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_name, logical_scope });
    defer allocator.free(id);
    return resource.ResourceNode.initOwned(allocator, .{
        .id = id,
        .provider = .gcp,
        .type_name = type_name,
        .schema_version = 1,
        .logical_id = logical_id,
        .inputs = .{ .object = fields },
        .lifecycle = lifecycle,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateField => error.DuplicateField,
        else => unreachable,
    };
}

fn protocolRulesValueOwned(allocator: std.mem.Allocator, rules: []const ProtocolPorts) BuildError!value.Value {
    if (rules.len == 0) return error.InvalidValue;
    const items = try allocator.alloc(value.Value, rules.len);
    defer allocator.free(items);
    var built: usize = 0;
    defer for (items[0..built]) |*item| item.deinit(allocator);
    for (rules, 0..) |rule, index| {
        if (rule.protocol.len == 0 or std.mem.indexOfAny(u8, rule.protocol, "\x00\r\n ") != null) return error.InvalidValue;
        try validatePorts(rule.ports);
        var ports = try stringListValueOwned(allocator, rule.ports);
        defer ports.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "ports", .value = ports },
            .{ .name = "protocol", .value = .{ .string = rule.protocol } },
        };
        items[index] = try value.Value.initOwned(allocator, .{ .object = &fields });
        built += 1;
    }
    return value.Value.initOwned(allocator, .{ .list = items });
}

fn backendsValueOwned(allocator: std.mem.Allocator, backends: []const Backend) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, backends.len);
    defer allocator.free(items);
    var built: usize = 0;
    defer for (items[0..built]) |*item| item.deinit(allocator);
    for (backends, 0..) |backend, index| {
        if (!std.math.isFinite(backend.max_utilization) or backend.max_utilization <= 0 or backend.max_utilization > 1 or
            !std.math.isFinite(backend.capacity_scaler) or backend.capacity_scaler < 0 or backend.capacity_scaler > 1) return error.InvalidBackend;
        const fields = [_]value.Field{
            .{ .name = "balancing_mode", .value = .{ .string = switch (backend.balancing_mode) {
                .connection => "CONNECTION",
                .utilization => "UTILIZATION",
                .rate => "RATE",
            } } },
            .{ .name = "capacity_scaler_micros", .value = .{ .integer = @intFromFloat(backend.capacity_scaler * 1_000_000.0) } },
            .{ .name = "failover", .value = .{ .boolean = backend.failover } },
            .{ .name = "group", .value = try publicOutputValue(backend.group) },
            .{ .name = "max_utilization_micros", .value = .{ .integer = @intFromFloat(backend.max_utilization * 1_000_000.0) } },
        };
        items[index] = try value.Value.initOwned(allocator, .{ .object = &fields });
        built += 1;
    }
    return value.Value.initOwned(allocator, .{ .list = items });
}

fn stringListValueOwned(allocator: std.mem.Allocator, source: []const []const u8) BuildError!value.Value {
    const sorted = try allocator.dupe([]const u8, source);
    defer allocator.free(sorted);
    std.mem.sort([]const u8, sorted, {}, lessString);
    for (sorted, 0..) |item, index| {
        if (item.len == 0 or std.mem.indexOfScalar(u8, item, 0) != null) return error.InvalidValue;
        if (index > 0 and std.mem.eql(u8, sorted[index - 1], item)) return error.DuplicateValue;
    }
    const items = try allocator.alloc(value.Value, sorted.len);
    defer allocator.free(items);
    for (sorted, 0..) |item, index| items[index] = .{ .string = item };
    return value.Value.initOwned(allocator, .{ .list = items });
}

fn publicOutputValue(candidate: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (candidate) {
        .value => |text| if (text.len > 0) .{ .string = text } else error.InvalidValue,
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn validateBackendMode(mode: BackendMode, protocol: BackendProtocol, port_name: []const u8) BuildError!void {
    switch (mode) {
        .internal_passthrough => {
            if (protocol != .tcp and protocol != .udp and protocol != .unspecified) return error.InvalidLoadBalancerMode;
            if (port_name.len != 0) return error.InvalidLoadBalancerMode;
        },
        .internal_application => {
            if (protocol != .http and protocol != .https and protocol != .http2 and protocol != .h2c and protocol != .grpc) return error.InvalidLoadBalancerMode;
            if (port_name.len == 0) return error.InvalidLoadBalancerMode;
        },
    }
}

fn validateHealth(protocol: HealthProtocol, port: u16, port_name: []const u8, request_path: []const u8, grpc_service_name: []const u8, interval: u32, timeout: u32, healthy: u32, unhealthy: u32) BuildError!void {
    if (port == 0 or interval < 1 or interval > 300 or timeout == 0 or timeout > interval or healthy == 0 or healthy > 10 or unhealthy == 0 or unhealthy > 10) return error.InvalidHealthTiming;
    if (port_name.len > 63 or request_path.len > 2048 or (request_path.len > 0 and request_path[0] != '/')) return error.InvalidHealthProtocol;
    if (protocol == .grpc and request_path.len > 1) return error.InvalidHealthProtocol;
    if (protocol != .grpc and grpc_service_name.len > 0) return error.InvalidHealthProtocol;
}

fn validatePorts(ports: []const []const u8) BuildError!void {
    for (ports) |port| {
        if (port.len == 0) return error.InvalidPort;
        if (std.mem.indexOfScalar(u8, port, '-')) |dash| {
            const first = std.fmt.parseInt(u16, port[0..dash], 10) catch return error.InvalidPort;
            const last = std.fmt.parseInt(u16, port[dash + 1 ..], 10) catch return error.InvalidPort;
            if (first == 0 or last < first) return error.InvalidPort;
        } else if ((std.fmt.parseInt(u16, port, 10) catch return error.InvalidPort) == 0) return error.InvalidPort;
    }
}

fn validateCidrs(cidrs: []const []const u8) BuildError!void {
    for (cidrs) |cidr| try validateCidr(cidr);
}

fn validateCidr(cidr: []const u8) BuildError!void {
    const slash = std.mem.lastIndexOfScalar(u8, cidr, '/') orelse return error.InvalidCidr;
    if (slash == 0 or slash + 1 == cidr.len) return error.InvalidCidr;
    const prefix = std.fmt.parseInt(u8, cidr[slash + 1 ..], 10) catch return error.InvalidCidr;
    if (std.mem.indexOfScalar(u8, cidr[0..slash], ':') != null) {
        if (prefix > 128) return error.InvalidCidr;
        for (cidr[0..slash]) |character| if (!std.ascii.isHex(character) and character != ':' and character != '.') return error.InvalidCidr;
        return;
    }
    if (prefix > 32) return error.InvalidCidr;
    var octets = std.mem.splitScalar(u8, cidr[0..slash], '.');
    var count: usize = 0;
    while (octets.next()) |octet| : (count += 1) {
        if (octet.len == 0) return error.InvalidCidr;
        _ = std.fmt.parseInt(u8, octet, 10) catch return error.InvalidCidr;
    }
    if (count != 4) return error.InvalidCidr;
}

fn validateIp(ip: []const u8) BuildError!void {
    var buffer: [80]u8 = undefined;
    const cidr = std.fmt.bufPrint(&buffer, "{s}/32", .{ip}) catch return error.InvalidCidr;
    try validateCidr(cidr);
}

fn validateName(text: []const u8) BuildError!void {
    if (text.len == 0 or text.len > 63 or !std.ascii.isLower(text[0]) or !std.ascii.isAlphanumeric(text[text.len - 1])) return error.InvalidName;
    for (text) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return error.InvalidName;
}

fn validateRegion(text: []const u8) BuildError!void {
    if (text.len < 3 or text.len > 32 or !std.ascii.isLower(text[0])) return error.MissingRegion;
    for (text) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return error.MissingRegion;
}

fn protocolName(protocol: HealthProtocol) []const u8 {
    return switch (protocol) {
        .http => "HTTP",
        .https => "HTTPS",
        .http2 => "HTTP2",
        .tcp => "TCP",
        .ssl => "SSL",
        .grpc => "GRPC",
    };
}

fn backendProtocolName(protocol: BackendProtocol) []const u8 {
    return switch (protocol) {
        .unspecified => "UNSPECIFIED",
        .tcp => "TCP",
        .udp => "UDP",
        .http => "HTTP",
        .https => "HTTPS",
        .http2 => "HTTP2",
        .h2c => "H2C",
        .grpc => "GRPC",
    };
}

fn lessString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}
