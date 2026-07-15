const std = @import("std");
const output_mod = @import("output.zig");
const resource = @import("resource.zig");
const stack_registry = @import("stack_registry.zig");
const value_mod = @import("value.zig");

pub const schema = "ziac.program.v1";

pub const Target = struct {
    stack: []const u8,
    stage: []const u8,
};

pub const Error = std.mem.Allocator.Error || resource.ResourceGraphError || error{
    InvalidProgramArtifact,
    UnsupportedProgramSchema,
    ProgramIntegrityMismatch,
    ProgramTargetMismatch,
    SecretMaterialDetected,
};

pub fn encodeAlloc(
    allocator: std.mem.Allocator,
    stack: []const u8,
    stage: []const u8,
    program: *const stack_registry.StackProgram,
) Error![]u8 {
    const payload = try encodePayloadAlloc(allocator, stack, stage, program);
    defer allocator.free(payload);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, "{\"schema\":");
    try appendJsonString(&result, allocator, schema);
    try result.appendSlice(allocator, ",\"digest\":");
    try appendJsonString(&result, allocator, &hex);
    try result.appendSlice(allocator, ",\"program\":");
    try result.appendSlice(allocator, payload);
    try result.append(allocator, '}');
    return result.toOwnedSlice(allocator);
}

pub fn decodeAlloc(allocator: std.mem.Allocator, bytes: []const u8, target: Target) Error!stack_registry.StackProgram {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return error.InvalidProgramArtifact;
    defer parsed.deinit();
    const root = asObject(parsed.value) orelse return error.InvalidProgramArtifact;
    if (!std.mem.eql(u8, try stringField(root, "schema"), schema)) return error.UnsupportedProgramSchema;
    const digest_text = try stringField(root, "digest");
    if (digest_text.len != 64) return error.InvalidProgramArtifact;
    const payload = root.get("program") orelse return error.InvalidProgramArtifact;
    const payload_object = asObject(payload) orelse return error.InvalidProgramArtifact;
    const stack = try stringField(payload_object, "stack");
    const stage = try stringField(payload_object, "stage");
    if (!std.mem.eql(u8, stack, target.stack) or !std.mem.eql(u8, stage, target.stage)) return error.ProgramTargetMismatch;

    var program = try parseProgram(allocator, payload_object);
    errdefer program.deinit();
    const canonical = try encodePayloadAlloc(allocator, stack, stage, &program);
    defer allocator.free(canonical);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &actual, digest_text)) return error.ProgramIntegrityMismatch;
    return program;
}

fn encodePayloadAlloc(
    allocator: std.mem.Allocator,
    stack: []const u8,
    stage: []const u8,
    program: *const stack_registry.StackProgram,
) Error![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, "{\"stack\":");
    try appendJsonString(&result, allocator, stack);
    try result.appendSlice(allocator, ",\"stage\":");
    try appendJsonString(&result, allocator, stage);
    try result.appendSlice(allocator, ",\"resources\":[");
    for (program.graph.resources.items, 0..) |node, index| {
        if (index != 0) try result.append(allocator, ',');
        try appendResource(&result, allocator, node);
    }
    try result.appendSlice(allocator, "],\"dependencies\":[");
    const dependencies = try allocator.dupe(resource.DependencyEdge, program.graph.dependencies.items);
    defer allocator.free(dependencies);
    std.mem.sort(resource.DependencyEdge, dependencies, {}, dependencyLessThan);
    for (dependencies, 0..) |edge, index| {
        if (index != 0) try result.append(allocator, ',');
        try result.appendSlice(allocator, "{\"from\":");
        try appendJsonString(&result, allocator, edge.from);
        try result.appendSlice(allocator, ",\"to\":");
        try appendJsonString(&result, allocator, edge.to);
        try result.append(allocator, '}');
    }
    try result.appendSlice(allocator, "],\"outputs\":[");
    for (program.outputs.items, 0..) |definition, index| {
        if (index != 0) try result.append(allocator, ',');
        try appendOutput(&result, allocator, definition);
    }
    try result.appendSlice(allocator, "]}");
    return result.toOwnedSlice(allocator);
}

fn dependencyLessThan(_: void, left: resource.DependencyEdge, right: resource.DependencyEdge) bool {
    const from_order = std.mem.order(u8, left.from, right.from);
    if (from_order == .lt) return true;
    if (from_order == .gt) return false;
    return std.mem.lessThan(u8, left.to, right.to);
}

fn appendResource(result: *std.ArrayList(u8), allocator: std.mem.Allocator, node: resource.ResourceNode) Error!void {
    if (containsSecretLiteral(node.inputs, null)) return error.SecretMaterialDetected;
    try result.appendSlice(allocator, "{\"id\":");
    try appendJsonString(result, allocator, node.id);
    try result.appendSlice(allocator, ",\"provider\":");
    try appendJsonString(result, allocator, @tagName(node.provider));
    try result.appendSlice(allocator, ",\"type_name\":");
    try appendJsonString(result, allocator, node.type_name);
    try result.print(allocator, ",\"schema_version\":{d},\"logical_id\":", .{node.schema_version});
    try appendJsonString(result, allocator, node.logical_id);
    if (node.component) |origin| {
        try result.appendSlice(allocator, ",\"component\":{\"package\":");
        try appendJsonString(result, allocator, origin.package);
        try result.appendSlice(allocator, ",\"name\":");
        try appendJsonString(result, allocator, origin.name);
        try result.appendSlice(allocator, ",\"version\":");
        try appendJsonString(result, allocator, origin.version);
        try result.appendSlice(allocator, ",\"instance\":");
        try appendJsonString(result, allocator, origin.instance);
        try result.appendSlice(allocator, ",\"source_digest\":");
        try appendJsonString(result, allocator, origin.source_digest);
        try result.append(allocator, '}');
    }
    try result.appendSlice(allocator, ",\"inputs\":");
    const inputs = try node.inputs.canonicalJsonAlloc(allocator);
    defer allocator.free(inputs);
    try result.appendSlice(allocator, inputs);
    try result.appendSlice(allocator, ",\"lifecycle\":{");
    try result.print(allocator, "\"protect\":{},\"retain_on_delete\":{},\"replace_before_delete\":{},\"ignore_changes\":[", .{
        node.lifecycle.protect,
        node.lifecycle.retain_on_delete,
        node.lifecycle.replace_before_delete,
    });
    for (node.lifecycle.ignore_changes, 0..) |field, index| {
        if (index != 0) try result.append(allocator, ',');
        try appendJsonString(result, allocator, field);
    }
    try result.print(allocator, "],\"operation_timeout_millis\":{d}", .{node.lifecycle.operation_timeout_millis});
    try result.appendSlice(allocator, "}}");
}

fn appendOutput(result: *std.ArrayList(u8), allocator: std.mem.Allocator, definition: stack_registry.OutputDefinition) Error!void {
    try result.appendSlice(allocator, "{\"name\":");
    try appendJsonString(result, allocator, definition.name);
    try result.print(allocator, ",\"secret\":{},\"source\":{{", .{definition.secret});
    switch (definition.source) {
        .literal => |literal| {
            if (definition.secret) return error.SecretMaterialDetected;
            try result.appendSlice(allocator, "\"kind\":\"literal\",\"value\":");
            try appendJsonString(result, allocator, literal);
        },
        .resource_ref => |reference| {
            try result.appendSlice(allocator, "\"kind\":\"resource_ref\",\"resource_id\":");
            try appendJsonString(result, allocator, reference.resource_id);
            try result.appendSlice(allocator, ",\"field\":");
            try appendJsonString(result, allocator, reference.field);
        },
    }
    try result.appendSlice(allocator, "}}");
}

fn parseProgram(allocator: std.mem.Allocator, source: std.json.ObjectMap) Error!stack_registry.StackProgram {
    var graph = resource.ResourceGraph.init(allocator);
    errdefer graph.deinit();
    const resources = asArray(source.get("resources") orelse return error.InvalidProgramArtifact) orelse return error.InvalidProgramArtifact;
    for (resources) |entry| try parseAndAddResource(allocator, &graph, entry);
    const dependencies = asArray(source.get("dependencies") orelse return error.InvalidProgramArtifact) orelse return error.InvalidProgramArtifact;
    for (dependencies) |entry| {
        const edge = asObject(entry) orelse return error.InvalidProgramArtifact;
        try graph.addDependency(try stringField(edge, "from"), try stringField(edge, "to"));
    }
    try graph.validateAcyclic();

    var outputs = std.ArrayList(stack_registry.OutputDefinition).empty;
    errdefer {
        for (outputs.items) |*entry| entry.deinit(allocator);
        outputs.deinit(allocator);
    }
    const encoded_outputs = asArray(source.get("outputs") orelse return error.InvalidProgramArtifact) orelse return error.InvalidProgramArtifact;
    for (encoded_outputs) |entry| try parseAndAppendOutput(allocator, &outputs, entry);
    return .{ .allocator = allocator, .graph = graph, .outputs = outputs };
}

fn parseAndAddResource(allocator: std.mem.Allocator, graph: *resource.ResourceGraph, source: std.json.Value) Error!void {
    const object = asObject(source) orelse return error.InvalidProgramArtifact;
    const provider_name = try stringField(object, "provider");
    const provider = std.meta.stringToEnum(resource.ProviderId, provider_name) orelse return error.InvalidProgramArtifact;
    var inputs = value_mod.Value.fromJsonValueAlloc(allocator, object.get("inputs") orelse return error.InvalidProgramArtifact) catch return error.InvalidProgramArtifact;
    defer inputs.deinit(allocator);
    if (containsSecretLiteral(inputs, null)) return error.SecretMaterialDetected;
    const lifecycle_object = asObject(object.get("lifecycle") orelse return error.InvalidProgramArtifact) orelse return error.InvalidProgramArtifact;
    const ignore_json = asArray(lifecycle_object.get("ignore_changes") orelse return error.InvalidProgramArtifact) orelse return error.InvalidProgramArtifact;
    const ignores = try allocator.alloc([]const u8, ignore_json.len);
    defer allocator.free(ignores);
    for (ignore_json, 0..) |entry, index| ignores[index] = switch (entry) {
        .string => |value| value,
        else => return error.InvalidProgramArtifact,
    };
    const schema_version = try unsignedField(u32, object, "schema_version");
    const timeout = try unsignedField(u64, lifecycle_object, "operation_timeout_millis");
    if (timeout == 0) return error.InvalidProgramArtifact;
    try graph.addResource(.{
        .id = try stringField(object, "id"),
        .provider = provider,
        .type_name = try stringField(object, "type_name"),
        .schema_version = schema_version,
        .logical_id = try stringField(object, "logical_id"),
        .inputs = inputs,
        .component = if (object.get("component")) |value| try parseComponentOrigin(value) else null,
        .lifecycle = .{
            .protect = try boolField(lifecycle_object, "protect"),
            .retain_on_delete = try boolField(lifecycle_object, "retain_on_delete"),
            .replace_before_delete = try boolField(lifecycle_object, "replace_before_delete"),
            .ignore_changes = ignores,
            .operation_timeout_millis = timeout,
        },
    });
}

fn parseComponentOrigin(source: std.json.Value) Error!@import("provenance.zig").Origin {
    const object = asObject(source) orelse return error.InvalidProgramArtifact;
    if (object.count() != 5) return error.InvalidProgramArtifact;
    const origin = @import("provenance.zig").Origin{
        .package = try stringField(object, "package"),
        .name = try stringField(object, "name"),
        .version = try stringField(object, "version"),
        .instance = try stringField(object, "instance"),
        .source_digest = try stringField(object, "source_digest"),
    };
    origin.validate() catch return error.InvalidProgramArtifact;
    return origin;
}

fn parseAndAppendOutput(allocator: std.mem.Allocator, outputs: *std.ArrayList(stack_registry.OutputDefinition), source: std.json.Value) Error!void {
    const object = asObject(source) orelse return error.InvalidProgramArtifact;
    const source_object = asObject(object.get("source") orelse return error.InvalidProgramArtifact) orelse return error.InvalidProgramArtifact;
    const name = try allocator.dupe(u8, try stringField(object, "name"));
    errdefer allocator.free(name);
    const secret = try boolField(object, "secret");
    const kind = try stringField(source_object, "kind");
    var definition: stack_registry.OutputDefinition = undefined;
    if (std.mem.eql(u8, kind, "literal")) {
        if (secret) return error.SecretMaterialDetected;
        definition = .{
            .name = name,
            .source = .{ .literal = try allocator.dupe(u8, try stringField(source_object, "value")) },
            .secret = false,
        };
    } else if (std.mem.eql(u8, kind, "resource_ref")) {
        const resource_id = try allocator.dupe(u8, try stringField(source_object, "resource_id"));
        errdefer allocator.free(resource_id);
        definition = .{
            .name = name,
            .source = .{ .resource_ref = output_mod.OutputRef{
                .resource_id = resource_id,
                .field = try allocator.dupe(u8, try stringField(source_object, "field")),
            } },
            .secret = secret,
        };
    } else return error.InvalidProgramArtifact;
    try outputs.append(allocator, definition);
}

fn containsSecretLiteral(value: value_mod.Value, field_name: ?[]const u8) bool {
    return switch (value) {
        .secret_ref => false,
        .string => |text| (field_name != null and isSecretField(field_name.?)) or std.mem.indexOf(u8, text, "://") != null and std.mem.indexOfScalar(u8, text, '@') != null,
        .list => |items| for (items) |item| {
            if (containsSecretLiteral(item, field_name)) break true;
        } else false,
        .object => |fields| for (fields) |field| {
            if (containsSecretLiteral(field.value, field.name)) break true;
        } else false,
        .integer, .boolean, .output_ref, .unknown_reason => false,
    };
}

fn isSecretField(name: []const u8) bool {
    const metadata_fields = [_][]const u8{ "secret_id", "secret_name" };
    for (metadata_fields) |field| if (std.mem.eql(u8, name, field)) return false;
    const needles = [_][]const u8{ "secret", "password", "token", "credential", "private_key", "database_url", "connection_string" };
    var lower: [256]u8 = undefined;
    if (name.len > lower.len) return true;
    for (name, 0..) |char, index| lower[index] = std.ascii.toLower(char);
    for (needles) |needle| if (std.mem.indexOf(u8, lower[0..name.len], needle) != null) return true;
    return false;
}

fn appendJsonString(result: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(encoded);
    try result.appendSlice(allocator, encoded);
}

fn asObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |inner| inner,
        else => null,
    };
}

fn asArray(value: std.json.Value) ?[]const std.json.Value {
    return switch (value) {
        .array => |inner| inner.items,
        else => null,
    };
}

fn stringField(object: std.json.ObjectMap, name: []const u8) Error![]const u8 {
    return switch (object.get(name) orelse return error.InvalidProgramArtifact) {
        .string => |inner| if (inner.len == 0) error.InvalidProgramArtifact else inner,
        else => error.InvalidProgramArtifact,
    };
}

fn boolField(object: std.json.ObjectMap, name: []const u8) Error!bool {
    return switch (object.get(name) orelse return error.InvalidProgramArtifact) {
        .bool => |inner| inner,
        else => error.InvalidProgramArtifact,
    };
}

fn unsignedField(comptime T: type, object: std.json.ObjectMap, name: []const u8) Error!T {
    return switch (object.get(name) orelse return error.InvalidProgramArtifact) {
        .integer => |inner| std.math.cast(T, inner) orelse error.InvalidProgramArtifact,
        else => error.InvalidProgramArtifact,
    };
}
