const std = @import("std");
const client_mod = @import("client.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;
const record_set_type = "gcp.dns.RecordSet";
const managed_zone_type = "gcp.dns.ManagedZone";

const Kind = enum { record_set, managed_zone };

pub const Handler = struct {
    client: *client_mod.Client,

    pub fn read(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_override: ?[]const u8,
    ) ProviderError!provider_mod.ReadResult {
        const resource_kind = kind(node) orelse return error.InvalidConfiguration;
        const generated = try physicalIdAlloc(context, node, resource_kind);
        defer context.allocator.free(generated);
        const physical_id = physical_override orelse generated;
        if (!std.mem.eql(u8, generated, physical_id)) return error.InvalidConfiguration;
        const path = try restPathFromPhysicalIdAlloc(context.allocator, physical_id, resource_kind);
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .dns, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try resultFromJson(context, node, resource_kind, response.body) };
    }

    pub fn diff(
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        observed: *const provider_mod.ResourceResult,
    ) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        const resource_kind = kind(node) orelse return error.InvalidConfiguration;
        const diff_kind: provider_mod.DiffKind = if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash))
            .noop
        else if (resource_kind == .record_set and try sameIdentity(context, node.inputs, observed.observed_inputs))
            .update
        else
            .replace;
        const reasons: []const []const u8 = if (diff_kind == .noop) &.{} else &.{"Cloud DNS desired state differs from observed resource"};
        return provider_mod.DiffResult.init(context.allocator, diff_kind, reasons);
    }

    pub fn create(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        const resource_kind = kind(node) orelse return error.InvalidConfiguration;
        const path = try collectionPathAlloc(context.allocator, node, resource_kind);
        defer context.allocator.free(path);
        return self.mutate(context, node, resource_kind, "POST", path);
    }

    pub fn update(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!provider_mod.ResourceResult {
        const resource_kind = kind(node) orelse return error.InvalidConfiguration;
        if (resource_kind != .record_set) return error.InvalidConfiguration;
        const expected = try physicalIdAlloc(context, node, resource_kind);
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        const path = try restPathFromPhysicalIdAlloc(context.allocator, physical_id, resource_kind);
        defer context.allocator.free(path);
        return self.mutate(context, node, resource_kind, "PATCH", path);
    }

    pub fn delete(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!void {
        const resource_kind = kind(node) orelse return error.InvalidConfiguration;
        const expected = try physicalIdAlloc(context, node, resource_kind);
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        const path = try restPathFromPhysicalIdAlloc(context.allocator, physical_id, resource_kind);
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
        resource_kind: Kind,
        method: []const u8,
        path: []const u8,
    ) ProviderError!provider_mod.ResourceResult {
        const body = try desiredBodyAlloc(context, node, resource_kind);
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .dns, .method = method, .path = path, .body = body });
        defer response.deinit(context.allocator);
        return resultFromJson(context, node, resource_kind, response.body);
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
    return kind(node) != null;
}

fn kind(node: resource.ResourceNode) ?Kind {
    if (std.mem.eql(u8, node.type_name, record_set_type)) return .record_set;
    if (std.mem.eql(u8, node.type_name, managed_zone_type)) return .managed_zone;
    return null;
}

fn resultFromJson(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    resource_kind: Kind,
    body: []const u8,
) ProviderError!provider_mod.ResourceResult {
    return switch (resource_kind) {
        .record_set => recordSetResultFromJson(context, node, body),
        .managed_zone => managedZoneResultFromJson(context, node, body),
    };
}

fn recordSetResultFromJson(
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
        .{ .name = "name", .value = try normalizedFqdnInput(context, node.inputs, "name", name) },
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

fn managedZoneResultFromJson(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    body: []const u8,
) ProviderError!provider_mod.ResourceResult {
    const allocator = context.allocator;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const remote = asObject(parsed.value) orelse return error.ProviderBug;
    const name = try requiredJsonString(remote, "name");
    const dns_name = try requiredJsonString(remote, "dnsName");
    const visibility = try requiredJsonString(remote, "visibility");
    if (!std.ascii.eqlIgnoreCase(visibility, "private")) return error.InvalidConfiguration;
    const private_config = asObject(remote.get("privateVisibilityConfig") orelse return error.ProviderBug) orelse return error.ProviderBug;
    const networks = asArray(private_config.get("networks") orelse return error.ProviderBug) orelse return error.ProviderBug;
    if (networks.items.len != 1) return error.InvalidConfiguration;
    const network_object = asObject(networks.items[0]) orelse return error.ProviderBug;
    const network = try requiredJsonString(network_object, "networkUrl");
    const fields = [_]value.Field{
        .{ .name = "dns_name", .value = try normalizedFqdnInput(context, node.inputs, "dns_name", dns_name) },
        .{ .name = "name", .value = .{ .string = name } },
        .{ .name = "network", .value = try normalizedStringInput(context, node.inputs, "network", network) },
        .{ .name = "project_id", .value = .{ .string = try requiredString(node.inputs, "project_id") } },
        .{ .name = "visibility", .value = .{ .string = "PRIVATE" } },
    };
    const physical_id = try managedZonePhysicalIdAlloc(
        allocator,
        try requiredString(node.inputs, "project_id"),
        name,
    );
    defer allocator.free(physical_id);
    const outputs = [_]state.StateOutput{
        .{ .name = "zone_name", .value = .{ .string = name } },
        .{ .name = "dns_name", .value = .{ .string = dns_name } },
    };
    return provider_mod.ResourceResult.init(allocator, physical_id, .{ .object = &fields }, &outputs, null);
}

fn desiredBodyAlloc(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    resource_kind: Kind,
) ProviderError![]const u8 {
    return switch (resource_kind) {
        .record_set => recordSetDesiredBodyAlloc(context, node),
        .managed_zone => managedZoneDesiredBodyAlloc(context, node),
    };
}

fn recordSetDesiredBodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError![]const u8 {
    const allocator = context.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var body: std.json.ObjectMap = .empty;
    const resolved_name = try resolveInputString(context, node.inputs, "name");
    const name = try fqdnAlloc(arena, resolved_name);
    try body.put(arena, "name", .{ .string = name });
    try body.put(arena, "type", .{ .string = try requiredString(node.inputs, "type") });
    try body.put(arena, "ttl", .{ .integer = try requiredInteger(node.inputs, "ttl") });
    try body.put(arena, "rrdatas", try valueStringListJson(context, arena, try requiredValue(node.inputs, "rrdatas")));
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = body }, .{}) catch return error.OutOfMemory;
}

fn managedZoneDesiredBodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError![]const u8 {
    const allocator = context.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var body: std.json.ObjectMap = .empty;
    try body.put(arena, "name", .{ .string = try requiredString(node.inputs, "name") });
    const resolved_dns_name = try resolveInputString(context, node.inputs, "dns_name");
    try body.put(arena, "dnsName", .{ .string = try fqdnAlloc(arena, resolved_dns_name) });
    try body.put(arena, "visibility", .{ .string = "private" });
    const project_id = try requiredString(node.inputs, "project_id");
    const network_url = try resolveInputString(context, node.inputs, "network");
    if (!isProjectNetwork(network_url, project_id)) return error.InvalidConfiguration;
    var network = std.json.ObjectMap.empty;
    try network.put(arena, "networkUrl", .{ .string = network_url });
    var networks = std.json.Array.init(arena);
    try networks.append(.{ .object = network });
    var private_config = std.json.ObjectMap.empty;
    try private_config.put(arena, "networks", .{ .array = networks });
    try body.put(arena, "privateVisibilityConfig", .{ .object = private_config });
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = body }, .{}) catch return error.OutOfMemory;
}

fn collectionPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, resource_kind: Kind) ProviderError![]const u8 {
    return switch (resource_kind) {
        .record_set => std.fmt.allocPrint(allocator, "/dns/v1/projects/{s}/managedZones/{s}/rrsets", .{
            try requiredString(node.inputs, "project_id"),
            try requiredString(node.inputs, "zone"),
        }),
        .managed_zone => std.fmt.allocPrint(allocator, "/dns/v1/projects/{s}/managedZones", .{
            try requiredString(node.inputs, "project_id"),
        }),
    } catch return error.OutOfMemory;
}

fn physicalIdAlloc(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    resource_kind: Kind,
) ProviderError![]const u8 {
    return switch (resource_kind) {
        .record_set => blk: {
            const resolved_name = try resolveInputString(context, node.inputs, "name");
            const name = try fqdnAlloc(context.allocator, resolved_name);
            defer context.allocator.free(name);
            break :blk physicalIdFromIdentityAlloc(
                context.allocator,
                try requiredString(node.inputs, "project_id"),
                try requiredString(node.inputs, "zone"),
                try requiredString(node.inputs, "type"),
                name,
            );
        },
        .managed_zone => managedZonePhysicalIdAlloc(
            context.allocator,
            try requiredString(node.inputs, "project_id"),
            try requiredString(node.inputs, "name"),
        ),
    };
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

fn managedZonePhysicalIdAlloc(
    allocator: std.mem.Allocator,
    project_id: []const u8,
    name: []const u8,
) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "projects/{s}/managedZones/{s}", .{ project_id, name }) catch return error.OutOfMemory;
}

fn restPathFromPhysicalIdAlloc(
    allocator: std.mem.Allocator,
    physical_id: []const u8,
    resource_kind: Kind,
) ProviderError![]const u8 {
    var segments = std.mem.splitScalar(u8, std.mem.trim(u8, physical_id, "/"), '/');
    if (!std.mem.eql(u8, segments.next() orelse return error.InvalidConfiguration, "projects")) return error.InvalidConfiguration;
    const project_id = segments.next() orelse return error.InvalidConfiguration;
    if (!std.mem.eql(u8, segments.next() orelse return error.InvalidConfiguration, "managedZones")) return error.InvalidConfiguration;
    const zone = segments.next() orelse return error.InvalidConfiguration;
    if (resource_kind == .managed_zone) {
        if (segments.next() != null) return error.InvalidConfiguration;
        return std.fmt.allocPrint(allocator, "/dns/v1/projects/{s}/managedZones/{s}", .{ project_id, zone }) catch return error.OutOfMemory;
    }
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

fn sameIdentity(
    context: *provider_mod.OperationContext,
    desired: value.Value,
    observed: value.Value,
) ProviderError!bool {
    for ([_][]const u8{ "project_id", "zone", "type" }) |field| {
        const desired_value = try requiredString(desired, field);
        const observed_value = try requiredString(observed, field);
        if (!std.mem.eql(u8, desired_value, observed_value)) return false;
    }
    const desired_name = try resolveValueString(context, try requiredValue(desired, "name"));
    const observed_name = try resolveValueString(context, try requiredValue(observed, "name"));
    return fqdnEqual(desired_name, observed_name);
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

fn normalizedFqdnInput(
    context: *provider_mod.OperationContext,
    inputs: value.Value,
    name: []const u8,
    remote: []const u8,
) ProviderError!value.Value {
    const desired = try requiredValue(inputs, name);
    const resolved = try resolveValueString(context, desired);
    return if (fqdnEqual(resolved, remote)) desired else .{ .string = remote };
}

fn normalizedStringInput(
    context: *provider_mod.OperationContext,
    inputs: value.Value,
    name: []const u8,
    remote: []const u8,
) ProviderError!value.Value {
    const desired = try requiredValue(inputs, name);
    const resolved = try resolveValueString(context, desired);
    return if (std.mem.eql(u8, resolved, remote)) desired else .{ .string = remote };
}

fn resolveInputString(
    context: *provider_mod.OperationContext,
    inputs: value.Value,
    name: []const u8,
) ProviderError![]const u8 {
    return resolveValueString(context, try requiredValue(inputs, name));
}

fn resolveValueString(context: *provider_mod.OperationContext, input: value.Value) ProviderError![]const u8 {
    return switch (input) {
        .string => |string| string,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}

fn fqdnAlloc(allocator: std.mem.Allocator, name: []const u8) ProviderError![]const u8 {
    if (!isValidDnsName(name)) return error.InvalidConfiguration;
    if (name[name.len - 1] == '.') return allocator.dupe(u8, name) catch return error.OutOfMemory;
    return std.fmt.allocPrint(allocator, "{s}.", .{name}) catch return error.OutOfMemory;
}

fn isValidDnsName(name: []const u8) bool {
    if (name.len < 2 or name.len > 254) return false;
    const trailing_dot = name[name.len - 1] == '.';
    const labels_input = if (trailing_dot) name[0 .. name.len - 1] else name;
    if (!trailing_dot and name.len == 254) return false;
    var labels = std.mem.splitScalar(u8, labels_input, '.');
    var count: usize = 0;
    while (labels.next()) |label| : (count += 1) {
        if (label.len == 0 or label.len > 63) return false;
        if (std.mem.eql(u8, label, "*")) {
            if (count != 0) return false;
            continue;
        }
        for (label) |character| {
            if (!(std.ascii.isLower(character) or std.ascii.isDigit(character) or character == '-' or character == '_')) return false;
        }
    }
    return count >= 2;
}

fn isProjectNetwork(input: []const u8, project: []const u8) bool {
    const marker = "projects/";
    const start = std.mem.indexOf(u8, input, marker) orelse return false;
    var segments = std.mem.splitScalar(u8, input[start..], '/');
    return std.mem.eql(u8, segments.next() orelse return false, "projects") and
        std.mem.eql(u8, segments.next() orelse return false, project) and
        std.mem.eql(u8, segments.next() orelse return false, "global") and
        std.mem.eql(u8, segments.next() orelse return false, "networks") and
        (segments.next() orelse return false).len > 0 and segments.next() == null;
}

fn fqdnEqual(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, left, "."), std.mem.trimEnd(u8, right, "."));
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
