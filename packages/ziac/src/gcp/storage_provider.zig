const std = @import("std");
const client_mod = @import("client.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const storage = @import("storage.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;
const bucket_type = "gcp.storage.Bucket";
const bucket_iam_member_type = "gcp.storage.BucketIamMember";
const build_bucket_type = "gcp.storage.BuildBucket";
const source_object_type = "gcp.storage.SourceObject";

const Kind = enum { bucket, bucket_iam_member, build_bucket, source_object };

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

    pub fn initTake(
        allocator: std.mem.Allocator,
        bytes: []u8,
        observer: ?PayloadDeinitObserver,
    ) Payload {
        return .{ .allocator = allocator, .bytes = bytes, .observer = observer };
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
    iam_conflict_retries: usize = 3,

    pub fn read(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_override: ?[]const u8,
    ) ProviderError!provider_mod.ReadResult {
        return switch (kind(node) orelse return error.InvalidConfiguration) {
            .bucket, .build_bucket => self.readBucket(context, node, physical_override),
            .bucket_iam_member => self.readBucketIamMember(context, node, physical_override),
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
            .bucket_iam_member, .source_object => .replace,
            .bucket, .build_bucket => if (sameBucketIdentity(node.inputs, observed.observed_inputs)) .update else .replace,
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
            .bucket, .build_bucket => self.createBucket(context, node),
            .bucket_iam_member => self.ensureBucketIamMember(context, node, true),
            .source_object => self.createSourceObject(context, node),
        };
    }

    pub fn update(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!provider_mod.ResourceResult {
        const resource_kind = kind(node) orelse return error.InvalidConfiguration;
        if (resource_kind != .bucket and resource_kind != .build_bucket) return error.InvalidConfiguration;
        const expected = try bucketPhysicalIdAlloc(context.allocator, node);
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        const bucket = try requiredString(node.inputs, "name");
        const encoded_bucket = try percentEncodeAlloc(context.allocator, bucket);
        defer context.allocator.free(encoded_bucket);
        const path = if (resource_kind == .bucket) blk: {
            const metageneration = try self.readBucketMetageneration(context, encoded_bucket);
            defer context.allocator.free(metageneration);
            break :blk try std.fmt.allocPrint(
                context.allocator,
                "/storage/v1/b/{s}?ifMetagenerationMatch={s}",
                .{ encoded_bucket, metageneration },
            );
        } else try std.fmt.allocPrint(context.allocator, "/storage/v1/b/{s}", .{encoded_bucket});
        defer context.allocator.free(path);
        const body = try bucketBodyAlloc(context.allocator, node, false);
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .storage, .method = "PATCH", .path = path, .body = body });
        defer response.deinit(context.allocator);
        return bucketResultFromJson(context, node, response.body);
    }

    pub fn delete(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!void {
        try context.checkActive();
        const resource_kind = kind(node) orelse return error.InvalidConfiguration;
        const expected = switch (resource_kind) {
            .bucket, .build_bucket => try bucketPhysicalIdAlloc(context.allocator, node),
            .bucket_iam_member => try bucketIamPhysicalIdAlloc(context, node),
            .source_object => try validateSourcePhysicalIdAlloc(context, node, physical_id),
        };
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        switch (resource_kind) {
            .build_bucket, .source_object => {},
            .bucket => {
                if (node.lifecycle.retain_on_delete) return;
                const bucket = try requiredString(node.inputs, "name");
                const encoded_bucket = try percentEncodeAlloc(context.allocator, bucket);
                defer context.allocator.free(encoded_bucket);
                const path = try std.fmt.allocPrint(context.allocator, "/storage/v1/b/{s}", .{encoded_bucket});
                defer context.allocator.free(path);
                var response = self.request(context, .{ .api = .storage, .method = "DELETE", .path = path }) catch |err| {
                    if (err == error.NotFound) return;
                    return err;
                };
                response.deinit(context.allocator);
            },
            .bucket_iam_member => {
                var removed = try self.ensureBucketIamMember(context, node, false);
                removed.deinit();
            },
        }
    }

    fn readBucket(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_override: ?[]const u8,
    ) ProviderError!provider_mod.ReadResult {
        const expected = try bucketPhysicalIdAlloc(context.allocator, node);
        defer context.allocator.free(expected);
        if (physical_override) |physical_id| {
            if (!bucketPhysicalIdMatches(node, physical_id)) return error.InvalidConfiguration;
        }
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

    fn readBucketMetageneration(
        self: Handler,
        context: *provider_mod.OperationContext,
        encoded_bucket: []const u8,
    ) ProviderError![]const u8 {
        const path = try std.fmt.allocPrint(context.allocator, "/storage/v1/b/{s}", .{encoded_bucket});
        defer context.allocator.free(path);
        var response = try self.request(context, .{ .api = .storage, .method = "GET", .path = path });
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const remote = asObject(parsed.value) orelse return error.ProviderBug;
        const metageneration = try requiredJsonString(remote, "metageneration");
        return context.allocator.dupe(u8, metageneration) catch return error.OutOfMemory;
    }

    fn readBucketIamMember(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_override: ?[]const u8,
    ) ProviderError!provider_mod.ReadResult {
        if (physical_override) |physical_id| {
            const expected = try bucketIamPhysicalIdAlloc(context, node);
            defer context.allocator.free(expected);
            if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        }
        const role = try requiredString(node.inputs, "role");
        const member = try requiredString(node.inputs, "member");
        var policy = try self.getBucketPolicy(context, node);
        defer policy.deinit();
        if (!policyHasMember(policy.value, role, member)) return .absent;
        return .{ .present = try bucketIamMemberResult(context, node) };
    }

    fn ensureBucketIamMember(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        should_exist: bool,
    ) ProviderError!provider_mod.ResourceResult {
        const role = try requiredString(node.inputs, "role");
        const member = try requiredString(node.inputs, "member");
        var conflicts: usize = 0;
        while (true) {
            try context.checkActive();
            var policy = try self.getBucketPolicy(context, node);
            defer policy.deinit();
            const changed = try mutatePolicy(&policy, role, member, should_exist);
            if (!changed) return bucketIamMemberResult(context, node);
            self.setBucketPolicy(context, node, policy.value) catch |err| {
                if (err == error.Conflict and conflicts < self.iam_conflict_retries) {
                    conflicts += 1;
                    continue;
                }
                return err;
            };
            return bucketIamMemberResult(context, node);
        }
    }

    fn getBucketPolicy(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!std.json.Parsed(std.json.Value) {
        const bucket = try resolveString(context, try requiredValue(node.inputs, "bucket"));
        const encoded_bucket = try percentEncodeAlloc(context.allocator, bucket);
        defer context.allocator.free(encoded_bucket);
        const path = try std.fmt.allocPrint(
            context.allocator,
            "/storage/v1/b/{s}/iam?optionsRequestedPolicyVersion=3",
            .{encoded_bucket},
        );
        defer context.allocator.free(path);
        var response = try self.request(context, .{ .api = .storage, .method = "GET", .path = path });
        defer response.deinit(context.allocator);
        return std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
    }

    fn setBucketPolicy(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        policy: std.json.Value,
    ) ProviderError!void {
        const bucket = try resolveString(context, try requiredValue(node.inputs, "bucket"));
        const encoded_bucket = try percentEncodeAlloc(context.allocator, bucket);
        defer context.allocator.free(encoded_bucket);
        const path = try std.fmt.allocPrint(context.allocator, "/storage/v1/b/{s}/iam", .{encoded_bucket});
        defer context.allocator.free(path);
        const body = std.json.Stringify.valueAlloc(context.allocator, policy, .{}) catch return error.OutOfMemory;
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .storage, .method = "PUT", .path = path, .body = body });
        response.deinit(context.allocator);
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
    if (std.mem.eql(u8, node.type_name, bucket_type)) return .bucket;
    if (std.mem.eql(u8, node.type_name, bucket_iam_member_type)) return .bucket_iam_member;
    if (std.mem.eql(u8, node.type_name, build_bucket_type)) return .build_bucket;
    if (std.mem.eql(u8, node.type_name, source_object_type)) return .source_object;
    return null;
}

fn bucketResultFromJson(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    body: []const u8,
) ProviderError!provider_mod.ResourceResult {
    return switch (kind(node) orelse return error.InvalidConfiguration) {
        .bucket => generalBucketResultFromJson(context, node, body),
        .build_bucket => buildBucketResultFromJson(context, node, body),
        else => error.InvalidConfiguration,
    };
}

fn buildBucketResultFromJson(
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

fn generalBucketResultFromJson(
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
    const public_prevention = jsonString(iam.get("publicAccessPrevention")) orelse "inherited";
    const versioning = if (asObject(remote.get("versioning") orelse .null)) |settings|
        jsonBoolean(settings.get("enabled")) orelse false
    else
        false;
    const soft_delete = if (asObject(remote.get("softDeletePolicy") orelse .null)) |settings|
        jsonInt64(settings.get("retentionDurationSeconds")) orelse 0
    else
        0;
    const retention = if (asObject(remote.get("retentionPolicy") orelse .null)) |settings|
        jsonInt64(settings.get("retentionPeriod")) orelse 0
    else
        0;
    const kms_key = if (asObject(remote.get("encryption") orelse .null)) |settings|
        jsonString(settings.get("defaultKmsKeyName")) orelse ""
    else
        "";
    const delete_after_days = lifecycleAge(remote) catch return error.ProviderBug;
    const label_object = asObject(remote.get("labels") orelse .{ .object = .empty }) orelse return error.ProviderBug;
    const label_fields = try jsonFieldsAlloc(context.allocator, label_object);
    defer context.allocator.free(label_fields);
    const fields = [_]value.Field{
        .{ .name = "default_kms_key_name", .value = .{ .string = kms_key } },
        .{ .name = "delete_after_days", .value = .{ .integer = delete_after_days } },
        .{ .name = "labels", .value = .{ .object = label_fields } },
        .{ .name = "location", .value = .{ .string = location } },
        .{ .name = "name", .value = .{ .string = name } },
        .{ .name = "project_id", .value = .{ .string = try requiredString(node.inputs, "project_id") } },
        .{ .name = "public_access_prevention", .value = .{ .string = public_prevention } },
        .{ .name = "retention_period_seconds", .value = .{ .integer = retention } },
        .{ .name = "soft_delete_retention_seconds", .value = .{ .integer = soft_delete } },
        .{ .name = "storage_class", .value = .{ .string = try requiredJsonString(remote, "storageClass") } },
        .{ .name = "uniform_bucket_level_access", .value = .{ .boolean = uniform } },
        .{ .name = "versioning", .value = .{ .boolean = versioning } },
    };
    const physical_id = try std.fmt.allocPrint(context.allocator, "buckets/{s}", .{name});
    defer context.allocator.free(physical_id);
    const url = try std.fmt.allocPrint(context.allocator, "gs://{s}", .{name});
    defer context.allocator.free(url);
    const outputs = [_]state.StateOutput{
        .{ .name = "metageneration", .value = .{ .string = try requiredJsonString(remote, "metageneration") } },
        .{ .name = "name", .value = .{ .string = name } },
        .{ .name = "self_link", .value = .{ .string = try requiredJsonString(remote, "selfLink") } },
        .{ .name = "url", .value = .{ .string = url } },
    };
    return provider_mod.ResourceResult.init(context.allocator, physical_id, .{ .object = &fields }, &outputs, null);
}

fn bucketIamMemberResult(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
) ProviderError!provider_mod.ResourceResult {
    const physical_id = try bucketIamPhysicalIdAlloc(context, node);
    defer context.allocator.free(physical_id);
    const bucket = try resolveString(context, try requiredValue(node.inputs, "bucket"));
    const role = try requiredString(node.inputs, "role");
    const member = try requiredString(node.inputs, "member");
    const binding_id = try std.fmt.allocPrint(context.allocator, "{s}|{s}|{s}", .{ bucket, role, member });
    defer context.allocator.free(binding_id);
    const outputs = [_]state.StateOutput{
        .{ .name = "binding_id", .value = .{ .string = binding_id } },
    };
    return provider_mod.ResourceResult.init(context.allocator, physical_id, node.inputs, &outputs, null);
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
    if (kind(node) == .bucket) return generalBucketBodyAlloc(allocator, node, include_identity);
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

fn generalBucketBodyAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, include_identity: bool) ProviderError![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root: std.json.ObjectMap = .empty;
    if (include_identity) {
        try root.put(arena, "name", .{ .string = try requiredString(node.inputs, "name") });
        try root.put(arena, "location", .{ .string = try requiredString(node.inputs, "location") });
    }
    try root.put(arena, "storageClass", .{ .string = try requiredString(node.inputs, "storage_class") });

    var uniform: std.json.ObjectMap = .empty;
    try uniform.put(arena, "enabled", .{ .bool = try requiredBoolean(node.inputs, "uniform_bucket_level_access") });
    var iam: std.json.ObjectMap = .empty;
    try iam.put(arena, "uniformBucketLevelAccess", .{ .object = uniform });
    try iam.put(arena, "publicAccessPrevention", .{ .string = try requiredString(node.inputs, "public_access_prevention") });
    try root.put(arena, "iamConfiguration", .{ .object = iam });

    var versioning: std.json.ObjectMap = .empty;
    try versioning.put(arena, "enabled", .{ .bool = try requiredBoolean(node.inputs, "versioning") });
    try root.put(arena, "versioning", .{ .object = versioning });

    var soft_delete: std.json.ObjectMap = .empty;
    try soft_delete.put(arena, "retentionDurationSeconds", .{ .integer = try requiredInteger(node.inputs, "soft_delete_retention_seconds") });
    try root.put(arena, "softDeletePolicy", .{ .object = soft_delete });

    const retention_period = try requiredInteger(node.inputs, "retention_period_seconds");
    if (retention_period > 0) {
        var retention: std.json.ObjectMap = .empty;
        try retention.put(arena, "retentionPeriod", .{ .integer = retention_period });
        try root.put(arena, "retentionPolicy", .{ .object = retention });
    } else if (!include_identity) {
        try root.put(arena, "retentionPolicy", .null);
    }

    var rules = std.json.Array.init(arena);
    const delete_after_days = try requiredInteger(node.inputs, "delete_after_days");
    if (delete_after_days > 0) {
        var action: std.json.ObjectMap = .empty;
        try action.put(arena, "type", .{ .string = "Delete" });
        var condition: std.json.ObjectMap = .empty;
        try condition.put(arena, "age", .{ .integer = delete_after_days });
        var rule: std.json.ObjectMap = .empty;
        try rule.put(arena, "action", .{ .object = action });
        try rule.put(arena, "condition", .{ .object = condition });
        try rules.append(.{ .object = rule });
    }
    var lifecycle: std.json.ObjectMap = .empty;
    try lifecycle.put(arena, "rule", .{ .array = rules });
    try root.put(arena, "lifecycle", .{ .object = lifecycle });

    const kms_key = try requiredString(node.inputs, "default_kms_key_name");
    if (kms_key.len > 0) {
        var encryption: std.json.ObjectMap = .empty;
        try encryption.put(arena, "defaultKmsKeyName", .{ .string = kms_key });
        try root.put(arena, "encryption", .{ .object = encryption });
    } else if (!include_identity) {
        var encryption: std.json.ObjectMap = .empty;
        try encryption.put(arena, "defaultKmsKeyName", .null);
        try root.put(arena, "encryption", .{ .object = encryption });
    }
    const labels = try requiredValue(node.inputs, "labels");
    const label_fields = switch (labels) {
        .object => |fields| fields,
        else => return error.InvalidConfiguration,
    };
    var label_object: std.json.ObjectMap = .empty;
    for (label_fields) |field| {
        const label_value = switch (field.value) {
            .string => |text| text,
            else => return error.InvalidConfiguration,
        };
        try label_object.put(arena, field.name, .{ .string = label_value });
    }
    try root.put(arena, "labels", .{ .object = label_object });
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

fn bucketPhysicalIdMatches(node: resource.ResourceNode, physical_id: []const u8) bool {
    const name = requiredString(node.inputs, "name") catch return false;
    if (std.mem.startsWith(u8, physical_id, "buckets/")) {
        return std.mem.eql(u8, physical_id["buckets/".len..], name);
    }
    if (std.mem.startsWith(u8, physical_id, "gs://")) {
        return std.mem.eql(u8, physical_id["gs://".len..], name);
    }
    return false;
}

fn bucketIamPhysicalIdAlloc(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
) ProviderError![]const u8 {
    const bucket = try resolveString(context, try requiredValue(node.inputs, "bucket"));
    const name = try requiredString(node.inputs, "name");
    return std.fmt.allocPrint(context.allocator, "buckets/{s}/iam/{s}", .{ bucket, name }) catch return error.OutOfMemory;
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

fn requiredBoolean(input: value.Value, name: []const u8) ProviderError!bool {
    return switch (try requiredValue(input, name)) {
        .boolean => |boolean| boolean,
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

fn jsonInt64(json_value: ?std.json.Value) ?i64 {
    const present = json_value orelse return null;
    return switch (present) {
        .integer => |integer| integer,
        .string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
}

fn jsonFieldsAlloc(allocator: std.mem.Allocator, object: std.json.ObjectMap) ProviderError![]value.Field {
    const fields = allocator.alloc(value.Field, object.count()) catch return error.OutOfMemory;
    var iterator = object.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| : (index += 1) {
        fields[index] = .{
            .name = entry.key_ptr.*,
            .value = .{ .string = jsonString(entry.value_ptr.*) orelse return error.ProviderBug },
        };
    }
    return fields;
}

fn policyHasMember(policy: std.json.Value, role: []const u8, member: []const u8) bool {
    const object = asObject(policy) orelse return false;
    const bindings_value = object.get("bindings") orelse return false;
    const bindings = switch (bindings_value) {
        .array => |array| array.items,
        else => return false,
    };
    for (bindings) |binding_value| {
        const binding = asObject(binding_value) orelse continue;
        if (binding.get("condition") != null) continue;
        const binding_role = jsonString(binding.get("role")) orelse continue;
        if (!std.mem.eql(u8, binding_role, role)) continue;
        const members_value = binding.get("members") orelse continue;
        const members = switch (members_value) {
            .array => |array| array.items,
            else => continue,
        };
        for (members) |member_value| {
            const candidate = jsonString(member_value) orelse continue;
            if (std.mem.eql(u8, candidate, member)) return true;
        }
    }
    return false;
}

fn mutatePolicy(
    parsed: *std.json.Parsed(std.json.Value),
    role: []const u8,
    member: []const u8,
    should_exist: bool,
) ProviderError!bool {
    const allocator = parsed.arena.allocator();
    const root = switch (parsed.value) {
        .object => |*object| object,
        else => return error.ProviderBug,
    };
    var bindings_value = root.getPtr("bindings");
    if (bindings_value == null) {
        if (!should_exist) return false;
        try root.put(allocator, "bindings", .{ .array = std.json.Array.init(allocator) });
        bindings_value = root.getPtr("bindings");
    }
    const bindings = switch (bindings_value.?.*) {
        .array => |*array| array,
        else => return error.ProviderBug,
    };

    for (bindings.items, 0..) |*binding_value, binding_index| {
        const binding = switch (binding_value.*) {
            .object => |*object| object,
            else => continue,
        };
        if (binding.get("condition") != null) continue;
        const binding_role = jsonString(binding.get("role")) orelse continue;
        if (!std.mem.eql(u8, binding_role, role)) continue;
        const members_value = binding.getPtr("members") orelse continue;
        const members = switch (members_value.*) {
            .array => |*array| array,
            else => continue,
        };
        for (members.items, 0..) |member_value, member_index| {
            const candidate = jsonString(member_value) orelse continue;
            if (!std.mem.eql(u8, candidate, member)) continue;
            if (should_exist) return false;
            _ = members.orderedRemove(member_index);
            if (members.items.len == 0) _ = bindings.orderedRemove(binding_index);
            return true;
        }
        if (!should_exist) return false;
        try members.append(.{ .string = member });
        return true;
    }

    if (!should_exist) return false;
    var members = std.json.Array.init(allocator);
    try members.append(.{ .string = member });
    var binding: std.json.ObjectMap = .empty;
    try binding.put(allocator, "role", .{ .string = role });
    try binding.put(allocator, "members", .{ .array = members });
    try bindings.append(.{ .object = binding });
    return true;
}

fn isGeneration(generation: []const u8) bool {
    if (generation.len == 0) return false;
    for (generation) |character| if (!std.ascii.isDigit(character)) return false;
    return true;
}
