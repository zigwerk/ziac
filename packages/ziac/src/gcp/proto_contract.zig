const std = @import("std");

pub const googleapis_revision = "95de37fafded89761dd958268242904a6d893eae";
pub const descriptor_sha256 = "b782942487e0e305651bf83c5f211f132e4b29e3bedcdf15a83b478df6a8b722";
pub const snapshot_sha256 = "f4f0ca51afa49e9412d484cf3d10281519c21fdbf7e332dbe8aaf5f930d0baff";
pub const embedded_descriptor = @embedFile("generated/cloud-run-v2.pb");

pub const Error = std.mem.Allocator.Error || error{
    InvalidDescriptor,
    DescriptorLockMismatch,
    CloudRunContractMissing,
};

pub const Behavior = enum {
    unspecified,
    optional,
    required,
    output_only,
    input_only,
    immutable,
    unordered_list,
    non_empty_default,
    identifier,
};

pub const SemanticFact = struct {
    path: []const u8,
    behavior: Behavior,
};

pub const MethodFact = struct {
    name: []const u8,
    input_type: []const u8,
    output_type: []const u8,
    http_method: []const u8,
    path_template: []const u8,
    body: []const u8,
    routing_field: []const u8,
    lro_response_type: []const u8,
    lro_metadata_type: []const u8,
};

pub const Contract = struct {
    file_count: usize,
    package: []const u8,
    service: []const u8,
    default_host: []const u8,
    oauth_scope: []const u8,
    resource_type: []const u8,
    resource_pattern: []const u8,
    methods: []MethodFact,
    fields: []SemanticFact,

    pub fn deinit(self: *Contract, allocator: std.mem.Allocator) void {
        allocator.free(self.package);
        allocator.free(self.service);
        allocator.free(self.default_host);
        allocator.free(self.oauth_scope);
        allocator.free(self.resource_type);
        allocator.free(self.resource_pattern);
        for (self.methods) |method_fact| deinitMethod(allocator, method_fact);
        allocator.free(self.methods);
        for (self.fields) |field| allocator.free(field.path);
        allocator.free(self.fields);
        self.* = undefined;
    }

    pub fn hasMethod(self: Contract, name: []const u8) bool {
        for (self.methods) |method_fact| if (std.mem.eql(u8, method_fact.name, name)) return true;
        return false;
    }

    pub fn method(self: Contract, name: []const u8) ?MethodFact {
        for (self.methods) |candidate| if (std.mem.eql(u8, candidate.name, name)) return candidate;
        return null;
    }

    pub fn hasBinding(
        self: Contract,
        name: []const u8,
        http_method: []const u8,
        path_template: []const u8,
        routing_field: []const u8,
    ) bool {
        const candidate = self.method(name) orelse return false;
        return std.mem.eql(u8, candidate.http_method, http_method) and
            std.mem.eql(u8, candidate.path_template, path_template) and
            std.mem.eql(u8, candidate.routing_field, routing_field);
    }

    pub fn hasField(self: Contract, path: []const u8, behavior: Behavior) bool {
        for (self.fields) |field| {
            if (field.behavior == behavior and std.mem.eql(u8, field.path, path)) return true;
        }
        return false;
    }
};

pub fn verifyEmbeddedLock() Error!void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(embedded_descriptor, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &actual, descriptor_sha256)) return error.DescriptorLockMismatch;
}

pub fn inspectCloudRunV2(allocator: std.mem.Allocator, descriptor: []const u8) Error!Contract {
    var methods: std.ArrayList(MethodFact) = .empty;
    errdefer {
        for (methods.items) |method| deinitMethod(allocator, method);
        methods.deinit(allocator);
    }
    var fields: std.ArrayList(SemanticFact) = .empty;
    errdefer {
        for (fields.items) |field| allocator.free(field.path);
        fields.deinit(allocator);
    }

    var file_count: usize = 0;
    var package: ?[]u8 = null;
    errdefer if (package) |value| allocator.free(value);
    var service_name: ?[]u8 = null;
    errdefer if (service_name) |value| allocator.free(value);
    var default_host: ?[]u8 = null;
    errdefer if (default_host) |value| allocator.free(value);
    var oauth_scope: ?[]u8 = null;
    errdefer if (oauth_scope) |value| allocator.free(value);
    var resource_type: ?[]u8 = null;
    errdefer if (resource_type) |value| allocator.free(value);
    var resource_pattern: ?[]u8 = null;
    errdefer if (resource_pattern) |value| allocator.free(value);

    var set = WireReader.init(descriptor);
    while (try set.next()) |field| {
        if (field.number != 1 or field.wire_type != .bytes) continue;
        file_count += 1;
        if (!try fileHasName(field.bytes, "google/cloud/run/v2/service.proto")) continue;
        var file = WireReader.init(field.bytes);
        while (try file.next()) |entry| switch (entry.number) {
            2 => if (entry.wire_type == .bytes) {
                package = try allocator.dupe(u8, entry.bytes);
            },
            4 => if (entry.wire_type == .bytes) {
                try inspectMessage(allocator, entry.bytes, "", &fields);
                if (std.mem.eql(u8, try messageStringField(entry.bytes, 1), "Service")) {
                    const resource = try inspectResourceDescriptor(allocator, entry.bytes);
                    resource_type = resource.resource_type;
                    resource_pattern = resource.resource_pattern;
                }
            },
            6 => if (entry.wire_type == .bytes) {
                const parsed = try inspectService(allocator, entry.bytes, &methods);
                if (parsed.name) |name| service_name = name;
                if (parsed.default_host) |host| default_host = host;
                if (parsed.oauth_scope) |scope| oauth_scope = scope;
            },
            else => {},
        };
    }

    return .{
        .file_count = file_count,
        .package = package orelse return error.CloudRunContractMissing,
        .service = service_name orelse return error.CloudRunContractMissing,
        .default_host = default_host orelse return error.CloudRunContractMissing,
        .oauth_scope = oauth_scope orelse return error.CloudRunContractMissing,
        .resource_type = resource_type orelse return error.CloudRunContractMissing,
        .resource_pattern = resource_pattern orelse return error.CloudRunContractMissing,
        .methods = try methods.toOwnedSlice(allocator),
        .fields = try fields.toOwnedSlice(allocator),
    };
}

pub fn snapshotJsonAlloc(allocator: std.mem.Allocator, descriptor: []const u8) Error![]u8 {
    var contract = try inspectCloudRunV2(allocator, descriptor);
    defer contract.deinit(allocator);
    return std.json.Stringify.valueAlloc(allocator, .{
        .schema = "ziac.google.proto.v1",
        .revision = googleapis_revision,
        .descriptor_sha256 = descriptor_sha256,
        .file_count = contract.file_count,
        .package = contract.package,
        .service = contract.service,
        .default_host = contract.default_host,
        .oauth_scope = contract.oauth_scope,
        .resource_type = contract.resource_type,
        .resource_pattern = contract.resource_pattern,
        .methods = contract.methods,
        .fields = contract.fields,
    }, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
}

pub fn verifyGeneratedSnapshot(allocator: std.mem.Allocator) Error!void {
    const snapshot = try snapshotJsonAlloc(allocator, embedded_descriptor);
    defer allocator.free(snapshot);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(snapshot, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &actual, snapshot_sha256)) return error.DescriptorLockMismatch;
}

pub const ChangedFact = struct {
    path: []const u8,
    previous: Behavior,
    next: Behavior,
};

pub const SemanticDiff = struct {
    added: []SemanticFact,
    removed: []SemanticFact,
    changed: []ChangedFact,
    breaking: bool,

    pub fn deinit(self: *SemanticDiff, allocator: std.mem.Allocator) void {
        for (self.added) |fact| allocator.free(fact.path);
        allocator.free(self.added);
        for (self.removed) |fact| allocator.free(fact.path);
        allocator.free(self.removed);
        for (self.changed) |fact| allocator.free(fact.path);
        allocator.free(self.changed);
        self.* = undefined;
    }
};

pub fn diffFacts(
    allocator: std.mem.Allocator,
    current: []const SemanticFact,
    next: []const SemanticFact,
) std.mem.Allocator.Error!SemanticDiff {
    var added: std.ArrayList(SemanticFact) = .empty;
    errdefer deinitFactList(allocator, &added);
    var removed: std.ArrayList(SemanticFact) = .empty;
    errdefer deinitFactList(allocator, &removed);
    var changed: std.ArrayList(ChangedFact) = .empty;
    errdefer {
        for (changed.items) |fact| allocator.free(fact.path);
        changed.deinit(allocator);
    }
    var breaking = false;

    for (current) |before| {
        const after = findFact(next, before.path) orelse {
            try removed.append(allocator, .{ .path = try allocator.dupe(u8, before.path), .behavior = before.behavior });
            breaking = true;
            continue;
        };
        if (before.behavior != after.behavior) {
            try changed.append(allocator, .{
                .path = try allocator.dupe(u8, before.path),
                .previous = before.behavior,
                .next = after.behavior,
            });
            if (after.behavior == .required or after.behavior == .immutable) breaking = true;
        }
    }
    for (next) |after| if (findFact(current, after.path) == null) {
        try added.append(allocator, .{ .path = try allocator.dupe(u8, after.path), .behavior = after.behavior });
    };

    return .{
        .added = try added.toOwnedSlice(allocator),
        .removed = try removed.toOwnedSlice(allocator),
        .changed = try changed.toOwnedSlice(allocator),
        .breaking = breaking,
    };
}

pub fn semanticDiffJsonAlloc(
    allocator: std.mem.Allocator,
    current: []const SemanticFact,
    next: []const SemanticFact,
) std.mem.Allocator.Error![]u8 {
    var diff = try diffFacts(allocator, current, next);
    defer diff.deinit(allocator);
    return std.json.Stringify.valueAlloc(allocator, .{
        .schema = "ziac.google.proto-semantic-diff.v1",
        .googleapis_revision = googleapis_revision,
        .descriptor_sha256 = descriptor_sha256,
        .breaking = diff.breaking,
        .added = diff.added,
        .removed = diff.removed,
        .changed = diff.changed,
    }, .{}) catch return error.OutOfMemory;
}

fn findFact(facts: []const SemanticFact, path: []const u8) ?SemanticFact {
    for (facts) |fact| if (std.mem.eql(u8, fact.path, path)) return fact;
    return null;
}

fn deinitFactList(allocator: std.mem.Allocator, list: *std.ArrayList(SemanticFact)) void {
    for (list.items) |fact| allocator.free(fact.path);
    list.deinit(allocator);
}

const ServiceInspection = struct {
    name: ?[]u8 = null,
    default_host: ?[]u8 = null,
    oauth_scope: ?[]u8 = null,
};

fn inspectService(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    methods: *std.ArrayList(MethodFact),
) Error!ServiceInspection {
    var result = ServiceInspection{};
    errdefer {
        if (result.name) |name| allocator.free(name);
        if (result.default_host) |host| allocator.free(host);
        if (result.oauth_scope) |scope| allocator.free(scope);
    }
    var reader = WireReader.init(bytes);
    while (try reader.next()) |field| switch (field.number) {
        1 => {
            if (field.wire_type == .bytes) result.name = try allocator.dupe(u8, field.bytes);
        },
        2 => if (field.wire_type == .bytes) {
            try methods.append(allocator, try inspectMethod(allocator, field.bytes));
        },
        3 => if (field.wire_type == .bytes) {
            var options = WireReader.init(field.bytes);
            while (try options.next()) |option| {
                if (option.number == 1049 and option.wire_type == .bytes) {
                    result.default_host = try allocator.dupe(u8, option.bytes);
                } else if (option.number == 1050 and option.wire_type == .bytes) {
                    result.oauth_scope = try allocator.dupe(u8, option.bytes);
                }
            }
        },
        else => {},
    };
    return result;
}

const MethodParts = struct {
    name: []const u8 = "",
    input_type: []const u8 = "",
    output_type: []const u8 = "",
    http_method: []const u8 = "",
    path_template: []const u8 = "",
    body: []const u8 = "",
    routing_field: []const u8 = "",
    lro_response_type: []const u8 = "",
    lro_metadata_type: []const u8 = "",
};

fn inspectMethod(allocator: std.mem.Allocator, bytes: []const u8) Error!MethodFact {
    var parts = MethodParts{};
    var reader = WireReader.init(bytes);
    while (try reader.next()) |field| switch (field.number) {
        1 => {
            if (field.wire_type == .bytes) parts.name = field.bytes;
        },
        2 => {
            if (field.wire_type == .bytes) parts.input_type = field.bytes;
        },
        3 => {
            if (field.wire_type == .bytes) parts.output_type = field.bytes;
        },
        4 => {
            if (field.wire_type == .bytes) try inspectMethodOptions(field.bytes, &parts);
        },
        else => {},
    };
    if (parts.name.len == 0 or parts.input_type.len == 0 or parts.output_type.len == 0) return error.InvalidDescriptor;
    return dupeMethod(allocator, parts);
}

fn inspectMethodOptions(bytes: []const u8, parts: *MethodParts) Error!void {
    var options = WireReader.init(bytes);
    while (try options.next()) |option| {
        if (option.wire_type != .bytes) continue;
        switch (option.number) {
            1049 => {
                parts.lro_response_type = try messageStringField(option.bytes, 1);
                parts.lro_metadata_type = try messageStringField(option.bytes, 2);
            },
            72295728 => try inspectHttpRule(option.bytes, parts),
            72295729 => parts.routing_field = try inspectRoutingRule(option.bytes),
            else => {},
        }
    }
}

fn inspectHttpRule(bytes: []const u8, parts: *MethodParts) Error!void {
    var rule = WireReader.init(bytes);
    while (try rule.next()) |field| {
        if (field.wire_type != .bytes) continue;
        switch (field.number) {
            2 => {
                parts.http_method = "GET";
                parts.path_template = field.bytes;
            },
            3 => {
                parts.http_method = "PUT";
                parts.path_template = field.bytes;
            },
            4 => {
                parts.http_method = "POST";
                parts.path_template = field.bytes;
            },
            5 => {
                parts.http_method = "DELETE";
                parts.path_template = field.bytes;
            },
            6 => {
                parts.http_method = "PATCH";
                parts.path_template = field.bytes;
            },
            7 => parts.body = field.bytes,
            else => {},
        }
    }
}

fn inspectRoutingRule(bytes: []const u8) Error![]const u8 {
    var rule = WireReader.init(bytes);
    while (try rule.next()) |field| {
        if (field.number == 2 and field.wire_type == .bytes) return messageStringField(field.bytes, 1);
    }
    return "";
}

const ResourceInspection = struct {
    resource_type: ?[]u8 = null,
    resource_pattern: ?[]u8 = null,
};

fn inspectResourceDescriptor(allocator: std.mem.Allocator, bytes: []const u8) Error!ResourceInspection {
    var result = ResourceInspection{};
    errdefer {
        if (result.resource_type) |value| allocator.free(value);
        if (result.resource_pattern) |value| allocator.free(value);
    }
    var message = WireReader.init(bytes);
    while (try message.next()) |field| {
        if (field.number != 7 or field.wire_type != .bytes) continue;
        var options = WireReader.init(field.bytes);
        while (try options.next()) |option| {
            if (option.number != 1053 or option.wire_type != .bytes) continue;
            result.resource_type = try allocator.dupe(u8, try messageStringField(option.bytes, 1));
            result.resource_pattern = try allocator.dupe(u8, try messageStringField(option.bytes, 2));
            return result;
        }
    }
    return error.CloudRunContractMissing;
}

fn dupeMethod(allocator: std.mem.Allocator, parts: MethodParts) std.mem.Allocator.Error!MethodFact {
    var method: MethodFact = undefined;
    const fields = @typeInfo(MethodFact).@"struct".fields;
    var initialized: usize = 0;
    errdefer inline for (fields, 0..) |field, index| {
        if (index < initialized) allocator.free(@field(method, field.name));
    };
    inline for (fields) |field| {
        @field(method, field.name) = try allocator.dupe(u8, @field(parts, field.name));
        initialized += 1;
    }
    return method;
}

fn deinitMethod(allocator: std.mem.Allocator, method: MethodFact) void {
    inline for (@typeInfo(MethodFact).@"struct".fields) |field| allocator.free(@field(method, field.name));
}

fn inspectMessage(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    prefix: []const u8,
    fields: *std.ArrayList(SemanticFact),
) Error!void {
    const name = try messageStringField(bytes, 1);
    const path_prefix = if (prefix.len == 0)
        try allocator.dupe(u8, name)
    else
        try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, name });
    defer allocator.free(path_prefix);

    var reader = WireReader.init(bytes);
    while (try reader.next()) |field| switch (field.number) {
        2 => if (field.wire_type == .bytes) {
            const field_name = try messageStringField(field.bytes, 1);
            const behavior = try fieldBehavior(field.bytes);
            if (behavior != .unspecified) {
                try fields.append(allocator, .{
                    .path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ path_prefix, field_name }),
                    .behavior = behavior,
                });
            }
        },
        3 => if (field.wire_type == .bytes) try inspectMessage(allocator, field.bytes, path_prefix, fields),
        else => {},
    };
}

fn fieldBehavior(bytes: []const u8) Error!Behavior {
    var field = WireReader.init(bytes);
    while (try field.next()) |entry| {
        if (entry.number != 8 or entry.wire_type != .bytes) continue;
        var options = WireReader.init(entry.bytes);
        while (try options.next()) |option| {
            if (option.number == 1052 and option.wire_type == .varint) return behaviorFromNumber(option.varint);
        }
    }
    return .unspecified;
}

fn behaviorFromNumber(number: u64) Behavior {
    return switch (number) {
        1 => .optional,
        2 => .required,
        3 => .output_only,
        4 => .input_only,
        5 => .immutable,
        6 => .unordered_list,
        7 => .non_empty_default,
        8 => .identifier,
        else => .unspecified,
    };
}

fn fileHasName(bytes: []const u8, expected: []const u8) Error!bool {
    var reader = WireReader.init(bytes);
    while (try reader.next()) |field| {
        if (field.number == 1 and field.wire_type == .bytes) return std.mem.eql(u8, field.bytes, expected);
    }
    return false;
}

fn messageStringField(bytes: []const u8, number: u32) Error![]const u8 {
    var reader = WireReader.init(bytes);
    while (try reader.next()) |field| {
        if (field.number == number and field.wire_type == .bytes) return field.bytes;
    }
    return error.InvalidDescriptor;
}

const WireType = enum(u3) { varint = 0, fixed64 = 1, bytes = 2, fixed32 = 5 };
const WireField = struct {
    number: u32,
    wire_type: WireType,
    varint: u64 = 0,
    bytes: []const u8 = &.{},
};

const WireReader = struct {
    input: []const u8,
    index: usize = 0,

    fn init(input: []const u8) WireReader {
        return .{ .input = input };
    }

    fn next(self: *WireReader) Error!?WireField {
        if (self.index == self.input.len) return null;
        const key = try self.readVarint();
        const number: u32 = @intCast(key >> 3);
        if (number == 0) return error.InvalidDescriptor;
        const wire_type: WireType = switch (key & 7) {
            0 => .varint,
            1 => .fixed64,
            2 => .bytes,
            5 => .fixed32,
            else => return error.InvalidDescriptor,
        };
        return switch (wire_type) {
            .varint => .{ .number = number, .wire_type = wire_type, .varint = try self.readVarint() },
            .bytes => bytes: {
                const length: usize = @intCast(try self.readVarint());
                if (length > self.input.len - self.index) return error.InvalidDescriptor;
                const value = self.input[self.index .. self.index + length];
                self.index += length;
                break :bytes .{ .number = number, .wire_type = wire_type, .bytes = value };
            },
            .fixed64 => fixed: {
                if (8 > self.input.len - self.index) return error.InvalidDescriptor;
                self.index += 8;
                break :fixed .{ .number = number, .wire_type = wire_type };
            },
            .fixed32 => fixed: {
                if (4 > self.input.len - self.index) return error.InvalidDescriptor;
                self.index += 4;
                break :fixed .{ .number = number, .wire_type = wire_type };
            },
        };
    }

    fn readVarint(self: *WireReader) Error!u64 {
        var value: u64 = 0;
        var shift: u8 = 0;
        while (shift < 64) : (shift += 7) {
            if (self.index >= self.input.len) return error.InvalidDescriptor;
            const byte = self.input[self.index];
            self.index += 1;
            value |= @as(u64, byte & 0x7f) << @intCast(shift);
            if (byte & 0x80 == 0) return value;
        }
        return error.InvalidDescriptor;
    }
};
