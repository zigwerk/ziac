const std = @import("std");
const client_mod = @import("client.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;

const supported_types = [_][]const u8{
    "gcp.bigquery.ConnectionIamMember",
    "gcp.bigquery.DatasetIamMember",
    "gcp.bigquery.ReservationIamMember",
    "gcp.bigquery.RoutineIamMember",
    "gcp.bigquery.TableIamMember",
    "gcp.firestore.DatabaseIamMember",
    "gcp.iam.FolderBinding",
    "gcp.iam.FolderMember",
    "gcp.iam.FolderPolicy",
    "gcp.iam.OrganizationBinding",
    "gcp.iam.OrganizationMember",
    "gcp.iam.OrganizationPolicy",
    "gcp.iam.ProjectBinding",
    "gcp.iam.ProjectMember",
    "gcp.iam.ProjectPolicy",
    "gcp.iam.ServiceAccountIamBinding",
    "gcp.iam.ServiceAccountIamMember",
};

const Ownership = enum { member, binding, policy };

pub const Handler = struct {
    client: *client_mod.Client,
    conflict_retries: usize = 3,

    pub fn read(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_override: ?[]const u8,
    ) ProviderError!provider_mod.ReadResult {
        const target = try requiredString(node.inputs, "resource_name");
        const physical = try physicalIdAlloc(context.allocator, node, target);
        defer context.allocator.free(physical);
        if (physical_override) |provided| if (!std.mem.eql(u8, provided, physical)) return error.InvalidConfiguration;
        var policy = self.getPolicy(context, node, target) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer policy.deinit();
        switch (try ownership(node)) {
            .member => if (!policyHasExactMember(policy.value, node)) return .absent,
            .binding => if (findBinding(policy.value, node) == null) return .absent,
            .policy => {},
        }
        return .{ .present = try resultFromPolicy(context, node, target, policy.value) };
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
        const mode = try ownership(node);
        const kind: provider_mod.DiffKind = if (mode == .member or identityChanged(node.inputs, observed.observed_inputs)) .replace else .update;
        const reason: []const u8 = if (kind == .replace)
            "IAM ownership identity changed"
        else
            "IAM authoritative member set changed";
        return provider_mod.DiffResult.init(context.allocator, kind, &.{reason});
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        return self.ensure(context, node, true);
    }

    pub fn update(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        _: []const u8,
    ) ProviderError!provider_mod.ResourceResult {
        return self.ensure(context, node, true);
    }

    pub fn delete(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!void {
        const target = try requiredString(node.inputs, "resource_name");
        const expected = try physicalIdAlloc(context.allocator, node, target);
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        var removed = try self.ensure(context, node, false);
        removed.deinit();
    }

    fn ensure(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        should_exist: bool,
    ) ProviderError!provider_mod.ResourceResult {
        const target = try requiredString(node.inputs, "resource_name");
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            try context.checkActive();
            var policy = self.getPolicy(context, node, target) catch |err| {
                if (err == error.NotFound and !should_exist) return resultFromDesired(context, node, target);
                return err;
            };
            defer policy.deinit();
            const changed = try mutatePolicy(&policy, node, should_exist);
            if (!changed) return resultFromPolicy(context, node, target, policy.value);
            const body = try policyBodyAlloc(context.allocator, policy.value);
            defer context.allocator.free(body);
            const path = try policyPathAlloc(context.allocator, node, target, false);
            defer context.allocator.free(path);
            var response = self.request(context, .{
                .api = policyApi(node),
                .method = "POST",
                .path = path,
                .body = body,
            }) catch |err| {
                if (err == error.Conflict and attempt < self.conflict_retries) continue;
                return err;
            };
            response.deinit(context.allocator);
            return resultFromPolicy(context, node, target, policy.value);
        }
    }

    fn getPolicy(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        target: []const u8,
    ) ProviderError!std.json.Parsed(std.json.Value) {
        const path = try policyPathAlloc(context.allocator, node, target, true);
        defer context.allocator.free(path);
        var response = try self.request(context, .{
            .api = policyApi(node),
            .method = "POST",
            .path = path,
            .body = "{\"options\":{\"requestedPolicyVersion\":3}}",
        });
        defer response.deinit(context.allocator);
        return std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch error.ProviderBug;
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
    for (supported_types) |type_name| if (std.mem.eql(u8, node.type_name, type_name)) return true;
    return false;
}

fn ownership(node: resource.ResourceNode) ProviderError!Ownership {
    const text = try requiredString(node.inputs, "ownership_mode");
    if (std.mem.eql(u8, text, "member")) return .member;
    if (std.mem.eql(u8, text, "binding")) return .binding;
    if (std.mem.eql(u8, text, "policy")) return .policy;
    return error.InvalidConfiguration;
}

fn policyApi(node: resource.ResourceNode) client_mod.Api {
    if (std.mem.startsWith(u8, node.type_name, "gcp.firestore.")) return .firestore;
    if (std.mem.startsWith(u8, node.type_name, "gcp.bigquery.Connection")) return .bigquery_connection;
    if (std.mem.startsWith(u8, node.type_name, "gcp.bigquery.Reservation")) return .bigquery_reservation;
    if (std.mem.startsWith(u8, node.type_name, "gcp.bigquery.")) return .bigquery;
    return if (std.mem.indexOf(u8, node.type_name, "ServiceAccount") != null) .iam else .resource_manager;
}

fn policyPathAlloc(
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    target: []const u8,
    get: bool,
) ProviderError![]const u8 {
    if (std.mem.startsWith(u8, node.type_name, "gcp.firestore.")) {
        return std.fmt.allocPrint(allocator, "/v1/{s}:{s}IamPolicy", .{ target, if (get) "get" else "set" }) catch error.OutOfMemory;
    }
    if (std.mem.startsWith(u8, node.type_name, "gcp.bigquery.")) {
        const version: []const u8 = if (std.mem.indexOf(u8, node.type_name, "Connection") != null or
            std.mem.indexOf(u8, node.type_name, "Reservation") != null) "v1" else "bigquery/v2";
        return std.fmt.allocPrint(allocator, "/{s}/{s}:{s}IamPolicy", .{ version, target, if (get) "get" else "set" }) catch error.OutOfMemory;
    }
    const version: []const u8 = if (policyApi(node) == .iam) "v1" else "v3";
    return std.fmt.allocPrint(allocator, "/{s}/{s}:{s}IamPolicy", .{ version, target, if (get) "get" else "set" }) catch error.OutOfMemory;
}

fn policyBodyAlloc(allocator: std.mem.Allocator, policy: std.json.Value) ProviderError![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var wrapper: std.json.ObjectMap = .empty;
    try wrapper.put(arena, "policy", policy);
    try wrapper.put(arena, "updateMask", .{ .string = "bindings,etag" });
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = wrapper }, .{}) catch error.OutOfMemory;
}

fn mutatePolicy(
    parsed: *std.json.Parsed(std.json.Value),
    node: resource.ResourceNode,
    should_exist: bool,
) ProviderError!bool {
    const changed = switch (try ownership(node)) {
        .member => try mutateMember(parsed, node, should_exist),
        .binding => try mutateBinding(parsed, node, should_exist),
        .policy => try mutateAuthoritativePolicy(parsed, node, should_exist),
    };
    if (changed) try updatePolicyVersion(parsed);
    return changed;
}

fn mutateMember(
    parsed: *std.json.Parsed(std.json.Value),
    node: resource.ResourceNode,
    should_exist: bool,
) ProviderError!bool {
    const allocator = parsed.arena.allocator();
    const bindings = try mutableBindings(parsed, should_exist);
    if (bindings == null) return false;
    for (bindings.?.items, 0..) |*binding_value, binding_index| {
        const binding = switch (binding_value.*) {
            .object => |*object| object,
            else => continue,
        };
        if (!bindingIdentityMatches(binding.*, node)) continue;
        const members_value = binding.getPtr("members") orelse return error.ProviderBug;
        const members = switch (members_value.*) {
            .array => |*array| array,
            else => return error.ProviderBug,
        };
        const member = try requiredString(node.inputs, "member");
        for (members.items, 0..) |candidate, member_index| {
            if (!stringEquals(candidate, member)) continue;
            if (should_exist) return false;
            _ = members.orderedRemove(member_index);
            if (members.items.len == 0) _ = bindings.?.orderedRemove(binding_index);
            return true;
        }
        if (!should_exist) return false;
        try members.append(.{ .string = member });
        sortJsonMembers(members.items);
        return true;
    }
    if (!should_exist) return false;
    var binding: std.json.ObjectMap = .empty;
    try binding.put(allocator, "role", .{ .string = try requiredString(node.inputs, "role") });
    try binding.put(allocator, "members", try desiredMembersJson(allocator, node, true));
    try appendDesiredCondition(allocator, &binding, node);
    try bindings.?.append(.{ .object = binding });
    return true;
}

fn mutateBinding(
    parsed: *std.json.Parsed(std.json.Value),
    node: resource.ResourceNode,
    should_exist: bool,
) ProviderError!bool {
    const allocator = parsed.arena.allocator();
    const bindings = try mutableBindings(parsed, should_exist);
    if (bindings == null) return false;
    for (bindings.?.items, 0..) |*binding_value, binding_index| {
        const binding = switch (binding_value.*) {
            .object => |*object| object,
            else => continue,
        };
        if (!bindingIdentityMatches(binding.*, node)) continue;
        if (!should_exist) {
            _ = bindings.?.orderedRemove(binding_index);
            return true;
        }
        if (bindingMembersMatch(binding.*, node)) return false;
        try binding.put(allocator, "members", try desiredMembersJson(allocator, node, false));
        return true;
    }
    if (!should_exist) return false;
    var binding: std.json.ObjectMap = .empty;
    try binding.put(allocator, "role", .{ .string = try requiredString(node.inputs, "role") });
    try binding.put(allocator, "members", try desiredMembersJson(allocator, node, false));
    try appendDesiredCondition(allocator, &binding, node);
    try bindings.?.append(.{ .object = binding });
    return true;
}

fn mutateAuthoritativePolicy(
    parsed: *std.json.Parsed(std.json.Value),
    node: resource.ResourceNode,
    should_exist: bool,
) ProviderError!bool {
    const allocator = parsed.arena.allocator();
    const root = switch (parsed.value) {
        .object => |*object| object,
        else => return error.ProviderBug,
    };
    const desired_json = if (should_exist) try requiredString(node.inputs, "bindings_json") else "[]";
    const current_json = try canonicalBindingsJsonAlloc(allocator, parsed.value);
    if (std.mem.eql(u8, current_json, desired_json)) return false;
    var desired = std.json.parseFromSlice(std.json.Value, allocator, desired_json, .{}) catch return error.InvalidConfiguration;
    defer desired.deinit();
    if (desired.value != .array) return error.InvalidConfiguration;
    try root.put(allocator, "bindings", try cloneJsonValue(allocator, desired.value));
    return true;
}

fn mutableBindings(
    parsed: *std.json.Parsed(std.json.Value),
    create: bool,
) ProviderError!?*std.json.Array {
    const allocator = parsed.arena.allocator();
    const root = switch (parsed.value) {
        .object => |*object| object,
        else => return error.ProviderBug,
    };
    var bindings_value = root.getPtr("bindings");
    if (bindings_value == null) {
        if (!create) return null;
        try root.put(allocator, "bindings", .{ .array = std.json.Array.init(allocator) });
        bindings_value = root.getPtr("bindings");
    }
    return switch (bindings_value.?.*) {
        .array => |*array| array,
        else => error.ProviderBug,
    };
}

fn updatePolicyVersion(parsed: *std.json.Parsed(std.json.Value)) ProviderError!void {
    const allocator = parsed.arena.allocator();
    const root = switch (parsed.value) {
        .object => |*object| object,
        else => return error.ProviderBug,
    };
    const bindings = jsonArray(root.get("bindings") orelse .{ .array = std.json.Array.init(allocator) }) orelse return error.ProviderBug;
    var conditional = false;
    for (bindings.items) |binding_value| {
        const binding = jsonObject(binding_value) orelse continue;
        if (binding.get("condition") != null) {
            conditional = true;
            break;
        }
    }
    try root.put(allocator, "version", .{ .integer = if (conditional) 3 else 1 });
}

fn policyHasExactMember(policy: std.json.Value, node: resource.ResourceNode) bool {
    const binding = findBinding(policy, node) orelse return false;
    const members = jsonArray(binding.get("members") orelse return false) orelse return false;
    const expected = inputString(node.inputs, "member") orelse return false;
    for (members.items) |member| if (stringEquals(member, expected)) return true;
    return false;
}

fn findBinding(policy: std.json.Value, node: resource.ResourceNode) ?std.json.ObjectMap {
    const root = jsonObject(policy) orelse return null;
    const bindings = jsonArray(root.get("bindings") orelse return null) orelse return null;
    for (bindings.items) |binding_value| {
        const binding = jsonObject(binding_value) orelse continue;
        if (bindingIdentityMatches(binding, node)) return binding;
    }
    return null;
}

fn bindingIdentityMatches(binding: std.json.ObjectMap, node: resource.ResourceNode) bool {
    if (!stringEquals(binding.get("role") orelse return false, inputString(node.inputs, "role") orelse return false)) return false;
    const expected_title = inputString(node.inputs, "condition_title") orelse return false;
    const expected_description = inputString(node.inputs, "condition_description") orelse return false;
    const expected_expression = inputString(node.inputs, "condition_expression") orelse return false;
    const condition_value = binding.get("condition");
    if (condition_value == null) return expected_title.len == 0 and expected_description.len == 0 and expected_expression.len == 0;
    const condition = jsonObject(condition_value.?) orelse return false;
    return optionalStringEquals(condition.get("title"), expected_title) and
        optionalStringEquals(condition.get("description"), expected_description) and
        optionalStringEquals(condition.get("expression"), expected_expression);
}

fn bindingMembersMatch(binding: std.json.ObjectMap, node: resource.ResourceNode) bool {
    const remote = jsonArray(binding.get("members") orelse return false) orelse return false;
    const desired = inputList(node.inputs, "members") orelse return false;
    if (remote.items.len != desired.len) return false;
    for (desired) |desired_member| {
        const expected = switch (desired_member) {
            .string => |text| text,
            else => return false,
        };
        var found = false;
        for (remote.items) |remote_member| if (stringEquals(remote_member, expected)) {
            found = true;
            break;
        };
        if (!found) return false;
    }
    return true;
}

fn desiredMembersJson(allocator: std.mem.Allocator, node: resource.ResourceNode, single: bool) ProviderError!std.json.Value {
    var members = std.json.Array.init(allocator);
    if (single) {
        try members.append(.{ .string = try requiredString(node.inputs, "member") });
    } else {
        const desired = inputList(node.inputs, "members") orelse return error.InvalidConfiguration;
        for (desired) |member| switch (member) {
            .string => |text| try members.append(.{ .string = text }),
            else => return error.InvalidConfiguration,
        };
    }
    sortJsonMembers(members.items);
    return .{ .array = members };
}

fn appendDesiredCondition(
    allocator: std.mem.Allocator,
    binding: *std.json.ObjectMap,
    node: resource.ResourceNode,
) ProviderError!void {
    const title = try requiredString(node.inputs, "condition_title");
    if (title.len == 0) return;
    var condition: std.json.ObjectMap = .empty;
    try condition.put(allocator, "title", .{ .string = title });
    try condition.put(allocator, "description", .{ .string = try requiredString(node.inputs, "condition_description") });
    try condition.put(allocator, "expression", .{ .string = try requiredString(node.inputs, "condition_expression") });
    try binding.put(allocator, "condition", .{ .object = condition });
}

fn resultFromPolicy(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    target: []const u8,
    policy: std.json.Value,
) ProviderError!provider_mod.ResourceResult {
    var observed = value.Value.initOwned(context.allocator, node.inputs) catch |err| return mapValueError(err);
    defer observed.deinit(context.allocator);
    switch (try ownership(node)) {
        .member => {},
        .binding => {
            const binding = findBinding(policy, node) orelse return error.NotFound;
            const members = jsonArray(binding.get("members") orelse return error.ProviderBug) orelse return error.ProviderBug;
            const temporary = try context.allocator.alloc(value.Value, members.items.len);
            defer context.allocator.free(temporary);
            for (members.items, 0..) |member, index| temporary[index] = .{ .string = jsonString(member) orelse return error.ProviderBug };
            std.mem.sort(value.Value, temporary, {}, lessThanValueString);
            try replaceInput(&observed, context.allocator, "members", .{ .list = temporary });
        },
        .policy => {
            const bindings_json = try canonicalBindingsJsonAlloc(context.allocator, policy);
            defer context.allocator.free(bindings_json);
            try replaceInput(&observed, context.allocator, "bindings_json", .{ .string = bindings_json });
        },
    }
    return resultWithInputs(context, node, target, observed);
}

fn resultFromDesired(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    target: []const u8,
) ProviderError!provider_mod.ResourceResult {
    return resultWithInputs(context, node, target, node.inputs);
}

fn resultWithInputs(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    target: []const u8,
    inputs: value.Value,
) ProviderError!provider_mod.ResourceResult {
    const physical = try physicalIdAlloc(context.allocator, node, target);
    defer context.allocator.free(physical);
    const output_name: []const u8 = if ((try ownership(node)) == .policy) "policy_id" else "binding_id";
    const outputs = [_]state.StateOutput{.{ .name = output_name, .value = .{ .string = physical } }};
    return provider_mod.ResourceResult.init(context.allocator, physical, inputs, &outputs, null);
}

fn physicalIdAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, target: []const u8) ProviderError![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}/iam/{s}/{s}",
        .{ target, try requiredString(node.inputs, "ownership_mode"), try requiredString(node.inputs, "name") },
    ) catch error.OutOfMemory;
}

fn identityChanged(desired: value.Value, observed: value.Value) bool {
    const names = [_][]const u8{ "resource_name", "role", "condition_title", "condition_description", "condition_expression" };
    for (names) |name| {
        const left = inputString(desired, name) orelse "";
        const right = inputString(observed, name) orelse "";
        if (!std.mem.eql(u8, left, right)) return true;
    }
    return false;
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

fn canonicalBindingsJsonAlloc(allocator: std.mem.Allocator, policy: std.json.Value) ProviderError![]const u8 {
    const root = jsonObject(policy) orelse return error.ProviderBug;
    const bindings = jsonArray(root.get("bindings") orelse .{ .array = std.json.Array.init(allocator) }) orelse return error.ProviderBug;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const views = try arena.alloc(BindingView, bindings.items.len);
    for (bindings.items, 0..) |binding_value, index| {
        const binding = jsonObject(binding_value) orelse return error.ProviderBug;
        const condition = if (binding.get("condition")) |entry| jsonObject(entry) orelse return error.ProviderBug else null;
        views[index] = .{
            .binding = binding,
            .role = jsonString(binding.get("role") orelse return error.ProviderBug) orelse return error.ProviderBug,
            .title = if (condition) |entry| jsonString(entry.get("title") orelse .{ .string = "" }) orelse "" else "",
            .description = if (condition) |entry| jsonString(entry.get("description") orelse .{ .string = "" }) orelse "" else "",
            .expression = if (condition) |entry| jsonString(entry.get("expression") orelse .{ .string = "" }) orelse "" else "",
        };
    }
    std.mem.sort(BindingView, views, {}, lessThanBindingView);
    var normalized = std.json.Array.init(arena);
    for (views) |view| {
        var binding: std.json.ObjectMap = .empty;
        try binding.put(arena, "role", .{ .string = view.role });
        const source_members = jsonArray(view.binding.get("members") orelse return error.ProviderBug) orelse return error.ProviderBug;
        const member_strings = try arena.alloc([]const u8, source_members.items.len);
        for (source_members.items, 0..) |member, index| member_strings[index] = jsonString(member) orelse return error.ProviderBug;
        std.mem.sort([]const u8, member_strings, {}, lessThanString);
        var members = std.json.Array.init(arena);
        for (member_strings) |member| try members.append(.{ .string = member });
        try binding.put(arena, "members", .{ .array = members });
        if (view.title.len > 0 or view.expression.len > 0) {
            var condition: std.json.ObjectMap = .empty;
            try condition.put(arena, "title", .{ .string = view.title });
            try condition.put(arena, "description", .{ .string = view.description });
            try condition.put(arena, "expression", .{ .string = view.expression });
            try binding.put(arena, "condition", .{ .object = condition });
        }
        try normalized.append(.{ .object = binding });
    }
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .array = normalized }, .{}) catch error.OutOfMemory;
}

const BindingView = struct {
    binding: std.json.ObjectMap,
    role: []const u8,
    title: []const u8,
    description: []const u8,
    expression: []const u8,
};

fn lessThanBindingView(_: void, left: BindingView, right: BindingView) bool {
    const role = std.mem.order(u8, left.role, right.role);
    if (role != .eq) return role == .lt;
    const title = std.mem.order(u8, left.title, right.title);
    if (title != .eq) return title == .lt;
    const expression = std.mem.order(u8, left.expression, right.expression);
    if (expression != .eq) return expression == .lt;
    return std.mem.lessThan(u8, left.description, right.description);
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

fn inputString(input: value.Value, name: []const u8) ?[]const u8 {
    return switch (requiredValue(input, name) catch return null) {
        .string => |text| text,
        else => null,
    };
}

fn inputList(input: value.Value, name: []const u8) ?[]const value.Value {
    return switch (requiredValue(input, name) catch return null) {
        .list => |items| items,
        else => null,
    };
}

fn mapValueError(err: value.ValueError) ProviderError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateField => error.ProviderBug,
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

fn jsonString(input: std.json.Value) ?[]const u8 {
    return switch (input) {
        .string => |text| text,
        else => null,
    };
}

fn stringEquals(input: std.json.Value, expected: []const u8) bool {
    const actual = jsonString(input) orelse return false;
    return std.mem.eql(u8, actual, expected);
}

fn optionalStringEquals(input: ?std.json.Value, expected: []const u8) bool {
    if (input == null) return expected.len == 0;
    return stringEquals(input.?, expected);
}

fn sortJsonMembers(items: []std.json.Value) void {
    std.mem.sort(std.json.Value, items, {}, lessThanJsonString);
}

fn lessThanJsonString(_: void, left: std.json.Value, right: std.json.Value) bool {
    return std.mem.lessThan(u8, jsonString(left) orelse "", jsonString(right) orelse "");
}

fn lessThanValueString(_: void, left: value.Value, right: value.Value) bool {
    return std.mem.lessThan(u8, left.string, right.string);
}

fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
