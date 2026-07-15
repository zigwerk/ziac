const std = @import("std");
const aip = @import("aip.zig");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;
const Kind = enum {
    dataset,
    model,
    endpoint,
    index,
    index_endpoint,
    feature_group,
    feature,
    online_store,
    feature_view,
    tensorboard,
    metadata_store,
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
        const expected = try physicalAlloc(context.allocator, node, kind);
        defer context.allocator.free(expected);
        const physical = physical_override orelse context.physical_id orelse expected;
        try validatePhysical(node, kind, physical);
        if (context.operation_handle) |handle| {
            var completed = try self.waitOperation(context, node, handle);
            defer completed.deinit(context.allocator);
            if (try operationResponseAlloc(context.allocator, completed.payload)) |response_json| {
                defer context.allocator.free(response_json);
                return .{ .present = try resultFromJson(context, node, kind, physical, response_json) };
            }
        }
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical});
        defer context.allocator.free(path);
        var response = self.request(context, node, "GET", path, "") catch |err| {
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
        if (identityChanged(node, observed, immutableFields(kind)))
            return provider_mod.DiffResult.init(context.allocator, .replace, &.{"Vertex AI immutable configuration changed"});
        const desired_json = try bodyAlloc(context, node, kind, null);
        defer context.allocator.free(desired_json);
        const remote_json = outputString(observed.*, "__remote_spec") orelse return provider_mod.DiffResult.init(context.allocator, .update, &.{"Vertex AI configuration differs"});
        const mask = try changedMaskAlloc(context.allocator, desired_json, remote_json);
        defer context.allocator.free(mask);
        if (mask.len == 0) return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        return provider_mod.DiffResult.init(context.allocator, .update, &.{"Vertex AI configuration differs"});
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        const path = try createPathAlloc(context.allocator, node, kind);
        defer context.allocator.free(path);
        const resource_body = try bodyAlloc(context, node, kind, null);
        defer context.allocator.free(resource_body);
        const body = if (kind == .model) try uploadBodyAlloc(context.allocator, node, resource_body) else try context.allocator.dupe(u8, resource_body);
        defer context.allocator.free(body);
        var response = try self.request(context, node, "POST", path, body);
        defer response.deinit(context.allocator);
        return pendingOrComplete(context, node, kind, response.body);
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
        const etag = outputString(observed.*, "etag") orelse "";
        var request_id: [36]u8 = undefined;
        aip.requestId("ziac", node.id, "update", &request_id);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}?updateMask={s}&requestId={s}", .{ observed.physical_id, encoded_mask, request_id[0..] });
        defer context.allocator.free(path);
        const body = try bodyAlloc(context, node, kind, etag);
        defer context.allocator.free(body);
        var response = try self.request(context, node, if (kind == .endpoint and containsMask(mask, "trafficSplit")) "POST" else "PATCH", path, body);
        defer response.deinit(context.allocator);
        return pendingOrComplete(context, node, kind, response.body);
    }

    pub fn delete(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical: []const u8) ProviderError!void {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(node, kind, physical);
        if (!std.mem.eql(u8, try requiredString(node.inputs, "removal_policy"), "delete") or !context.destructive_confirmation) return error.DestructiveConfirmationRequired;
        var request_id: [36]u8 = undefined;
        aip.requestId("ziac", node.id, "delete", &request_id);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}?requestId={s}", .{ physical, request_id[0..] });
        defer context.allocator.free(path);
        var response = self.request(context, node, "DELETE", path, "") catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer response.deinit(context.allocator);
        if (try operationNameOptionalAlloc(context.allocator, response.body)) |handle| {
            defer context.allocator.free(handle);
            var completed = try self.waitOperation(context, node, handle);
            completed.deinit(context.allocator);
        }
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

    fn waitOperation(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, handle: []const u8) ProviderError!operation.Result {
        const regional = try regionalBaseAlloc(context.allocator, self.client.endpoints.vertex_ai, try requiredString(node.inputs, "location"));
        defer context.allocator.free(regional);
        const base = try std.fmt.allocPrint(context.allocator, "{s}/v1", .{regional});
        defer context.allocator.free(base);
        var target = operation.Target.genericAlloc(context.allocator, base, handle) catch return error.OutOfMemory;
        defer target.deinit(context.allocator);
        return operation.waitAlloc(self.client, context, target, self.operation_policy);
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, method: []const u8, path: []const u8, body: []const u8) ProviderError!@import("zigeffect_std").Http.Response {
        const base = try regionalBaseAlloc(context.allocator, self.client.endpoints.vertex_ai, try requiredString(node.inputs, "location"));
        defer context.allocator.free(base);
        const url = try joinUrlAlloc(context.allocator, base, path);
        defer context.allocator.free(url);
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, .{ .method = method, .path = url, .body = body }, &diagnostic);
    }
};

fn kindOf(node: resource.ResourceNode) ?Kind {
    const mappings = [_]struct { []const u8, Kind }{
        .{ "gcp.vertex.Dataset", .dataset },
        .{ "gcp.vertex.Model", .model },
        .{ "gcp.vertex.Endpoint", .endpoint },
        .{ "gcp.vertex.Index", .index },
        .{ "gcp.vertex.IndexEndpoint", .index_endpoint },
        .{ "gcp.vertex.FeatureGroup", .feature_group },
        .{ "gcp.vertex.Feature", .feature },
        .{ "gcp.vertex.FeatureOnlineStore", .online_store },
        .{ "gcp.vertex.FeatureView", .feature_view },
        .{ "gcp.vertex.Tensorboard", .tensorboard },
        .{ "gcp.vertex.MetadataStore", .metadata_store },
    };
    for (mappings) |mapping| if (std.mem.eql(u8, node.type_name, mapping[0])) return mapping[1];
    return null;
}
fn collection(kind: Kind) []const u8 {
    return switch (kind) {
        .dataset => "datasets",
        .model => "models",
        .endpoint => "endpoints",
        .index => "indexes",
        .index_endpoint => "indexEndpoints",
        .feature_group => "featureGroups",
        .feature => "features",
        .online_store => "featureOnlineStores",
        .feature_view => "featureViews",
        .tensorboard => "tensorboards",
        .metadata_store => "metadataStores",
    };
}
fn idParameter(kind: Kind) ?[]const u8 {
    return switch (kind) {
        .model => "modelId",
        .endpoint => "endpointId",
        .feature_group => "featureGroupId",
        .feature => "featureId",
        .online_store => "featureOnlineStoreId",
        .feature_view => "featureViewId",
        .metadata_store => "metadataStoreId",
        .dataset, .index, .index_endpoint, .tensorboard => null,
    };
}
fn parentAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]u8 {
    const base = try std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}", .{ try requiredString(node.inputs, "project_id"), try requiredString(node.inputs, "location") });
    if (kind == .feature) {
        defer allocator.free(base);
        return std.fmt.allocPrint(allocator, "{s}/featureGroups/{s}", .{ base, try requiredString(node.inputs, "feature_group_name") }) catch error.OutOfMemory;
    }
    if (kind == .feature_view) {
        defer allocator.free(base);
        return std.fmt.allocPrint(allocator, "{s}/featureOnlineStores/{s}", .{ base, try requiredString(node.inputs, "online_store_name") }) catch error.OutOfMemory;
    }
    return base;
}
fn physicalAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]u8 {
    const parent = try parentAlloc(allocator, node, kind);
    defer allocator.free(parent);
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ parent, collection(kind), try requiredString(node.inputs, "name") }) catch error.OutOfMemory;
}
fn validatePhysical(node: resource.ResourceNode, kind: Kind, physical: []const u8) ProviderError!void {
    if (std.mem.indexOfAny(u8, physical, "?# \t\r\n") != null) return error.InvalidConfiguration;
    const prefix = try parentAlloc(std.heap.page_allocator, node, kind);
    defer std.heap.page_allocator.free(prefix);
    const required_prefix = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}/", .{ prefix, collection(kind) });
    defer std.heap.page_allocator.free(required_prefix);
    if (!std.mem.startsWith(u8, physical, required_prefix) or physical.len == required_prefix.len) return error.InvalidConfiguration;
    if (idParameter(kind) != null) {
        const expected = try physicalAlloc(std.heap.page_allocator, node, kind);
        defer std.heap.page_allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical)) return error.InvalidConfiguration;
    }
}
fn createPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]u8 {
    var request_id: [36]u8 = undefined;
    aip.requestId("ziac", node.id, "create", &request_id);
    const parent = try parentAlloc(allocator, node, kind);
    defer allocator.free(parent);
    if (kind == .model) return std.fmt.allocPrint(allocator, "/v1/{s}/models:upload?requestId={s}", .{ parent, request_id[0..] }) catch error.OutOfMemory;
    if (idParameter(kind)) |parameter| return std.fmt.allocPrint(allocator, "/v1/{s}/{s}?{s}={s}&requestId={s}", .{ parent, collection(kind), parameter, try requiredString(node.inputs, "name"), request_id[0..] }) catch error.OutOfMemory;
    return std.fmt.allocPrint(allocator, "/v1/{s}/{s}?requestId={s}", .{ parent, collection(kind), request_id[0..] }) catch error.OutOfMemory;
}
fn uploadBodyAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, resource_body: []const u8) ProviderError![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"modelId\":\"{s}\",\"model\":{s}}}", .{ try requiredString(node.inputs, "name"), resource_body }) catch error.OutOfMemory;
}
fn pendingOrComplete(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, body: []const u8) ProviderError!provider_mod.ResourceResult {
    if (try operationNameOptionalAlloc(context.allocator, body)) |handle| {
        defer context.allocator.free(handle);
        const physical = try physicalAlloc(context.allocator, node, kind);
        defer context.allocator.free(physical);
        const outputs = [_]state.StateOutput{
            .{ .name = "name", .value = .{ .unknown_reason = "Vertex AI operation pending" } },
            .{ .name = "etag", .value = .{ .unknown_reason = "Vertex AI operation pending" } },
        };
        var result = try provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &outputs, handle);
        result.completed = false;
        return result;
    }
    const physical = try physicalAlloc(context.allocator, node, kind);
    defer context.allocator.free(physical);
    return resultFromJson(context, node, kind, physical, body);
}
fn resultFromJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, fallback: []const u8, body: []const u8) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const physical = jsonString(root.get("name")) orelse fallback;
    try validatePhysical(node, kind, physical);
    const remote = std.json.Stringify.valueAlloc(context.allocator, parsed.value, .{}) catch return error.OutOfMemory;
    defer context.allocator.free(remote);
    const serving_uri = jsonString(root.get("dedicatedEndpointDns")) orelse jsonString(root.get("publicEndpointDomainName")) orelse jsonNestedString(root.get("dedicatedServingEndpoint"), "publicEndpointDomainName") orelse "";
    const outputs = [_]state.StateOutput{
        .{ .name = "__remote_spec", .value = .{ .string = remote } },
        .{ .name = "name", .value = .{ .string = physical } },
        .{ .name = "etag", .value = .{ .string = jsonString(root.get("etag")) orelse "" } },
        .{ .name = "serving_uri", .value = .{ .string = serving_uri } },
        .{ .name = "service_account", .value = .{ .string = jsonString(root.get("serviceAccountEmail")) orelse "" } },
    };
    return provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &outputs, null);
}

fn bodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, etag: ?[]const u8) ProviderError![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = std.json.ObjectMap.empty;
    switch (kind) {
        .dataset, .index => {
            try addString(arena, &root, node.inputs, "display_name", "displayName");
            try addString(arena, &root, node.inputs, "description", "description");
            try addString(arena, &root, node.inputs, "metadata_schema_uri", "metadataSchemaUri");
            try addJson(arena, &root, node.inputs, "metadata_json", "metadata");
            try addMap(context, arena, &root, node.inputs, "labels", "labels");
            try addEncryption(context, arena, &root, node.inputs);
            if (kind == .index) try addString(arena, &root, node.inputs, "update_method", "indexUpdateMethod");
        },
        .model => {
            try addString(arena, &root, node.inputs, "display_name", "displayName");
            try addString(arena, &root, node.inputs, "description", "description");
            try addString(arena, &root, node.inputs, "artifact_uri", "artifactUri");
            try addString(arena, &root, node.inputs, "metadata_schema_uri", "metadataSchemaUri");
            try addJson(arena, &root, node.inputs, "metadata_json", "metadata");
            try addMap(context, arena, &root, node.inputs, "labels", "labels");
            try addEncryption(context, arena, &root, node.inputs);
            try root.put(arena, "containerSpec", try containerJson(context, arena, try requiredValue(node.inputs, "container")));
        },
        .endpoint, .index_endpoint => {
            try addString(arena, &root, node.inputs, "display_name", "displayName");
            try addString(arena, &root, node.inputs, "description", "description");
            try addMap(context, arena, &root, node.inputs, "labels", "labels");
            try addEncryption(context, arena, &root, node.inputs);
            try addConnectivity(context, arena, &root, node.inputs, kind);
            if (kind == .endpoint) try root.put(arena, "dedicatedEndpointEnabled", .{ .bool = try requiredBoolean(node.inputs, "dedicated_endpoint") });
        },
        .feature_group => {
            try addString(arena, &root, node.inputs, "description", "description");
            try addMap(context, arena, &root, node.inputs, "labels", "labels");
            var source = std.json.ObjectMap.empty;
            try source.put(arena, "bigQuerySource", .{ .object = try bqSource(arena, try requiredString(node.inputs, "bigquery_source")) });
            try source.put(arena, "entityIdColumns", try valueJson(context, arena, try requiredValue(node.inputs, "entity_id_columns")));
            try root.put(arena, "bigQuery", .{ .object = source });
        },
        .feature => {
            try addString(arena, &root, node.inputs, "description", "description");
            try addString(arena, &root, node.inputs, "point_of_contact", "pointOfContact");
            try addMap(context, arena, &root, node.inputs, "labels", "labels");
        },
        .online_store => {
            try addMap(context, arena, &root, node.inputs, "labels", "labels");
            try addEncryption(context, arena, &root, node.inputs);
            try addStorage(arena, &root, try requiredValue(node.inputs, "storage"));
        },
        .feature_view => {
            try addMap(context, arena, &root, node.inputs, "labels", "labels");
            try addFeatureViewSource(context, arena, &root, try requiredValue(node.inputs, "source"));
            var sync = std.json.ObjectMap.empty;
            try sync.put(arena, "cron", .{ .string = try syncCronAlloc(arena, try requiredInteger(node.inputs, "sync_interval_seconds")) });
            try root.put(arena, "syncConfig", .{ .object = sync });
        },
        .tensorboard => {
            try addString(arena, &root, node.inputs, "display_name", "displayName");
            try addString(arena, &root, node.inputs, "description", "description");
            try addMap(context, arena, &root, node.inputs, "labels", "labels");
            try addEncryption(context, arena, &root, node.inputs);
            try root.put(arena, "isDefault", .{ .bool = try requiredBoolean(node.inputs, "is_default") });
        },
        .metadata_store => {
            try addString(arena, &root, node.inputs, "description", "description");
            try addEncryption(context, arena, &root, node.inputs);
        },
    }
    if (etag) |present| if (present.len != 0) try root.put(arena, "etag", .{ .string = present });
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch error.OutOfMemory;
}

fn addString(arena: std.mem.Allocator, root: *std.json.ObjectMap, inputs: value.Value, input_name: []const u8, api_name: []const u8) ProviderError!void {
    const text = try requiredString(inputs, input_name);
    if (text.len != 0) try root.put(arena, api_name, .{ .string = text });
}
fn addJson(arena: std.mem.Allocator, root: *std.json.ObjectMap, inputs: value.Value, input_name: []const u8, api_name: []const u8) ProviderError!void {
    const text = try requiredString(inputs, input_name);
    var parsed = std.json.parseFromSlice(std.json.Value, arena, text, .{}) catch return error.InvalidConfiguration;
    defer parsed.deinit();
    try root.put(arena, api_name, parsed.value);
}
fn addMap(context: *provider_mod.OperationContext, arena: std.mem.Allocator, root: *std.json.ObjectMap, inputs: value.Value, input_name: []const u8, api_name: []const u8) ProviderError!void {
    const selected = try requiredValue(inputs, input_name);
    if (valueObject(selected).?.len != 0) try root.put(arena, api_name, try valueJson(context, arena, selected));
}
fn addEncryption(context: *provider_mod.OperationContext, arena: std.mem.Allocator, root: *std.json.ObjectMap, inputs: value.Value) ProviderError!void {
    const key = try resolveValueString(context, try requiredValue(inputs, "kms_key_name"));
    if (key.len == 0) return;
    var encryption = std.json.ObjectMap.empty;
    try encryption.put(arena, "kmsKeyName", .{ .string = key });
    try root.put(arena, "encryptionSpec", .{ .object = encryption });
}
fn addConnectivity(context: *provider_mod.OperationContext, arena: std.mem.Allocator, root: *std.json.ObjectMap, inputs: value.Value, kind: Kind) ProviderError!void {
    const fields = valueObject(try requiredValue(inputs, "connectivity")) orelse return error.InvalidConfiguration;
    const selected = try objectString(fields, "kind");
    if (std.mem.eql(u8, selected, "public")) {
        if (kind == .index_endpoint) try root.put(arena, "publicEndpointEnabled", .{ .bool = true });
    } else if (std.mem.eql(u8, selected, "vpc")) {
        try root.put(arena, "network", .{ .string = try resolveValueString(context, try objectValue(fields, "network")) });
    } else if (std.mem.eql(u8, selected, "private_service_connect")) {
        var config = std.json.ObjectMap.empty;
        try config.put(arena, "enablePrivateServiceConnect", .{ .bool = true });
        try config.put(arena, "projectAllowlist", try valueJson(context, arena, try objectValue(fields, "project_allowlist")));
        try root.put(arena, "privateServiceConnectConfig", .{ .object = config });
    } else return error.InvalidConfiguration;
}
fn containerJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    const fields = valueObject(source) orelse return error.InvalidConfiguration;
    var container = std.json.ObjectMap.empty;
    try container.put(arena, "imageUri", .{ .string = try objectString(fields, "image_uri") });
    try container.put(arena, "ports", try valueJson(context, arena, try objectValue(fields, "ports")));
    try container.put(arena, "predictRoute", .{ .string = try objectString(fields, "predict_route") });
    try container.put(arena, "healthRoute", .{ .string = try objectString(fields, "health_route") });
    inline for (.{ "command", "args" }) |name| {
        const selected = try objectValue(fields, name);
        if (valueList(selected).?.len != 0) try container.put(arena, name, try valueJson(context, arena, selected));
    }
    const environment = valueObject(try objectValue(fields, "environment")) orelse return error.InvalidConfiguration;
    if (environment.len != 0) {
        var variables = std.json.Array.init(arena);
        for (environment) |entry| {
            var variable = std.json.ObjectMap.empty;
            try variable.put(arena, "name", .{ .string = entry.name });
            try variable.put(arena, "value", .{ .string = if (entry.value == .string) entry.value.string else return error.InvalidConfiguration });
            try variables.append(.{ .object = variable });
        }
        try container.put(arena, "env", .{ .array = variables });
    }
    return .{ .object = container };
}
fn bqSource(arena: std.mem.Allocator, uri: []const u8) ProviderError!std.json.ObjectMap {
    var source = std.json.ObjectMap.empty;
    try source.put(arena, "inputUri", .{ .string = uri });
    return source;
}
fn addStorage(arena: std.mem.Allocator, root: *std.json.ObjectMap, source: value.Value) ProviderError!void {
    const fields = valueObject(source) orelse return error.InvalidConfiguration;
    const kind = try objectString(fields, "kind");
    if (std.mem.eql(u8, kind, "bigtable")) {
        var autoscaling = std.json.ObjectMap.empty;
        try autoscaling.put(arena, "minNodeCount", .{ .integer = try objectInteger(fields, "min_nodes") });
        try autoscaling.put(arena, "maxNodeCount", .{ .integer = try objectInteger(fields, "max_nodes") });
        var bigtable = std.json.ObjectMap.empty;
        try bigtable.put(arena, "autoScaling", .{ .object = autoscaling });
        try root.put(arena, "bigtable", .{ .object = bigtable });
    } else if (std.mem.eql(u8, kind, "optimized")) {
        var optimized = std.json.ObjectMap.empty;
        if (try objectBoolean(fields, "private_service_connect")) {
            var psc = std.json.ObjectMap.empty;
            try psc.put(arena, "enablePrivateServiceConnect", .{ .bool = true });
            try optimized.put(arena, "privateServiceConnectConfig", .{ .object = psc });
        }
        try root.put(arena, "optimized", .{ .object = optimized });
    } else return error.InvalidConfiguration;
}
fn addFeatureViewSource(context: *provider_mod.OperationContext, arena: std.mem.Allocator, root: *std.json.ObjectMap, source: value.Value) ProviderError!void {
    const fields = valueObject(source) orelse return error.InvalidConfiguration;
    const kind = try objectString(fields, "kind");
    if (std.mem.eql(u8, kind, "bigquery")) {
        var selected = std.json.ObjectMap.empty;
        try selected.put(arena, "uri", .{ .string = try objectString(fields, "uri") });
        try root.put(arena, "bigQuerySource", .{ .object = selected });
    } else if (std.mem.eql(u8, kind, "feature_registry")) {
        var selected = std.json.ObjectMap.empty;
        try selected.put(arena, "featureGroups", .{ .array = blk: {
            var groups = std.json.Array.init(arena);
            var group = std.json.ObjectMap.empty;
            try group.put(arena, "featureGroupId", .{ .string = resourceBasename(try resolveValueString(context, try objectValue(fields, "feature_group"))) });
            var feature_ids = std.json.Array.init(arena);
            const features = valueList(try objectValue(fields, "features")) orelse return error.InvalidConfiguration;
            for (features) |feature| try feature_ids.append(.{ .string = resourceBasename(try resolveValueString(context, feature)) });
            try group.put(arena, "featureIds", .{ .array = feature_ids });
            try groups.append(.{ .object = group });
            break :blk groups;
        } });
        try root.put(arena, "featureRegistrySource", .{ .object = selected });
    } else return error.InvalidConfiguration;
}

fn syncCronAlloc(allocator: std.mem.Allocator, seconds: i64) ProviderError![]u8 {
    if (seconds < 60 or seconds > 604800 or @mod(seconds, 60) != 0) return error.InvalidConfiguration;
    const minutes = @divExact(seconds, 60);
    if (minutes < 60 and @mod(60, minutes) == 0)
        return std.fmt.allocPrint(allocator, "*/{d} * * * *", .{minutes}) catch error.OutOfMemory;
    if (minutes < 1440 and @mod(minutes, 60) == 0) {
        const hours = @divExact(minutes, 60);
        if (@mod(24, hours) == 0)
            return std.fmt.allocPrint(allocator, "0 */{d} * * *", .{hours}) catch error.OutOfMemory;
    }
    if (seconds == 86400) return allocator.dupe(u8, "0 0 * * *") catch error.OutOfMemory;
    if (seconds == 604800) return allocator.dupe(u8, "0 0 * * 0") catch error.OutOfMemory;
    return error.InvalidConfiguration;
}

fn resourceBasename(name: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, name, '/')) |index| name[index + 1 ..] else name;
}

fn immutableFields(kind: Kind) []const []const u8 {
    return switch (kind) {
        .dataset => &.{ "project_id", "location", "name", "metadata_schema_uri", "kms_key_name" },
        .model => &.{ "project_id", "location", "name", "artifact_uri", "container", "metadata_schema_uri", "kms_key_name" },
        .endpoint, .index_endpoint => &.{ "project_id", "location", "name", "connectivity", "kms_key_name" },
        .index => &.{ "project_id", "location", "name", "metadata_schema_uri", "update_method", "kms_key_name" },
        .feature_group => &.{ "project_id", "location", "name", "bigquery_source", "entity_id_columns" },
        .feature => &.{ "project_id", "location", "name", "feature_group" },
        .online_store => &.{ "project_id", "location", "name", "storage", "kms_key_name" },
        .feature_view => &.{ "project_id", "location", "name", "online_store", "source" },
        .tensorboard => &.{ "project_id", "location", "name", "kms_key_name" },
        .metadata_store => &.{ "project_id", "location", "name", "kms_key_name" },
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
fn operationNameOptionalAlloc(allocator: std.mem.Allocator, body: []const u8) ProviderError!?[]u8 {
    if (body.len == 0) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return null;
    const name = jsonString(root.get("name")) orelse return null;
    if (std.mem.indexOf(u8, name, "/operations/") == null) return null;
    return allocator.dupe(u8, name) catch error.OutOfMemory;
}
fn operationResponseAlloc(allocator: std.mem.Allocator, payload: []const u8) ProviderError!?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const response = root.get("response") orelse return null;
    if (response == .null) return null;
    return std.json.Stringify.valueAlloc(allocator, response, .{}) catch error.OutOfMemory;
}
fn regionalBaseAlloc(allocator: std.mem.Allocator, base: []const u8, location: []const u8) ProviderError![]u8 {
    if (std.mem.indexOfAny(u8, location, "./:@?# \t\r\n") != null) return error.InvalidConfiguration;
    const prefix = "https://";
    if (!std.mem.startsWith(u8, base, prefix)) return error.InvalidConfiguration;
    const host = std.mem.trimEnd(u8, base[prefix.len..], "/");
    if (host.len == 0 or std.mem.indexOfScalar(u8, host, '/') != null) return error.InvalidConfiguration;
    return std.fmt.allocPrint(allocator, "https://{s}-{s}", .{ location, host }) catch error.OutOfMemory;
}
fn joinUrlAlloc(allocator: std.mem.Allocator, base: []const u8, path: []const u8) ProviderError![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ std.mem.trimEnd(u8, base, "/"), std.mem.trimStart(u8, path, "/") }) catch error.OutOfMemory;
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
fn requiredInteger(source: value.Value, name: []const u8) ProviderError!i64 {
    const selected = try requiredValue(source, name);
    return if (selected == .integer) selected.integer else error.InvalidConfiguration;
}
fn requiredBoolean(source: value.Value, name: []const u8) ProviderError!bool {
    const selected = try requiredValue(source, name);
    return if (selected == .boolean) selected.boolean else error.InvalidConfiguration;
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
fn objectBoolean(fields: []const value.Field, name: []const u8) ProviderError!bool {
    const selected = try objectValue(fields, name);
    return if (selected == .boolean) selected.boolean else error.InvalidConfiguration;
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
fn jsonString(source: ?std.json.Value) ?[]const u8 {
    const selected = source orelse return null;
    return if (selected == .string) selected.string else null;
}
fn jsonNestedString(source: ?std.json.Value, name: []const u8) ?[]const u8 {
    const selected = source orelse return null;
    if (selected != .object) return null;
    return jsonString(selected.object.get(name));
}
fn containsMask(mask: []const u8, field: []const u8) bool {
    var iterator = std.mem.splitScalar(u8, mask, ',');
    while (iterator.next()) |name| if (std.mem.eql(u8, name, field)) return true;
    return false;
}
fn lessString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
fn percentEncodeAlloc(allocator: std.mem.Allocator, source: []const u8) ProviderError![]u8 {
    var result = std.ArrayList(u8).empty;
    for (source) |character| if (character == ',') try result.appendSlice(allocator, "%2C") else try result.append(allocator, character);
    return result.toOwnedSlice(allocator) catch error.OutOfMemory;
}
