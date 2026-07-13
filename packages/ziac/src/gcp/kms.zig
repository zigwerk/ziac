const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{ DuplicateField, InvalidName, InvalidLocation, OutputNotKnown, InvalidConfiguration };

pub const KeyRing = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: struct { name: []const u8, location: []const u8 }) BuildError!KeyRing {
        try provider.validate();
        try validateName(args.name);
        try validateLocation(args.location);
        const fields = [_]value.Field{
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.kms.KeyRing.{s}", .{args.name});
        defer allocator.free(id);
        var node = try nodeAlloc(allocator, id, "gcp.kms.KeyRing", args.name, &fields);
        node.lifecycle.retain_on_delete = true;
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
    }
    pub fn deinit(self: *KeyRing, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const CryptoKey = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: struct {
        name: []const u8,
        key_ring: output.Output([]const u8, .public),
        rotation_period_seconds: u64 = 7_776_000,
    }) BuildError!CryptoKey {
        try provider.validate();
        try validateName(args.name);
        if (args.rotation_period_seconds < 86_400) return error.InvalidConfiguration;
        const ring_value: value.Value = switch (args.key_ring) {
            .value => |known| .{ .string = known },
            .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
            .unknown_reason => return error.OutputNotKnown,
        };
        const fields = [_]value.Field{
            .{ .name = "key_ring", .value = ring_value },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "purpose", .value = .{ .string = "ENCRYPT_DECRYPT" } },
            .{ .name = "rotation_period_seconds", .value = .{ .integer = @intCast(args.rotation_period_seconds) } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.kms.CryptoKey.{s}", .{args.name});
        defer allocator.free(id);
        var node = try nodeAlloc(allocator, id, "gcp.kms.CryptoKey", args.name, &fields);
        node.lifecycle.retain_on_delete = true;
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
    }
    pub fn deinit(self: *CryptoKey, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn nodeAlloc(allocator: std.mem.Allocator, id: []const u8, type_name: []const u8, logical_id: []const u8, fields: []const value.Field) BuildError!resource.ResourceNode {
    return resource.ResourceNode.initOwned(allocator, .{
        .id = id,
        .provider = .gcp,
        .type_name = type_name,
        .schema_version = 1,
        .logical_id = logical_id,
        .inputs = .{ .object = fields },
    }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}
fn validateName(name: []const u8) BuildError!void {
    if (name.len == 0 or name.len > 63 or !std.ascii.isAlphabetic(name[0])) return error.InvalidName;
    for (name) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_')) return error.InvalidName;
}
fn validateLocation(location: []const u8) BuildError!void {
    if (location.len == 0 or location.len > 63) return error.InvalidLocation;
    for (location) |byte| if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '-')) return error.InvalidLocation;
}
