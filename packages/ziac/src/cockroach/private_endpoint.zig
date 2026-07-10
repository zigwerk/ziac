const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const validation = @import("validation.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || validation.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    InvalidEndpointId,
    InvalidEndpointServiceId,
    InvalidName,
    InvalidRegion,
    OutputNotKnown,
};

pub const ClusterId = output.Output([]const u8, .public);

pub const ClusterRegionArgs = struct {
    name: []const u8,
    cluster_id: ClusterId,
    region: []const u8,
};

pub const ClusterRegion = struct {
    pub const Outputs = struct {
        pub const ClusterId = output.Descriptor("cluster_id", []const u8, .public);
        pub const Region = output.Descriptor("region", []const u8, .public);
        pub const SqlDns = output.Descriptor("sql_dns", []const u8, .public);
        pub const InternalDns = output.Descriptor("internal_dns", []const u8, .public);
        pub const PrivateEndpointDns = output.Descriptor("private_endpoint_dns", []const u8, .public);
        pub const UiDns = output.Descriptor("ui_dns", []const u8, .public);
        pub const NodeCount = output.Descriptor("node_count", i64, .public);
        pub const Primary = output.Descriptor("primary", bool, .public);
    };

    node: resource.ResourceNode,
    cluster_id: Outputs.ClusterId.OutputType,
    region: Outputs.Region.OutputType,
    sql_dns: Outputs.SqlDns.OutputType,
    internal_dns: Outputs.InternalDns.OutputType,
    private_endpoint_dns: Outputs.PrivateEndpointDns.OutputType,
    ui_dns: Outputs.UiDns.OutputType,
    node_count: Outputs.NodeCount.OutputType,
    primary: Outputs.Primary.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: ClusterRegionArgs,
    ) BuildError!ClusterRegion {
        try provider.validate();
        try validateName(args.name);
        try validateRegion(args.region);
        const fields = [_]value.Field{
            .{ .name = "cluster_id", .value = try clusterIdValue(args.cluster_id) },
            .{ .name = "region", .value = .{ .string = args.region } },
        };
        const node = try buildNode(allocator, "cockroach.ClusterRegion", args.name, args.region, &fields, true);
        return .{
            .node = node,
            .cluster_id = Outputs.ClusterId.fromResource(node.id),
            .region = Outputs.Region.fromResource(node.id),
            .sql_dns = Outputs.SqlDns.fromResource(node.id),
            .internal_dns = Outputs.InternalDns.fromResource(node.id),
            .private_endpoint_dns = Outputs.PrivateEndpointDns.fromResource(node.id),
            .ui_dns = Outputs.UiDns.fromResource(node.id),
            .node_count = Outputs.NodeCount.fromResource(node.id),
            .primary = Outputs.Primary.fromResource(node.id),
        };
    }

    pub fn deinit(self: *ClusterRegion, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const EligiblePlan = enum {
    standard,
    advanced,

    pub fn apiName(self: EligiblePlan) []const u8 {
        return switch (self) {
            .standard => "STANDARD",
            .advanced => "ADVANCED",
        };
    }
};

pub const PrivateEndpointServiceArgs = struct {
    name: []const u8,
    cluster_id: ClusterId,
    plan: EligiblePlan,
    region: []const u8,
};

pub const PrivateEndpointService = struct {
    pub const Outputs = struct {
        pub const ServiceAttachment = output.Descriptor("service_attachment", []const u8, .public);
        pub const EndpointServiceId = output.Descriptor("endpoint_service_id", []const u8, .public);
        pub const Region = output.Descriptor("region", []const u8, .public);
        pub const Status = output.Descriptor("status", []const u8, .public);
    };

    node: resource.ResourceNode,
    service_attachment: Outputs.ServiceAttachment.OutputType,
    endpoint_service_id: Outputs.EndpointServiceId.OutputType,
    region: Outputs.Region.OutputType,
    status: Outputs.Status.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: PrivateEndpointServiceArgs,
    ) BuildError!PrivateEndpointService {
        try provider.validate();
        try validateName(args.name);
        try validateRegion(args.region);
        const fields = [_]value.Field{
            .{ .name = "cluster_id", .value = try clusterIdValue(args.cluster_id) },
            .{ .name = "plan", .value = .{ .string = args.plan.apiName() } },
            .{ .name = "region", .value = .{ .string = args.region } },
        };
        const node = try buildNode(allocator, "cockroach.PrivateEndpointService", args.name, args.region, &fields, true);
        return .{
            .node = node,
            .service_attachment = Outputs.ServiceAttachment.fromResource(node.id),
            .endpoint_service_id = Outputs.EndpointServiceId.fromResource(node.id),
            .region = Outputs.Region.fromResource(node.id),
            .status = Outputs.Status.fromResource(node.id),
        };
    }

    pub fn deinit(self: *PrivateEndpointService, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const PrivateEndpointConnectionArgs = struct {
    name: []const u8,
    cluster_id: ClusterId,
    endpoint_id: output.Output([]const u8, .public),
    endpoint_service_id: output.Output([]const u8, .public),
    region: []const u8,
};

pub const PrivateEndpointConnection = struct {
    pub const Outputs = struct {
        pub const EndpointId = output.Descriptor("endpoint_id", []const u8, .public);
        pub const EndpointServiceId = output.Descriptor("endpoint_service_id", []const u8, .public);
        pub const Region = output.Descriptor("region", []const u8, .public);
        pub const ServiceName = output.Descriptor("service_name", []const u8, .public);
        pub const Status = output.Descriptor("status", []const u8, .public);
    };

    node: resource.ResourceNode,
    endpoint_id: Outputs.EndpointId.OutputType,
    endpoint_service_id: Outputs.EndpointServiceId.OutputType,
    region: Outputs.Region.OutputType,
    service_name: Outputs.ServiceName.OutputType,
    status: Outputs.Status.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: PrivateEndpointConnectionArgs,
    ) BuildError!PrivateEndpointConnection {
        try provider.validate();
        try validateName(args.name);
        try validateRegion(args.region);
        const fields = [_]value.Field{
            .{ .name = "cluster_id", .value = try clusterIdValue(args.cluster_id) },
            .{ .name = "endpoint_id", .value = try endpointIdValue(args.endpoint_id) },
            .{ .name = "endpoint_service_id", .value = try endpointServiceIdValue(args.endpoint_service_id) },
            .{ .name = "region", .value = .{ .string = args.region } },
        };
        const node = try buildNode(allocator, "cockroach.PrivateEndpointConnection", args.name, args.region, &fields, false);
        return .{
            .node = node,
            .endpoint_id = Outputs.EndpointId.fromResource(node.id),
            .endpoint_service_id = Outputs.EndpointServiceId.fromResource(node.id),
            .region = Outputs.Region.fromResource(node.id),
            .service_name = Outputs.ServiceName.fromResource(node.id),
            .status = Outputs.Status.fromResource(node.id),
        };
    }

    pub fn deinit(self: *PrivateEndpointConnection, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn buildNode(
    allocator: std.mem.Allocator,
    type_name: []const u8,
    name: []const u8,
    region: []const u8,
    fields: []const value.Field,
    retain_on_delete: bool,
) BuildError!resource.ResourceNode {
    const id = try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ type_name, name, region });
    defer allocator.free(id);
    const logical_id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ name, region });
    defer allocator.free(logical_id);
    return resource.ResourceNode.initOwned(allocator, .{
        .id = id,
        .provider = .cockroach,
        .type_name = type_name,
        .logical_id = logical_id,
        .inputs = .{ .object = fields },
        .lifecycle = .{
            .retain_on_delete = retain_on_delete,
            .operation_timeout_millis = 60 * 60 * 1000,
        },
    }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
    };
}

fn clusterIdValue(result: ClusterId) BuildError!value.Value {
    return switch (result) {
        .value => |known| blk: {
            try validation.validateClusterId(known);
            break :blk .{ .string = known };
        },
        .resource_ref => |reference| outputReference(reference),
        .unknown_reason => error.OutputNotKnown,
    };
}

fn endpointIdValue(result: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (result) {
        .value => |known| blk: {
            if (known.len == 0) return error.InvalidEndpointId;
            for (known) |character| if (!std.ascii.isDigit(character)) return error.InvalidEndpointId;
            break :blk .{ .string = known };
        },
        .resource_ref => |reference| outputReference(reference),
        .unknown_reason => error.OutputNotKnown,
    };
}

fn endpointServiceIdValue(result: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (result) {
        .value => |known| if (known.len == 0) error.InvalidEndpointServiceId else .{ .string = known },
        .resource_ref => |reference| outputReference(reference),
        .unknown_reason => error.OutputNotKnown,
    };
}

fn outputReference(reference: output.OutputRef) value.Value {
    return .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } };
}

fn validateName(name: []const u8) BuildError!void {
    if (name.len == 0) return error.MissingName;
    if (name.len > 63 or !std.ascii.isLower(name[0])) return error.InvalidName;
    for (name) |character| {
        if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return error.InvalidName;
    }
}

fn validateRegion(region: []const u8) BuildError!void {
    if (region.len == 0) return error.MissingRegion;
    if (!std.ascii.isLower(region[0]) or region[region.len - 1] == '-') return error.InvalidRegion;
    for (region) |character| {
        if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return error.InvalidRegion;
    }
}
