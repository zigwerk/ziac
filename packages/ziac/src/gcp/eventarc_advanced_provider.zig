const std = @import("std");
const aip = @import("aip.zig");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;
const Kind = enum { message_bus, pipeline, enrollment, google_api_source };

pub const Handler = struct {
    client: *client_mod.Client,
    operation_policy: operation.Policy = .{},

    pub fn supports(node: resource.ResourceNode) bool {
        return kindOf(node) != null;
    }

    pub fn read(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        const expected = try physicalAlloc(context.allocator, node, kind);
        defer context.allocator.free(expected);
        const physical = physical_override orelse context.physical_id orelse expected;
        try validatePhysical(node, kind, physical);
        if (context.operation_handle) |handle| {
            var completed = try self.waitOperation(context, handle);
            defer completed.deinit(context.allocator);
            if (try operationResponseAlloc(context.allocator, completed.payload)) |response_json| {
                defer context.allocator.free(response_json);
                return .{ .present = try resultFromJson(context, node, kind, physical, response_json) };
            }
        }
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical});
        defer context.allocator.free(path);
        var response = self.request(context, "GET", path, "") catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try resultFromJson(context, node, kind, physical, response.body) };
    }

    pub fn diff(context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(node, kind, observed.physical_id);
        if (identityChanged(node, observed, identityFields(kind)))
            return provider_mod.DiffResult.init(context.allocator, .replace, &.{"Eventarc Advanced identity changed"});
        const desired_json = try bodyAlloc(context, node, kind, null);
        defer context.allocator.free(desired_json);
        const remote_json = outputString(observed.*, "__remote_spec") orelse return provider_mod.DiffResult.init(context.allocator, .update, &.{"Eventarc Advanced configuration differs"});
        const mask = try changedMaskAlloc(context.allocator, desired_json, remote_json);
        defer context.allocator.free(mask);
        if (mask.len == 0) return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        if ((kind == .message_bus or kind == .google_api_source) and containsMask(mask, "cryptoKeyName"))
            return provider_mod.DiffResult.init(context.allocator, .replace, &.{"Eventarc Advanced CMEK changed"});
        return provider_mod.DiffResult.init(context.allocator, .update, &.{"Eventarc Advanced configuration differs"});
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        const path = try createPathAlloc(context.allocator, node, kind);
        defer context.allocator.free(path);
        const body = try bodyAlloc(context, node, kind, null);
        defer context.allocator.free(body);
        var response = try self.request(context, "POST", path, body);
        defer response.deinit(context.allocator);
        return pendingResult(context, node, kind, response.body);
    }

    pub fn update(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(node, kind, observed.physical_id);
        var classification = try Handler.diff(context, node, observed);
        defer classification.deinit();
        if (classification.kind == .noop) return observed.clone(context.allocator);
        if (classification.kind != .update) return error.InvalidConfiguration;
        const desired_json = try bodyAlloc(context, node, kind, null);
        defer context.allocator.free(desired_json);
        const remote_json = outputString(observed.*, "__remote_spec") orelse return error.InvalidConfiguration;
        const mask = try changedMaskAlloc(context.allocator, desired_json, remote_json);
        defer context.allocator.free(mask);
        const encoded_mask = try percentEncodeAlloc(context.allocator, mask);
        defer context.allocator.free(encoded_mask);
        const etag = outputString(observed.*, "etag") orelse return error.Conflict;
        var request_id: [36]u8 = undefined;
        aip.requestId("ziac", node.id, "update", &request_id);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}?updateMask={s}&requestId={s}", .{ observed.physical_id, encoded_mask, request_id[0..] });
        defer context.allocator.free(path);
        const body = try bodyAlloc(context, node, kind, etag);
        defer context.allocator.free(body);
        var response = try self.request(context, "PATCH", path, body);
        defer response.deinit(context.allocator);
        return pendingResult(context, node, kind, response.body);
    }

    pub fn delete(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical: []const u8) ProviderError!void {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(node, kind, physical);
        if (!std.mem.eql(u8, try requiredString(node.inputs, "removal_policy"), "delete") or !context.destructive_confirmation) return error.DestructiveConfirmationRequired;
        var current = try self.read(context, node, physical);
        defer current.deinit();
        const etag = switch (current) {
            .absent => return,
            .present => |present| outputString(present, "etag") orelse return error.Conflict,
        };
        const encoded_etag = try percentEncodeAlloc(context.allocator, etag);
        defer context.allocator.free(encoded_etag);
        var request_id: [36]u8 = undefined;
        aip.requestId("ziac", node.id, "delete", &request_id);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}?etag={s}&requestId={s}", .{ physical, encoded_etag, request_id[0..] });
        defer context.allocator.free(path);
        var response = self.request(context, "DELETE", path, "") catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer response.deinit(context.allocator);
        const handle = try operationNameAlloc(context.allocator, response.body);
        defer context.allocator.free(handle);
        var completed = try self.waitOperation(context, handle);
        completed.deinit(context.allocator);
    }

    pub fn importResource(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical: []const u8) ProviderError!provider_mod.ResourceResult {
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(node, kind, physical);
        var result = try self.read(context, node, physical);
        defer result.deinit();
        return switch (result) {
            .absent => error.NotFound,
            .present => |present| present.clone(context.allocator),
        };
    }

    fn waitOperation(self: Handler, context: *provider_mod.OperationContext, handle: []const u8) ProviderError!operation.Result {
        const base = try std.fmt.allocPrint(context.allocator, "{s}/v1", .{std.mem.trimEnd(u8, self.client.endpoints.eventarc, "/")});
        defer context.allocator.free(base);
        var target = operation.Target.genericAlloc(context.allocator, base, handle) catch return error.OutOfMemory;
        defer target.deinit(context.allocator);
        return operation.waitAlloc(self.client, context, target, self.operation_policy);
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, method: []const u8, path: []const u8, body: []const u8) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, .{ .api = .eventarc, .method = method, .path = path, .body = body }, &diagnostic);
    }
};

fn kindOf(node: resource.ResourceNode) ?Kind {
    const mappings = [_]struct { type_name: []const u8, kind: Kind }{
        .{ .type_name = "gcp.eventarc.MessageBus", .kind = .message_bus },
        .{ .type_name = "gcp.eventarc.Pipeline", .kind = .pipeline },
        .{ .type_name = "gcp.eventarc.Enrollment", .kind = .enrollment },
        .{ .type_name = "gcp.eventarc.GoogleApiSource", .kind = .google_api_source },
    };
    for (mappings) |mapping| if (std.mem.eql(u8, node.type_name, mapping.type_name)) return mapping.kind;
    return null;
}
fn collection(kind: Kind) []const u8 {
    return switch (kind) {
        .message_bus => "messageBuses",
        .pipeline => "pipelines",
        .enrollment => "enrollments",
        .google_api_source => "googleApiSources",
    };
}
fn idParameter(kind: Kind) []const u8 {
    return switch (kind) {
        .message_bus => "messageBusId",
        .pipeline => "pipelineId",
        .enrollment => "enrollmentId",
        .google_api_source => "googleApiSourceId",
    };
}
fn physicalAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}/{s}/{s}", .{ try requiredString(node.inputs, "project_id"), try requiredString(node.inputs, "location"), collection(kind), try requiredString(node.inputs, "name") }) catch error.OutOfMemory;
}
fn validatePhysical(node: resource.ResourceNode, kind: Kind, physical: []const u8) ProviderError!void {
    if (std.mem.indexOfAny(u8, physical, "?# \t\r\n") != null) return error.InvalidConfiguration;
    const expected = try physicalAlloc(std.heap.page_allocator, node, kind);
    defer std.heap.page_allocator.free(expected);
    if (!std.mem.eql(u8, expected, physical)) return error.InvalidConfiguration;
}
fn createPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    var request_id: [36]u8 = undefined;
    aip.requestId("ziac", node.id, "create", &request_id);
    return std.fmt.allocPrint(allocator, "/v1/projects/{s}/locations/{s}/{s}?{s}={s}&requestId={s}", .{ try requiredString(node.inputs, "project_id"), try requiredString(node.inputs, "location"), collection(kind), idParameter(kind), try requiredString(node.inputs, "name"), request_id[0..] }) catch error.OutOfMemory;
}
fn pendingResult(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, body: []const u8) ProviderError!provider_mod.ResourceResult {
    const handle = try operationNameAlloc(context.allocator, body);
    defer context.allocator.free(handle);
    const physical = try physicalAlloc(context.allocator, node, kind);
    defer context.allocator.free(physical);
    const outputs = [_]state.StateOutput{
        .{ .name = "name", .value = .{ .unknown_reason = "Eventarc Advanced operation pending" } },
        .{ .name = "etag", .value = .{ .unknown_reason = "Eventarc Advanced operation pending" } },
    };
    var result = try provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &outputs, handle);
    result.completed = false;
    return result;
}
fn resultFromJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, physical: []const u8, body: []const u8) ProviderError!provider_mod.ResourceResult {
    _ = kind;
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const remote = std.json.Stringify.valueAlloc(context.allocator, parsed.value, .{}) catch return error.OutOfMemory;
    defer context.allocator.free(remote);
    const outputs = [_]state.StateOutput{
        .{ .name = "__remote_spec", .value = .{ .string = remote } },
        .{ .name = "name", .value = .{ .string = jsonString(root.get("name")) orelse physical } },
        .{ .name = "uid", .value = .{ .string = jsonString(root.get("uid")) orelse "" } },
        .{ .name = "etag", .value = .{ .string = jsonString(root.get("etag")) orelse "" } },
    };
    return provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &outputs, null);
}
fn bodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, etag: ?[]const u8) ProviderError![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = std.json.ObjectMap.empty;
    switch (kind) {
        .message_bus => {
            try addMap(context, arena, &root, node.inputs, "annotations", "annotations");
            try addResolvedString(context, arena, &root, node.inputs, "crypto_key_name", "cryptoKeyName");
            try addString(arena, &root, node.inputs, "display_name", "displayName");
            try addMap(context, arena, &root, node.inputs, "labels", "labels");
            try addLogging(arena, &root, node.inputs);
        },
        .pipeline => {
            try addMap(context, arena, &root, node.inputs, "annotations", "annotations");
            try addResolvedString(context, arena, &root, node.inputs, "crypto_key_name", "cryptoKeyName");
            try addString(arena, &root, node.inputs, "display_name", "displayName");
            try root.put(arena, "destinations", try pipelineDestinations(context, arena, try requiredValue(node.inputs, "destination")));
            try addMap(context, arena, &root, node.inputs, "labels", "labels");
            try addLogging(arena, &root, node.inputs);
            try root.put(arena, "retryPolicy", try pipelineRetry(arena, try requiredValue(node.inputs, "retry")));
            try addPipelineFormats(arena, &root, node.inputs);
            try addTransformation(arena, &root, node.inputs);
        },
        .enrollment => {
            try addMap(context, arena, &root, node.inputs, "annotations", "annotations");
            try addString(arena, &root, node.inputs, "cel_match", "celMatch");
            try addResolvedString(context, arena, &root, node.inputs, "destination_pipeline", "destination");
            try addString(arena, &root, node.inputs, "display_name", "displayName");
            try addMap(context, arena, &root, node.inputs, "labels", "labels");
            try addResolvedString(context, arena, &root, node.inputs, "message_bus", "messageBus");
        },
        .google_api_source => {
            try addMap(context, arena, &root, node.inputs, "annotations", "annotations");
            try addResolvedString(context, arena, &root, node.inputs, "crypto_key_name", "cryptoKeyName");
            try addResolvedString(context, arena, &root, node.inputs, "destination_message_bus", "destination");
            try addString(arena, &root, node.inputs, "display_name", "displayName");
            try addMap(context, arena, &root, node.inputs, "labels", "labels");
            try addLogging(arena, &root, node.inputs);
            try addSubscriptions(context, arena, &root, try requiredValue(node.inputs, "subscriptions"));
        },
    }
    if (etag) |present| try root.put(arena, "etag", .{ .string = present });
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch error.OutOfMemory;
}

fn pipelineDestinations(context: *provider_mod.OperationContext, arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    const fields = valueObject(source) orelse return error.InvalidConfiguration;
    const kind = try objectString(fields, "kind");
    var destination = std.json.ObjectMap.empty;
    if (std.mem.eql(u8, kind, "https")) {
        var endpoint = std.json.ObjectMap.empty;
        try endpoint.put(arena, "uri", .{ .string = try objectString(fields, "uri") });
        const binding = try objectString(fields, "message_binding_template");
        if (binding.len != 0) try endpoint.put(arena, "messageBindingTemplate", .{ .string = binding });
        try destination.put(arena, "httpEndpoint", .{ .object = endpoint });
        const attachment = try objectString(fields, "network_attachment");
        if (attachment.len != 0) {
            var network = std.json.ObjectMap.empty;
            try network.put(arena, "networkAttachment", .{ .string = attachment });
            try destination.put(arena, "networkConfig", .{ .object = network });
        }
        const authentication = valueObject(try objectValue(fields, "authentication")) orelse return error.InvalidConfiguration;
        if (authentication.len != 0) {
            const auth_kind = try objectString(authentication, "kind");
            var token = std.json.ObjectMap.empty;
            try token.put(arena, "serviceAccount", .{ .string = try objectString(authentication, "service_account_email") });
            const claim = try objectString(authentication, "claim");
            if (claim.len != 0) try token.put(arena, if (std.mem.eql(u8, auth_kind, "oidc")) "audience" else "scope", .{ .string = claim });
            var config = std.json.ObjectMap.empty;
            try config.put(arena, if (std.mem.eql(u8, auth_kind, "oidc")) "googleOidc" else "oauthToken", .{ .object = token });
            try destination.put(arena, "authenticationConfig", .{ .object = config });
        }
    } else {
        const target = try resolveValueString(context, try objectValue(fields, "resource"));
        if (std.mem.eql(u8, kind, "workflow")) try destination.put(arena, "workflow", .{ .string = target }) else if (std.mem.eql(u8, kind, "pubsub_topic")) try destination.put(arena, "topic", .{ .string = target }) else if (std.mem.eql(u8, kind, "message_bus")) try destination.put(arena, "messageBus", .{ .string = target }) else return error.InvalidConfiguration;
    }
    var list = std.json.Array.init(arena);
    try list.append(.{ .object = destination });
    return .{ .array = list };
}
fn pipelineRetry(arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    const fields = valueObject(source) orelse return error.InvalidConfiguration;
    var retry = std.json.ObjectMap.empty;
    try retry.put(arena, "maxAttempts", .{ .integer = try objectInteger(fields, "max_attempts") });
    try retry.put(arena, "minRetryDelay", .{ .string = try std.fmt.allocPrint(arena, "{d}s", .{try objectInteger(fields, "min_delay_seconds")}) });
    try retry.put(arena, "maxRetryDelay", .{ .string = try std.fmt.allocPrint(arena, "{d}s", .{try objectInteger(fields, "max_delay_seconds")}) });
    return .{ .object = retry };
}
fn addPipelineFormats(arena: std.mem.Allocator, root: *std.json.ObjectMap, inputs: value.Value) ProviderError!void {
    const input_format = try requiredString(inputs, "input_payload_format");
    const output_format = try requiredString(inputs, "output_payload_format");
    if (!std.mem.eql(u8, input_format, "cloud_event_json")) try root.put(arena, "inputPayloadFormat", try payloadFormat(arena, input_format));
    if (!std.mem.eql(u8, output_format, "cloud_event_json")) {
        const destinations = root.getPtr("destinations") orelse return error.ProviderBug;
        try destinations.array.items[0].object.put(arena, "outputPayloadFormat", try payloadFormat(arena, output_format));
    }
}
fn payloadFormat(arena: std.mem.Allocator, format: []const u8) ProviderError!std.json.Value {
    var config = std.json.ObjectMap.empty;
    if (std.mem.eql(u8, format, "json")) try config.put(arena, "json", .{ .object = std.json.ObjectMap.empty }) else if (std.mem.eql(u8, format, "protobuf")) try config.put(arena, "protobuf", .{ .object = std.json.ObjectMap.empty }) else if (std.mem.eql(u8, format, "avro")) try config.put(arena, "avro", .{ .object = std.json.ObjectMap.empty }) else return error.InvalidConfiguration;
    return .{ .object = config };
}
fn addTransformation(arena: std.mem.Allocator, root: *std.json.ObjectMap, inputs: value.Value) ProviderError!void {
    const expression = try requiredString(inputs, "transformation_cel");
    if (expression.len == 0) return;
    var transformation = std.json.ObjectMap.empty;
    try transformation.put(arena, "transformationTemplate", .{ .string = expression });
    var mediation = std.json.ObjectMap.empty;
    try mediation.put(arena, "transformation", .{ .object = transformation });
    var list = std.json.Array.init(arena);
    try list.append(.{ .object = mediation });
    try root.put(arena, "mediations", .{ .array = list });
}
fn addSubscriptions(context: *provider_mod.OperationContext, arena: std.mem.Allocator, root: *std.json.ObjectMap, source: value.Value) ProviderError!void {
    _ = context;
    const fields = valueObject(source) orelse return error.InvalidConfiguration;
    const kind = try objectString(fields, "kind");
    if (std.mem.eql(u8, kind, "projects")) {
        var config = std.json.ObjectMap.empty;
        try config.put(arena, "projectIds", try plainValueJson(arena, try objectValue(fields, "projects")));
        try root.put(arena, "projectSubscriptions", .{ .object = config });
    } else if (std.mem.eql(u8, kind, "organization")) {
        var config = std.json.ObjectMap.empty;
        try config.put(arena, "organization", .{ .string = try objectString(fields, "organization") });
        try root.put(arena, "organizationSubscription", .{ .object = config });
    } else return error.InvalidConfiguration;
}
fn addString(arena: std.mem.Allocator, root: *std.json.ObjectMap, inputs: value.Value, input_name: []const u8, api_name: []const u8) ProviderError!void {
    const text = try requiredString(inputs, input_name);
    if (text.len != 0) try root.put(arena, api_name, .{ .string = text });
}
fn addResolvedString(context: *provider_mod.OperationContext, arena: std.mem.Allocator, root: *std.json.ObjectMap, inputs: value.Value, input_name: []const u8, api_name: []const u8) ProviderError!void {
    const text = try resolveValueString(context, try requiredValue(inputs, input_name));
    if (text.len != 0) try root.put(arena, api_name, .{ .string = text });
}
fn addMap(context: *provider_mod.OperationContext, arena: std.mem.Allocator, root: *std.json.ObjectMap, inputs: value.Value, input_name: []const u8, api_name: []const u8) ProviderError!void {
    const selected = try requiredValue(inputs, input_name);
    if (valueObject(selected).?.len != 0) try root.put(arena, api_name, try valueJson(context, arena, selected));
}
fn addLogging(arena: std.mem.Allocator, root: *std.json.ObjectMap, inputs: value.Value) ProviderError!void {
    const severity = try requiredString(inputs, "logging_severity");
    if (std.mem.eql(u8, severity, "LOG_SEVERITY_UNSPECIFIED")) return;
    var logging = std.json.ObjectMap.empty;
    try logging.put(arena, "logSeverity", .{ .string = severity });
    try root.put(arena, "loggingConfig", .{ .object = logging });
}
fn changedMaskAlloc(allocator: std.mem.Allocator, desired_json: []const u8, remote_json: []const u8) ProviderError![]u8 {
    var desired = std.json.parseFromSlice(std.json.Value, allocator, desired_json, .{}) catch return error.ProviderBug;
    defer desired.deinit();
    var remote = std.json.parseFromSlice(std.json.Value, allocator, remote_json, .{}) catch return error.ProviderBug;
    defer remote.deinit();
    const desired_root = jsonObject(desired.value) orelse return error.ProviderBug;
    const remote_root = jsonObject(remote.value) orelse return error.ProviderBug;
    var fields = std.ArrayList([]const u8).empty;
    defer fields.deinit(allocator);
    for (desired_root.keys()) |name| if (!jsonEquivalent(desired_root.get(name).?, remote_root.get(name))) try fields.append(allocator, name);
    std.mem.sort([]const u8, fields.items, {}, lessString);
    return std.mem.join(allocator, ",", fields.items) catch error.OutOfMemory;
}
fn containsMask(mask: []const u8, field: []const u8) bool {
    var iterator = std.mem.splitScalar(u8, mask, ',');
    while (iterator.next()) |name| if (std.mem.eql(u8, name, field)) return true;
    return false;
}
fn identityFields(kind: Kind) []const []const u8 {
    return switch (kind) {
        .message_bus, .pipeline => &.{ "project_id", "location", "name" },
        .enrollment => &.{ "project_id", "location", "name", "message_bus" },
        .google_api_source => &.{ "project_id", "location", "name", "destination_message_bus" },
    };
}
fn identityChanged(node: resource.ResourceNode, observed: *const provider_mod.ResourceResult, fields: []const []const u8) bool {
    for (fields) |name| if (!valuesEqual(findField(node.inputs, name), findField(observed.observed_inputs, name))) return true;
    return false;
}
fn valuesEqual(left: ?value.Value, right: ?value.Value) bool {
    if (left == null or right == null) return left == null and right == null;
    const left_json = left.?.canonicalJsonAlloc(std.heap.page_allocator) catch return false;
    defer std.heap.page_allocator.free(left_json);
    const right_json = right.?.canonicalJsonAlloc(std.heap.page_allocator) catch return false;
    defer std.heap.page_allocator.free(right_json);
    return std.mem.eql(u8, left_json, right_json);
}
fn operationNameAlloc(allocator: std.mem.Allocator, body: []const u8) ProviderError![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const name = jsonString(root.get("name")) orelse return error.ProviderBug;
    if (std.mem.indexOf(u8, name, "/operations/") == null) return error.ProviderBug;
    return allocator.dupe(u8, name) catch error.OutOfMemory;
}
fn operationResponseAlloc(allocator: std.mem.Allocator, payload: []const u8) ProviderError!?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const response = root.get("response") orelse return null;
    if (response == .null) return null;
    return std.json.Stringify.valueAlloc(allocator, response, .{}) catch error.OutOfMemory;
}
fn valueJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    return switch (source) {
        .string => |text| .{ .string = text },
        .integer => |number| .{ .integer = number },
        .boolean => |flag| .{ .bool = flag },
        .output_ref => |reference| .{ .string = try context.resolveOutputString(reference) },
        .list => |items| blk: {
            var result = std.json.Array.init(arena);
            for (items) |item| try result.append(try valueJson(context, arena, item));
            break :blk .{ .array = result };
        },
        .object => |fields| blk: {
            var result = std.json.ObjectMap.empty;
            for (fields) |field| try result.put(arena, field.name, try valueJson(context, arena, field.value));
            break :blk .{ .object = result };
        },
        .secret_ref, .unknown_reason => error.InvalidConfiguration,
    };
}
fn plainValueJson(arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    return switch (source) {
        .string => |text| .{ .string = text },
        .integer => |number| .{ .integer = number },
        .boolean => |flag| .{ .bool = flag },
        .list => |items| blk: {
            var result = std.json.Array.init(arena);
            for (items) |item| try result.append(try plainValueJson(arena, item));
            break :blk .{ .array = result };
        },
        .object => |fields| blk: {
            var result = std.json.ObjectMap.empty;
            for (fields) |field| try result.put(arena, field.name, try plainValueJson(arena, field.value));
            break :blk .{ .object = result };
        },
        else => error.InvalidConfiguration,
    };
}
fn jsonEquivalent(desired: std.json.Value, remote_optional: ?std.json.Value) bool {
    const remote = remote_optional orelse return jsonEmpty(desired);
    if (std.meta.activeTag(desired) != std.meta.activeTag(remote)) return false;
    return switch (desired) {
        .null => true,
        .bool => desired.bool == remote.bool,
        .integer => desired.integer == remote.integer,
        .float => desired.float == remote.float,
        .number_string => std.mem.eql(u8, desired.number_string, remote.number_string),
        .string => std.mem.eql(u8, desired.string, remote.string),
        .array => |array| blk: {
            if (array.items.len != remote.array.items.len) break :blk false;
            for (array.items, remote.array.items) |left, right| if (!jsonEquivalent(left, right)) break :blk false;
            break :blk true;
        },
        .object => |object| blk: {
            for (object.keys()) |key| if (!jsonEquivalent(object.get(key).?, remote.object.get(key))) break :blk false;
            break :blk true;
        },
    };
}
fn jsonEmpty(source: std.json.Value) bool {
    return switch (source) {
        .string => |text| text.len == 0,
        .array => |items| items.items.len == 0,
        .object => |object| object.count() == 0,
        .bool => |flag| !flag,
        else => false,
    };
}
fn resolveValueString(context: *provider_mod.OperationContext, source: value.Value) ProviderError![]const u8 {
    return switch (source) {
        .string => |text| text,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}
fn findField(source: value.Value, name: []const u8) ?value.Value {
    const fields = valueObject(source) orelse return null;
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return null;
}
fn requiredValue(source: value.Value, name: []const u8) ProviderError!value.Value {
    return findField(source, name) orelse error.InvalidConfiguration;
}
fn requiredString(source: value.Value, name: []const u8) ProviderError![]const u8 {
    const selected = try requiredValue(source, name);
    return if (selected == .string) selected.string else error.InvalidConfiguration;
}
fn objectValue(fields: []const value.Field, name: []const u8) ProviderError!value.Value {
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return error.InvalidConfiguration;
}
fn objectString(fields: []const value.Field, name: []const u8) ProviderError![]const u8 {
    const selected = try objectValue(fields, name);
    return if (selected == .string) selected.string else error.InvalidConfiguration;
}
fn objectInteger(fields: []const value.Field, name: []const u8) ProviderError!i64 {
    const selected = try objectValue(fields, name);
    return if (selected == .integer) selected.integer else error.InvalidConfiguration;
}
fn valueObject(source: value.Value) ?[]const value.Field {
    return if (source == .object) source.object else null;
}
fn outputString(result: provider_mod.ResourceResult, name: []const u8) ?[]const u8 {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name) and item.value == .string) return item.value.string;
    return null;
}
fn jsonObject(source: std.json.Value) ?std.json.ObjectMap {
    return if (source == .object) source.object else null;
}
fn jsonString(source: ?std.json.Value) ?[]const u8 {
    const selected = source orelse return null;
    return if (selected == .string) selected.string else null;
}
fn lessString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
fn percentEncodeAlloc(allocator: std.mem.Allocator, source: []const u8) ProviderError![]u8 {
    var result = std.ArrayList(u8).empty;
    for (source) |character| if (character == ',') try result.appendSlice(allocator, "%2C") else try result.append(allocator, character);
    return result.toOwnedSlice(allocator) catch error.OutOfMemory;
}
