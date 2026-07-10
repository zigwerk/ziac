const std = @import("std");
const config_mod = @import("config.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");
const validation = @import("validation.zig");

pub const BuildError = validation.ValidationError || std.mem.Allocator.Error || error{DuplicateField};

pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
    secret: bool = false,
};

pub const ServiceArgs = struct {
    name: []const u8,
    image: []const u8,
    region: ?[]const u8 = null,
    port: u16 = 8080,
    service_account: ?[]const u8 = null,
    env: []const EnvVar = &.{},
};

pub const Service = struct {
    node: resource.ResourceNode,
    service_url: []const u8,
    service_account: []const u8,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: ServiceArgs,
    ) BuildError!Service {
        try provider.validate();
        if (args.name.len == 0) return error.MissingName;
        if (args.image.len == 0) return error.MissingImage;
        if (args.port == 0) return error.InvalidPort;

        const region = args.region orelse provider.primary_region;
        if (region.len == 0) return error.MissingRegion;
        try validateEnv(args.env);

        const selected_service_account = args.service_account orelse provider.service_account orelse "default";
        const id = try std.fmt.allocPrint(allocator, "gcp.run.Service.{s}.{s}", .{ region, args.name });
        defer allocator.free(id);
        const service_url = try std.fmt.allocPrint(allocator, "https://{s}-{s}-{s}.run.app", .{ args.name, region, provider.project_id });
        errdefer allocator.free(service_url);
        const owned_service_account = try allocator.dupe(u8, selected_service_account);
        errdefer allocator.free(owned_service_account);

        const label_fields = try allocator.alloc(value.Field, provider.labels.len);
        defer allocator.free(label_fields);
        for (provider.labels, 0..) |label, index| {
            label_fields[index] = .{ .name = label.key, .value = .{ .string = label.value } };
        }

        const env_values = try allocator.alloc(value.Value, args.env.len);
        defer allocator.free(env_values);
        var initialized_env: usize = 0;
        defer {
            for (env_values[0..initialized_env]) |*env_value| env_value.deinit(allocator);
        }
        for (args.env, 0..) |entry, index| {
            const env_value: value.Value = if (entry.secret)
                .{ .secret_ref = .{
                    .provider = "ziac",
                    .resource = entry.name,
                    .field = "value",
                } }
            else
                .{ .string = entry.value };
            const env_fields = [_]value.Field{
                .{ .name = "name", .value = .{ .string = entry.name } },
                .{ .name = "secret", .value = .{ .boolean = entry.secret } },
                .{ .name = "value", .value = env_value },
            };
            env_values[index] = value.Value.initOwned(allocator, .{ .object = env_fields[0..] }) catch |err| switch (err) {
                error.DuplicateField => return error.DuplicateField,
                error.OutOfMemory => return error.OutOfMemory,
            };
            initialized_env += 1;
        }

        const input_fields = [_]value.Field{
            .{ .name = "env", .value = .{ .list = env_values } },
            .{ .name = "image", .value = .{ .string = args.image } },
            .{ .name = "labels", .value = .{ .object = label_fields } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "port", .value = .{ .integer = args.port } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "region", .value = .{ .string = region } },
            .{ .name = "service_account", .value = .{ .string = selected_service_account } },
        };
        const node = resource.ResourceNode.initOwned(allocator, .{
            .id = id,
            .provider = .gcp,
            .type_name = "gcp.run.Service",
            .schema_version = 1,
            .logical_id = args.name,
            .inputs = .{ .object = input_fields[0..] },
        }) catch |err| switch (err) {
            error.DuplicateField => return error.DuplicateField,
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
        };
        errdefer {
            var mutable_node = node;
            mutable_node.deinit(allocator);
        }

        return .{
            .node = node,
            .service_url = service_url,
            .service_account = owned_service_account,
        };
    }

    pub fn deinit(self: *Service, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        allocator.free(self.service_url);
        allocator.free(self.service_account);
        self.* = undefined;
    }
};

fn validateEnv(env: []const EnvVar) validation.ValidationError!void {
    for (env, 0..) |left, left_index| {
        if (left.name.len == 0) return error.MissingName;
        for (env[left_index + 1 ..]) |right| {
            if (std.mem.eql(u8, left.name, right.name)) return error.DuplicateEnvVar;
        }
    }
}
