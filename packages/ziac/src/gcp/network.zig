const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    InvalidCidr,
    InvalidAsn,
    InvalidMinPorts,
    InvalidName,
    OutputNotKnown,
};

pub const Network = struct {
    pub const Outputs = struct {
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
    };

    node: resource.ResourceNode,
    self_link: Outputs.SelfLink.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: struct { name: []const u8 }) BuildError!Network {
        try provider.validate();
        try validateName(args.name);
        const fields = [_]value.Field{
            .{ .name = "auto_create_subnetworks", .value = .{ .boolean = false } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "routing_mode", .value = .{ .string = "GLOBAL" } },
        };
        const node = try buildNode(allocator, "gcp.compute.Network", args.name, args.name, &fields);
        return .{ .node = node, .self_link = Outputs.SelfLink.fromResource(node.id) };
    }

    pub fn deinit(self: *Network, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const SubnetworkArgs = struct {
    name: []const u8,
    region: []const u8,
    ip_cidr_range: []const u8,
    network: output.Output([]const u8, .public),
};

pub const Subnetwork = struct {
    pub const Outputs = struct {
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
    };

    node: resource.ResourceNode,
    self_link: Outputs.SelfLink.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: SubnetworkArgs) BuildError!Subnetwork {
        try provider.validate();
        try validateName(args.name);
        if (args.region.len == 0) return error.MissingRegion;
        try validateSubnetCidr(args.ip_cidr_range);
        const fields = [_]value.Field{
            .{ .name = "ip_cidr_range", .value = .{ .string = args.ip_cidr_range } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "network", .value = try outputValue(args.network) },
            .{ .name = "private_ip_google_access", .value = .{ .boolean = true } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "region", .value = .{ .string = args.region } },
        };
        const logical_id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ args.region, args.name });
        defer allocator.free(logical_id);
        const node = try buildNode(allocator, "gcp.compute.Subnetwork", logical_id, args.name, &fields);
        return .{ .node = node, .self_link = Outputs.SelfLink.fromResource(node.id) };
    }

    pub fn deinit(self: *Subnetwork, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const RouterArgs = struct {
    name: []const u8,
    region: []const u8,
    network: output.Output([]const u8, .public),
    bgp_asn: ?u32 = null,
    advertise_mode: RouterAdvertisementMode = .default,
    advertised_groups: []const []const u8 = &.{},
};

pub const RouterAdvertisementMode = enum { default, custom };

pub const Router = struct {
    pub const Outputs = struct {
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
    };

    node: resource.ResourceNode,
    self_link: Outputs.SelfLink.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: RouterArgs) BuildError!Router {
        try provider.validate();
        try validateName(args.name);
        if (args.region.len == 0) return error.MissingRegion;
        if (args.bgp_asn) |asn| try validatePrivateAsn(asn);
        if (args.advertise_mode == .default and args.advertised_groups.len > 0) return error.InvalidAsn;
        var groups = try stringListValueOwned(allocator, args.advertised_groups);
        defer groups.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "advertise_mode", .value = .{ .string = if (args.advertise_mode == .custom) "CUSTOM" else "DEFAULT" } },
            .{ .name = "advertised_groups", .value = groups },
            .{ .name = "bgp_asn", .value = .{ .integer = args.bgp_asn orelse 0 } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "network", .value = try outputValue(args.network) },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "region", .value = .{ .string = args.region } },
        };
        const logical_id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ args.region, args.name });
        defer allocator.free(logical_id);
        const node = try buildNode(allocator, "gcp.compute.Router", logical_id, args.name, &fields);
        return .{ .node = node, .self_link = Outputs.SelfLink.fromResource(node.id) };
    }

    pub fn deinit(self: *Router, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const RegionalAddressArgs = struct { name: []const u8, region: []const u8 };

pub const RegionalAddress = struct {
    pub const Outputs = struct {
        pub const Address = output.Descriptor("address", []const u8, .public);
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
    };

    node: resource.ResourceNode,
    address: Outputs.Address.OutputType,
    self_link: Outputs.SelfLink.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: RegionalAddressArgs) BuildError!RegionalAddress {
        try provider.validate();
        try validateName(args.name);
        if (args.region.len == 0) return error.MissingRegion;
        const fields = [_]value.Field{
            .{ .name = "address_type", .value = .{ .string = "EXTERNAL" } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "network_tier", .value = .{ .string = "PREMIUM" } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "region", .value = .{ .string = args.region } },
        };
        const logical_id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ args.region, args.name });
        defer allocator.free(logical_id);
        const node = try buildNode(allocator, "gcp.compute.RegionalAddress", logical_id, args.name, &fields);
        return .{
            .node = node,
            .address = Outputs.Address.fromResource(node.id),
            .self_link = Outputs.SelfLink.fromResource(node.id),
        };
    }

    pub fn deinit(self: *RegionalAddress, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const RouterNatArgs = struct {
    name: []const u8,
    region: []const u8,
    router_name: []const u8,
    router: output.Output([]const u8, .public),
    subnetwork: output.Output([]const u8, .public),
    nat_ip: output.Output([]const u8, .public),
    min_ports_per_vm: u16 = 64,
};

pub const RouterNat = struct {
    pub const Outputs = struct {
        pub const ResourceId = output.Descriptor("resource_id", []const u8, .public);
    };

    node: resource.ResourceNode,
    resource_id: Outputs.ResourceId.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: RouterNatArgs) BuildError!RouterNat {
        try provider.validate();
        try validateName(args.name);
        try validateName(args.router_name);
        if (args.region.len == 0) return error.MissingRegion;
        if (args.min_ports_per_vm < 32 or !std.math.isPowerOfTwo(args.min_ports_per_vm)) return error.InvalidMinPorts;
        const fields = [_]value.Field{
            .{ .name = "enable_endpoint_independent_mapping", .value = .{ .boolean = true } },
            .{ .name = "min_ports_per_vm", .value = .{ .integer = args.min_ports_per_vm } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "nat_ip", .value = try outputValue(args.nat_ip) },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "region", .value = .{ .string = args.region } },
            .{ .name = "router", .value = try outputValue(args.router) },
            .{ .name = "router_name", .value = .{ .string = args.router_name } },
            .{ .name = "subnetwork", .value = try outputValue(args.subnetwork) },
        };
        const logical_id = try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ args.region, args.router_name, args.name });
        defer allocator.free(logical_id);
        const node = try buildNode(allocator, "gcp.compute.RouterNat", logical_id, args.name, &fields);
        return .{ .node = node, .resource_id = Outputs.ResourceId.fromResource(node.id) };
    }

    pub fn deinit(self: *RouterNat, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn buildNode(
    allocator: std.mem.Allocator,
    type_name: []const u8,
    logical_id: []const u8,
    name: []const u8,
    fields: []const value.Field,
) BuildError!resource.ResourceNode {
    const id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_name, logical_id });
    defer allocator.free(id);
    return resource.ResourceNode.initOwned(allocator, .{
        .id = id,
        .provider = .gcp,
        .type_name = type_name,
        .logical_id = name,
        .inputs = .{ .object = fields },
    }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
    };
}

fn outputValue(result: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (result) {
        .value => |known| .{ .string = known },
        .resource_ref => |reference| .{ .output_ref = .{
            .resource_id = reference.resource_id,
            .field = reference.field,
        } },
        .unknown_reason => error.OutputNotKnown,
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

fn validatePrivateAsn(asn: u32) BuildError!void {
    if (!((asn >= 64_512 and asn <= 65_534) or (asn >= 4_200_000_000 and asn <= 4_294_967_294))) return error.InvalidAsn;
}

fn validateName(name: []const u8) BuildError!void {
    if (name.len == 0 or name.len > 63 or !std.ascii.isLower(name[0])) return error.InvalidName;
    if (!std.ascii.isLower(name[name.len - 1]) and !std.ascii.isDigit(name[name.len - 1])) return error.InvalidName;
    for (name) |character| {
        if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return error.InvalidName;
    }
}

fn validateSubnetCidr(cidr: []const u8) BuildError!void {
    const slash = std.mem.indexOfScalar(u8, cidr, '/') orelse return error.InvalidCidr;
    const prefix = std.fmt.parseInt(u8, cidr[slash + 1 ..], 10) catch return error.InvalidCidr;
    if (prefix < 8 or prefix > 28) return error.InvalidCidr;
    var octets = std.mem.splitScalar(u8, cidr[0..slash], '.');
    var count: usize = 0;
    while (octets.next()) |octet| : (count += 1) {
        if (octet.len == 0) return error.InvalidCidr;
        _ = std.fmt.parseInt(u8, octet, 10) catch return error.InvalidCidr;
    }
    if (count != 4) return error.InvalidCidr;
}
