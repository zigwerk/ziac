const std = @import("std");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;
const instance_type = "gcp.spanner.Instance";
const database_type = "gcp.spanner.Database";
const backup_type = "gcp.spanner.Backup";
const schedule_type = "gcp.spanner.BackupSchedule";

const Kind = enum { instance, database, backup, schedule };

pub const Handler = struct {
    client: *client_mod.Client,
    operation_policy: operation.Policy = .{},

    pub fn read(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
        const kind = try kindFor(node);
        if (context.operation_handle) |handle| try self.waitOperation(context, handle);
        const physical = if (physical_override) |provided|
            try canonicalPhysicalAlloc(context.allocator, node, kind, provided)
        else
            try deterministicPhysicalAlloc(context.allocator, node, kind);
        defer context.allocator.free(physical);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .spanner, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        const ddl = if (kind == .database) try self.readDdlAlloc(context, physical) else null;
        defer if (ddl) |present| context.allocator.free(present);
        return .{ .present = try resultFromJson(context, node, kind, response.body, ddl) };
    }

    pub fn diff(context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        const kind = try kindFor(node);
        if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash)) return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        const replacement = switch (kind) {
            .instance => changedAny(node.inputs, observed.observed_inputs, &.{ "project_id", "instance_id", "config" }),
            .database => changedAny(node.inputs, observed.observed_inputs, &.{ "project_id", "instance_id", "database_id", "dialect", "kms_key_name" }),
            .backup => changedAny(node.inputs, observed.observed_inputs, &.{ "project_id", "instance_id", "database_id", "backup_id", "database", "version_time", "kms_key_name" }),
            .schedule => changedAny(node.inputs, observed.observed_inputs, &.{ "project_id", "instance_id", "database_id", "schedule_id", "database" }),
        };
        return provider_mod.DiffResult.init(
            context.allocator,
            if (replacement) .replace else .update,
            if (replacement) &.{"Spanner immutable identity, placement, dialect, source or encryption differs"} else &.{"Spanner mutable configuration differs"},
        );
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        const kind = try kindFor(node);
        const path = try createPathAlloc(context.allocator, node, kind);
        defer context.allocator.free(path);
        const body = try bodyAlloc(context, node, kind, false, null);
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .spanner, .method = "POST", .path = path, .body = body });
        defer response.deinit(context.allocator);
        if (kind == .schedule) return resultFromJson(context, node, kind, response.body, null);
        const handle = try operationNameAlloc(context.allocator, response.body);
        defer context.allocator.free(handle);
        return pendingResult(context, node, kind, handle);
    }

    pub fn update(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        const kind = try kindFor(node);
        const physical = observed.physical_id;
        if (kind == .database and changedField(node.inputs, observed.observed_inputs, "ddl_json")) {
            const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}/ddl", .{physical});
            defer context.allocator.free(path);
            const body = try ddlUpdateBodyAlloc(context, node);
            defer context.allocator.free(body);
            var response = try self.request(context, .{ .api = .spanner, .method = "PATCH", .path = path, .body = body });
            defer response.deinit(context.allocator);
            const handle = try operationNameAlloc(context.allocator, response.body);
            defer context.allocator.free(handle);
            return pendingResult(context, node, kind, handle);
        }
        const mask = try updateMaskAlloc(context.allocator, node, observed.observed_inputs, kind);
        defer context.allocator.free(mask);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}?updateMask={s}", .{ physical, mask });
        defer context.allocator.free(path);
        const body = try bodyAlloc(context, node, kind, true, physical);
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .spanner, .method = "PATCH", .path = path, .body = body });
        defer response.deinit(context.allocator);
        if (kind == .schedule) return resultFromJson(context, node, kind, response.body, null);
        const handle = try operationNameAlloc(context.allocator, response.body);
        defer context.allocator.free(handle);
        return pendingResult(context, node, kind, handle);
    }

    pub fn delete(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!void {
        const kind = try kindFor(node);
        const physical = try canonicalPhysicalAlloc(context.allocator, node, kind, physical_id);
        defer context.allocator.free(physical);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .spanner, .method = "DELETE", .path = path }) catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer response.deinit(context.allocator);
        if (kind == .schedule) return;
        const handle = try operationNameAlloc(context.allocator, response.body);
        defer context.allocator.free(handle);
        try self.waitOperation(context, handle);
    }

    pub fn importResource(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!provider_mod.ResourceResult {
        const read_result = try self.read(context, node, physical_id);
        return switch (read_result) {
            .absent => error.NotFound,
            .present => |present| present,
        };
    }

    fn readDdlAlloc(self: Handler, context: *provider_mod.OperationContext, physical: []const u8) ProviderError![]const u8 {
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}/ddl", .{physical});
        defer context.allocator.free(path);
        var response = try self.request(context, .{ .api = .spanner, .method = "GET", .path = path });
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const root = jsonObject(parsed.value) orelse return error.ProviderBug;
        const statements = root.get("statements") orelse return error.ProviderBug;
        if (statements != .array) return error.ProviderBug;
        var filtered = std.json.Array.init(context.allocator);
        defer filtered.deinit();
        for (statements.array.items) |statement| {
            const text = jsonString(statement) orelse return error.ProviderBug;
            if (std.ascii.startsWithIgnoreCase(std.mem.trim(u8, text, " \t\r\n"), "ALTER DATABASE")) continue;
            try filtered.append(.{ .string = text });
        }
        return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .array = filtered }, .{}) catch error.OutOfMemory;
    }

    fn waitOperation(self: Handler, context: *provider_mod.OperationContext, handle: []const u8) ProviderError!void {
        const base = try std.fmt.allocPrint(context.allocator, "{s}/v1", .{std.mem.trimEnd(u8, self.client.endpoints.spanner, "/")});
        defer context.allocator.free(base);
        var target = operation.Target.genericAlloc(context.allocator, base, handle) catch return error.OutOfMemory;
        defer target.deinit(context.allocator);
        var completed = try operation.waitAlloc(self.client, context, target, self.operation_policy);
        completed.deinit(context.allocator);
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, request_value: client_mod.Request) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, request_value, &diagnostic);
    }
};

pub fn supports(node: resource.ResourceNode) bool {
    return std.mem.eql(u8, node.type_name, instance_type) or std.mem.eql(u8, node.type_name, database_type) or std.mem.eql(u8, node.type_name, backup_type) or std.mem.eql(u8, node.type_name, schedule_type);
}

fn kindFor(node: resource.ResourceNode) ProviderError!Kind {
    if (std.mem.eql(u8, node.type_name, instance_type)) return .instance;
    if (std.mem.eql(u8, node.type_name, database_type)) return .database;
    if (std.mem.eql(u8, node.type_name, backup_type)) return .backup;
    if (std.mem.eql(u8, node.type_name, schedule_type)) return .schedule;
    return error.InvalidConfiguration;
}

fn deterministicPhysicalAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    const project = try requiredString(node.inputs, "project_id");
    const instance = try requiredString(node.inputs, "instance_id");
    return switch (kind) {
        .instance => std.fmt.allocPrint(allocator, "projects/{s}/instances/{s}", .{ project, instance }) catch error.OutOfMemory,
        .database => std.fmt.allocPrint(allocator, "projects/{s}/instances/{s}/databases/{s}", .{ project, instance, try requiredString(node.inputs, "database_id") }) catch error.OutOfMemory,
        .backup => std.fmt.allocPrint(allocator, "projects/{s}/instances/{s}/backups/{s}", .{ project, instance, try requiredString(node.inputs, "backup_id") }) catch error.OutOfMemory,
        .schedule => std.fmt.allocPrint(allocator, "projects/{s}/instances/{s}/databases/{s}/backupSchedules/{s}", .{ project, instance, try requiredString(node.inputs, "database_id"), try requiredString(node.inputs, "schedule_id") }) catch error.OutOfMemory,
    };
}

fn canonicalPhysicalAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind, physical: []const u8) ProviderError![]const u8 {
    const canonical = std.mem.trimStart(u8, physical, "/");
    const expected = try deterministicPhysicalAlloc(allocator, node, kind);
    defer allocator.free(expected);
    if (!std.mem.eql(u8, canonical, expected)) return error.InvalidConfiguration;
    return allocator.dupe(u8, canonical) catch error.OutOfMemory;
}

fn createPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    const project = try requiredString(node.inputs, "project_id");
    const instance = try requiredString(node.inputs, "instance_id");
    return switch (kind) {
        .instance => std.fmt.allocPrint(allocator, "/v1/projects/{s}/instances", .{project}) catch error.OutOfMemory,
        .database => std.fmt.allocPrint(allocator, "/v1/projects/{s}/instances/{s}/databases", .{ project, instance }) catch error.OutOfMemory,
        .backup => blk: {
            const key = try requiredString(node.inputs, "kms_key_name");
            if (key.len == 0) break :blk std.fmt.allocPrint(allocator, "/v1/projects/{s}/instances/{s}/backups?backupId={s}", .{ project, instance, try requiredString(node.inputs, "backup_id") }) catch error.OutOfMemory;
            const encoded_key = try percentEncodeAlloc(allocator, key);
            defer allocator.free(encoded_key);
            break :blk std.fmt.allocPrint(allocator, "/v1/projects/{s}/instances/{s}/backups?backupId={s}&encryptionConfig.encryptionType=CUSTOMER_MANAGED_ENCRYPTION&encryptionConfig.kmsKeyNames={s}", .{ project, instance, try requiredString(node.inputs, "backup_id"), encoded_key }) catch error.OutOfMemory;
        },
        .schedule => std.fmt.allocPrint(allocator, "/v1/projects/{s}/instances/{s}/databases/{s}/backupSchedules?backupScheduleId={s}", .{ project, instance, try requiredString(node.inputs, "database_id"), try requiredString(node.inputs, "schedule_id") }) catch error.OutOfMemory,
    };
}

fn bodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, update: bool, physical: ?[]const u8) ProviderError![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root: std.json.ObjectMap = .empty;
    switch (kind) {
        .instance => {
            var instance: std.json.ObjectMap = .empty;
            const project = try requiredString(node.inputs, "project_id");
            const id = try requiredString(node.inputs, "instance_id");
            const config = try requiredString(node.inputs, "config");
            try instance.put(arena, "name", .{ .string = try std.fmt.allocPrint(arena, "projects/{s}/instances/{s}", .{ project, id }) });
            try instance.put(arena, "config", .{ .string = if (std.mem.startsWith(u8, config, "projects/")) config else try std.fmt.allocPrint(arena, "projects/{s}/instanceConfigs/{s}", .{ project, config }) });
            try instance.put(arena, "displayName", .{ .string = try requiredString(node.inputs, "display_name") });
            try instance.put(arena, "edition", .{ .string = try requiredString(node.inputs, "edition") });
            try instance.put(arena, "defaultBackupScheduleType", .{ .string = try requiredString(node.inputs, "default_backup_schedule") });
            try instance.put(arena, "labels", .{ .object = try keyValuesObject(arena, try requiredString(node.inputs, "labels")) });
            try appendCapacity(arena, &instance, node);
            if (update) return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = instance }, .{}) catch error.OutOfMemory;
            try root.put(arena, "instanceId", .{ .string = id });
            try root.put(arena, "instance", .{ .object = instance });
        },
        .database => {
            if (update) {
                try root.put(arena, "name", .{ .string = physical orelse return error.InvalidConfiguration });
                try root.put(arena, "enableDropProtection", .{ .bool = try requiredBool(node.inputs, "drop_protection") });
            } else {
                const id = try requiredString(node.inputs, "database_id");
                try root.put(arena, "createStatement", .{ .string = try std.fmt.allocPrint(arena, "CREATE DATABASE `{s}`", .{id}) });
                try root.put(arena, "databaseDialect", .{ .string = try requiredString(node.inputs, "dialect") });
                var statements = try parseStringArray(arena, try requiredString(node.inputs, "ddl_json"));
                try appendDatabaseOptions(arena, &statements, node);
                try root.put(arena, "extraStatements", .{ .array = statements });
                const key = try requiredString(node.inputs, "kms_key_name");
                if (key.len > 0) {
                    var encryption: std.json.ObjectMap = .empty;
                    var keys = std.json.Array.init(arena);
                    try keys.append(.{ .string = key });
                    try encryption.put(arena, "kmsKeyNames", .{ .array = keys });
                    try root.put(arena, "encryptionConfig", .{ .object = encryption });
                }
            }
        },
        .backup => {
            try root.put(arena, "name", .{ .string = physical orelse "" });
            try root.put(arena, "database", try outputOrString(node.inputs, "database"));
            try root.put(arena, "expireTime", .{ .string = try requiredString(node.inputs, "expire_time") });
            const version = try requiredString(node.inputs, "version_time");
            if (version.len > 0) try root.put(arena, "versionTime", .{ .string = version });
        },
        .schedule => {
            if (physical) |name| try root.put(arena, "name", .{ .string = name });
            var cron: std.json.ObjectMap = .empty;
            try cron.put(arena, "text", .{ .string = try requiredString(node.inputs, "cron") });
            var spec: std.json.ObjectMap = .empty;
            try spec.put(arena, "cronSpec", .{ .object = cron });
            try root.put(arena, "spec", .{ .object = spec });
            try root.put(arena, "retentionDuration", .{ .string = try std.fmt.allocPrint(arena, "{d}s", .{try requiredInteger(node.inputs, "retention_seconds")}) });
            try root.put(arena, if (std.mem.eql(u8, try requiredString(node.inputs, "mode"), "incremental")) "incrementalBackupSpec" else "fullBackupSpec", .{ .object = .empty });
            try appendBackupEncryption(arena, &root, try requiredString(node.inputs, "kms_key_name"));
        },
    }
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch error.OutOfMemory;
}

fn appendBackupEncryption(allocator: std.mem.Allocator, root: *std.json.ObjectMap, key: []const u8) ProviderError!void {
    if (key.len == 0) return;
    var keys = std.json.Array.init(allocator);
    try keys.append(.{ .string = key });
    var encryption: std.json.ObjectMap = .empty;
    try encryption.put(allocator, "encryptionType", .{ .string = "CUSTOMER_MANAGED_ENCRYPTION" });
    try encryption.put(allocator, "kmsKeyNames", .{ .array = keys });
    try root.put(allocator, "encryptionConfig", .{ .object = encryption });
}

fn ddlUpdateBodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var statements = try parseStringArray(arena, try requiredString(node.inputs, "ddl_json"));
    try appendDatabaseOptions(arena, &statements, node);
    var root: std.json.ObjectMap = .empty;
    try root.put(arena, "statements", .{ .array = statements });
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch error.OutOfMemory;
}

fn appendDatabaseOptions(allocator: std.mem.Allocator, statements: *std.json.Array, node: resource.ResourceNode) ProviderError!void {
    const id = try requiredString(node.inputs, "database_id");
    const retention = try requiredString(node.inputs, "version_retention_period");
    if (!std.mem.eql(u8, retention, "1h")) try statements.append(.{ .string = try std.fmt.allocPrint(allocator, "ALTER DATABASE `{s}` SET OPTIONS (version_retention_period = '{s}')", .{ id, retention }) });
    const leader = try requiredString(node.inputs, "default_leader");
    if (leader.len > 0) try statements.append(.{ .string = try std.fmt.allocPrint(allocator, "ALTER DATABASE `{s}` SET OPTIONS (default_leader = '{s}')", .{ id, leader }) });
}

fn appendCapacity(allocator: std.mem.Allocator, instance: *std.json.ObjectMap, node: resource.ResourceNode) ProviderError!void {
    const mode = try requiredString(node.inputs, "capacity_mode");
    const min = try requiredInteger(node.inputs, "capacity_min");
    const max = try requiredInteger(node.inputs, "capacity_max");
    if (std.mem.eql(u8, mode, "nodes")) return instance.put(allocator, "nodeCount", .{ .integer = max });
    if (std.mem.eql(u8, mode, "processing_units")) return instance.put(allocator, "processingUnits", .{ .integer = max });
    var limits: std.json.ObjectMap = .empty;
    if (std.mem.eql(u8, mode, "autoscaling_nodes")) {
        try limits.put(allocator, "minNodes", .{ .integer = min });
        try limits.put(allocator, "maxNodes", .{ .integer = max });
    } else {
        try limits.put(allocator, "minProcessingUnits", .{ .integer = min });
        try limits.put(allocator, "maxProcessingUnits", .{ .integer = max });
    }
    var targets: std.json.ObjectMap = .empty;
    try targets.put(allocator, "highPriorityCpuUtilizationPercent", .{ .integer = try requiredInteger(node.inputs, "cpu_target") });
    try targets.put(allocator, "storageUtilizationPercent", .{ .integer = try requiredInteger(node.inputs, "storage_target") });
    var autoscaling: std.json.ObjectMap = .empty;
    try autoscaling.put(allocator, "autoscalingLimits", .{ .object = limits });
    try autoscaling.put(allocator, "autoscalingTargets", .{ .object = targets });
    try instance.put(allocator, "autoscalingConfig", .{ .object = autoscaling });
}

fn resultFromJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, body: []const u8, ddl: ?[]const u8) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const physical = jsonString(root.get("name")) orelse return error.ProviderBug;
    var observed = try normalizedInputsAlloc(context, node, kind, root, ddl);
    defer observed.deinit(context.allocator);
    const outputs = switch (kind) {
        .instance => &[_]state.StateOutput{
            .{ .name = "name", .value = .{ .string = physical } },
            .{ .name = "state", .value = .{ .string = jsonString(root.get("state")) orelse "" } },
        },
        .database => &[_]state.StateOutput{
            .{ .name = "name", .value = .{ .string = physical } },
            .{ .name = "state", .value = .{ .string = jsonString(root.get("state")) orelse "" } },
        },
        .backup => &[_]state.StateOutput{
            .{ .name = "name", .value = .{ .string = physical } },
            .{ .name = "state", .value = .{ .string = jsonString(root.get("state")) orelse "" } },
            .{ .name = "size_bytes", .value = .{ .integer = jsonIntegerString(root.get("sizeBytes")) } },
        },
        .schedule => &[_]state.StateOutput{
            .{ .name = "name", .value = .{ .string = physical } },
            .{ .name = "update_time", .value = .{ .string = jsonString(root.get("updateTime")) orelse "" } },
        },
    };
    return provider_mod.ResourceResult.init(context.allocator, physical, observed, outputs, null);
}

fn normalizedInputsAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, root: std.json.ObjectMap, ddl: ?[]const u8) ProviderError!value.Value {
    return switch (kind) {
        .instance => normalizedInstance(context, node, root),
        .database => normalizedDatabase(context, node, root, ddl orelse return error.ProviderBug),
        .backup => normalizedBackup(context, node, root),
        .schedule => normalizedSchedule(context, node, root),
    };
}

fn normalizedInstance(context: *provider_mod.OperationContext, node: resource.ResourceNode, root: std.json.ObjectMap) ProviderError!value.Value {
    const config = lastSegment(jsonString(root.get("config")) orelse "");
    const labels = try jsonMapTextAlloc(context.allocator, root.get("labels"));
    defer context.allocator.free(labels);
    var mode: []const u8 = "processing_units";
    var min: i64 = 0;
    var max: i64 = 0;
    var cpu: i64 = 0;
    var storage: i64 = 0;
    if (root.get("autoscalingConfig")) |candidate| {
        const autoscaling = jsonObject(candidate) orelse return error.ProviderBug;
        const limits = jsonObject(autoscaling.get("autoscalingLimits") orelse return error.ProviderBug) orelse return error.ProviderBug;
        const targets = jsonObject(autoscaling.get("autoscalingTargets") orelse return error.ProviderBug) orelse return error.ProviderBug;
        if (jsonInteger(limits.get("minNodes"))) |present| {
            mode = "autoscaling_nodes";
            min = present;
            max = jsonInteger(limits.get("maxNodes")) orelse return error.ProviderBug;
        } else {
            mode = "autoscaling_processing_units";
            min = jsonInteger(limits.get("minProcessingUnits")) orelse return error.ProviderBug;
            max = jsonInteger(limits.get("maxProcessingUnits")) orelse return error.ProviderBug;
        }
        cpu = jsonInteger(targets.get("highPriorityCpuUtilizationPercent")) orelse 0;
        storage = jsonInteger(targets.get("storageUtilizationPercent")) orelse 0;
    } else if (jsonInteger(root.get("nodeCount"))) |present| {
        mode = "nodes";
        min = present;
        max = present;
    } else {
        max = jsonInteger(root.get("processingUnits")) orelse 0;
        min = max;
    }
    const fields = [_]value.Field{
        .{ .name = "capacity_max", .value = .{ .integer = max } },
        .{ .name = "capacity_min", .value = .{ .integer = min } },
        .{ .name = "capacity_mode", .value = .{ .string = mode } },
        .{ .name = "config", .value = .{ .string = config } },
        .{ .name = "cpu_target", .value = .{ .integer = cpu } },
        .{ .name = "default_backup_schedule", .value = .{ .string = jsonString(root.get("defaultBackupScheduleType")) orelse "NONE" } },
        .{ .name = "display_name", .value = .{ .string = jsonString(root.get("displayName")) orelse "" } },
        .{ .name = "edition", .value = .{ .string = jsonString(root.get("edition")) orelse "STANDARD" } },
        .{ .name = "instance_id", .value = try requiredValue(node.inputs, "instance_id") },
        .{ .name = "labels", .value = .{ .string = labels } },
        .{ .name = "project_id", .value = try requiredValue(node.inputs, "project_id") },
        .{ .name = "storage_target", .value = .{ .integer = storage } },
    };
    return ownedObject(context.allocator, &fields);
}

fn normalizedDatabase(context: *provider_mod.OperationContext, node: resource.ResourceNode, root: std.json.ObjectMap, ddl: []const u8) ProviderError!value.Value {
    const encryption = if (root.get("encryptionConfig")) |candidate| blk: {
        const object = jsonObject(candidate) orelse return error.ProviderBug;
        const keys = object.get("kmsKeyNames") orelse break :blk "";
        if (keys != .array or keys.array.items.len == 0) break :blk "";
        break :blk jsonString(keys.array.items[0]) orelse "";
    } else "";
    const fields = [_]value.Field{
        .{ .name = "database_id", .value = try requiredValue(node.inputs, "database_id") },
        .{ .name = "ddl_json", .value = .{ .string = ddl } },
        .{ .name = "default_leader", .value = .{ .string = jsonString(root.get("defaultLeader")) orelse "" } },
        .{ .name = "dialect", .value = .{ .string = jsonString(root.get("databaseDialect")) orelse "GOOGLE_STANDARD_SQL" } },
        .{ .name = "drop_protection", .value = .{ .boolean = jsonBool(root.get("enableDropProtection")) orelse false } },
        .{ .name = "instance", .value = try requiredValue(node.inputs, "instance") },
        .{ .name = "instance_id", .value = try requiredValue(node.inputs, "instance_id") },
        .{ .name = "kms_key_name", .value = .{ .string = encryption } },
        .{ .name = "project_id", .value = try requiredValue(node.inputs, "project_id") },
        .{ .name = "version_retention_period", .value = .{ .string = jsonString(root.get("versionRetentionPeriod")) orelse "1h" } },
    };
    return ownedObject(context.allocator, &fields);
}

fn normalizedBackup(context: *provider_mod.OperationContext, node: resource.ResourceNode, root: std.json.ObjectMap) ProviderError!value.Value {
    const fields = [_]value.Field{
        .{ .name = "backup_id", .value = try requiredValue(node.inputs, "backup_id") },
        .{ .name = "database", .value = .{ .string = jsonString(root.get("database")) orelse return error.ProviderBug } },
        .{ .name = "database_id", .value = try requiredValue(node.inputs, "database_id") },
        .{ .name = "expire_time", .value = .{ .string = jsonString(root.get("expireTime")) orelse return error.ProviderBug } },
        .{ .name = "instance_id", .value = try requiredValue(node.inputs, "instance_id") },
        .{ .name = "kms_key_name", .value = .{ .string = backupKmsKey(root) } },
        .{ .name = "project_id", .value = try requiredValue(node.inputs, "project_id") },
        .{ .name = "version_time", .value = .{ .string = jsonString(root.get("versionTime")) orelse "" } },
    };
    return ownedObject(context.allocator, &fields);
}

fn normalizedSchedule(context: *provider_mod.OperationContext, node: resource.ResourceNode, root: std.json.ObjectMap) ProviderError!value.Value {
    const spec = jsonObject(root.get("spec") orelse return error.ProviderBug) orelse return error.ProviderBug;
    const cron = jsonObject(spec.get("cronSpec") orelse return error.ProviderBug) orelse return error.ProviderBug;
    const retention = durationSeconds(jsonString(root.get("retentionDuration")) orelse return error.ProviderBug) orelse return error.ProviderBug;
    const fields = [_]value.Field{
        .{ .name = "cron", .value = .{ .string = jsonString(cron.get("text")) orelse return error.ProviderBug } },
        .{ .name = "database", .value = try requiredValue(node.inputs, "database") },
        .{ .name = "database_id", .value = try requiredValue(node.inputs, "database_id") },
        .{ .name = "instance_id", .value = try requiredValue(node.inputs, "instance_id") },
        .{ .name = "kms_key_name", .value = .{ .string = backupScheduleKmsKey(root) } },
        .{ .name = "mode", .value = .{ .string = if (root.get("incrementalBackupSpec") != null) "incremental" else "full" } },
        .{ .name = "project_id", .value = try requiredValue(node.inputs, "project_id") },
        .{ .name = "retention_seconds", .value = .{ .integer = retention } },
        .{ .name = "schedule_id", .value = try requiredValue(node.inputs, "schedule_id") },
    };
    return ownedObject(context.allocator, &fields);
}

fn updateMaskAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, observed: value.Value, kind: Kind) ProviderError![]const u8 {
    if (kind == .instance) {
        var mask: std.ArrayList(u8) = .empty;
        defer mask.deinit(allocator);
        if (changedAny(node.inputs, observed, &.{ "capacity_mode", "capacity_min", "capacity_max", "cpu_target", "storage_target" })) try appendMask(&mask, allocator, "autoscalingConfig");
        if (changedField(node.inputs, observed, "display_name")) try appendMask(&mask, allocator, "displayName");
        if (changedField(node.inputs, observed, "labels")) try appendMask(&mask, allocator, "labels");
        if (changedField(node.inputs, observed, "edition")) try appendMask(&mask, allocator, "edition");
        if (changedField(node.inputs, observed, "default_backup_schedule")) try appendMask(&mask, allocator, "defaultBackupScheduleType");
        return mask.toOwnedSlice(allocator);
    }
    return allocator.dupe(u8, switch (kind) {
        .database => "enableDropProtection",
        .backup => "expireTime",
        .schedule => "spec,retentionDuration,fullBackupSpec,incrementalBackupSpec,encryptionConfig",
        .instance => unreachable,
    }) catch error.OutOfMemory;
}

fn backupKmsKey(root: std.json.ObjectMap) []const u8 {
    const version = blk: {
        if (root.get("encryptionInformation")) |information| {
            if (information == .array and information.array.items.len > 0) {
                const first = jsonObject(information.array.items[0]) orelse break :blk "";
                break :blk jsonString(first.get("kmsKeyVersion")) orelse "";
            }
        }
        const info = jsonObject(root.get("encryptionInfo") orelse break :blk "") orelse break :blk "";
        break :blk jsonString(info.get("kmsKeyVersion")) orelse "";
    };
    const suffix = std.mem.lastIndexOf(u8, version, "/cryptoKeyVersions/") orelse return "";
    return version[0..suffix];
}

fn backupScheduleKmsKey(root: std.json.ObjectMap) []const u8 {
    const encryption = jsonObject(root.get("encryptionConfig") orelse return "") orelse return "";
    const keys = encryption.get("kmsKeyNames") orelse return "";
    if (keys != .array or keys.array.items.len == 0) return "";
    return jsonString(keys.array.items[0]) orelse "";
}

fn percentEncodeAlloc(allocator: std.mem.Allocator, input: []const u8) ProviderError![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const digits = "0123456789ABCDEF";
    for (input) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try output.append(allocator, byte);
        } else {
            try output.appendSlice(allocator, &.{ '%', digits[byte >> 4], digits[byte & 0x0f] });
        }
    }
    return output.toOwnedSlice(allocator) catch error.OutOfMemory;
}

fn pendingResult(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, handle: []const u8) ProviderError!provider_mod.ResourceResult {
    const physical = try deterministicPhysicalAlloc(context.allocator, node, kind);
    defer context.allocator.free(physical);
    var observed = value.Value.initOwned(context.allocator, node.inputs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DuplicateField => return error.ProviderBug,
    };
    defer observed.deinit(context.allocator);
    var result = try provider_mod.ResourceResult.init(context.allocator, physical, observed, &.{}, handle);
    result.completed = false;
    return result;
}

fn operationNameAlloc(allocator: std.mem.Allocator, body: []const u8) ProviderError![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    return allocator.dupe(u8, jsonString((jsonObject(parsed.value) orelse return error.ProviderBug).get("name")) orelse return error.ProviderBug) catch error.OutOfMemory;
}

fn parseStringArray(allocator: std.mem.Allocator, json: []const u8) ProviderError!std.json.Array {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{}) catch return error.InvalidConfiguration;
    if (parsed != .array) return error.InvalidConfiguration;
    return parsed.array;
}

fn keyValuesObject(allocator: std.mem.Allocator, text: []const u8) ProviderError!std.json.ObjectMap {
    var object: std.json.ObjectMap = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfiguration;
        try object.put(allocator, line[0..separator], .{ .string = line[separator + 1 ..] });
    }
    return object;
}

fn jsonMapTextAlloc(allocator: std.mem.Allocator, candidate: ?std.json.Value) ProviderError![]const u8 {
    const object = if (candidate) |present| jsonObject(present) orelse return error.ProviderBug else std.json.ObjectMap.empty;
    const entries = try allocator.alloc(struct { key: []const u8, value: []const u8 }, object.count());
    defer allocator.free(entries);
    var iterator = object.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| : (index += 1) entries[index] = .{ .key = entry.key_ptr.*, .value = jsonString(entry.value_ptr.*) orelse return error.ProviderBug };
    std.mem.sort(@TypeOf(entries[0]), entries, {}, struct {
        fn lessThan(_: void, left: @TypeOf(entries[0]), right: @TypeOf(entries[0])) bool {
            return std.mem.order(u8, left.key, right.key) == .lt;
        }
    }.lessThan);
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    for (entries, 0..) |entry, entry_index| {
        if (entry_index > 0) try result.append(allocator, '\n');
        try result.appendSlice(allocator, entry.key);
        try result.append(allocator, '=');
        try result.appendSlice(allocator, entry.value);
    }
    return result.toOwnedSlice(allocator);
}

fn changedAny(desired: value.Value, observed: value.Value, names: []const []const u8) bool {
    for (names) |name| if (changedField(desired, observed, name)) return true;
    return false;
}

fn changedField(desired: value.Value, observed: value.Value, name: []const u8) bool {
    const left = findValue(desired, name) orelse return true;
    const right = findValue(observed, name) orelse return true;
    return !valueEqual(left, right);
}

fn valueEqual(left: value.Value, right: value.Value) bool {
    return switch (left) {
        .string => |text| right == .string and std.mem.eql(u8, text, right.string),
        .integer => |number| right == .integer and number == right.integer,
        .boolean => |present| right == .boolean and present == right.boolean,
        .output_ref => |reference| right == .output_ref and std.mem.eql(u8, reference.resource_id, right.output_ref.resource_id) and std.mem.eql(u8, reference.field, right.output_ref.field),
        else => false,
    };
}

fn appendMask(mask: *std.ArrayList(u8), allocator: std.mem.Allocator, field: []const u8) ProviderError!void {
    if (mask.items.len > 0) try mask.append(allocator, ',');
    try mask.appendSlice(allocator, field);
}

fn ownedObject(allocator: std.mem.Allocator, fields: []const value.Field) ProviderError!value.Value {
    return value.Value.initOwned(allocator, .{ .object = fields }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateField => error.ProviderBug,
    };
}

fn outputOrString(inputs: value.Value, name: []const u8) ProviderError!std.json.Value {
    return switch (findValue(inputs, name) orelse return error.InvalidConfiguration) {
        .string => |text| .{ .string = text },
        else => return error.InvalidConfiguration,
    };
}

fn requiredValue(inputs: value.Value, name: []const u8) ProviderError!value.Value {
    return findValue(inputs, name) orelse error.InvalidConfiguration;
}
fn requiredString(inputs: value.Value, name: []const u8) ProviderError![]const u8 {
    return switch (try requiredValue(inputs, name)) {
        .string => |text| text,
        else => error.InvalidConfiguration,
    };
}
fn requiredInteger(inputs: value.Value, name: []const u8) ProviderError!i64 {
    return switch (try requiredValue(inputs, name)) {
        .integer => |number| number,
        else => error.InvalidConfiguration,
    };
}
fn requiredBool(inputs: value.Value, name: []const u8) ProviderError!bool {
    return switch (try requiredValue(inputs, name)) {
        .boolean => |present| present,
        else => error.InvalidConfiguration,
    };
}
fn findValue(inputs: value.Value, name: []const u8) ?value.Value {
    if (inputs != .object) return null;
    for (inputs.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return null;
}

fn jsonObject(candidate: std.json.Value) ?std.json.ObjectMap {
    return switch (candidate) {
        .object => |object| object,
        else => null,
    };
}
fn jsonString(candidate: ?std.json.Value) ?[]const u8 {
    const present = candidate orelse return null;
    return switch (present) {
        .string => |text| text,
        else => null,
    };
}
fn jsonBool(candidate: ?std.json.Value) ?bool {
    const present = candidate orelse return null;
    return switch (present) {
        .bool => |value_bool| value_bool,
        else => null,
    };
}
fn jsonInteger(candidate: ?std.json.Value) ?i64 {
    const present = candidate orelse return null;
    return switch (present) {
        .integer => |number| number,
        else => null,
    };
}
fn jsonIntegerString(candidate: ?std.json.Value) i64 {
    const text = jsonString(candidate) orelse return 0;
    return std.fmt.parseInt(i64, text, 10) catch 0;
}
fn lastSegment(text: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, text, '/')) |index| text[index + 1 ..] else text;
}
fn durationSeconds(text: []const u8) ?i64 {
    if (text.len < 2 or text[text.len - 1] != 's') return null;
    return std.fmt.parseInt(i64, text[0 .. text.len - 1], 10) catch null;
}
