const std = @import("std");
const aip = @import("aip.zig");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;
const Kind = enum { cluster, autoscaling_policy, workflow_template };

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
            return provider_mod.DiffResult.init(context.allocator, .replace, &.{"Dataproc resource identity changed"});
        const desired_json = try bodyAlloc(context, node, kind, null);
        defer context.allocator.free(desired_json);
        const remote_json = outputString(observed.*, "__remote_spec") orelse return provider_mod.DiffResult.init(context.allocator, .update, &.{"Dataproc configuration differs"});
        if (try jsonContainsAlloc(context.allocator, desired_json, remote_json))
            return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        return provider_mod.DiffResult.init(context.allocator, .update, &.{"Dataproc configuration differs"});
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
        if (kind == .cluster) return pendingResult(context, node, kind, response.body);
        const physical = try physicalAlloc(context.allocator, node, kind);
        defer context.allocator.free(physical);
        return resultFromJson(context, node, kind, physical, response.body);
    }

    pub fn update(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(node, kind, observed.physical_id);
        var classification = try Handler.diff(context, node, observed);
        defer classification.deinit();
        if (classification.kind == .noop) return observed.clone(context.allocator);
        if (classification.kind != .update) return error.InvalidConfiguration;

        const version = if (kind == .workflow_template) outputInteger(observed.*, "version") else null;
        const body = try bodyAlloc(context, node, kind, version);
        defer context.allocator.free(body);
        const path = try updatePathAlloc(context.allocator, node, kind, observed.physical_id);
        defer context.allocator.free(path);
        const method = if (kind == .cluster) "PATCH" else "PUT";
        var response = try self.request(context, method, path, body);
        defer response.deinit(context.allocator);
        if (kind == .cluster) return pendingResult(context, node, kind, response.body);
        return resultFromJson(context, node, kind, observed.physical_id, response.body);
    }

    pub fn delete(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical: []const u8) ProviderError!void {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(node, kind, physical);
        if (!std.mem.eql(u8, try requiredString(node.inputs, "removal_policy"), "delete") or !context.destructive_confirmation)
            return error.DestructiveConfirmationRequired;
        var request_id: [36]u8 = undefined;
        aip.requestId("ziac", node.id, "delete", &request_id);
        const path = if (kind == .cluster)
            try std.fmt.allocPrint(context.allocator, "/v1/{s}?requestId={s}", .{ physical, request_id[0..] })
        else
            try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical});
        defer context.allocator.free(path);
        var response = self.request(context, "DELETE", path, "") catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer response.deinit(context.allocator);
        if (kind == .cluster) {
            const handle = try operationNameAlloc(context.allocator, response.body);
            defer context.allocator.free(handle);
            var completed = try self.waitOperation(context, handle);
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

    fn waitOperation(self: Handler, context: *provider_mod.OperationContext, handle: []const u8) ProviderError!operation.Result {
        const base = try std.fmt.allocPrint(context.allocator, "{s}/v1", .{std.mem.trimEnd(u8, self.client.endpoints.dataproc, "/")});
        defer context.allocator.free(base);
        var target = operation.Target.genericAlloc(context.allocator, base, handle) catch return error.OutOfMemory;
        defer target.deinit(context.allocator);
        return operation.waitAlloc(self.client, context, target, self.operation_policy);
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, method: []const u8, path: []const u8, body: []const u8) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, .{ .api = .dataproc, .method = method, .path = path, .body = body }, &diagnostic);
    }
};

fn kindOf(node: resource.ResourceNode) ?Kind {
    const mappings = [_]struct { name: []const u8, kind: Kind }{
        .{ .name = "gcp.dataproc.Cluster", .kind = .cluster },
        .{ .name = "gcp.dataproc.AutoscalingPolicy", .kind = .autoscaling_policy },
        .{ .name = "gcp.dataproc.WorkflowTemplate", .kind = .workflow_template },
    };
    for (mappings) |mapping| if (std.mem.eql(u8, node.type_name, mapping.name)) return mapping.kind;
    return null;
}

fn collection(kind: Kind) []const u8 {
    return switch (kind) {
        .cluster => "clusters",
        .autoscaling_policy => "autoscalingPolicies",
        .workflow_template => "workflowTemplates",
    };
}

fn physicalAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "projects/{s}/regions/{s}/{s}/{s}", .{
        try requiredString(node.inputs, "project_id"),
        try requiredString(node.inputs, "region"),
        collection(kind),
        try requiredString(node.inputs, "name"),
    }) catch error.OutOfMemory;
}

fn validatePhysical(node: resource.ResourceNode, kind: Kind, physical: []const u8) ProviderError!void {
    if (std.mem.indexOfAny(u8, physical, "?# \t\r\n") != null) return error.InvalidConfiguration;
    const expected = try physicalAlloc(std.heap.page_allocator, node, kind);
    defer std.heap.page_allocator.free(expected);
    if (!std.mem.eql(u8, expected, physical)) return error.InvalidConfiguration;
}

fn createPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    const project = try requiredString(node.inputs, "project_id");
    const region = try requiredString(node.inputs, "region");
    if (kind == .cluster) {
        var request_id: [36]u8 = undefined;
        aip.requestId("ziac", node.id, "create", &request_id);
        return std.fmt.allocPrint(allocator, "/v1/projects/{s}/regions/{s}/clusters?requestId={s}", .{ project, region, request_id[0..] }) catch error.OutOfMemory;
    }
    return std.fmt.allocPrint(allocator, "/v1/projects/{s}/regions/{s}/{s}", .{ project, region, collection(kind) }) catch error.OutOfMemory;
}

fn updatePathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind, physical: []const u8) ProviderError![]const u8 {
    if (kind != .cluster) return std.fmt.allocPrint(allocator, "/v1/{s}", .{physical}) catch error.OutOfMemory;
    var request_id: [36]u8 = undefined;
    aip.requestId("ziac", node.id, "update", &request_id);
    return std.fmt.allocPrint(allocator, "/v1/{s}?updateMask=config.workerConfig.numInstances,config.secondaryWorkerConfig.numInstances,labels&requestId={s}", .{ physical, request_id[0..] }) catch error.OutOfMemory;
}

fn pendingResult(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, body: []const u8) ProviderError!provider_mod.ResourceResult {
    const handle = try operationNameAlloc(context.allocator, body);
    defer context.allocator.free(handle);
    const physical = try physicalAlloc(context.allocator, node, kind);
    defer context.allocator.free(physical);
    const outputs = [_]state.StateOutput{.{ .name = "state", .value = .{ .unknown_reason = "Dataproc operation pending" } }};
    var result = try provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &outputs, handle);
    result.completed = false;
    return result;
}

fn resultFromJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, physical: []const u8, body: []const u8) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const remote = std.json.Stringify.valueAlloc(context.allocator, parsed.value, .{}) catch return error.OutOfMemory;
    defer context.allocator.free(remote);
    const discovered_name = switch (kind) {
        .cluster => jsonString(root.get("clusterName")) orelse try requiredString(node.inputs, "name"),
        else => jsonString(root.get("name")) orelse physical,
    };
    _ = discovered_name;
    const status = jsonObject(root.get("status") orelse .null);
    const outputs = [_]state.StateOutput{
        .{ .name = "__remote_spec", .value = .{ .string = remote } },
        .{ .name = "name", .value = .{ .string = physical } },
        .{ .name = "state", .value = .{ .string = if (status) |object| jsonString(object.get("state")) orelse "STATE_UNSPECIFIED" else "STATE_UNSPECIFIED" } },
        .{ .name = "uuid", .value = .{ .string = jsonString(root.get("clusterUuid")) orelse "" } },
        .{ .name = "version", .value = .{ .integer = jsonInteger(root.get("version")) orelse 0 } },
    };
    return provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &outputs, null);
}

fn bodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, version: ?i64) ProviderError![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = std.json.ObjectMap.empty;
    const name = try requiredString(node.inputs, "name");
    switch (kind) {
        .cluster => {
            try root.put(arena, "projectId", .{ .string = try requiredString(node.inputs, "project_id") });
            try root.put(arena, "clusterName", .{ .string = name });
            try root.put(arena, "labels", try valueJson(context, arena, try requiredValue(node.inputs, "labels")));
            try root.put(arena, "config", try clusterConfigJson(context, arena, node.inputs));
        },
        .autoscaling_policy => {
            try root.put(arena, "id", .{ .string = name });
            try root.put(arena, "labels", try valueJson(context, arena, try requiredValue(node.inputs, "labels")));
            try root.put(arena, "basicAlgorithm", try autoscalingJson(context, arena, node.inputs));
        },
        .workflow_template => {
            try root.put(arena, "id", .{ .string = name });
            try root.put(arena, "labels", try valueJson(context, arena, try requiredValue(node.inputs, "labels")));
            try root.put(arena, "placement", try renameJson(context, arena, try requiredValue(node.inputs, "placement")));
            try root.put(arena, "jobs", try workflowJobsJson(context, arena, try requiredValue(node.inputs, "jobs")));
            const timeout = try requiredInteger(node.inputs, "dag_timeout_seconds");
            if (timeout != 0) try root.put(arena, "dagTimeout", .{ .string = try std.fmt.allocPrint(arena, "{d}s", .{timeout}) });
            if (version) |token| try root.put(arena, "version", .{ .integer = token });
        },
    }
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch error.OutOfMemory;
}

fn clusterConfigJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, inputs: value.Value) ProviderError!std.json.Value {
    var config = std.json.ObjectMap.empty;
    var gce = std.json.ObjectMap.empty;
    inline for (.{ .{ "zone", "zoneUri" }, .{ "service_account", "serviceAccount" }, .{ "subnetwork", "subnetworkUri" }, .{ "network", "networkUri" } }) |mapping| {
        const text = try resolvedString(context, inputs, mapping[0]);
        if (text.len != 0) try gce.put(arena, mapping[1], .{ .string = text });
    }
    try config.put(arena, "gceClusterConfig", .{ .object = gce });
    try config.put(arena, "masterConfig", try instanceGroupJson(context, arena, try requiredValue(inputs, "master")));
    try config.put(arena, "workerConfig", try instanceGroupJson(context, arena, try requiredValue(inputs, "worker")));
    const secondary = try requiredValue(inputs, "secondary_worker");
    if (valueObject(secondary)) |fields| if (fields.len != 0) try config.put(arena, "secondaryWorkerConfig", try instanceGroupJson(context, arena, secondary));
    var software = std.json.ObjectMap.empty;
    const image = try requiredString(inputs, "image_version");
    if (image.len != 0) try software.put(arena, "imageVersion", .{ .string = image });
    try software.put(arena, "properties", try valueJson(context, arena, try requiredValue(inputs, "properties")));
    try config.put(arena, "softwareConfig", .{ .object = software });
    var endpoint = std.json.ObjectMap.empty;
    try endpoint.put(arena, "enableHttpPortAccess", .{ .bool = try requiredBoolean(inputs, "component_gateway") });
    try config.put(arena, "endpointConfig", .{ .object = endpoint });
    const autoscale = try resolvedString(context, inputs, "autoscaling_policy");
    if (autoscale.len != 0) {
        var selected = std.json.ObjectMap.empty;
        try selected.put(arena, "policyUri", .{ .string = autoscale });
        try config.put(arena, "autoscalingConfig", .{ .object = selected });
    }
    const kms = try resolvedString(context, inputs, "kms_key_name");
    if (kms.len != 0) {
        var encryption = std.json.ObjectMap.empty;
        try encryption.put(arena, "gcePdKmsKeyName", .{ .string = kms });
        try config.put(arena, "encryptionConfig", .{ .object = encryption });
    }
    try config.put(arena, "initializationActions", try initActionsJson(context, arena, try requiredValue(inputs, "init_actions")));
    return .{ .object = config };
}

fn instanceGroupJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    const fields = valueObject(source) orelse return error.InvalidConfiguration;
    var group = std.json.ObjectMap.empty;
    try group.put(arena, "numInstances", .{ .integer = try objectInteger(fields, "instances") });
    try group.put(arena, "machineTypeUri", .{ .string = try objectString(fields, "machine_type") });
    try group.put(arena, "preemptibility", .{ .string = try enumUpperAlloc(arena, try objectString(fields, "preemptibility")) });
    var disk = std.json.ObjectMap.empty;
    try disk.put(arena, "bootDiskType", .{ .string = try objectString(fields, "disk_type") });
    try disk.put(arena, "bootDiskSizeGb", .{ .integer = try objectInteger(fields, "disk_size_gb") });
    try disk.put(arena, "numLocalSsds", .{ .integer = try objectInteger(fields, "local_ssds") });
    try group.put(arena, "diskConfig", .{ .object = disk });
    _ = context;
    return .{ .object = group };
}

fn initActionsJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    const items = valueList(source) orelse return error.InvalidConfiguration;
    var result = std.json.Array.init(arena);
    for (items) |item| {
        const fields = valueObject(item) orelse return error.InvalidConfiguration;
        var action = std.json.ObjectMap.empty;
        try action.put(arena, "executableFile", .{ .string = try objectString(fields, "executable_file") });
        try action.put(arena, "executionTimeout", .{ .string = try std.fmt.allocPrint(arena, "{d}s", .{try objectInteger(fields, "timeout_seconds")}) });
        try result.append(.{ .object = action });
    }
    _ = context;
    return .{ .array = result };
}

fn autoscalingJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, inputs: value.Value) ProviderError!std.json.Value {
    var result = std.json.ObjectMap.empty;
    try result.put(arena, "workerConfig", try renameJson(context, arena, try requiredValue(inputs, "worker")));
    const secondary = try requiredValue(inputs, "secondary_worker");
    if (valueObject(secondary)) |fields| if (fields.len != 0) try result.put(arena, "secondaryWorkerConfig", try renameJson(context, arena, secondary));
    const algorithm = valueObject(try requiredValue(inputs, "algorithm")) orelse return error.InvalidConfiguration;
    const yarn = try requiredObjectValue(algorithm, "yarn");
    try result.put(arena, "yarnConfig", try renameJson(context, arena, yarn));
    return .{ .object = result };
}

fn workflowJobsJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    const items = valueList(source) orelse return error.InvalidConfiguration;
    var result = std.json.Array.init(arena);
    for (items) |item| try result.append(try renameJson(context, arena, item));
    return .{ .array = result };
}

fn renameJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    return switch (source) {
        .object => |fields| blk: {
            var result = std.json.ObjectMap.empty;
            for (fields) |field| try result.put(arena, try camelAlloc(arena, field.name), try renameJson(context, arena, field.value));
            break :blk .{ .object = result };
        },
        .list => |items| blk: {
            var result = std.json.Array.init(arena);
            for (items) |item| try result.append(try renameJson(context, arena, item));
            break :blk .{ .array = result };
        },
        else => valueJson(context, arena, source),
    };
}

fn valueJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    return switch (source) {
        .string => |text| .{ .string = text },
        .integer => |number| .{ .integer = number },
        .boolean => |flag| .{ .bool = flag },
        .list, .object => renameJson(context, arena, source),
        .output_ref => |reference| .{ .string = try context.resolveOutputString(reference) },
        .secret_ref, .unknown_reason => error.InvalidConfiguration,
    };
}

fn operationNameAlloc(allocator: std.mem.Allocator, body: []const u8) ProviderError![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const name = jsonString((jsonObject(parsed.value) orelse return error.ProviderBug).get("name")) orelse return error.ProviderBug;
    if (std.mem.indexOf(u8, name, "/operations/") == null) return error.ProviderBug;
    return allocator.dupe(u8, name) catch error.OutOfMemory;
}

fn operationResponseAlloc(allocator: std.mem.Allocator, body: []const u8) ProviderError!?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const response = (jsonObject(parsed.value) orelse return error.ProviderBug).get("response") orelse return null;
    return std.json.Stringify.valueAlloc(allocator, response, .{}) catch error.OutOfMemory;
}

fn jsonContainsAlloc(allocator: std.mem.Allocator, desired_json: []const u8, remote_json: []const u8) ProviderError!bool {
    var desired = std.json.parseFromSlice(std.json.Value, allocator, desired_json, .{}) catch return error.ProviderBug;
    defer desired.deinit();
    var remote = std.json.parseFromSlice(std.json.Value, allocator, remote_json, .{}) catch return error.ProviderBug;
    defer remote.deinit();
    return jsonContains(desired.value, remote.value);
}

fn jsonContains(desired: std.json.Value, remote: std.json.Value) bool {
    if (std.meta.activeTag(desired) != std.meta.activeTag(remote)) return false;
    return switch (desired) {
        .object => |object| blk: {
            for (object.keys()) |key| if (!jsonContains(object.get(key).?, remote.object.get(key) orelse break :blk false)) break :blk false;
            break :blk true;
        },
        .array => |array| blk: {
            if (array.items.len != remote.array.items.len) break :blk false;
            for (array.items, remote.array.items) |left, right| if (!jsonContains(left, right)) break :blk false;
            break :blk true;
        },
        .null => true,
        .bool => |flag| flag == remote.bool,
        .integer => |number| number == remote.integer,
        .float => |number| number == remote.float,
        .number_string => |text| std.mem.eql(u8, text, remote.number_string),
        .string => |text| std.mem.eql(u8, text, remote.string),
    };
}

fn identityFields(kind: Kind) []const []const u8 {
    return switch (kind) {
        .cluster => &.{ "project_id", "region", "name", "zone", "network", "subnetwork", "service_account", "kms_key_name" },
        .autoscaling_policy, .workflow_template => &.{ "project_id", "region", "name" },
    };
}

fn identityChanged(node: resource.ResourceNode, observed: *const provider_mod.ResourceResult, fields: []const []const u8) bool {
    for (fields) |name| {
        const desired = findField(node.inputs, name) orelse return true;
        const current = findField(observed.observed_inputs, name) orelse return true;
        if (!valuesEqual(desired, current)) return true;
    }
    return false;
}

fn findField(source: value.Value, name: []const u8) ?value.Value {
    const fields = valueObject(source) orelse return null;
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return null;
}
fn valuesEqual(left: value.Value, right: value.Value) bool {
    const left_json = left.canonicalJsonAlloc(std.heap.page_allocator) catch return false;
    defer std.heap.page_allocator.free(left_json);
    const right_json = right.canonicalJsonAlloc(std.heap.page_allocator) catch return false;
    defer std.heap.page_allocator.free(right_json);
    return std.mem.eql(u8, left_json, right_json);
}
fn requiredValue(source: value.Value, name: []const u8) ProviderError!value.Value {
    return findField(source, name) orelse error.InvalidConfiguration;
}
fn requiredString(source: value.Value, name: []const u8) ProviderError![]const u8 {
    return valueString(try requiredValue(source, name)) orelse error.InvalidConfiguration;
}
fn requiredInteger(source: value.Value, name: []const u8) ProviderError!i64 {
    const selected = try requiredValue(source, name);
    return if (selected == .integer) selected.integer else error.InvalidConfiguration;
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
fn requiredObjectValue(fields: []const value.Field, name: []const u8) ProviderError!value.Value {
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return error.InvalidConfiguration;
}
fn objectString(fields: []const value.Field, name: []const u8) ProviderError![]const u8 {
    return valueString(try requiredObjectValue(fields, name)) orelse error.InvalidConfiguration;
}
fn objectInteger(fields: []const value.Field, name: []const u8) ProviderError!i64 {
    const selected = try requiredObjectValue(fields, name);
    return if (selected == .integer) selected.integer else error.InvalidConfiguration;
}
fn valueObject(source: value.Value) ?[]const value.Field {
    return if (source == .object) source.object else null;
}
fn valueList(source: value.Value) ?[]const value.Value {
    return if (source == .list) source.list else null;
}
fn valueString(source: value.Value) ?[]const u8 {
    return if (source == .string) source.string else null;
}
fn outputString(result: provider_mod.ResourceResult, name: []const u8) ?[]const u8 {
    for (result.outputs) |entry| if (std.mem.eql(u8, entry.name, name) and entry.value == .string) return entry.value.string;
    return null;
}
fn outputInteger(result: provider_mod.ResourceResult, name: []const u8) ?i64 {
    for (result.outputs) |entry| if (std.mem.eql(u8, entry.name, name) and entry.value == .integer) return entry.value.integer;
    return null;
}
fn jsonObject(source: std.json.Value) ?std.json.ObjectMap {
    return if (source == .object) source.object else null;
}
fn jsonString(source: ?std.json.Value) ?[]const u8 {
    const selected = source orelse return null;
    return if (selected == .string) selected.string else null;
}
fn jsonInteger(source: ?std.json.Value) ?i64 {
    const selected = source orelse return null;
    return if (selected == .integer) selected.integer else null;
}

fn camelAlloc(allocator: std.mem.Allocator, source: []const u8) ProviderError![]u8 {
    var result = std.ArrayList(u8).empty;
    var upper = false;
    for (source) |character| {
        if (character == '_') {
            upper = true;
            continue;
        }
        try result.append(allocator, if (upper) std.ascii.toUpper(character) else character);
        upper = false;
    }
    return result.toOwnedSlice(allocator) catch error.OutOfMemory;
}

fn enumUpperAlloc(allocator: std.mem.Allocator, source: []const u8) ProviderError![]u8 {
    const result = allocator.alloc(u8, source.len) catch return error.OutOfMemory;
    for (source, 0..) |character, index| result[index] = std.ascii.toUpper(character);
    return result;
}
