const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const validation = @import("validation.zig");
const value = @import("../value.zig");

pub const BuildError = validation.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    InvalidSecretReference,
    InvalidRole,
    InvalidMember,
};

pub const SecretArgs = struct {
    name: []const u8,
};

pub const Secret = struct {
    pub const Outputs = struct {
        pub const ResourceName = output.Descriptor("resource_name", []const u8, .public);

        pub fn field(comptime name: []const u8) type {
            if (std.mem.eql(u8, name, "resource_name")) return ResourceName;
            @compileError("ZIAC120 unknown gcp.secret.Secret output field: " ++ name);
        }
    };

    node: resource.ResourceNode,
    resource_name: Outputs.ResourceName.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: SecretArgs) BuildError!Secret {
        try provider.validate();
        if (args.name.len == 0) return error.MissingName;
        const id = try std.fmt.allocPrint(allocator, "gcp.secret.Secret.{s}", .{args.name});
        defer allocator.free(id);
        const label_fields = try labelFieldsAlloc(allocator, provider);
        defer allocator.free(label_fields);
        const fields = [_]value.Field{
            .{ .name = "labels", .value = .{ .object = label_fields } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "replication", .value = .{ .string = "automatic" } },
        };
        const node = try nodeOwned(allocator, .{
            .id = id,
            .provider = .gcp,
            .type_name = "gcp.secret.Secret",
            .schema_version = 1,
            .logical_id = args.name,
            .inputs = .{ .object = &fields },
        });
        return .{ .node = node, .resource_name = Outputs.ResourceName.fromResource(node.id) };
    }

    pub fn deinit(self: *Secret, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const SecretVersionArgs = struct {
    name: []const u8,
    secret_id: []const u8,
    source: value.SecretReference,
};

pub const SecretVersion = struct {
    pub const Outputs = struct {
        pub const Version = output.Descriptor("version", value.SecretReference, .secret);

        pub fn field(comptime name: []const u8) type {
            if (std.mem.eql(u8, name, "version")) return Version;
            @compileError("ZIAC120 unknown gcp.secret.SecretVersion output field: " ++ name);
        }
    };

    node: resource.ResourceNode,
    version: Outputs.Version.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: SecretVersionArgs,
    ) BuildError!SecretVersion {
        try provider.validate();
        if (args.name.len == 0 or args.secret_id.len == 0) return error.MissingName;
        if (args.source.provider.len == 0 or args.source.resource.len == 0) return error.InvalidSecretReference;
        const id = try std.fmt.allocPrint(allocator, "gcp.secret.SecretVersion.{s}.{s}", .{ args.secret_id, args.name });
        defer allocator.free(id);
        const fields = [_]value.Field{
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "secret_id", .value = .{ .string = args.secret_id } },
            .{ .name = "source", .value = .{ .secret_ref = args.source } },
        };
        const node = try nodeOwned(allocator, .{
            .id = id,
            .provider = .gcp,
            .type_name = "gcp.secret.SecretVersion",
            .schema_version = 1,
            .logical_id = args.name,
            .inputs = .{ .object = &fields },
        });
        return .{ .node = node, .version = Outputs.Version.fromResource(node.id) };
    }

    pub fn deinit(self: *SecretVersion, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const SecretIamMemberArgs = struct {
    name: []const u8,
    secret_id: []const u8,
    role: []const u8,
    member: []const u8,
};

pub const SecretIamMember = struct {
    pub const Outputs = struct {
        pub const BindingId = output.Descriptor("binding_id", []const u8, .public);

        pub fn field(comptime name: []const u8) type {
            if (std.mem.eql(u8, name, "binding_id")) return BindingId;
            @compileError("ZIAC120 unknown gcp.secret.SecretIamMember output field: " ++ name);
        }
    };

    node: resource.ResourceNode,
    binding_id: Outputs.BindingId.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: SecretIamMemberArgs,
    ) BuildError!SecretIamMember {
        try provider.validate();
        if (args.name.len == 0 or args.secret_id.len == 0) return error.MissingName;
        if (!std.mem.startsWith(u8, args.role, "roles/") or args.role.len <= "roles/".len) return error.InvalidRole;
        if (std.mem.indexOfScalar(u8, args.member, ':') == null) return error.InvalidMember;
        const id = try std.fmt.allocPrint(
            allocator,
            "gcp.secret.SecretIamMember.{s}.{s}",
            .{ args.secret_id, args.name },
        );
        defer allocator.free(id);
        const fields = [_]value.Field{
            .{ .name = "member", .value = .{ .string = args.member } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "role", .value = .{ .string = args.role } },
            .{ .name = "secret_id", .value = .{ .string = args.secret_id } },
        };
        const node = try nodeOwned(allocator, .{
            .id = id,
            .provider = .gcp,
            .type_name = "gcp.secret.SecretIamMember",
            .schema_version = 1,
            .logical_id = args.name,
            .inputs = .{ .object = &fields },
        });
        return .{ .node = node, .binding_id = Outputs.BindingId.fromResource(node.id) };
    }

    pub fn deinit(self: *SecretIamMember, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn labelFieldsAlloc(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig) BuildError![]value.Field {
    const fields = try allocator.alloc(value.Field, provider.labels.len);
    for (provider.labels, 0..) |label, index| {
        fields[index] = .{ .name = label.key, .value = .{ .string = label.value } };
    }
    return fields;
}

fn nodeOwned(allocator: std.mem.Allocator, node: resource.ResourceNode) BuildError!resource.ResourceNode {
    return resource.ResourceNode.initOwned(allocator, node) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
    };
}
