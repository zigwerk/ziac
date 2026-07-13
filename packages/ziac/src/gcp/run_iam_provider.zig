const std = @import("std");
const client_mod = @import("client.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const rpc = @import("rpc.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;
const service_iam_type = "gcp.run.ServiceIamMember";
const job_iam_type = "gcp.run.JobIamMember";

pub const Handler = struct {
    client: *client_mod.Client,
    conflict_retries: usize = 3,

    pub fn read(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_override: ?[]const u8,
    ) ProviderError!provider_mod.ReadResult {
        const target = try resolveString(context, try requiredValue(node.inputs, "resource"));
        const physical = try physicalIdAlloc(context.allocator, node, target);
        defer context.allocator.free(physical);
        if (physical_override) |provided| if (!std.mem.eql(u8, provided, physical)) return error.InvalidConfiguration;
        const path = try policyPathAlloc(context.allocator, getPolicyMethod(node), target, true);
        defer context.allocator.free(path);
        var response = self.request(context, .{
            .api = .run,
            .method = getPolicyMethod(node).rest.?.method.text(),
            .path = path,
        }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        if (!policyHasExactMember(parsed.value, node)) return .absent;
        return .{ .present = try memberResult(context, node, target) };
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
        return provider_mod.DiffResult.init(context.allocator, .replace, &.{"Cloud Run IAM resource identity changed"});
    }

    pub fn create(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
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
        const target = try resolveString(context, try requiredValue(node.inputs, "resource"));
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
        const target = try resolveString(context, try requiredValue(node.inputs, "resource"));
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const get_path = try policyPathAlloc(context.allocator, getPolicyMethod(node), target, true);
            defer context.allocator.free(get_path);
            var current = self.request(context, .{
                .api = .run,
                .method = getPolicyMethod(node).rest.?.method.text(),
                .path = get_path,
            }) catch |err| {
                if (err == error.NotFound and !should_exist) return memberResult(context, node, target);
                return err;
            };
            defer current.deinit(context.allocator);
            var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, current.body, .{}) catch return error.ProviderBug;
            defer parsed.deinit();
            const changed = try mutatePolicy(&parsed, node, should_exist);
            if (!changed) return memberResult(context, node, target);
            const body = try policyBodyAlloc(context.allocator, parsed.value);
            defer context.allocator.free(body);
            const set_path = try policyPathAlloc(context.allocator, setPolicyMethod(node), target, false);
            defer context.allocator.free(set_path);
            var response = self.request(context, .{
                .api = .run,
                .method = setPolicyMethod(node).rest.?.method.text(),
                .path = set_path,
                .body = body,
            }) catch |err| {
                if (err == error.Conflict and attempt < self.conflict_retries) continue;
                return err;
            };
            response.deinit(context.allocator);
            return memberResult(context, node, target);
        }
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
    return std.mem.eql(u8, node.type_name, service_iam_type) or std.mem.eql(u8, node.type_name, job_iam_type);
}

fn getPolicyMethod(node: resource.ResourceNode) rpc.Method {
    return if (std.mem.eql(u8, node.type_name, job_iam_type)) rpc.cloud_run_v2.get_job_iam_policy else rpc.cloud_run_v2.get_service_iam_policy;
}

fn setPolicyMethod(node: resource.ResourceNode) rpc.Method {
    return if (std.mem.eql(u8, node.type_name, job_iam_type)) rpc.cloud_run_v2.set_job_iam_policy else rpc.cloud_run_v2.set_service_iam_policy;
}

fn policyPathAlloc(
    allocator: std.mem.Allocator,
    method: rpc.Method,
    target: []const u8,
    requested_version: bool,
) ProviderError![]u8 {
    const query: []const rpc.Parameter = if (requested_version)
        &.{.{ .field = "requested_policy_version", .value = "3" }}
    else
        &.{};
    return rpc.restPathAlloc(allocator, method, &.{.{ .field = "resource", .value = target }}, query) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidPathTemplate,
        error.InvalidResourceName,
        error.MissingPathParameter,
        error.UnknownQueryParameter,
        error.MissingRestBinding,
        => error.ProviderBug,
    };
}

fn physicalIdAlloc(
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    target: []const u8,
) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/iam/{s}", .{ target, try requiredString(node.inputs, "name") }) catch error.OutOfMemory;
}

fn memberResult(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    target: []const u8,
) ProviderError!provider_mod.ResourceResult {
    const physical = try physicalIdAlloc(context.allocator, node, target);
    defer context.allocator.free(physical);
    const outputs = [_]state.StateOutput{.{ .name = "binding_id", .value = .{ .string = physical } }};
    return provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &outputs, null);
}

fn policyBodyAlloc(allocator: std.mem.Allocator, policy: std.json.Value) ProviderError![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var wrapper: std.json.ObjectMap = .empty;
    try wrapper.put(arena.allocator(), "policy", policy);
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = wrapper }, .{}) catch error.OutOfMemory;
}

fn policyHasExactMember(policy: std.json.Value, node: resource.ResourceNode) bool {
    const root = jsonObject(policy) orelse return false;
    const bindings = jsonArray(root.get("bindings") orelse return false) orelse return false;
    for (bindings.items) |candidate| {
        const binding = jsonObject(candidate) orelse continue;
        if (!bindingIdentityMatches(binding, node)) continue;
        const members = jsonArray(binding.get("members") orelse continue) orelse continue;
        for (members.items) |member| {
            if (stringEquals(member, inputString(node.inputs, "member") orelse return false)) return true;
        }
    }
    return false;
}

fn mutatePolicy(
    parsed: *std.json.Parsed(std.json.Value),
    node: resource.ResourceNode,
    should_exist: bool,
) ProviderError!bool {
    const allocator = parsed.arena.allocator();
    const root = switch (parsed.value) {
        .object => |*object| object,
        else => return error.ProviderBug,
    };
    try root.put(allocator, "version", .{ .integer = 3 });
    var bindings_value = root.getPtr("bindings");
    if (bindings_value == null) {
        if (!should_exist) return false;
        try root.put(allocator, "bindings", .{ .array = std.json.Array.init(allocator) });
        bindings_value = root.getPtr("bindings");
    }
    const bindings = switch (bindings_value.?.*) {
        .array => |*array| array,
        else => return error.ProviderBug,
    };
    for (bindings.items, 0..) |*binding_value, binding_index| {
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
            if (members.items.len == 0) _ = bindings.orderedRemove(binding_index);
            return true;
        }
        if (!should_exist) return false;
        try members.append(.{ .string = member });
        return true;
    }
    if (!should_exist) return false;
    var members = std.json.Array.init(allocator);
    try members.append(.{ .string = try requiredString(node.inputs, "member") });
    var binding: std.json.ObjectMap = .empty;
    try binding.put(allocator, "role", .{ .string = try requiredString(node.inputs, "role") });
    try binding.put(allocator, "members", .{ .array = members });
    const condition_title = try requiredString(node.inputs, "condition_title");
    if (condition_title.len > 0) {
        var condition: std.json.ObjectMap = .empty;
        try condition.put(allocator, "title", .{ .string = condition_title });
        const description = try requiredString(node.inputs, "condition_description");
        if (description.len > 0) try condition.put(allocator, "description", .{ .string = description });
        try condition.put(allocator, "expression", .{ .string = try requiredString(node.inputs, "condition_expression") });
        try binding.put(allocator, "condition", .{ .object = condition });
    }
    try bindings.append(.{ .object = binding });
    return true;
}

fn bindingIdentityMatches(binding: std.json.ObjectMap, node: resource.ResourceNode) bool {
    if (!stringEquals(binding.get("role"), inputString(node.inputs, "role") orelse return false)) return false;
    const title = inputString(node.inputs, "condition_title") orelse return false;
    const description = inputString(node.inputs, "condition_description") orelse return false;
    const expression = inputString(node.inputs, "condition_expression") orelse return false;
    const condition = jsonObject(binding.get("condition") orelse .{ .object = .empty }) orelse return false;
    return stringEquals(condition.get("title"), title) and
        stringEquals(condition.get("description"), description) and
        stringEquals(condition.get("expression"), expression);
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

fn resolveString(context: *provider_mod.OperationContext, input: value.Value) ProviderError![]const u8 {
    return switch (input) {
        .string => |text| text,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}

fn inputString(input: value.Value, name: []const u8) ?[]const u8 {
    return switch (requiredValue(input, name) catch return null) {
        .string => |text| text,
        else => null,
    };
}

fn stringEquals(input: ?std.json.Value, expected: []const u8) bool {
    const actual = jsonString(input) orelse return expected.len == 0;
    return std.mem.eql(u8, actual, expected);
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
    const present = input orelse return null;
    return switch (present) {
        .string => |text| text,
        else => null,
    };
}
