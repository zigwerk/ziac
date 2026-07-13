const std = @import("std");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;
const project_role_type = "gcp.iam.ProjectCustomRole";
const organization_role_type = "gcp.iam.OrganizationCustomRole";
const pool_type = "gcp.iam.WorkloadIdentityPool";
const pool_provider_type = "gcp.iam.WorkloadIdentityPoolProvider";
const role_update_mask = "title%2Cdescription%2CincludedPermissions%2Cstage";
const pool_update_mask = "displayName%2Cdescription%2Cdisabled";
const provider_update_mask = "displayName%2Cdescription%2Cdisabled%2CattributeMapping%2CattributeCondition%2Coidc";

pub const Handler = struct {
    client: *client_mod.Client,
    operation_policy: operation.Policy = .{},

    pub fn read(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_override: ?[]const u8,
    ) ProviderError!provider_mod.ReadResult {
        if (context.operation_handle) |handle| {
            if (try self.waitForResource(context, node, handle)) |result| return .{ .present = result };
        }
        const expected = try physicalIdAlloc(context, node);
        defer context.allocator.free(expected);
        const physical = physical_override orelse expected;
        if (!std.mem.eql(u8, expected, physical)) return error.InvalidConfiguration;
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .iam, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try resultFromJson(context, node, response.body, null) };
    }

    pub fn diff(
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        observed: *const provider_mod.ResourceResult,
    ) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash)) {
            return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        }
        const immutable = if (isRole(node))
            !sameInput(node.inputs, observed.observed_inputs, "resource_name")
        else if (isPool(node))
            !sameInput(node.inputs, observed.observed_inputs, "project_number") or !sameInput(node.inputs, observed.observed_inputs, "pool_id")
        else
            !sameInput(node.inputs, observed.observed_inputs, "pool") or !sameInput(node.inputs, observed.observed_inputs, "provider_id");
        return provider_mod.DiffResult.init(
            context.allocator,
            if (immutable) .replace else .update,
            &.{if (immutable) "IAM identity resource name changed" else "IAM identity configuration differs"},
        );
    }

    pub fn create(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        if (isRole(node)) return self.createRole(context, node);
        const path = try createPathAlloc(context, node);
        defer context.allocator.free(path);
        const body = try resourceBodyAlloc(context, node, null);
        defer context.allocator.free(body);
        const handle = self.startOperation(context, "POST", path, body) catch |err| {
            if (err != error.Conflict) return err;
            const undelete_path = try undeletePathAlloc(context, node);
            defer context.allocator.free(undelete_path);
            const recovered_handle = try self.startOperation(context, "POST", undelete_path, "{}");
            defer context.allocator.free(recovered_handle);
            return pendingResult(context, node, recovered_handle);
        };
        defer context.allocator.free(handle);
        return pendingResult(context, node, handle);
    }

    pub fn update(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        observed: *const provider_mod.ResourceResult,
    ) ProviderError!provider_mod.ResourceResult {
        if (isRole(node)) {
            const etag = outputString(observed, "etag") orelse return error.Conflict;
            const physical = try physicalIdAlloc(context, node);
            defer context.allocator.free(physical);
            const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}?updateMask={s}", .{ physical, role_update_mask });
            defer context.allocator.free(path);
            const body = try resourceBodyAlloc(context, node, etag);
            defer context.allocator.free(body);
            var response = try self.request(context, .{ .api = .iam, .method = "PATCH", .path = path, .body = body });
            defer response.deinit(context.allocator);
            return resultFromJson(context, node, response.body, null);
        }
        const physical = try physicalIdAlloc(context, node);
        defer context.allocator.free(physical);
        const mask = if (isPool(node)) pool_update_mask else provider_update_mask;
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}?updateMask={s}", .{ physical, mask });
        defer context.allocator.free(path);
        const body = try resourceBodyAlloc(context, node, null);
        defer context.allocator.free(body);
        const handle = try self.startOperation(context, "PATCH", path, body);
        defer context.allocator.free(handle);
        return pendingResult(context, node, handle);
    }

    pub fn delete(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!void {
        const expected = try physicalIdAlloc(context, node);
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical_id});
        defer context.allocator.free(path);
        if (isRole(node)) {
            var response = self.request(context, .{ .api = .iam, .method = "DELETE", .path = path }) catch |err| {
                if (err == error.NotFound) return;
                return err;
            };
            response.deinit(context.allocator);
            return;
        }
        const handle = self.startOperation(context, "DELETE", path, "") catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer context.allocator.free(handle);
        _ = try self.waitForResource(context, null, handle);
    }

    fn createRole(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        const path = try createPathAlloc(context, node);
        defer context.allocator.free(path);
        const body = try resourceBodyAlloc(context, node, null);
        defer context.allocator.free(body);
        var response = self.request(context, .{ .api = .iam, .method = "POST", .path = path, .body = body }) catch |err| {
            if (err != error.Conflict) return err;
            return self.restoreRole(context, node);
        };
        defer response.deinit(context.allocator);
        return resultFromJson(context, node, response.body, null);
    }

    fn restoreRole(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        const path = try undeletePathAlloc(context, node);
        defer context.allocator.free(path);
        var response = try self.request(context, .{ .api = .iam, .method = "POST", .path = path, .body = "{}" });
        defer response.deinit(context.allocator);
        var restored = try resultFromJson(context, node, response.body, null);
        defer restored.deinit();
        return self.update(context, node, &restored);
    }

    fn startOperation(
        self: Handler,
        context: *provider_mod.OperationContext,
        method: []const u8,
        path: []const u8,
        body: []const u8,
    ) ProviderError![]const u8 {
        var response = try self.request(context, .{ .api = .iam, .method = method, .path = path, .body = body });
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const root = jsonObject(parsed.value) orelse return error.ProviderBug;
        return context.allocator.dupe(u8, jsonString(root.get("name")) orelse return error.ProviderBug) catch error.OutOfMemory;
    }

    fn waitForResource(
        self: Handler,
        context: *provider_mod.OperationContext,
        maybe_node: ?resource.ResourceNode,
        handle: []const u8,
    ) ProviderError!?provider_mod.ResourceResult {
        const base = try std.fmt.allocPrint(context.allocator, "{s}/v1", .{std.mem.trimEnd(u8, self.client.endpoints.iam, "/")});
        defer context.allocator.free(base);
        var target = operation.Target.genericAlloc(context.allocator, base, handle) catch return error.OutOfMemory;
        defer target.deinit(context.allocator);
        var completed = try operation.waitAlloc(self.client, context, target, self.operation_policy);
        defer completed.deinit(context.allocator);
        const node = maybe_node orelse return null;
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, completed.payload, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const root = jsonObject(parsed.value) orelse return error.ProviderBug;
        const response_value = root.get("response") orelse return error.ProviderBug;
        const body = std.json.Stringify.valueAlloc(context.allocator, response_value, .{}) catch return error.OutOfMemory;
        defer context.allocator.free(body);
        var result = try resultFromJson(context, node, body, handle);
        if (!isRole(node) and !std.mem.eql(u8, &node.inputs_hash, &result.observed_hash)) {
            defer result.deinit();
            return try self.update(context, node, &result);
        }
        return result;
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
    return isRole(node) or isPool(node) or isPoolProvider(node);
}

fn isRole(node: resource.ResourceNode) bool {
    return std.mem.eql(u8, node.type_name, project_role_type) or std.mem.eql(u8, node.type_name, organization_role_type);
}

fn isPool(node: resource.ResourceNode) bool {
    return std.mem.eql(u8, node.type_name, pool_type);
}

fn isPoolProvider(node: resource.ResourceNode) bool {
    return std.mem.eql(u8, node.type_name, pool_provider_type);
}

fn createPathAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError![]const u8 {
    if (isRole(node)) {
        return std.fmt.allocPrint(
            context.allocator,
            "/v1/{s}/roles?roleId={s}",
            .{ try requiredString(node.inputs, "parent"), try requiredString(node.inputs, "role_id") },
        ) catch error.OutOfMemory;
    }
    if (isPool(node)) {
        return std.fmt.allocPrint(
            context.allocator,
            "/v1/projects/{s}/locations/global/workloadIdentityPools?workloadIdentityPoolId={s}",
            .{ try requiredString(node.inputs, "project_number"), try requiredString(node.inputs, "pool_id") },
        ) catch error.OutOfMemory;
    }
    const pool = try resolveString(context, try requiredValue(node.inputs, "pool"));
    return std.fmt.allocPrint(
        context.allocator,
        "/v1/{s}/providers?workloadIdentityPoolProviderId={s}",
        .{ pool, try requiredString(node.inputs, "provider_id") },
    ) catch error.OutOfMemory;
}

fn physicalIdAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError![]const u8 {
    if (isRole(node) or isPool(node)) return context.allocator.dupe(u8, try requiredString(node.inputs, "resource_name")) catch error.OutOfMemory;
    const pool = try resolveString(context, try requiredValue(node.inputs, "pool"));
    return std.fmt.allocPrint(context.allocator, "{s}/providers/{s}", .{ pool, try requiredString(node.inputs, "provider_id") }) catch error.OutOfMemory;
}

fn undeletePathAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError![]const u8 {
    const physical = try physicalIdAlloc(context, node);
    defer context.allocator.free(physical);
    return std.fmt.allocPrint(context.allocator, "/v1/{s}:undelete", .{physical}) catch error.OutOfMemory;
}

fn resourceBodyAlloc(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    etag: ?[]const u8,
) ProviderError![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root: std.json.ObjectMap = .empty;
    if (isRole(node)) {
        if (etag) |present| try root.put(arena, "etag", .{ .string = present });
        if (etag != null) try root.put(arena, "name", .{ .string = try requiredString(node.inputs, "resource_name") });
        try root.put(arena, "title", .{ .string = try requiredString(node.inputs, "title") });
        try root.put(arena, "description", .{ .string = try requiredString(node.inputs, "description") });
        try root.put(arena, "stage", .{ .string = try requiredString(node.inputs, "stage") });
        try root.put(arena, "includedPermissions", try stringListJson(arena, try requiredList(node.inputs, "included_permissions")));
    } else if (isPool(node)) {
        try root.put(arena, "name", .{ .string = try requiredString(node.inputs, "resource_name") });
        try root.put(arena, "displayName", .{ .string = try requiredString(node.inputs, "display_name") });
        try root.put(arena, "description", .{ .string = try requiredString(node.inputs, "description") });
        try root.put(arena, "disabled", .{ .bool = try requiredBool(node.inputs, "disabled") });
    } else {
        const physical = try physicalIdAlloc(context, node);
        defer context.allocator.free(physical);
        try root.put(arena, "name", .{ .string = physical });
        try root.put(arena, "displayName", .{ .string = try requiredString(node.inputs, "display_name") });
        try root.put(arena, "description", .{ .string = try requiredString(node.inputs, "description") });
        try root.put(arena, "disabled", .{ .bool = try requiredBool(node.inputs, "disabled") });
        try root.put(arena, "attributeCondition", .{ .string = try requiredString(node.inputs, "attribute_condition") });
        const mapping_json = try requiredString(node.inputs, "attribute_mapping_json");
        var mapping = std.json.parseFromSlice(std.json.Value, arena, mapping_json, .{}) catch return error.InvalidConfiguration;
        defer mapping.deinit();
        try root.put(arena, "attributeMapping", try cloneJsonValue(arena, mapping.value));
        var oidc: std.json.ObjectMap = .empty;
        try oidc.put(arena, "issuerUri", .{ .string = try requiredString(node.inputs, "issuer_uri") });
        try oidc.put(arena, "allowedAudiences", try stringListJson(arena, try requiredList(node.inputs, "allowed_audiences")));
        try root.put(arena, "oidc", .{ .object = oidc });
    }
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch error.OutOfMemory;
}

fn resultFromJson(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    body: []const u8,
    operation_handle: ?[]const u8,
) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const physical = jsonString(root.get("name")) orelse return error.ProviderBug;
    const expected = try physicalIdAlloc(context, node);
    defer context.allocator.free(expected);
    if (!std.mem.eql(u8, physical, expected)) return error.InvalidConfiguration;
    var observed = value.Value.initOwned(context.allocator, node.inputs) catch |err| return mapValueError(err);
    defer observed.deinit(context.allocator);
    if (isRole(node)) {
        try replaceString(&observed, context.allocator, "title", jsonString(root.get("title")) orelse "");
        try replaceString(&observed, context.allocator, "description", jsonString(root.get("description")) orelse "");
        try replaceString(&observed, context.allocator, "stage", jsonString(root.get("stage")) orelse "GA");
        try replaceJsonStringList(&observed, context.allocator, "included_permissions", root.get("includedPermissions"));
        const outputs = [_]state.StateOutput{
            .{ .name = "name", .value = .{ .string = physical } },
            .{ .name = "etag", .value = .{ .string = jsonString(root.get("etag")) orelse "" } },
        };
        return provider_mod.ResourceResult.init(context.allocator, physical, observed, &outputs, operation_handle);
    }
    try replaceString(&observed, context.allocator, "display_name", jsonString(root.get("displayName")) orelse "");
    try replaceString(&observed, context.allocator, "description", jsonString(root.get("description")) orelse "");
    try replaceBool(&observed, context.allocator, "disabled", jsonBool(root.get("disabled")) orelse false);
    if (isPoolProvider(node)) {
        try replaceString(&observed, context.allocator, "attribute_condition", jsonString(root.get("attributeCondition")) orelse "");
        if (root.get("attributeMapping")) |mapping| {
            const canonical = try canonicalStringMapJsonAlloc(context.allocator, mapping);
            defer context.allocator.free(canonical);
            try replaceString(&observed, context.allocator, "attribute_mapping_json", canonical);
        }
        if (root.get("oidc")) |oidc_value| {
            const oidc = jsonObject(oidc_value) orelse return error.ProviderBug;
            try replaceString(&observed, context.allocator, "issuer_uri", jsonString(oidc.get("issuerUri")) orelse "");
            try replaceJsonStringList(&observed, context.allocator, "allowed_audiences", oidc.get("allowedAudiences"));
        }
    }
    const outputs = [_]state.StateOutput{
        .{ .name = "name", .value = .{ .string = physical } },
        .{ .name = "state", .value = .{ .string = jsonString(root.get("state")) orelse "STATE_UNSPECIFIED" } },
    };
    return provider_mod.ResourceResult.init(context.allocator, physical, observed, &outputs, operation_handle);
}

fn pendingResult(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    handle: []const u8,
) ProviderError!provider_mod.ResourceResult {
    const physical = try physicalIdAlloc(context, node);
    defer context.allocator.free(physical);
    const outputs = [_]state.StateOutput{
        .{ .name = "name", .value = .{ .string = physical } },
        .{ .name = "state", .value = .{ .string = "PENDING" } },
    };
    var result = try provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &outputs, handle);
    result.completed = false;
    return result;
}

fn outputString(result: *const provider_mod.ResourceResult, name: []const u8) ?[]const u8 {
    for (result.outputs) |entry| if (std.mem.eql(u8, entry.name, name)) return switch (entry.value) {
        .string => |text| text,
        else => null,
    };
    return null;
}

fn sameInput(left: value.Value, right: value.Value, name: []const u8) bool {
    const a = requiredValue(left, name) catch return false;
    const b = requiredValue(right, name) catch return false;
    const a_json = a.canonicalJsonAlloc(std.heap.page_allocator) catch return false;
    defer std.heap.page_allocator.free(a_json);
    const b_json = b.canonicalJsonAlloc(std.heap.page_allocator) catch return false;
    defer std.heap.page_allocator.free(b_json);
    return std.mem.eql(u8, a_json, b_json);
}

fn stringListJson(allocator: std.mem.Allocator, items: []const value.Value) ProviderError!std.json.Value {
    var array = std.json.Array.init(allocator);
    for (items) |item| switch (item) {
        .string => |text| try array.append(.{ .string = text }),
        else => return error.InvalidConfiguration,
    };
    return .{ .array = array };
}

fn replaceString(target: *value.Value, allocator: std.mem.Allocator, name: []const u8, text: []const u8) ProviderError!void {
    return replaceInput(target, allocator, name, .{ .string = text });
}

fn replaceBool(target: *value.Value, allocator: std.mem.Allocator, name: []const u8, present: bool) ProviderError!void {
    return replaceInput(target, allocator, name, .{ .boolean = present });
}

fn replaceJsonStringList(
    target: *value.Value,
    allocator: std.mem.Allocator,
    name: []const u8,
    maybe_json: ?std.json.Value,
) ProviderError!void {
    const array = if (maybe_json) |json| jsonArray(json) orelse return error.ProviderBug else std.json.Array.init(allocator);
    const temporary = try allocator.alloc(value.Value, array.items.len);
    defer allocator.free(temporary);
    for (array.items, 0..) |item, index| temporary[index] = .{ .string = jsonString(item) orelse return error.ProviderBug };
    std.mem.sort(value.Value, temporary, {}, lessThanValueString);
    return replaceInput(target, allocator, name, .{ .list = temporary });
}

fn replaceInput(target: *value.Value, allocator: std.mem.Allocator, name: []const u8, replacement: value.Value) ProviderError!void {
    const fields = switch (target.*) {
        .object => |items| @constCast(items),
        else => return error.ProviderBug,
    };
    for (fields) |*field| {
        if (!std.mem.eql(u8, field.name, name)) continue;
        field.value.deinit(allocator);
        field.value = value.Value.initOwned(allocator, replacement) catch |err| return mapValueError(err);
        return;
    }
    return error.ProviderBug;
}

fn canonicalStringMapJsonAlloc(allocator: std.mem.Allocator, source: std.json.Value) ProviderError![]const u8 {
    const object = jsonObject(source) orelse return error.ProviderBug;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entries = try arena.alloc(MapEntry, object.count());
    var iterator = object.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| : (index += 1) entries[index] = .{
        .key = entry.key_ptr.*,
        .value = jsonString(entry.value_ptr.*) orelse return error.ProviderBug,
    };
    std.mem.sort(MapEntry, entries, {}, lessThanMapEntry);
    var normalized: std.json.ObjectMap = .empty;
    for (entries) |entry| try normalized.put(arena, entry.key, .{ .string = entry.value });
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = normalized }, .{}) catch error.OutOfMemory;
}

const MapEntry = struct { key: []const u8, value: []const u8 };

fn lessThanMapEntry(_: void, left: MapEntry, right: MapEntry) bool {
    return std.mem.lessThan(u8, left.key, right.key);
}

fn requiredValue(input: value.Value, name: []const u8) ProviderError!value.Value {
    if (input != .object) return error.InvalidConfiguration;
    for (input.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return error.InvalidConfiguration;
}

fn requiredString(input: value.Value, name: []const u8) ProviderError![]const u8 {
    return switch (try requiredValue(input, name)) {
        .string => |text| text,
        else => error.InvalidConfiguration,
    };
}

fn requiredList(input: value.Value, name: []const u8) ProviderError![]const value.Value {
    return switch (try requiredValue(input, name)) {
        .list => |items| items,
        else => error.InvalidConfiguration,
    };
}

fn requiredBool(input: value.Value, name: []const u8) ProviderError!bool {
    return switch (try requiredValue(input, name)) {
        .boolean => |present| present,
        else => error.InvalidConfiguration,
    };
}

fn resolveString(context: *provider_mod.OperationContext, input: value.Value) ProviderError![]const u8 {
    return switch (input) {
        .string => |text| text,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}

fn mapValueError(err: value.ValueError) ProviderError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateField => error.ProviderBug,
    };
}

fn cloneJsonValue(allocator: std.mem.Allocator, source: std.json.Value) ProviderError!std.json.Value {
    return switch (source) {
        .null => .null,
        .bool => |inner| .{ .bool = inner },
        .integer => |inner| .{ .integer = inner },
        .float => |inner| .{ .float = inner },
        .number_string => |inner| .{ .number_string = try allocator.dupe(u8, inner) },
        .string => |inner| .{ .string = try allocator.dupe(u8, inner) },
        .array => |inner| blk: {
            var array = std.json.Array.init(allocator);
            for (inner.items) |item| try array.append(try cloneJsonValue(allocator, item));
            break :blk .{ .array = array };
        },
        .object => |inner| blk: {
            var object: std.json.ObjectMap = .empty;
            var iterator = inner.iterator();
            while (iterator.next()) |entry| try object.put(
                allocator,
                try allocator.dupe(u8, entry.key_ptr.*),
                try cloneJsonValue(allocator, entry.value_ptr.*),
            );
            break :blk .{ .object = object };
        },
    };
}

fn jsonObject(input: std.json.Value) ?std.json.ObjectMap {
    return switch (input) {
        .object => |object| object,
        else => null,
    };
}

fn jsonArray(input: std.json.Value) ?std.json.Array {
    return switch (input) {
        .array => |array| array,
        else => null,
    };
}

fn jsonString(input: ?std.json.Value) ?[]const u8 {
    if (input == null) return null;
    return switch (input.?) {
        .string => |text| text,
        else => null,
    };
}

fn jsonBool(input: ?std.json.Value) ?bool {
    if (input == null) return null;
    return switch (input.?) {
        .bool => |present| present,
        else => null,
    };
}

fn lessThanValueString(_: void, left: value.Value, right: value.Value) bool {
    return std.mem.lessThan(u8, left.string, right.string);
}
