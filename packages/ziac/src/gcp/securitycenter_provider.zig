const std = @import("std");
const client_mod = @import("client.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;
const Kind = enum { source, notification, mute, bigquery_export, resource_value };

pub const Handler = struct {
    client: *client_mod.Client,

    pub fn supports(node: resource.ResourceNode) bool {
        return kindOf(node) != null;
    }

    pub fn read(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        const physical = try physicalForReadAlloc(context, node, kind, physical_override);
        defer if (physical) |owned| context.allocator.free(owned);
        if (physical == null) return self.readFromList(context, node, kind);
        try validatePhysical(kind, physical.?);
        const path = try std.fmt.allocPrint(context.allocator, "/v2/{s}", .{physical.?});
        defer context.allocator.free(path);
        var response = self.request(context, "GET", path, "") catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try resultFromJson(context, node, kind, response.body) };
    }

    pub fn diff(context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        const remote_json = outputString(observed.*, "__remote_spec") orelse return error.ProviderBug;
        var remote = std.json.parseFromSlice(std.json.Value, context.allocator, remote_json, .{}) catch return error.ProviderBug;
        defer remote.deinit();
        const desired_body = try bodyAlloc(context, node, kind);
        defer context.allocator.free(desired_body);
        var desired = std.json.parseFromSlice(std.json.Value, context.allocator, desired_body, .{}) catch return error.ProviderBug;
        defer desired.deinit();
        const desired_root = jsonObject(desired.value) orelse return error.ProviderBug;
        const remote_root = jsonObject(remote.value) orelse return error.ProviderBug;
        if (jsonContains(desired_root, remote_root)) return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        if (kind == .mute and !jsonValueEquivalent(desired_root.get("type"), remote_root.get("type"))) return provider_mod.DiffResult.init(context.allocator, .replace, &.{"SCC mute type is immutable"});
        return provider_mod.DiffResult.init(context.allocator, .update, &.{"SCC configuration differs"});
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        const path = try createPathAlloc(context, node, kind);
        defer context.allocator.free(path);
        const resource_body = try bodyAlloc(context, node, kind);
        defer context.allocator.free(resource_body);
        const body = if (kind == .resource_value) try batchBodyAlloc(context.allocator, resource_body) else try context.allocator.dupe(u8, resource_body);
        defer context.allocator.free(body);
        var response = try self.request(context, "POST", path, body);
        defer response.deinit(context.allocator);
        const result_body = if (kind == .resource_value) try firstResourceValueAlloc(context.allocator, response.body) else try context.allocator.dupe(u8, response.body);
        defer context.allocator.free(result_body);
        return resultFromJson(context, node, kind, result_body);
    }

    pub fn update(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(kind, observed.physical_id);
        const path = try updatePathAlloc(context.allocator, kind, observed.physical_id);
        defer context.allocator.free(path);
        const body = try bodyAlloc(context, node, kind);
        defer context.allocator.free(body);
        var response = try self.request(context, "PATCH", path, body);
        defer response.deinit(context.allocator);
        return resultFromJson(context, node, kind, response.body);
    }

    pub fn delete(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical: []const u8) ProviderError!void {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (kind == .source) return error.InvalidConfiguration;
        try validatePhysical(kind, physical);
        if (!std.mem.eql(u8, try requiredLiteralString(node.inputs, "removal_policy"), "delete") or !context.destructive_confirmation) return error.DestructiveConfirmationRequired;
        const path = try std.fmt.allocPrint(context.allocator, "/v2/{s}", .{physical});
        defer context.allocator.free(path);
        var response = self.request(context, "DELETE", path, "") catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        response.deinit(context.allocator);
    }

    pub fn importResource(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical: []const u8) ProviderError!provider_mod.ResourceResult {
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(kind, physical);
        var found = try self.read(context, node, physical);
        defer found.deinit();
        return switch (found) {
            .absent => error.NotFound,
            .present => |present| present.clone(context.allocator),
        };
    }

    fn readFromList(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind) ProviderError!provider_mod.ReadResult {
        if (kind != .source and kind != .resource_value) return .absent;
        const path = switch (kind) {
            .source => try std.fmt.allocPrint(context.allocator, "/v2/{s}/sources", .{try requiredString(context, node.inputs, "organization")}),
            .resource_value => try std.fmt.allocPrint(context.allocator, "/v2/{s}/locations/{s}/resourceValueConfigs", .{ try requiredString(context, node.inputs, "organization"), try requiredLiteralString(node.inputs, "location") }),
            else => unreachable,
        };
        defer context.allocator.free(path);
        var response = self.request(context, "GET", path, "") catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const root = jsonObject(parsed.value) orelse return error.ProviderBug;
        const field = if (kind == .source) "sources" else "resourceValueConfigs";
        const items = jsonArray(root.get(field) orelse return .absent) orelse return error.ProviderBug;
        for (items.items) |candidate| {
            const object = jsonObject(candidate) orelse continue;
            if (!try remoteMatches(context, node, kind, object)) continue;
            const bytes = std.json.Stringify.valueAlloc(context.allocator, candidate, .{}) catch return error.OutOfMemory;
            defer context.allocator.free(bytes);
            return .{ .present = try resultFromJson(context, node, kind, bytes) };
        }
        return .absent;
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, method: []const u8, path: []const u8, body: []const u8) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, .{ .api = .security_center, .method = method, .path = path, .body = body }, &diagnostic);
    }
};

fn kindOf(node: resource.ResourceNode) ?Kind {
    const mappings = [_]struct { []const u8, Kind }{
        .{ "gcp.securitycenter.Source", .source },
        .{ "gcp.securitycenter.NotificationConfig", .notification },
        .{ "gcp.securitycenter.MuteConfig", .mute },
        .{ "gcp.securitycenter.BigQueryExport", .bigquery_export },
        .{ "gcp.securitycenter.ResourceValueConfig", .resource_value },
    };
    for (mappings) |mapping| if (std.mem.eql(u8, node.type_name, mapping[0])) return mapping[1];
    return null;
}

fn physicalForReadAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, override: ?[]const u8) ProviderError!?[]const u8 {
    if (override orelse context.physical_id) |physical| return context.allocator.dupe(u8, physical) catch error.OutOfMemory;
    return switch (kind) {
        .source, .resource_value => null,
        .notification => std.fmt.allocPrint(context.allocator, "{s}/locations/{s}/notificationConfigs/{s}", .{ try requiredString(context, node.inputs, "parent"), try requiredLiteralString(node.inputs, "location"), node.logical_id }) catch error.OutOfMemory,
        .mute => std.fmt.allocPrint(context.allocator, "{s}/locations/{s}/muteConfigs/{s}", .{ try requiredString(context, node.inputs, "parent"), try requiredLiteralString(node.inputs, "location"), node.logical_id }) catch error.OutOfMemory,
        .bigquery_export => std.fmt.allocPrint(context.allocator, "{s}/locations/{s}/bigQueryExports/{s}", .{ try requiredString(context, node.inputs, "parent"), try requiredLiteralString(node.inputs, "location"), node.logical_id }) catch error.OutOfMemory,
    };
}

fn createPathAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    return switch (kind) {
        .source => std.fmt.allocPrint(context.allocator, "/v2/{s}/sources", .{try requiredString(context, node.inputs, "organization")}) catch error.OutOfMemory,
        .notification => std.fmt.allocPrint(context.allocator, "/v2/{s}/locations/{s}/notificationConfigs?configId={s}", .{ try requiredString(context, node.inputs, "parent"), try requiredLiteralString(node.inputs, "location"), node.logical_id }) catch error.OutOfMemory,
        .mute => std.fmt.allocPrint(context.allocator, "/v2/{s}/locations/{s}/muteConfigs?muteConfigId={s}", .{ try requiredString(context, node.inputs, "parent"), try requiredLiteralString(node.inputs, "location"), node.logical_id }) catch error.OutOfMemory,
        .bigquery_export => std.fmt.allocPrint(context.allocator, "/v2/{s}/locations/{s}/bigQueryExports?bigQueryExportId={s}", .{ try requiredString(context, node.inputs, "parent"), try requiredLiteralString(node.inputs, "location"), node.logical_id }) catch error.OutOfMemory,
        .resource_value => std.fmt.allocPrint(context.allocator, "/v2/{s}/locations/{s}/resourceValueConfigs:batchCreate", .{ try requiredString(context, node.inputs, "organization"), try requiredLiteralString(node.inputs, "location") }) catch error.OutOfMemory,
    };
}

fn updatePathAlloc(allocator: std.mem.Allocator, kind: Kind, physical: []const u8) ProviderError![]const u8 {
    const mask = switch (kind) {
        .source => "displayName%2Cdescription",
        .notification => "description%2CpubsubTopic%2CstreamingConfig.filter",
        .mute => "description%2Cfilter%2CexpiryTime",
        .bigquery_export => "description%2Cfilter%2Cdataset",
        .resource_value => "resourceValue%2Cdescription%2CresourceType%2CresourceLabelsSelector%2CtagValues%2Cscope",
    };
    return std.fmt.allocPrint(allocator, "/v2/{s}?updateMask={s}", .{ physical, mask }) catch error.OutOfMemory;
}

fn bodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind) ProviderError![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = std.json.ObjectMap.empty;
    switch (kind) {
        .source => {
            try root.put(arena, "displayName", .{ .string = try requiredLiteralString(node.inputs, "display_name") });
            try putOptionalString(arena, &root, "description", try requiredLiteralString(node.inputs, "description"));
        },
        .notification => {
            try putOptionalString(arena, &root, "description", try requiredLiteralString(node.inputs, "description"));
            try root.put(arena, "pubsubTopic", .{ .string = try requiredString(context, node.inputs, "pubsub_topic") });
            var streaming = std.json.ObjectMap.empty;
            try streaming.put(arena, "filter", .{ .string = try requiredLiteralString(node.inputs, "filter") });
            try root.put(arena, "streamingConfig", .{ .object = streaming });
        },
        .mute => {
            try putOptionalString(arena, &root, "description", try requiredLiteralString(node.inputs, "description"));
            try root.put(arena, "filter", .{ .string = try requiredLiteralString(node.inputs, "filter") });
            try root.put(arena, "type", .{ .string = try requiredLiteralString(node.inputs, "config_type") });
            try putOptionalString(arena, &root, "expiryTime", try requiredLiteralString(node.inputs, "expiry_time"));
        },
        .bigquery_export => {
            try putOptionalString(arena, &root, "description", try requiredLiteralString(node.inputs, "description"));
            try root.put(arena, "filter", .{ .string = try requiredLiteralString(node.inputs, "filter") });
            try root.put(arena, "dataset", .{ .string = try requiredString(context, node.inputs, "dataset") });
        },
        .resource_value => {
            try putOptionalString(arena, &root, "description", try requiredLiteralString(node.inputs, "description"));
            try root.put(arena, "resourceValue", .{ .string = try requiredLiteralString(node.inputs, "resource_value") });
            try root.put(arena, "cloudProvider", .{ .string = try requiredLiteralString(node.inputs, "cloud_provider") });
            try putOptionalString(arena, &root, "resourceType", try requiredLiteralString(node.inputs, "resource_type"));
            try putOptionalString(arena, &root, "scope", try requiredLiteralString(node.inputs, "scope"));
            const labels = try requiredValue(node.inputs, "labels");
            if (!valueIsEmpty(labels)) try root.put(arena, "resourceLabelsSelector", try resolvedValueJson(context, arena, labels));
            const tags = try requiredValue(node.inputs, "tag_values");
            if (!valueIsEmpty(tags)) try root.put(arena, "tagValues", try resolvedValueJson(context, arena, tags));
        },
    }
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch error.OutOfMemory;
}

fn batchBodyAlloc(allocator: std.mem.Allocator, resource_body: []const u8) ProviderError![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, resource_body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var request = std.json.ObjectMap.empty;
    try request.put(arena, "resourceValueConfig", try cloneJson(arena, parsed.value));
    var requests = std.json.Array.init(arena);
    try requests.append(.{ .object = request });
    var root = std.json.ObjectMap.empty;
    try root.put(arena, "requests", .{ .array = requests });
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = root }, .{}) catch error.OutOfMemory;
}

fn firstResourceValueAlloc(allocator: std.mem.Allocator, body: []const u8) ProviderError![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const items = jsonArray(root.get("resourceValueConfigs") orelse return error.ProviderBug) orelse return error.ProviderBug;
    if (items.items.len != 1) return error.ProviderBug;
    return std.json.Stringify.valueAlloc(allocator, items.items[0], .{}) catch error.OutOfMemory;
}

fn resultFromJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, body: []const u8) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const physical = jsonString(root.get("name")) orelse return error.ProviderBug;
    try validatePhysical(kind, physical);
    const observed: value.Value = if (try remoteMatches(context, node, kind, root)) node.inputs else .{ .unknown_reason = "remote SCC configuration drifted" };
    var outputs: [4]state.StateOutput = undefined;
    var count: usize = 0;
    outputs[count] = .{ .name = "name", .value = .{ .string = physical } };
    count += 1;
    switch (kind) {
        .source => {
            outputs[count] = .{ .name = "canonical_name", .value = .{ .string = jsonString(root.get("canonicalName")) orelse "" } };
            count += 1;
        },
        .notification => {
            outputs[count] = .{ .name = "service_account", .value = .{ .string = jsonString(root.get("serviceAccount")) orelse "" } };
            count += 1;
        },
        .bigquery_export => {
            outputs[count] = .{ .name = "principal", .value = .{ .string = jsonString(root.get("principal")) orelse "" } };
            count += 1;
        },
        .mute, .resource_value => {},
    }
    outputs[count] = .{ .name = "__remote_spec", .value = .{ .string = body } };
    count += 1;
    return provider_mod.ResourceResult.init(context.allocator, physical, observed, outputs[0..count], null);
}

fn remoteMatches(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, remote: std.json.ObjectMap) ProviderError!bool {
    const desired_body = try bodyAlloc(context, node, kind);
    defer context.allocator.free(desired_body);
    var desired = std.json.parseFromSlice(std.json.Value, context.allocator, desired_body, .{}) catch return error.ProviderBug;
    defer desired.deinit();
    return jsonContains(jsonObject(desired.value) orelse return error.ProviderBug, remote);
}

fn validatePhysical(kind: Kind, physical: []const u8) ProviderError!void {
    if (std.mem.indexOfAny(u8, physical, "?# \t\r\n") != null) return error.InvalidConfiguration;
    const valid = switch (kind) {
        .source => std.mem.startsWith(u8, physical, "organizations/") and std.mem.indexOf(u8, physical, "/sources/") != null,
        .notification => std.mem.indexOf(u8, physical, "/locations/") != null and std.mem.indexOf(u8, physical, "/notificationConfigs/") != null,
        .mute => std.mem.indexOf(u8, physical, "/locations/") != null and std.mem.indexOf(u8, physical, "/muteConfigs/") != null,
        .bigquery_export => std.mem.indexOf(u8, physical, "/locations/") != null and std.mem.indexOf(u8, physical, "/bigQueryExports/") != null,
        .resource_value => std.mem.startsWith(u8, physical, "organizations/") and std.mem.indexOf(u8, physical, "/resourceValueConfigs/") != null,
    };
    if (!valid) return error.InvalidConfiguration;
}

fn requiredValue(source: value.Value, name: []const u8) ProviderError!value.Value {
    if (source != .object) return error.InvalidConfiguration;
    for (source.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return error.InvalidConfiguration;
}

fn requiredLiteralString(source: value.Value, name: []const u8) ProviderError![]const u8 {
    return switch (try requiredValue(source, name)) {
        .string => |text| text,
        else => error.InvalidConfiguration,
    };
}

fn requiredString(context: *provider_mod.OperationContext, source: value.Value, name: []const u8) ProviderError![]const u8 {
    return switch (try requiredValue(source, name)) {
        .string => |text| text,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}

fn resolvedValueJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    return switch (source) {
        .string => |text| .{ .string = text },
        .integer => |number| .{ .integer = number },
        .boolean => |flag| .{ .bool = flag },
        .list => |items| blk: {
            var array = std.json.Array.init(arena);
            for (items) |item| try array.append(try resolvedValueJson(context, arena, item));
            break :blk .{ .array = array };
        },
        .object => |fields| blk: {
            var object = std.json.ObjectMap.empty;
            for (fields) |field| try object.put(arena, field.name, try resolvedValueJson(context, arena, field.value));
            break :blk .{ .object = object };
        },
        .output_ref => |reference| .{ .string = try context.resolveOutputString(reference) },
        .secret_ref, .unknown_reason => error.InvalidConfiguration,
    };
}

fn cloneJson(arena: std.mem.Allocator, source: std.json.Value) ProviderError!std.json.Value {
    return switch (source) {
        .null, .bool, .integer, .float, .number_string, .string => source,
        .array => |items| blk: {
            var result = std.json.Array.init(arena);
            for (items.items) |item| try result.append(try cloneJson(arena, item));
            break :blk .{ .array = result };
        },
        .object => |object| blk: {
            var result = std.json.ObjectMap.empty;
            var iterator = object.iterator();
            while (iterator.next()) |entry| try result.put(arena, entry.key_ptr.*, try cloneJson(arena, entry.value_ptr.*));
            break :blk .{ .object = result };
        },
    };
}

fn jsonContains(desired: std.json.ObjectMap, remote: std.json.ObjectMap) bool {
    var iterator = desired.iterator();
    while (iterator.next()) |entry| if (!jsonValueEquivalent(entry.value_ptr.*, remote.get(entry.key_ptr.*))) return false;
    return true;
}

fn jsonValueEquivalent(desired_optional: ?std.json.Value, remote_optional: ?std.json.Value) bool {
    const desired = desired_optional orelse return remote_optional == null;
    const remote = remote_optional orelse return jsonValueEmpty(desired);
    return switch (desired) {
        .null => remote == .null,
        .bool => |flag| remote == .bool and remote.bool == flag,
        .integer => |number| remote == .integer and remote.integer == number,
        .float => |number| remote == .float and remote.float == number,
        .number_string => |number| remote == .number_string and std.mem.eql(u8, remote.number_string, number),
        .string => |text| remote == .string and std.mem.eql(u8, remote.string, text),
        .array => |items| blk: {
            if (remote != .array or remote.array.items.len != items.items.len) break :blk false;
            for (items.items, remote.array.items) |left, right| if (!jsonValueEquivalent(left, right)) break :blk false;
            break :blk true;
        },
        .object => |object| remote == .object and jsonContains(object, remote.object),
    };
}

fn jsonValueEmpty(candidate: std.json.Value) bool {
    return switch (candidate) {
        .string => |text| text.len == 0,
        .array => |items| items.items.len == 0,
        .object => |object| object.count() == 0,
        .bool => |flag| !flag,
        else => false,
    };
}

fn valueIsEmpty(candidate: value.Value) bool {
    return switch (candidate) {
        .string => |text| text.len == 0,
        .list => |items| items.len == 0,
        .object => |fields| fields.len == 0,
        .boolean => |flag| !flag,
        else => false,
    };
}

fn putOptionalString(arena: std.mem.Allocator, object: *std.json.ObjectMap, name: []const u8, text: []const u8) ProviderError!void {
    if (text.len != 0) try object.put(arena, name, .{ .string = text });
}

fn outputString(result: provider_mod.ResourceResult, name: []const u8) ?[]const u8 {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name)) return switch (item.value) {
        .string => |text| text,
        else => null,
    };
    return null;
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
