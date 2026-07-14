const std = @import("std");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;

const Kind = enum { bucket, view, sink, exclusion, metric };

const bucket_update_mask = "analyticsEnabled%2CcmekSettings.kmsKeyName%2Cdescription%2CindexConfigs%2Clocked%2CretentionDays%2CrestrictedFields";
const view_update_mask = "description%2Cfilter";
const sink_update_mask = "bigqueryOptions%2Cdescription%2Cdestination%2Cdisabled%2Cexclusions%2Cfilter";
const exclusion_update_mask = "description%2Cdisabled%2Cfilter";

pub fn supports(node: resource.ResourceNode) bool {
    return kindOf(node) != null;
}

pub const Handler = struct {
    client: *client_mod.Client,
    operation_policy: operation.Policy = .{},

    pub fn read(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (kind == .bucket) if (context.operation_handle) |handle| try self.waitOperation(context, handle);
        const expected = try stablePhysicalAlloc(context.allocator, node, kind);
        defer context.allocator.free(expected);
        const physical = physical_override orelse expected;
        if (!std.mem.eql(u8, expected, physical)) return error.InvalidConfiguration;
        const path = try std.fmt.allocPrint(context.allocator, "/v2/{s}", .{physical});
        defer context.allocator.free(path);
        var response = self.request(context, "GET", path, "") catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try self.resultFromJson(context, node, kind, response.body) };
    }

    pub fn diff(context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash)) return provider_mod.DiffResult.init(context.allocator, .noop, &.{});

        const replace = switch (kind) {
            .bucket => inputChanged(node.inputs, observed.observed_inputs, "location") or inputChanged(node.inputs, observed.observed_inputs, "name"),
            .view => inputChanged(node.inputs, observed.observed_inputs, "location") or inputChanged(node.inputs, observed.observed_inputs, "bucket_name") or inputChanged(node.inputs, observed.observed_inputs, "bucket") or inputChanged(node.inputs, observed.observed_inputs, "name"),
            .metric => inputChanged(node.inputs, observed.observed_inputs, "name") or inputChanged(node.inputs, observed.observed_inputs, "metric_kind") or inputChanged(node.inputs, observed.observed_inputs, "value_type") or inputChanged(node.inputs, observed.observed_inputs, "labels"),
            .sink, .exclusion => inputChanged(node.inputs, observed.observed_inputs, "name"),
        };
        if (kind == .bucket) try validateBucketTransition(node.inputs, observed.observed_inputs);
        if (kind == .sink and !requiredBoolean(node.inputs, "unique_writer_identity") and requiredBoolean(observed.observed_inputs, "unique_writer_identity")) return error.InvalidConfiguration;
        return provider_mod.DiffResult.init(
            context.allocator,
            if (replace) .replace else .update,
            &.{if (replace) "immutable Cloud Logging identity or schema changed" else "Cloud Logging configuration differs"},
        );
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        const path = try createPathAlloc(context.allocator, node, kind);
        defer context.allocator.free(path);
        const body = try bodyAlloc(context, node, kind);
        defer context.allocator.free(body);
        var response = try self.request(context, "POST", path, body);
        defer response.deinit(context.allocator);
        if (kind == .bucket) return pendingResult(context, node, kind, response.body);
        return self.resultFromJson(context, node, kind, response.body);
    }

    pub fn update(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(context.allocator, node, kind, observed.physical_id);
        if (kind == .bucket) try validateBucketTransition(node.inputs, observed.observed_inputs);
        const path = try updatePathAlloc(context.allocator, node, kind, observed.physical_id);
        defer context.allocator.free(path);
        const body = try bodyAlloc(context, node, kind);
        defer context.allocator.free(body);
        var response = try self.request(context, if (kind == .sink or kind == .view or kind == .exclusion) "PATCH" else if (kind == .metric) "PUT" else "POST", path, body);
        defer response.deinit(context.allocator);
        if (kind == .bucket) return pendingResult(context, node, kind, response.body);
        return self.resultFromJson(context, node, kind, response.body);
    }

    pub fn delete(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!void {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(context.allocator, node, kind, physical_id);
        const path = try std.fmt.allocPrint(context.allocator, "/v2/{s}", .{physical_id});
        defer context.allocator.free(path);
        var response = self.request(context, "DELETE", path, "") catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        response.deinit(context.allocator);
    }

    pub fn importResource(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!provider_mod.ResourceResult {
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(context.allocator, node, kind, physical_id);
        var read_result = try self.read(context, node, physical_id);
        defer read_result.deinit();
        return switch (read_result) {
            .absent => error.NotFound,
            .present => |present| present.clone(context.allocator),
        };
    }

    fn waitOperation(self: Handler, context: *provider_mod.OperationContext, handle: []const u8) ProviderError!void {
        const base = try std.fmt.allocPrint(context.allocator, "{s}/v2", .{std.mem.trimEnd(u8, self.client.endpoints.logging, "/")});
        defer context.allocator.free(base);
        var target = operation.Target.genericAlloc(context.allocator, base, handle) catch return error.OutOfMemory;
        defer target.deinit(context.allocator);
        var completed = try operation.waitAlloc(self.client, context, target, self.operation_policy);
        completed.deinit(context.allocator);
    }

    fn resultFromJson(_: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, body: []const u8) ProviderError!provider_mod.ResourceResult {
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const remote = jsonObject(parsed.value) orelse return error.ProviderBug;
        const physical = try stablePhysicalAlloc(context.allocator, node, kind);
        defer context.allocator.free(physical);
        if (remote.get("name")) |name_value| {
            const remote_name = jsonString(name_value) orelse return error.ProviderBug;
            if (kind != .metric and kind != .sink and kind != .exclusion and !std.mem.eql(u8, remote_name, physical)) return error.InvalidConfiguration;
            if ((kind == .metric or kind == .sink or kind == .exclusion) and !std.mem.eql(u8, remote_name, try requiredString(node.inputs, "name")) and !std.mem.eql(u8, remote_name, physical)) return error.InvalidConfiguration;
        }

        const desired_body = try bodyAlloc(context, node, kind);
        defer context.allocator.free(desired_body);
        var desired = std.json.parseFromSlice(std.json.Value, context.allocator, desired_body, .{}) catch return error.ProviderBug;
        defer desired.deinit();
        var observed = if (jsonSubset(parsed.value, desired.value))
            node.inputs.clone(context.allocator) catch return error.OutOfMemory
        else
            driftedInputsAlloc(context.allocator, node.inputs) catch return error.OutOfMemory;
        defer observed.deinit(context.allocator);

        var outputs: [2]state.StateOutput = undefined;
        var output_count: usize = 1;
        outputs[0] = .{ .name = "name", .value = .{ .string = physical } };
        if (kind == .bucket) {
            outputs[1] = .{ .name = "lifecycle_state", .value = .{ .string = jsonString(remote.get("lifecycleState") orelse .{ .string = "ACTIVE" }) orelse "ACTIVE" } };
            output_count = 2;
        } else if (kind == .sink) {
            outputs[1] = .{ .name = "writer_identity", .value = .{ .string = jsonString(remote.get("writerIdentity") orelse .{ .string = "" }) orelse "" } };
            output_count = 2;
        }
        return provider_mod.ResourceResult.init(context.allocator, physical, observed, outputs[0..output_count], null);
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, method: []const u8, path: []const u8, body: []const u8) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, .{ .api = .logging, .method = method, .path = path, .body = body }, &diagnostic);
    }
};

fn pendingResult(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, body: []const u8) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const handle = jsonString(root.get("name") orelse return error.ProviderBug) orelse return error.ProviderBug;
    if (std.mem.indexOf(u8, handle, "/operations/") == null or std.mem.indexOfAny(u8, handle, " \t\r\n?#") != null) return error.ProviderBug;
    const physical = try stablePhysicalAlloc(context.allocator, node, kind);
    defer context.allocator.free(physical);
    const outputs = [_]state.StateOutput{
        .{ .name = "name", .value = .{ .unknown_reason = "Cloud Logging operation pending" } },
        .{ .name = "lifecycle_state", .value = .{ .unknown_reason = "Cloud Logging operation pending" } },
    };
    var result = try provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &outputs, handle);
    result.completed = false;
    return result;
}

fn bodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = std.json.ObjectMap.empty;
    switch (kind) {
        .bucket => try bucketBody(context, arena, &root, node),
        .view => try viewBody(context, arena, &root, node),
        .sink => try sinkBody(context, arena, &root, node),
        .exclusion => try exclusionBody(arena, &root, node),
        .metric => try metricBody(context, arena, &root, node),
    }
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch return error.OutOfMemory;
}

fn bucketBody(context: *provider_mod.OperationContext, arena: std.mem.Allocator, root: *std.json.ObjectMap, node: resource.ResourceNode) ProviderError!void {
    const physical = try stablePhysicalAlloc(context.allocator, node, .bucket);
    defer context.allocator.free(physical);
    try root.put(arena, "name", .{ .string = physical });
    try root.put(arena, "description", .{ .string = try requiredString(node.inputs, "description") });
    try root.put(arena, "retentionDays", .{ .integer = try requiredInteger(node.inputs, "retention_days") });
    try root.put(arena, "analyticsEnabled", .{ .bool = requiredBoolean(node.inputs, "analytics_enabled") });
    try root.put(arena, "locked", .{ .bool = requiredBoolean(node.inputs, "locked") });
    try root.put(arena, "restrictedFields", .{ .array = try stringArrayAlloc(context, arena, try requiredList(node.inputs, "restricted_fields")) });
    var indexes = std.json.Array.init(arena);
    for (try requiredList(node.inputs, "indexes")) |candidate| {
        const fields = valueObject(candidate) orelse return error.InvalidConfiguration;
        var encoded = std.json.ObjectMap.empty;
        try encoded.put(arena, "fieldPath", .{ .string = requiredObjectString(fields, "field_path") });
        try encoded.put(arena, "type", .{ .string = requiredObjectString(fields, "type") });
        try indexes.append(.{ .object = encoded });
    }
    try root.put(arena, "indexConfigs", .{ .array = indexes });
    const kms_key = try resolveString(context, try requiredValue(node.inputs, "kms_key_name"));
    if (kms_key.len != 0) {
        var settings = std.json.ObjectMap.empty;
        try settings.put(arena, "kmsKeyName", .{ .string = kms_key });
        try root.put(arena, "cmekSettings", .{ .object = settings });
    }
}

fn viewBody(context: *provider_mod.OperationContext, arena: std.mem.Allocator, root: *std.json.ObjectMap, node: resource.ResourceNode) ProviderError!void {
    const physical = try stablePhysicalAlloc(context.allocator, node, .view);
    defer context.allocator.free(physical);
    try root.put(arena, "name", .{ .string = physical });
    try root.put(arena, "description", .{ .string = try requiredString(node.inputs, "description") });
    try root.put(arena, "filter", .{ .string = try requiredString(node.inputs, "filter") });
}

fn sinkBody(context: *provider_mod.OperationContext, arena: std.mem.Allocator, root: *std.json.ObjectMap, node: resource.ResourceNode) ProviderError!void {
    try root.put(arena, "name", .{ .string = try requiredString(node.inputs, "name") });
    const destination = try requiredObject(node.inputs, "destination");
    const kind = requiredObjectString(destination, "kind");
    const target = try resolveString(context, requiredObjectValue(destination, "target"));
    const prefix = if (std.mem.eql(u8, kind, "LOGGING_BUCKET")) "logging.googleapis.com/" else if (std.mem.eql(u8, kind, "STORAGE_BUCKET")) "storage.googleapis.com/" else if (std.mem.eql(u8, kind, "BIGQUERY_DATASET")) "bigquery.googleapis.com/" else if (std.mem.eql(u8, kind, "PUBSUB_TOPIC")) "pubsub.googleapis.com/" else return error.InvalidConfiguration;
    const wire_destination = if (std.mem.startsWith(u8, target, prefix)) target else try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, std.mem.trimStart(u8, target, "/") });
    try root.put(arena, "destination", .{ .string = wire_destination });
    try root.put(arena, "filter", .{ .string = try requiredString(node.inputs, "filter") });
    try root.put(arena, "description", .{ .string = try requiredString(node.inputs, "description") });
    try root.put(arena, "disabled", .{ .bool = requiredBoolean(node.inputs, "disabled") });
    if (requiredBoolean(node.inputs, "partitioned_tables")) {
        var options = std.json.ObjectMap.empty;
        try options.put(arena, "usePartitionedTables", .{ .bool = true });
        try root.put(arena, "bigqueryOptions", .{ .object = options });
    }
    var exclusions = std.json.Array.init(arena);
    for (try requiredList(node.inputs, "exclusions")) |candidate| {
        const fields = valueObject(candidate) orelse return error.InvalidConfiguration;
        var encoded = std.json.ObjectMap.empty;
        try encoded.put(arena, "name", .{ .string = requiredObjectString(fields, "name") });
        try encoded.put(arena, "description", .{ .string = requiredObjectString(fields, "description") });
        try encoded.put(arena, "filter", .{ .string = requiredObjectString(fields, "filter") });
        try encoded.put(arena, "disabled", .{ .bool = requiredObjectBoolean(fields, "disabled") });
        try exclusions.append(.{ .object = encoded });
    }
    try root.put(arena, "exclusions", .{ .array = exclusions });
}

fn exclusionBody(arena: std.mem.Allocator, root: *std.json.ObjectMap, node: resource.ResourceNode) ProviderError!void {
    try root.put(arena, "name", .{ .string = try requiredString(node.inputs, "name") });
    try root.put(arena, "description", .{ .string = try requiredString(node.inputs, "description") });
    try root.put(arena, "filter", .{ .string = try requiredString(node.inputs, "filter") });
    try root.put(arena, "disabled", .{ .bool = requiredBoolean(node.inputs, "disabled") });
}

fn metricBody(context: *provider_mod.OperationContext, arena: std.mem.Allocator, root: *std.json.ObjectMap, node: resource.ResourceNode) ProviderError!void {
    try root.put(arena, "name", .{ .string = try requiredString(node.inputs, "name") });
    try root.put(arena, "description", .{ .string = try requiredString(node.inputs, "description") });
    try root.put(arena, "filter", .{ .string = try requiredString(node.inputs, "filter") });
    try root.put(arena, "disabled", .{ .bool = requiredBoolean(node.inputs, "disabled") });
    var descriptor = std.json.ObjectMap.empty;
    try descriptor.put(arena, "metricKind", .{ .string = try requiredString(node.inputs, "metric_kind") });
    try descriptor.put(arena, "valueType", .{ .string = try requiredString(node.inputs, "value_type") });
    var labels = std.json.Array.init(arena);
    for (try requiredList(node.inputs, "labels")) |candidate| {
        const fields = valueObject(candidate) orelse return error.InvalidConfiguration;
        var encoded = std.json.ObjectMap.empty;
        try encoded.put(arena, "key", .{ .string = requiredObjectString(fields, "key") });
        try encoded.put(arena, "description", .{ .string = requiredObjectString(fields, "description") });
        try encoded.put(arena, "valueType", .{ .string = requiredObjectString(fields, "value_type") });
        try labels.append(.{ .object = encoded });
    }
    try descriptor.put(arena, "labels", .{ .array = labels });
    try root.put(arena, "metricDescriptor", .{ .object = descriptor });
    try root.put(arena, "labelExtractors", .{ .object = try stringMapAlloc(arena, try requiredObject(node.inputs, "label_extractors")) });
    const bucket_name = try resolveString(context, try requiredValue(node.inputs, "bucket_name"));
    if (bucket_name.len != 0) try root.put(arena, "bucketName", .{ .string = bucket_name });
    const mode = try requiredObject(node.inputs, "mode");
    if (std.mem.eql(u8, requiredObjectString(mode, "kind"), "DISTRIBUTION")) {
        try root.put(arena, "valueExtractor", .{ .string = requiredObjectString(mode, "value_extractor") });
        try root.put(arena, "bucketOptions", .{ .object = try bucketOptionsAlloc(arena, valueObject(requiredObjectValue(mode, "buckets")) orelse return error.InvalidConfiguration) });
    }
}

fn bucketOptionsAlloc(arena: std.mem.Allocator, buckets: []const value.Field) ProviderError!std.json.ObjectMap {
    var result = std.json.ObjectMap.empty;
    const kind = requiredObjectString(buckets, "kind");
    if (std.mem.eql(u8, kind, "LINEAR")) {
        var linear = std.json.ObjectMap.empty;
        try linear.put(arena, "numFiniteBuckets", .{ .integer = requiredObjectInteger(buckets, "count") });
        try linear.put(arena, "width", .{ .float = microsToFloat(requiredObjectInteger(buckets, "width_micros")) });
        try linear.put(arena, "offset", .{ .float = microsToFloat(requiredObjectInteger(buckets, "offset_micros")) });
        try result.put(arena, "linearBuckets", .{ .object = linear });
    } else if (std.mem.eql(u8, kind, "EXPONENTIAL")) {
        var exponential = std.json.ObjectMap.empty;
        try exponential.put(arena, "numFiniteBuckets", .{ .integer = requiredObjectInteger(buckets, "count") });
        try exponential.put(arena, "growthFactor", .{ .float = microsToFloat(requiredObjectInteger(buckets, "growth_factor_micros")) });
        try exponential.put(arena, "scale", .{ .float = microsToFloat(requiredObjectInteger(buckets, "scale_micros")) });
        try result.put(arena, "exponentialBuckets", .{ .object = exponential });
    } else if (std.mem.eql(u8, kind, "EXPLICIT")) {
        var explicit = std.json.ObjectMap.empty;
        var bounds = std.json.Array.init(arena);
        for (valueList(requiredObjectValue(buckets, "bounds_micros")) orelse return error.InvalidConfiguration) |candidate| try bounds.append(.{ .float = microsToFloat(valueInteger(candidate) orelse return error.InvalidConfiguration) });
        try explicit.put(arena, "bounds", .{ .array = bounds });
        try result.put(arena, "explicitBuckets", .{ .object = explicit });
    } else return error.InvalidConfiguration;
    return result;
}

fn createPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    const project = try requiredString(node.inputs, "project_id");
    const name = try requiredString(node.inputs, "name");
    return switch (kind) {
        .bucket => std.fmt.allocPrint(allocator, "/v2/projects/{s}/locations/{s}/buckets:createAsync?bucketId={s}", .{ project, try requiredString(node.inputs, "location"), name }),
        .view => std.fmt.allocPrint(allocator, "/v2/projects/{s}/locations/{s}/buckets/{s}/views?viewId={s}", .{ project, try requiredString(node.inputs, "location"), try requiredString(node.inputs, "bucket_name"), name }),
        .sink => std.fmt.allocPrint(allocator, "/v2/projects/{s}/sinks?uniqueWriterIdentity={s}", .{ project, if (requiredBoolean(node.inputs, "unique_writer_identity")) "true" else "false" }),
        .exclusion => std.fmt.allocPrint(allocator, "/v2/projects/{s}/exclusions", .{project}),
        .metric => std.fmt.allocPrint(allocator, "/v2/projects/{s}/metrics", .{project}),
    } catch return error.OutOfMemory;
}

fn updatePathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind, physical: []const u8) ProviderError![]const u8 {
    return switch (kind) {
        .bucket => std.fmt.allocPrint(allocator, "/v2/{s}:updateAsync?updateMask={s}", .{ physical, bucket_update_mask }),
        .view => std.fmt.allocPrint(allocator, "/v2/{s}?updateMask={s}", .{ physical, view_update_mask }),
        .sink => std.fmt.allocPrint(allocator, "/v2/{s}?updateMask={s}&uniqueWriterIdentity={s}", .{ physical, sink_update_mask, if (requiredBoolean(node.inputs, "unique_writer_identity")) "true" else "false" }),
        .exclusion => std.fmt.allocPrint(allocator, "/v2/{s}?updateMask={s}", .{ physical, exclusion_update_mask }),
        .metric => std.fmt.allocPrint(allocator, "/v2/{s}", .{physical}),
    } catch return error.OutOfMemory;
}

fn stablePhysicalAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    const project = try requiredString(node.inputs, "project_id");
    const name = try requiredString(node.inputs, "name");
    return switch (kind) {
        .bucket => std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}/buckets/{s}", .{ project, try requiredString(node.inputs, "location"), name }),
        .view => std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}/buckets/{s}/views/{s}", .{ project, try requiredString(node.inputs, "location"), try requiredString(node.inputs, "bucket_name"), name }),
        .sink => std.fmt.allocPrint(allocator, "projects/{s}/sinks/{s}", .{ project, name }),
        .exclusion => std.fmt.allocPrint(allocator, "projects/{s}/exclusions/{s}", .{ project, name }),
        .metric => std.fmt.allocPrint(allocator, "projects/{s}/metrics/{s}", .{ project, name }),
    } catch return error.OutOfMemory;
}

fn validatePhysical(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind, physical: []const u8) ProviderError!void {
    const expected = try stablePhysicalAlloc(allocator, node, kind);
    defer allocator.free(expected);
    if (!std.mem.eql(u8, expected, physical)) return error.InvalidConfiguration;
}

fn validateBucketTransition(desired: value.Value, observed: value.Value) ProviderError!void {
    const desired_analytics = requiredBoolean(desired, "analytics_enabled");
    const observed_analytics = requiredBoolean(observed, "analytics_enabled");
    const desired_locked = requiredBoolean(desired, "locked");
    const observed_locked = requiredBoolean(observed, "locked");
    if ((observed_analytics and !desired_analytics) or (observed_locked and !desired_locked)) return error.InvalidConfiguration;
    if (observed_locked and inputChanged(desired, observed, "retention_days")) return error.InvalidConfiguration;
    const desired_kms = requiredValue(desired, "kms_key_name") catch return error.InvalidConfiguration;
    const observed_kms = requiredValue(observed, "kms_key_name") catch return error.InvalidConfiguration;
    if (valueString(observed_kms)) |present| if (present.len != 0) if (valueString(desired_kms)) |next| if (next.len == 0) return error.InvalidConfiguration;
}

fn kindOf(node: resource.ResourceNode) ?Kind {
    if (std.mem.eql(u8, node.type_name, "gcp.logging.Bucket")) return .bucket;
    if (std.mem.eql(u8, node.type_name, "gcp.logging.View")) return .view;
    if (std.mem.eql(u8, node.type_name, "gcp.logging.Sink")) return .sink;
    if (std.mem.eql(u8, node.type_name, "gcp.logging.Exclusion")) return .exclusion;
    if (std.mem.eql(u8, node.type_name, "gcp.logging.Metric")) return .metric;
    return null;
}

fn driftedInputsAlloc(allocator: std.mem.Allocator, inputs: value.Value) !value.Value {
    const source = valueObject(inputs) orelse return error.InvalidConfiguration;
    const fields = try allocator.alloc(value.Field, source.len + 1);
    defer allocator.free(fields);
    @memcpy(fields[0..source.len], source);
    fields[source.len] = .{ .name = "_remote_drift", .value = .{ .boolean = true } };
    return value.Value.initOwned(allocator, .{ .object = fields });
}

fn jsonSubset(remote: std.json.Value, desired: std.json.Value) bool {
    return switch (desired) {
        .null => remote == .null,
        .bool => |expected| remote == .bool and remote.bool == expected,
        .integer => |expected| switch (remote) {
            .integer => |actual| actual == expected,
            .float => |actual| actual == @as(f64, @floatFromInt(expected)),
            else => false,
        },
        .float => |expected| switch (remote) {
            .integer => |actual| @as(f64, @floatFromInt(actual)) == expected,
            .float => |actual| @abs(actual - expected) < 0.0000001,
            else => false,
        },
        .number_string => |expected| remote == .number_string and std.mem.eql(u8, remote.number_string, expected),
        .string => |expected| remote == .string and std.mem.eql(u8, remote.string, expected),
        .array => |expected| blk: {
            if (remote != .array or remote.array.items.len != expected.items.len) break :blk false;
            for (remote.array.items, expected.items) |actual, wanted| if (!jsonSubset(actual, wanted)) break :blk false;
            break :blk true;
        },
        .object => |expected| blk: {
            if (remote != .object) break :blk false;
            var iterator = expected.iterator();
            while (iterator.next()) |entry| {
                const actual = remote.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!jsonSubset(actual, entry.value_ptr.*)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn stringArrayAlloc(context: *provider_mod.OperationContext, allocator: std.mem.Allocator, values: []const value.Value) ProviderError!std.json.Array {
    var result = std.json.Array.init(allocator);
    for (values) |candidate| try result.append(.{ .string = try resolveString(context, candidate) });
    return result;
}

fn stringMapAlloc(allocator: std.mem.Allocator, fields: []const value.Field) ProviderError!std.json.ObjectMap {
    var result = std.json.ObjectMap.empty;
    for (fields) |field| try result.put(allocator, field.name, .{ .string = valueString(field.value) orelse return error.InvalidConfiguration });
    return result;
}

fn resolveString(context: *provider_mod.OperationContext, candidate: value.Value) ProviderError![]const u8 {
    return switch (candidate) {
        .string => |text| text,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}

fn requiredValue(inputs: value.Value, name: []const u8) ProviderError!value.Value {
    return objectField(valueObject(inputs) orelse return error.InvalidConfiguration, name) orelse error.InvalidConfiguration;
}

fn requiredString(inputs: value.Value, name: []const u8) ProviderError![]const u8 {
    return valueString(try requiredValue(inputs, name)) orelse error.InvalidConfiguration;
}

fn requiredInteger(inputs: value.Value, name: []const u8) ProviderError!i64 {
    return valueInteger(try requiredValue(inputs, name)) orelse error.InvalidConfiguration;
}

fn requiredBoolean(inputs: value.Value, name: []const u8) bool {
    return valueBoolean(requiredValue(inputs, name) catch return false) orelse false;
}

fn requiredObject(inputs: value.Value, name: []const u8) ProviderError![]const value.Field {
    return valueObject(try requiredValue(inputs, name)) orelse error.InvalidConfiguration;
}

fn requiredList(inputs: value.Value, name: []const u8) ProviderError![]const value.Value {
    return valueList(try requiredValue(inputs, name)) orelse error.InvalidConfiguration;
}

fn requiredObjectValue(fields: []const value.Field, name: []const u8) value.Value {
    return objectField(fields, name) orelse unreachable;
}

fn requiredObjectString(fields: []const value.Field, name: []const u8) []const u8 {
    return valueString(requiredObjectValue(fields, name)) orelse unreachable;
}

fn requiredObjectInteger(fields: []const value.Field, name: []const u8) i64 {
    return valueInteger(requiredObjectValue(fields, name)) orelse unreachable;
}

fn requiredObjectBoolean(fields: []const value.Field, name: []const u8) bool {
    return valueBoolean(requiredObjectValue(fields, name)) orelse unreachable;
}

fn objectField(fields: []const value.Field, name: []const u8) ?value.Value {
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return null;
}

fn valueObject(candidate: value.Value) ?[]const value.Field {
    return switch (candidate) {
        .object => |fields| fields,
        else => null,
    };
}

fn valueList(candidate: value.Value) ?[]const value.Value {
    return switch (candidate) {
        .list => |items| items,
        else => null,
    };
}

fn valueString(candidate: value.Value) ?[]const u8 {
    return switch (candidate) {
        .string => |text| text,
        else => null,
    };
}

fn valueInteger(candidate: value.Value) ?i64 {
    return switch (candidate) {
        .integer => |number| number,
        else => null,
    };
}

fn valueBoolean(candidate: value.Value) ?bool {
    return switch (candidate) {
        .boolean => |flag| flag,
        else => null,
    };
}

fn inputChanged(desired: value.Value, observed: value.Value, name: []const u8) bool {
    const left = requiredValue(desired, name) catch return true;
    const right = requiredValue(observed, name) catch return true;
    const left_json = left.canonicalJsonAlloc(std.heap.page_allocator) catch return true;
    defer std.heap.page_allocator.free(left_json);
    const right_json = right.canonicalJsonAlloc(std.heap.page_allocator) catch return true;
    defer std.heap.page_allocator.free(right_json);
    return !std.mem.eql(u8, left_json, right_json);
}

fn jsonObject(candidate: std.json.Value) ?std.json.ObjectMap {
    return switch (candidate) {
        .object => |object| object,
        else => null,
    };
}

fn jsonString(candidate: std.json.Value) ?[]const u8 {
    return switch (candidate) {
        .string => |text| text,
        else => null,
    };
}

fn microsToFloat(micros: i64) f64 {
    return @as(f64, @floatFromInt(micros)) / 1_000_000.0;
}
