const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const validation = @import("validation.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || validation.ValidationError || std.mem.Allocator.Error || error{DuplicateField};

pub const Plan = enum {
    basic,
    standard,
    advanced,

    pub fn apiName(self: Plan) []const u8 {
        return switch (self) {
            .basic => "BASIC",
            .standard => "STANDARD",
            .advanced => "ADVANCED",
        };
    }
};

pub const ExistingClusterArgs = struct {
    name: []const u8,
    cluster_id: []const u8,
    plan: Plan,
    regions: []const []const u8,
};

pub const ExistingCluster = struct {
    pub const Outputs = struct {
        pub const ClusterId = output.Descriptor("cluster_id", []const u8, .public);
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const CloudProvider = output.Descriptor("cloud_provider", []const u8, .public);
        pub const PlanName = output.Descriptor("plan", []const u8, .public);
        pub const SqlDns = output.Descriptor("sql_dns", []const u8, .public);
        pub const Regions = output.Descriptor("regions", []const u8, .public);
        pub const PrimaryRegion = output.Descriptor("primary_region", []const u8, .public);
        pub const PrimarySqlDns = output.Descriptor("primary_sql_dns", []const u8, .public);
        pub const PrimaryInternalDns = output.Descriptor("primary_internal_dns", []const u8, .public);
        pub const PrimaryPrivateEndpointDns = output.Descriptor("primary_private_endpoint_dns", []const u8, .public);

        pub fn field(comptime name: []const u8) type {
            if (std.mem.eql(u8, name, "cluster_id")) return ClusterId;
            if (std.mem.eql(u8, name, "name")) return Name;
            if (std.mem.eql(u8, name, "cloud_provider")) return CloudProvider;
            if (std.mem.eql(u8, name, "plan")) return PlanName;
            if (std.mem.eql(u8, name, "sql_dns")) return SqlDns;
            if (std.mem.eql(u8, name, "regions")) return Regions;
            if (std.mem.eql(u8, name, "primary_region")) return PrimaryRegion;
            if (std.mem.eql(u8, name, "primary_sql_dns")) return PrimarySqlDns;
            if (std.mem.eql(u8, name, "primary_internal_dns")) return PrimaryInternalDns;
            if (std.mem.eql(u8, name, "primary_private_endpoint_dns")) return PrimaryPrivateEndpointDns;
            @compileError("ZIAC130 unknown cockroach.ExistingCluster output field: " ++ name);
        }
    };

    node: resource.ResourceNode,
    cluster_id: Outputs.ClusterId.OutputType,
    name: Outputs.Name.OutputType,
    cloud_provider: Outputs.CloudProvider.OutputType,
    plan: Outputs.PlanName.OutputType,
    sql_dns: Outputs.SqlDns.OutputType,
    regions: Outputs.Regions.OutputType,
    primary_region: Outputs.PrimaryRegion.OutputType,
    primary_sql_dns: Outputs.PrimarySqlDns.OutputType,
    primary_internal_dns: Outputs.PrimaryInternalDns.OutputType,
    primary_private_endpoint_dns: Outputs.PrimaryPrivateEndpointDns.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: ExistingClusterArgs,
    ) BuildError!ExistingCluster {
        try provider.validate();
        if (args.name.len == 0) return error.MissingName;
        try validation.validateClusterId(args.cluster_id);
        try validation.validateRegions(args.regions);

        const sorted_regions = try validation.sortedRegionsAlloc(allocator, args.regions);
        defer allocator.free(sorted_regions);
        const region_values = try allocator.alloc(value.Value, sorted_regions.len);
        defer allocator.free(region_values);
        for (sorted_regions, 0..) |region, index| region_values[index] = .{ .string = region };
        const fields = [_]value.Field{
            .{ .name = "cloud_provider", .value = .{ .string = "GCP" } },
            .{ .name = "cluster_id", .value = .{ .string = args.cluster_id } },
            .{ .name = "plan", .value = .{ .string = args.plan.apiName() } },
            .{ .name = "regions", .value = .{ .list = region_values } },
        };
        const id = try std.fmt.allocPrint(allocator, "cockroach.Cluster.Existing.{s}", .{args.name});
        defer allocator.free(id);
        const node = resource.ResourceNode.initOwned(allocator, .{
            .id = id,
            .provider = .cockroach,
            .type_name = "cockroach.Cluster.Existing",
            .logical_id = args.name,
            .inputs = .{ .object = &fields },
            .lifecycle = .{ .retain_on_delete = true },
        }) catch |err| switch (err) {
            error.DuplicateField => return error.DuplicateField,
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
        };
        errdefer {
            var mutable = node;
            mutable.deinit(allocator);
        }
        return .{
            .node = node,
            .cluster_id = Outputs.ClusterId.fromResource(node.id),
            .name = Outputs.Name.fromResource(node.id),
            .cloud_provider = Outputs.CloudProvider.fromResource(node.id),
            .plan = Outputs.PlanName.fromResource(node.id),
            .sql_dns = Outputs.SqlDns.fromResource(node.id),
            .regions = Outputs.Regions.fromResource(node.id),
            .primary_region = Outputs.PrimaryRegion.fromResource(node.id),
            .primary_sql_dns = Outputs.PrimarySqlDns.fromResource(node.id),
            .primary_internal_dns = Outputs.PrimaryInternalDns.fromResource(node.id),
            .primary_private_endpoint_dns = Outputs.PrimaryPrivateEndpointDns.fromResource(node.id),
        };
    }

    pub fn deinit(self: *ExistingCluster, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};
