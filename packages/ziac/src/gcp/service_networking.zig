const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || resource.ResourceGraphError || std.mem.Allocator.Error || error{
    DuplicateRange,
    InvalidAddress,
    InvalidConnection,
    InvalidNetwork,
    InvalidPrefixLength,
    InvalidRange,
    OutputNotKnown,
};

pub const PrivateServiceRangeArgs = struct {
    name: []const u8,
    network: []const u8,
    prefix_length: u8,
    address: []const u8 = "",
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const PrivateServiceRange = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
        pub const Address = output.Descriptor("address", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    self_link: Outputs.SelfLink.OutputType,
    address: Outputs.Address.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: PrivateServiceRangeArgs) BuildError!PrivateServiceRange {
        try provider.validate();
        try validateName(args.name, error.InvalidRange);
        try validateNetwork(args.network);
        if (args.prefix_length < 8 or args.prefix_length > 29) return error.InvalidPrefixLength;
        if (args.address.len > 0 and !validIpv4(args.address)) return error.InvalidAddress;
        const fields = [_]value.Field{
            .{ .name = "address", .value = .{ .string = args.address } },
            .{ .name = "address_type", .value = .{ .string = "INTERNAL" } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "network", .value = .{ .string = args.network } },
            .{ .name = "prefix_length", .value = .{ .integer = args.prefix_length } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "purpose", .value = .{ .string = "VPC_PEERING" } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.compute.PrivateServiceRange.{s}", .{args.name});
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.compute.PrivateServiceRange", args.name, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
            .operation_timeout_millis = 30 * 60 * 1000,
        });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .self_link = Outputs.SelfLink.fromResource(node.id),
            .address = Outputs.Address.fromResource(node.id),
        };
    }

    pub fn deinit(self: *PrivateServiceRange, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const ReservedRange = struct {
    name: []const u8,
    dependency: output.Output([]const u8, .public),
};

pub const ConnectionArgs = struct {
    name: []const u8,
    network: []const u8,
    service: []const u8 = "servicenetworking.googleapis.com",
    reserved_ranges: []const ReservedRange,
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const Connection = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Peering = output.Descriptor("peering", []const u8, .public);
        pub const Network = output.Descriptor("network", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    peering: Outputs.Peering.OutputType,
    network: Outputs.Network.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ConnectionArgs) BuildError!Connection {
        try provider.validate();
        try validateName(args.name, error.InvalidConnection);
        try validateNetwork(args.network);
        if (args.reserved_ranges.len == 0 or !validService(args.service)) return error.InvalidConnection;
        const sorted = try allocator.dupe(ReservedRange, args.reserved_ranges);
        defer allocator.free(sorted);
        std.mem.sort(ReservedRange, sorted, {}, struct {
            fn lessThan(_: void, left: ReservedRange, right: ReservedRange) bool {
                return std.mem.order(u8, left.name, right.name) == .lt;
            }
        }.lessThan);
        var names: std.ArrayList(u8) = .empty;
        defer names.deinit(allocator);
        const dependencies = try allocator.alloc(value.Value, sorted.len);
        defer allocator.free(dependencies);
        for (sorted, 0..) |range, index| {
            try validateName(range.name, error.InvalidRange);
            if (index > 0 and std.mem.eql(u8, sorted[index - 1].name, range.name)) return error.DuplicateRange;
            if (index > 0) try names.append(allocator, '\n');
            try names.appendSlice(allocator, range.name);
            dependencies[index] = try publicOutputValue(range.dependency);
        }
        const fields = [_]value.Field{
            .{ .name = "network", .value = .{ .string = args.network } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "range_dependencies", .value = .{ .list = dependencies } },
            .{ .name = "reserved_ranges", .value = .{ .string = names.items } },
            .{ .name = "service", .value = .{ .string = args.service } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.servicenetworking.Connection.{s}", .{args.name});
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.servicenetworking.Connection", args.name, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
            .operation_timeout_millis = 30 * 60 * 1000,
        });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .peering = Outputs.Peering.fromResource(node.id),
            .network = Outputs.Network.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Connection, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn validateName(name: []const u8, err: BuildError) BuildError!void {
    if (name.len == 0 or name.len > 63 or !std.ascii.isLower(name[0]) or !std.ascii.isAlphanumeric(name[name.len - 1])) return err;
    for (name) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return err;
}

fn validateNetwork(network: []const u8) BuildError!void {
    if (!std.mem.startsWith(u8, network, "projects/") or std.mem.indexOf(u8, network, "/global/networks/") == null or std.mem.indexOfAny(u8, network, "\x00\r\n ?") != null) return error.InvalidNetwork;
}

fn validService(service: []const u8) bool {
    return std.mem.endsWith(u8, service, ".googleapis.com") and std.mem.indexOfAny(u8, service, "\x00\r\n /?") == null;
}

fn validIpv4(address: []const u8) bool {
    var parts: usize = 0;
    var iterator = std.mem.tokenizeScalar(u8, address, '.');
    while (iterator.next()) |part| {
        if (part.len == 0 or part.len > 3) return false;
        const number = std.fmt.parseUnsigned(u8, part, 10) catch return false;
        _ = number;
        parts += 1;
    }
    return parts == 4;
}

fn publicOutputValue(candidate: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (candidate) {
        .value => |text| .{ .string = text },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn nodeOwned(allocator: std.mem.Allocator, id: []const u8, type_name: []const u8, logical_id: []const u8, fields: []const value.Field, lifecycle: resource.Lifecycle) BuildError!resource.ResourceNode {
    return resource.ResourceNode.initOwned(allocator, .{
        .id = id,
        .provider = .gcp,
        .type_name = type_name,
        .schema_version = 1,
        .logical_id = logical_id,
        .inputs = .{ .object = fields },
        .lifecycle = lifecycle,
    });
}
