const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const validation = @import("validation.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || validation.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    InvalidIpAddress,
    OutputNotKnown,
    UnrestrictedCidr,
};

pub const AuthorizedNetworkArgs = struct {
    name: []const u8,
    cluster_id: []const u8,
    ip_address: output.Output([]const u8, .public),
    cidr_mask: u8 = 32,
    sql: bool = true,
    ui: bool = false,
    production: bool = true,
};

pub const AuthorizedNetwork = struct {
    pub const Outputs = struct {
        pub const Cidr = output.Descriptor("cidr", []const u8, .public);
    };

    node: resource.ResourceNode,
    cidr: Outputs.Cidr.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: AuthorizedNetworkArgs,
    ) BuildError!AuthorizedNetwork {
        try provider.validate();
        if (args.name.len == 0) return error.MissingName;
        try validation.validateClusterId(args.cluster_id);
        if (args.cidr_mask > 32) return error.InvalidIpAddress;
        if (args.production and args.cidr_mask != 32) return error.UnrestrictedCidr;
        const address_value: value.Value = switch (args.ip_address) {
            .value => |known| blk: {
                try validateIpv4(known);
                break :blk .{ .string = known };
            },
            .resource_ref => |reference| .{ .output_ref = .{
                .resource_id = reference.resource_id,
                .field = reference.field,
            } },
            .unknown_reason => return error.OutputNotKnown,
        };
        const fields = [_]value.Field{
            .{ .name = "cidr_mask", .value = .{ .integer = args.cidr_mask } },
            .{ .name = "cluster_id", .value = .{ .string = args.cluster_id } },
            .{ .name = "ip_address", .value = address_value },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "sql", .value = .{ .boolean = args.sql } },
            .{ .name = "ui", .value = .{ .boolean = args.ui } },
        };
        const id = try std.fmt.allocPrint(allocator, "cockroach.AuthorizedNetwork.{s}.{s}", .{ args.cluster_id, args.name });
        defer allocator.free(id);
        const node = resource.ResourceNode.initOwned(allocator, .{
            .id = id,
            .provider = .cockroach,
            .type_name = "cockroach.AuthorizedNetwork",
            .logical_id = args.name,
            .inputs = .{ .object = &fields },
        }) catch |err| switch (err) {
            error.DuplicateField => return error.DuplicateField,
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
        };
        return .{ .node = node, .cidr = Outputs.Cidr.fromResource(node.id) };
    }

    pub fn deinit(self: *AuthorizedNetwork, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn validateIpv4(address: []const u8) BuildError!void {
    var octets = std.mem.splitScalar(u8, address, '.');
    var count: usize = 0;
    while (octets.next()) |octet| : (count += 1) {
        if (octet.len == 0) return error.InvalidIpAddress;
        _ = std.fmt.parseInt(u8, octet, 10) catch return error.InvalidIpAddress;
    }
    if (count != 4) return error.InvalidIpAddress;
}
