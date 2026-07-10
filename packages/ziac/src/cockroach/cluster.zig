const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const validation = @import("validation.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || validation.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    DuplicatePrimaryRegion,
    InvalidCidrRange,
    InvalidClusterName,
    InvalidRegion,
    InvalidSizing,
    MissingPrimaryRegion,
};

pub const Region = struct {
    name: []const u8,
    primary: bool = false,
};

pub const AdvancedRegion = struct {
    name: []const u8,
    node_count: u16,
};

pub const Basic = struct {
    regions: []const Region,
    request_unit_limit: ?u64 = null,
    storage_mib_limit: ?u64 = null,
};

pub const Standard = struct {
    regions: []const Region,
    provisioned_virtual_cpus: u16,
};

pub const Advanced = struct {
    regions: []const AdvancedRegion,
    num_virtual_cpus: u16,
    storage_gib: ?u32 = null,
    cockroach_version: ?[]const u8 = null,
    private_network_visibility: bool = false,
    cidr_range: ?[]const u8 = null,
};

pub const Plan = union(enum) {
    basic: Basic,
    standard: Standard,
    advanced: Advanced,

    pub fn apiName(self: Plan) []const u8 {
        return switch (self) {
            .basic => "BASIC",
            .standard => "STANDARD",
            .advanced => "ADVANCED",
        };
    }
};

pub const ClusterArgs = struct {
    name: []const u8,
    plan: Plan,
    protect: bool = true,
};

pub const Cluster = struct {
    pub const Outputs = struct {
        pub const ClusterId = output.Descriptor("cluster_id", []const u8, .public);
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const CloudProvider = output.Descriptor("cloud_provider", []const u8, .public);
        pub const PlanName = output.Descriptor("plan", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
        pub const DeleteProtection = output.Descriptor("delete_protection", bool, .public);
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
            if (std.mem.eql(u8, name, "state")) return State;
            if (std.mem.eql(u8, name, "delete_protection")) return DeleteProtection;
            if (std.mem.eql(u8, name, "sql_dns")) return SqlDns;
            if (std.mem.eql(u8, name, "regions")) return Regions;
            if (std.mem.eql(u8, name, "primary_region")) return PrimaryRegion;
            if (std.mem.eql(u8, name, "primary_sql_dns")) return PrimarySqlDns;
            if (std.mem.eql(u8, name, "primary_internal_dns")) return PrimaryInternalDns;
            if (std.mem.eql(u8, name, "primary_private_endpoint_dns")) return PrimaryPrivateEndpointDns;
            @compileError("ZIAC131 unknown cockroach.Cluster output field: " ++ name);
        }
    };

    node: resource.ResourceNode,
    cluster_id: Outputs.ClusterId.OutputType,
    name: Outputs.Name.OutputType,
    cloud_provider: Outputs.CloudProvider.OutputType,
    plan: Outputs.PlanName.OutputType,
    state: Outputs.State.OutputType,
    delete_protection: Outputs.DeleteProtection.OutputType,
    sql_dns: Outputs.SqlDns.OutputType,
    regions: Outputs.Regions.OutputType,
    primary_region: Outputs.PrimaryRegion.OutputType,
    primary_sql_dns: Outputs.PrimarySqlDns.OutputType,
    primary_internal_dns: Outputs.PrimaryInternalDns.OutputType,
    primary_private_endpoint_dns: Outputs.PrimaryPrivateEndpointDns.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: ClusterArgs,
    ) BuildError!Cluster {
        try provider.validate();
        try validateClusterName(args.name);
        const node = switch (args.plan) {
            .basic => |spec| try buildBasicNode(allocator, args, spec),
            .standard => |spec| try buildStandardNode(allocator, args, spec),
            .advanced => |spec| try buildAdvancedNode(allocator, args, spec),
        };
        return fromNode(node);
    }

    pub fn deinit(self: *Cluster, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }

    fn fromNode(node: resource.ResourceNode) Cluster {
        return .{
            .node = node,
            .cluster_id = Outputs.ClusterId.fromResource(node.id),
            .name = Outputs.Name.fromResource(node.id),
            .cloud_provider = Outputs.CloudProvider.fromResource(node.id),
            .plan = Outputs.PlanName.fromResource(node.id),
            .state = Outputs.State.fromResource(node.id),
            .delete_protection = Outputs.DeleteProtection.fromResource(node.id),
            .sql_dns = Outputs.SqlDns.fromResource(node.id),
            .regions = Outputs.Regions.fromResource(node.id),
            .primary_region = Outputs.PrimaryRegion.fromResource(node.id),
            .primary_sql_dns = Outputs.PrimarySqlDns.fromResource(node.id),
            .primary_internal_dns = Outputs.PrimaryInternalDns.fromResource(node.id),
            .primary_private_endpoint_dns = Outputs.PrimaryPrivateEndpointDns.fromResource(node.id),
        };
    }
};

fn buildBasicNode(allocator: std.mem.Allocator, args: ClusterArgs, spec: Basic) BuildError!resource.ResourceNode {
    const normalized = try normalizeServerlessRegions(allocator, spec.regions);
    defer normalized.deinit(allocator);
    try validatePositiveOptional(spec.request_unit_limit);
    try validatePositiveOptional(spec.storage_mib_limit);

    var fields = std.ArrayList(value.Field).empty;
    defer fields.deinit(allocator);
    try appendCommonFields(allocator, &fields, args, "BASIC", normalized);
    try fields.append(allocator, .{ .name = "request_unit_limit", .value = .{ .integer = if (spec.request_unit_limit) |limit| try integer(limit) else 0 } });
    try fields.append(allocator, .{ .name = "storage_mib_limit", .value = .{ .integer = if (spec.storage_mib_limit) |limit| try integer(limit) else 0 } });
    return initNode(allocator, args, fields.items);
}

fn buildStandardNode(allocator: std.mem.Allocator, args: ClusterArgs, spec: Standard) BuildError!resource.ResourceNode {
    if (spec.provisioned_virtual_cpus == 0) return error.InvalidSizing;
    const normalized = try normalizeServerlessRegions(allocator, spec.regions);
    defer normalized.deinit(allocator);

    var fields = std.ArrayList(value.Field).empty;
    defer fields.deinit(allocator);
    try appendCommonFields(allocator, &fields, args, "STANDARD", normalized);
    try fields.append(allocator, .{ .name = "provisioned_virtual_cpus", .value = .{ .integer = spec.provisioned_virtual_cpus } });
    return initNode(allocator, args, fields.items);
}

fn buildAdvancedNode(allocator: std.mem.Allocator, args: ClusterArgs, spec: Advanced) BuildError!resource.ResourceNode {
    if (spec.num_virtual_cpus == 0) return error.InvalidSizing;
    if (spec.storage_gib) |storage| if (storage == 0) return error.InvalidSizing;
    if (spec.cockroach_version) |version| if (version.len == 0) return error.InvalidSizing;
    if (spec.cidr_range) |cidr| {
        if (!spec.private_network_visibility) return error.InvalidCidrRange;
        try validateAdvancedCidr(cidr);
    }
    const normalized = try normalizeAdvancedRegions(allocator, spec.regions);
    defer normalized.deinit(allocator);

    var fields = std.ArrayList(value.Field).empty;
    defer fields.deinit(allocator);
    try fields.append(allocator, .{ .name = "cidr_range", .value = .{ .string = spec.cidr_range orelse "" } });
    try fields.append(allocator, .{ .name = "cloud_provider", .value = .{ .string = "GCP" } });
    try fields.append(allocator, .{ .name = "cockroach_version", .value = .{ .string = spec.cockroach_version orelse "" } });
    try fields.append(allocator, .{ .name = "name", .value = .{ .string = args.name } });
    try fields.append(allocator, .{ .name = "num_virtual_cpus", .value = .{ .integer = spec.num_virtual_cpus } });
    try fields.append(allocator, .{ .name = "plan", .value = .{ .string = "ADVANCED" } });
    try fields.append(allocator, .{ .name = "private_network_visibility", .value = .{ .boolean = spec.private_network_visibility } });
    try fields.append(allocator, .{ .name = "protect", .value = .{ .boolean = args.protect } });
    try fields.append(allocator, .{ .name = "regions", .value = .{ .list = normalized.values } });
    try fields.append(allocator, .{ .name = "storage_gib", .value = .{ .integer = spec.storage_gib orelse 0 } });
    return initNode(allocator, args, fields.items);
}

const NormalizedRegions = struct {
    values: []value.Value,
    objects: []value.Field,

    fn deinit(self: NormalizedRegions, allocator: std.mem.Allocator) void {
        allocator.free(self.values);
        allocator.free(self.objects);
    }
};

fn normalizeServerlessRegions(allocator: std.mem.Allocator, regions: []const Region) BuildError!NormalizedRegions {
    if (regions.len == 0) return error.MissingRegion;
    const sorted = try allocator.dupe(Region, regions);
    defer allocator.free(sorted);
    std.mem.sort(Region, sorted, {}, lessThanRegion);
    var primary_count: usize = 0;
    for (sorted, 0..) |region, index| {
        try validateRegionName(region.name);
        if (index > 0 and std.mem.eql(u8, sorted[index - 1].name, region.name)) return error.DuplicateRegion;
        if (region.primary) primary_count += 1;
    }
    if (primary_count > 1) return error.DuplicatePrimaryRegion;
    if (regions.len > 1 and primary_count == 0) return error.MissingPrimaryRegion;

    const values = try allocator.alloc(value.Value, sorted.len);
    errdefer allocator.free(values);
    const objects = try allocator.alloc(value.Field, sorted.len * 3);
    errdefer allocator.free(objects);
    for (sorted, 0..) |region, index| {
        const start = index * 3;
        const primary = if (sorted.len == 1) true else region.primary;
        objects[start..][0..3].* = .{
            .{ .name = "name", .value = .{ .string = region.name } },
            .{ .name = "node_count", .value = .{ .integer = 0 } },
            .{ .name = "primary", .value = .{ .boolean = primary } },
        };
        values[index] = .{ .object = objects[start..][0..3] };
    }
    return .{ .values = values, .objects = objects };
}

fn normalizeAdvancedRegions(allocator: std.mem.Allocator, regions: []const AdvancedRegion) BuildError!NormalizedRegions {
    if (regions.len == 0) return error.MissingRegion;
    const sorted = try allocator.dupe(AdvancedRegion, regions);
    defer allocator.free(sorted);
    std.mem.sort(AdvancedRegion, sorted, {}, lessThanAdvancedRegion);
    const values = try allocator.alloc(value.Value, sorted.len);
    errdefer allocator.free(values);
    const objects = try allocator.alloc(value.Field, sorted.len * 3);
    errdefer allocator.free(objects);
    for (sorted, 0..) |region, index| {
        try validateRegionName(region.name);
        if (region.node_count == 0) return error.InvalidSizing;
        if (index > 0 and std.mem.eql(u8, sorted[index - 1].name, region.name)) return error.DuplicateRegion;
        const start = index * 3;
        objects[start..][0..3].* = .{
            .{ .name = "name", .value = .{ .string = region.name } },
            .{ .name = "node_count", .value = .{ .integer = region.node_count } },
            .{ .name = "primary", .value = .{ .boolean = false } },
        };
        values[index] = .{ .object = objects[start..][0..3] };
    }
    return .{ .values = values, .objects = objects };
}

fn appendCommonFields(
    allocator: std.mem.Allocator,
    fields: *std.ArrayList(value.Field),
    args: ClusterArgs,
    plan: []const u8,
    regions: NormalizedRegions,
) std.mem.Allocator.Error!void {
    var primary: []const u8 = "";
    for (regions.values) |region_value| {
        const region_fields = region_value.object;
        if (region_fields[2].value.boolean) {
            primary = region_fields[0].value.string;
            break;
        }
    }
    try fields.appendSlice(allocator, &.{
        .{ .name = "cloud_provider", .value = .{ .string = "GCP" } },
        .{ .name = "name", .value = .{ .string = args.name } },
        .{ .name = "plan", .value = .{ .string = plan } },
        .{ .name = "primary_region", .value = .{ .string = primary } },
        .{ .name = "protect", .value = .{ .boolean = args.protect } },
        .{ .name = "regions", .value = .{ .list = regions.values } },
    });
}

fn initNode(allocator: std.mem.Allocator, args: ClusterArgs, fields: []const value.Field) BuildError!resource.ResourceNode {
    const id = try std.fmt.allocPrint(allocator, "cockroach.Cluster.{s}", .{args.name});
    defer allocator.free(id);
    return resource.ResourceNode.initOwned(allocator, .{
        .id = id,
        .provider = .cockroach,
        .type_name = "cockroach.Cluster",
        .logical_id = args.name,
        .inputs = .{ .object = fields },
        .lifecycle = .{
            .protect = args.protect,
            .operation_timeout_millis = 2 * 60 * 60 * 1000,
        },
    }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
    };
}

fn validateClusterName(name: []const u8) BuildError!void {
    if (name.len < 6 or name.len > 20 or name[0] == '-' or name[name.len - 1] == '-') return error.InvalidClusterName;
    for (name) |character| {
        if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return error.InvalidClusterName;
    }
}

fn validateRegionName(name: []const u8) BuildError!void {
    if (name.len == 0 or !std.ascii.isLower(name[0]) or name[name.len - 1] == '-') return error.InvalidRegion;
    for (name) |character| {
        if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return error.InvalidRegion;
    }
}

fn validatePositiveOptional(number: ?u64) BuildError!void {
    if (number) |present| {
        if (present == 0 or present > std.math.maxInt(i64)) return error.InvalidSizing;
    }
}

fn integer(number: u64) BuildError!i64 {
    if (number > std.math.maxInt(i64)) return error.InvalidSizing;
    return @intCast(number);
}

fn validateAdvancedCidr(cidr: []const u8) BuildError!void {
    const slash = std.mem.indexOfScalar(u8, cidr, '/') orelse return error.InvalidCidrRange;
    if (slash == 0 or slash + 1 >= cidr.len) return error.InvalidCidrRange;
    const prefix = std.fmt.parseInt(u8, cidr[slash + 1 ..], 10) catch return error.InvalidCidrRange;
    if (prefix > 19) return error.InvalidCidrRange;
    var octets = std.mem.splitScalar(u8, cidr[0..slash], '.');
    var count: usize = 0;
    while (octets.next()) |octet| : (count += 1) {
        if (octet.len == 0) return error.InvalidCidrRange;
        _ = std.fmt.parseInt(u8, octet, 10) catch return error.InvalidCidrRange;
    }
    if (count != 4) return error.InvalidCidrRange;
}

fn lessThanRegion(_: void, left: Region, right: Region) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}

fn lessThanAdvancedRegion(_: void, left: AdvancedRegion, right: AdvancedRegion) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}
