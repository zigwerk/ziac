const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const validation = @import("validation.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || validation.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    SecretNotKnown,
};

pub const SqlUserArgs = struct {
    cluster_id: []const u8,
    username: []const u8,
    connection_secret: output.Output(value.SecretReference, .secret),
};

pub const SqlUser = struct {
    pub const Outputs = struct {
        pub const Username = output.Descriptor("username", []const u8, .public);

        pub fn field(comptime name: []const u8) type {
            if (std.mem.eql(u8, name, "username")) return Username;
            @compileError("ZIAC130 unknown cockroach.SqlUser output field: " ++ name);
        }
    };

    node: resource.ResourceNode,
    username: Outputs.Username.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: SqlUserArgs,
    ) BuildError!SqlUser {
        try provider.validate();
        try validation.validateClusterId(args.cluster_id);
        try validation.validateUsername(args.username);
        const secret_input: value.Value = switch (args.connection_secret) {
            .value => |reference| .{ .secret_ref = reference },
            .resource_ref => |reference| .{ .output_ref = .{
                .resource_id = reference.resource_id,
                .field = reference.field,
            } },
            .unknown_reason => return error.SecretNotKnown,
        };
        const fields = [_]value.Field{
            .{ .name = "cluster_id", .value = .{ .string = args.cluster_id } },
            .{ .name = "connection_secret", .value = secret_input },
            .{ .name = "username", .value = .{ .string = args.username } },
        };
        const id = try std.fmt.allocPrint(allocator, "cockroach.SqlUser.{s}.{s}", .{ args.cluster_id, args.username });
        defer allocator.free(id);
        const node = resource.ResourceNode.initOwned(allocator, .{
            .id = id,
            .provider = .cockroach,
            .type_name = "cockroach.SqlUser",
            .logical_id = args.username,
            .inputs = .{ .object = &fields },
        }) catch |err| switch (err) {
            error.DuplicateField => return error.DuplicateField,
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
        };
        return .{ .node = node, .username = Outputs.Username.fromResource(node.id) };
    }

    pub fn deinit(self: *SqlUser, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};
