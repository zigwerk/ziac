const std = @import("std");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const rpc = @import("rpc.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;
const database_type = "gcp.firestore.Database";
const index_type = "gcp.firestore.Index";
const field_type = "gcp.firestore.Field";
const backup_schedule_type = "gcp.firestore.BackupSchedule";
const database_update_mask = "concurrencyMode,pointInTimeRecoveryEnablement,deleteProtectionState,realtimeUpdatesMode";
const field_update_mask = "indexConfig,ttlConfig";
const backup_update_mask = "retention,recurrence";

const Kind = enum { database, index, field, backup_schedule };

pub const Handler = struct {
    client: *client_mod.Client,
    operation_policy: operation.Policy,

    pub fn read(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
        const kind = try kindFor(node);
        if (context.operation_handle) |handle| {
            if (try self.waitForResource(context, kind, node, handle)) |result| return .{ .present = result };
        }
        const physical = try self.physicalForRead(context, node, kind, physical_override) orelse return .absent;
        defer context.allocator.free(physical);
        const method = getMethod(kind);
        const path = try rpcPathAlloc(context, method, &.{.{ .field = "name", .value = physical }}, &.{});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .firestore, .method = method.rest.?.method.text(), .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try resultFromJson(context, node, kind, response.body) };
    }

    pub fn diff(context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        const kind = try kindFor(node);
        if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash)) return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        const replacement = switch (kind) {
            .index => true,
            .database => changedAny(node.inputs, observed.observed_inputs, &.{ "project_id", "database_id", "location", "database_type", "edition", "kms_key_name" }),
            .field => changedAny(node.inputs, observed.observed_inputs, &.{ "project_id", "database_id", "collection_group", "field_path" }),
            .backup_schedule => changedAny(node.inputs, observed.observed_inputs, &.{ "project_id", "database_id" }),
        };
        return provider_mod.DiffResult.init(
            context.allocator,
            if (replacement) .replace else .update,
            if (replacement) &.{"Firestore immutable identity or index definition differs"} else &.{"Firestore mutable configuration differs"},
        );
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        const kind = try kindFor(node);
        if (kind == .backup_schedule) return self.createBackupSchedule(context, node);
        const method = createMethod(kind);
        const path = switch (kind) {
            .database => blk: {
                const parent = try std.fmt.allocPrint(context.allocator, "projects/{s}", .{try requiredString(node.inputs, "project_id")});
                defer context.allocator.free(parent);
                break :blk try rpcPathAlloc(context, method, &.{.{ .field = "parent", .value = parent }}, &.{.{ .field = "database_id", .value = try requiredString(node.inputs, "database_id") }});
            },
            .index => blk: {
                const parent = try indexParentAlloc(context.allocator, node);
                defer context.allocator.free(parent);
                break :blk try rpcPathAlloc(context, method, &.{.{ .field = "parent", .value = parent }}, &.{});
            },
            .field => blk: {
                const physical = try deterministicPhysicalAlloc(context.allocator, node, kind);
                defer context.allocator.free(physical);
                break :blk try rpcPathAlloc(context, method, &.{.{ .field = "field.name", .value = physical }}, &.{.{ .field = "update_mask", .value = field_update_mask }});
            },
            .backup_schedule => unreachable,
        };
        defer context.allocator.free(path);
        const body = try bodyAlloc(context, node, kind, null, null, false);
        defer context.allocator.free(body);
        const handle = try self.startOperation(context, method, path, body);
        defer context.allocator.free(handle);
        return pendingResult(context, node, kind, handle);
    }

    pub fn update(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        const kind = try kindFor(node);
        if (kind == .index) return error.InvalidConfiguration;
        if (kind == .backup_schedule) return self.updateBackupSchedule(context, node, observed.physical_id);
        const method = updateMethod(kind);
        const etag = if (kind == .database) outputString(observed, "etag") orelse return error.Conflict else null;
        const routing_field = if (kind == .database) "database.name" else "field.name";
        const update_mask = if (kind == .database) database_update_mask else field_update_mask;
        const path = try rpcPathAlloc(context, method, &.{.{ .field = routing_field, .value = observed.physical_id }}, &.{.{ .field = "update_mask", .value = update_mask }});
        defer context.allocator.free(path);
        const body = try bodyAlloc(context, node, kind, observed.physical_id, etag, false);
        defer context.allocator.free(body);
        const handle = try self.startOperation(context, method, path, body);
        defer context.allocator.free(handle);
        return pendingResult(context, node, kind, handle);
    }

    pub fn delete(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!void {
        const kind = try kindFor(node);
        try validatePhysical(context.allocator, node, kind, canonicalPhysical(physical_id));
        if (kind == .index or kind == .backup_schedule) {
            const method = deleteMethod(kind);
            const path = try rpcPathAlloc(context, method, &.{.{ .field = "name", .value = canonicalPhysical(physical_id) }}, &.{});
            defer context.allocator.free(path);
            var response = self.request(context, .{ .api = .firestore, .method = method.rest.?.method.text(), .path = path }) catch |err| {
                if (err == error.NotFound) return;
                return err;
            };
            response.deinit(context.allocator);
            return;
        }
        if (kind == .field) {
            if (!try requiredBool(node.inputs, "revert_on_delete")) return error.InvalidConfiguration;
            const method = rpc.firestore_admin_v1.update_field;
            const path = try rpcPathAlloc(context, method, &.{.{ .field = "field.name", .value = canonicalPhysical(physical_id) }}, &.{.{ .field = "update_mask", .value = field_update_mask }});
            defer context.allocator.free(path);
            const body = try bodyAlloc(context, node, kind, canonicalPhysical(physical_id), null, true);
            defer context.allocator.free(body);
            const handle = self.startOperation(context, method, path, body) catch |err| {
                if (err == error.NotFound) return;
                return err;
            };
            defer context.allocator.free(handle);
            _ = try self.waitForResource(context, kind, null, handle);
            return;
        }
        const get_path = try rpcPathAlloc(context, rpc.firestore_admin_v1.get_database, &.{.{ .field = "name", .value = canonicalPhysical(physical_id) }}, &.{});
        defer context.allocator.free(get_path);
        var current = self.request(context, .{ .api = .firestore, .method = "GET", .path = get_path }) catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer current.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, current.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const etag = jsonString((jsonObject(parsed.value) orelse return error.ProviderBug).get("etag")) orelse return error.Conflict;
        const method = rpc.firestore_admin_v1.delete_database;
        const path = try rpcPathAlloc(context, method, &.{.{ .field = "name", .value = canonicalPhysical(physical_id) }}, &.{.{ .field = "etag", .value = etag }});
        defer context.allocator.free(path);
        const handle = self.startOperation(context, method, path, "") catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer context.allocator.free(handle);
        _ = try self.waitForResource(context, kind, null, handle);
    }

    fn createBackupSchedule(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        const parent = try databasePhysicalAlloc(context.allocator, node);
        defer context.allocator.free(parent);
        const method = rpc.firestore_admin_v1.create_backup_schedule;
        const path = try rpcPathAlloc(context, method, &.{.{ .field = "parent", .value = parent }}, &.{});
        defer context.allocator.free(path);
        const body = try bodyAlloc(context, node, .backup_schedule, null, null, false);
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .firestore, .method = method.rest.?.method.text(), .path = path, .body = body });
        defer response.deinit(context.allocator);
        return resultFromJson(context, node, .backup_schedule, response.body);
    }

    fn updateBackupSchedule(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical: []const u8) ProviderError!provider_mod.ResourceResult {
        try validatePhysical(context.allocator, node, .backup_schedule, canonicalPhysical(physical));
        const method = rpc.firestore_admin_v1.update_backup_schedule;
        const path = try rpcPathAlloc(context, method, &.{.{ .field = "backup_schedule.name", .value = canonicalPhysical(physical) }}, &.{.{ .field = "update_mask", .value = backup_update_mask }});
        defer context.allocator.free(path);
        const body = try bodyAlloc(context, node, .backup_schedule, canonicalPhysical(physical), null, false);
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .firestore, .method = method.rest.?.method.text(), .path = path, .body = body });
        defer response.deinit(context.allocator);
        return resultFromJson(context, node, .backup_schedule, response.body);
    }

    fn physicalForRead(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, override: ?[]const u8) ProviderError!?[]const u8 {
        _ = self;
        if (override) |provided| {
            const physical = canonicalPhysical(provided);
            try validatePhysical(context.allocator, node, kind, physical);
            return context.allocator.dupe(u8, physical) catch error.OutOfMemory;
        }
        if (kind == .database or kind == .field) return @as(?[]const u8, try deterministicPhysicalAlloc(context.allocator, node, kind));
        if (context.physical_id) |provided| {
            const physical = canonicalPhysical(provided);
            try validatePhysical(context.allocator, node, kind, physical);
            return context.allocator.dupe(u8, physical) catch error.OutOfMemory;
        }
        return null;
    }

    fn startOperation(self: Handler, context: *provider_mod.OperationContext, method: rpc.Method, path: []const u8, body: []const u8) ProviderError![]const u8 {
        var response = try self.request(context, .{ .api = .firestore, .method = method.rest.?.method.text(), .path = path, .body = body });
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const root = jsonObject(parsed.value) orelse return error.ProviderBug;
        return context.allocator.dupe(u8, jsonString(root.get("name")) orelse return error.ProviderBug) catch error.OutOfMemory;
    }

    fn waitForResource(self: Handler, context: *provider_mod.OperationContext, kind: Kind, maybe_node: ?resource.ResourceNode, handle: []const u8) ProviderError!?provider_mod.ResourceResult {
        const base = try std.fmt.allocPrint(context.allocator, "{s}/v1", .{std.mem.trimEnd(u8, self.client.endpoints.firestore, "/")});
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
        return @as(?provider_mod.ResourceResult, try resultFromJson(context, node, kind, body));
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, request_value: client_mod.Request) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, request_value, &diagnostic);
    }
};

pub fn supports(node: resource.ResourceNode) bool {
    return std.mem.eql(u8, node.type_name, database_type) or std.mem.eql(u8, node.type_name, index_type) or
        std.mem.eql(u8, node.type_name, field_type) or std.mem.eql(u8, node.type_name, backup_schedule_type);
}

fn kindFor(node: resource.ResourceNode) ProviderError!Kind {
    if (std.mem.eql(u8, node.type_name, database_type)) return .database;
    if (std.mem.eql(u8, node.type_name, index_type)) return .index;
    if (std.mem.eql(u8, node.type_name, field_type)) return .field;
    if (std.mem.eql(u8, node.type_name, backup_schedule_type)) return .backup_schedule;
    return error.InvalidConfiguration;
}

fn createMethod(kind: Kind) rpc.Method {
    return switch (kind) {
        .database => rpc.firestore_admin_v1.create_database,
        .index => rpc.firestore_admin_v1.create_index,
        .field => rpc.firestore_admin_v1.update_field,
        .backup_schedule => rpc.firestore_admin_v1.create_backup_schedule,
    };
}

fn getMethod(kind: Kind) rpc.Method {
    return switch (kind) {
        .database => rpc.firestore_admin_v1.get_database,
        .index => rpc.firestore_admin_v1.get_index,
        .field => rpc.firestore_admin_v1.get_field,
        .backup_schedule => rpc.firestore_admin_v1.get_backup_schedule,
    };
}

fn updateMethod(kind: Kind) rpc.Method {
    return switch (kind) {
        .database => rpc.firestore_admin_v1.update_database,
        .field => rpc.firestore_admin_v1.update_field,
        .backup_schedule => rpc.firestore_admin_v1.update_backup_schedule,
        .index => unreachable,
    };
}

fn deleteMethod(kind: Kind) rpc.Method {
    return switch (kind) {
        .database => rpc.firestore_admin_v1.delete_database,
        .index => rpc.firestore_admin_v1.delete_index,
        .field => rpc.firestore_admin_v1.update_field,
        .backup_schedule => rpc.firestore_admin_v1.delete_backup_schedule,
    };
}

fn bodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, physical: ?[]const u8, etag: ?[]const u8, reset: bool) ProviderError![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var body: std.json.ObjectMap = .empty;
    switch (kind) {
        .database => {
            if (physical) |name| try body.put(arena, "name", .{ .string = name });
            try body.put(arena, "locationId", .{ .string = try requiredString(node.inputs, "location") });
            try body.put(arena, "type", .{ .string = try requiredString(node.inputs, "database_type") });
            try body.put(arena, "edition", .{ .string = try requiredString(node.inputs, "edition") });
            try body.put(arena, "concurrencyMode", .{ .string = try requiredString(node.inputs, "concurrency_mode") });
            try body.put(arena, "pointInTimeRecoveryEnablement", .{ .string = if (try requiredBool(node.inputs, "point_in_time_recovery")) "POINT_IN_TIME_RECOVERY_ENABLED" else "POINT_IN_TIME_RECOVERY_DISABLED" });
            try body.put(arena, "deleteProtectionState", .{ .string = if (try requiredBool(node.inputs, "delete_protection")) "DELETE_PROTECTION_ENABLED" else "DELETE_PROTECTION_DISABLED" });
            try body.put(arena, "realtimeUpdatesMode", .{ .string = try requiredString(node.inputs, "realtime_updates_mode") });
            const key = try requiredString(node.inputs, "kms_key_name");
            if (key.len > 0) {
                var cmek: std.json.ObjectMap = .empty;
                try cmek.put(arena, "kmsKeyName", .{ .string = key });
                try body.put(arena, "cmekConfig", .{ .object = cmek });
            }
            if (etag) |present| try body.put(arena, "etag", .{ .string = present });
        },
        .index => {
            const fields_json = try requiredString(node.inputs, "fields_json");
            var parsed = std.json.parseFromSlice(std.json.Value, arena, fields_json, .{}) catch return error.InvalidConfiguration;
            defer parsed.deinit();
            try body.put(arena, "fields", parsed.value);
            try body.put(arena, "queryScope", .{ .string = try requiredString(node.inputs, "query_scope") });
            try body.put(arena, "apiScope", .{ .string = try requiredString(node.inputs, "api_scope") });
            const density = try requiredString(node.inputs, "density");
            if (density.len > 0) try body.put(arena, "density", .{ .string = density });
            if (try requiredBool(node.inputs, "multikey")) try body.put(arena, "multikey", .{ .bool = true });
        },
        .field => {
            const name = physical orelse try deterministicPhysicalAlloc(arena, node, kind);
            try body.put(arena, "name", .{ .string = name });
            if (!reset) {
                var index_config: std.json.ObjectMap = .empty;
                var indexes = std.json.Array.init(arena);
                const modes_json = try requiredString(node.inputs, "index_modes_json");
                var parsed = std.json.parseFromSlice(std.json.Value, arena, modes_json, .{}) catch return error.InvalidConfiguration;
                defer parsed.deinit();
                if (parsed.value != .array) return error.InvalidConfiguration;
                for (parsed.value.array.items) |mode_value| {
                    const mode = jsonString(mode_value) orelse return error.InvalidConfiguration;
                    var item: std.json.ObjectMap = .empty;
                    if (std.mem.eql(u8, mode, "CONTAINS")) try item.put(arena, "arrayConfig", .{ .string = mode }) else try item.put(arena, "order", .{ .string = mode });
                    try item.put(arena, "queryScope", .{ .string = try requiredString(node.inputs, "query_scope") });
                    try indexes.append(.{ .object = item });
                }
                try index_config.put(arena, "indexes", .{ .array = indexes });
                try body.put(arena, "indexConfig", .{ .object = index_config });
                if (try requiredBool(node.inputs, "ttl_enabled")) try body.put(arena, "ttlConfig", .{ .object = .empty });
            }
        },
        .backup_schedule => {
            if (physical) |name| try body.put(arena, "name", .{ .string = name });
            const retention = try std.fmt.allocPrint(arena, "{d}s", .{try requiredInteger(node.inputs, "retention_seconds")});
            try body.put(arena, "retention", .{ .string = retention });
            if (std.mem.eql(u8, try requiredString(node.inputs, "recurrence"), "DAILY")) {
                try body.put(arena, "dailyRecurrence", .{ .object = .empty });
            } else {
                var weekly: std.json.ObjectMap = .empty;
                try weekly.put(arena, "day", .{ .string = try requiredString(node.inputs, "day_of_week") });
                try body.put(arena, "weeklyRecurrence", .{ .object = weekly });
            }
        },
    }
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = body }, .{}) catch error.OutOfMemory;
}

fn resultFromJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, body: []const u8) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const physical = jsonString(root.get("name")) orelse return error.ProviderBug;
    try validatePhysical(context.allocator, node, kind, physical);
    var observed = try normalizedInputsAlloc(context, node, kind, root);
    defer observed.deinit(context.allocator);
    const outputs = switch (kind) {
        .database => &[_]state.StateOutput{
            .{ .name = "name", .value = .{ .string = physical } },
            .{ .name = "etag", .value = .{ .string = jsonString(root.get("etag")) orelse "" } },
            .{ .name = "uid", .value = .{ .string = jsonString(root.get("uid")) orelse "" } },
            .{ .name = "state", .value = .{ .string = jsonString(root.get("state")) orelse "" } },
        },
        .index => &[_]state.StateOutput{
            .{ .name = "name", .value = .{ .string = physical } },
            .{ .name = "state", .value = .{ .string = jsonString(root.get("state")) orelse "" } },
        },
        .field => &[_]state.StateOutput{
            .{ .name = "name", .value = .{ .string = physical } },
            .{ .name = "ttl_state", .value = .{ .string = ttlState(root) } },
        },
        .backup_schedule => &[_]state.StateOutput{
            .{ .name = "name", .value = .{ .string = physical } },
            .{ .name = "create_time", .value = .{ .string = jsonString(root.get("createTime")) orelse "" } },
        },
    };
    return provider_mod.ResourceResult.init(context.allocator, physical, observed, outputs, null);
}

fn normalizedInputsAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, root: std.json.ObjectMap) ProviderError!value.Value {
    if (kind == .index) return normalizedIndexInputsAlloc(context, node, root);
    if (kind == .field) return normalizedFieldInputsAlloc(context, node, root);
    if (kind == .backup_schedule) return normalizedBackupInputsAlloc(context, node, root);
    const cmek = if (root.get("cmekConfig")) |present| jsonString((jsonObject(present) orelse return error.ProviderBug).get("kmsKeyName")) orelse "" else "";
    const fields = [_]value.Field{
        .{ .name = "concurrency_mode", .value = .{ .string = jsonString(root.get("concurrencyMode")) orelse "" } },
        .{ .name = "database_id", .value = .{ .string = try requiredString(node.inputs, "database_id") } },
        .{ .name = "database_type", .value = .{ .string = jsonString(root.get("type")) orelse "" } },
        .{ .name = "delete_protection", .value = .{ .boolean = std.mem.eql(u8, jsonString(root.get("deleteProtectionState")) orelse "", "DELETE_PROTECTION_ENABLED") } },
        .{ .name = "edition", .value = .{ .string = jsonString(root.get("edition")) orelse "STANDARD" } },
        .{ .name = "kms_key_name", .value = .{ .string = cmek } },
        .{ .name = "location", .value = .{ .string = jsonString(root.get("locationId")) orelse "" } },
        .{ .name = "point_in_time_recovery", .value = .{ .boolean = std.mem.eql(u8, jsonString(root.get("pointInTimeRecoveryEnablement")) orelse "", "POINT_IN_TIME_RECOVERY_ENABLED") } },
        .{ .name = "project_id", .value = .{ .string = try requiredString(node.inputs, "project_id") } },
        .{ .name = "realtime_updates_mode", .value = .{ .string = jsonString(root.get("realtimeUpdatesMode")) orelse "REALTIME_UPDATES_MODE_ENABLED" } },
    };
    return value.Value.initOwned(context.allocator, .{ .object = &fields }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateField => error.ProviderBug,
    };
}

fn normalizedIndexInputsAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, root: std.json.ObjectMap) ProviderError!value.Value {
    const remote_fields = root.get("fields") orelse return error.ProviderBug;
    if (remote_fields != .array) return error.ProviderBug;
    const fields_json = std.json.Stringify.valueAlloc(context.allocator, remote_fields, .{}) catch return error.OutOfMemory;
    defer context.allocator.free(fields_json);
    const fields = [_]value.Field{
        .{ .name = "api_scope", .value = .{ .string = jsonString(root.get("apiScope")) orelse "ANY_API" } },
        .{ .name = "collection_group", .value = try requiredValue(node.inputs, "collection_group") },
        .{ .name = "database", .value = try requiredValue(node.inputs, "database") },
        .{ .name = "database_id", .value = try requiredValue(node.inputs, "database_id") },
        .{ .name = "density", .value = .{ .string = jsonString(root.get("density")) orelse try requiredString(node.inputs, "density") } },
        .{ .name = "fields_json", .value = .{ .string = fields_json } },
        .{ .name = "multikey", .value = .{ .boolean = jsonBool(root.get("multikey")) orelse false } },
        .{ .name = "project_id", .value = try requiredValue(node.inputs, "project_id") },
        .{ .name = "query_scope", .value = .{ .string = jsonString(root.get("queryScope")) orelse "COLLECTION" } },
    };
    return ownedObject(context.allocator, &fields);
}

fn normalizedFieldInputsAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, root: std.json.ObjectMap) ProviderError!value.Value {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var modes = std.json.Array.init(arena);
    var query_scope = try requiredString(node.inputs, "query_scope");
    if (root.get("indexConfig")) |config_value| {
        const config = jsonObject(config_value) orelse return error.ProviderBug;
        if (config.get("indexes")) |indexes_value| {
            if (indexes_value != .array) return error.ProviderBug;
            for (indexes_value.array.items) |index_value| {
                const index = jsonObject(index_value) orelse return error.ProviderBug;
                const mode = jsonString(index.get("order")) orelse jsonString(index.get("arrayConfig")) orelse return error.ProviderBug;
                try modes.append(.{ .string = mode });
                query_scope = jsonString(index.get("queryScope")) orelse query_scope;
            }
        }
    }
    const modes_json = std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .array = modes }, .{}) catch return error.OutOfMemory;
    defer context.allocator.free(modes_json);
    const fields = [_]value.Field{
        .{ .name = "collection_group", .value = try requiredValue(node.inputs, "collection_group") },
        .{ .name = "database", .value = try requiredValue(node.inputs, "database") },
        .{ .name = "database_id", .value = try requiredValue(node.inputs, "database_id") },
        .{ .name = "field_path", .value = try requiredValue(node.inputs, "field_path") },
        .{ .name = "index_modes_json", .value = .{ .string = modes_json } },
        .{ .name = "project_id", .value = try requiredValue(node.inputs, "project_id") },
        .{ .name = "query_scope", .value = .{ .string = query_scope } },
        .{ .name = "revert_on_delete", .value = try requiredValue(node.inputs, "revert_on_delete") },
        .{ .name = "ttl_enabled", .value = .{ .boolean = root.get("ttlConfig") != null } },
    };
    return ownedObject(context.allocator, &fields);
}

fn normalizedBackupInputsAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, root: std.json.ObjectMap) ProviderError!value.Value {
    const retention_text = jsonString(root.get("retention")) orelse return error.ProviderBug;
    const retention = parseDurationSeconds(retention_text) orelse return error.ProviderBug;
    const weekly = root.get("weeklyRecurrence");
    const day = if (weekly) |weekly_value| jsonString((jsonObject(weekly_value) orelse return error.ProviderBug).get("day")) orelse return error.ProviderBug else "";
    const fields = [_]value.Field{
        .{ .name = "database", .value = try requiredValue(node.inputs, "database") },
        .{ .name = "database_id", .value = try requiredValue(node.inputs, "database_id") },
        .{ .name = "day_of_week", .value = .{ .string = day } },
        .{ .name = "name", .value = try requiredValue(node.inputs, "name") },
        .{ .name = "project_id", .value = try requiredValue(node.inputs, "project_id") },
        .{ .name = "recurrence", .value = .{ .string = if (weekly != null) "WEEKLY" else "DAILY" } },
        .{ .name = "retention_seconds", .value = .{ .integer = retention } },
    };
    return ownedObject(context.allocator, &fields);
}

fn ownedObject(allocator: std.mem.Allocator, fields: []const value.Field) ProviderError!value.Value {
    return value.Value.initOwned(allocator, .{ .object = fields }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateField => error.ProviderBug,
    };
}

fn parseDurationSeconds(text: []const u8) ?i64 {
    if (text.len < 2 or text[text.len - 1] != 's') return null;
    return std.fmt.parseInt(i64, text[0 .. text.len - 1], 10) catch null;
}

fn pendingResult(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, handle: []const u8) ProviderError!provider_mod.ResourceResult {
    const physical = if (kind == .database or kind == .field)
        try deterministicPhysicalAlloc(context.allocator, node, kind)
    else
        try std.fmt.allocPrint(context.allocator, "pending:{s}", .{node.id});
    defer context.allocator.free(physical);
    const outputs = switch (kind) {
        .database => &[_]state.StateOutput{
            .{ .name = "name", .value = .{ .string = physical } },
            .{ .name = "etag", .value = .{ .unknown_reason = "Firestore operation pending" } },
            .{ .name = "uid", .value = .{ .unknown_reason = "Firestore operation pending" } },
            .{ .name = "state", .value = .{ .string = "CREATING" } },
        },
        .index => &[_]state.StateOutput{
            .{ .name = "name", .value = .{ .unknown_reason = "Firestore assigns the index name" } },
            .{ .name = "state", .value = .{ .string = "CREATING" } },
        },
        .field => &[_]state.StateOutput{
            .{ .name = "name", .value = .{ .string = physical } },
            .{ .name = "ttl_state", .value = .{ .string = "CREATING" } },
        },
        .backup_schedule => unreachable,
    };
    var result = try provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, outputs, handle);
    result.completed = false;
    return result;
}

fn deterministicPhysicalAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    return switch (kind) {
        .database => databasePhysicalAlloc(allocator, node),
        .field => std.fmt.allocPrint(allocator, "projects/{s}/databases/{s}/collectionGroups/{s}/fields/{s}", .{
            try requiredString(node.inputs, "project_id"),
            try requiredString(node.inputs, "database_id"),
            try requiredString(node.inputs, "collection_group"),
            try requiredString(node.inputs, "field_path"),
        }) catch error.OutOfMemory,
        else => error.InvalidConfiguration,
    };
}

fn databasePhysicalAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "projects/{s}/databases/{s}", .{
        try requiredString(node.inputs, "project_id"),
        try requiredString(node.inputs, "database_id"),
    }) catch error.OutOfMemory;
}

fn indexParentAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "projects/{s}/databases/{s}/collectionGroups/{s}", .{
        try requiredString(node.inputs, "project_id"),
        try requiredString(node.inputs, "database_id"),
        try requiredString(node.inputs, "collection_group"),
    }) catch error.OutOfMemory;
}

fn validatePhysical(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind, physical: []const u8) ProviderError!void {
    if (kind == .database or kind == .field) {
        const expected = try deterministicPhysicalAlloc(allocator, node, kind);
        defer allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical)) return error.InvalidConfiguration;
        return;
    }
    const parent = if (kind == .index)
        try indexParentAlloc(allocator, node)
    else
        try databasePhysicalAlloc(allocator, node);
    defer allocator.free(parent);
    const segment = if (kind == .index) "/indexes/" else "/backupSchedules/";
    if (!std.mem.startsWith(u8, physical, parent) or physical.len <= parent.len + segment.len or !std.mem.eql(u8, physical[parent.len .. parent.len + segment.len], segment)) return error.InvalidConfiguration;
}

fn canonicalPhysical(physical: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, physical, "//firestore.googleapis.com/")) physical["//firestore.googleapis.com/".len..] else physical;
}

fn changedAny(desired: value.Value, observed: value.Value, fields: []const []const u8) bool {
    for (fields) |field| if (!valuesEqual(inputValue(desired, field), inputValue(observed, field))) return true;
    return false;
}

fn valuesEqual(left: ?value.Value, right: ?value.Value) bool {
    const lhs = left orelse return right == null;
    const rhs = right orelse return false;
    return switch (lhs) {
        .string => |text| rhs == .string and std.mem.eql(u8, text, rhs.string),
        .integer => |number| rhs == .integer and number == rhs.integer,
        .boolean => |boolean| rhs == .boolean and boolean == rhs.boolean,
        else => false,
    };
}

fn ttlState(root: std.json.ObjectMap) []const u8 {
    const config = root.get("ttlConfig") orelse return "DISABLED";
    const object = jsonObject(config) orelse return "DISABLED";
    return jsonString(object.get("state")) orelse "ENABLED";
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

fn inputValue(input: value.Value, name: []const u8) ?value.Value {
    if (input != .object) return null;
    for (input.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return null;
}

fn requiredValue(input: value.Value, name: []const u8) ProviderError!value.Value {
    return inputValue(input, name) orelse error.InvalidConfiguration;
}

fn requiredString(input: value.Value, name: []const u8) ProviderError![]const u8 {
    return switch (try requiredValue(input, name)) {
        .string => |text| text,
        else => error.InvalidConfiguration,
    };
}

fn requiredBool(input: value.Value, name: []const u8) ProviderError!bool {
    return switch (try requiredValue(input, name)) {
        .boolean => |present| present,
        else => error.InvalidConfiguration,
    };
}

fn requiredInteger(input: value.Value, name: []const u8) ProviderError!i64 {
    return switch (try requiredValue(input, name)) {
        .integer => |present| present,
        else => error.InvalidConfiguration,
    };
}

fn jsonObject(input: std.json.Value) ?std.json.ObjectMap {
    return switch (input) {
        .object => |object| object,
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

fn jsonBool(input: ?std.json.Value) ?bool {
    const present = input orelse return null;
    return switch (present) {
        .bool => |boolean| boolean,
        else => null,
    };
}
