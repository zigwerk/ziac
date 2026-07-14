const std = @import("std");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;

const Kind = enum {
    policy,
    custom_constraint,
    tag_key,
    tag_value,
    tag_binding,
    tag_hold,
    access_policy,
    access_level,
    service_perimeter,
    user_access_binding,
};

pub const Handler = struct {
    client: *client_mod.Client,
    operation_policy: operation.Policy = .{},

    pub fn supports(node: resource.ResourceNode) bool {
        return kindOf(node) != null;
    }

    pub fn read(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (context.operation_handle) |handle| {
            const payload = try self.waitOperationAlloc(context, kind, handle);
            defer context.allocator.free(payload);
            const response = try operationResponseAlloc(context.allocator, payload);
            defer context.allocator.free(response);
            return .{ .present = try resultFromJson(context, node, kind, response) };
        }

        const physical = try physicalForReadAlloc(context, node, kind, physical_override);
        defer if (physical) |owned| context.allocator.free(owned);
        if (requiresListRead(kind) or physical == null) return self.readFromList(context, node, kind, physical);
        try validatePhysical(kind, physical.?);
        const path = try readPathAlloc(context.allocator, kind, physical.?);
        defer context.allocator.free(path);
        var response = self.request(context, apiFor(kind), "GET", path, "") catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try resultFromJson(context, node, kind, response.body) };
    }

    pub fn diff(context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(kind, observed.physical_id);
        const remote_json = outputString(observed.*, "__remote_spec") orelse return error.ProviderBug;
        var remote = std.json.parseFromSlice(std.json.Value, context.allocator, remote_json, .{}) catch return error.ProviderBug;
        defer remote.deinit();
        const remote_root = jsonObject(remote.value) orelse return error.ProviderBug;
        const desired_body = try bodyAlloc(context, node, kind, null);
        defer context.allocator.free(desired_body);
        var desired = std.json.parseFromSlice(std.json.Value, context.allocator, desired_body, .{}) catch return error.ProviderBug;
        defer desired.deinit();
        const desired_root = jsonObject(desired.value) orelse return error.ProviderBug;
        if (jsonContains(desired_root, remote_root)) return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        if (immutableChanged(kind, desired_root, remote_root)) return provider_mod.DiffResult.init(context.allocator, .replace, &.{"immutable governance identity differs"});
        return provider_mod.DiffResult.init(context.allocator, .update, &.{"governance configuration differs"});
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        const path = try createPathAlloc(context, node, kind);
        defer context.allocator.free(path);
        const body = try bodyAlloc(context, node, kind, null);
        defer context.allocator.free(body);
        var response = try self.request(context, apiFor(kind), "POST", path, body);
        defer response.deinit(context.allocator);
        return if (isLongRunning(kind))
            pendingResult(context, node, kind, response.body)
        else
            resultFromJson(context, node, kind, response.body);
    }

    pub fn update(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(kind, observed.physical_id);
        if (kind == .tag_binding or kind == .tag_hold) return error.InvalidConfiguration;
        const remote_json = outputString(observed.*, "__remote_spec") orelse return error.ProviderBug;
        const etag = try etagFromRemoteAlloc(context.allocator, kind, remote_json);
        defer if (etag) |owned| context.allocator.free(owned);
        const body = try bodyAlloc(context, node, kind, .{ .physical = observed.physical_id, .etag = etag orelse "" });
        defer context.allocator.free(body);
        const path = try updatePathAlloc(context.allocator, kind, observed.physical_id);
        defer context.allocator.free(path);
        var response = try self.request(context, apiFor(kind), "PATCH", path, body);
        defer response.deinit(context.allocator);
        return if (isLongRunning(kind))
            pendingResultWithPhysical(context, node, kind, observed.physical_id, response.body)
        else
            resultFromJson(context, node, kind, response.body);
    }

    pub fn delete(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical: []const u8) ProviderError!void {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(kind, physical);
        if (!try deletionRequested(node, kind) or !context.destructive_confirmation) return error.DestructiveConfirmationRequired;
        const path = try deletePathAlloc(context.allocator, kind, physical);
        defer context.allocator.free(path);
        var response = self.request(context, apiFor(kind), "DELETE", path, "") catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer response.deinit(context.allocator);
        if (!isLongRunning(kind)) return;
        const handle = try operationNameAlloc(context.allocator, response.body);
        defer context.allocator.free(handle);
        const payload = try self.waitOperationAlloc(context, kind, handle);
        context.allocator.free(payload);
    }

    pub fn importResource(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical: []const u8) ProviderError!provider_mod.ResourceResult {
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(kind, physical);
        var found = try self.read(context, node, physical);
        defer found.deinit();
        return switch (found) {
            .absent => error.NotFound,
            .present => |present| present.clone(context.allocator),
        };
    }

    fn readFromList(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, physical: ?[]const u8) ProviderError!provider_mod.ReadResult {
        const path = try listPathAlloc(context, node, kind);
        defer context.allocator.free(path);
        var response = self.request(context, apiFor(kind), "GET", path, "") catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const root = jsonObject(parsed.value) orelse return error.ProviderBug;
        const list_value = root.get(listField(kind)) orelse return .absent;
        const items = jsonArray(list_value) orelse return error.ProviderBug;
        for (items.items) |candidate| {
            const object = jsonObject(candidate) orelse continue;
            const name = jsonString(object.get("name")) orelse continue;
            if (physical) |wanted| {
                if (!std.mem.eql(u8, name, wanted)) continue;
            } else if (!try remoteMatches(context, node, kind, object)) continue;
            const body = std.json.Stringify.valueAlloc(context.allocator, candidate, .{}) catch return error.OutOfMemory;
            defer context.allocator.free(body);
            return .{ .present = try resultFromJson(context, node, kind, body) };
        }
        return .absent;
    }

    fn waitOperationAlloc(self: Handler, context: *provider_mod.OperationContext, kind: Kind, handle: []const u8) ProviderError![]const u8 {
        const endpoint = self.client.endpoints.get(apiFor(kind));
        const version = if (isTag(kind)) "v3" else "v1";
        const base = try std.fmt.allocPrint(context.allocator, "{s}/{s}", .{ std.mem.trimEnd(u8, endpoint, "/"), version });
        defer context.allocator.free(base);
        var target = operation.Target.genericAlloc(context.allocator, base, handle) catch return error.OutOfMemory;
        defer target.deinit(context.allocator);
        var completed = try operation.waitAlloc(self.client, context, target, self.operation_policy);
        defer completed.deinit(context.allocator);
        return context.allocator.dupe(u8, completed.payload) catch error.OutOfMemory;
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, api: client_mod.Api, method: []const u8, path: []const u8, body: []const u8) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, .{ .api = api, .method = method, .path = path, .body = body }, &diagnostic);
    }
};

const UpdateMetadata = struct { physical: []const u8, etag: []const u8 };

fn kindOf(node: resource.ResourceNode) ?Kind {
    const mappings = [_]struct { []const u8, Kind }{
        .{ "gcp.orgpolicy.Policy", .policy },
        .{ "gcp.orgpolicy.CustomConstraint", .custom_constraint },
        .{ "gcp.tags.TagKey", .tag_key },
        .{ "gcp.tags.TagValue", .tag_value },
        .{ "gcp.tags.TagBinding", .tag_binding },
        .{ "gcp.tags.TagHold", .tag_hold },
        .{ "gcp.accesscontextmanager.AccessPolicy", .access_policy },
        .{ "gcp.accesscontextmanager.AccessLevel", .access_level },
        .{ "gcp.accesscontextmanager.ServicePerimeter", .service_perimeter },
        .{ "gcp.accesscontextmanager.GcpUserAccessBinding", .user_access_binding },
    };
    for (mappings) |mapping| if (std.mem.eql(u8, node.type_name, mapping[0])) return mapping[1];
    return null;
}

fn apiFor(kind: Kind) client_mod.Api {
    return switch (kind) {
        .policy, .custom_constraint => .organization_policy,
        .tag_key, .tag_value, .tag_binding, .tag_hold => .resource_manager,
        .access_policy, .access_level, .service_perimeter, .user_access_binding => .access_context_manager,
    };
}

fn isTag(kind: Kind) bool {
    return switch (kind) {
        .tag_key, .tag_value, .tag_binding, .tag_hold => true,
        else => false,
    };
}

fn isLongRunning(kind: Kind) bool {
    return switch (kind) {
        .policy, .custom_constraint => false,
        else => true,
    };
}

fn requiresListRead(kind: Kind) bool {
    return kind == .tag_binding or kind == .tag_hold;
}

fn physicalForReadAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, override: ?[]const u8) ProviderError!?[]const u8 {
    if (override orelse context.physical_id) |physical| return context.allocator.dupe(u8, physical) catch error.OutOfMemory;
    return switch (kind) {
        .policy => std.fmt.allocPrint(context.allocator, "{s}/policies/{s}", .{ try requiredString(context, node.inputs, "parent"), try requiredLiteralString(node.inputs, "constraint") }) catch error.OutOfMemory,
        .custom_constraint => std.fmt.allocPrint(context.allocator, "{s}/customConstraints/{s}", .{ try requiredString(context, node.inputs, "organization"), try requiredLiteralString(node.inputs, "constraint_id") }) catch error.OutOfMemory,
        .access_level => std.fmt.allocPrint(context.allocator, "{s}/accessLevels/{s}", .{ try requiredString(context, node.inputs, "policy"), node.logical_id }) catch error.OutOfMemory,
        .service_perimeter => std.fmt.allocPrint(context.allocator, "{s}/servicePerimeters/{s}", .{ try requiredString(context, node.inputs, "policy"), node.logical_id }) catch error.OutOfMemory,
        .tag_key, .tag_value, .tag_binding, .tag_hold, .access_policy, .user_access_binding => null,
    };
}

fn validatePhysical(kind: Kind, physical: []const u8) ProviderError!void {
    if (physical.len == 0 or std.mem.indexOfAny(u8, physical, "?# \t\r\n") != null) return error.InvalidConfiguration;
    const valid = switch (kind) {
        .policy => containsCanonical(physical, "/policies/"),
        .custom_constraint => containsCanonical(physical, "/customConstraints/custom."),
        .tag_key => numericName(physical, "tagKeys/"),
        .tag_value => numericName(physical, "tagValues/"),
        .tag_binding => std.mem.startsWith(u8, physical, "tagBindings/"),
        .tag_hold => std.mem.startsWith(u8, physical, "tagValues/") and std.mem.indexOf(u8, physical, "/tagHolds/") != null,
        .access_policy => numericName(physical, "accessPolicies/"),
        .access_level => std.mem.startsWith(u8, physical, "accessPolicies/") and std.mem.indexOf(u8, physical, "/accessLevels/") != null,
        .service_perimeter => std.mem.startsWith(u8, physical, "accessPolicies/") and std.mem.indexOf(u8, physical, "/servicePerimeters/") != null,
        .user_access_binding => std.mem.startsWith(u8, physical, "organizations/") and std.mem.indexOf(u8, physical, "/gcpUserAccessBindings/") != null,
    };
    if (!valid) return error.InvalidConfiguration;
}

fn readPathAlloc(allocator: std.mem.Allocator, kind: Kind, physical: []const u8) ProviderError![]const u8 {
    const version = if (kind == .policy or kind == .custom_constraint) "v2" else if (isTag(kind)) "v3" else "v1";
    return std.fmt.allocPrint(allocator, "/{s}/{s}", .{ version, physical }) catch error.OutOfMemory;
}

fn createPathAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    return switch (kind) {
        .policy => std.fmt.allocPrint(context.allocator, "/v2/{s}/policies", .{try requiredString(context, node.inputs, "parent")}) catch error.OutOfMemory,
        .custom_constraint => std.fmt.allocPrint(context.allocator, "/v2/{s}/customConstraints", .{try requiredString(context, node.inputs, "organization")}) catch error.OutOfMemory,
        .tag_key => context.allocator.dupe(u8, "/v3/tagKeys") catch error.OutOfMemory,
        .tag_value => context.allocator.dupe(u8, "/v3/tagValues") catch error.OutOfMemory,
        .tag_binding => context.allocator.dupe(u8, "/v3/tagBindings") catch error.OutOfMemory,
        .tag_hold => std.fmt.allocPrint(context.allocator, "/v3/{s}/tagHolds", .{try requiredString(context, node.inputs, "parent")}) catch error.OutOfMemory,
        .access_policy => context.allocator.dupe(u8, "/v1/accessPolicies") catch error.OutOfMemory,
        .access_level => std.fmt.allocPrint(context.allocator, "/v1/{s}/accessLevels", .{try requiredString(context, node.inputs, "policy")}) catch error.OutOfMemory,
        .service_perimeter => std.fmt.allocPrint(context.allocator, "/v1/{s}/servicePerimeters", .{try requiredString(context, node.inputs, "policy")}) catch error.OutOfMemory,
        .user_access_binding => std.fmt.allocPrint(context.allocator, "/v1/{s}/gcpUserAccessBindings", .{try requiredString(context, node.inputs, "organization")}) catch error.OutOfMemory,
    };
}

fn updatePathAlloc(allocator: std.mem.Allocator, kind: Kind, physical: []const u8) ProviderError![]const u8 {
    const mask = switch (kind) {
        .policy => "spec%2CdryRunSpec",
        .custom_constraint => "displayName%2Cdescription%2CactionType%2Ccondition%2CmethodTypes",
        .tag_key, .tag_value => "description",
        .access_policy => "title",
        .access_level => "title%2Cdescription%2Cbasic%2Ccustom",
        .service_perimeter => "title%2Cdescription%2CperimeterType%2Cstatus%2Cspec%2CuseExplicitDryRunSpec",
        .user_access_binding => "accessLevels%2CdryRunAccessLevels",
        .tag_binding, .tag_hold => return error.InvalidConfiguration,
    };
    const version = if (kind == .policy or kind == .custom_constraint) "v2" else if (isTag(kind)) "v3" else "v1";
    return std.fmt.allocPrint(allocator, "/{s}/{s}?updateMask={s}", .{ version, physical, mask }) catch error.OutOfMemory;
}

fn deletePathAlloc(allocator: std.mem.Allocator, kind: Kind, physical: []const u8) ProviderError![]const u8 {
    return readPathAlloc(allocator, kind, physical);
}

fn listPathAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    const parent_field = switch (kind) {
        .tag_key, .tag_binding, .tag_hold => "parent",
        .tag_value => "parent",
        .access_policy => "parent",
        .user_access_binding => "organization",
        else => return error.InvalidConfiguration,
    };
    const parent = try requiredString(context, node.inputs, parent_field);
    const encoded = try percentEncodeAlloc(context.allocator, parent);
    defer context.allocator.free(encoded);
    return switch (kind) {
        .tag_key => std.fmt.allocPrint(context.allocator, "/v3/tagKeys?parent={s}", .{encoded}) catch error.OutOfMemory,
        .tag_value => std.fmt.allocPrint(context.allocator, "/v3/tagValues?parent={s}", .{encoded}) catch error.OutOfMemory,
        .tag_binding => std.fmt.allocPrint(context.allocator, "/v3/tagBindings?parent={s}", .{encoded}) catch error.OutOfMemory,
        .tag_hold => std.fmt.allocPrint(context.allocator, "/v3/{s}/tagHolds", .{parent}) catch error.OutOfMemory,
        .access_policy => std.fmt.allocPrint(context.allocator, "/v1/accessPolicies?parent={s}", .{encoded}) catch error.OutOfMemory,
        .user_access_binding => std.fmt.allocPrint(context.allocator, "/v1/{s}/gcpUserAccessBindings", .{parent}) catch error.OutOfMemory,
        else => error.InvalidConfiguration,
    };
}

fn listField(kind: Kind) []const u8 {
    return switch (kind) {
        .tag_key => "tagKeys",
        .tag_value => "tagValues",
        .tag_binding => "tagBindings",
        .tag_hold => "tagHolds",
        .access_policy => "accessPolicies",
        .user_access_binding => "gcpUserAccessBindings",
        else => "",
    };
}

fn bodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, update: ?UpdateMetadata) ProviderError![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = std.json.ObjectMap.empty;
    if (update) |metadata| {
        try root.put(arena, "name", .{ .string = metadata.physical });
        if (metadata.etag.len != 0 and kind != .policy) try root.put(arena, "etag", .{ .string = metadata.etag });
    }
    switch (kind) {
        .policy => try policyBody(context, arena, node, update, &root),
        .custom_constraint => try customConstraintBody(context, arena, node, &root),
        .tag_key => try tagKeyBody(context, arena, node, &root),
        .tag_value => try tagValueBody(context, arena, node, &root),
        .tag_binding => {
            try root.put(arena, "parent", .{ .string = try requiredString(context, node.inputs, "parent") });
            try root.put(arena, "tagValue", .{ .string = try requiredString(context, node.inputs, "tag_value") });
        },
        .tag_hold => {
            try root.put(arena, "holder", .{ .string = try requiredLiteralString(node.inputs, "holder") });
            try putOptionalString(arena, &root, "origin", try requiredLiteralString(node.inputs, "origin"));
            try putOptionalString(arena, &root, "helpLink", try requiredLiteralString(node.inputs, "help_link"));
        },
        .access_policy => try accessPolicyBody(context, arena, node, &root),
        .access_level => try accessLevelBody(context, arena, node, &root),
        .service_perimeter => try servicePerimeterBody(context, arena, node, &root),
        .user_access_binding => try userAccessBindingBody(context, arena, node, &root),
    }
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch error.OutOfMemory;
}

fn policyBody(context: *provider_mod.OperationContext, arena: std.mem.Allocator, node: resource.ResourceNode, update: ?UpdateMetadata, root: *std.json.ObjectMap) ProviderError!void {
    if (update == null) {
        const name = try std.fmt.allocPrint(arena, "{s}/policies/{s}", .{ try requiredString(context, node.inputs, "parent"), try requiredLiteralString(node.inputs, "constraint") });
        try root.put(arena, "name", .{ .string = name });
    }
    var spec = try policySpecJson(context, arena, try requiredValue(node.inputs, "spec"));
    if (update) |metadata| if (metadata.etag.len != 0) try spec.object.put(arena, "etag", .{ .string = metadata.etag });
    try root.put(arena, "spec", spec);
    if (try requiredBoolean(node.inputs, "has_dry_run_spec")) {
        try root.put(arena, "dryRunSpec", try policySpecJson(context, arena, try requiredValue(node.inputs, "dry_run_spec")));
    }
}

fn policySpecJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    const fields = valueObject(source) orelse return error.InvalidConfiguration;
    var result = std.json.ObjectMap.empty;
    try result.put(arena, "inheritFromParent", .{ .bool = try requiredObjectBoolean(fields, "inherit_from_parent") });
    try result.put(arena, "reset", .{ .bool = try requiredObjectBoolean(fields, "reset") });
    var rules = std.json.Array.init(arena);
    const source_rules = valueList(try requiredObjectValue(fields, "rules")) orelse return error.InvalidConfiguration;
    for (source_rules) |rule_value| {
        const rule_fields = valueObject(rule_value) orelse return error.InvalidConfiguration;
        var rule = std.json.ObjectMap.empty;
        const condition = try requiredObjectString(rule_fields, "condition");
        if (condition.len != 0) {
            var expr = std.json.ObjectMap.empty;
            try expr.put(arena, "expression", .{ .string = condition });
            try rule.put(arena, "condition", .{ .object = expr });
        }
        const effect = valueObject(try requiredObjectValue(rule_fields, "effect")) orelse return error.InvalidConfiguration;
        if (objectField(effect, "enforce")) |selected| try rule.put(arena, "enforce", try resolvedValueJson(context, arena, selected));
        if (objectField(effect, "allow_all")) |selected| try rule.put(arena, "allowAll", try resolvedValueJson(context, arena, selected));
        if (objectField(effect, "deny_all")) |selected| try rule.put(arena, "denyAll", try resolvedValueJson(context, arena, selected));
        if (objectField(effect, "values")) |selected| {
            const values = valueObject(selected) orelse return error.InvalidConfiguration;
            var api_values = std.json.ObjectMap.empty;
            try api_values.put(arena, "allowedValues", try resolvedValueJson(context, arena, try requiredObjectValue(values, "allowed")));
            try api_values.put(arena, "deniedValues", try resolvedValueJson(context, arena, try requiredObjectValue(values, "denied")));
            try rule.put(arena, "values", .{ .object = api_values });
        }
        const parameters = try requiredObjectValue(rule_fields, "parameters");
        if (!valueIsEmptyObject(parameters)) try rule.put(arena, "parameters", try resolvedValueJson(context, arena, parameters));
        try rules.append(.{ .object = rule });
    }
    try result.put(arena, "rules", .{ .array = rules });
    return .{ .object = result };
}

fn customConstraintBody(context: *provider_mod.OperationContext, arena: std.mem.Allocator, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    const name = try std.fmt.allocPrint(arena, "{s}/customConstraints/{s}", .{ try requiredString(context, node.inputs, "organization"), try requiredLiteralString(node.inputs, "constraint_id") });
    if (root.get("name") == null) try root.put(arena, "name", .{ .string = name });
    try root.put(arena, "resourceTypes", try resolvedValueJson(context, arena, try requiredValue(node.inputs, "resource_types")));
    try root.put(arena, "methodTypes", try resolvedValueJson(context, arena, try requiredValue(node.inputs, "method_types")));
    try root.put(arena, "condition", .{ .string = try requiredLiteralString(node.inputs, "condition") });
    try root.put(arena, "actionType", .{ .string = try requiredLiteralString(node.inputs, "action") });
    try root.put(arena, "displayName", .{ .string = try requiredLiteralString(node.inputs, "display_name") });
    try putOptionalString(arena, root, "description", try requiredLiteralString(node.inputs, "description"));
}

fn tagKeyBody(context: *provider_mod.OperationContext, arena: std.mem.Allocator, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    try root.put(arena, "parent", .{ .string = try requiredString(context, node.inputs, "parent") });
    try root.put(arena, "shortName", .{ .string = try requiredLiteralString(node.inputs, "short_name") });
    try putOptionalString(arena, root, "description", try requiredLiteralString(node.inputs, "description"));
    const purpose = try requiredLiteralString(node.inputs, "purpose");
    if (!std.mem.eql(u8, purpose, "PURPOSE_UNSPECIFIED")) try root.put(arena, "purpose", .{ .string = purpose });
    const purpose_data = try requiredValue(node.inputs, "purpose_data");
    if (!valueIsEmptyObject(purpose_data)) try root.put(arena, "purposeData", try resolvedValueJson(context, arena, purpose_data));
    try putOptionalString(arena, root, "allowedValuesRegex", try requiredLiteralString(node.inputs, "allowed_values_regex"));
}

fn tagValueBody(context: *provider_mod.OperationContext, arena: std.mem.Allocator, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    try root.put(arena, "parent", .{ .string = try requiredString(context, node.inputs, "parent") });
    try root.put(arena, "shortName", .{ .string = try requiredLiteralString(node.inputs, "short_name") });
    try putOptionalString(arena, root, "description", try requiredLiteralString(node.inputs, "description"));
}

fn accessPolicyBody(context: *provider_mod.OperationContext, arena: std.mem.Allocator, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    try root.put(arena, "parent", .{ .string = try requiredString(context, node.inputs, "parent") });
    try root.put(arena, "title", .{ .string = try requiredLiteralString(node.inputs, "title") });
    const scope = try requiredString(context, node.inputs, "scope");
    if (scope.len != 0) {
        var scopes = std.json.Array.init(arena);
        try scopes.append(.{ .string = scope });
        try root.put(arena, "scopes", .{ .array = scopes });
    }
}

fn accessLevelBody(context: *provider_mod.OperationContext, arena: std.mem.Allocator, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    if (root.get("name") == null) {
        const name = try std.fmt.allocPrint(arena, "{s}/accessLevels/{s}", .{ try requiredString(context, node.inputs, "policy"), node.logical_id });
        try root.put(arena, "name", .{ .string = name });
    }
    try root.put(arena, "title", .{ .string = try requiredLiteralString(node.inputs, "title") });
    try putOptionalString(arena, root, "description", try requiredLiteralString(node.inputs, "description"));
    const level = valueObject(try requiredValue(node.inputs, "level")) orelse return error.InvalidConfiguration;
    if (objectField(level, "custom")) |custom| {
        var expression = std.json.ObjectMap.empty;
        try expression.put(arena, "expr", .{ .string = valueString(custom) orelse return error.InvalidConfiguration });
        try root.put(arena, "custom", .{ .object = expression });
    } else if (objectField(level, "basic")) |basic| {
        try root.put(arena, "basic", try basicAccessLevelJson(context, arena, basic));
    } else return error.InvalidConfiguration;
}

fn basicAccessLevelJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    const fields = valueObject(source) orelse return error.InvalidConfiguration;
    var result = std.json.ObjectMap.empty;
    try result.put(arena, "combiningFunction", .{ .string = try requiredObjectString(fields, "combining_function") });
    var conditions = std.json.Array.init(arena);
    for (valueList(try requiredObjectValue(fields, "conditions")) orelse return error.InvalidConfiguration) |condition_value| {
        const condition = valueObject(condition_value) orelse return error.InvalidConfiguration;
        var api = std.json.ObjectMap.empty;
        try copyValueField(context, arena, &api, condition, "ip_subnetworks", "ipSubnetworks", false);
        try copyValueField(context, arena, &api, condition, "members", "members", false);
        try copyValueField(context, arena, &api, condition, "regions", "regions", false);
        try copyValueField(context, arena, &api, condition, "required_access_levels", "requiredAccessLevels", false);
        if (try requiredObjectBoolean(condition, "negate")) try api.put(arena, "negate", .{ .bool = true });
        try conditions.append(.{ .object = api });
    }
    try result.put(arena, "conditions", .{ .array = conditions });
    return .{ .object = result };
}

fn servicePerimeterBody(context: *provider_mod.OperationContext, arena: std.mem.Allocator, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    if (root.get("name") == null) {
        const name = try std.fmt.allocPrint(arena, "{s}/servicePerimeters/{s}", .{ try requiredString(context, node.inputs, "policy"), node.logical_id });
        try root.put(arena, "name", .{ .string = name });
    }
    try root.put(arena, "title", .{ .string = try requiredLiteralString(node.inputs, "title") });
    try putOptionalString(arena, root, "description", try requiredLiteralString(node.inputs, "description"));
    try root.put(arena, "perimeterType", .{ .string = try requiredLiteralString(node.inputs, "perimeter_type") });
    try root.put(arena, "status", try perimeterConfigJson(context, arena, try requiredValue(node.inputs, "status")));
    const has_dry_run = try requiredBoolean(node.inputs, "has_dry_run");
    try root.put(arena, "useExplicitDryRunSpec", .{ .bool = has_dry_run });
    if (has_dry_run) try root.put(arena, "spec", try perimeterConfigJson(context, arena, try requiredValue(node.inputs, "dry_run")));
}

fn perimeterConfigJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    const fields = valueObject(source) orelse return error.InvalidConfiguration;
    var result = std.json.ObjectMap.empty;
    try copyValueField(context, arena, &result, fields, "resources", "resources", false);
    try copyValueField(context, arena, &result, fields, "restricted_services", "restrictedServices", false);
    try copyValueField(context, arena, &result, fields, "access_levels", "accessLevels", false);
    const ingress_values = valueList(try requiredObjectValue(fields, "ingress_policies")) orelse return error.InvalidConfiguration;
    if (ingress_values.len != 0) {
        var ingress = std.json.Array.init(arena);
        for (ingress_values) |item| try ingress.append(try ingressPolicyJson(context, arena, item));
        try result.put(arena, "ingressPolicies", .{ .array = ingress });
    }
    const egress_values = valueList(try requiredObjectValue(fields, "egress_policies")) orelse return error.InvalidConfiguration;
    if (egress_values.len != 0) {
        var egress = std.json.Array.init(arena);
        for (egress_values) |item| try egress.append(try egressPolicyJson(context, arena, item));
        try result.put(arena, "egressPolicies", .{ .array = egress });
    }
    const vpc = valueObject(try requiredObjectValue(fields, "vpc_accessible_services")) orelse return error.InvalidConfiguration;
    if (try requiredObjectBoolean(vpc, "enabled")) {
        var api_vpc = std.json.ObjectMap.empty;
        try api_vpc.put(arena, "enableRestriction", .{ .bool = true });
        try copyValueField(context, arena, &api_vpc, vpc, "allowed_services", "allowedServices", false);
        try result.put(arena, "vpcAccessibleServices", .{ .object = api_vpc });
    }
    return .{ .object = result };
}

fn ingressPolicyJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    const fields = valueObject(source) orelse return error.InvalidConfiguration;
    var result = std.json.ObjectMap.empty;
    var from = std.json.ObjectMap.empty;
    try copyValueField(context, arena, &from, fields, "source_resources", "resources", false);
    try copyValueField(context, arena, &from, fields, "source_access_levels", "accessLevels", false);
    try copyValueField(context, arena, &from, fields, "identities", "identities", false);
    try putIdentityType(arena, &from, try requiredObjectString(fields, "identity_type"));
    if (from.count() != 0) try result.put(arena, "ingressFrom", .{ .object = from });
    var to = std.json.ObjectMap.empty;
    try copyValueField(context, arena, &to, fields, "target_resources", "resources", false);
    try operationsJson(context, arena, &to, fields);
    try copyValueField(context, arena, &to, fields, "roles", "roles", false);
    if (to.count() != 0) try result.put(arena, "ingressTo", .{ .object = to });
    return .{ .object = result };
}

fn egressPolicyJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    const fields = valueObject(source) orelse return error.InvalidConfiguration;
    var result = std.json.ObjectMap.empty;
    var from = std.json.ObjectMap.empty;
    try copyValueField(context, arena, &from, fields, "identities", "identities", false);
    try putIdentityType(arena, &from, try requiredObjectString(fields, "identity_type"));
    if (from.count() != 0) try result.put(arena, "egressFrom", .{ .object = from });
    var to = std.json.ObjectMap.empty;
    try copyValueField(context, arena, &to, fields, "target_resources", "resources", false);
    try operationsJson(context, arena, &to, fields);
    if (to.count() != 0) try result.put(arena, "egressTo", .{ .object = to });
    return .{ .object = result };
}

fn operationsJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, target: *std.json.ObjectMap, fields: []const value.Field) ProviderError!void {
    const operations = valueList(try requiredObjectValue(fields, "operations")) orelse return error.InvalidConfiguration;
    if (operations.len == 0) return;
    var api_operations = std.json.Array.init(arena);
    for (operations) |operation_value| {
        const operation_fields = valueObject(operation_value) orelse return error.InvalidConfiguration;
        var api = std.json.ObjectMap.empty;
        try api.put(arena, "serviceName", .{ .string = try requiredObjectString(operation_fields, "service") });
        try copyValueField(context, arena, &api, operation_fields, "methods", "methodSelectors", false);
        try copyValueField(context, arena, &api, operation_fields, "permissions", "permissionSelectors", false);
        try api_operations.append(.{ .object = api });
    }
    try target.put(arena, "operations", .{ .array = api_operations });
}

fn userAccessBindingBody(context: *provider_mod.OperationContext, arena: std.mem.Allocator, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    try root.put(arena, "groupKey", .{ .string = try requiredLiteralString(node.inputs, "group_key") });
    const access = try requiredString(context, node.inputs, "access_level");
    if (access.len != 0) {
        var levels = std.json.Array.init(arena);
        try levels.append(.{ .string = access });
        try root.put(arena, "accessLevels", .{ .array = levels });
    }
    const dry_run = try requiredString(context, node.inputs, "dry_run_access_level");
    if (dry_run.len != 0) {
        var levels = std.json.Array.init(arena);
        try levels.append(.{ .string = dry_run });
        try root.put(arena, "dryRunAccessLevels", .{ .array = levels });
    }
}

fn putIdentityType(arena: std.mem.Allocator, object: *std.json.ObjectMap, identity_type: []const u8) ProviderError!void {
    if (identity_type.len != 0) try object.put(arena, "identityType", .{ .string = identity_type });
}

fn copyValueField(context: *provider_mod.OperationContext, arena: std.mem.Allocator, target: *std.json.ObjectMap, fields: []const value.Field, source_name: []const u8, target_name: []const u8, include_empty: bool) ProviderError!void {
    const source = try requiredObjectValue(fields, source_name);
    if (!include_empty and valueIsEmpty(source)) return;
    try target.put(arena, target_name, try resolvedValueJson(context, arena, source));
}

fn remoteMatches(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, remote: std.json.ObjectMap) ProviderError!bool {
    const desired_body = try bodyAlloc(context, node, kind, null);
    defer context.allocator.free(desired_body);
    var desired = std.json.parseFromSlice(std.json.Value, context.allocator, desired_body, .{}) catch return error.ProviderBug;
    defer desired.deinit();
    const desired_root = jsonObject(desired.value) orelse return error.ProviderBug;
    return jsonContains(desired_root, remote);
}

fn immutableChanged(kind: Kind, desired: std.json.ObjectMap, remote: std.json.ObjectMap) bool {
    const immutable_fields: []const []const u8 = switch (kind) {
        .policy => &.{"name"},
        .custom_constraint => &.{ "name", "resourceTypes" },
        .tag_key => &.{ "parent", "shortName", "purpose", "purposeData", "allowedValuesRegex" },
        .tag_value => &.{ "parent", "shortName" },
        .tag_binding, .tag_hold => return true,
        .access_policy => &.{ "parent", "scopes" },
        .access_level, .service_perimeter => &.{"name"},
        .user_access_binding => &.{"groupKey"},
    };
    for (immutable_fields) |field| if (!jsonValueEquivalent(desired.get(field), remote.get(field))) return true;
    return false;
}

fn jsonContains(desired: std.json.ObjectMap, remote: std.json.ObjectMap) bool {
    var iterator = desired.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "etag")) continue;
        const remote_value = remote.get(entry.key_ptr.*);
        if (!jsonValueEquivalent(entry.value_ptr.*, remote_value)) return false;
    }
    return true;
}

fn jsonValueEquivalent(desired_optional: ?std.json.Value, remote_optional: ?std.json.Value) bool {
    const desired = desired_optional orelse return remote_optional == null or (remote_optional != null and jsonValueEmpty(remote_optional.?));
    const remote = remote_optional orelse return jsonValueEmpty(desired);
    return switch (desired) {
        .null => remote == .null,
        .bool => |flag| remote == .bool and remote.bool == flag,
        .integer => |number| remote == .integer and remote.integer == number,
        .float => |number| remote == .float and remote.float == number,
        .number_string => |number| remote == .number_string and std.mem.eql(u8, remote.number_string, number),
        .string => |text| remote == .string and std.mem.eql(u8, remote.string, text),
        .array => |items| blk: {
            if (remote != .array or remote.array.items.len != items.items.len) break :blk false;
            for (items.items, remote.array.items) |left, right| if (!jsonValueEquivalent(left, right)) break :blk false;
            break :blk true;
        },
        .object => |object| remote == .object and jsonContains(object, remote.object),
    };
}

fn jsonValueEmpty(candidate: std.json.Value) bool {
    return switch (candidate) {
        .string => |text| text.len == 0,
        .array => |items| items.items.len == 0,
        .object => |object| object.count() == 0,
        .bool => |flag| !flag,
        else => false,
    };
}

fn pendingResult(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, body: []const u8) ProviderError!provider_mod.ResourceResult {
    const physical = (try physicalForReadAlloc(context, node, kind, null)) orelse try operationNameAlloc(context.allocator, body);
    defer context.allocator.free(physical);
    return pendingResultWithPhysical(context, node, kind, physical, body);
}

fn pendingResultWithPhysical(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, physical: []const u8, body: []const u8) ProviderError!provider_mod.ResourceResult {
    const handle = try operationNameAlloc(context.allocator, body);
    defer context.allocator.free(handle);
    const outputs = [_]state.StateOutput{.{ .name = primaryOutput(kind), .value = .{ .unknown_reason = "Google operation pending" } }};
    var result = try provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &outputs, handle);
    result.completed = false;
    return result;
}

fn resultFromJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, body: []const u8) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const physical = jsonString(root.get("name")) orelse return error.ProviderBug;
    try validatePhysical(kind, physical);
    const observed: value.Value = if (try remoteMatches(context, node, kind, root)) node.inputs else .{ .unknown_reason = "remote governance resource drifted" };
    var outputs: [5]state.StateOutput = undefined;
    var count: usize = 0;
    outputs[count] = .{ .name = primaryOutput(kind), .value = .{ .string = physical } };
    count += 1;
    switch (kind) {
        .policy => {
            outputs[count] = .{ .name = "etag", .value = .{ .string = jsonString(root.get("etag")) orelse "" } };
            count += 1;
            const spec = if (root.get("spec")) |candidate| jsonObject(candidate) else null;
            outputs[count] = .{ .name = "spec_etag", .value = .{ .string = if (spec) |object| jsonString(object.get("etag")) orelse "" else "" } };
            count += 1;
        },
        .custom_constraint => {
            outputs[count] = .{ .name = "update_time", .value = .{ .string = jsonString(root.get("updateTime")) orelse "" } };
            count += 1;
        },
        .tag_key, .tag_value => {
            outputs[count] = .{ .name = "namespaced_name", .value = .{ .string = jsonString(root.get("namespacedName")) orelse "" } };
            count += 1;
            outputs[count] = .{ .name = "etag", .value = .{ .string = jsonString(root.get("etag")) orelse "" } };
            count += 1;
        },
        .tag_hold => {
            outputs[count] = .{ .name = "create_time", .value = .{ .string = jsonString(root.get("createTime")) orelse "" } };
            count += 1;
        },
        .access_policy, .service_perimeter => {
            outputs[count] = .{ .name = "etag", .value = .{ .string = jsonString(root.get("etag")) orelse "" } };
            count += 1;
        },
        .tag_binding => {
            outputs[count] = .{ .name = "tag_value", .value = .{ .string = jsonString(root.get("tagValue")) orelse "" } };
            count += 1;
        },
        .access_level, .user_access_binding => {},
    }
    outputs[count] = .{ .name = "__remote_spec", .value = .{ .string = body } };
    count += 1;
    return provider_mod.ResourceResult.init(context.allocator, physical, observed, outputs[0..count], null);
}

fn operationNameAlloc(allocator: std.mem.Allocator, body: []const u8) ProviderError![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const name = jsonString(root.get("name")) orelse return error.ProviderBug;
    if (std.mem.indexOf(u8, name, "operations/") == null) return error.ProviderBug;
    return allocator.dupe(u8, name) catch error.OutOfMemory;
}

fn operationResponseAlloc(allocator: std.mem.Allocator, body: []const u8) ProviderError![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const response = root.get("response") orelse return error.ProviderBug;
    return std.json.Stringify.valueAlloc(allocator, response, .{}) catch error.OutOfMemory;
}

fn etagFromRemoteAlloc(allocator: std.mem.Allocator, kind: Kind, body: []const u8) ProviderError!?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const source = if (kind == .policy) blk: {
        const spec = root.get("spec") orelse break :blk null;
        const object = jsonObject(spec) orelse break :blk null;
        break :blk jsonString(object.get("etag"));
    } else jsonString(root.get("etag"));
    if (source) |etag| return allocator.dupe(u8, etag) catch error.OutOfMemory;
    return null;
}

fn primaryOutput(kind: Kind) []const u8 {
    _ = kind;
    return "name";
}

fn deletionRequested(node: resource.ResourceNode, kind: Kind) ProviderError!bool {
    if (kind == .access_policy) return requiredBoolean(node.inputs, "request_delete");
    return std.mem.eql(u8, try requiredLiteralString(node.inputs, "removal_policy"), "delete");
}

fn outputString(result: provider_mod.ResourceResult, name: []const u8) ?[]const u8 {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name)) return switch (item.value) {
        .string => |text| text,
        else => null,
    };
    return null;
}

fn requiredValue(source: value.Value, name: []const u8) ProviderError!value.Value {
    const fields = valueObject(source) orelse return error.InvalidConfiguration;
    return requiredObjectValue(fields, name);
}

fn requiredLiteralString(source: value.Value, name: []const u8) ProviderError![]const u8 {
    return valueString(try requiredValue(source, name)) orelse error.InvalidConfiguration;
}

fn requiredString(context: *provider_mod.OperationContext, source: value.Value, name: []const u8) ProviderError![]const u8 {
    return resolveString(context, try requiredValue(source, name));
}

fn resolveString(context: *provider_mod.OperationContext, source: value.Value) ProviderError![]const u8 {
    return switch (source) {
        .string => |text| text,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}

fn requiredBoolean(source: value.Value, name: []const u8) ProviderError!bool {
    return switch (try requiredValue(source, name)) {
        .boolean => |flag| flag,
        else => error.InvalidConfiguration,
    };
}

fn requiredObjectValue(fields: []const value.Field, name: []const u8) ProviderError!value.Value {
    return objectField(fields, name) orelse error.InvalidConfiguration;
}

fn requiredObjectString(fields: []const value.Field, name: []const u8) ProviderError![]const u8 {
    return valueString(try requiredObjectValue(fields, name)) orelse error.InvalidConfiguration;
}

fn requiredObjectBoolean(fields: []const value.Field, name: []const u8) ProviderError!bool {
    return switch (try requiredObjectValue(fields, name)) {
        .boolean => |flag| flag,
        else => error.InvalidConfiguration,
    };
}

fn objectField(fields: []const value.Field, name: []const u8) ?value.Value {
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return null;
}

fn valueObject(source: value.Value) ?[]const value.Field {
    return switch (source) {
        .object => |fields| fields,
        else => null,
    };
}

fn valueList(source: value.Value) ?[]const value.Value {
    return switch (source) {
        .list => |items| items,
        else => null,
    };
}

fn valueString(source: value.Value) ?[]const u8 {
    return switch (source) {
        .string => |text| text,
        else => null,
    };
}

fn resolvedValueJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    return switch (source) {
        .string => |text| .{ .string = text },
        .integer => |number| .{ .integer = number },
        .boolean => |flag| .{ .bool = flag },
        .list => |items| blk: {
            var array = std.json.Array.init(arena);
            for (items) |item| try array.append(try resolvedValueJson(context, arena, item));
            break :blk .{ .array = array };
        },
        .object => |fields| blk: {
            var object = std.json.ObjectMap.empty;
            for (fields) |field| try object.put(arena, field.name, try resolvedValueJson(context, arena, field.value));
            break :blk .{ .object = object };
        },
        .output_ref => |reference| .{ .string = try context.resolveOutputString(reference) },
        .secret_ref, .unknown_reason => error.InvalidConfiguration,
    };
}

fn valueIsEmpty(source: value.Value) bool {
    return switch (source) {
        .string => |text| text.len == 0,
        .list => |items| items.len == 0,
        .object => |fields| fields.len == 0,
        .boolean => |flag| !flag,
        else => false,
    };
}

fn valueIsEmptyObject(source: value.Value) bool {
    return source == .object and source.object.len == 0;
}

fn putOptionalString(arena: std.mem.Allocator, object: *std.json.ObjectMap, name: []const u8, text: []const u8) ProviderError!void {
    if (text.len != 0) try object.put(arena, name, .{ .string = text });
}

fn jsonObject(candidate: std.json.Value) ?std.json.ObjectMap {
    return switch (candidate) {
        .object => |object| object,
        else => null,
    };
}

fn jsonArray(candidate: std.json.Value) ?std.json.Array {
    return switch (candidate) {
        .array => |array| array,
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

fn percentEncodeAlloc(allocator: std.mem.Allocator, input: []const u8) ProviderError![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (input) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try result.append(allocator, byte);
        } else {
            try result.appendSlice(allocator, &.{ '%', hex[byte >> 4], hex[byte & 0x0f] });
        }
    }
    return result.toOwnedSlice(allocator) catch error.OutOfMemory;
}

fn numericName(candidate: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, candidate, prefix)) return false;
    const suffix = candidate[prefix.len..];
    if (suffix.len == 0 or std.mem.indexOfScalar(u8, suffix, '/') != null) return false;
    for (suffix) |char| if (!std.ascii.isDigit(char)) return false;
    return true;
}

fn containsCanonical(candidate: []const u8, separator: []const u8) bool {
    const index = std.mem.indexOf(u8, candidate, separator) orelse return false;
    return index != 0 and index + separator.len < candidate.len;
}
