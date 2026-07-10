const std = @import("std");
const client_mod = @import("client.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const storage = @import("storage.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;
const build_bucket_type = "gcp.storage.BuildBucket";
const source_object_type = "gcp.storage.SourceObject";

const Kind = enum { build_bucket, source_object };

pub const PayloadDeinitObserver = struct {
    ptr: *anyopaque,
    deinitFn: *const fn (*anyopaque) void,
};

pub const Payload = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    observer: ?PayloadDeinitObserver = null,

    pub fn initOwned(
        allocator: std.mem.Allocator,
        bytes: []const u8,
        observer: ?PayloadDeinitObserver,
    ) ProviderError!Payload {
        return .{
            .allocator = allocator,
            .bytes = allocator.dupe(u8, bytes) catch return error.OutOfMemory,
            .observer = observer,
        };
    }

    pub fn deinit(self: *Payload) void {
        std.crypto.secureZero(u8, self.bytes);
        self.allocator.free(self.bytes);
        if (self.observer) |observer| observer.deinitFn(observer.ptr);
        self.* = undefined;
    }
};

pub const PayloadSource = struct {
    ptr: *anyopaque,
    resolveFn: *const fn (
        *anyopaque,
        *provider_mod.OperationContext,
        std.mem.Allocator,
        []const u8,
    ) ProviderError!Payload,

    pub fn resolve(
        self: PayloadSource,
        context: *provider_mod.OperationContext,
        allocator: std.mem.Allocator,
        source_path: []const u8,
    ) ProviderError!Payload {
        return self.resolveFn(self.ptr, context, allocator, source_path);
    }
};

pub const Handler = struct {
    client: *client_mod.Client,
    payload_source: ?PayloadSource = null,

    pub fn read(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_override: ?[]const u8,
    ) ProviderError!provider_mod.ReadResult {
        return switch (kind(node) orelse return error.InvalidConfiguration) {
            .build_bucket => self.readBucket(context, node, physical_override),
            .source_object => self.readSourceObject(context, node, physical_override),
        };
    }

    pub fn diff(
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        observed: *const provider_mod.ResourceResult,
    ) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        const resource_kind = kind(node) orelse return error.InvalidConfiguration;
        const diff_kind: provider_mod.DiffKind = if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash))
            .noop
        else switch (resource_kind) {
            .source_object => .replace,
            .build_bucket => if (sameBucketIdentity(node.inputs, observed.observed_inputs)) .update else .replace,
        };
        const reasons: []const []const u8 = if (diff_kind == .noop) &.{} else &.{"Cloud Storage desired state differs from observed resource"};
        return provider_mod.DiffResult.init(context.allocator, diff_kind, reasons);
    }

    pub fn create(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        return switch (kind(node) orelse return error.InvalidConfiguration) {
            .build_bucket => self.createBucket(context, node),
            .source_object => self.createSourceObject(context, node),
        };
    }

    pub fn update(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!provider_mod.ResourceResult {
        if (kind(node) != .build_bucket) return error.InvalidConfiguration;
        const expected = try bucketPhysicalIdAlloc(context.allocator, node);
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        const bucket = try requiredString(node.inputs, "name");
        const encoded_bucket = try percentEncodeAlloc(context.allocator, bucket);
        defer context.allocator.free(encoded_bucket);
        const path = try std.fmt.allocPrint(context.allocator, "/storage/v1/b/{s}", .{encoded_bucket});
        defer context.allocator.free(path);
        const body = try bucketBodyAlloc(context.allocator, node, false);
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .storage, .method = "PATCH", .path = path, .body = body });
        defer response.deinit(context.allocator);
        return bucketResultFromJson(context, node, response.body);
    }

    pub fn delete(
        _: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!void {
        try context.checkActive();
        const resource_kind = kind(node) orelse return error.InvalidConfiguration;
        const expected = switch (resource_kind) {
            .build_bucket => try bucketPhysicalIdAlloc(context.allocator, node),
            .source_object => try validateSourcePhysicalIdAlloc(context, node, physical_id),
        };
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        // Build inputs are content addressed and intentionally retained for rollback.
    }

    fn readBucket(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_override: ?[]const u8,
    ) ProviderError!provider_mod.ReadResult {
        const expected = try bucketPhysicalIdAlloc(context.allocator, node);
        defer context.allocator.free(expected);
        const physical_id = physical_override orelse expected;
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        const bucket = try requiredString(node.inputs, "name");
        const encoded_bucket = try percentEncodeAlloc(context.allocator, bucket);
        defer context.allocator.free(encoded_bucket);
        const path = try std.fmt.allocPrint(context.allocator, "/storage/v1/b/{s}", .{encoded_bucket});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .storage, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try bucketResultFromJson(context, node, response.body) };
    }

    fn createBucket(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        const project_id = try requiredString(node.inputs, "project_id");
        const encoded_project = try percentEncodeAlloc(context.allocator, project_id);
        defer context.allocator.free(encoded_project);
        const path = try std.fmt.allocPrint(context.allocator, "/storage/v1/b?project={s}", .{encoded_project});
        defer context.allocator.free(path);
        const body = try bucketBodyAlloc(context.allocator, node, true);
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .storage, .method = "POST", .path = path, .body = body });
        defer response.deinit(context.allocator);
        return bucketResultFromJson(context, node, response.body);
    }

    fn readSourceObject(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_override: ?[]const u8,
    ) ProviderError!provider_mod.ReadResult {
        const identity = try sourceIdentity(context, node, physical_override);
        defer identity.deinit(context.allocator);
        const path = try sourceObjectGetPathAlloc(context.allocator, identity.bucket, identity.object_name, identity.generation);
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .storage, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        var present = try sourceObjectResultFromJson(context, node, response.body);
        errdefer present.deinit();
        if (physical_override) |expected| {
            if (!std.mem.eql(u8, expected, present.physical_id)) return error.InvalidConfiguration;
        }
        return .{ .present = present };
    }

    fn createSourceObject(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        const payload_source = self.payload_source orelse return error.InvalidConfiguration;
        var payload = try payload_source.resolve(context, context.allocator, try requiredString(node.inputs, "source_path"));
        defer payload.deinit();
        try verifyPayload(node, payload.bytes);

        const bucket = try resolveString(context, try requiredValue(node.inputs, "bucket"));
        const object_name = try requiredString(node.inputs, "object_name");
        const encoded_bucket = try percentEncodeAlloc(context.allocator, bucket);
        defer context.allocator.free(encoded_bucket);
        const encoded_name = try percentEncodeAlloc(context.allocator, object_name);
        defer context.allocator.free(encoded_name);
        const path = try std.fmt.allocPrint(
            context.allocator,
            "/upload/storage/v1/b/{s}/o?uploadType=media&name={s}&ifGenerationMatch=0",
            .{ encoded_bucket, encoded_name },
        );
        defer context.allocator.free(path);
        var response = self.request(context, .{
            .api = .storage,
            .method = "POST",
            .path = path,
            .body = payload.bytes,
            .content_type = "application/gzip",
        }) catch |err| {
            if (err != error.Conflict) return err;
            const adopted = self.readSourceObject(context, node, null) catch |read_err| {
                if (read_err == error.InvalidConfiguration or read_err == error.ProviderBug) return error.Conflict;
                return read_err;
            };
            return switch (adopted) {
                .absent => error.Conflict,
                .present => |present| present,
            };
        };
        defer response.deinit(context.allocator);
        return sourceObjectResultFromJson(context, node, response.body);
    }

    fn request(
        self: Handler,
        context: *provider_mod.OperationContext,
        request_value: client_mod.Request,
    ) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, request_value, &diagnostic);
    }
};

pub fn supports(node: resource.ResourceNode) bool {
    return kind(node) != null;
}

fn kind(node: resource.ResourceNode) ?Kind {
    if (std.mem.eql(u8, node.type_name, build_bucket_type)) return .build_bucket;
    if (std.mem.eql(u8, node.type_name, source_object_type)) return .source_object;
    return null;
}

fn bucketResultFromJson(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    body: []const u8,
) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const remote = asObject(parsed.value) orelse return error.ProviderBug;
    const name = try requiredJsonString(remote, "name");
    if (!std.mem.eql(u8, name, try requiredString(node.inputs, "name"))) return error.InvalidConfiguration;
    const remote_location = try requiredJsonString(remote, "location");
    const desired_location = try requiredString(node.inputs, "location");
    const location = if (std.ascii.eqlIgnoreCase(remote_location, desired_location)) desired_location else remote_location;
    const iam = asObject(remote.get("iamConfiguration") orelse return error.ProviderBug) orelse return error.ProviderBug;
    const uniform = if (asObject(iam.get("uniformBucketLevelAccess") orelse .null)) |settings|
        jsonBoolean(settings.get("enabled")) orelse false
    else
        false;
    const public_prevention = if (jsonString(iam.get("publicAccessPrevention"))) |setting|
        std.mem.eql(u8, setting, "enforced")
    else
        false;
    const versioning = if (asObject(remote.get("versioning") orelse .null)) |settings|
        jsonBoolean(settings.get("enabled")) orelse false
    else
        false;
    const age = lifecycleAge(remote) catch return error.ProviderBug;
    const fields = [_]value.Field{
        .{ .name = "lifecycle_age_days", .value = .{ .integer = age } },
        .{ .name = "location", .value = .{ .string = location } },
        .{ .name = "name", .value = .{ .string = name } },
        .{ .name = "project_id", .value = .{ .string = try requiredString(node.inputs, "project_id") } },
        .{ .name = "public_access_prevention", .value = .{ .boolean = public_prevention } },
        .{ .name = "uniform_bucket_level_access", .value = .{ .boolean = uniform } },
        .{ .name = "versioning", .value = .{ .boolean = versioning } },
    };
    const physical_id = try std.fmt.allocPrint(context.allocator, "buckets/{s}", .{name});
    defer context.allocator.free(physical_id);
    const outputs = [_]state.StateOutput{
        .{ .name = "name", .value = .{ .string = name } },
        .{ .name = "self_link", .value = .{ .string = try requiredJsonString(remote, "selfLink") } },
    };
    return provider_mod.ResourceResult.init(context.allocator, physical_id, .{ .object = &fields }, &outputs, null);
}

fn sourceObjectResultFromJson(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    body: []const u8,
) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const remote = asObject(parsed.value) orelse return error.ProviderBug;
    const bucket = try requiredJsonString(remote, "bucket");
    const desired_bucket = try resolveString(context, try requiredValue(node.inputs, "bucket"));
    const object_name = try requiredJsonString(remote, "name");
    const desired_name = try requiredString(node.inputs, "object_name");
    const generation = try requiredJsonString(remote, "generation");
    const remote_crc = try requiredJsonString(remote, "crc32c");
    const remote_size_text = try requiredJsonString(remote, "size");
    const remote_size = std.fmt.parseInt(u64, remote_size_text, 10) catch return error.ProviderBug;
    const expected_size = try requiredInteger(node.inputs, "size");
    if (!std.mem.eql(u8, bucket, desired_bucket) or
        !std.mem.eql(u8, object_name, desired_name) or
        !std.mem.eql(u8, remote_crc, try requiredString(node.inputs, "crc32c")) or
        expected_size < 0 or remote_size != @as(u64, @intCast(expected_size)) or
        !isGeneration(generation)) return error.InvalidConfiguration;
    const physical_id = try std.fmt.allocPrint(context.allocator, "gs://{s}/{s}#{s}", .{ bucket, object_name, generation });
    defer context.allocator.free(physical_id);
    const gs_uri = try std.fmt.allocPrint(context.allocator, "gs://{s}/{s}", .{ bucket, object_name });
    defer context.allocator.free(gs_uri);
    const outputs = [_]state.StateOutput{
        .{ .name = "bucket", .value = .{ .string = bucket } },
        .{ .name = "object_name", .value = .{ .string = object_name } },
        .{ .name = "generation", .value = .{ .string = generation } },
        .{ .name = "gs_uri", .value = .{ .string = gs_uri } },
        .{ .name = "source_digest", .value = .{ .string = try requiredString(node.inputs, "source_digest") } },
    };
    return provider_mod.ResourceResult.init(context.allocator, physical_id, node.inputs, &outputs, null);
}

fn bucketBodyAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, include_identity: bool) ProviderError![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root: std.json.ObjectMap = .empty;
    if (include_identity) {
        try root.put(arena, "name", .{ .string = try requiredString(node.inputs, "name") });
        try root.put(arena, "location", .{ .string = try requiredString(node.inputs, "location") });
    }
    var uniform: std.json.ObjectMap = .empty;
    try uniform.put(arena, "enabled", .{ .bool = true });
    var iam: std.json.ObjectMap = .empty;
    try iam.put(arena, "uniformBucketLevelAccess", .{ .object = uniform });
    try iam.put(arena, "publicAccessPrevention", .{ .string = "enforced" });
    try root.put(arena, "iamConfiguration", .{ .object = iam });
    var versioning: std.json.ObjectMap = .empty;
    try versioning.put(arena, "enabled", .{ .bool = true });
    try root.put(arena, "versioning", .{ .object = versioning });
    var action: std.json.ObjectMap = .empty;
    try action.put(arena, "type", .{ .string = "Delete" });
    var condition: std.json.ObjectMap = .empty;
    try condition.put(arena, "age", .{ .integer = try requiredInteger(node.inputs, "lifecycle_age_days") });
    var rule: std.json.ObjectMap = .empty;
    try rule.put(arena, "action", .{ .object = action });
    try rule.put(arena, "condition", .{ .object = condition });
    var rules = std.json.Array.init(arena);
    try rules.append(.{ .object = rule });
    var lifecycle: std.json.ObjectMap = .empty;
    try lifecycle.put(arena, "rule", .{ .array = rules });
    try root.put(arena, "lifecycle", .{ .object = lifecycle });
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = root }, .{}) catch return error.OutOfMemory;
}

fn verifyPayload(node: resource.ResourceNode, bytes: []const u8) ProviderError!void {
    const actual = storage.integrity(bytes);
    const expected_size = try requiredInteger(node.inputs, "size");
    if (expected_size < 0 or actual.size != @as(u64, @intCast(expected_size)) or
        !std.mem.eql(u8, actual.crc32c[0..], try requiredString(node.inputs, "crc32c")) or
        !std.mem.eql(u8, actual.sha256[0..], try requiredString(node.inputs, "source_digest"))) return error.InvalidConfiguration;
}

const SourceIdentity = struct {
    bucket: []const u8,
    object_name: []const u8,
    generation: ?[]const u8 = null,

    fn deinit(self: SourceIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.bucket);
        allocator.free(self.object_name);
        if (self.generation) |generation| allocator.free(generation);
    }
};

fn sourceIdentity(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    physical_override: ?[]const u8,
) ProviderError!SourceIdentity {
    const desired_bucket = try resolveString(context, try requiredValue(node.inputs, "bucket"));
    const desired_name = try requiredString(node.inputs, "object_name");
    if (physical_override == null) {
        const bucket = context.allocator.dupe(u8, desired_bucket) catch return error.OutOfMemory;
        errdefer context.allocator.free(bucket);
        const object_name = context.allocator.dupe(u8, desired_name) catch return error.OutOfMemory;
        return .{ .bucket = bucket, .object_name = object_name };
    }
    const physical_id = physical_override.?;
    if (!std.mem.startsWith(u8, physical_id, "gs://")) return error.InvalidConfiguration;
    const separator = std.mem.lastIndexOfScalar(u8, physical_id, '#') orelse return error.InvalidConfiguration;
    const path = physical_id["gs://".len..separator];
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return error.InvalidConfiguration;
    const bucket = path[0..slash];
    const object_name = path[slash + 1 ..];
    const generation = physical_id[separator + 1 ..];
    if (!std.mem.eql(u8, bucket, desired_bucket) or !std.mem.eql(u8, object_name, desired_name) or !isGeneration(generation)) {
        return error.InvalidConfiguration;
    }
    const bucket_copy = context.allocator.dupe(u8, bucket) catch return error.OutOfMemory;
    errdefer context.allocator.free(bucket_copy);
    const object_copy = context.allocator.dupe(u8, object_name) catch return error.OutOfMemory;
    errdefer context.allocator.free(object_copy);
    const generation_copy = context.allocator.dupe(u8, generation) catch return error.OutOfMemory;
    return .{ .bucket = bucket_copy, .object_name = object_copy, .generation = generation_copy };
}

fn validateSourcePhysicalIdAlloc(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    physical_id: []const u8,
) ProviderError![]const u8 {
    const identity = try sourceIdentity(context, node, physical_id);
    defer identity.deinit(context.allocator);
    return context.allocator.dupe(u8, physical_id) catch return error.OutOfMemory;
}

fn sourceObjectGetPathAlloc(
    allocator: std.mem.Allocator,
    bucket: []const u8,
    object_name: []const u8,
    generation: ?[]const u8,
) ProviderError![]const u8 {
    const encoded_bucket = try percentEncodeAlloc(allocator, bucket);
    defer allocator.free(encoded_bucket);
    const encoded_name = try percentEncodeAlloc(allocator, object_name);
    defer allocator.free(encoded_name);
    return if (generation) |present|
        std.fmt.allocPrint(allocator, "/storage/v1/b/{s}/o/{s}?generation={s}", .{ encoded_bucket, encoded_name, present }) catch return error.OutOfMemory
    else
        std.fmt.allocPrint(allocator, "/storage/v1/b/{s}/o/{s}", .{ encoded_bucket, encoded_name }) catch return error.OutOfMemory;
}

fn bucketPhysicalIdAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "buckets/{s}", .{try requiredString(node.inputs, "name")}) catch return error.OutOfMemory;
}

fn sameBucketIdentity(desired: value.Value, observed: value.Value) bool {
    const desired_project = requiredString(desired, "project_id") catch return false;
    const observed_project = requiredString(observed, "project_id") catch return false;
    const desired_name = requiredString(desired, "name") catch return false;
    const observed_name = requiredString(observed, "name") catch return false;
    const desired_location = requiredString(desired, "location") catch return false;
    const observed_location = requiredString(observed, "location") catch return false;
    return std.mem.eql(u8, desired_project, observed_project) and
        std.mem.eql(u8, desired_name, observed_name) and
        std.ascii.eqlIgnoreCase(desired_location, observed_location);
}

fn lifecycleAge(remote: std.json.ObjectMap) !i64 {
    const lifecycle = asObject(remote.get("lifecycle") orelse return 0) orelse return 0;
    const rules = asArray(lifecycle.get("rule") orelse return 0) orelse return 0;
    for (rules.items) |rule_value| {
        const rule = asObject(rule_value) orelse continue;
        const action = asObject(rule.get("action") orelse continue) orelse continue;
        const action_type = jsonString(action.get("type")) orelse continue;
        if (!std.mem.eql(u8, action_type, "Delete")) continue;
        const condition = asObject(rule.get("condition") orelse continue) orelse continue;
        return jsonInteger(condition.get("age")) orelse 0;
    }
    return 0;
}

fn percentEncodeAlloc(allocator: std.mem.Allocator, input: []const u8) ProviderError![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (input) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try result.append(allocator, byte);
        } else {
            try result.appendSlice(allocator, &.{ '%', hex[byte >> 4], hex[byte & 0x0f] });
        }
    }
    return result.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn requiredValue(input: value.Value, name: []const u8) ProviderError!value.Value {
    const fields = switch (input) {
        .object => |fields| fields,
        else => return error.InvalidConfiguration,
    };
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return error.InvalidConfiguration;
}

fn requiredString(input: value.Value, name: []const u8) ProviderError![]const u8 {
    return switch (try requiredValue(input, name)) {
        .string => |string| string,
        else => error.InvalidConfiguration,
    };
}

fn requiredInteger(input: value.Value, name: []const u8) ProviderError!i64 {
    return switch (try requiredValue(input, name)) {
        .integer => |integer| integer,
        else => error.InvalidConfiguration,
    };
}

fn resolveString(context: *provider_mod.OperationContext, input: value.Value) ProviderError![]const u8 {
    return switch (input) {
        .string => |string| string,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}

fn requiredJsonString(object: std.json.ObjectMap, name: []const u8) ProviderError![]const u8 {
    return jsonString(object.get(name)) orelse error.ProviderBug;
}

fn asObject(json_value: std.json.Value) ?std.json.ObjectMap {
    return switch (json_value) {
        .object => |object| object,
        else => null,
    };
}

fn asArray(json_value: std.json.Value) ?std.json.Array {
    return switch (json_value) {
        .array => |array| array,
        else => null,
    };
}

fn jsonString(json_value: ?std.json.Value) ?[]const u8 {
    const present = json_value orelse return null;
    return switch (present) {
        .string => |string| string,
        else => null,
    };
}

fn jsonBoolean(json_value: ?std.json.Value) ?bool {
    const present = json_value orelse return null;
    return switch (present) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn jsonInteger(json_value: ?std.json.Value) ?i64 {
    const present = json_value orelse return null;
    return switch (present) {
        .integer => |integer| integer,
        else => null,
    };
}

fn isGeneration(generation: []const u8) bool {
    if (generation.len == 0) return false;
    for (generation) |character| if (!std.ascii.isDigit(character)) return false;
    return true;
}
