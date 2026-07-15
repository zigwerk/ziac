const std = @import("std");
const aip = @import("aip.zig");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;
const Kind = enum { connection, endpoint_attachment, event_subscription, managed_zone, regional_settings };

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
            return provider_mod.DiffResult.init(context.allocator, .replace, &.{"Connector identity changed"});
        const desired_json = try bodyAlloc(context, node, kind);
        defer context.allocator.free(desired_json);
        const remote_json = outputString(observed.*, "__remote_spec") orelse return provider_mod.DiffResult.init(context.allocator, .update, &.{"Connector configuration differs"});
        const mask = try changedMaskAlloc(context.allocator, desired_json, remote_json);
        defer context.allocator.free(mask);
        if (mask.len == 0) return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        if (requiresReplacement(kind, mask)) return provider_mod.DiffResult.init(context.allocator, .replace, &.{"Connector immutable configuration changed"});
        return provider_mod.DiffResult.init(context.allocator, .update, &.{"Connector configuration differs"});
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        const path = try createPathAlloc(context.allocator, node, kind);
        defer context.allocator.free(path);
        const body = try bodyAlloc(context, node, kind);
        defer context.allocator.free(body);
        var response = try self.request(context, if (kind == .regional_settings) "PATCH" else "POST", path, body);
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
        const desired_json = try bodyAlloc(context, node, kind);
        defer context.allocator.free(desired_json);
        const remote_json = outputString(observed.*, "__remote_spec") orelse return error.InvalidConfiguration;
        const mask = try changedMaskAlloc(context.allocator, desired_json, remote_json);
        defer context.allocator.free(mask);
        const encoded_mask = try percentEncodeAlloc(context.allocator, mask);
        defer context.allocator.free(encoded_mask);
        var request_id: [36]u8 = undefined;
        aip.requestId("ziac", node.id, "update", &request_id);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}?updateMask={s}&requestId={s}", .{ observed.physical_id, encoded_mask, request_id[0..] });
        defer context.allocator.free(path);
        var response = try self.request(context, "PATCH", path, desired_json);
        defer response.deinit(context.allocator);
        return pendingResult(context, node, kind, response.body);
    }

    pub fn delete(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical: []const u8) ProviderError!void {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (kind == .regional_settings) return error.InvalidConfiguration;
        try validatePhysical(node, kind, physical);
        if (!std.mem.eql(u8, try requiredString(node.inputs, "removal_policy"), "delete") or !context.destructive_confirmation) return error.DestructiveConfirmationRequired;
        var request_id: [36]u8 = undefined;
        aip.requestId("ziac", node.id, "delete", &request_id);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}?requestId={s}", .{ physical, request_id[0..] });
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
        const base = try std.fmt.allocPrint(context.allocator, "{s}/v1", .{std.mem.trimEnd(u8, self.client.endpoints.connectors, "/")});
        defer context.allocator.free(base);
        var target = operation.Target.genericAlloc(context.allocator, base, handle) catch return error.OutOfMemory;
        defer target.deinit(context.allocator);
        return operation.waitAlloc(self.client, context, target, self.operation_policy);
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, method: []const u8, path: []const u8, body: []const u8) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, .{ .api = .connectors, .method = method, .path = path, .body = body }, &diagnostic);
    }
};

fn kindOf(node: resource.ResourceNode) ?Kind {
    const mappings = [_]struct { type_name: []const u8, kind: Kind }{
        .{ .type_name = "gcp.connectors.Connection", .kind = .connection },
        .{ .type_name = "gcp.connectors.EndpointAttachment", .kind = .endpoint_attachment },
        .{ .type_name = "gcp.connectors.EventSubscription", .kind = .event_subscription },
        .{ .type_name = "gcp.connectors.ManagedZone", .kind = .managed_zone },
        .{ .type_name = "gcp.connectors.RegionalSettings", .kind = .regional_settings },
    };
    for (mappings) |mapping| if (std.mem.eql(u8, node.type_name, mapping.type_name)) return mapping.kind;
    return null;
}
fn collection(kind: Kind) []const u8 {
    return switch (kind) {
        .connection => "connections",
        .endpoint_attachment => "endpointAttachments",
        .event_subscription => "eventSubscriptions",
        .managed_zone => "managedZones",
        .regional_settings => "regionalSettings",
    };
}
fn idParameter(kind: Kind) []const u8 {
    return switch (kind) {
        .connection => "connectionId",
        .endpoint_attachment => "endpointAttachmentId",
        .event_subscription => "eventSubscriptionId",
        .managed_zone => "managedZoneId",
        .regional_settings => "",
    };
}
fn physicalAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    const project = try requiredString(node.inputs, "project_id");
    return switch (kind) {
        .managed_zone => std.fmt.allocPrint(allocator, "projects/{s}/locations/global/managedZones/{s}", .{ project, try requiredString(node.inputs, "name") }) catch error.OutOfMemory,
        .regional_settings => std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}/regionalSettings", .{ project, try requiredString(node.inputs, "location") }) catch error.OutOfMemory,
        .event_subscription => std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}/connections/{s}/eventSubscriptions/{s}", .{ project, try requiredString(node.inputs, "location"), try requiredString(node.inputs, "connection_name"), try requiredString(node.inputs, "name") }) catch error.OutOfMemory,
        else => std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}/{s}/{s}", .{ project, try requiredString(node.inputs, "location"), collection(kind), try requiredString(node.inputs, "name") }) catch error.OutOfMemory,
    };
}
fn validatePhysical(node: resource.ResourceNode, kind: Kind, physical: []const u8) ProviderError!void {
    if (std.mem.indexOfAny(u8, physical, "?# \t\r\n") != null) return error.InvalidConfiguration;
    const expected = try physicalAlloc(std.heap.page_allocator, node, kind);
    defer std.heap.page_allocator.free(expected);
    if (!std.mem.eql(u8, expected, physical)) return error.InvalidConfiguration;
}
fn createPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    const project = try requiredString(node.inputs, "project_id");
    var request_id: [36]u8 = undefined;
    aip.requestId("ziac", node.id, "create", &request_id);
    return switch (kind) {
        .regional_settings => std.fmt.allocPrint(allocator, "/v1/projects/{s}/locations/{s}/regionalSettings?updateMask=networkConfig%2CencryptionConfig%2Cclient", .{ project, try requiredString(node.inputs, "location") }) catch error.OutOfMemory,
        .managed_zone => std.fmt.allocPrint(allocator, "/v1/projects/{s}/locations/global/managedZones?managedZoneId={s}&requestId={s}", .{ project, try requiredString(node.inputs, "name"), request_id[0..] }) catch error.OutOfMemory,
        .event_subscription => std.fmt.allocPrint(allocator, "/v1/projects/{s}/locations/{s}/connections/{s}/eventSubscriptions?eventSubscriptionId={s}&requestId={s}", .{ project, try requiredString(node.inputs, "location"), try requiredString(node.inputs, "connection_name"), try requiredString(node.inputs, "name"), request_id[0..] }) catch error.OutOfMemory,
        else => std.fmt.allocPrint(allocator, "/v1/projects/{s}/locations/{s}/{s}?{s}={s}&requestId={s}", .{ project, try requiredString(node.inputs, "location"), collection(kind), idParameter(kind), try requiredString(node.inputs, "name"), request_id[0..] }) catch error.OutOfMemory,
    };
}
fn pendingResult(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, body: []const u8) ProviderError!provider_mod.ResourceResult {
    const handle = try operationNameAlloc(context.allocator, body);
    defer context.allocator.free(handle);
    const physical = try physicalAlloc(context.allocator, node, kind);
    defer context.allocator.free(physical);
    const outputs = [_]state.StateOutput{
        .{ .name = "name", .value = .{ .unknown_reason = "Connectors operation pending" } },
        .{ .name = "status", .value = .{ .unknown_reason = "Connectors operation pending" } },
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
    const status = jsonObject(root.get("status") orelse .null);
    const outputs = [_]state.StateOutput{
        .{ .name = "__remote_spec", .value = .{ .string = remote } },
        .{ .name = "name", .value = .{ .string = jsonString(root.get("name")) orelse physical } },
        .{ .name = "status", .value = .{ .string = if (status) |present| jsonString(present.get("state")) orelse "STATE_UNSPECIFIED" else "STATE_UNSPECIFIED" } },
        .{ .name = "service_directory", .value = .{ .string = jsonString(root.get("serviceDirectory")) orelse "" } },
        .{ .name = "host", .value = .{ .string = jsonString(root.get("host")) orelse "" } },
        .{ .name = "endpoint_ip", .value = .{ .string = jsonString(root.get("endpointIp")) orelse "" } },
        .{ .name = "state", .value = .{ .string = jsonString(root.get("state")) orelse "STATE_UNSPECIFIED" } },
        .{ .name = "subscriber_link", .value = .{ .string = jsonString(root.get("subscriberLink")) orelse "" } },
        .{ .name = "provisioned", .value = .{ .boolean = jsonBoolean(root.get("provisioned")) orelse false } },
        .{ .name = "egress_ips", .value = .{ .string = try egressIpsAlloc(context.allocator, root) } },
        .{ .name = "connection_revision", .value = .{ .string = jsonString(root.get("connectionRevision")) orelse "" } },
    };
    defer context.allocator.free(outputs[9].value.string);
    return provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &outputs, null);
}
fn egressIpsAlloc(allocator: std.mem.Allocator, root: std.json.ObjectMap) ProviderError![]u8 {
    const network = jsonObject(root.get("networkConfig") orelse .null) orelse return allocator.dupe(u8, "") catch error.OutOfMemory;
    const values = jsonArray(network.get("egressIps") orelse .null) orelse return allocator.dupe(u8, "") catch error.OutOfMemory;
    var ips = std.ArrayList([]const u8).empty;
    defer ips.deinit(allocator);
    for (values.items) |item| if (item == .string) try ips.append(allocator, item.string);
    return std.mem.join(allocator, ",", ips.items) catch error.OutOfMemory;
}

fn bodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind) ProviderError![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = std.json.ObjectMap.empty;
    switch (kind) {
        .connection => try connectionBody(context, arena, &root, node.inputs),
        .endpoint_attachment => {
            try addString(arena, &root, node.inputs, "description", "description");
            try root.put(arena, "endpointGlobalAccess", .{ .bool = try requiredBoolean(node.inputs, "endpoint_global_access") });
            try addMap(context, arena, &root, node.inputs, "labels", "labels");
            try addResolvedString(context, arena, &root, node.inputs, "service_attachment", "serviceAttachment");
        },
        .event_subscription => try eventSubscriptionBody(context, arena, &root, node.inputs),
        .managed_zone => {
            try addString(arena, &root, node.inputs, "description", "description");
            try addString(arena, &root, node.inputs, "dns", "dns");
            try addMap(context, arena, &root, node.inputs, "labels", "labels");
            try addString(arena, &root, node.inputs, "target_project", "targetProject");
            try addString(arena, &root, node.inputs, "target_vpc", "targetVpc");
        },
        .regional_settings => {
            try addString(arena, &root, node.inputs, "client", "client");
            var network = std.json.ObjectMap.empty;
            try network.put(arena, "egressMode", .{ .string = try requiredString(node.inputs, "egress_mode") });
            try root.put(arena, "networkConfig", .{ .object = network });
            const kms = try resolvedString(context, node.inputs, "kms_key_name");
            if (kms.len != 0) {
                var encryption = std.json.ObjectMap.empty;
                try encryption.put(arena, "encryptionType", .{ .string = "CMEK" });
                try encryption.put(arena, "kmsKeyName", .{ .string = kms });
                try root.put(arena, "encryptionConfig", .{ .object = encryption });
            }
        },
    }
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch error.OutOfMemory;
}
fn connectionBody(context: *provider_mod.OperationContext, arena: std.mem.Allocator, root: *std.json.ObjectMap, inputs: value.Value) ProviderError!void {
    try root.put(arena, "authConfig", try authenticationJson(context, arena, try requiredValue(inputs, "authentication")));
    try root.put(arena, "configVariables", try configVariablesJson(context, arena, try requiredValue(inputs, "config_variables")));
    try addString(arena, root, inputs, "connector_version", "connectorVersion");
    try addString(arena, root, inputs, "description", "description");
    try root.put(arena, "destinationConfigs", try destinationsJson(arena, try requiredValue(inputs, "destinations")));
    try addMap(context, arena, root, inputs, "labels", "labels");
    var log = std.json.ObjectMap.empty;
    const level = try requiredString(inputs, "log_level");
    try log.put(arena, "enabled", .{ .bool = !std.mem.eql(u8, level, "OFF") });
    try log.put(arena, "level", .{ .string = level });
    try root.put(arena, "logConfig", .{ .object = log });
    try root.put(arena, "nodeConfig", try nodeConfigJson(arena, try requiredValue(inputs, "node_config")));
    try addString(arena, root, inputs, "service_account_email", "serviceAccount");
    try root.put(arena, "suspended", .{ .bool = try requiredBoolean(inputs, "suspended") });
}
fn authenticationJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    const fields = valueObject(source) orelse return error.InvalidConfiguration;
    const kind = try objectString(fields, "kind");
    if (std.mem.eql(u8, kind, "none")) return .{ .object = std.json.ObjectMap.empty };
    var auth = std.json.ObjectMap.empty;
    if (std.mem.eql(u8, kind, "user_password")) {
        try auth.put(arena, "authType", .{ .string = "USER_PASSWORD" });
        var user_password = std.json.ObjectMap.empty;
        try user_password.put(arena, "username", .{ .string = try objectString(fields, "username") });
        try user_password.put(arena, "password", try secretJson(context, arena, try objectValue(fields, "password_secret_version")));
        try auth.put(arena, "userPassword", .{ .object = user_password });
    } else if (std.mem.eql(u8, kind, "oauth_client_credentials")) {
        try auth.put(arena, "authType", .{ .string = "OAUTH2_CLIENT_CREDENTIALS" });
        var oauth = std.json.ObjectMap.empty;
        try oauth.put(arena, "clientId", .{ .string = try objectString(fields, "client_id") });
        try oauth.put(arena, "clientSecret", try secretJson(context, arena, try objectValue(fields, "client_secret_version")));
        try auth.put(arena, "oauth2ClientCredentials", .{ .object = oauth });
    } else if (std.mem.eql(u8, kind, "ssh")) {
        try auth.put(arena, "authType", .{ .string = "SSH_PUBLIC_KEY" });
        var ssh = std.json.ObjectMap.empty;
        try ssh.put(arena, "username", .{ .string = try objectString(fields, "username") });
        try ssh.put(arena, "privateKey", try secretJson(context, arena, try objectValue(fields, "private_key_secret_version")));
        try auth.put(arena, "sshPublicKey", .{ .object = ssh });
    } else return error.InvalidConfiguration;
    return .{ .object = auth };
}
fn configVariablesJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    var result = std.json.Array.init(arena);
    for (valueList(source) orelse return error.InvalidConfiguration) |item| {
        const fields = valueObject(item) orelse return error.InvalidConfiguration;
        const selected = valueObject(try objectValue(fields, "value")) orelse return error.InvalidConfiguration;
        const kind = try objectString(selected, "kind");
        const inner = try objectValue(selected, "value");
        var variable = std.json.ObjectMap.empty;
        try variable.put(arena, "key", .{ .string = try objectString(fields, "key") });
        if (std.mem.eql(u8, kind, "string")) try variable.put(arena, "stringValue", try scalarJson(inner)) else if (std.mem.eql(u8, kind, "integer")) {
            const number = if (inner == .integer) inner.integer else return error.InvalidConfiguration;
            try variable.put(arena, "intValue", .{ .string = try std.fmt.allocPrint(arena, "{d}", .{number}) });
        } else if (std.mem.eql(u8, kind, "boolean")) try variable.put(arena, "boolValue", try scalarJson(inner)) else if (std.mem.eql(u8, kind, "secret_version")) try variable.put(arena, "secretValue", try secretJson(context, arena, inner)) else return error.InvalidConfiguration;
        try result.append(.{ .object = variable });
    }
    return .{ .array = result };
}
fn destinationsJson(arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    var result = std.json.Array.init(arena);
    for (valueList(source) orelse return error.InvalidConfiguration) |item| {
        const fields = valueObject(item) orelse return error.InvalidConfiguration;
        var destination = std.json.ObjectMap.empty;
        try destination.put(arena, "key", .{ .string = try objectString(fields, "key") });
        try destination.put(arena, "destinations", try plainValueJson(arena, try objectValue(fields, "destinations")));
        try result.append(.{ .object = destination });
    }
    return .{ .array = result };
}
fn nodeConfigJson(arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    const fields = valueObject(source) orelse return error.InvalidConfiguration;
    var nodes = std.json.ObjectMap.empty;
    try nodes.put(arena, "minNodeCount", .{ .integer = try objectInteger(fields, "min_nodes") });
    try nodes.put(arena, "maxNodeCount", .{ .integer = try objectInteger(fields, "max_nodes") });
    return .{ .object = nodes };
}
fn eventSubscriptionBody(context: *provider_mod.OperationContext, arena: std.mem.Allocator, root: *std.json.ObjectMap, inputs: value.Value) ProviderError!void {
    try addString(arena, root, inputs, "event_type_id", "eventTypeId");
    try addString(arena, root, inputs, "filter", "filter");
    try root.put(arena, "destinations", try eventDestinationJson(arena, try requiredValue(inputs, "destination")));
    try root.put(arena, "triggerConfigVariables", try configVariablesJson(context, arena, try requiredValue(inputs, "trigger_config_variables")));
}
fn eventDestinationJson(arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    const fields = valueObject(source) orelse return error.InvalidConfiguration;
    const kind = try objectString(fields, "kind");
    var destination = std.json.ObjectMap.empty;
    if (std.mem.eql(u8, kind, "https")) {
        try destination.put(arena, "type", .{ .string = "ENDPOINT" });
        var endpoint = std.json.ObjectMap.empty;
        try endpoint.put(arena, "endpointUri", .{ .string = try objectString(fields, "uri") });
        try destination.put(arena, "endpoint", .{ .object = endpoint });
        const service_account = try objectString(fields, "service_account_email");
        if (service_account.len != 0) try destination.put(arena, "serviceAccount", .{ .string = service_account });
    } else if (std.mem.eql(u8, kind, "pubsub")) {
        try destination.put(arena, "type", .{ .string = "PUBSUB" });
        var pubsub = std.json.ObjectMap.empty;
        try pubsub.put(arena, "projectId", .{ .string = try objectString(fields, "project_id") });
        try pubsub.put(arena, "topicId", .{ .string = try objectString(fields, "topic_id") });
        try destination.put(arena, "pubsub", .{ .object = pubsub });
    } else return error.InvalidConfiguration;
    return .{ .object = destination };
}
fn secretJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    const reference = switch (source) {
        .secret_ref => |present| present,
        .output_ref => |output_reference| try context.resolveOutputSecret(output_reference),
        else => return error.InvalidConfiguration,
    };
    var secret = std.json.ObjectMap.empty;
    try secret.put(arena, "secretVersion", .{ .string = reference.resource });
    return .{ .object = secret };
}
fn scalarJson(source: value.Value) ProviderError!std.json.Value {
    return switch (source) {
        .string => |text| .{ .string = text },
        .integer => |number| .{ .integer = number },
        .boolean => |flag| .{ .bool = flag },
        else => error.InvalidConfiguration,
    };
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
fn requiresReplacement(kind: Kind, mask: []const u8) bool {
    const immutable: []const []const u8 = switch (kind) {
        .connection => &.{ "connectorVersion", "authConfig" },
        .endpoint_attachment => &.{"serviceAttachment"},
        .event_subscription => &.{"eventTypeId"},
        .managed_zone => &.{ "targetProject", "targetVpc", "dns" },
        .regional_settings => &.{},
    };
    var iterator = std.mem.splitScalar(u8, mask, ',');
    while (iterator.next()) |field| for (immutable) |name| if (std.mem.eql(u8, field, name)) return true;
    return false;
}
fn identityFields(kind: Kind) []const []const u8 {
    return switch (kind) {
        .connection, .endpoint_attachment => &.{ "project_id", "location", "name" },
        .event_subscription => &.{ "project_id", "location", "connection_name", "name" },
        .managed_zone => &.{ "project_id", "name" },
        .regional_settings => &.{ "project_id", "location" },
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
fn addString(arena: std.mem.Allocator, root: *std.json.ObjectMap, inputs: value.Value, input_name: []const u8, api_name: []const u8) ProviderError!void {
    const text = try requiredString(inputs, input_name);
    if (text.len != 0) try root.put(arena, api_name, .{ .string = text });
}
fn addResolvedString(context: *provider_mod.OperationContext, arena: std.mem.Allocator, root: *std.json.ObjectMap, inputs: value.Value, input_name: []const u8, api_name: []const u8) ProviderError!void {
    const text = try resolvedString(context, inputs, input_name);
    if (text.len != 0) try root.put(arena, api_name, .{ .string = text });
}
fn addMap(context: *provider_mod.OperationContext, arena: std.mem.Allocator, root: *std.json.ObjectMap, inputs: value.Value, input_name: []const u8, api_name: []const u8) ProviderError!void {
    const selected = try requiredValue(inputs, input_name);
    if (valueObject(selected).?.len != 0) try root.put(arena, api_name, try valueJson(context, arena, selected));
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
fn requiredBoolean(source: value.Value, name: []const u8) ProviderError!bool {
    const selected = try requiredValue(source, name);
    return if (selected == .boolean) selected.boolean else error.InvalidConfiguration;
}
fn resolvedString(context: *provider_mod.OperationContext, source: value.Value, name: []const u8) ProviderError![]const u8 {
    return switch (try requiredValue(source, name)) {
        .string => |text| text,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
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
fn valueList(source: value.Value) ?[]const value.Value {
    return if (source == .list) source.list else null;
}
fn outputString(result: provider_mod.ResourceResult, name: []const u8) ?[]const u8 {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name) and item.value == .string) return item.value.string;
    return null;
}
fn jsonObject(source: std.json.Value) ?std.json.ObjectMap {
    return if (source == .object) source.object else null;
}
fn jsonArray(source: std.json.Value) ?std.json.Array {
    return if (source == .array) source.array else null;
}
fn jsonString(source: ?std.json.Value) ?[]const u8 {
    const selected = source orelse return null;
    return if (selected == .string) selected.string else null;
}
fn jsonBoolean(source: ?std.json.Value) ?bool {
    const selected = source orelse return null;
    return if (selected == .bool) selected.bool else null;
}
fn lessString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
fn percentEncodeAlloc(allocator: std.mem.Allocator, source: []const u8) ProviderError![]u8 {
    var result = std.ArrayList(u8).empty;
    for (source) |character| if (character == ',') try result.appendSlice(allocator, "%2C") else try result.append(allocator, character);
    return result.toOwnedSlice(allocator) catch error.OutOfMemory;
}
