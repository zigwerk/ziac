const std = @import("std");
const local_state = @import("local_state.zig");
const plan_mod = @import("plan.zig");
const resource = @import("resource.zig");
const value_mod = @import("value.zig");

pub const schema = "ziac.saved-plan.v1";
pub const format_version: u32 = 1;
pub const default_max_bytes: usize = 64 * 1024 * 1024;

pub const Target = struct {
    stack: []const u8,
    stage: []const u8,
    created_at_millis: u64,
};

pub const LoadOptions = struct {
    max_bytes: usize = default_max_bytes,
};

pub const Metadata = struct {
    digest: [32]u8,
    approval_required: bool,

    pub fn digestHex(self: Metadata) [64]u8 {
        return std.fmt.bytesToHex(self.digest, .lower);
    }
};

pub const SerializedPlan = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    digest: [32]u8,
    approval_required: bool,

    pub fn deinit(self: *SerializedPlan) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn metadata(self: SerializedPlan) Metadata {
        return .{ .digest = self.digest, .approval_required = self.approval_required };
    }
};

pub const LoadedPlan = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    stack: []const u8,
    stage: []const u8,
    created_at_millis: u64,
    digest: [32]u8,
    approval_required: bool,
    plan: plan_mod.Plan,

    pub fn deinit(self: *LoadedPlan) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.* = undefined;
    }

    pub fn metadata(self: LoadedPlan) Metadata {
        return .{ .digest = self.digest, .approval_required = self.approval_required };
    }
};

pub fn serializeAlloc(
    allocator: std.mem.Allocator,
    planned: *const plan_mod.Plan,
    target: Target,
) !SerializedPlan {
    try validateTarget(target.stack);
    try validateTarget(target.stage);
    try validatePlanIntegrity(allocator, planned);
    const approval_required = requiresApproval(planned.operations);
    const digest = try planDigestAlloc(allocator, target, planned.preconditions, approval_required);

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.append(allocator, '{');
    try appendNamedString(&output, allocator, "schema", schema, false);
    try appendNamedUnsigned(&output, allocator, "format_version", format_version, true);
    try appendNamedUnsigned(&output, allocator, "created_at_millis", target.created_at_millis, true);
    try appendNamedString(&output, allocator, "stack", target.stack, true);
    try appendNamedString(&output, allocator, "stage", target.stage, true);
    try appendNamedHash(&output, allocator, "plan_digest", digest, true);
    try appendNamedBool(&output, allocator, "approval_required", approval_required, true);
    try output.appendSlice(allocator, ",\"preconditions\":");
    try appendPreconditions(&output, allocator, planned.preconditions);
    try output.appendSlice(allocator, ",\"operations\":[");
    for (planned.operations, 0..) |operation, index| {
        if (index != 0) try output.append(allocator, ',');
        try appendOperation(&output, allocator, operation);
    }
    try output.appendSlice(allocator, "]}");
    return .{
        .allocator = allocator,
        .bytes = try output.toOwnedSlice(allocator),
        .digest = digest,
        .approval_required = approval_required,
    };
}

pub fn parseAlloc(allocator: std.mem.Allocator, bytes: []const u8) !LoadedPlan {
    if (bytes.len > default_max_bytes) return error.PlanTooLarge;
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    var parsed = std.json.parseFromSlice(std.json.Value, arena_allocator, bytes, .{}) catch return error.InvalidPlanFile;
    defer parsed.deinit();
    const root = valueObject(parsed.value) catch return error.InvalidPlanFile;
    if (root.count() != 9) return error.InvalidPlanFile;
    if (!std.mem.eql(u8, jsonString(root, "schema") catch return error.InvalidPlanFile, schema)) {
        return error.InvalidPlanFile;
    }
    const version = jsonU32(root, "format_version") catch return error.InvalidPlanFile;
    if (version != format_version) return error.UnsupportedPlanVersion;
    const created_at_millis = jsonU64(root, "created_at_millis") catch return error.InvalidPlanFile;
    const stack = jsonString(root, "stack") catch return error.InvalidPlanFile;
    const stage = jsonString(root, "stage") catch return error.InvalidPlanFile;
    validateTarget(stack) catch return error.InvalidPlanTarget;
    validateTarget(stage) catch return error.InvalidPlanTarget;
    const stored_digest = parseHash(jsonString(root, "plan_digest") catch return error.InvalidPlanFile) catch return error.InvalidPlanFile;
    const stored_approval = jsonBool(root, "approval_required") catch return error.InvalidPlanFile;
    const preconditions = parsePreconditions(root.get("preconditions") orelse return error.InvalidPlanFile) catch return error.InvalidPlanFile;
    const operation_values = valueArray(root.get("operations") orelse return error.InvalidPlanFile) catch return error.InvalidPlanFile;
    const operations = try arena_allocator.alloc(plan_mod.PlanOperation, operation_values.len);
    for (operation_values, 0..) |operation_value, index| {
        operations[index] = parseOperation(arena_allocator, operation_value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.PlanIntegrityMismatch => return error.PlanIntegrityMismatch,
            else => return error.InvalidPlanFile,
        };
    }

    const actual_operations_digest = try plan_mod.operationsDigestAlloc(allocator, operations);
    if (!std.mem.eql(u8, &actual_operations_digest, &preconditions.operations_digest)) {
        return error.PlanIntegrityMismatch;
    }
    const approval_required = requiresApproval(operations);
    if (approval_required != stored_approval) return error.PlanIntegrityMismatch;
    const actual_digest = try planDigestAlloc(allocator, .{
        .stack = stack,
        .stage = stage,
        .created_at_millis = created_at_millis,
    }, preconditions, approval_required);
    if (!std.mem.eql(u8, &actual_digest, &stored_digest)) return error.PlanIntegrityMismatch;

    return .{
        .allocator = allocator,
        .arena = arena,
        .stack = stack,
        .stage = stage,
        .created_at_millis = created_at_millis,
        .digest = actual_digest,
        .approval_required = approval_required,
        .plan = .{
            .allocator = arena_allocator,
            .operations = operations,
            .preconditions = preconditions,
        },
    };
}

pub fn save(
    files: local_state.FileStore,
    allocator: std.mem.Allocator,
    path: []const u8,
    planned: *const plan_mod.Plan,
    target: Target,
) !Metadata {
    try validatePath(path);
    var serialized = try serializeAlloc(allocator, planned, target);
    defer serialized.deinit();
    files.createExclusiveFile(path, serialized.bytes) catch |err| switch (err) {
        error.PathAlreadyExists, error.FileAlreadyExists => return error.PlanAlreadyExists,
        else => return err,
    };
    return serialized.metadata();
}

pub fn load(
    files: local_state.FileStore,
    allocator: std.mem.Allocator,
    path: []const u8,
    options: LoadOptions,
) !LoadedPlan {
    try validatePath(path);
    if (options.max_bytes == 0) return error.InvalidPlanLimit;
    const bytes = files.readFileAllocBounded(allocator, path, options.max_bytes) catch |err| switch (err) {
        error.StreamTooLong => return error.PlanTooLarge,
        else => return err,
    };
    defer allocator.free(bytes);
    return parseAlloc(allocator, bytes);
}

pub fn requiresApproval(operations: []const plan_mod.PlanOperation) bool {
    return plan_mod.hasDestructiveOperations(operations);
}

pub fn planDigestAlloc(
    allocator: std.mem.Allocator,
    target: Target,
    preconditions: plan_mod.PlanPreconditions,
    approval_required: bool,
) std.mem.Allocator.Error![32]u8 {
    var transcript = std.ArrayList(u8).empty;
    defer transcript.deinit(allocator);
    try appendFramed(&transcript, allocator, schema);
    try transcript.print(allocator, "{d}:", .{format_version});
    try transcript.print(allocator, "{d}:", .{target.created_at_millis});
    try appendFramed(&transcript, allocator, target.stack);
    try appendFramed(&transcript, allocator, target.stage);
    try transcript.appendSlice(allocator, &preconditions.lineage_hash);
    try transcript.print(allocator, "{d}:", .{preconditions.state_serial});
    try transcript.appendSlice(allocator, &preconditions.desired_graph_digest);
    try transcript.appendSlice(allocator, &preconditions.operations_digest);
    try transcript.append(allocator, @intFromBool(approval_required));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(transcript.items, &digest, .{});
    return digest;
}

fn validatePlanIntegrity(allocator: std.mem.Allocator, planned: *const plan_mod.Plan) !void {
    for (planned.operations) |operation| {
        if (operation.kind == .delete) continue;
        const actual = operation.resource.inputs.sha256(allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateField => return error.PlanIntegrityMismatch,
        };
        if (!std.mem.eql(u8, &actual, &operation.resource.inputs_hash)) return error.PlanIntegrityMismatch;
    }
    const actual = try plan_mod.operationsDigestAlloc(allocator, planned.operations);
    if (!std.mem.eql(u8, &actual, &planned.preconditions.operations_digest)) return error.PlanIntegrityMismatch;
}

fn appendPreconditions(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    preconditions: plan_mod.PlanPreconditions,
) !void {
    try output.append(allocator, '{');
    try appendNamedHash(output, allocator, "lineage_hash", preconditions.lineage_hash, false);
    try appendNamedUnsigned(output, allocator, "state_serial", preconditions.state_serial, true);
    try appendNamedHash(output, allocator, "desired_graph_digest", preconditions.desired_graph_digest, true);
    try appendNamedHash(output, allocator, "operations_digest", preconditions.operations_digest, true);
    try output.append(allocator, '}');
}

fn appendOperation(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    operation: plan_mod.PlanOperation,
) !void {
    try output.append(allocator, '{');
    try appendNamedString(output, allocator, "kind", @tagName(operation.kind), false);
    try output.appendSlice(allocator, ",\"resource\":");
    try appendResource(output, allocator, operation.resource);
    try output.appendSlice(allocator, ",\"dependencies\":");
    try appendStringArray(output, allocator, operation.dependencies, false);
    try output.appendSlice(allocator, ",\"reasons\":");
    try appendStringArray(output, allocator, operation.reasons, false);
    try output.append(allocator, '}');
}

fn appendResource(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
) !void {
    try output.append(allocator, '{');
    try appendNamedString(output, allocator, "id", node.id, false);
    try appendNamedString(output, allocator, "provider", @tagName(node.provider), true);
    try appendNamedString(output, allocator, "type_name", node.type_name, true);
    try appendNamedUnsigned(output, allocator, "schema_version", node.schema_version, true);
    try appendNamedString(output, allocator, "logical_id", node.logical_id, true);
    try output.appendSlice(allocator, ",\"inputs\":");
    const inputs = try node.inputs.canonicalJsonAlloc(allocator);
    defer allocator.free(inputs);
    try output.appendSlice(allocator, inputs);
    try appendNamedHash(output, allocator, "inputs_hash", node.inputs_hash, true);
    try output.appendSlice(allocator, ",\"lifecycle\":");
    try appendLifecycle(output, allocator, node.lifecycle);
    try output.append(allocator, '}');
}

fn appendLifecycle(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    lifecycle: resource.Lifecycle,
) !void {
    try output.append(allocator, '{');
    try appendNamedBool(output, allocator, "protect", lifecycle.protect, false);
    try appendNamedBool(output, allocator, "retain_on_delete", lifecycle.retain_on_delete, true);
    try appendNamedBool(output, allocator, "replace_before_delete", lifecycle.replace_before_delete, true);
    try output.appendSlice(allocator, ",\"ignore_changes\":");
    try appendStringArray(output, allocator, lifecycle.ignore_changes, true);
    try appendNamedUnsigned(output, allocator, "operation_timeout_millis", lifecycle.operation_timeout_millis, true);
    try output.append(allocator, '}');
}

fn parsePreconditions(source: std.json.Value) !plan_mod.PlanPreconditions {
    const object = try valueObject(source);
    if (object.count() != 4) return error.InvalidPlanFile;
    return .{
        .lineage_hash = try parseHash(try jsonString(object, "lineage_hash")),
        .state_serial = try jsonU64(object, "state_serial"),
        .desired_graph_digest = try parseHash(try jsonString(object, "desired_graph_digest")),
        .operations_digest = try parseHash(try jsonString(object, "operations_digest")),
    };
}

fn parseOperation(allocator: std.mem.Allocator, source: std.json.Value) !plan_mod.PlanOperation {
    const object = try valueObject(source);
    if (object.count() != 4) return error.InvalidPlanFile;
    const kind = try parseOperationKind(try jsonString(object, "kind"));
    return .{
        .kind = kind,
        .resource = try parseResource(allocator, kind, object.get("resource") orelse return error.InvalidPlanFile),
        .dependencies = try parseStringArray(allocator, object.get("dependencies") orelse return error.InvalidPlanFile),
        .reasons = try parseStringArray(allocator, object.get("reasons") orelse return error.InvalidPlanFile),
    };
}

fn parseResource(
    allocator: std.mem.Allocator,
    kind: plan_mod.OperationKind,
    source: std.json.Value,
) !resource.ResourceNode {
    const object = try valueObject(source);
    if (object.count() != 8) return error.InvalidPlanFile;
    const inputs = value_mod.Value.fromJsonValueAlloc(allocator, object.get("inputs") orelse return error.InvalidPlanFile) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPlanFile,
    };
    const inputs_hash = try parseHash(try jsonString(object, "inputs_hash"));
    const actual_hash = inputs.sha256(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DuplicateField => return error.InvalidPlanFile,
    };
    if (kind != .delete and !std.mem.eql(u8, &actual_hash, &inputs_hash)) return error.PlanIntegrityMismatch;
    return .{
        .id = try nonEmptyString(object, "id"),
        .provider = try parseProvider(try jsonString(object, "provider")),
        .type_name = try nonEmptyString(object, "type_name"),
        .schema_version = try jsonU32(object, "schema_version"),
        .logical_id = try nonEmptyString(object, "logical_id"),
        .inputs = inputs,
        .inputs_hash = inputs_hash,
        .lifecycle = try parseLifecycle(allocator, object.get("lifecycle") orelse return error.InvalidPlanFile),
    };
}

fn parseLifecycle(allocator: std.mem.Allocator, source: std.json.Value) !resource.Lifecycle {
    const object = try valueObject(source);
    if (object.count() != 5) return error.InvalidPlanFile;
    const timeout = try jsonU64(object, "operation_timeout_millis");
    if (timeout == 0) return error.InvalidPlanFile;
    return .{
        .protect = try jsonBool(object, "protect"),
        .retain_on_delete = try jsonBool(object, "retain_on_delete"),
        .replace_before_delete = try jsonBool(object, "replace_before_delete"),
        .ignore_changes = try parseStringArray(allocator, object.get("ignore_changes") orelse return error.InvalidPlanFile),
        .operation_timeout_millis = timeout,
    };
}

fn parseStringArray(allocator: std.mem.Allocator, source: std.json.Value) ![]const []const u8 {
    const values = try valueArray(source);
    const strings = try allocator.alloc([]const u8, values.len);
    for (values, 0..) |value, index| {
        strings[index] = switch (value) {
            .string => |text| text,
            else => return error.InvalidPlanFile,
        };
    }
    return strings;
}

fn parseProvider(name: []const u8) !resource.ProviderId {
    inline for (@typeInfo(resource.ProviderId).@"enum".fields) |field| {
        if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
    }
    return error.InvalidPlanFile;
}

fn parseOperationKind(name: []const u8) !plan_mod.OperationKind {
    inline for (@typeInfo(plan_mod.OperationKind).@"enum".fields) |field| {
        if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
    }
    return error.InvalidPlanFile;
}

fn appendStringArray(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    values: []const []const u8,
    sort_values: bool,
) !void {
    var owned: ?[][]const u8 = null;
    defer if (owned) |items| allocator.free(items);
    var ordered = values;
    if (sort_values) {
        const items = try allocator.dupe([]const u8, values);
        std.mem.sort([]const u8, items, {}, lessThanString);
        owned = items;
        ordered = items;
    }
    try output.append(allocator, '[');
    for (ordered, 0..) |value, index| {
        if (index != 0) try output.append(allocator, ',');
        try appendJsonString(output, allocator, value);
    }
    try output.append(allocator, ']');
}

fn appendNamedString(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    value: []const u8,
    comma: bool,
) !void {
    if (comma) try output.append(allocator, ',');
    try appendJsonString(output, allocator, name);
    try output.append(allocator, ':');
    try appendJsonString(output, allocator, value);
}

fn appendNamedUnsigned(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    value: anytype,
    comma: bool,
) !void {
    if (comma) try output.append(allocator, ',');
    try appendJsonString(output, allocator, name);
    try output.print(allocator, ":{d}", .{value});
}

fn appendNamedBool(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    value: bool,
    comma: bool,
) !void {
    if (comma) try output.append(allocator, ',');
    try appendJsonString(output, allocator, name);
    try output.appendSlice(allocator, if (value) ":true" else ":false");
}

fn appendNamedHash(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    hash: [32]u8,
    comma: bool,
) !void {
    const encoded = std.fmt.bytesToHex(hash, .lower);
    try appendNamedString(output, allocator, name, &encoded, comma);
}

fn appendJsonString(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(encoded);
    try output.appendSlice(allocator, encoded);
}

fn appendFramed(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try output.print(allocator, "{d}:", .{value.len});
    try output.appendSlice(allocator, value);
}

fn parseHash(text: []const u8) ![32]u8 {
    if (text.len != 64) return error.InvalidPlanFile;
    var result: [32]u8 = undefined;
    for (result[0..], 0..) |*byte, index| {
        const high = try lowerHexNibble(text[index * 2]);
        const low = try lowerHexNibble(text[index * 2 + 1]);
        byte.* = (high << 4) | low;
    }
    return result;
}

fn lowerHexNibble(character: u8) !u8 {
    return switch (character) {
        '0'...'9' => character - '0',
        'a'...'f' => character - 'a' + 10,
        else => error.InvalidPlanFile,
    };
}

fn valueObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.InvalidPlanFile,
    };
}

fn valueArray(value: std.json.Value) ![]const std.json.Value {
    return switch (value) {
        .array => |array| array.items,
        else => error.InvalidPlanFile,
    };
}

fn jsonString(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return switch (object.get(name) orelse return error.InvalidPlanFile) {
        .string => |value| value,
        else => error.InvalidPlanFile,
    };
}

fn nonEmptyString(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = try jsonString(object, name);
    if (value.len == 0 or value.len > 1024) return error.InvalidPlanFile;
    return value;
}

fn jsonBool(object: std.json.ObjectMap, name: []const u8) !bool {
    return switch (object.get(name) orelse return error.InvalidPlanFile) {
        .bool => |value| value,
        else => error.InvalidPlanFile,
    };
}

fn jsonU32(object: std.json.ObjectMap, name: []const u8) !u32 {
    const value = try jsonU64(object, name);
    return std.math.cast(u32, value) orelse error.InvalidPlanFile;
}

fn jsonU64(object: std.json.ObjectMap, name: []const u8) !u64 {
    return switch (object.get(name) orelse return error.InvalidPlanFile) {
        .integer => |value| if (value >= 0) @intCast(value) else error.InvalidPlanFile,
        else => error.InvalidPlanFile,
    };
}

fn validateTarget(value: []const u8) !void {
    if (value.len == 0 or value.len > 128 or std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) {
        return error.InvalidPlanTarget;
    }
    for (value) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '-' and character != '_') {
            return error.InvalidPlanTarget;
        }
    }
}

fn validatePath(path: []const u8) !void {
    if (path.len == 0 or path.len > 4096 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPlanPath;
}

fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
