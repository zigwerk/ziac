const std = @import("std");
const client_mod = @import("client.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;

pub const Handler = struct {
    client: *client_mod.Client,

    pub fn supports(node: resource.ResourceNode) bool {
        return apiFor(node) != null;
    }

    pub fn read(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, _: ?[]const u8) ProviderError!provider_mod.ReadResult {
        try context.checkActive();
        const target = try requiredString(context, node.inputs, "resource");
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}:getIamPolicy?options.requestedPolicyVersion=3", .{target});
        defer context.allocator.free(path);
        var response = self.request(context, node, "GET", path, "") catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        if (!policyHasExactMember(parsed.value, node)) return .absent;
        return .{ .present = try iamResult(context, node, target) };
    }

    pub fn diff(context: *provider_mod.OperationContext, node: resource.ResourceNode, _: *const provider_mod.ResourceResult) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        if (!supports(node)) return error.InvalidConfiguration;
        return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        return self.mutate(context, node, true);
    }

    pub fn update(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, _: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        return self.mutate(context, node, true);
    }

    pub fn delete(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, _: []const u8) ProviderError!void {
        try context.checkActive();
        var removed = try self.mutate(context, node, false);
        removed.deinit();
    }

    pub fn importResource(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, _: []const u8) ProviderError!provider_mod.ResourceResult {
        var result = try self.read(context, node, null);
        defer result.deinit();
        return switch (result) {
            .absent => error.NotFound,
            .present => |present| present.clone(context.allocator),
        };
    }

    fn mutate(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, should_exist: bool) ProviderError!provider_mod.ResourceResult {
        const target = try requiredString(context, node.inputs, "resource");
        const get_path = try std.fmt.allocPrint(context.allocator, "/v1/{s}:getIamPolicy?options.requestedPolicyVersion=3", .{target});
        defer context.allocator.free(get_path);
        var get_response = try self.request(context, node, "GET", get_path, "");
        defer get_response.deinit(context.allocator);
        var policy = std.json.parseFromSlice(std.json.Value, context.allocator, get_response.body, .{}) catch return error.ProviderBug;
        defer policy.deinit();
        if (try mutatePolicy(&policy, node, should_exist)) {
            const body = try policyBodyAlloc(context.allocator, policy.value);
            defer context.allocator.free(body);
            const set_path = try std.fmt.allocPrint(context.allocator, "/v1/{s}:setIamPolicy", .{target});
            defer context.allocator.free(set_path);
            var response = try self.request(context, node, "POST", set_path, body);
            response.deinit(context.allocator);
        }
        return iamResult(context, node, target);
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, method: []const u8, path: []const u8, body: []const u8) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, .{ .api = apiFor(node) orelse return error.InvalidConfiguration, .method = method, .path = path, .body = body }, &diagnostic);
    }
};

fn apiFor(node: resource.ResourceNode) ?client_mod.Api {
    if (std.mem.eql(u8, node.type_name, "gcp.dataform.RepositoryIamMember") or
        std.mem.eql(u8, node.type_name, "gcp.dataform.WorkspaceIamMember")) return .dataform;
    if (std.mem.eql(u8, node.type_name, "gcp.dataproc.ClusterIamMember") or
        std.mem.eql(u8, node.type_name, "gcp.dataproc.AutoscalingPolicyIamMember") or
        std.mem.eql(u8, node.type_name, "gcp.dataproc.WorkflowTemplateIamMember")) return .dataproc;
    return null;
}

fn iamResult(context: *provider_mod.OperationContext, node: resource.ResourceNode, target: []const u8) ProviderError!provider_mod.ResourceResult {
    const outputs = [_]state.StateOutput{.{ .name = "resource", .value = .{ .string = target } }};
    const physical = try std.fmt.allocPrint(context.allocator, "{s}#iam/{s}", .{ target, node.id });
    defer context.allocator.free(physical);
    return provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &outputs, null);
}

fn policyBodyAlloc(allocator: std.mem.Allocator, policy: std.json.Value) ProviderError![]u8 {
    var wrapper = std.json.ObjectMap.empty;
    try wrapper.put(allocator, "policy", policy);
    defer wrapper.deinit(allocator);
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = wrapper }, .{}) catch error.OutOfMemory;
}

fn policyHasExactMember(policy: std.json.Value, node: resource.ResourceNode) bool {
    const root = jsonObject(policy) orelse return false;
    const bindings = jsonArray(root.get("bindings") orelse return false) orelse return false;
    for (bindings.items) |candidate| {
        const binding = jsonObject(candidate) orelse continue;
        if (!bindingIdentityMatches(binding, node)) continue;
        const members = jsonArray(binding.get("members") orelse continue) orelse continue;
        for (members.items) |member| if (stringEquals(member, inputString(node.inputs, "member") orelse return false)) return true;
    }
    return false;
}

fn mutatePolicy(parsed: *std.json.Parsed(std.json.Value), node: resource.ResourceNode, should_exist: bool) ProviderError!bool {
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
        const member = try requiredLiteralString(node.inputs, "member");
        for (members.items, 0..) |candidate, member_index| if (stringEquals(candidate, member)) {
            if (should_exist) return false;
            _ = members.orderedRemove(member_index);
            if (members.items.len == 0) _ = bindings.orderedRemove(binding_index);
            return true;
        };
        if (!should_exist) return false;
        try members.append(.{ .string = member });
        return true;
    }
    if (!should_exist) return false;
    var members = std.json.Array.init(allocator);
    try members.append(.{ .string = try requiredLiteralString(node.inputs, "member") });
    var binding = std.json.ObjectMap.empty;
    try binding.put(allocator, "role", .{ .string = try requiredLiteralString(node.inputs, "role") });
    try binding.put(allocator, "members", .{ .array = members });
    const condition = try requiredValue(node.inputs, "condition");
    if (!valueIsEmpty(condition)) try binding.put(allocator, "condition", try valueJsonLiteral(allocator, condition));
    try bindings.append(.{ .object = binding });
    return true;
}

fn bindingIdentityMatches(binding: std.json.ObjectMap, node: resource.ResourceNode) bool {
    if (!stringEquals(binding.get("role"), inputString(node.inputs, "role") orelse return false)) return false;
    const desired = requiredValue(node.inputs, "condition") catch return false;
    if (valueIsEmpty(desired)) return binding.get("condition") == null;
    return jsonMatchesValue(desired, binding.get("condition") orelse return false);
}

fn requiredValue(source: value.Value, name: []const u8) ProviderError!value.Value {
    const fields = if (source == .object) source.object else return error.InvalidConfiguration;
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return error.InvalidConfiguration;
}
fn requiredLiteralString(source: value.Value, name: []const u8) ProviderError![]const u8 {
    const selected = try requiredValue(source, name);
    return if (selected == .string) selected.string else error.InvalidConfiguration;
}
fn requiredString(context: *provider_mod.OperationContext, source: value.Value, name: []const u8) ProviderError![]const u8 {
    return switch (try requiredValue(source, name)) {
        .string => |text| text,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}
fn inputString(input: value.Value, name: []const u8) ?[]const u8 {
    const selected = requiredValue(input, name) catch return null;
    return if (selected == .string) selected.string else null;
}
fn valueIsEmpty(candidate: value.Value) bool {
    return candidate == .object and candidate.object.len == 0;
}

fn valueJsonLiteral(allocator: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    return switch (source) {
        .string => |text| .{ .string = text },
        .integer => |number| .{ .integer = number },
        .boolean => |flag| .{ .bool = flag },
        .list => |items| blk: {
            var array = std.json.Array.init(allocator);
            for (items) |item| try array.append(try valueJsonLiteral(allocator, item));
            break :blk .{ .array = array };
        },
        .object => |fields| blk: {
            var object = std.json.ObjectMap.empty;
            for (fields) |field| try object.put(allocator, field.name, try valueJsonLiteral(allocator, field.value));
            break :blk .{ .object = object };
        },
        .output_ref, .secret_ref, .unknown_reason => error.InvalidConfiguration,
    };
}

fn jsonMatchesValue(desired: value.Value, actual: std.json.Value) bool {
    return switch (desired) {
        .string => |text| actual == .string and std.mem.eql(u8, text, actual.string),
        .integer => |number| actual == .integer and number == actual.integer,
        .boolean => |flag| actual == .bool and flag == actual.bool,
        .object => |fields| blk: {
            const object = jsonObject(actual) orelse break :blk false;
            for (fields) |field| if (!jsonMatchesValue(field.value, object.get(field.name) orelse break :blk false)) break :blk false;
            break :blk true;
        },
        .list => |items| blk: {
            const array = jsonArray(actual) orelse break :blk false;
            if (items.len != array.items.len) break :blk false;
            for (items, array.items) |left, right| if (!jsonMatchesValue(left, right)) break :blk false;
            break :blk true;
        },
        .output_ref, .secret_ref, .unknown_reason => false,
    };
}
fn stringEquals(input: ?std.json.Value, expected: []const u8) bool {
    const actual = jsonString(input) orelse return false;
    return std.mem.eql(u8, actual, expected);
}
fn jsonObject(candidate: std.json.Value) ?std.json.ObjectMap {
    return if (candidate == .object) candidate.object else null;
}
fn jsonArray(candidate: std.json.Value) ?std.json.Array {
    return if (candidate == .array) candidate.array else null;
}
fn jsonString(candidate: ?std.json.Value) ?[]const u8 {
    const selected = candidate orelse return null;
    return if (selected == .string) selected.string else null;
}
