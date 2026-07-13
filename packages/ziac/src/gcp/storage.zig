const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    ConflictingLifecyclePolicy,
    DuplicateField,
    InvalidBucket,
    InvalidContentType,
    InvalidCorsOrigin,
    InvalidCrc32c,
    InvalidDigest,
    InvalidIamCondition,
    InvalidLifecycleAge,
    InvalidLifecycleRule,
    InvalidName,
    InvalidObjectName,
    InvalidKmsKey,
    InvalidLocation,
    InvalidMember,
    InvalidRegion,
    InvalidRetention,
    InvalidRole,
    InvalidSize,
    InvalidSoftDeleteRetention,
    InvalidSourcePath,
    OutputNotKnown,
};

pub const Integrity = struct {
    size: u64,
    crc32c: [8]u8,
    sha256: [64]u8,
};

pub fn integrity(bytes: []const u8) Integrity {
    const checksum = std.hash.crc.Crc32Iscsi.hash(bytes);
    var checksum_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &checksum_bytes, checksum, .big);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var encoded: [8]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&encoded, &checksum_bytes);
    return .{
        .size = bytes.len,
        .crc32c = encoded,
        .sha256 = std.fmt.bytesToHex(digest, .lower),
    };
}

pub const StorageClass = enum {
    standard,
    nearline,
    coldline,
    archive,

    pub fn apiName(self: StorageClass) []const u8 {
        return switch (self) {
            .standard => "STANDARD",
            .nearline => "NEARLINE",
            .coldline => "COLDLINE",
            .archive => "ARCHIVE",
        };
    }
};

pub const PublicAccessPrevention = enum {
    inherited,
    enforced,

    pub fn apiName(self: PublicAccessPrevention) []const u8 {
        return @tagName(self);
    }
};

pub const LifecycleAction = union(enum) {
    delete,
    set_storage_class: StorageClass,
    abort_incomplete_multipart_upload,
};

pub const LifecycleCondition = struct {
    age_days: u32 = 0,
    created_before: ?[]const u8 = null,
    days_since_noncurrent_time: u32 = 0,
    is_live: ?bool = null,
    matches_prefixes: []const []const u8 = &.{},
    matches_suffixes: []const []const u8 = &.{},
    matches_storage_classes: []const StorageClass = &.{},
    num_newer_versions: u32 = 0,
};

pub const LifecycleRule = struct {
    action: LifecycleAction,
    condition: LifecycleCondition,
};

pub const CorsMethod = enum {
    get,
    head,
    put,
    post,
    delete,
    options,
    any,

    pub fn apiName(self: CorsMethod) []const u8 {
        return switch (self) {
            .get => "GET",
            .head => "HEAD",
            .put => "PUT",
            .post => "POST",
            .delete => "DELETE",
            .options => "OPTIONS",
            .any => "*",
        };
    }
};

pub const CorsRule = struct {
    origins: []const []const u8,
    methods: []const CorsMethod,
    response_headers: []const []const u8 = &.{},
    max_age_seconds: u32 = 3600,
};

pub const BucketArgs = struct {
    name: []const u8,
    location: []const u8,
    storage_class: StorageClass = .standard,
    uniform_bucket_level_access: bool = true,
    public_access_prevention: PublicAccessPrevention = .enforced,
    versioning: bool = false,
    soft_delete_retention_seconds: u64 = 7 * 24 * 60 * 60,
    retention_period_seconds: u64 = 0,
    delete_after_days: u32 = 0,
    lifecycle_rules: []const LifecycleRule = &.{},
    cors: []const CorsRule = &.{},
    default_kms_key_name: ?[]const u8 = null,
    force_destroy: bool = false,
    retain_on_delete: bool = true,
};

pub const Bucket = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
        pub const Url = output.Descriptor("url", []const u8, .public);
        pub const Metageneration = output.Descriptor("metageneration", []const u8, .public);

        pub fn field(comptime name: []const u8) type {
            if (std.mem.eql(u8, name, "name")) return Name;
            if (std.mem.eql(u8, name, "self_link")) return SelfLink;
            if (std.mem.eql(u8, name, "url")) return Url;
            if (std.mem.eql(u8, name, "metageneration")) return Metageneration;
            @compileError("ZIAC120 unknown gcp.storage.Bucket output field: " ++ name);
        }
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    self_link: Outputs.SelfLink.OutputType,
    url: Outputs.Url.OutputType,
    metageneration: Outputs.Metageneration.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: BucketArgs,
    ) BuildError!Bucket {
        try provider.validate();
        if (!isValidBucket(args.name)) return error.InvalidBucket;
        if (!isValidLocation(args.location)) return error.InvalidLocation;
        if (!isValidSoftDeleteRetention(args.soft_delete_retention_seconds)) return error.InvalidSoftDeleteRetention;
        if (args.retention_period_seconds > std.math.maxInt(i64)) return error.InvalidRetention;
        if (args.delete_after_days > 36_500) return error.InvalidLifecycleAge;
        if (args.delete_after_days > 0 and args.lifecycle_rules.len > 0) return error.ConflictingLifecyclePolicy;
        try validateLifecycleRules(args.lifecycle_rules);
        try validateCorsRules(args.cors);
        const kms_key_name = args.default_kms_key_name orelse "";
        if (kms_key_name.len > 0 and !isKmsKeyName(kms_key_name)) return error.InvalidKmsKey;

        const labels = try labelValueAlloc(allocator, provider.labels);
        defer allocator.free(labels.object);
        var lifecycle_rules = try lifecycleRulesValueAlloc(allocator, args.lifecycle_rules);
        defer lifecycle_rules.deinit(allocator);
        var cors = try corsRulesValueAlloc(allocator, args.cors);
        defer cors.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "cors", .value = cors },
            .{ .name = "default_kms_key_name", .value = .{ .string = kms_key_name } },
            .{ .name = "delete_after_days", .value = .{ .integer = args.delete_after_days } },
            .{ .name = "force_destroy", .value = .{ .boolean = args.force_destroy } },
            .{ .name = "labels", .value = labels },
            .{ .name = "lifecycle_rules", .value = lifecycle_rules },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "public_access_prevention", .value = .{ .string = args.public_access_prevention.apiName() } },
            .{ .name = "retention_period_seconds", .value = .{ .integer = @intCast(args.retention_period_seconds) } },
            .{ .name = "soft_delete_retention_seconds", .value = .{ .integer = @intCast(args.soft_delete_retention_seconds) } },
            .{ .name = "storage_class", .value = .{ .string = args.storage_class.apiName() } },
            .{ .name = "uniform_bucket_level_access", .value = .{ .boolean = args.uniform_bucket_level_access } },
            .{ .name = "versioning", .value = .{ .boolean = args.versioning } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.storage.Bucket.{s}", .{args.name});
        defer allocator.free(id);
        const node = try buildNodeWithLifecycle(allocator, id, "gcp.storage.Bucket", args.name, &fields, .{
            .retain_on_delete = args.retain_on_delete,
            .operation_timeout_millis = 30 * 60 * 1000,
        });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .self_link = Outputs.SelfLink.fromResource(node.id),
            .url = Outputs.Url.fromResource(node.id),
            .metageneration = Outputs.Metageneration.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Bucket, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const IamCondition = struct {
    title: []const u8,
    description: []const u8 = "",
    expression: []const u8,
};

pub const BucketIamMemberArgs = struct {
    name: []const u8,
    bucket: output.Output([]const u8, .public),
    role: []const u8,
    member: []const u8,
    condition: ?IamCondition = null,
};

pub const BucketIamMember = struct {
    pub const Outputs = struct {
        pub const BindingId = output.Descriptor("binding_id", []const u8, .public);

        pub fn field(comptime name: []const u8) type {
            if (std.mem.eql(u8, name, "binding_id")) return BindingId;
            @compileError("ZIAC120 unknown gcp.storage.BucketIamMember output field: " ++ name);
        }
    };

    node: resource.ResourceNode,
    binding_id: Outputs.BindingId.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: BucketIamMemberArgs,
    ) BuildError!BucketIamMember {
        try provider.validate();
        try validateName(args.name);
        if (!std.mem.startsWith(u8, args.role, "roles/storage.") or args.role.len <= "roles/storage.".len) return error.InvalidRole;
        if (!isValidIamMember(args.member)) return error.InvalidMember;
        if (args.condition) |condition| try validateIamCondition(args.member, condition);
        const condition_title = if (args.condition) |condition| condition.title else "";
        const condition_description = if (args.condition) |condition| condition.description else "";
        const condition_expression = if (args.condition) |condition| condition.expression else "";
        const fields = [_]value.Field{
            .{ .name = "bucket", .value = try bucketValue(args.bucket) },
            .{ .name = "condition_description", .value = .{ .string = condition_description } },
            .{ .name = "condition_expression", .value = .{ .string = condition_expression } },
            .{ .name = "condition_title", .value = .{ .string = condition_title } },
            .{ .name = "member", .value = .{ .string = args.member } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "role", .value = .{ .string = args.role } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.storage.BucketIamMember.{s}", .{args.name});
        defer allocator.free(id);
        const node = try buildNodeWithLifecycle(allocator, id, "gcp.storage.BucketIamMember", args.name, &fields, .{});
        return .{ .node = node, .binding_id = Outputs.BindingId.fromResource(node.id) };
    }

    pub fn deinit(self: *BucketIamMember, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const BuildBucketArgs = struct {
    name: []const u8,
    location: []const u8,
    lifecycle_age_days: u32 = 30,
};

pub const BuildBucket = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);

        pub fn field(comptime name: []const u8) type {
            if (std.mem.eql(u8, name, "name")) return Name;
            if (std.mem.eql(u8, name, "self_link")) return SelfLink;
            @compileError("ZIAC120 unknown gcp.storage.BuildBucket output field: " ++ name);
        }
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    self_link: Outputs.SelfLink.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: BuildBucketArgs,
    ) BuildError!BuildBucket {
        try provider.validate();
        if (!isValidBucket(args.name)) return error.InvalidBucket;
        if (!isConfiguredRegion(provider, args.location)) return error.InvalidRegion;
        if (args.lifecycle_age_days == 0 or args.lifecycle_age_days > 3650) return error.InvalidLifecycleAge;
        const fields = [_]value.Field{
            .{ .name = "lifecycle_age_days", .value = .{ .integer = args.lifecycle_age_days } },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "public_access_prevention", .value = .{ .boolean = true } },
            .{ .name = "uniform_bucket_level_access", .value = .{ .boolean = true } },
            .{ .name = "versioning", .value = .{ .boolean = true } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.storage.BuildBucket.{s}", .{args.name});
        defer allocator.free(id);
        const node = try buildNode(allocator, id, "gcp.storage.BuildBucket", args.name, &fields);
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .self_link = Outputs.SelfLink.fromResource(node.id),
        };
    }

    pub fn deinit(self: *BuildBucket, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const SourceObjectArgs = struct {
    name: []const u8,
    bucket: output.Output([]const u8, .public),
    object_name: []const u8,
    source_path: []const u8,
    source_digest: []const u8,
    size: u64,
    crc32c: []const u8,
};

pub const SourceObject = struct {
    pub const Outputs = struct {
        pub const Bucket = output.Descriptor("bucket", []const u8, .public);
        pub const ObjectName = output.Descriptor("object_name", []const u8, .public);
        pub const Generation = output.Descriptor("generation", []const u8, .public);
        pub const GsUri = output.Descriptor("gs_uri", []const u8, .public);
        pub const SourceDigest = output.Descriptor("source_digest", []const u8, .public);

        pub fn field(comptime name: []const u8) type {
            if (std.mem.eql(u8, name, "bucket")) return @This().Bucket;
            if (std.mem.eql(u8, name, "object_name")) return @This().ObjectName;
            if (std.mem.eql(u8, name, "generation")) return @This().Generation;
            if (std.mem.eql(u8, name, "gs_uri")) return @This().GsUri;
            if (std.mem.eql(u8, name, "source_digest")) return @This().SourceDigest;
            @compileError("ZIAC120 unknown gcp.storage.SourceObject output field: " ++ name);
        }
    };

    node: resource.ResourceNode,
    bucket: Outputs.Bucket.OutputType,
    object_name: Outputs.ObjectName.OutputType,
    generation: Outputs.Generation.OutputType,
    gs_uri: Outputs.GsUri.OutputType,
    source_digest: Outputs.SourceDigest.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: SourceObjectArgs,
    ) BuildError!SourceObject {
        try provider.validate();
        try validateName(args.name);
        if (!isDigest(args.source_digest)) return error.InvalidDigest;
        if (!isContentAddressedObject(args.object_name, args.source_digest)) return error.InvalidObjectName;
        if (!isRelativePath(args.source_path)) return error.InvalidSourcePath;
        if (args.size == 0 or args.size > std.math.maxInt(i64)) return error.InvalidSize;
        if (!isCrc32c(args.crc32c)) return error.InvalidCrc32c;
        const fields = [_]value.Field{
            .{ .name = "bucket", .value = try bucketValue(args.bucket) },
            .{ .name = "crc32c", .value = .{ .string = args.crc32c } },
            .{ .name = "object_name", .value = .{ .string = args.object_name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "size", .value = .{ .integer = @intCast(args.size) } },
            .{ .name = "source_digest", .value = .{ .string = args.source_digest } },
            .{ .name = "source_path", .value = .{ .string = args.source_path } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.storage.SourceObject.{s}", .{args.name});
        defer allocator.free(id);
        const node = try buildNode(allocator, id, "gcp.storage.SourceObject", args.name, &fields);
        return .{
            .node = node,
            .bucket = Outputs.Bucket.fromResource(node.id),
            .object_name = Outputs.ObjectName.fromResource(node.id),
            .generation = Outputs.Generation.fromResource(node.id),
            .gs_uri = Outputs.GsUri.fromResource(node.id),
            .source_digest = Outputs.SourceDigest.fromResource(node.id),
        };
    }

    pub fn deinit(self: *SourceObject, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const ObjectArgs = struct {
    name: []const u8,
    bucket: output.Output([]const u8, .public),
    object_name: []const u8,
    source_path: []const u8,
    source_digest: []const u8,
    size: u64,
    crc32c: []const u8,
    content_type: []const u8 = "application/octet-stream",
    retain_on_delete: bool = true,
};

pub const Object = struct {
    pub const Outputs = struct {
        pub const Bucket = output.Descriptor("bucket", []const u8, .public);
        pub const ObjectName = output.Descriptor("object_name", []const u8, .public);
        pub const Generation = output.Descriptor("generation", []const u8, .public);
        pub const GsUri = output.Descriptor("gs_uri", []const u8, .public);
        pub const SourceDigest = output.Descriptor("source_digest", []const u8, .public);

        pub fn field(comptime name: []const u8) type {
            if (std.mem.eql(u8, name, "bucket")) return @This().Bucket;
            if (std.mem.eql(u8, name, "object_name")) return @This().ObjectName;
            if (std.mem.eql(u8, name, "generation")) return @This().Generation;
            if (std.mem.eql(u8, name, "gs_uri")) return @This().GsUri;
            if (std.mem.eql(u8, name, "source_digest")) return @This().SourceDigest;
            @compileError("ZIAC120 unknown gcp.storage.Object output field: " ++ name);
        }
    };

    node: resource.ResourceNode,
    bucket: Outputs.Bucket.OutputType,
    object_name: Outputs.ObjectName.OutputType,
    generation: Outputs.Generation.OutputType,
    gs_uri: Outputs.GsUri.OutputType,
    source_digest: Outputs.SourceDigest.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: ObjectArgs,
    ) BuildError!Object {
        try provider.validate();
        try validateName(args.name);
        if (!isObjectName(args.object_name)) return error.InvalidObjectName;
        if (!isRelativePath(args.source_path)) return error.InvalidSourcePath;
        if (!isDigest(args.source_digest)) return error.InvalidDigest;
        if (args.size > 5 * 1024 * 1024 * 1024 * 1024) return error.InvalidSize;
        if (!isCrc32c(args.crc32c)) return error.InvalidCrc32c;
        if (!isContentType(args.content_type)) return error.InvalidContentType;
        const fields = [_]value.Field{
            .{ .name = "bucket", .value = try bucketValue(args.bucket) },
            .{ .name = "content_type", .value = .{ .string = args.content_type } },
            .{ .name = "crc32c", .value = .{ .string = args.crc32c } },
            .{ .name = "object_name", .value = .{ .string = args.object_name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "size", .value = .{ .integer = @intCast(args.size) } },
            .{ .name = "source_digest", .value = .{ .string = args.source_digest } },
            .{ .name = "source_path", .value = .{ .string = args.source_path } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.storage.Object.{s}", .{args.name});
        defer allocator.free(id);
        const node = try buildNodeWithLifecycle(allocator, id, "gcp.storage.Object", args.name, &fields, .{
            .retain_on_delete = args.retain_on_delete,
            .operation_timeout_millis = 30 * 60 * 1000,
        });
        return .{
            .node = node,
            .bucket = Outputs.Bucket.fromResource(node.id),
            .object_name = Outputs.ObjectName.fromResource(node.id),
            .generation = Outputs.Generation.fromResource(node.id),
            .gs_uri = Outputs.GsUri.fromResource(node.id),
            .source_digest = Outputs.SourceDigest.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Object, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn buildNode(
    allocator: std.mem.Allocator,
    id: []const u8,
    type_name: []const u8,
    logical_id: []const u8,
    fields: []const value.Field,
) BuildError!resource.ResourceNode {
    return buildNodeWithLifecycle(allocator, id, type_name, logical_id, fields, .{
        .retain_on_delete = true,
        .operation_timeout_millis = 30 * 60 * 1000,
    });
}

fn buildNodeWithLifecycle(
    allocator: std.mem.Allocator,
    id: []const u8,
    type_name: []const u8,
    logical_id: []const u8,
    fields: []const value.Field,
    lifecycle: resource.Lifecycle,
) BuildError!resource.ResourceNode {
    return resource.ResourceNode.initOwned(allocator, .{
        .id = id,
        .provider = .gcp,
        .type_name = type_name,
        .logical_id = logical_id,
        .inputs = .{ .object = fields },
        .lifecycle = lifecycle,
    }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
    };
}

fn bucketValue(result: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (result) {
        .value => |known| if (isValidBucket(known)) .{ .string = known } else error.InvalidBucket,
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn isValidBucket(name: []const u8) bool {
    if (name.len < 3 or name.len > 63 or !std.ascii.isLower(name[0]) or
        (!std.ascii.isLower(name[name.len - 1]) and !std.ascii.isDigit(name[name.len - 1]))) return false;
    for (name) |character| {
        if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-' and character != '_' and character != '.') return false;
    }
    return !std.mem.startsWith(u8, name, "goog") and
        std.mem.indexOf(u8, name, "google") == null and
        std.mem.indexOf(u8, name, "..") == null and
        std.mem.indexOf(u8, name, ".-") == null and
        std.mem.indexOf(u8, name, "-.") == null;
}

fn isValidLocation(location: []const u8) bool {
    if (location.len == 0 or location.len > 63) return false;
    for (location) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '-') return false;
    }
    return true;
}

fn isValidSoftDeleteRetention(seconds: u64) bool {
    return seconds == 0 or seconds >= 7 * 24 * 60 * 60 and seconds <= 90 * 24 * 60 * 60;
}

fn isKmsKeyName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "projects/")) return false;
    const markers = [_][]const u8{ "/locations/", "/keyRings/", "/cryptoKeys/" };
    var offset: usize = "projects/".len;
    for (markers) |marker| {
        const index = std.mem.indexOfPos(u8, name, offset, marker) orelse return false;
        if (index == offset) return false;
        offset = index + marker.len;
    }
    return offset < name.len;
}

fn labelValueAlloc(allocator: std.mem.Allocator, labels: []const config_mod.Label) std.mem.Allocator.Error!value.Value {
    const fields = try allocator.alloc(value.Field, labels.len);
    for (labels, 0..) |label, index| {
        fields[index] = .{ .name = label.key, .value = .{ .string = label.value } };
    }
    return .{ .object = fields };
}

const LifecycleRuleWire = struct {
    action_type: []const u8,
    storage_class: []const u8,
    age_days: u32,
    created_before: []const u8,
    days_since_noncurrent_time: u32,
    is_live: []const u8,
    matches_prefixes: []const []const u8,
    matches_suffixes: []const []const u8,
    matches_storage_classes: []const []const u8,
    num_newer_versions: u32,
};

fn lifecycleRulesValueAlloc(allocator: std.mem.Allocator, rules: []const LifecycleRule) BuildError!value.Value {
    const wires = try allocator.alloc(LifecycleRuleWire, rules.len);
    defer allocator.free(wires);
    const class_lists = try allocator.alloc([]const []const u8, rules.len);
    defer allocator.free(class_lists);

    var initialized: usize = 0;
    errdefer for (class_lists[0..initialized]) |classes| allocator.free(classes);
    for (rules, 0..) |rule, index| {
        const classes = try allocator.alloc([]const u8, rule.condition.matches_storage_classes.len);
        class_lists[index] = classes;
        initialized += 1;
        for (rule.condition.matches_storage_classes, 0..) |class, class_index| {
            classes[class_index] = class.apiName();
        }
        wires[index] = .{
            .action_type = switch (rule.action) {
                .delete => "Delete",
                .set_storage_class => "SetStorageClass",
                .abort_incomplete_multipart_upload => "AbortIncompleteMultipartUpload",
            },
            .storage_class = switch (rule.action) {
                .set_storage_class => |class| class.apiName(),
                else => "",
            },
            .age_days = rule.condition.age_days,
            .created_before = rule.condition.created_before orelse "",
            .days_since_noncurrent_time = rule.condition.days_since_noncurrent_time,
            .is_live = if (rule.condition.is_live) |is_live| if (is_live) "true" else "false" else "any",
            .matches_prefixes = rule.condition.matches_prefixes,
            .matches_suffixes = rule.condition.matches_suffixes,
            .matches_storage_classes = classes,
            .num_newer_versions = rule.condition.num_newer_versions,
        };
    }
    defer for (class_lists) |classes| allocator.free(classes);
    return valueFromJsonAlloc(allocator, wires);
}

const CorsRuleWire = struct {
    max_age_seconds: u32,
    methods: []const []const u8,
    origins: []const []const u8,
    response_headers: []const []const u8,
};

fn corsRulesValueAlloc(allocator: std.mem.Allocator, rules: []const CorsRule) BuildError!value.Value {
    const wires = try allocator.alloc(CorsRuleWire, rules.len);
    defer allocator.free(wires);
    const method_lists = try allocator.alloc([]const []const u8, rules.len);
    defer allocator.free(method_lists);

    var initialized: usize = 0;
    errdefer for (method_lists[0..initialized]) |methods| allocator.free(methods);
    for (rules, 0..) |rule, index| {
        const methods = try allocator.alloc([]const u8, rule.methods.len);
        method_lists[index] = methods;
        initialized += 1;
        for (rule.methods, 0..) |method, method_index| methods[method_index] = method.apiName();
        wires[index] = .{
            .max_age_seconds = rule.max_age_seconds,
            .methods = methods,
            .origins = rule.origins,
            .response_headers = rule.response_headers,
        };
    }
    defer for (method_lists) |methods| allocator.free(methods);
    return valueFromJsonAlloc(allocator, wires);
}

fn valueFromJsonAlloc(allocator: std.mem.Allocator, source: anytype) BuildError!value.Value {
    const encoded = std.json.Stringify.valueAlloc(allocator, source, .{}) catch return error.OutOfMemory;
    defer allocator.free(encoded);
    return value.Value.parseJsonAlloc(allocator, encoded) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateField => error.DuplicateField,
        error.InvalidJson, error.UnsupportedJsonValue => unreachable,
    };
}

fn validateLifecycleRules(rules: []const LifecycleRule) BuildError!void {
    for (rules) |rule| {
        const condition = rule.condition;
        if (condition.age_days > 36_500 or condition.days_since_noncurrent_time > 36_500) return error.InvalidLifecycleAge;
        if (condition.created_before) |date| if (!isIsoDate(date)) return error.InvalidLifecycleRule;
        if (condition.age_days == 0 and
            condition.created_before == null and
            condition.days_since_noncurrent_time == 0 and
            condition.is_live == null and
            condition.matches_prefixes.len == 0 and
            condition.matches_suffixes.len == 0 and
            condition.matches_storage_classes.len == 0 and
            condition.num_newer_versions == 0) return error.InvalidLifecycleRule;
        for (condition.matches_prefixes) |prefix| if (!isObjectToken(prefix)) return error.InvalidLifecycleRule;
        for (condition.matches_suffixes) |suffix| if (!isObjectToken(suffix)) return error.InvalidLifecycleRule;
    }
}

fn validateCorsRules(rules: []const CorsRule) BuildError!void {
    for (rules) |rule| {
        if (rule.origins.len == 0 or rule.methods.len == 0 or rule.max_age_seconds > std.math.maxInt(i32)) return error.InvalidCorsOrigin;
        for (rule.origins) |origin| {
            if (!std.mem.eql(u8, origin, "*") and
                !std.mem.startsWith(u8, origin, "https://") and
                !std.mem.startsWith(u8, origin, "http://")) return error.InvalidCorsOrigin;
            if (!isTextValue(origin)) return error.InvalidCorsOrigin;
        }
        for (rule.response_headers) |header| if (!isTextValue(header)) return error.InvalidCorsOrigin;
    }
}

fn isIsoDate(date: []const u8) bool {
    if (date.len != 10 or date[4] != '-' or date[7] != '-') return false;
    for (date, 0..) |character, index| {
        if (index == 4 or index == 7) continue;
        if (!std.ascii.isDigit(character)) return false;
    }
    return !std.mem.eql(u8, date[5..7], "00") and !std.mem.eql(u8, date[8..10], "00");
}

fn isObjectToken(token: []const u8) bool {
    return token.len > 0 and std.mem.indexOfScalar(u8, token, 0) == null;
}

fn isTextValue(text: []const u8) bool {
    return text.len > 0 and
        std.mem.indexOfScalar(u8, text, 0) == null and
        std.mem.indexOfScalar(u8, text, '\r') == null and
        std.mem.indexOfScalar(u8, text, '\n') == null;
}

fn isValidIamMember(member: []const u8) bool {
    return std.mem.eql(u8, member, "allUsers") or
        std.mem.eql(u8, member, "allAuthenticatedUsers") or
        std.mem.indexOfScalar(u8, member, ':') != null;
}

fn validateIamCondition(member: []const u8, condition: IamCondition) BuildError!void {
    if (std.mem.eql(u8, member, "allUsers") or std.mem.eql(u8, member, "allAuthenticatedUsers")) return error.InvalidIamCondition;
    if (!isTextValue(condition.title) or condition.title.len > 100 or !isTextValue(condition.expression)) return error.InvalidIamCondition;
    if (condition.description.len > 0 and !isTextValue(condition.description)) return error.InvalidIamCondition;
}

fn validateName(name: []const u8) BuildError!void {
    if (name.len == 0 or name.len > 63 or !std.ascii.isLower(name[0])) return error.InvalidName;
    for (name) |character| {
        if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return error.InvalidName;
    }
}

fn isConfiguredRegion(provider: config_mod.ProviderConfig, region: []const u8) bool {
    if (std.mem.eql(u8, provider.primary_region, region)) return true;
    for (provider.service_regions) |candidate| if (std.mem.eql(u8, candidate, region)) return true;
    return false;
}

fn isDigest(digest: []const u8) bool {
    if (digest.len != 64) return false;
    for (digest) |character| if (!(std.ascii.isDigit(character) or character >= 'a' and character <= 'f')) return false;
    return true;
}

fn isContentAddressedObject(name: []const u8, digest: []const u8) bool {
    if (name.len <= digest.len + ".tar.gz".len or name[0] == '/' or std.mem.indexOf(u8, name, "..") != null) return false;
    const digest_start = name.len - digest.len - ".tar.gz".len;
    return name[digest_start - 1] == '/' and
        std.mem.eql(u8, name[digest_start .. digest_start + digest.len], digest) and
        std.mem.endsWith(u8, name, ".tar.gz");
}

fn isObjectName(name: []const u8) bool {
    if (name.len == 0 or name.len > 1024 or name[0] == '/' or std.mem.indexOfScalar(u8, name, 0) != null) return false;
    var components = std.mem.splitScalar(u8, name, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn isContentType(content_type: []const u8) bool {
    return isTextValue(content_type) and std.mem.indexOfScalar(u8, content_type, '/') != null;
}

fn isRelativePath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or path[path.len - 1] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn isCrc32c(encoded: []const u8) bool {
    if (encoded.len != 8) return false;
    var decoded: [4]u8 = undefined;
    const size = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return false;
    if (size != decoded.len) return false;
    std.base64.standard.Decoder.decode(&decoded, encoded) catch return false;
    return true;
}
