const std = @import("std");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;
const range_type = "gcp.compute.PrivateServiceRange";
const connection_type = "gcp.servicenetworking.Connection";
const Kind = enum { range, connection };

pub const Handler = struct {
    client: *client_mod.Client,
    operation_policy: operation.Policy = .{},

    pub fn read(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
        const resource_kind = try kindFor(node);
        if (context.operation_handle) |handle| try self.waitOperation(context, node, resource_kind, handle);
        return switch (resource_kind) {
            .range => self.readRange(context, node, physical_override),
            .connection => self.readConnection(context, node, physical_override),
        };
    }

    pub fn diff(context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash)) return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        const resource_kind = try kindFor(node);
        const replacement = resource_kind == .range or changedAny(node.inputs, observed.observed_inputs, &.{ "project_id", "service", "network" });
        return provider_mod.DiffResult.init(
            context.allocator,
            if (replacement) .replace else .update,
            if (replacement) &.{"Private service identity, network, or allocated address range differs"} else &.{"Reserved private service ranges differ"},
        );
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        const resource_kind = try kindFor(node);
        const body = try desiredBodyAlloc(context.allocator, node, resource_kind, null);
        defer context.allocator.free(body);
        const path = try createPathAlloc(context.allocator, node, resource_kind);
        defer context.allocator.free(path);
        const api: client_mod.Api = if (resource_kind == .range) .compute else .service_networking;
        const handle = try self.startOperation(context, api, "POST", path, body);
        defer context.allocator.free(handle);
        return pendingResult(context, node, resource_kind, handle);
    }

    pub fn update(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        if (try kindFor(node) != .connection) return error.InvalidConfiguration;
        try validateConnectionPhysical(node, observed.physical_id);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}?updateMask=reservedPeeringRanges&force=true", .{observed.physical_id});
        defer context.allocator.free(path);
        const body = try desiredBodyAlloc(context.allocator, node, .connection, observed.physical_id);
        defer context.allocator.free(body);
        const handle = try self.startOperation(context, .service_networking, "PATCH", path, body);
        defer context.allocator.free(handle);
        return pendingResultWithPhysical(context, node, observed.physical_id, handle);
    }

    pub fn delete(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!void {
        const resource_kind = try kindFor(node);
        const path = switch (resource_kind) {
            .range => blk: {
                const expected = try rangePhysicalAlloc(context.allocator, node);
                defer context.allocator.free(expected);
                if (!std.mem.eql(u8, expected, std.mem.trimStart(u8, physical_id, "/"))) return error.InvalidConfiguration;
                break :blk try std.fmt.allocPrint(context.allocator, "/compute/v1/{s}", .{expected});
            },
            .connection => blk: {
                try validateConnectionPhysical(node, physical_id);
                break :blk try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{std.mem.trimStart(u8, physical_id, "/")});
            },
        };
        defer context.allocator.free(path);
        const api: client_mod.Api = if (resource_kind == .range) .compute else .service_networking;
        const method = if (resource_kind == .range) "DELETE" else "POST";
        const body = if (resource_kind == .connection)
            try std.fmt.allocPrint(context.allocator, "{{\"consumerNetwork\":\"{s}\"}}", .{try requiredString(node.inputs, "network")})
        else
            try context.allocator.dupe(u8, "");
        defer context.allocator.free(body);
        const handle = self.startOperation(context, api, method, path, body) catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer context.allocator.free(handle);
        try self.waitOperation(context, node, resource_kind, handle);
    }

    pub fn importResource(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!provider_mod.ResourceResult {
        const read_result = try self.read(context, node, physical_id);
        return switch (read_result) {
            .absent => error.NotFound,
            .present => |present| present,
        };
    }

    fn readRange(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
        const expected = try rangePhysicalAlloc(context.allocator, node);
        defer context.allocator.free(expected);
        if (physical_override) |physical| if (!std.mem.eql(u8, expected, std.mem.trimStart(u8, physical, "/"))) return error.InvalidConfiguration;
        const path = try std.fmt.allocPrint(context.allocator, "/compute/v1/{s}", .{expected});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .compute, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try rangeResultFromJson(context, node, response.body) };
    }

    fn readConnection(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
        if (physical_override) |physical| try validateConnectionPhysical(node, physical);
        const network = try requiredString(node.inputs, "network");
        const encoded_network = try percentEncodeAlloc(context.allocator, network);
        defer context.allocator.free(encoded_network);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/services/{s}/connections?network={s}", .{ try requiredString(node.inputs, "service"), encoded_network });
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .service_networking, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return connectionResultFromList(context, node, response.body, physical_override);
    }

    fn startOperation(self: Handler, context: *provider_mod.OperationContext, api: client_mod.Api, method: []const u8, path: []const u8, body: []const u8) ProviderError![]const u8 {
        var response = try self.request(context, .{ .api = api, .method = method, .path = path, .body = body });
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        return context.allocator.dupe(u8, jsonString((jsonObject(parsed.value) orelse return error.ProviderBug).get("name")) orelse return error.ProviderBug) catch error.OutOfMemory;
    }

    fn waitOperation(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, resource_kind: Kind, handle: []const u8) ProviderError!void {
        var target = switch (resource_kind) {
            .range => blk: {
                const base = try std.fmt.allocPrint(context.allocator, "{s}/compute/v1", .{std.mem.trimEnd(u8, self.client.endpoints.compute, "/")});
                defer context.allocator.free(base);
                break :blk operation.Target.computeGlobalAlloc(context.allocator, base, try requiredString(node.inputs, "project_id"), handle) catch return error.OutOfMemory;
            },
            .connection => blk: {
                const base = try std.fmt.allocPrint(context.allocator, "{s}/v1", .{std.mem.trimEnd(u8, self.client.endpoints.service_networking, "/")});
                defer context.allocator.free(base);
                break :blk operation.Target.genericAlloc(context.allocator, base, handle) catch return error.OutOfMemory;
            },
        };
        defer target.deinit(context.allocator);
        var completed = try operation.waitAlloc(self.client, context, target, self.operation_policy);
        completed.deinit(context.allocator);
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, request_value: client_mod.Request) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, request_value, &diagnostic);
    }
};

pub fn supports(node: resource.ResourceNode) bool {
    return std.mem.eql(u8, node.type_name, range_type) or std.mem.eql(u8, node.type_name, connection_type);
}

fn kindFor(node: resource.ResourceNode) ProviderError!Kind {
    if (std.mem.eql(u8, node.type_name, range_type)) return .range;
    if (std.mem.eql(u8, node.type_name, connection_type)) return .connection;
    return error.InvalidConfiguration;
}

fn createPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, resource_kind: Kind) ProviderError![]const u8 {
    return switch (resource_kind) {
        .range => std.fmt.allocPrint(allocator, "/compute/v1/projects/{s}/global/addresses", .{try requiredString(node.inputs, "project_id")}) catch error.OutOfMemory,
        .connection => std.fmt.allocPrint(allocator, "/v1/services/{s}/connections", .{try requiredString(node.inputs, "service")}) catch error.OutOfMemory,
    };
}

fn desiredBodyAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, resource_kind: Kind, physical: ?[]const u8) ProviderError![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var body: std.json.ObjectMap = .empty;
    switch (resource_kind) {
        .range => {
            try body.put(arena, "name", .{ .string = try requiredString(node.inputs, "name") });
            try body.put(arena, "addressType", .{ .string = "INTERNAL" });
            try body.put(arena, "purpose", .{ .string = "VPC_PEERING" });
            try body.put(arena, "prefixLength", .{ .integer = try requiredInteger(node.inputs, "prefix_length") });
            try body.put(arena, "network", .{ .string = try requiredString(node.inputs, "network") });
            const address = try requiredString(node.inputs, "address");
            if (address.len > 0) try body.put(arena, "address", .{ .string = address });
        },
        .connection => {
            if (physical) |name| try body.put(arena, "name", .{ .string = name });
            try body.put(arena, "network", .{ .string = try requiredString(node.inputs, "network") });
            try body.put(arena, "reservedPeeringRanges", .{ .array = try newlineArray(arena, try requiredString(node.inputs, "reserved_ranges")) });
        },
    }
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = body }, .{}) catch error.OutOfMemory;
}

fn pendingResult(context: *provider_mod.OperationContext, node: resource.ResourceNode, resource_kind: Kind, handle: []const u8) ProviderError!provider_mod.ResourceResult {
    const physical = switch (resource_kind) {
        .range => try rangePhysicalAlloc(context.allocator, node),
        .connection => try std.fmt.allocPrint(context.allocator, "services/{s}/connections/{s}", .{ try requiredString(node.inputs, "service"), node.logical_id }),
    };
    defer context.allocator.free(physical);
    return pendingResultWithPhysical(context, node, physical, handle);
}

fn pendingResultWithPhysical(context: *provider_mod.OperationContext, node: resource.ResourceNode, physical: []const u8, handle: []const u8) ProviderError!provider_mod.ResourceResult {
    var result = try provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &.{}, handle);
    result.completed = false;
    return result;
}

fn rangeResultFromJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, body: []const u8) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const remote = jsonObject(parsed.value) orelse return error.ProviderBug;
    const physical = try rangePhysicalAlloc(context.allocator, node);
    defer context.allocator.free(physical);
    const desired_address = try requiredString(node.inputs, "address");
    const fields = [_]value.Field{
        .{ .name = "address", .value = .{ .string = if (desired_address.len == 0) "" else jsonString(remote.get("address")) orelse "" } },
        .{ .name = "address_type", .value = .{ .string = jsonString(remote.get("addressType")) orelse "" } },
        .{ .name = "name", .value = .{ .string = jsonString(remote.get("name")) orelse return error.ProviderBug } },
        .{ .name = "network", .value = .{ .string = jsonString(remote.get("network")) orelse return error.ProviderBug } },
        .{ .name = "prefix_length", .value = .{ .integer = jsonInteger(remote.get("prefixLength")) orelse return error.ProviderBug } },
        .{ .name = "project_id", .value = try requiredValue(node.inputs, "project_id") },
        .{ .name = "purpose", .value = .{ .string = jsonString(remote.get("purpose")) orelse "" } },
    };
    var observed = try ownedObject(context.allocator, &fields);
    defer observed.deinit(context.allocator);
    const outputs = [_]state.StateOutput{
        .{ .name = "name", .value = .{ .string = jsonString(remote.get("name")) orelse return error.ProviderBug } },
        .{ .name = "self_link", .value = .{ .string = jsonString(remote.get("selfLink")) orelse return error.ProviderBug } },
        .{ .name = "address", .value = .{ .string = jsonString(remote.get("address")) orelse return error.ProviderBug } },
    };
    return provider_mod.ResourceResult.init(context.allocator, physical, observed, &outputs, null);
}

fn connectionResultFromList(context: *provider_mod.OperationContext, node: resource.ResourceNode, body: []const u8, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const connections = root.get("connections") orelse return .absent;
    if (connections != .array) return error.ProviderBug;
    const expected_network = try requiredString(node.inputs, "network");
    const expected_peering: ?[]const u8 = if (physical_override) |physical| blk: {
        const separator = std.mem.lastIndexOfScalar(u8, physical, '/') orelse return error.InvalidConfiguration;
        break :blk physical[separator + 1 ..];
    } else null;
    for (connections.array.items) |candidate| {
        const remote = jsonObject(candidate) orelse return error.ProviderBug;
        if (!std.mem.eql(u8, jsonString(remote.get("network")) orelse continue, expected_network)) continue;
        const peering = jsonString(remote.get("peering")) orelse return error.ProviderBug;
        if (expected_peering) |expected| if (!std.mem.eql(u8, expected, peering)) continue;
        return .{ .present = try connectionResult(context, node, remote) };
    }
    return .absent;
}

fn connectionResult(context: *provider_mod.OperationContext, node: resource.ResourceNode, remote: std.json.ObjectMap) ProviderError!provider_mod.ResourceResult {
    const peering = jsonString(remote.get("peering")) orelse return error.ProviderBug;
    const service = try requiredString(node.inputs, "service");
    const physical = try std.fmt.allocPrint(context.allocator, "services/{s}/connections/{s}", .{ service, peering });
    defer context.allocator.free(physical);
    const ranges = try sortedJsonStringsAlloc(context.allocator, remote.get("reservedPeeringRanges"));
    defer context.allocator.free(ranges);
    const fields = [_]value.Field{
        .{ .name = "network", .value = .{ .string = jsonString(remote.get("network")) orelse return error.ProviderBug } },
        .{ .name = "project_id", .value = try requiredValue(node.inputs, "project_id") },
        .{ .name = "range_dependencies", .value = try requiredValue(node.inputs, "range_dependencies") },
        .{ .name = "reserved_ranges", .value = .{ .string = ranges } },
        .{ .name = "service", .value = .{ .string = service } },
    };
    var observed = try ownedObject(context.allocator, &fields);
    defer observed.deinit(context.allocator);
    const outputs = [_]state.StateOutput{
        .{ .name = "name", .value = .{ .string = physical } },
        .{ .name = "peering", .value = .{ .string = peering } },
        .{ .name = "network", .value = .{ .string = jsonString(remote.get("network")) orelse return error.ProviderBug } },
    };
    return provider_mod.ResourceResult.init(context.allocator, physical, observed, &outputs, null);
}

fn rangePhysicalAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "projects/{s}/global/addresses/{s}", .{ try requiredString(node.inputs, "project_id"), try requiredString(node.inputs, "name") }) catch error.OutOfMemory;
}

fn validateConnectionPhysical(node: resource.ResourceNode, physical: []const u8) ProviderError!void {
    const prefix_buffer = std.fmt.allocPrint(std.heap.page_allocator, "services/{s}/connections/", .{try requiredString(node.inputs, "service")}) catch return error.OutOfMemory;
    defer std.heap.page_allocator.free(prefix_buffer);
    if (!std.mem.startsWith(u8, std.mem.trimStart(u8, physical, "/"), prefix_buffer) or physical.len <= prefix_buffer.len) return error.InvalidConfiguration;
}

fn newlineArray(allocator: std.mem.Allocator, text: []const u8) ProviderError!std.json.Array {
    var result = std.json.Array.init(allocator);
    var iterator = std.mem.tokenizeScalar(u8, text, '\n');
    while (iterator.next()) |item| try result.append(.{ .string = item });
    return result;
}

fn sortedJsonStringsAlloc(allocator: std.mem.Allocator, candidate: ?std.json.Value) ProviderError![]const u8 {
    const present = candidate orelse return error.ProviderBug;
    if (present != .array) return error.ProviderBug;
    const strings = try allocator.alloc([]const u8, present.array.items.len);
    defer allocator.free(strings);
    for (present.array.items, 0..) |item, index| strings[index] = jsonString(item) orelse return error.ProviderBug;
    std.mem.sort([]const u8, strings, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);
    return std.mem.join(allocator, "\n", strings) catch error.OutOfMemory;
}

fn percentEncodeAlloc(allocator: std.mem.Allocator, input: []const u8) ProviderError![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (input) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try output.append(allocator, byte);
        } else {
            try output.append(allocator, '%');
            const digits = "0123456789ABCDEF";
            try output.append(allocator, digits[byte >> 4]);
            try output.append(allocator, digits[byte & 0x0f]);
        }
    }
    return output.toOwnedSlice(allocator);
}

fn changedAny(desired: value.Value, observed: value.Value, names: []const []const u8) bool {
    for (names) |name| if (changedField(desired, observed, name)) return true;
    return false;
}

fn changedField(desired: value.Value, observed: value.Value, name: []const u8) bool {
    const left = findValue(desired, name) orelse return true;
    const right = findValue(observed, name) orelse return true;
    const left_hash = left.sha256(std.heap.page_allocator) catch return true;
    const right_hash = right.sha256(std.heap.page_allocator) catch return true;
    return !std.mem.eql(u8, &left_hash, &right_hash);
}

fn ownedObject(allocator: std.mem.Allocator, fields: []const value.Field) ProviderError!value.Value {
    return value.Value.initOwned(allocator, .{ .object = fields }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateField => error.ProviderBug,
    };
}

fn requiredValue(inputs: value.Value, name: []const u8) ProviderError!value.Value {
    return findValue(inputs, name) orelse error.InvalidConfiguration;
}

fn requiredString(inputs: value.Value, name: []const u8) ProviderError![]const u8 {
    return switch (try requiredValue(inputs, name)) {
        .string => |text| text,
        else => error.InvalidConfiguration,
    };
}

fn requiredInteger(inputs: value.Value, name: []const u8) ProviderError!i64 {
    return switch (try requiredValue(inputs, name)) {
        .integer => |number| number,
        else => error.InvalidConfiguration,
    };
}

fn findValue(inputs: value.Value, name: []const u8) ?value.Value {
    if (inputs != .object) return null;
    for (inputs.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return null;
}

fn jsonObject(candidate: std.json.Value) ?std.json.ObjectMap {
    return switch (candidate) {
        .object => |object| object,
        else => null,
    };
}

fn jsonString(candidate: ?std.json.Value) ?[]const u8 {
    const present = candidate orelse return null;
    return switch (present) {
        .string => |text| text,
        else => null,
    };
}

fn jsonInteger(candidate: ?std.json.Value) ?i64 {
    const present = candidate orelse return null;
    return switch (present) {
        .integer => |number| number,
        else => null,
    };
}
