const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const validation = @import("validation.zig");
const value = @import("../value.zig");

pub const BuildError = validation.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    InvalidAccountId,
    InvalidRole,
    InvalidMember,
};

pub const ServiceAccountArgs = struct {
    account_id: []const u8,
    display_name: []const u8 = "",
    description: []const u8 = "",
};

pub const ServiceAccount = struct {
    pub const Outputs = struct {
        pub const Email = output.Descriptor("email", []const u8, .public);
        pub const UniqueId = output.Descriptor("unique_id", []const u8, .public);

        pub fn field(comptime name: []const u8) type {
            if (std.mem.eql(u8, name, "email")) return Email;
            if (std.mem.eql(u8, name, "unique_id")) return UniqueId;
            @compileError("ZIAC120 unknown gcp.iam.ServiceAccount output field: " ++ name);
        }
    };

    node: resource.ResourceNode,
    email: Outputs.Email.OutputType,
    unique_id: Outputs.UniqueId.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: ServiceAccountArgs,
    ) BuildError!ServiceAccount {
        try provider.validate();
        if (!validAccountId(args.account_id)) return error.InvalidAccountId;
        const id = try std.fmt.allocPrint(allocator, "gcp.iam.ServiceAccount.{s}", .{args.account_id});
        defer allocator.free(id);
        const fields = [_]value.Field{
            .{ .name = "account_id", .value = .{ .string = args.account_id } },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        };
        const node = resource.ResourceNode.initOwned(allocator, .{
            .id = id,
            .provider = .gcp,
            .type_name = "gcp.iam.ServiceAccount",
            .schema_version = 1,
            .logical_id = args.account_id,
            .inputs = .{ .object = &fields },
        }) catch |err| switch (err) {
            error.DuplicateField => return error.DuplicateField,
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
        };
        return .{
            .node = node,
            .email = Outputs.Email.fromResource(node.id),
            .unique_id = Outputs.UniqueId.fromResource(node.id),
        };
    }

    pub fn deinit(self: *ServiceAccount, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const ProjectMemberArgs = struct {
    name: []const u8,
    role: []const u8,
    member: []const u8,
};

pub const ProjectMember = struct {
    pub const Outputs = struct {
        pub const BindingId = output.Descriptor("binding_id", []const u8, .public);

        pub fn field(comptime name: []const u8) type {
            if (std.mem.eql(u8, name, "binding_id")) return BindingId;
            @compileError("ZIAC120 unknown gcp.iam.ProjectMember output field: " ++ name);
        }
    };

    node: resource.ResourceNode,
    binding_id: Outputs.BindingId.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: ProjectMemberArgs,
    ) BuildError!ProjectMember {
        try provider.validate();
        if (args.name.len == 0) return error.MissingName;
        if (!std.mem.startsWith(u8, args.role, "roles/") or args.role.len <= "roles/".len) return error.InvalidRole;
        if (std.mem.indexOfScalar(u8, args.member, ':') == null) return error.InvalidMember;
        const id = try std.fmt.allocPrint(allocator, "gcp.iam.ProjectMember.{s}", .{args.name});
        defer allocator.free(id);
        const fields = [_]value.Field{
            .{ .name = "member", .value = .{ .string = args.member } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "role", .value = .{ .string = args.role } },
        };
        const node = resource.ResourceNode.initOwned(allocator, .{
            .id = id,
            .provider = .gcp,
            .type_name = "gcp.iam.ProjectMember",
            .schema_version = 1,
            .logical_id = args.name,
            .inputs = .{ .object = &fields },
        }) catch |err| switch (err) {
            error.DuplicateField => return error.DuplicateField,
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
        };
        return .{
            .node = node,
            .binding_id = Outputs.BindingId.fromResource(node.id),
        };
    }

    pub fn deinit(self: *ProjectMember, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn validAccountId(account_id: []const u8) bool {
    if (account_id.len < 6 or account_id.len > 30 or account_id[0] < 'a' or account_id[0] > 'z') return false;
    if (!std.ascii.isAlphanumeric(account_id[account_id.len - 1])) return false;
    for (account_id[1..]) |byte| {
        if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '-') return false;
    }
    return true;
}
