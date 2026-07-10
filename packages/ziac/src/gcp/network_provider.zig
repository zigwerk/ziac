const std = @import("std");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;
const router_nat_type = "gcp.compute.RouterNat";

pub const Handler = struct {
    client: *client_mod.Client,
    operation_policy: operation.Policy,
    conflict_retries: usize,

    pub fn read(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_override: ?[]const u8,
    ) ProviderError!provider_mod.ReadResult {
        if (!supports(node)) return error.InvalidConfiguration;
        if (physical_override) |physical_id| {
            const expected = try physicalIdAlloc(context.allocator, node);
            defer context.allocator.free(expected);
            if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        }
        if (context.operation_handle) |handle| try self.waitOperation(context, node, handle);
        const path = try routerPathAlloc(context.allocator, node);
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .compute, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return resultFromRouterJson(context, node, response.body);
    }

    pub fn diff(
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        observed: *const provider_mod.ResourceResult,
    ) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        if (!supports(node)) return error.InvalidConfiguration;
        if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash)) {
            return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        }
        for ([_][]const u8{ "project_id", "region", "router_name", "name" }) |field| {
            if (!std.mem.eql(u8, try requiredString(node.inputs, field), try requiredString(observed.observed_inputs, field))) {
                return provider_mod.DiffResult.init(context.allocator, .replace, &.{"Cloud NAT identity changed"});
            }
        }
        return provider_mod.DiffResult.init(context.allocator, .update, &.{"Cloud NAT policy changed"});
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        return self.mutate(context, node, true);
    }

    pub fn update(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!provider_mod.ResourceResult {
        const expected = try physicalIdAlloc(context.allocator, node);
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        return self.mutate(context, node, true);
    }

    pub fn delete(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!void {
        const expected = try physicalIdAlloc(context.allocator, node);
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        var result = try self.mutate(context, node, false);
        defer result.deinit();
        if (result.operation_handle) |handle| try self.waitOperation(context, node, handle);
    }

    fn mutate(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        should_exist: bool,
    ) ProviderError!provider_mod.ResourceResult {
        const path = try routerPathAlloc(context.allocator, node);
        defer context.allocator.free(path);
        var conflicts: usize = 0;
        while (true) {
            var remote = self.request(context, .{ .api = .compute, .method = "GET", .path = path }) catch |err| {
                if (err == error.NotFound and !should_exist) return desiredResult(context.allocator, node, null);
                return err;
            };
            defer remote.deinit(context.allocator);
            const body = try mutateRouterBodyAlloc(context, node, remote.body, should_exist);
            defer context.allocator.free(body.json);
            if (!body.changed) return desiredResult(context.allocator, node, null);
            const handle = self.startOperation(context, path, body.json) catch |err| {
                if (err == error.Conflict and conflicts < self.conflict_retries) {
                    conflicts += 1;
                    continue;
                }
                return err;
            };
            defer context.allocator.free(handle);
            return pendingResult(context.allocator, node, handle);
        }
    }

    fn startOperation(
        self: Handler,
        context: *provider_mod.OperationContext,
        path: []const u8,
        body: []const u8,
    ) ProviderError![]const u8 {
        var response = try self.request(context, .{ .api = .compute, .method = "PATCH", .path = path, .body = body });
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const object = asObject(parsed.value) orelse return error.ProviderBug;
        return context.allocator.dupe(u8, try requiredJsonString(object, "name")) catch return error.OutOfMemory;
    }

    fn waitOperation(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, handle: []const u8) ProviderError!void {
        const base = try std.fmt.allocPrint(context.allocator, "{s}/compute/v1", .{std.mem.trimEnd(u8, self.client.endpoints.compute, "/")});
        defer context.allocator.free(base);
        var target = operation.Target.computeRegionalAlloc(
            context.allocator,
            base,
            try requiredString(node.inputs, "project_id"),
            try requiredString(node.inputs, "region"),
            handle,
        ) catch return error.OutOfMemory;
        defer target.deinit(context.allocator);
        var completed = try operation.waitAlloc(self.client, context, target, self.operation_policy);
        completed.deinit(context.allocator);
    }

    fn request(
        self: Handler,
        context: *provider_mod.OperationContext,
        request_value: client_mod.Request,
    ) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, request_value, &diagnostic);
    }
};

pub fn supports(node: resource.ResourceNode) bool {
    return std.mem.eql(u8, node.type_name, router_nat_type);
}

const MutationBody = struct { json: []const u8, changed: bool };

fn mutateRouterBodyAlloc(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    remote_json: []const u8,
    should_exist: bool,
) ProviderError!MutationBody {
    const allocator = context.allocator;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, remote_json, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const router = switch (parsed.value) {
        .object => |*object| object,
        else => return error.ProviderBug,
    };
    const arena = parsed.arena.allocator();
    const nat_name = try requiredString(node.inputs, "name");
    const existing_value = router.get("nats");
    const existing = if (existing_value) |nats| asArray(nats) orelse return error.ProviderBug else std.json.Array.init(arena);
    var nats = std.json.Array.init(arena);
    var found = false;
    for (existing.items) |item| {
        const nat = asObject(item) orelse return error.ProviderBug;
        if (std.mem.eql(u8, try requiredJsonString(nat, "name"), nat_name)) {
            found = true;
            if (should_exist) try nats.append(try desiredNatJson(context, node, arena));
        } else {
            try nats.append(item);
        }
    }
    if (should_exist and !found) try nats.append(try desiredNatJson(context, node, arena));
    if ((!should_exist and !found) or (should_exist and found and try natMatchesDesired(context, node, existing))) {
        return .{ .json = try allocator.dupe(u8, remote_json), .changed = false };
    }
    try router.put(arena, "nats", .{ .array = nats });
    inline for (&.{ "selfLink", "id", "creationTimestamp", "kind", "region" }) |field| _ = router.orderedRemove(field);
    return .{
        .json = std.json.Stringify.valueAlloc(allocator, parsed.value, .{}) catch return error.OutOfMemory,
        .changed = true,
    };
}

fn natMatchesDesired(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    nats: std.json.Array,
) ProviderError!bool {
    const name = try requiredString(node.inputs, "name");
    for (nats.items) |item| {
        const nat = asObject(item) orelse return error.ProviderBug;
        if (!std.mem.eql(u8, try requiredJsonString(nat, "name"), name)) continue;
        if (!std.mem.eql(u8, try requiredJsonString(nat, "type"), "PUBLIC")) return false;
        if (!std.mem.eql(u8, try requiredJsonString(nat, "natIpAllocateOption"), "MANUAL_ONLY")) return false;
        if (!std.mem.eql(u8, try requiredJsonString(nat, "sourceSubnetworkIpRangesToNat"), "LIST_OF_SUBNETWORKS")) return false;
        if (!std.mem.eql(u8, try firstString(nat, "natIps"), try resolveStringValue(context, try requiredValue(node.inputs, "nat_ip")))) return false;
        if (!std.mem.eql(u8, try firstSubnetwork(nat), try resolveStringValue(context, try requiredValue(node.inputs, "subnetwork")))) return false;
        if (!subnetworkUsesAllIpRanges(nat)) return false;
        if (try requiredJsonInteger(nat, "minPortsPerVm") != try requiredInteger(node.inputs, "min_ports_per_vm")) return false;
        if (try requiredJsonBool(nat, "enableEndpointIndependentMapping") != try requiredBoolean(node.inputs, "enable_endpoint_independent_mapping")) return false;
        return true;
    }
    return false;
}

fn desiredNatJson(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    allocator: std.mem.Allocator,
) ProviderError!std.json.Value {
    var nat: std.json.ObjectMap = .empty;
    try nat.put(allocator, "name", .{ .string = try requiredString(node.inputs, "name") });
    try nat.put(allocator, "type", .{ .string = "PUBLIC" });
    try nat.put(allocator, "natIpAllocateOption", .{ .string = "MANUAL_ONLY" });
    try nat.put(allocator, "sourceSubnetworkIpRangesToNat", .{ .string = "LIST_OF_SUBNETWORKS" });
    var ips = std.json.Array.init(allocator);
    try ips.append(.{ .string = try resolveStringValue(context, try requiredValue(node.inputs, "nat_ip")) });
    try nat.put(allocator, "natIps", .{ .array = ips });
    var ranges = std.json.Array.init(allocator);
    try ranges.append(.{ .string = "ALL_IP_RANGES" });
    var subnet: std.json.ObjectMap = .empty;
    try subnet.put(allocator, "name", .{ .string = try resolveStringValue(context, try requiredValue(node.inputs, "subnetwork")) });
    try subnet.put(allocator, "sourceIpRangesToNat", .{ .array = ranges });
    var subnets = std.json.Array.init(allocator);
    try subnets.append(.{ .object = subnet });
    try nat.put(allocator, "subnetworks", .{ .array = subnets });
    try nat.put(allocator, "minPortsPerVm", .{ .integer = try requiredInteger(node.inputs, "min_ports_per_vm") });
    try nat.put(allocator, "enableEndpointIndependentMapping", .{ .bool = try requiredBoolean(node.inputs, "enable_endpoint_independent_mapping") });
    return .{ .object = nat };
}

fn resultFromRouterJson(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    body: []const u8,
) ProviderError!provider_mod.ReadResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const router = asObject(parsed.value) orelse return error.ProviderBug;
    const nats_value = router.get("nats") orelse return .absent;
    const nats = asArray(nats_value) orelse return error.ProviderBug;
    const name = try requiredString(node.inputs, "name");
    for (nats.items) |item| {
        const nat = asObject(item) orelse return error.ProviderBug;
        if (!std.mem.eql(u8, try requiredJsonString(nat, "name"), name)) continue;
        var observed = try normalizedInputsAlloc(context, node, router, nat);
        defer observed.deinit(context.allocator);
        const physical_id = try physicalIdAlloc(context.allocator, node);
        defer context.allocator.free(physical_id);
        const outputs = [_]state.StateOutput{.{ .name = "resource_id", .value = .{ .string = physical_id } }};
        return .{ .present = try provider_mod.ResourceResult.init(context.allocator, physical_id, observed, &outputs, null) };
    }
    return .absent;
}

fn normalizedInputsAlloc(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    router: std.json.ObjectMap,
    nat: std.json.ObjectMap,
) ProviderError!value.Value {
    const allocator = context.allocator;
    var fields = [_]value.Field{
        .{ .name = "enable_endpoint_independent_mapping", .value = .{ .boolean = try requiredJsonBool(nat, "enableEndpointIndependentMapping") } },
        .{ .name = "min_ports_per_vm", .value = .{ .integer = try requiredJsonInteger(nat, "minPortsPerVm") } },
        .{ .name = "name", .value = .{ .string = try requiredJsonString(nat, "name") } },
        .{ .name = "nat_ip", .value = try preservedStringValue(context, node, "nat_ip", try firstString(nat, "natIps")) },
        .{ .name = "project_id", .value = .{ .string = try requiredString(node.inputs, "project_id") } },
        .{ .name = "region", .value = .{ .string = try requiredString(node.inputs, "region") } },
        .{ .name = "router", .value = try preservedStringValue(context, node, "router", try requiredJsonString(router, "selfLink")) },
        .{ .name = "router_name", .value = .{ .string = try requiredString(node.inputs, "router_name") } },
        .{ .name = "subnetwork", .value = try preservedStringValue(context, node, "subnetwork", try firstSubnetwork(nat)) },
    };
    return value.Value.initOwned(allocator, .{ .object = &fields }) catch |err| switch (err) {
        error.DuplicateField => error.ProviderBug,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn desiredResult(allocator: std.mem.Allocator, node: resource.ResourceNode, handle: ?[]const u8) ProviderError!provider_mod.ResourceResult {
    const physical_id = try physicalIdAlloc(allocator, node);
    defer allocator.free(physical_id);
    const outputs = [_]state.StateOutput{.{ .name = "resource_id", .value = .{ .string = physical_id } }};
    return provider_mod.ResourceResult.init(allocator, physical_id, node.inputs, &outputs, handle);
}

fn pendingResult(allocator: std.mem.Allocator, node: resource.ResourceNode, handle: []const u8) ProviderError!provider_mod.ResourceResult {
    var result = try desiredResult(allocator, node, handle);
    result.completed = false;
    return result;
}

fn routerPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "/compute/v1/projects/{s}/regions/{s}/routers/{s}", .{
        try requiredString(node.inputs, "project_id"),
        try requiredString(node.inputs, "region"),
        try requiredString(node.inputs, "router_name"),
    }) catch return error.OutOfMemory;
}

fn physicalIdAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "projects/{s}/regions/{s}/routers/{s}/nats/{s}", .{
        try requiredString(node.inputs, "project_id"),
        try requiredString(node.inputs, "region"),
        try requiredString(node.inputs, "router_name"),
        try requiredString(node.inputs, "name"),
    }) catch return error.OutOfMemory;
}

fn preservedStringValue(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    field: []const u8,
    remote: []const u8,
) ProviderError!value.Value {
    const desired = try requiredValue(node.inputs, field);
    return if (std.mem.eql(u8, try resolveStringValue(context, desired), remote)) desired else .{ .string = remote };
}

fn firstString(object: std.json.ObjectMap, field: []const u8) ProviderError![]const u8 {
    const array = asArray(object.get(field) orelse return error.ProviderBug) orelse return error.ProviderBug;
    if (array.items.len != 1) return error.ProviderBug;
    return asString(array.items[0]) orelse error.ProviderBug;
}

fn firstSubnetwork(nat: std.json.ObjectMap) ProviderError![]const u8 {
    const array = asArray(nat.get("subnetworks") orelse return error.ProviderBug) orelse return error.ProviderBug;
    if (array.items.len != 1) return error.ProviderBug;
    return requiredJsonString(asObject(array.items[0]) orelse return error.ProviderBug, "name");
}

fn subnetworkUsesAllIpRanges(nat: std.json.ObjectMap) bool {
    const subnetworks = asArray(nat.get("subnetworks") orelse return false) orelse return false;
    if (subnetworks.items.len != 1) return false;
    const subnet = asObject(subnetworks.items[0]) orelse return false;
    const ranges = asArray(subnet.get("sourceIpRangesToNat") orelse return false) orelse return false;
    return ranges.items.len == 1 and std.mem.eql(u8, asString(ranges.items[0]) orelse return false, "ALL_IP_RANGES");
}

fn requiredValue(input: value.Value, name: []const u8) ProviderError!value.Value {
    const fields = switch (input) {
        .object => |fields| fields,
        else => return error.InvalidConfiguration,
    };
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return error.InvalidConfiguration;
}

fn requiredString(input: value.Value, name: []const u8) ProviderError![]const u8 {
    return switch (try requiredValue(input, name)) {
        .string => |string| string,
        else => error.InvalidConfiguration,
    };
}

fn requiredInteger(input: value.Value, name: []const u8) ProviderError!i64 {
    return switch (try requiredValue(input, name)) {
        .integer => |integer| integer,
        else => error.InvalidConfiguration,
    };
}

fn requiredBoolean(input: value.Value, name: []const u8) ProviderError!bool {
    return switch (try requiredValue(input, name)) {
        .boolean => |boolean| boolean,
        else => error.InvalidConfiguration,
    };
}

fn resolveStringValue(context: *provider_mod.OperationContext, input: value.Value) ProviderError![]const u8 {
    return switch (input) {
        .string => |string| string,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}

fn requiredJsonString(object: std.json.ObjectMap, name: []const u8) ProviderError![]const u8 {
    return asString(object.get(name)) orelse error.ProviderBug;
}

fn requiredJsonBool(object: std.json.ObjectMap, name: []const u8) ProviderError!bool {
    return switch (object.get(name) orelse return error.ProviderBug) {
        .bool => |boolean| boolean,
        else => error.ProviderBug,
    };
}

fn requiredJsonInteger(object: std.json.ObjectMap, name: []const u8) ProviderError!i64 {
    return switch (object.get(name) orelse return error.ProviderBug) {
        .integer => |integer| integer,
        else => error.ProviderBug,
    };
}

fn asObject(input: std.json.Value) ?std.json.ObjectMap {
    return switch (input) {
        .object => |object| object,
        else => null,
    };
}

fn asArray(input: std.json.Value) ?std.json.Array {
    return switch (input) {
        .array => |array| array,
        else => null,
    };
}

fn asString(input: ?std.json.Value) ?[]const u8 {
    const value_input = input orelse return null;
    return switch (value_input) {
        .string => |string| string,
        else => null,
    };
}
