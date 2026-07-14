const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const validation = @import("validation.zig");
const value = @import("../value.zig");

pub const BuildError = validation.ValidationError || std.mem.Allocator.Error || error{ DuplicateField, InvalidName, MissingService };

pub const ServiceArgs = struct {
    name: ?[]const u8 = null,
    service: []const u8,
};

pub const Service = struct {
    pub const Outputs = struct {
        pub const ResourceName = output.Descriptor("resource_name", []const u8, .public);

        pub fn field(comptime name: []const u8) type {
            if (std.mem.eql(u8, name, "resource_name")) return ResourceName;
            @compileError("ZIAC120 unknown gcp.project.Service output field: " ++ name);
        }
    };

    node: resource.ResourceNode,
    resource_name: Outputs.ResourceName.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: ServiceArgs,
    ) BuildError!Service {
        try provider.validate();
        if (args.service.len == 0) return error.MissingService;
        const logical_name = args.name orelse args.service;
        if (logical_name.len == 0) return error.InvalidName;
        const id = try std.fmt.allocPrint(allocator, "gcp.project.Service.{s}", .{logical_name});
        defer allocator.free(id);
        const fields = [_]value.Field{
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "service", .value = .{ .string = args.service } },
        };
        const node = resource.ResourceNode.initOwned(allocator, .{
            .id = id,
            .provider = .gcp,
            .type_name = "gcp.project.Service",
            .schema_version = 1,
            .logical_id = logical_name,
            .inputs = .{ .object = &fields },
        }) catch |err| switch (err) {
            error.DuplicateField => return error.DuplicateField,
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
        };
        return .{
            .node = node,
            .resource_name = Outputs.ResourceName.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Service, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};
