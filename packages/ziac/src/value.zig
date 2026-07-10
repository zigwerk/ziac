const std = @import("std");

pub const ValueError = std.mem.Allocator.Error || error{DuplicateField};
pub const ParseError = ValueError || error{ InvalidJson, UnsupportedJsonValue };

pub const SecretReference = struct {
    provider: []const u8,
    resource: []const u8,
    version: ?[]const u8 = null,
    field: ?[]const u8 = null,
};

pub const Field = struct {
    name: []const u8,
    value: Value,
};

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    boolean: bool,
    list: []const Value,
    object: []const Field,
    secret_ref: SecretReference,
    unknown_reason: []const u8,

    pub fn initOwned(allocator: std.mem.Allocator, source: Value) ValueError!Value {
        return switch (source) {
            .string => |inner| .{ .string = try allocator.dupe(u8, inner) },
            .integer => |inner| .{ .integer = inner },
            .boolean => |inner| .{ .boolean = inner },
            .list => |inner| .{ .list = try cloneList(allocator, inner) },
            .object => |inner| .{ .object = try cloneObject(allocator, inner) },
            .secret_ref => |inner| .{ .secret_ref = try cloneSecretReference(allocator, inner) },
            .unknown_reason => |inner| .{ .unknown_reason = try allocator.dupe(u8, inner) },
        };
    }

    pub fn clone(self: Value, allocator: std.mem.Allocator) ValueError!Value {
        return initOwned(allocator, self);
    }

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |inner| allocator.free(inner),
            .integer, .boolean => {},
            .list => |inner| freeList(allocator, inner),
            .object => |inner| freeObject(allocator, inner),
            .secret_ref => |inner| freeSecretReference(allocator, inner),
            .unknown_reason => |inner| allocator.free(inner),
        }
        self.* = undefined;
    }

    pub fn canonicalJsonAlloc(self: Value, allocator: std.mem.Allocator) ValueError![]const u8 {
        var normalized = try self.clone(allocator);
        defer normalized.deinit(allocator);

        var output = std.ArrayList(u8).empty;
        errdefer output.deinit(allocator);
        try appendCanonicalJson(&output, allocator, normalized);
        return output.toOwnedSlice(allocator);
    }

    pub fn sha256(self: Value, allocator: std.mem.Allocator) ValueError![32]u8 {
        const json = try self.canonicalJsonAlloc(allocator);
        defer allocator.free(json);

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(json, &digest, .{});
        return digest;
    }

    pub fn parseJsonAlloc(allocator: std.mem.Allocator, input: []const u8) ParseError!Value {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch return error.InvalidJson;
        defer parsed.deinit();
        return valueFromJson(allocator, parsed.value);
    }
};

fn cloneList(allocator: std.mem.Allocator, source: []const Value) ValueError![]const Value {
    const values = try allocator.alloc(Value, source.len);
    errdefer allocator.free(values);

    var initialized: usize = 0;
    errdefer {
        for (values[0..initialized]) |*value| value.deinit(allocator);
    }

    for (source, 0..) |value, index| {
        values[index] = try Value.initOwned(allocator, value);
        initialized += 1;
    }
    return values;
}

fn freeList(allocator: std.mem.Allocator, values: []const Value) void {
    const mutable_values: []Value = @constCast(values);
    for (mutable_values) |*value| value.deinit(allocator);
    allocator.free(values);
}

fn cloneObject(allocator: std.mem.Allocator, source: []const Field) ValueError![]const Field {
    const fields = try allocator.alloc(Field, source.len);
    errdefer allocator.free(fields);

    var initialized: usize = 0;
    errdefer {
        for (fields[0..initialized]) |*field| {
            allocator.free(field.name);
            field.value.deinit(allocator);
        }
    }

    for (source, 0..) |field, index| {
        const name = try allocator.dupe(u8, field.name);
        errdefer allocator.free(name);
        fields[index] = .{
            .name = name,
            .value = try Value.initOwned(allocator, field.value),
        };
        initialized += 1;
    }

    std.mem.sort(Field, fields, {}, lessThanFieldName);
    if (fields.len > 1) {
        for (fields[1..], fields[0 .. fields.len - 1]) |right, left| {
            if (std.mem.eql(u8, left.name, right.name)) return error.DuplicateField;
        }
    }
    return fields;
}

fn freeObject(allocator: std.mem.Allocator, fields: []const Field) void {
    const mutable_fields: []Field = @constCast(fields);
    for (mutable_fields) |*field| {
        allocator.free(field.name);
        field.value.deinit(allocator);
    }
    allocator.free(fields);
}

fn lessThanFieldName(_: void, left: Field, right: Field) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}

fn cloneSecretReference(
    allocator: std.mem.Allocator,
    source: SecretReference,
) std.mem.Allocator.Error!SecretReference {
    const provider = try allocator.dupe(u8, source.provider);
    errdefer allocator.free(provider);
    const resource = try allocator.dupe(u8, source.resource);
    errdefer allocator.free(resource);
    const version = if (source.version) |value| try allocator.dupe(u8, value) else null;
    errdefer if (version) |value| allocator.free(value);
    const field = if (source.field) |value| try allocator.dupe(u8, value) else null;
    errdefer if (field) |value| allocator.free(value);

    return .{
        .provider = provider,
        .resource = resource,
        .version = version,
        .field = field,
    };
}

fn freeSecretReference(allocator: std.mem.Allocator, reference: SecretReference) void {
    allocator.free(reference.provider);
    allocator.free(reference.resource);
    if (reference.version) |value| allocator.free(value);
    if (reference.field) |value| allocator.free(value);
}

fn appendCanonicalJson(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: Value,
) ValueError!void {
    switch (value) {
        .string => |inner| try appendJsonString(output, allocator, inner),
        .integer => |inner| try output.print(allocator, "{d}", .{inner}),
        .boolean => |inner| try output.appendSlice(allocator, if (inner) "true" else "false"),
        .list => |inner| {
            try output.append(allocator, '[');
            for (inner, 0..) |item, index| {
                if (index != 0) try output.append(allocator, ',');
                try appendCanonicalJson(output, allocator, item);
            }
            try output.append(allocator, ']');
        },
        .object => |inner| {
            try output.append(allocator, '{');
            for (inner, 0..) |field, index| {
                if (index != 0) try output.append(allocator, ',');
                try appendJsonString(output, allocator, field.name);
                try output.append(allocator, ':');
                try appendCanonicalJson(output, allocator, field.value);
            }
            try output.append(allocator, '}');
        },
        .secret_ref => |inner| {
            try output.appendSlice(allocator, "{\"$secret\":{");
            var needs_comma = false;
            if (inner.field) |field| {
                try output.appendSlice(allocator, "\"field\":");
                try appendJsonString(output, allocator, field);
                needs_comma = true;
            }
            if (needs_comma) try output.append(allocator, ',');
            try output.appendSlice(allocator, "\"provider\":");
            try appendJsonString(output, allocator, inner.provider);
            try output.appendSlice(allocator, ",\"resource\":");
            try appendJsonString(output, allocator, inner.resource);
            if (inner.version) |version| {
                try output.appendSlice(allocator, ",\"version\":");
                try appendJsonString(output, allocator, version);
            }
            try output.appendSlice(allocator, "}}");
        },
        .unknown_reason => |inner| {
            try output.appendSlice(allocator, "{\"$unknown\":");
            try appendJsonString(output, allocator, inner);
            try output.append(allocator, '}');
        },
    }
}

fn appendJsonString(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: []const u8,
) std.mem.Allocator.Error!void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(encoded);
    try output.appendSlice(allocator, encoded);
}

fn valueFromJson(allocator: std.mem.Allocator, source: std.json.Value) ParseError!Value {
    return switch (source) {
        .string => |inner| Value.initOwned(allocator, .{ .string = inner }),
        .integer => |inner| .{ .integer = inner },
        .bool => |inner| .{ .boolean = inner },
        .array => |inner| valueListFromJson(allocator, inner.items),
        .object => |inner| valueObjectFromJson(allocator, inner),
        .null, .float, .number_string => error.UnsupportedJsonValue,
    };
}

fn valueListFromJson(allocator: std.mem.Allocator, source: []const std.json.Value) ParseError!Value {
    const items = try allocator.alloc(Value, source.len);
    errdefer allocator.free(items);

    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |*item| item.deinit(allocator);
    }
    for (source, 0..) |item, index| {
        items[index] = try valueFromJson(allocator, item);
        initialized += 1;
    }
    return .{ .list = items };
}

fn valueObjectFromJson(allocator: std.mem.Allocator, source: std.json.ObjectMap) ParseError!Value {
    if (source.count() == 1) {
        if (source.get("$unknown")) |unknown| {
            return switch (unknown) {
                .string => |inner| Value.initOwned(allocator, .{ .unknown_reason = inner }),
                else => error.InvalidJson,
            };
        }
        if (source.get("$secret")) |secret| {
            const object = switch (secret) {
                .object => |inner| inner,
                else => return error.InvalidJson,
            };
            return Value.initOwned(allocator, .{ .secret_ref = .{
                .provider = try objectString(object, "provider"),
                .resource = try objectString(object, "resource"),
                .version = try optionalObjectString(object, "version"),
                .field = try optionalObjectString(object, "field"),
            } });
        }
    }

    const fields = try allocator.alloc(Field, source.count());
    errdefer allocator.free(fields);
    var initialized: usize = 0;
    errdefer {
        for (fields[0..initialized]) |*field| {
            allocator.free(field.name);
            field.value.deinit(allocator);
        }
    }

    var iterator = source.iterator();
    while (iterator.next()) |entry| {
        const name = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(name);
        var owned_value = try valueFromJson(allocator, entry.value_ptr.*);
        errdefer owned_value.deinit(allocator);
        fields[initialized] = .{ .name = name, .value = owned_value };
        initialized += 1;
    }
    std.mem.sort(Field, fields, {}, lessThanFieldName);
    return .{ .object = fields };
}

fn objectString(object: std.json.ObjectMap, name: []const u8) error{InvalidJson}![]const u8 {
    const field = object.get(name) orelse return error.InvalidJson;
    return switch (field) {
        .string => |inner| inner,
        else => error.InvalidJson,
    };
}

fn optionalObjectString(object: std.json.ObjectMap, name: []const u8) error{InvalidJson}!?[]const u8 {
    const field = object.get(name) orelse return null;
    return switch (field) {
        .string => |inner| inner,
        else => error.InvalidJson,
    };
}
