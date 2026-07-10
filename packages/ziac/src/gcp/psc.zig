const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    InvalidAddress,
    InvalidAddressResource,
    InvalidName,
    InvalidNetwork,
    InvalidRegion,
    InvalidSubnetwork,
    InvalidTarget,
    OutputNotKnown,
};

pub const AddressArgs = struct {
    name: []const u8,
    region: []const u8,
    subnetwork: output.Output([]const u8, .public),
};

pub const Address = struct {
    pub const Outputs = struct {
        pub const Address = output.Descriptor("address", []const u8, .public);
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
    };

    node: resource.ResourceNode,
    address: Outputs.Address.OutputType,
    self_link: Outputs.SelfLink.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: AddressArgs,
    ) BuildError!Address {
        try validateCommon(provider, args.name, args.region);
        const fields = [_]value.Field{
            .{ .name = "address_type", .value = .{ .string = "INTERNAL" } },
            .{ .name = "ip_version", .value = .{ .string = "IPV4" } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "region", .value = .{ .string = args.region } },
            .{ .name = "subnetwork", .value = try regionalResourceValue(
                args.subnetwork,
                provider.project_id,
                args.region,
                "subnetworks",
                error.InvalidSubnetwork,
            ) },
        };
        const node = try buildNode(allocator, "gcp.compute.PscAddress", args.name, args.region, &fields);
        return .{
            .node = node,
            .address = Outputs.Address.fromResource(node.id),
            .self_link = Outputs.SelfLink.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Address, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const EndpointArgs = struct {
    name: []const u8,
    region: []const u8,
    network: output.Output([]const u8, .public),
    address: output.Output([]const u8, .public),
    address_resource: output.Output([]const u8, .public),
    target: output.Output([]const u8, .public),
};

pub const Endpoint = struct {
    pub const Outputs = struct {
        pub const IpAddress = output.Descriptor("ip_address", []const u8, .public);
        pub const PscConnectionId = output.Descriptor("psc_connection_id", []const u8, .public);
        pub const PscConnectionStatus = output.Descriptor("psc_connection_status", []const u8, .public);
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
    };

    node: resource.ResourceNode,
    ip_address: Outputs.IpAddress.OutputType,
    psc_connection_id: Outputs.PscConnectionId.OutputType,
    psc_connection_status: Outputs.PscConnectionStatus.OutputType,
    self_link: Outputs.SelfLink.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: EndpointArgs,
    ) BuildError!Endpoint {
        try validateCommon(provider, args.name, args.region);
        const fields = [_]value.Field{
            .{ .name = "address", .value = try addressValue(args.address) },
            .{ .name = "address_resource", .value = try regionalResourceValue(
                args.address_resource,
                provider.project_id,
                args.region,
                "addresses",
                error.InvalidAddressResource,
            ) },
            .{ .name = "allow_psc_global_access", .value = .{ .boolean = true } },
            .{ .name = "load_balancing_scheme", .value = .{ .string = "" } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "network", .value = try networkValue(args.network, provider.project_id) },
            .{ .name = "no_automate_dns_zone", .value = .{ .boolean = true } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "region", .value = .{ .string = args.region } },
            .{ .name = "target", .value = try targetValue(args.target, args.region) },
        };
        const node = try buildNode(allocator, "gcp.compute.PscEndpoint", args.name, args.region, &fields);
        return .{
            .node = node,
            .ip_address = Outputs.IpAddress.fromResource(node.id),
            .psc_connection_id = Outputs.PscConnectionId.fromResource(node.id),
            .psc_connection_status = Outputs.PscConnectionStatus.fromResource(node.id),
            .self_link = Outputs.SelfLink.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Endpoint, allocator: std.mem.Allocator) void {
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
) BuildError!resource.ResourceNode {
    const suffix = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ region, name });
    defer allocator.free(suffix);
    const id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_name, suffix });
    defer allocator.free(id);
    return resource.ResourceNode.initOwned(allocator, .{
        .id = id,
        .provider = .gcp,
        .type_name = type_name,
        .logical_id = suffix,
        .inputs = .{ .object = fields },
        .lifecycle = .{ .operation_timeout_millis = 30 * 60 * 1000 },
    }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
    };
}

fn validateCommon(provider: config_mod.ProviderConfig, name: []const u8, region: []const u8) BuildError!void {
    try provider.validate();
    if (name.len == 0) return error.MissingName;
    if (name.len > 63 or !std.ascii.isLower(name[0]) or
        (!std.ascii.isLower(name[name.len - 1]) and !std.ascii.isDigit(name[name.len - 1])))
    {
        return error.InvalidName;
    }
    for (name) |character| {
        if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return error.InvalidName;
    }
    if (region.len == 0) return error.MissingRegion;
    var configured = std.mem.eql(u8, provider.primary_region, region);
    for (provider.service_regions) |candidate| if (std.mem.eql(u8, candidate, region)) {
        configured = true;
        break;
    };
    if (!configured) return error.InvalidRegion;
}

fn addressValue(result: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (result) {
        .value => |known| blk: {
            if (!isIpv4(known)) return error.InvalidAddress;
            break :blk .{ .string = known };
        },
        .resource_ref => |reference| outputReference(reference),
        .unknown_reason => error.OutputNotKnown,
    };
}

fn networkValue(result: output.Output([]const u8, .public), project: []const u8) BuildError!value.Value {
    return switch (result) {
        .value => |known| if (resourceMatches(known, project, "global", "", "networks")) .{ .string = known } else error.InvalidNetwork,
        .resource_ref => |reference| outputReference(reference),
        .unknown_reason => error.OutputNotKnown,
    };
}

fn regionalResourceValue(
    result: output.Output([]const u8, .public),
    project: []const u8,
    region: []const u8,
    collection: []const u8,
    invalid: BuildError,
) BuildError!value.Value {
    return switch (result) {
        .value => |known| if (resourceMatches(known, project, "regions", region, collection)) .{ .string = known } else invalid,
        .resource_ref => |reference| outputReference(reference),
        .unknown_reason => error.OutputNotKnown,
    };
}

fn targetValue(result: output.Output([]const u8, .public), region: []const u8) BuildError!value.Value {
    return switch (result) {
        .value => |known| if (resourceMatches(known, "", "regions", region, "serviceAttachments")) .{ .string = known } else error.InvalidTarget,
        .resource_ref => |reference| outputReference(reference),
        .unknown_reason => error.OutputNotKnown,
    };
}

fn outputReference(reference: output.OutputRef) value.Value {
    return .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } };
}

fn resourceMatches(
    input: []const u8,
    project: []const u8,
    scope: []const u8,
    region: []const u8,
    collection: []const u8,
) bool {
    const marker = "projects/";
    const start = std.mem.indexOf(u8, input, marker) orelse return false;
    var segments = std.mem.splitScalar(u8, input[start..], '/');
    if (!std.mem.eql(u8, segments.next() orelse return false, "projects")) return false;
    const found_project = segments.next() orelse return false;
    if (project.len > 0 and !std.mem.eql(u8, found_project, project)) return false;
    if (!std.mem.eql(u8, segments.next() orelse return false, scope)) return false;
    if (region.len > 0 and !std.mem.eql(u8, segments.next() orelse return false, region)) return false;
    if (!std.mem.eql(u8, segments.next() orelse return false, collection)) return false;
    const name = segments.next() orelse return false;
    return name.len > 0 and segments.next() == null;
}

fn isIpv4(address: []const u8) bool {
    var octets = std.mem.splitScalar(u8, address, '.');
    var count: usize = 0;
    while (octets.next()) |octet| : (count += 1) {
        if (octet.len == 0) return false;
        _ = std.fmt.parseInt(u8, octet, 10) catch return false;
    }
    return count == 4;
}
