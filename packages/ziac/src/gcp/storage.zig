const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    InvalidBucket,
    InvalidCrc32c,
    InvalidDigest,
    InvalidLifecycleAge,
    InvalidName,
    InvalidObjectName,
    InvalidRegion,
    InvalidSize,
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
            if (std.mem.eql(u8, name, "bucket")) return Bucket;
            if (std.mem.eql(u8, name, "object_name")) return ObjectName;
            if (std.mem.eql(u8, name, "generation")) return Generation;
            if (std.mem.eql(u8, name, "gs_uri")) return GsUri;
            if (std.mem.eql(u8, name, "source_digest")) return SourceDigest;
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

fn buildNode(
    allocator: std.mem.Allocator,
    id: []const u8,
    type_name: []const u8,
    logical_id: []const u8,
    fields: []const value.Field,
) BuildError!resource.ResourceNode {
    return resource.ResourceNode.initOwned(allocator, .{
        .id = id,
        .provider = .gcp,
        .type_name = type_name,
        .logical_id = logical_id,
        .inputs = .{ .object = fields },
        .lifecycle = .{ .retain_on_delete = true, .operation_timeout_millis = 30 * 60 * 1000 },
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
        if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return false;
    }
    return !std.mem.startsWith(u8, name, "goog") and std.mem.indexOf(u8, name, "google") == null;
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
