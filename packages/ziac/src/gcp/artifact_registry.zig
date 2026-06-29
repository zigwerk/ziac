const std = @import("std");
const config_mod = @import("config.zig");
const resource = @import("../resource.zig");
const validation = @import("validation.zig");

pub const BuildError = validation.ValidationError || std.mem.Allocator.Error;

pub const DockerRepositoryArgs = struct {
    name: []const u8,
    location: ?[]const u8 = null,
};

pub const DockerRepository = struct {
    node: resource.ResourceNode,
    repository_url: []const u8,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: DockerRepositoryArgs,
    ) BuildError!DockerRepository {
        try provider.validate();
        if (args.name.len == 0) return error.MissingName;
        const location = args.location orelse provider.primary_region;
        if (location.len == 0) return error.MissingRegion;

        const id = try std.fmt.allocPrint(allocator, "gcp.artifact.Repository.{s}.{s}", .{ location, args.name });
        errdefer allocator.free(id);
        const repository_url = try std.fmt.allocPrint(allocator, "{s}-docker.pkg.dev/{s}/{s}", .{ location, provider.project_id, args.name });
        errdefer allocator.free(repository_url);

        return .{
            .node = .{
                .id = id,
                .type_name = "gcp.artifact.Repository",
                .logical_id = args.name,
            },
            .repository_url = repository_url,
        };
    }

    pub fn deinit(self: *DockerRepository, allocator: std.mem.Allocator) void {
        allocator.free(self.node.id);
        allocator.free(self.repository_url);
    }
};
