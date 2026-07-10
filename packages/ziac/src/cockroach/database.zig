const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const sql = @import("sql.zig");
const validation = @import("validation.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || validation.ValidationError || sql.SqlTextError ||
    std.mem.Allocator.Error || error{ DuplicateField, SecretNotKnown };

pub const DatabaseArgs = struct {
    cluster_id: []const u8,
    name: []const u8,
    connection_secret: output.Output(value.SecretReference, .secret),
    protect: bool = true,
};

pub const Database = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: DatabaseArgs) BuildError!Database {
        try provider.validate();
        try validation.validateClusterId(args.cluster_id);
        try sql.validateIdentifier(args.name);
        const fields = [_]value.Field{
            .{ .name = "cluster_id", .value = .{ .string = args.cluster_id } },
            .{ .name = "connection_secret", .value = try sql.connectionInput(args.connection_secret) },
            .{ .name = "name", .value = .{ .string = args.name } },
        };
        const id = try std.fmt.allocPrint(allocator, "cockroach.Database.{s}.{s}", .{ args.cluster_id, args.name });
        defer allocator.free(id);
        const node = resource.ResourceNode.initOwned(allocator, .{
            .id = id,
            .provider = .cockroach,
            .type_name = "cockroach.Database",
            .logical_id = args.name,
            .inputs = .{ .object = &fields },
            .lifecycle = .{ .protect = args.protect },
        }) catch |err| switch (err) {
            error.DuplicateField => return error.DuplicateField,
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
        };
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
    }

    pub fn deinit(self: *Database, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};
