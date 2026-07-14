const std = @import("std");
const client_mod = @import("client.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;
const Kind = enum { key_ring, crypto_key, crypto_key_version };

pub const Handler = struct {
    client: *client_mod.Client,

    pub fn read(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
        const resource_kind = kind(node) orelse return error.InvalidConfiguration;
        const generated = if (resource_kind == .crypto_key_version) null else try physicalIdAlloc(context, node);
        defer if (generated) |physical| context.allocator.free(physical);
        const physical = physical_override orelse context.physical_id orelse generated orelse return .absent;
        if (generated) |expected| if (!std.mem.eql(u8, expected, physical)) return error.InvalidConfiguration;
        try validatePhysical(node, resource_kind, physical);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .cloud_kms, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try resultFromJson(context, node, resource_kind, physical, response.body) };
    }

    pub fn diff(context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash)) return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        const resource_kind = kind(node) orelse return error.InvalidConfiguration;
        const change: provider_mod.DiffKind = switch (resource_kind) {
            .key_ring => .replace,
            .crypto_key => if (anyChanged(node.inputs, observed.observed_inputs, &.{ "key_ring", "name", "project_id", "purpose", "algorithm", "protection_level", "import_only", "destroy_scheduled_duration_seconds" })) .replace else .update,
            .crypto_key_version => if (anyChanged(node.inputs, observed.observed_inputs, &.{ "crypto_key", "name", "project_id" })) .replace else .update,
        };
        return provider_mod.DiffResult.init(context.allocator, change, &.{if (change == .replace) "Cloud KMS immutable identity differs" else "Cloud KMS mutable configuration differs"});
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        const resource_kind = kind(node) orelse return error.InvalidConfiguration;
        const path = switch (resource_kind) {
            .key_ring => try keyRingCreatePathAlloc(context.allocator, node),
            .crypto_key => try cryptoKeyCreatePathAlloc(context, node),
            .crypto_key_version => try cryptoKeyVersionCreatePathAlloc(context, node),
        };
        defer context.allocator.free(path);
        const body = switch (resource_kind) {
            .key_ring, .crypto_key_version => try context.allocator.dupe(u8, "{}"),
            .crypto_key => try cryptoKeyCreateBodyAlloc(context.allocator, node),
        };
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .cloud_kms, .method = "POST", .path = path, .body = body });
        defer response.deinit(context.allocator);
        const physical = if (resource_kind == .crypto_key_version) try responseNameAlloc(context.allocator, response.body) else try physicalIdAlloc(context, node);
        defer context.allocator.free(physical);
        var created = try resultFromJson(context, node, resource_kind, physical, response.body);
        if (resource_kind != .crypto_key_version or std.mem.eql(u8, try requiredString(node.inputs, "state"), "ENABLED")) return created;
        created.deinit();
        return self.updateVersion(context, node, physical);
    }

    pub fn update(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        return switch (kind(node) orelse return error.InvalidConfiguration) {
            .key_ring => error.InvalidConfiguration,
            .crypto_key => self.updateKey(context, node, observed),
            .crypto_key_version => self.updateVersion(context, node, observed.physical_id),
        };
    }

    pub fn delete(_: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!void {
        const resource_kind = kind(node) orelse return error.InvalidConfiguration;
        try validatePhysical(node, resource_kind, physical_id);
        // Key material is retained. Irreversible transitions are governed actions.
        try context.checkActive();
    }

    fn updateKey(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        const physical_id = observed.physical_id;
        const expected = try physicalIdAlloc(context, node);
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        const mask = try cryptoKeyUpdateMaskAlloc(context.allocator, node.inputs, observed.observed_inputs);
        defer context.allocator.free(mask);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}?updateMask={s}", .{ physical_id, mask });
        defer context.allocator.free(path);
        const body = try cryptoKeyUpdateBodyAlloc(context.allocator, node, observed, physical_id);
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .cloud_kms, .method = "PATCH", .path = path, .body = body });
        defer response.deinit(context.allocator);
        return resultFromJson(context, node, .crypto_key, physical_id, response.body);
    }

    fn updateVersion(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!provider_mod.ResourceResult {
        try validatePhysical(node, .crypto_key_version, physical_id);
        const desired_state = try requiredString(node.inputs, "state");
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}?updateMask=state", .{physical_id});
        defer context.allocator.free(path);
        const body = std.json.Stringify.valueAlloc(context.allocator, .{ .name = physical_id, .state = desired_state }, .{}) catch return error.OutOfMemory;
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .cloud_kms, .method = "PATCH", .path = path, .body = body });
        defer response.deinit(context.allocator);
        return resultFromJson(context, node, .crypto_key_version, physical_id, response.body);
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, request_value: client_mod.Request) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, request_value, &diagnostic);
    }
};

pub fn supports(node: resource.ResourceNode) bool {
    return kind(node) != null;
}
fn kind(node: resource.ResourceNode) ?Kind {
    if (std.mem.eql(u8, node.type_name, "gcp.kms.KeyRing")) return .key_ring;
    if (std.mem.eql(u8, node.type_name, "gcp.kms.CryptoKey")) return .crypto_key;
    if (std.mem.eql(u8, node.type_name, "gcp.kms.CryptoKeyVersion")) return .crypto_key_version;
    return null;
}

fn physicalIdAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError![]u8 {
    const project = try requiredString(node.inputs, "project_id");
    const name = try requiredString(node.inputs, "name");
    return switch (kind(node) orelse return error.InvalidConfiguration) {
        .key_ring => std.fmt.allocPrint(context.allocator, "projects/{s}/locations/{s}/keyRings/{s}", .{ project, try requiredString(node.inputs, "location"), name }) catch error.OutOfMemory,
        .crypto_key => std.fmt.allocPrint(context.allocator, "{s}/cryptoKeys/{s}", .{ try resolveString(context, try requiredValue(node.inputs, "key_ring")), name }) catch error.OutOfMemory,
        .crypto_key_version => error.InvalidConfiguration,
    };
}

fn validatePhysical(node: resource.ResourceNode, resource_kind: Kind, physical: []const u8) ProviderError!void {
    if (std.mem.indexOfAny(u8, physical, "?# \t\r\n") != null or !std.mem.startsWith(u8, physical, "projects/")) return error.InvalidConfiguration;
    switch (resource_kind) {
        .key_ring => if (std.mem.indexOf(u8, physical, "/keyRings/") == null or std.mem.indexOf(u8, physical, "/cryptoKeys/") != null) return error.InvalidConfiguration,
        .crypto_key => if (std.mem.indexOf(u8, physical, "/cryptoKeys/") == null or std.mem.indexOf(u8, physical, "/cryptoKeyVersions/") != null) return error.InvalidConfiguration,
        .crypto_key_version => {
            const marker = "/cryptoKeyVersions/";
            const index = std.mem.lastIndexOf(u8, physical, marker) orelse return error.InvalidConfiguration;
            const version = physical[index + marker.len ..];
            _ = std.fmt.parseInt(u64, version, 10) catch return error.InvalidConfiguration;
            const parent = try requiredValue(node.inputs, "crypto_key");
            if (parent == .string and !std.mem.startsWith(u8, physical, parent.string)) return error.InvalidConfiguration;
        },
    }
}

fn keyRingCreatePathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]u8 {
    return std.fmt.allocPrint(allocator, "/v1/projects/{s}/locations/{s}/keyRings?keyRingId={s}", .{ try requiredString(node.inputs, "project_id"), try requiredString(node.inputs, "location"), try requiredString(node.inputs, "name") }) catch error.OutOfMemory;
}
fn cryptoKeyCreatePathAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError![]u8 {
    return std.fmt.allocPrint(context.allocator, "/v1/{s}/cryptoKeys?cryptoKeyId={s}", .{ try resolveString(context, try requiredValue(node.inputs, "key_ring")), try requiredString(node.inputs, "name") }) catch error.OutOfMemory;
}
fn cryptoKeyVersionCreatePathAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError![]u8 {
    return std.fmt.allocPrint(context.allocator, "/v1/{s}/cryptoKeyVersions", .{try resolveString(context, try requiredValue(node.inputs, "crypto_key"))}) catch error.OutOfMemory;
}

fn cryptoKeyCreateBodyAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root: std.json.ObjectMap = .empty;
    try root.put(arena, "purpose", .{ .string = try requiredString(node.inputs, "purpose") });
    try root.put(arena, "importOnly", .{ .bool = try requiredBool(node.inputs, "import_only") });
    const destroy_seconds = try requiredInteger(node.inputs, "destroy_scheduled_duration_seconds");
    try root.put(arena, "destroyScheduledDuration", .{ .string = try std.fmt.allocPrint(arena, "{d}s", .{destroy_seconds}) });
    var template: std.json.ObjectMap = .empty;
    try template.put(arena, "algorithm", .{ .string = try requiredString(node.inputs, "algorithm") });
    try template.put(arena, "protectionLevel", .{ .string = try requiredString(node.inputs, "protection_level") });
    try root.put(arena, "versionTemplate", .{ .object = template });
    try root.put(arena, "labels", try valueToJson(arena, try requiredValue(node.inputs, "labels")));
    if (optionalInteger(node.inputs, "rotation_period_seconds")) |seconds| try root.put(arena, "rotationPeriod", .{ .string = try std.fmt.allocPrint(arena, "{d}s", .{seconds}) });
    if (optionalString(node.inputs, "next_rotation_time")) |next| try root.put(arena, "nextRotationTime", .{ .string = next });
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = root }, .{}) catch error.OutOfMemory;
}

fn cryptoKeyUpdateMaskAlloc(allocator: std.mem.Allocator, desired: value.Value, observed: value.Value) ProviderError![]u8 {
    const fields = [_]struct { input: []const u8, api: []const u8 }{
        .{ .input = "labels", .api = "labels" },
        .{ .input = "rotation_period_seconds", .api = "rotationPeriod" },
        .{ .input = "next_rotation_time", .api = "nextRotationTime" },
    };
    var mask = std.ArrayList(u8).empty;
    errdefer mask.deinit(allocator);
    for (fields) |field| {
        if (!changedOptional(desired, observed, field.input)) continue;
        if (mask.items.len != 0) try mask.append(allocator, ',');
        try mask.appendSlice(allocator, field.api);
    }
    if (mask.items.len == 0) return error.ProviderBug;
    return mask.toOwnedSlice(allocator) catch error.OutOfMemory;
}

fn cryptoKeyUpdateBodyAlloc(
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    observed: *const provider_mod.ResourceResult,
    physical_id: []const u8,
) ProviderError![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root: std.json.ObjectMap = .empty;
    try root.put(arena, "name", .{ .string = physical_id });
    if (changedOptional(node.inputs, observed.observed_inputs, "labels")) {
        try root.put(arena, "labels", try valueToJson(arena, try requiredValue(node.inputs, "labels")));
    }
    if (changedOptional(node.inputs, observed.observed_inputs, "rotation_period_seconds")) {
        const field: std.json.Value = if (optionalInteger(node.inputs, "rotation_period_seconds")) |seconds|
            .{ .string = try std.fmt.allocPrint(arena, "{d}s", .{seconds}) }
        else
            .null;
        try root.put(arena, "rotationPeriod", field);
    }
    if (changedOptional(node.inputs, observed.observed_inputs, "next_rotation_time")) {
        try root.put(arena, "nextRotationTime", if (optionalString(node.inputs, "next_rotation_time")) |next| .{ .string = next } else .null);
    }
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = root }, .{}) catch error.OutOfMemory;
}

fn resultFromJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, resource_kind: Kind, physical: []const u8, body: []const u8) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const remote = jsonObject(parsed.value) orelse return error.ProviderBug;
    const remote_name = jsonString(remote.get("name")) orelse return error.ProviderBug;
    if (!std.mem.eql(u8, remote_name, physical)) return error.InvalidConfiguration;
    var observed = value.Value.initOwned(context.allocator, node.inputs) catch |err| return mapValueError(err);
    defer observed.deinit(context.allocator);
    var outputs: [2]state.StateOutput = undefined;
    var output_count: usize = 1;
    outputs[0] = .{ .name = "name", .value = .{ .string = physical } };
    switch (resource_kind) {
        .key_ring => {},
        .crypto_key => {
            try replaceString(context.allocator, &observed, "purpose", jsonString(remote.get("purpose")) orelse return error.ProviderBug);
            const template = jsonObject(remote.get("versionTemplate") orelse return error.ProviderBug) orelse return error.ProviderBug;
            try replaceString(context.allocator, &observed, "algorithm", jsonString(template.get("algorithm")) orelse return error.ProviderBug);
            try replaceString(context.allocator, &observed, "protection_level", jsonString(template.get("protectionLevel")) orelse "SOFTWARE");
            try replaceBool(context.allocator, &observed, "import_only", jsonBool(remote.get("importOnly")) orelse false);
            try replaceInteger(context.allocator, &observed, "destroy_scheduled_duration_seconds", durationSeconds(jsonString(remote.get("destroyScheduledDuration")) orelse "2592000s") orelse return error.ProviderBug);
            try replaceJson(context.allocator, &observed, "labels", remote.get("labels") orelse .{ .object = std.json.ObjectMap.empty });
            if (hasValue(observed, "rotation_period_seconds")) try replaceInteger(context.allocator, &observed, "rotation_period_seconds", durationSeconds(jsonString(remote.get("rotationPeriod")) orelse "0s") orelse 0);
            if (hasValue(observed, "next_rotation_time")) try replaceString(context.allocator, &observed, "next_rotation_time", jsonString(remote.get("nextRotationTime")) orelse "");
        },
        .crypto_key_version => {
            const remote_state = jsonString(remote.get("state")) orelse return error.ProviderBug;
            try replaceString(context.allocator, &observed, "state", remote_state);
            outputs[1] = .{ .name = "state", .value = .{ .string = remote_state } };
            output_count = 2;
        },
    }
    return provider_mod.ResourceResult.init(context.allocator, physical, observed, outputs[0..output_count], null);
}

fn responseNameAlloc(allocator: std.mem.Allocator, body: []const u8) ProviderError![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    return allocator.dupe(u8, jsonString((jsonObject(parsed.value) orelse return error.ProviderBug).get("name")) orelse return error.ProviderBug) catch error.OutOfMemory;
}

fn anyChanged(left: value.Value, right: value.Value, names: []const []const u8) bool {
    for (names) |name| if (changedOptional(left, right, name)) return true;
    return false;
}
fn changedOptional(left: value.Value, right: value.Value, name: []const u8) bool {
    const a = requiredValue(left, name) catch null;
    const b = requiredValue(right, name) catch null;
    if (a == null or b == null) return a != null or b != null;
    const ah = a.?.sha256(std.heap.page_allocator) catch return true;
    const bh = b.?.sha256(std.heap.page_allocator) catch return true;
    return !std.mem.eql(u8, &ah, &bh);
}

fn valueToJson(allocator: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    return switch (input) {
        .string => |text| .{ .string = text },
        .integer => |number| .{ .integer = number },
        .boolean => |flag| .{ .bool = flag },
        .list => |items| blk: {
            var array: std.json.Array = .init(allocator);
            for (items) |item| try array.append(try valueToJson(allocator, item));
            break :blk .{ .array = array };
        },
        .object => |fields| blk: {
            var object: std.json.ObjectMap = .empty;
            for (fields) |field| try object.put(allocator, field.name, try valueToJson(allocator, field.value));
            break :blk .{ .object = object };
        },
        else => error.InvalidConfiguration,
    };
}
fn jsonToValue(allocator: std.mem.Allocator, input: std.json.Value) ProviderError!value.Value {
    return switch (input) {
        .string => |text| own(allocator, .{ .string = text }),
        .integer => |number| own(allocator, .{ .integer = number }),
        .bool => |flag| own(allocator, .{ .boolean = flag }),
        .array => |array| blk: {
            const items = try allocator.alloc(value.Value, array.items.len);
            defer allocator.free(items);
            var count: usize = 0;
            defer for (items[0..count]) |*item| item.deinit(allocator);
            for (array.items, 0..) |item, index| {
                items[index] = try jsonToValue(allocator, item);
                count += 1;
            }
            break :blk try own(allocator, .{ .list = items });
        },
        .object => |object| blk: {
            const fields = try allocator.alloc(value.Field, object.count());
            defer allocator.free(fields);
            var iterator = object.iterator();
            var count: usize = 0;
            defer for (fields[0..count]) |*field| field.value.deinit(allocator);
            while (iterator.next()) |entry| : (count += 1) fields[count] = .{ .name = entry.key_ptr.*, .value = try jsonToValue(allocator, entry.value_ptr.*) };
            break :blk try own(allocator, .{ .object = fields });
        },
        else => error.ProviderBug,
    };
}
fn replaceJson(allocator: std.mem.Allocator, input: *value.Value, name: []const u8, replacement: std.json.Value) ProviderError!void {
    var converted = try jsonToValue(allocator, replacement);
    defer converted.deinit(allocator);
    return replace(allocator, input, name, converted);
}
fn replaceString(allocator: std.mem.Allocator, input: *value.Value, name: []const u8, replacement: []const u8) ProviderError!void {
    return replace(allocator, input, name, .{ .string = replacement });
}
fn replaceInteger(allocator: std.mem.Allocator, input: *value.Value, name: []const u8, replacement: i64) ProviderError!void {
    return replace(allocator, input, name, .{ .integer = replacement });
}
fn replaceBool(allocator: std.mem.Allocator, input: *value.Value, name: []const u8, replacement: bool) ProviderError!void {
    return replace(allocator, input, name, .{ .boolean = replacement });
}
fn replace(allocator: std.mem.Allocator, input: *value.Value, name: []const u8, replacement: value.Value) ProviderError!void {
    if (input.* != .object) return error.ProviderBug;
    for (@constCast(input.object)) |*field| if (std.mem.eql(u8, field.name, name)) {
        const owned = try own(allocator, replacement);
        field.value.deinit(allocator);
        field.value = owned;
        return;
    };
    return error.ProviderBug;
}
fn own(allocator: std.mem.Allocator, input: value.Value) ProviderError!value.Value {
    return value.Value.initOwned(allocator, input) catch |err| mapValueError(err);
}
fn mapValueError(err: value.ValueError) ProviderError {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.ProviderBug;
}
fn requiredValue(input: value.Value, name: []const u8) ProviderError!value.Value {
    if (input != .object) return error.InvalidConfiguration;
    for (input.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return error.InvalidConfiguration;
}
fn requiredString(input: value.Value, name: []const u8) ProviderError![]const u8 {
    return switch (try requiredValue(input, name)) {
        .string => |entry| entry,
        else => error.InvalidConfiguration,
    };
}
fn optionalString(input: value.Value, name: []const u8) ?[]const u8 {
    return switch (requiredValue(input, name) catch return null) {
        .string => |entry| entry,
        else => null,
    };
}
fn requiredInteger(input: value.Value, name: []const u8) ProviderError!i64 {
    return switch (try requiredValue(input, name)) {
        .integer => |entry| entry,
        else => error.InvalidConfiguration,
    };
}
fn optionalInteger(input: value.Value, name: []const u8) ?i64 {
    return switch (requiredValue(input, name) catch return null) {
        .integer => |entry| entry,
        else => null,
    };
}
fn requiredBool(input: value.Value, name: []const u8) ProviderError!bool {
    return switch (try requiredValue(input, name)) {
        .boolean => |entry| entry,
        else => error.InvalidConfiguration,
    };
}
fn hasValue(input: value.Value, name: []const u8) bool {
    _ = requiredValue(input, name) catch return false;
    return true;
}
fn resolveString(context: *provider_mod.OperationContext, input: value.Value) ProviderError![]const u8 {
    return switch (input) {
        .string => |entry| entry,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}
fn durationSeconds(text: []const u8) ?i64 {
    if (text.len < 2 or text[text.len - 1] != 's') return null;
    return std.fmt.parseInt(i64, text[0 .. text.len - 1], 10) catch null;
}
fn jsonObject(input: std.json.Value) ?std.json.ObjectMap {
    return switch (input) {
        .object => |object| object,
        else => null,
    };
}
fn jsonString(input: ?std.json.Value) ?[]const u8 {
    return switch (input orelse return null) {
        .string => |text| text,
        else => null,
    };
}
fn jsonBool(input: ?std.json.Value) ?bool {
    return switch (input orelse return null) {
        .bool => |flag| flag,
        else => null,
    };
}
