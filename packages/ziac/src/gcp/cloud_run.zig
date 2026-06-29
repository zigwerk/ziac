const std = @import("std");
const config_mod = @import("config.zig");
const resource = @import("../resource.zig");
const validation = @import("validation.zig");

pub const BuildError = validation.ValidationError || std.mem.Allocator.Error;

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
        errdefer allocator.free(id);
        const service_url = try std.fmt.allocPrint(allocator, "https://{s}-{s}-{s}.run.app", .{ args.name, region, provider.project_id });
        errdefer allocator.free(service_url);
        const owned_service_account = try allocator.dupe(u8, selected_service_account);
        errdefer allocator.free(owned_service_account);

        return .{
            .node = .{
                .id = id,
                .type_name = "gcp.run.Service",
                .logical_id = args.name,
            },
            .service_url = service_url,
            .service_account = owned_service_account,
        };
    }

    pub fn deinit(self: *Service, allocator: std.mem.Allocator) void {
        allocator.free(self.node.id);
        allocator.free(self.service_url);
        allocator.free(self.service_account);
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
