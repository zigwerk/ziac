const std = @import("std");
const client_mod = @import("client.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const validation = @import("validation.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;
const existing_cluster_type = "cockroach.Cluster.Existing";

pub const LiveProvider = struct {
    client: *client_mod.Client,

    pub fn init(client: *client_mod.Client) LiveProvider {
        return .{ .client = client };
    }

    pub fn provider(self: *LiveProvider) provider_mod.Provider {
        return .{
            .ptr = self,
            .readFn = read,
            .diffFn = diff,
            .createFn = create,
            .updateFn = update,
            .deleteFn = delete,
            .importFn = importResource,
        };
    }

    fn read(
        ptr: *anyopaque,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ReadResult {
        const self: *LiveProvider = @ptrCast(@alignCast(ptr));
        if (!isSupported(node)) return error.InvalidConfiguration;
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        var cluster = self.client.getClusterAlloc(context, try inputString(node.inputs, "cluster_id"), &diagnostic) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer cluster.deinit(context.allocator);
        return .{ .present = try resultFromCluster(context.allocator, node, cluster) };
    }

    fn diff(
        _: *anyopaque,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        observed: *const provider_mod.ResourceResult,
    ) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        if (!isSupported(node)) return error.InvalidConfiguration;
        if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash)) {
            return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        }
        return topologyDiff(context.allocator, node.inputs, observed.observed_inputs);
    }

    fn create(
        ptr: *anyopaque,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        const self: *LiveProvider = @ptrCast(@alignCast(ptr));
        return self.readExact(context, node);
    }

    fn update(
        _: *anyopaque,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        observed: *const provider_mod.ResourceResult,
    ) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        if (!isSupported(node)) return error.InvalidConfiguration;
        var result_diff = try topologyDiff(context.allocator, node.inputs, observed.observed_inputs);
        defer result_diff.deinit();
        if (result_diff.kind != .noop) return error.InvalidConfiguration;
        return observed.clone(context.allocator);
    }

    fn delete(
        _: *anyopaque,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!void {
        try context.checkActive();
        if (!isSupported(node)) return error.InvalidConfiguration;
        if (!std.mem.eql(u8, try inputString(node.inputs, "cluster_id"), physical_id)) {
            return error.InvalidConfiguration;
        }
    }

    fn importResource(
        ptr: *anyopaque,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!provider_mod.ResourceResult {
        const self: *LiveProvider = @ptrCast(@alignCast(ptr));
        if (!isSupported(node)) return error.InvalidConfiguration;
        if (!std.mem.eql(u8, try inputString(node.inputs, "cluster_id"), physical_id)) {
            return error.InvalidConfiguration;
        }
        return self.readExact(context, node);
    }

    fn readExact(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        var result = switch (try read(self, context, node)) {
            .absent => return error.NotFound,
            .present => |present| present,
        };
        errdefer result.deinit();
        var result_diff = try topologyDiff(context.allocator, node.inputs, result.observed_inputs);
        defer result_diff.deinit();
        if (result_diff.kind != .noop) return error.InvalidConfiguration;
        return result;
    }
};

fn resultFromCluster(
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    cluster: client_mod.Cluster,
) ProviderError!provider_mod.ResourceResult {
    const declared_id = try inputString(node.inputs, "cluster_id");
    if (!std.mem.eql(u8, declared_id, cluster.id)) return error.ProviderBug;
    const cloud_provider = cluster.cloud_provider orelse return error.ProviderBug;
    const plan = cluster.plan orelse return error.ProviderBug;
    if (cluster.regions.len == 0) return error.ProviderBug;

    const region_names = try allocator.alloc([]const u8, cluster.regions.len);
    defer allocator.free(region_names);
    for (cluster.regions, 0..) |region, index| region_names[index] = region.name;
    std.mem.sort([]const u8, region_names, {}, lessThanString);
    const region_values = try allocator.alloc(value.Value, region_names.len);
    defer allocator.free(region_values);
    for (region_names, 0..) |name, index| region_values[index] = .{ .string = name };
    const observed_fields = [_]value.Field{
        .{ .name = "cloud_provider", .value = .{ .string = cloud_provider } },
        .{ .name = "cluster_id", .value = .{ .string = cluster.id } },
        .{ .name = "plan", .value = .{ .string = plan } },
        .{ .name = "regions", .value = .{ .list = region_values } },
    };

    const regions_csv = try std.mem.join(allocator, ",", region_names);
    defer allocator.free(regions_csv);
    const primary = primaryRegion(cluster.regions);
    const sql_dns = cluster.sql_dns orelse primary.sql_dns;
    const outputs = [_]state.StateOutput{
        .{ .name = "cluster_id", .value = .{ .string = cluster.id } },
        .{ .name = "name", .value = .{ .string = cluster.name } },
        .{ .name = "cloud_provider", .value = .{ .string = cloud_provider } },
        .{ .name = "plan", .value = .{ .string = plan } },
        .{ .name = "sql_dns", .value = .{ .string = sql_dns } },
        .{ .name = "regions", .value = .{ .string = regions_csv } },
        .{ .name = "primary_region", .value = .{ .string = primary.name } },
        .{ .name = "primary_sql_dns", .value = .{ .string = primary.sql_dns } },
        .{ .name = "primary_internal_dns", .value = .{ .string = primary.internal_dns } },
        .{ .name = "primary_private_endpoint_dns", .value = .{ .string = primary.private_endpoint_dns } },
    };
    return provider_mod.ResourceResult.init(
        allocator,
        cluster.id,
        .{ .object = &observed_fields },
        &outputs,
        null,
    );
}

fn topologyDiff(
    allocator: std.mem.Allocator,
    desired: value.Value,
    observed: value.Value,
) ProviderError!provider_mod.DiffResult {
    var reasons = std.ArrayList([]const u8).empty;
    defer reasons.deinit(allocator);
    defer for (reasons.items) |reason| allocator.free(reason);

    const desired_id = try inputString(desired, "cluster_id");
    const observed_id = try inputString(observed, "cluster_id");
    if (!std.mem.eql(u8, desired_id, observed_id)) {
        const reason = std.fmt.allocPrint(allocator, "cluster_id: expected {s}, observed {s}", .{ desired_id, observed_id }) catch return error.OutOfMemory;
        try appendOwnedReason(allocator, &reasons, reason);
        return provider_mod.DiffResult.init(allocator, .replace, reasons.items);
    }

    inline for (&.{ "cloud_provider", "plan" }) |field| {
        const expected = try inputString(desired, field);
        const actual = try inputString(observed, field);
        if (!std.mem.eql(u8, expected, actual)) {
            const reason = std.fmt.allocPrint(allocator, "{s}: expected {s}, observed {s}", .{ field, expected, actual }) catch return error.OutOfMemory;
            try appendOwnedReason(allocator, &reasons, reason);
        }
    }
    const expected_regions = try inputStringListAlloc(allocator, desired, "regions");
    defer allocator.free(expected_regions);
    const actual_regions = try inputStringListAlloc(allocator, observed, "regions");
    defer allocator.free(actual_regions);
    var compatibility = validation.regionCompatibilityAlloc(allocator, expected_regions, actual_regions) catch return error.OutOfMemory;
    defer compatibility.deinit();
    if (!compatibility.compatible()) {
        const reason = compatibility.reasonAlloc(allocator) catch return error.OutOfMemory;
        try appendOwnedReason(allocator, &reasons, reason);
    }
    return provider_mod.DiffResult.init(allocator, if (reasons.items.len == 0) .noop else .update, reasons.items);
}

fn appendOwnedReason(
    allocator: std.mem.Allocator,
    reasons: *std.ArrayList([]const u8),
    reason: []const u8,
) ProviderError!void {
    reasons.append(allocator, reason) catch |err| {
        allocator.free(reason);
        return err;
    };
}

fn inputString(input: value.Value, name: []const u8) ProviderError![]const u8 {
    const fields = switch (input) {
        .object => |fields| fields,
        else => return error.InvalidConfiguration,
    };
    for (fields) |field| {
        if (!std.mem.eql(u8, field.name, name)) continue;
        return switch (field.value) {
            .string => |text| text,
            else => error.InvalidConfiguration,
        };
    }
    return error.InvalidConfiguration;
}

fn inputStringListAlloc(
    allocator: std.mem.Allocator,
    input: value.Value,
    name: []const u8,
) ProviderError![]const []const u8 {
    const fields = switch (input) {
        .object => |fields| fields,
        else => return error.InvalidConfiguration,
    };
    for (fields) |field| {
        if (!std.mem.eql(u8, field.name, name)) continue;
        const items = switch (field.value) {
            .list => |items| items,
            else => return error.InvalidConfiguration,
        };
        if (items.len == 0) return error.InvalidConfiguration;
        const strings = allocator.alloc([]const u8, items.len) catch return error.OutOfMemory;
        errdefer allocator.free(strings);
        for (items, 0..) |item, index| {
            strings[index] = switch (item) {
                .string => |text| text,
                else => return error.InvalidConfiguration,
            };
        }
        return strings;
    }
    return error.InvalidConfiguration;
}

fn primaryRegion(regions: []const client_mod.Region) client_mod.Region {
    for (regions) |region| if (region.primary orelse false) return region;
    return regions[0];
}

fn isSupported(node: resource.ResourceNode) bool {
    return std.mem.eql(u8, node.type_name, existing_cluster_type);
}

fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
