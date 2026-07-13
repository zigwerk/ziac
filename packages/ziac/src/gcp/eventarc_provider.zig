const std = @import("std");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const rpc = @import("rpc.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;
const trigger_type = "gcp.eventarc.Trigger";
const update_mask = "eventFilters,serviceAccount,destination,transport,labels,channel,eventDataContentType,retryPolicy";

pub const Handler = struct {
    client: *client_mod.Client,
    operation_policy: operation.Policy,

    pub fn read(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
        if (context.operation_handle) |handle| {
            if (try self.waitForTrigger(context, node, handle)) |result| return .{ .present = result };
        }
        const expected = try physicalIdAlloc(context.allocator, node);
        defer context.allocator.free(expected);
        const physical = physical_override orelse expected;
        if (!std.mem.eql(u8, expected, physical)) return error.InvalidConfiguration;
        const path = try rpcPathAlloc(context, rpc.eventarc_v1.get_trigger, &.{.{ .field = "name", .value = physical }}, &.{});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .eventarc, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try resultFromTriggerJson(context, node, response.body) };
    }

    pub fn diff(context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        var immutable_changed = false;
        for ([_][]const u8{ "project_id", "location", "name" }) |field| {
            immutable_changed = immutable_changed or !std.mem.eql(u8, inputString(node.inputs, field) orelse "", inputString(observed.observed_inputs, field) orelse "");
        }
        const changed = !std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash);
        return provider_mod.DiffResult.init(context.allocator, if (!changed) .noop else if (immutable_changed) .replace else .update, if (changed) &.{"Eventarc trigger configuration differs"} else &.{});
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        const parent = try std.fmt.allocPrint(context.allocator, "projects/{s}/locations/{s}", .{ try requiredString(node.inputs, "project_id"), try requiredString(node.inputs, "location") });
        defer context.allocator.free(parent);
        const path = try rpcPathAlloc(context, rpc.eventarc_v1.create_trigger, &.{.{ .field = "parent", .value = parent }}, &.{
            .{ .field = "trigger_id", .value = try requiredString(node.inputs, "name") },
            .{ .field = "validate_only", .value = "false" },
        });
        defer context.allocator.free(path);
        const body = try triggerBodyAlloc(context, node, null);
        defer context.allocator.free(body);
        const handle = try self.startOperation(context, "POST", path, body);
        defer context.allocator.free(handle);
        return pendingResult(context, node, handle);
    }

    pub fn update(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        const etag = outputString(observed, "etag") orelse return error.Conflict;
        const path = try rpcPathAlloc(context, rpc.eventarc_v1.update_trigger, &.{.{ .field = "trigger.name", .value = observed.physical_id }}, &.{
            .{ .field = "update_mask", .value = update_mask },
            .{ .field = "allow_missing", .value = "false" },
            .{ .field = "validate_only", .value = "false" },
        });
        defer context.allocator.free(path);
        const body = try triggerBodyAlloc(context, node, etag);
        defer context.allocator.free(body);
        const handle = try self.startOperation(context, "PATCH", path, body);
        defer context.allocator.free(handle);
        return pendingResult(context, node, handle);
    }

    pub fn delete(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!void {
        const expected = try physicalIdAlloc(context.allocator, node);
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        const get_path = try rpcPathAlloc(context, rpc.eventarc_v1.get_trigger, &.{.{ .field = "name", .value = physical_id }}, &.{});
        defer context.allocator.free(get_path);
        var current = self.request(context, .{ .api = .eventarc, .method = "GET", .path = get_path }) catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer current.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, current.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const root = jsonObject(parsed.value) orelse return error.ProviderBug;
        const etag = jsonString(root.get("etag")) orelse return error.Conflict;
        const path = try rpcPathAlloc(context, rpc.eventarc_v1.delete_trigger, &.{.{ .field = "name", .value = physical_id }}, &.{
            .{ .field = "etag", .value = etag },
            .{ .field = "allow_missing", .value = "true" },
            .{ .field = "validate_only", .value = "false" },
        });
        defer context.allocator.free(path);
        const handle = self.startOperation(context, "DELETE", path, "") catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer context.allocator.free(handle);
        _ = try self.waitForTrigger(context, null, handle);
    }

    fn startOperation(self: Handler, context: *provider_mod.OperationContext, method: []const u8, path: []const u8, body: []const u8) ProviderError![]const u8 {
        var response = try self.request(context, .{ .api = .eventarc, .method = method, .path = path, .body = body });
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const root = jsonObject(parsed.value) orelse return error.ProviderBug;
        const name = jsonString(root.get("name")) orelse return error.ProviderBug;
        return context.allocator.dupe(u8, name) catch error.OutOfMemory;
    }

    fn waitForTrigger(self: Handler, context: *provider_mod.OperationContext, maybe_node: ?resource.ResourceNode, handle: []const u8) ProviderError!?provider_mod.ResourceResult {
        const base = try std.fmt.allocPrint(context.allocator, "{s}/v1", .{std.mem.trimEnd(u8, self.client.endpoints.eventarc, "/")});
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
        return try resultFromTriggerJson(context, node, body);
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, request_value: client_mod.Request) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, request_value, &diagnostic);
    }
};

pub fn supports(node: resource.ResourceNode) bool {
    return std.mem.eql(u8, node.type_name, trigger_type);
}

fn triggerBodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, etag: ?[]const u8) ProviderError![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root: std.json.ObjectMap = .empty;
    const name = try physicalIdAlloc(context.allocator, node);
    defer context.allocator.free(name);
    try root.put(arena, "name", .{ .string = name });
    if (etag) |present| try root.put(arena, "etag", .{ .string = present });
    try root.put(arena, "serviceAccount", .{ .string = try requiredString(node.inputs, "service_account") });
    try root.put(arena, "eventDataContentType", .{ .string = try requiredString(node.inputs, "event_data_content_type") });
    const channel = try requiredString(node.inputs, "channel");
    if (channel.len > 0) try root.put(arena, "channel", .{ .string = channel });

    var filters = std.json.Array.init(arena);
    const desired_filters = try requiredList(node.inputs, "event_filters");
    for (desired_filters) |filter_value| {
        if (filter_value != .object) return error.InvalidConfiguration;
        var filter: std.json.ObjectMap = .empty;
        try filter.put(arena, "attribute", .{ .string = try requiredString(filter_value, "attribute") });
        try filter.put(arena, "value", .{ .string = try requiredString(filter_value, "value") });
        const internal_operator = try requiredString(filter_value, "operator");
        if (internal_operator.len > 0) {
            const wire = if (std.mem.eql(u8, internal_operator, "MATCH_PATH_PATTERN")) "match-path-pattern" else if (std.mem.eql(u8, internal_operator, "PATH_PATTERN")) "path_pattern" else return error.InvalidConfiguration;
            try filter.put(arena, "operator", .{ .string = wire });
        }
        try filters.append(.{ .object = filter });
    }
    try root.put(arena, "eventFilters", .{ .array = filters });

    var destination: std.json.ObjectMap = .empty;
    const kind = try requiredString(node.inputs, "destination_kind");
    if (std.mem.eql(u8, kind, "cloud_run")) {
        var target: std.json.ObjectMap = .empty;
        try target.put(arena, "service", .{ .string = try requiredString(node.inputs, "destination_primary") });
        try target.put(arena, "region", .{ .string = try requiredString(node.inputs, "destination_secondary") });
        const path = try requiredString(node.inputs, "destination_path");
        if (path.len > 0) try target.put(arena, "path", .{ .string = path });
        try destination.put(arena, "cloudRun", .{ .object = target });
    } else if (std.mem.eql(u8, kind, "gke")) {
        var target: std.json.ObjectMap = .empty;
        try target.put(arena, "cluster", .{ .string = try requiredString(node.inputs, "destination_primary") });
        try target.put(arena, "location", .{ .string = try requiredString(node.inputs, "destination_secondary") });
        try target.put(arena, "namespace", .{ .string = try requiredString(node.inputs, "destination_tertiary") });
        try target.put(arena, "service", .{ .string = try requiredString(node.inputs, "destination_network_attachment") });
        const path = try requiredString(node.inputs, "destination_path");
        if (path.len > 0) try target.put(arena, "path", .{ .string = path });
        try destination.put(arena, "gke", .{ .object = target });
    } else if (std.mem.eql(u8, kind, "workflow")) {
        try destination.put(arena, "workflow", .{ .string = try requiredString(node.inputs, "destination_primary") });
    } else if (std.mem.eql(u8, kind, "http_endpoint")) {
        var endpoint: std.json.ObjectMap = .empty;
        try endpoint.put(arena, "uri", .{ .string = try requiredString(node.inputs, "destination_primary") });
        try destination.put(arena, "httpEndpoint", .{ .object = endpoint });
        var network: std.json.ObjectMap = .empty;
        try network.put(arena, "networkAttachment", .{ .string = try requiredString(node.inputs, "destination_network_attachment") });
        try destination.put(arena, "networkConfig", .{ .object = network });
    } else return error.InvalidConfiguration;
    try root.put(arena, "destination", .{ .object = destination });

    const transport_topic = try resolveString(context, try requiredValue(node.inputs, "transport_topic"));
    if (transport_topic.len > 0) {
        var pubsub: std.json.ObjectMap = .empty;
        try pubsub.put(arena, "topic", .{ .string = transport_topic });
        var transport: std.json.ObjectMap = .empty;
        try transport.put(arena, "pubsub", .{ .object = pubsub });
        try root.put(arena, "transport", .{ .object = transport });
    }
    var labels: std.json.ObjectMap = .empty;
    for (try requiredObject(node.inputs, "labels")) |label| {
        const text = switch (label.value) {
            .string => |present| present,
            else => return error.InvalidConfiguration,
        };
        try labels.put(arena, label.name, .{ .string = text });
    }
    if (labels.count() > 0) try root.put(arena, "labels", .{ .object = labels });
    const max_attempts = try requiredInteger(node.inputs, "retry_max_attempts");
    if (max_attempts > 0) {
        var retry: std.json.ObjectMap = .empty;
        try retry.put(arena, "maxAttempts", .{ .integer = max_attempts });
        try root.put(arena, "retryPolicy", .{ .object = retry });
    }
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch error.OutOfMemory;
}

fn resultFromTriggerJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, body: []const u8) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const physical = jsonString(root.get("name")) orelse return error.ProviderBug;
    const expected = try physicalIdAlloc(context.allocator, node);
    defer context.allocator.free(expected);
    if (!std.mem.eql(u8, expected, physical)) return error.InvalidConfiguration;
    if (root.get("conditions")) |conditions_value| {
        const conditions = jsonObject(conditions_value) orelse return error.ProviderBug;
        if (failedCondition(conditions)) return error.RemoteOperationFailed;
    }
    var transport_topic: []const u8 = "";
    var transport_subscription: []const u8 = "";
    if (root.get("transport")) |transport_value| {
        const transport = jsonObject(transport_value) orelse return error.ProviderBug;
        if (transport.get("pubsub")) |pubsub_value| {
            const pubsub = jsonObject(pubsub_value) orelse return error.ProviderBug;
            transport_topic = jsonString(pubsub.get("topic")) orelse "";
            transport_subscription = jsonString(pubsub.get("subscription")) orelse "";
        }
    }
    const outputs = [_]state.StateOutput{
        .{ .name = "name", .value = .{ .string = physical } },
        .{ .name = "uid", .value = .{ .string = jsonString(root.get("uid")) orelse "" } },
        .{ .name = "transport_topic", .value = .{ .string = transport_topic } },
        .{ .name = "transport_subscription", .value = .{ .string = transport_subscription } },
        .{ .name = "etag", .value = .{ .string = jsonString(root.get("etag")) orelse "" } },
        .{ .name = "ready", .value = .{ .boolean = true } },
    };
    var observed = try normalizedTriggerInputsAlloc(context, node, root, transport_topic);
    defer observed.deinit(context.allocator);
    return provider_mod.ResourceResult.init(context.allocator, physical, observed, &outputs, null);
}

fn normalizedTriggerInputsAlloc(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    remote: std.json.ObjectMap,
    transport_topic: []const u8,
) ProviderError!value.Value {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var normalized: std.json.ObjectMap = .empty;
    try normalized.put(arena, "project_id", .{ .string = try requiredString(node.inputs, "project_id") });
    try normalized.put(arena, "location", .{ .string = try requiredString(node.inputs, "location") });
    try normalized.put(arena, "name", .{ .string = try requiredString(node.inputs, "name") });
    try normalized.put(arena, "service_account", .{ .string = jsonString(remote.get("serviceAccount")) orelse return error.ProviderBug });
    try normalized.put(arena, "channel", .{ .string = jsonString(remote.get("channel")) orelse "" });
    try normalized.put(arena, "event_data_content_type", .{ .string = jsonString(remote.get("eventDataContentType")) orelse "application/json" });

    const remote_filters = jsonArray(remote.get("eventFilters")) orelse return error.ProviderBug;
    var filters = std.json.Array.init(arena);
    for (remote_filters.items) |filter_value| {
        const remote_filter = jsonObject(filter_value) orelse return error.ProviderBug;
        var filter: std.json.ObjectMap = .empty;
        try filter.put(arena, "attribute", .{ .string = jsonString(remote_filter.get("attribute")) orelse return error.ProviderBug });
        try filter.put(arena, "value", .{ .string = jsonString(remote_filter.get("value")) orelse return error.ProviderBug });
        const wire_operator = jsonString(remote_filter.get("operator")) orelse "";
        const internal_operator = if (wire_operator.len == 0)
            ""
        else if (std.mem.eql(u8, wire_operator, "match-path-pattern"))
            "MATCH_PATH_PATTERN"
        else if (std.mem.eql(u8, wire_operator, "path_pattern"))
            "PATH_PATTERN"
        else
            return error.ProviderBug;
        try filter.put(arena, "operator", .{ .string = internal_operator });
        try filters.append(.{ .object = filter });
    }
    try normalized.put(arena, "event_filters", .{ .array = filters });

    const remote_destination = jsonObject(remote.get("destination") orelse return error.ProviderBug) orelse return error.ProviderBug;
    var destination_kind: []const u8 = "";
    var destination_primary: []const u8 = "";
    var destination_secondary: []const u8 = "";
    var destination_tertiary: []const u8 = "";
    var destination_path: []const u8 = "";
    var destination_network_attachment: []const u8 = "";
    if (remote_destination.get("cloudRun")) |target_value| {
        const target = jsonObject(target_value) orelse return error.ProviderBug;
        destination_kind = "cloud_run";
        destination_primary = jsonString(target.get("service")) orelse return error.ProviderBug;
        destination_secondary = jsonString(target.get("region")) orelse return error.ProviderBug;
        destination_path = jsonString(target.get("path")) orelse "";
    } else if (remote_destination.get("gke")) |target_value| {
        const target = jsonObject(target_value) orelse return error.ProviderBug;
        destination_kind = "gke";
        destination_primary = jsonString(target.get("cluster")) orelse return error.ProviderBug;
        destination_secondary = jsonString(target.get("location")) orelse return error.ProviderBug;
        destination_tertiary = jsonString(target.get("namespace")) orelse return error.ProviderBug;
        destination_network_attachment = jsonString(target.get("service")) orelse return error.ProviderBug;
        destination_path = jsonString(target.get("path")) orelse "";
    } else if (jsonString(remote_destination.get("workflow"))) |workflow| {
        destination_kind = "workflow";
        destination_primary = workflow;
    } else if (remote_destination.get("httpEndpoint")) |target_value| {
        const target = jsonObject(target_value) orelse return error.ProviderBug;
        destination_kind = "http_endpoint";
        destination_primary = jsonString(target.get("uri")) orelse return error.ProviderBug;
        if (remote_destination.get("networkConfig")) |network_value| {
            const network = jsonObject(network_value) orelse return error.ProviderBug;
            destination_network_attachment = jsonString(network.get("networkAttachment")) orelse "";
        }
    } else return error.ProviderBug;
    try normalized.put(arena, "destination_kind", .{ .string = destination_kind });
    try normalized.put(arena, "destination_primary", .{ .string = destination_primary });
    try normalized.put(arena, "destination_secondary", .{ .string = destination_secondary });
    try normalized.put(arena, "destination_tertiary", .{ .string = destination_tertiary });
    try normalized.put(arena, "destination_path", .{ .string = destination_path });
    try normalized.put(arena, "destination_network_attachment", .{ .string = destination_network_attachment });

    try normalized.put(arena, "transport_topic", try preservedStringJson(context, arena, node, "transport_topic", transport_topic));
    try normalized.put(arena, "labels", remote.get("labels") orelse .{ .object = .empty });
    var retry_max_attempts: i64 = 0;
    if (remote.get("retryPolicy")) |retry_value| {
        const retry = jsonObject(retry_value) orelse return error.ProviderBug;
        retry_max_attempts = jsonInteger(retry.get("maxAttempts")) orelse return error.ProviderBug;
    }
    try normalized.put(arena, "retry_max_attempts", .{ .integer = retry_max_attempts });

    const json = std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = normalized }, .{}) catch return error.OutOfMemory;
    defer context.allocator.free(json);
    return value.Value.parseJsonAlloc(context.allocator, json) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ProviderBug,
    };
}

fn preservedStringJson(
    context: *provider_mod.OperationContext,
    arena: std.mem.Allocator,
    node: resource.ResourceNode,
    field: []const u8,
    remote: []const u8,
) ProviderError!std.json.Value {
    const desired = try requiredValue(node.inputs, field);
    if (!std.mem.eql(u8, try resolveString(context, desired), remote)) return .{ .string = remote };
    return switch (desired) {
        .string => |text| .{ .string = text },
        .output_ref => |reference| output: {
            var descriptor: std.json.ObjectMap = .empty;
            try descriptor.put(arena, "resource", .{ .string = reference.resource_id });
            try descriptor.put(arena, "field", .{ .string = reference.field });
            var wrapper: std.json.ObjectMap = .empty;
            try wrapper.put(arena, "$output", .{ .object = descriptor });
            break :output .{ .object = wrapper };
        },
        else => error.InvalidConfiguration,
    };
}

fn failedCondition(conditions: std.json.ObjectMap) bool {
    var iterator = conditions.iterator();
    while (iterator.next()) |entry| {
        const condition = jsonObject(entry.value_ptr.*) orelse return true;
        const code = condition.get("code") orelse return true;
        const successful = switch (code) {
            .integer => |number| number == 0,
            .string => |text| std.mem.eql(u8, text, "OK") or std.mem.eql(u8, text, "0"),
            else => false,
        };
        if (!successful) return true;
    }
    return false;
}

fn pendingResult(context: *provider_mod.OperationContext, node: resource.ResourceNode, handle: []const u8) ProviderError!provider_mod.ResourceResult {
    const physical = try physicalIdAlloc(context.allocator, node);
    defer context.allocator.free(physical);
    const outputs = [_]state.StateOutput{
        .{ .name = "name", .value = .{ .string = physical } },
        .{ .name = "uid", .value = .{ .unknown_reason = "Eventarc operation pending" } },
        .{ .name = "transport_topic", .value = .{ .unknown_reason = "Eventarc operation pending" } },
        .{ .name = "transport_subscription", .value = .{ .unknown_reason = "Eventarc operation pending" } },
        .{ .name = "etag", .value = .{ .unknown_reason = "Eventarc operation pending" } },
        .{ .name = "ready", .value = .{ .boolean = false } },
    };
    var result = try provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &outputs, handle);
    result.completed = false;
    return result;
}

fn physicalIdAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}/triggers/{s}", .{
        try requiredString(node.inputs, "project_id"),
        try requiredString(node.inputs, "location"),
        try requiredString(node.inputs, "name"),
    }) catch error.OutOfMemory;
}

fn rpcPathAlloc(context: *provider_mod.OperationContext, method: rpc.Method, path_parameters: []const rpc.Parameter, query_parameters: []const rpc.Parameter) ProviderError![]u8 {
    return rpc.restPathAlloc(context.allocator, method, path_parameters, query_parameters) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ProviderBug,
    };
}
fn outputString(result: *const provider_mod.ResourceResult, name: []const u8) ?[]const u8 {
    for (result.outputs) |entry| if (std.mem.eql(u8, entry.name, name)) return switch (entry.value) {
        .string => |text| text,
        else => null,
    };
    return null;
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
fn requiredObject(input: value.Value, name: []const u8) ProviderError![]const value.Field {
    return switch (try requiredValue(input, name)) {
        .object => |fields| fields,
        else => error.InvalidConfiguration,
    };
}
fn requiredList(input: value.Value, name: []const u8) ProviderError![]const value.Value {
    return switch (try requiredValue(input, name)) {
        .list => |items| items,
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
fn jsonInteger(input: ?std.json.Value) ?i64 {
    const present = input orelse return null;
    return switch (present) {
        .integer => |number| number,
        else => null,
    };
}
