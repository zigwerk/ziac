const std = @import("std");
const client_mod = @import("client.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;
const record_set_type = "gcp.dns.RecordSet";

pub const Handler = struct {
    client: *client_mod.Client,

    pub fn read(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_override: ?[]const u8,
    ) ProviderError!provider_mod.ReadResult {
        if (!supports(node)) return error.InvalidConfiguration;
        const generated = try physicalIdAlloc(context.allocator, node);
        defer context.allocator.free(generated);
        const physical_id = physical_override orelse generated;
        if (!std.mem.eql(u8, generated, physical_id)) return error.InvalidConfiguration;
        const path = try restPathFromPhysicalIdAlloc(context.allocator, physical_id);
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .dns, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try resultFromJson(context, node, response.body) };
    }

    pub fn diff(
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        observed: *const provider_mod.ResourceResult,
    ) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        if (!supports(node)) return error.InvalidConfiguration;
        const kind: provider_mod.DiffKind = if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash))
            .noop
        else if (sameIdentity(node.inputs, observed.observed_inputs))
            .update
        else
            .replace;
        const reasons: []const []const u8 = if (kind == .noop) &.{} else &.{"Cloud DNS desired state differs from observed record set"};
        return provider_mod.DiffResult.init(context.allocator, kind, reasons);
    }

    pub fn create(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        if (!supports(node)) return error.InvalidConfiguration;
        const path = try collectionPathAlloc(context.allocator, node);
        defer context.allocator.free(path);
        return self.mutate(context, node, "POST", path);
    }

    pub fn update(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!provider_mod.ResourceResult {
        if (!supports(node)) return error.InvalidConfiguration;
        const expected = try physicalIdAlloc(context.allocator, node);
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        const path = try restPathFromPhysicalIdAlloc(context.allocator, physical_id);
        defer context.allocator.free(path);
        return self.mutate(context, node, "PATCH", path);
    }

    pub fn delete(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!void {
        if (!supports(node)) return error.InvalidConfiguration;
        const expected = try physicalIdAlloc(context.allocator, node);
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        const path = try restPathFromPhysicalIdAlloc(context.allocator, physical_id);
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .dns, .method = "DELETE", .path = path }) catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        response.deinit(context.allocator);
    }

    fn mutate(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        method: []const u8,
        path: []const u8,
    ) ProviderError!provider_mod.ResourceResult {
        const body = try desiredBodyAlloc(context, node);
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .dns, .method = method, .path = path, .body = body });
        defer response.deinit(context.allocator);
        return resultFromJson(context, node, response.body);
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
    return std.mem.eql(u8, node.type_name, record_set_type);
}

fn resultFromJson(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    body: []const u8,
) ProviderError!provider_mod.ResourceResult {
    const allocator = context.allocator;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const remote = asObject(parsed.value) orelse return error.ProviderBug;
    const name = try requiredJsonString(remote, "name");
    const record_type = try requiredJsonString(remote, "type");
    const ttl = try requiredJsonInteger(remote, "ttl");
    const remote_rrdatas = asArray(remote.get("rrdatas") orelse return error.ProviderBug) orelse return error.ProviderBug;
    var remote_rrdatas_value = try jsonArrayValueAlloc(allocator, remote_rrdatas);
    defer remote_rrdatas_value.deinit(allocator);
    const desired_rrdatas = try requiredValue(node.inputs, "rrdatas");
    const normalized_rrdatas = if (try recordDataMatches(context, desired_rrdatas, remote_rrdatas))
        desired_rrdatas
    else
        remote_rrdatas_value;
    const normalized_fields = [_]value.Field{
        .{ .name = "name", .value = .{ .string = name } },
        .{ .name = "project_id", .value = .{ .string = try requiredString(node.inputs, "project_id") } },
        .{ .name = "rrdatas", .value = normalized_rrdatas },
        .{ .name = "ttl", .value = .{ .integer = ttl } },
        .{ .name = "type", .value = .{ .string = record_type } },
        .{ .name = "zone", .value = .{ .string = try requiredString(node.inputs, "zone") } },
    };
    const physical_id = try physicalIdFromIdentityAlloc(
        allocator,
        try requiredString(node.inputs, "project_id"),
        try requiredString(node.inputs, "zone"),
        record_type,
        name,
    );
    defer allocator.free(physical_id);
    const outputs = [_]state.StateOutput{
        .{ .name = "fqdn", .value = .{ .string = name } },
        .{ .name = "record_type", .value = .{ .string = record_type } },
    };
    return provider_mod.ResourceResult.init(allocator, physical_id, .{ .object = &normalized_fields }, &outputs, null);
}

fn desiredBodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError![]const u8 {
    const allocator = context.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var body: std.json.ObjectMap = .empty;
    try body.put(arena, "name", .{ .string = try requiredString(node.inputs, "name") });
    try body.put(arena, "type", .{ .string = try requiredString(node.inputs, "type") });
    try body.put(arena, "ttl", .{ .integer = try requiredInteger(node.inputs, "ttl") });
    try body.put(arena, "rrdatas", try valueStringListJson(context, arena, try requiredValue(node.inputs, "rrdatas")));
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = body }, .{}) catch return error.OutOfMemory;
}

fn collectionPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "/dns/v1/projects/{s}/managedZones/{s}/rrsets", .{
        try requiredString(node.inputs, "project_id"),
        try requiredString(node.inputs, "zone"),
    }) catch return error.OutOfMemory;
}

fn physicalIdAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]const u8 {
    return physicalIdFromIdentityAlloc(
        allocator,
        try requiredString(node.inputs, "project_id"),
        try requiredString(node.inputs, "zone"),
        try requiredString(node.inputs, "type"),
        try requiredString(node.inputs, "name"),
    );
}

fn physicalIdFromIdentityAlloc(
    allocator: std.mem.Allocator,
    project_id: []const u8,
    zone: []const u8,
    record_type: []const u8,
    name: []const u8,
) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "projects/{s}/managedZones/{s}/rrsets/{s}/{s}", .{
        project_id,
        zone,
        record_type,
        name,
    }) catch return error.OutOfMemory;
}

fn restPathFromPhysicalIdAlloc(allocator: std.mem.Allocator, physical_id: []const u8) ProviderError![]const u8 {
    var segments = std.mem.splitScalar(u8, std.mem.trim(u8, physical_id, "/"), '/');
    if (!std.mem.eql(u8, segments.next() orelse return error.InvalidConfiguration, "projects")) return error.InvalidConfiguration;
    const project_id = segments.next() orelse return error.InvalidConfiguration;
    if (!std.mem.eql(u8, segments.next() orelse return error.InvalidConfiguration, "managedZones")) return error.InvalidConfiguration;
    const zone = segments.next() orelse return error.InvalidConfiguration;
    if (!std.mem.eql(u8, segments.next() orelse return error.InvalidConfiguration, "rrsets")) return error.InvalidConfiguration;
    const record_type = segments.next() orelse return error.InvalidConfiguration;
    const name = segments.next() orelse return error.InvalidConfiguration;
    if (segments.next() != null) return error.InvalidConfiguration;
    return std.fmt.allocPrint(allocator, "/dns/v1/projects/{s}/managedZones/{s}/rrsets/{s}/{s}", .{
        project_id,
        zone,
        name,
        record_type,
    }) catch return error.OutOfMemory;
}

fn sameIdentity(desired: value.Value, observed: value.Value) bool {
    for ([_][]const u8{ "project_id", "zone", "name", "type" }) |field| {
        const desired_value = requiredString(desired, field) catch return false;
        const observed_value = requiredString(observed, field) catch return false;
        if (!std.mem.eql(u8, desired_value, observed_value)) return false;
    }
    return true;
}

fn valueStringListJson(
    context: *provider_mod.OperationContext,
    allocator: std.mem.Allocator,
    input: value.Value,
) ProviderError!std.json.Value {
    const values = switch (input) {
        .list => |values| values,
        else => return error.InvalidConfiguration,
    };
    var array = std.json.Array.init(allocator);
    for (values) |item| {
        const string = switch (item) {
            .string => |string| string,
            .output_ref => |reference| try context.resolveOutputString(reference),
            else => return error.InvalidConfiguration,
        };
        for (array.items) |existing| {
            const existing_string = switch (existing) {
                .string => |value_string| value_string,
                else => unreachable,
            };
            if (std.mem.eql(u8, string, existing_string)) return error.InvalidConfiguration;
        }
        try array.append(.{ .string = string });
    }
    return .{ .array = array };
}

fn recordDataMatches(
    context: *provider_mod.OperationContext,
    desired: value.Value,
    remote: std.json.Array,
) ProviderError!bool {
    const desired_values = switch (desired) {
        .list => |items| items,
        else => return error.InvalidConfiguration,
    };
    if (desired_values.len != remote.items.len) return false;
    const matched = try context.allocator.alloc(bool, remote.items.len);
    defer context.allocator.free(matched);
    @memset(matched, false);
    for (desired_values) |item| {
        const desired_string = switch (item) {
            .string => |string| string,
            .output_ref => |reference| try context.resolveOutputString(reference),
            else => return error.InvalidConfiguration,
        };
        var found = false;
        for (remote.items, 0..) |remote_item, index| {
            if (matched[index]) continue;
            const remote_string = switch (remote_item) {
                .string => |string| string,
                else => return error.ProviderBug,
            };
            if (std.mem.eql(u8, desired_string, remote_string)) {
                matched[index] = true;
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn jsonArrayValueAlloc(allocator: std.mem.Allocator, input: std.json.Array) ProviderError!value.Value {
    const json = std.json.Stringify.valueAlloc(allocator, std.json.Value{ .array = input }, .{}) catch return error.OutOfMemory;
    defer allocator.free(json);
    return value.Value.parseJsonAlloc(allocator, json) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ProviderBug,
    };
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

fn requiredJsonString(object: std.json.ObjectMap, name: []const u8) ProviderError![]const u8 {
    const found = object.get(name) orelse return error.ProviderBug;
    return switch (found) {
        .string => |string| string,
        else => error.ProviderBug,
    };
}

fn requiredJsonInteger(object: std.json.ObjectMap, name: []const u8) ProviderError!i64 {
    const found = object.get(name) orelse return error.ProviderBug;
    return switch (found) {
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
