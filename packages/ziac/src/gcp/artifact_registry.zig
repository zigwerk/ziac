const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");
const validation = @import("validation.zig");

pub const BuildError = validation.ValidationError || std.mem.Allocator.Error || error{DuplicateField};

pub const DockerRepositoryArgs = struct {
    name: []const u8,
    location: ?[]const u8 = null,
};

pub const DockerRepository = struct {
    pub const Outputs = struct {
        pub const RepositoryUrl = output.Descriptor("repository_url", []const u8, .public);
    };

    node: resource.ResourceNode,
    repository_url: Outputs.RepositoryUrl.OutputType,

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
        defer allocator.free(id);
        const label_fields = try allocator.alloc(value.Field, provider.labels.len);
        defer allocator.free(label_fields);
        for (provider.labels, 0..) |label, index| {
            label_fields[index] = .{ .name = label.key, .value = .{ .string = label.value } };
        }
        const input_fields = [_]value.Field{
            .{ .name = "format", .value = .{ .string = "DOCKER" } },
            .{ .name = "labels", .value = .{ .object = label_fields } },
            .{ .name = "location", .value = .{ .string = location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        };
        const node = resource.ResourceNode.initOwned(allocator, .{
            .id = id,
            .provider = .gcp,
            .type_name = "gcp.artifact.Repository",
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
            .repository_url = Outputs.RepositoryUrl.fromResource(node.id),
        };
    }

    pub fn deinit(self: *DockerRepository, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};
