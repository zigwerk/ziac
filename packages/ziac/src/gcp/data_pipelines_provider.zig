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
        return std.mem.eql(u8, node.type_name, "gcp.datapipelines.Pipeline");
    }

    pub fn read(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
        try context.checkActive();
        if (!supports(node)) return error.InvalidConfiguration;
        const expected = try physicalAlloc(context.allocator, node);
        defer context.allocator.free(expected);
        const physical = physical_override orelse context.physical_id orelse expected;
        try validatePhysical(physical);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical});
        defer context.allocator.free(path);
        var response = self.request(context, "GET", path, "") catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try resultFromJson(context, node, response.body) };
    }

    pub fn diff(context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        if (!supports(node)) return error.InvalidConfiguration;
        try validatePhysical(observed.physical_id);
        const remote_json = outputString(observed.*, "__remote_spec") orelse return error.ProviderBug;
        const desired_json = try bodyAlloc(context, node);
        defer context.allocator.free(desired_json);
        var remote = std.json.parseFromSlice(std.json.Value, context.allocator, remote_json, .{}) catch return error.ProviderBug;
        defer remote.deinit();
        var desired = std.json.parseFromSlice(std.json.Value, context.allocator, desired_json, .{}) catch return error.ProviderBug;
        defer desired.deinit();
        if (jsonContains(desired.value, remote.value)) return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        return provider_mod.DiffResult.init(context.allocator, .update, &.{"Data Pipeline configuration differs"});
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        if (!supports(node)) return error.InvalidConfiguration;
        const project = try requiredLiteralString(node.inputs, "project_id");
        const location = try requiredLiteralString(node.inputs, "location");
        const path = try std.fmt.allocPrint(context.allocator, "/v1/projects/{s}/locations/{s}/pipelines", .{ project, location });
        defer context.allocator.free(path);
        const body = try bodyAlloc(context, node);
        defer context.allocator.free(body);
        var response = try self.request(context, "POST", path, body);
        defer response.deinit(context.allocator);
        return resultFromJson(context, node, response.body);
    }

    pub fn update(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        if (!supports(node)) return error.InvalidConfiguration;
        try validatePhysical(observed.physical_id);
        const remote_json = outputString(observed.*, "__remote_spec") orelse return error.ProviderBug;
        const desired_json = try bodyAlloc(context, node);
        defer context.allocator.free(desired_json);
        const mask = try changedMaskAlloc(context.allocator, desired_json, remote_json);
        defer context.allocator.free(mask);
        if (mask.len == 0) return observed.clone(context.allocator);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}?updateMask={s}", .{ observed.physical_id, mask });
        defer context.allocator.free(path);
        var response = try self.request(context, "PATCH", path, desired_json);
        defer response.deinit(context.allocator);
        return resultFromJson(context, node, response.body);
    }

    pub fn delete(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical: []const u8) ProviderError!void {
        try context.checkActive();
        if (!supports(node)) return error.InvalidConfiguration;
        try validatePhysical(physical);
        if (!std.mem.eql(u8, try requiredLiteralString(node.inputs, "removal_policy"), "delete") or !context.destructive_confirmation) return error.DestructiveConfirmationRequired;
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical});
        defer context.allocator.free(path);
        var response = self.request(context, "DELETE", path, "") catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        response.deinit(context.allocator);
    }

    pub fn importResource(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical: []const u8) ProviderError!provider_mod.ResourceResult {
        try validatePhysical(physical);
        var found = try self.read(context, node, physical);
        defer found.deinit();
        return switch (found) {
            .absent => error.NotFound,
            .present => |present| present.clone(context.allocator),
        };
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, method: []const u8, path: []const u8, body: []const u8) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, .{ .api = .data_pipelines, .method = method, .path = path, .body = body }, &diagnostic);
    }
};

fn physicalAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}/pipelines/{s}", .{
        try requiredLiteralString(node.inputs, "project_id"),
        try requiredLiteralString(node.inputs, "location"),
        try requiredLiteralString(node.inputs, "name"),
    }) catch error.OutOfMemory;
}
fn validatePhysical(physical: []const u8) ProviderError!void {
    if (!std.mem.startsWith(u8, physical, "projects/") or std.mem.indexOf(u8, physical, "/locations/") == null or std.mem.indexOf(u8, physical, "/pipelines/") == null or std.mem.indexOfAny(u8, physical, "?# \t\r\n") != null) return error.InvalidConfiguration;
}

fn bodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = std.json.ObjectMap.empty;
    const physical = try physicalAlloc(arena, node);
    try root.put(arena, "name", .{ .string = physical });
    try root.put(arena, "displayName", .{ .string = try requiredLiteralString(node.inputs, "display_name") });
    try root.put(arena, "type", .{ .string = try requiredLiteralString(node.inputs, "pipeline_type") });
    try root.put(arena, "state", .{ .string = "STATE_ACTIVE" });
    const scheduler = try requiredLiteralString(node.inputs, "scheduler_service_account_email");
    if (scheduler.len != 0) try root.put(arena, "schedulerServiceAccountEmail", .{ .string = scheduler });
    const schedule = try requiredValue(node.inputs, "schedule");
    if (valueObject(schedule)) |fields| if (fields.len != 0) {
        var wire = std.json.ObjectMap.empty;
        try wire.put(arena, "schedule", .{ .string = try requiredObjectString(fields, "cron") });
        try wire.put(arena, "timeZone", .{ .string = try requiredObjectString(fields, "time_zone") });
        try root.put(arena, "scheduleInfo", .{ .object = wire });
    };
    try root.put(arena, "workload", try workloadJson(context, arena, try requiredValue(node.inputs, "workload")));
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch error.OutOfMemory;
}

fn workloadJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    const fields = valueObject(source) orelse return error.InvalidConfiguration;
    const kind = try requiredObjectString(fields, "kind");
    var workload = std.json.ObjectMap.empty;
    var request = std.json.ObjectMap.empty;
    var launch = std.json.ObjectMap.empty;
    if (std.mem.eql(u8, kind, "flex_template")) {
        try launch.put(arena, "containerSpecGcsPath", .{ .string = try requiredObjectString(fields, "container_spec_gcs_path") });
        try launch.put(arena, "launchOptions", try valueJson(context, arena, try requiredObjectValue(fields, "launch_options")));
    } else if (std.mem.eql(u8, kind, "classic_template")) {
        try launch.put(arena, "gcsPath", .{ .string = try requiredObjectString(fields, "gcs_path") });
    } else return error.InvalidConfiguration;
    try launch.put(arena, "parameters", try valueJson(context, arena, try requiredObjectValue(fields, "parameters")));
    try launch.put(arena, "environment", try environmentJson(context, arena, try requiredObjectValue(fields, "environment")));
    try request.put(arena, "launchParameter", .{ .object = launch });
    try workload.put(arena, if (std.mem.eql(u8, kind, "flex_template")) "dataflowFlexTemplateRequest" else "dataflowLaunchTemplateRequest", .{ .object = request });
    return .{ .object = workload };
}

fn environmentJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    const fields = valueObject(source) orelse return error.InvalidConfiguration;
    var result = std.json.ObjectMap.empty;
    inline for (.{
        .{ "service_account_email", "serviceAccountEmail" }, .{ "temp_location", "tempLocation" }, .{ "staging_location", "stagingLocation" },
        .{ "subnetwork", "subnetwork" },                     .{ "machine_type", "machineType" },   .{ "kms_key_name", "kmsKeyName" },
        .{ "ip_configuration", "ipConfiguration" },
    }) |mapping| {
        const text = try resolvedObjectString(context, fields, mapping[0]);
        if (text.len != 0) try result.put(arena, mapping[1], .{ .string = text });
    }
    const num_workers = try requiredObjectInteger(fields, "num_workers");
    const max_workers = try requiredObjectInteger(fields, "max_workers");
    if (num_workers != 0) try result.put(arena, "numWorkers", .{ .integer = num_workers });
    if (max_workers != 0) try result.put(arena, "maxWorkers", .{ .integer = max_workers });
    const experiments = try requiredObjectValue(fields, "additional_experiments");
    if (valueList(experiments)) |items| if (items.len != 0) try result.put(arena, "additionalExperiments", try valueJson(context, arena, experiments));
    return .{ .object = result };
}

fn resultFromJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, body: []const u8) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const physical = jsonString(root.get("name")) orelse return error.ProviderBug;
    try validatePhysical(physical);
    const remote = try std.json.Stringify.valueAlloc(context.allocator, parsed.value, .{});
    defer context.allocator.free(remote);
    const outputs = [_]state.StateOutput{
        .{ .name = "__remote_spec", .value = .{ .string = remote } },
        .{ .name = "job_count", .value = .{ .integer = jsonInteger(root.get("jobCount")) orelse 0 } },
        .{ .name = "name", .value = .{ .string = physical } },
        .{ .name = "state", .value = .{ .string = jsonString(root.get("state")) orelse "STATE_UNSPECIFIED" } },
    };
    return provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &outputs, null);
}

fn changedMaskAlloc(allocator: std.mem.Allocator, desired_json: []const u8, remote_json: []const u8) ProviderError![]const u8 {
    var desired = std.json.parseFromSlice(std.json.Value, allocator, desired_json, .{}) catch return error.ProviderBug;
    defer desired.deinit();
    var remote = std.json.parseFromSlice(std.json.Value, allocator, remote_json, .{}) catch return error.ProviderBug;
    defer remote.deinit();
    const desired_root = jsonObject(desired.value) orelse return error.ProviderBug;
    const remote_root = jsonObject(remote.value) orelse return error.ProviderBug;
    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(allocator);
    for (desired_root.keys()) |name| {
        if (std.mem.eql(u8, name, "name") or std.mem.eql(u8, name, "state")) continue;
        const remote_value = remote_root.get(name) orelse {
            try names.append(allocator, name);
            continue;
        };
        if (!jsonValuesEqual(desired_root.get(name).?, remote_value)) try names.append(allocator, name);
    }
    std.mem.sort([]const u8, names.items, {}, lessString);
    return std.mem.join(allocator, ",", names.items) catch error.OutOfMemory;
}

fn valueJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    return switch (source) {
        .string => |text| .{ .string = text },
        .integer => |number| .{ .integer = number },
        .boolean => |flag| .{ .bool = flag },
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
        .output_ref => |reference| .{ .string = try context.resolveOutputString(reference) },
        .secret_ref, .unknown_reason => error.InvalidConfiguration,
    };
}
fn jsonContains(desired: std.json.Value, remote: std.json.Value) bool {
    if (std.meta.activeTag(desired) != std.meta.activeTag(remote)) return false;
    return switch (desired) {
        .object => |object| blk: {
            const other = remote.object;
            for (object.keys()) |key| if (!jsonContains(object.get(key).?, other.get(key) orelse break :blk false)) break :blk false;
            break :blk true;
        },
        .array => |array| blk: {
            if (array.items.len != remote.array.items.len) break :blk false;
            for (array.items, remote.array.items) |left, right| if (!jsonContains(left, right)) break :blk false;
            break :blk true;
        },
        else => jsonValuesEqual(desired, remote),
    };
}
fn requiredValue(source: value.Value, name: []const u8) ProviderError!value.Value {
    const fields = valueObject(source) orelse return error.InvalidConfiguration;
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return error.InvalidConfiguration;
}
fn requiredLiteralString(source: value.Value, name: []const u8) ProviderError![]const u8 {
    return valueString(try requiredValue(source, name)) orelse error.InvalidConfiguration;
}
fn requiredObjectValue(fields: []const value.Field, name: []const u8) ProviderError!value.Value {
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return error.InvalidConfiguration;
}
fn requiredObjectString(fields: []const value.Field, name: []const u8) ProviderError![]const u8 {
    return valueString(try requiredObjectValue(fields, name)) orelse error.InvalidConfiguration;
}
fn resolvedObjectString(context: *provider_mod.OperationContext, fields: []const value.Field, name: []const u8) ProviderError![]const u8 {
    return switch (try requiredObjectValue(fields, name)) {
        .string => |text| text,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}
fn requiredObjectInteger(fields: []const value.Field, name: []const u8) ProviderError!i64 {
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
fn outputString(result: provider_mod.ResourceResult, name: []const u8) ?[]const u8 {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name) and item.value == .string) return item.value.string;
    return null;
}
fn lessString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn jsonValuesEqual(left: std.json.Value, right: std.json.Value) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .null => true,
        .bool => left.bool == right.bool,
        .integer => left.integer == right.integer,
        .float => left.float == right.float,
        .number_string => std.mem.eql(u8, left.number_string, right.number_string),
        .string => std.mem.eql(u8, left.string, right.string),
        .array => |array| blk: {
            if (array.items.len != right.array.items.len) break :blk false;
            for (array.items, right.array.items) |a, b| {
                if (!jsonValuesEqual(a, b)) break :blk false;
            }
            break :blk true;
        },
        .object => |object| blk: {
            if (object.count() != right.object.count()) break :blk false;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const other = right.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!jsonValuesEqual(entry.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}
