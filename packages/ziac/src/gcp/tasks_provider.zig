const std = @import("std");
const client_mod = @import("client.zig");
const rpc = @import("rpc.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;
const queue_type = "gcp.tasks.Queue";
const queue_iam_type = "gcp.tasks.QueueIamMember";

pub const Handler = struct {
    client: *client_mod.Client,
    iam_conflict_retries: usize = 3,

    pub fn read(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
        if (isIam(node)) return self.readIam(context, node);
        const expected = try physicalIdAlloc(context, node);
        defer context.allocator.free(expected);
        const physical = physical_override orelse expected;
        if (!std.mem.eql(u8, expected, physical)) return error.InvalidConfiguration;
        const path = try rpcPathAlloc(context, rpc.cloud_tasks_v2.get_queue, &.{.{ .field = "name", .value = physical }}, &.{});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .cloud_tasks, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try resultFromQueueJson(context, node, response.body) };
    }

    pub fn diff(context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        if (isIam(node)) {
            const changed = !std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash);
            return provider_mod.DiffResult.init(context.allocator, if (changed) .replace else .noop, if (changed) &.{"Cloud Tasks queue IAM member changed"} else &.{});
        }
        var immutable_changed = false;
        for ([_][]const u8{ "project_id", "location", "name" }) |field| {
            immutable_changed = immutable_changed or !std.mem.eql(u8, inputString(node.inputs, field) orelse "", inputString(observed.observed_inputs, field) orelse "");
        }
        const changed = !std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash);
        return provider_mod.DiffResult.init(
            context.allocator,
            if (!changed) .noop else if (immutable_changed) .replace else .update,
            if (changed) &.{"Cloud Tasks queue configuration differs"} else &.{},
        );
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        if (isIam(node)) return self.ensureIam(context, node, true);
        const parent = try std.fmt.allocPrint(context.allocator, "projects/{s}/locations/{s}", .{ try requiredString(node.inputs, "project_id"), try requiredString(node.inputs, "location") });
        defer context.allocator.free(parent);
        const path = try rpcPathAlloc(context, rpc.cloud_tasks_v2.create_queue, &.{.{ .field = "parent", .value = parent }}, &.{});
        defer context.allocator.free(path);
        const body = try queueBodyAlloc(context, node);
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .cloud_tasks, .method = "POST", .path = path, .body = body });
        defer response.deinit(context.allocator);
        return resultFromQueueJson(context, node, response.body);
    }

    pub fn update(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!provider_mod.ResourceResult {
        if (isIam(node)) return self.ensureIam(context, node, true);
        const expected = try physicalIdAlloc(context, node);
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        const path = try rpcPathAlloc(context, rpc.cloud_tasks_v2.update_queue, &.{.{ .field = "queue.name", .value = physical_id }}, &.{.{
            .field = "update_mask",
            .value = "httpTarget,rateLimits,retryConfig,stackdriverLoggingConfig",
        }});
        defer context.allocator.free(path);
        const body = try queueBodyAlloc(context, node);
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .cloud_tasks, .method = "PATCH", .path = path, .body = body });
        defer response.deinit(context.allocator);
        return resultFromQueueJson(context, node, response.body);
    }

    pub fn delete(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!void {
        if (isIam(node)) {
            var removed = try self.ensureIam(context, node, false);
            removed.deinit();
            return;
        }
        const expected = try physicalIdAlloc(context, node);
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        const path = try rpcPathAlloc(context, rpc.cloud_tasks_v2.delete_queue, &.{.{ .field = "name", .value = physical_id }}, &.{});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .cloud_tasks, .method = "DELETE", .path = path }) catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        response.deinit(context.allocator);
    }

    fn readIam(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ReadResult {
        const queue = try resolveString(context, try requiredValue(node.inputs, "queue"));
        const path = try rpcPathAlloc(context, rpc.cloud_tasks_v2.get_queue_iam_policy, &.{.{ .field = "resource", .value = queue }}, &.{.{
            .field = "requested_policy_version",
            .value = "3",
        }});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .cloud_tasks, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        if (!policyHasMember(parsed.value, node)) return .absent;
        return .{ .present = try iamResult(context, node, queue) };
    }

    fn ensureIam(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, should_exist: bool) ProviderError!provider_mod.ResourceResult {
        const queue = try resolveString(context, try requiredValue(node.inputs, "queue"));
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const get_path = try rpcPathAlloc(context, rpc.cloud_tasks_v2.get_queue_iam_policy, &.{.{ .field = "resource", .value = queue }}, &.{.{ .field = "requested_policy_version", .value = "3" }});
            defer context.allocator.free(get_path);
            var current = try self.request(context, .{ .api = .cloud_tasks, .method = "GET", .path = get_path });
            defer current.deinit(context.allocator);
            var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, current.body, .{}) catch return error.ProviderBug;
            defer parsed.deinit();
            const changed = try mutatePolicy(&parsed, node, should_exist);
            if (!changed) return iamResult(context, node, queue);
            const body = try policyBodyAlloc(context.allocator, parsed.value);
            defer context.allocator.free(body);
            const set_path = try rpcPathAlloc(context, rpc.cloud_tasks_v2.set_queue_iam_policy, &.{.{ .field = "resource", .value = queue }}, &.{});
            defer context.allocator.free(set_path);
            var response = self.request(context, .{ .api = .cloud_tasks, .method = "POST", .path = set_path, .body = body }) catch |err| {
                if (err == error.Conflict and attempt < self.iam_conflict_retries) continue;
                return err;
            };
            response.deinit(context.allocator);
            return iamResult(context, node, queue);
        }
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, request_value: client_mod.Request) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, request_value, &diagnostic);
    }
};

pub fn supports(node: resource.ResourceNode) bool {
    return isType(node, queue_type) or isType(node, queue_iam_type);
}

fn queueBodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root: std.json.ObjectMap = .empty;
    const physical = try physicalIdAlloc(context, node);
    defer context.allocator.free(physical);
    try root.put(arena, "name", .{ .string = physical });

    var rate_limits: std.json.ObjectMap = .empty;
    const dispatch_rate = std.fmt.parseFloat(f64, try requiredString(node.inputs, "max_dispatches_per_second")) catch return error.InvalidConfiguration;
    try rate_limits.put(arena, "maxDispatchesPerSecond", .{ .float = dispatch_rate });
    try rate_limits.put(arena, "maxConcurrentDispatches", .{ .integer = try requiredInteger(node.inputs, "max_concurrent_dispatches") });
    try root.put(arena, "rateLimits", .{ .object = rate_limits });

    var retry: std.json.ObjectMap = .empty;
    try retry.put(arena, "maxAttempts", .{ .integer = try requiredInteger(node.inputs, "max_attempts") });
    try retry.put(arena, "maxRetryDuration", .{ .string = try durationAlloc(arena, try requiredInteger(node.inputs, "max_retry_duration_seconds")) });
    try retry.put(arena, "minBackoff", .{ .string = try durationAlloc(arena, try requiredInteger(node.inputs, "min_backoff_seconds")) });
    try retry.put(arena, "maxBackoff", .{ .string = try durationAlloc(arena, try requiredInteger(node.inputs, "max_backoff_seconds")) });
    try retry.put(arena, "maxDoublings", .{ .integer = try requiredInteger(node.inputs, "max_doublings") });
    try root.put(arena, "retryConfig", .{ .object = retry });

    var logging: std.json.ObjectMap = .empty;
    const logging_ratio = std.fmt.parseFloat(f64, try requiredString(node.inputs, "logging_sample_ratio")) catch return error.InvalidConfiguration;
    try logging.put(arena, "samplingRatio", .{ .float = logging_ratio });
    try root.put(arena, "stackdriverLoggingConfig", .{ .object = logging });

    if (try requiredBool(node.inputs, "http_target_enabled")) {
        var target: std.json.ObjectMap = .empty;
        const method = try requiredString(node.inputs, "http_method");
        if (method.len > 0) try target.put(arena, "httpMethod", .{ .string = method });
        var override: std.json.ObjectMap = .empty;
        const scheme = try requiredString(node.inputs, "uri_scheme");
        if (scheme.len > 0) try override.put(arena, "scheme", .{ .string = scheme });
        const host = try requiredString(node.inputs, "uri_host");
        if (host.len > 0) try override.put(arena, "host", .{ .string = host });
        const port = try requiredInteger(node.inputs, "uri_port");
        if (port > 0) try override.put(arena, "port", .{ .string = try std.fmt.allocPrint(arena, "{d}", .{port}) });
        const path = try requiredString(node.inputs, "uri_path");
        if (path.len > 0) {
            var path_override: std.json.ObjectMap = .empty;
            try path_override.put(arena, "path", .{ .string = path });
            try override.put(arena, "pathOverride", .{ .object = path_override });
        }
        const query = try requiredString(node.inputs, "uri_query");
        if (query.len > 0) {
            var query_override: std.json.ObjectMap = .empty;
            try query_override.put(arena, "queryParams", .{ .string = query });
            try override.put(arena, "queryOverride", .{ .object = query_override });
        }
        const enforce = try requiredString(node.inputs, "uri_enforce_mode");
        if (enforce.len > 0) try override.put(arena, "uriOverrideEnforceMode", .{ .string = enforce });
        try target.put(arena, "uriOverride", .{ .object = override });

        const header_fields = try requiredObject(node.inputs, "http_headers");
        var header_overrides = std.json.Array.init(arena);
        for (header_fields) |header| {
            var entry: std.json.ObjectMap = .empty;
            var header_value: std.json.ObjectMap = .empty;
            try header_value.put(arena, "key", .{ .string = header.name });
            try header_value.put(arena, "value", .{ .string = switch (header.value) {
                .string => |text| text,
                else => return error.InvalidConfiguration,
            } });
            try entry.put(arena, "header", .{ .object = header_value });
            try header_overrides.append(.{ .object = entry });
        }
        if (header_overrides.items.len > 0) try target.put(arena, "headerOverrides", .{ .array = header_overrides });
        const auth_kind = try requiredString(node.inputs, "authorization_kind");
        if (!std.mem.eql(u8, auth_kind, "none")) {
            var token: std.json.ObjectMap = .empty;
            try token.put(arena, "serviceAccountEmail", .{ .string = try requiredString(node.inputs, "authorization_service_account") });
            if (std.mem.eql(u8, auth_kind, "oidc")) {
                try token.put(arena, "audience", .{ .string = try requiredString(node.inputs, "authorization_audience_or_scope") });
                try target.put(arena, "oidcToken", .{ .object = token });
            } else if (std.mem.eql(u8, auth_kind, "oauth")) {
                try token.put(arena, "scope", .{ .string = try requiredString(node.inputs, "authorization_audience_or_scope") });
                try target.put(arena, "oauthToken", .{ .object = token });
            } else return error.InvalidConfiguration;
        }
        try root.put(arena, "httpTarget", .{ .object = target });
    }
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch error.OutOfMemory;
}

fn resultFromQueueJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, body: []const u8) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const physical = jsonString(root.get("name")) orelse return error.ProviderBug;
    const expected = try physicalIdAlloc(context, node);
    defer context.allocator.free(expected);
    if (!std.mem.eql(u8, expected, physical)) return error.InvalidConfiguration;
    const outputs = [_]state.StateOutput{
        .{ .name = "name", .value = .{ .string = physical } },
        .{ .name = "state", .value = .{ .string = jsonString(root.get("state")) orelse "RUNNING" } },
        .{ .name = "purge_time", .value = .{ .string = jsonString(root.get("purgeTime")) orelse "" } },
    };
    var observed = try normalizedQueueInputsAlloc(context, node, root);
    defer observed.deinit(context.allocator);
    return provider_mod.ResourceResult.init(context.allocator, physical, observed, &outputs, null);
}

fn normalizedQueueInputsAlloc(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    remote: std.json.ObjectMap,
) ProviderError!value.Value {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rate_limits = jsonObject(remote.get("rateLimits") orelse return error.ProviderBug) orelse return error.ProviderBug;
    const retry = jsonObject(remote.get("retryConfig") orelse return error.ProviderBug) orelse return error.ProviderBug;
    const logging = jsonObject(remote.get("stackdriverLoggingConfig") orelse return error.ProviderBug) orelse return error.ProviderBug;
    var normalized: std.json.ObjectMap = .empty;
    try normalized.put(arena, "project_id", .{ .string = try requiredString(node.inputs, "project_id") });
    try normalized.put(arena, "location", .{ .string = try requiredString(node.inputs, "location") });
    try normalized.put(arena, "name", .{ .string = try requiredString(node.inputs, "name") });
    try normalized.put(arena, "max_dispatches_per_second", .{ .string = try jsonNumberStringAlloc(arena, rate_limits.get("maxDispatchesPerSecond")) });
    try normalized.put(arena, "max_concurrent_dispatches", .{ .integer = try jsonInteger(rate_limits.get("maxConcurrentDispatches")) });
    try normalized.put(arena, "max_attempts", .{ .integer = try jsonInteger(retry.get("maxAttempts")) });
    try normalized.put(arena, "max_retry_duration_seconds", .{ .integer = try durationSeconds(retry.get("maxRetryDuration")) });
    try normalized.put(arena, "min_backoff_seconds", .{ .integer = try durationSeconds(retry.get("minBackoff")) });
    try normalized.put(arena, "max_backoff_seconds", .{ .integer = try durationSeconds(retry.get("maxBackoff")) });
    try normalized.put(arena, "max_doublings", .{ .integer = try jsonInteger(retry.get("maxDoublings")) });
    try normalized.put(arena, "logging_sample_ratio", .{ .string = try jsonNumberStringAlloc(arena, logging.get("samplingRatio")) });

    var target_enabled = false;
    var method: []const u8 = "";
    var scheme: []const u8 = "";
    var host: []const u8 = "";
    var port: i64 = 0;
    var path: []const u8 = "";
    var query: []const u8 = "";
    var enforce_mode: []const u8 = "";
    var auth_kind: []const u8 = "none";
    var auth_service_account: []const u8 = "";
    var auth_audience_or_scope: []const u8 = "";
    var headers: std.json.ObjectMap = .empty;
    if (remote.get("httpTarget")) |target_value| {
        target_enabled = true;
        const target = jsonObject(target_value) orelse return error.ProviderBug;
        method = jsonString(target.get("httpMethod")) orelse "";
        if (target.get("uriOverride")) |override_value| {
            const uri_override = jsonObject(override_value) orelse return error.ProviderBug;
            scheme = jsonString(uri_override.get("scheme")) orelse "";
            host = jsonString(uri_override.get("host")) orelse "";
            if (jsonString(uri_override.get("port"))) |port_text| port = std.fmt.parseInt(i64, port_text, 10) catch return error.ProviderBug;
            if (uri_override.get("pathOverride")) |path_value| {
                const path_override = jsonObject(path_value) orelse return error.ProviderBug;
                path = jsonString(path_override.get("path")) orelse "";
            }
            if (uri_override.get("queryOverride")) |query_value| {
                const query_override = jsonObject(query_value) orelse return error.ProviderBug;
                query = jsonString(query_override.get("queryParams")) orelse "";
            }
            enforce_mode = jsonString(uri_override.get("uriOverrideEnforceMode")) orelse "";
        }
        if (target.get("headerOverrides")) |headers_value| {
            const overrides = jsonArray(headers_value) orelse return error.ProviderBug;
            for (overrides.items) |entry_value| {
                const entry = jsonObject(entry_value) orelse return error.ProviderBug;
                const header = jsonObject(entry.get("header") orelse return error.ProviderBug) orelse return error.ProviderBug;
                const key = jsonString(header.get("key")) orelse return error.ProviderBug;
                if (headers.get(key) != null) return error.ProviderBug;
                try headers.put(arena, key, .{ .string = jsonString(header.get("value")) orelse return error.ProviderBug });
            }
        }
        if (target.get("oidcToken")) |token_value| {
            const token = jsonObject(token_value) orelse return error.ProviderBug;
            auth_kind = "oidc";
            auth_service_account = jsonString(token.get("serviceAccountEmail")) orelse return error.ProviderBug;
            auth_audience_or_scope = jsonString(token.get("audience")) orelse "";
        } else if (target.get("oauthToken")) |token_value| {
            const token = jsonObject(token_value) orelse return error.ProviderBug;
            auth_kind = "oauth";
            auth_service_account = jsonString(token.get("serviceAccountEmail")) orelse return error.ProviderBug;
            auth_audience_or_scope = jsonString(token.get("scope")) orelse "";
        }
    }
    try normalized.put(arena, "http_target_enabled", .{ .bool = target_enabled });
    try normalized.put(arena, "http_method", .{ .string = method });
    try normalized.put(arena, "http_headers", .{ .object = headers });
    try normalized.put(arena, "uri_scheme", .{ .string = scheme });
    try normalized.put(arena, "uri_host", .{ .string = host });
    try normalized.put(arena, "uri_port", .{ .integer = port });
    try normalized.put(arena, "uri_path", .{ .string = path });
    try normalized.put(arena, "uri_query", .{ .string = query });
    try normalized.put(arena, "uri_enforce_mode", .{ .string = enforce_mode });
    try normalized.put(arena, "authorization_kind", .{ .string = auth_kind });
    try normalized.put(arena, "authorization_service_account", .{ .string = auth_service_account });
    try normalized.put(arena, "authorization_audience_or_scope", .{ .string = auth_audience_or_scope });

    const json = std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = normalized }, .{}) catch return error.OutOfMemory;
    defer context.allocator.free(json);
    return value.Value.parseJsonAlloc(context.allocator, json) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ProviderBug,
    };
}

fn physicalIdAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError![]const u8 {
    if (isIam(node)) {
        const queue = try resolveString(context, try requiredValue(node.inputs, "queue"));
        return std.fmt.allocPrint(context.allocator, "{s}/iam/{s}", .{ queue, try requiredString(node.inputs, "name") }) catch error.OutOfMemory;
    }
    return std.fmt.allocPrint(context.allocator, "projects/{s}/locations/{s}/queues/{s}", .{
        try requiredString(node.inputs, "project_id"),
        try requiredString(node.inputs, "location"),
        try requiredString(node.inputs, "name"),
    }) catch error.OutOfMemory;
}

fn iamResult(context: *provider_mod.OperationContext, node: resource.ResourceNode, queue: []const u8) ProviderError!provider_mod.ResourceResult {
    const physical = try std.fmt.allocPrint(context.allocator, "{s}/iam/{s}", .{ queue, try requiredString(node.inputs, "name") });
    defer context.allocator.free(physical);
    const outputs = [_]state.StateOutput{.{ .name = "binding_id", .value = .{ .string = physical } }};
    return provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &outputs, null);
}

fn policyBodyAlloc(allocator: std.mem.Allocator, policy: std.json.Value) ProviderError![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var wrapper: std.json.ObjectMap = .empty;
    try wrapper.put(arena.allocator(), "policy", policy);
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = wrapper }, .{}) catch error.OutOfMemory;
}

fn policyHasMember(policy: std.json.Value, node: resource.ResourceNode) bool {
    const root = jsonObject(policy) orelse return false;
    const bindings = jsonArray(root.get("bindings")) orelse return false;
    for (bindings.items) |candidate| {
        const binding = jsonObject(candidate) orelse continue;
        if (!stringEquals(binding.get("role"), inputString(node.inputs, "role") orelse return false)) continue;
        const members = jsonArray(binding.get("members")) orelse continue;
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
    const role = try requiredString(node.inputs, "role");
    const member = try requiredString(node.inputs, "member");
    for (bindings.items, 0..) |*binding_value, binding_index| {
        const binding = switch (binding_value.*) {
            .object => |*object| object,
            else => continue,
        };
        if (!stringEquals(binding.get("role"), role)) continue;
        const members_value = binding.getPtr("members") orelse return error.ProviderBug;
        const members = switch (members_value.*) {
            .array => |*array| array,
            else => return error.ProviderBug,
        };
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
    try members.append(.{ .string = member });
    var binding: std.json.ObjectMap = .empty;
    try binding.put(allocator, "role", .{ .string = role });
    try binding.put(allocator, "members", .{ .array = members });
    try bindings.append(.{ .object = binding });
    return true;
}

fn rpcPathAlloc(context: *provider_mod.OperationContext, method: rpc.Method, path_parameters: []const rpc.Parameter, query_parameters: []const rpc.Parameter) ProviderError![]u8 {
    return rpc.restPathAlloc(context.allocator, method, path_parameters, query_parameters) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ProviderBug,
    };
}

fn durationAlloc(allocator: std.mem.Allocator, seconds: i64) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}s", .{seconds}) catch error.OutOfMemory;
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
fn requiredInteger(input: value.Value, name: []const u8) ProviderError!i64 {
    return switch (try requiredValue(input, name)) {
        .integer => |number| number,
        else => error.InvalidConfiguration,
    };
}
fn requiredBool(input: value.Value, name: []const u8) ProviderError!bool {
    return switch (try requiredValue(input, name)) {
        .boolean => |present| present,
        else => error.InvalidConfiguration,
    };
}
fn requiredObject(input: value.Value, name: []const u8) ProviderError![]const value.Field {
    return switch (try requiredValue(input, name)) {
        .object => |fields| fields,
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
fn jsonObject(input: std.json.Value) ?std.json.ObjectMap {
    return switch (input) {
        .object => |object| object,
        else => null,
    };
}
fn jsonArray(input: ?std.json.Value) ?std.json.Array {
    const present = input orelse return null;
    return switch (present) {
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
fn jsonInteger(input: ?std.json.Value) ProviderError!i64 {
    const present = input orelse return error.ProviderBug;
    return switch (present) {
        .integer => |number| number,
        .float => |number| std.math.lossyCast(i64, number),
        else => error.ProviderBug,
    };
}
fn jsonNumberStringAlloc(allocator: std.mem.Allocator, input: ?std.json.Value) ProviderError![]const u8 {
    const present = input orelse return error.ProviderBug;
    return switch (present) {
        .integer => |number| std.fmt.allocPrint(allocator, "{d}", .{number}) catch error.OutOfMemory,
        .float => |number| std.fmt.allocPrint(allocator, "{d}", .{number}) catch error.OutOfMemory,
        else => error.ProviderBug,
    };
}
fn durationSeconds(input: ?std.json.Value) ProviderError!i64 {
    const text = jsonString(input) orelse return error.ProviderBug;
    if (text.len < 2 or text[text.len - 1] != 's') return error.ProviderBug;
    return std.fmt.parseInt(i64, text[0 .. text.len - 1], 10) catch error.ProviderBug;
}
fn stringEquals(input: ?std.json.Value, expected: []const u8) bool {
    return if (jsonString(input)) |actual| std.mem.eql(u8, actual, expected) else false;
}
fn isIam(node: resource.ResourceNode) bool {
    return isType(node, queue_iam_type);
}
fn isType(node: resource.ResourceNode, type_name: []const u8) bool {
    return std.mem.eql(u8, node.type_name, type_name);
}
