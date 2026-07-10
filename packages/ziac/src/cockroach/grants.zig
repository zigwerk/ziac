const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const sql = @import("sql.zig");
const validation = @import("validation.zig");
const value = @import("../value.zig");

pub const Privilege = enum {
    all,
    connect,
    create,
    drop,

    pub fn sqlName(self: Privilege) []const u8 {
        return switch (self) {
            .all => "ALL",
            .connect => "CONNECT",
            .create => "CREATE",
            .drop => "DROP",
        };
    }
};

pub const BuildError = config_mod.ValidationError || validation.ValidationError || sql.SqlTextError ||
    std.mem.Allocator.Error || error{ DuplicateField, DuplicatePrivilege, EmptyPrivileges, SecretNotKnown };

pub const GrantsArgs = struct {
    cluster_id: []const u8,
    database: []const u8,
    grantee: []const u8,
    privileges: []const Privilege,
    connection_secret: output.Output(value.SecretReference, .secret),
};

pub const Grants = struct {
    pub const Outputs = struct {
        pub const Grantee = output.Descriptor("grantee", []const u8, .public);
    };

    node: resource.ResourceNode,
    grantee: Outputs.Grantee.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: GrantsArgs) BuildError!Grants {
        try provider.validate();
        try validation.validateClusterId(args.cluster_id);
        try sql.validateIdentifier(args.database);
        try sql.validateIdentifier(args.grantee);
        if (args.privileges.len == 0) return error.EmptyPrivileges;
        const sorted = try allocator.dupe(Privilege, args.privileges);
        defer allocator.free(sorted);
        std.mem.sort(Privilege, sorted, {}, privilegeLessThan);
        for (sorted[1..], sorted[0 .. sorted.len - 1]) |current, previous| {
            if (current == previous) return error.DuplicatePrivilege;
        }
        const privileges = try allocator.alloc(value.Value, sorted.len);
        defer allocator.free(privileges);
        for (sorted, 0..) |privilege, index| privileges[index] = .{ .string = privilege.sqlName() };
        const fields = [_]value.Field{
            .{ .name = "cluster_id", .value = .{ .string = args.cluster_id } },
            .{ .name = "connection_secret", .value = try sql.connectionInput(args.connection_secret) },
            .{ .name = "database", .value = .{ .string = args.database } },
            .{ .name = "grantee", .value = .{ .string = args.grantee } },
            .{ .name = "privileges", .value = .{ .list = privileges } },
        };
        const id = try std.fmt.allocPrint(allocator, "cockroach.Grants.{s}.{s}.{s}", .{ args.cluster_id, args.database, args.grantee });
        defer allocator.free(id);
        const node = resource.ResourceNode.initOwned(allocator, .{
            .id = id,
            .provider = .cockroach,
            .type_name = "cockroach.Grants",
            .logical_id = args.grantee,
            .inputs = .{ .object = &fields },
        }) catch |err| switch (err) {
            error.DuplicateField => return error.DuplicateField,
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
        };
        return .{ .node = node, .grantee = Outputs.Grantee.fromResource(node.id) };
    }

    pub fn deinit(self: *Grants, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn privilegeLessThan(_: void, left: Privilege, right: Privilege) bool {
    return std.mem.lessThan(u8, left.sqlName(), right.sqlName());
}
