const std = @import("std");
const local_state = @import("local_state.zig");

pub const manifest_media_type = "application/vnd.oci.image.manifest.v1+json";
pub const config_media_type = "application/vnd.oci.image.config.v1+json";
pub const layer_media_type = "application/vnd.oci.image.layer.v1.tar";
pub const Digest = [71]u8;

pub const Descriptor = struct {
    media_type: []const u8,
    digest: []const u8,
    size: usize,
};

pub const PlanInput = struct {
    repository: []const u8,
    base_manifest_digest: []const u8,
    base_config_digest: []const u8,
    base_layers: []const Descriptor = &.{},
    base_diff_ids: []const []const u8 = &.{},
    binary_tar: []const u8,
    architecture: []const u8 = "amd64",
    operating_system: []const u8 = "linux",
    entrypoint: []const u8,
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    repository: []const u8,
    layer_digest: Digest,
    config_digest: Digest,
    manifest_digest: Digest,
    layer_blob: []const u8,
    config_blob: []const u8,
    manifest_blob: []const u8,
    image_ref: []const u8,

    pub fn deinit(self: *Plan) void {
        self.allocator.free(self.repository);
        self.allocator.free(self.layer_blob);
        self.allocator.free(self.config_blob);
        self.allocator.free(self.manifest_blob);
        self.allocator.free(self.image_ref);
        self.* = undefined;
    }
};

const JsonDescriptor = struct {
    mediaType: []const u8,
    digest: []const u8,
    size: usize,
};

pub fn planAlloc(allocator: std.mem.Allocator, input: PlanInput) !Plan {
    if (input.repository.len == 0) return error.InvalidRepository;
    if (!isDigest(input.base_manifest_digest)) return error.UnpinnedBaseManifest;
    if (!isDigest(input.base_config_digest)) return error.InvalidBaseConfig;
    if (input.binary_tar.len == 0 or input.entrypoint.len == 0) return error.InvalidApplicationLayer;
    for (input.base_layers) |layer| if (!isDigest(layer.digest) or layer.size == 0) return error.InvalidBaseLayer;
    for (input.base_diff_ids) |diff_id| if (!isDigest(diff_id)) return error.InvalidBaseLayer;

    const repository = try allocator.dupe(u8, input.repository);
    errdefer allocator.free(repository);
    const layer_blob = try allocator.dupe(u8, input.binary_tar);
    errdefer allocator.free(layer_blob);
    const layer_digest = digest(input.binary_tar);

    const diff_ids = try allocator.alloc([]const u8, input.base_diff_ids.len + 1);
    defer allocator.free(diff_ids);
    @memcpy(diff_ids[0..input.base_diff_ids.len], input.base_diff_ids);
    diff_ids[input.base_diff_ids.len] = &layer_digest;
    const config_blob = std.json.Stringify.valueAlloc(allocator, .{
        .architecture = input.architecture,
        .os = input.operating_system,
        .config = .{ .Entrypoint = &.{input.entrypoint} },
        .rootfs = .{ .type = "layers", .diff_ids = diff_ids },
        .history = &.{.{ .created_by = "ziac immutable Zig binary layer" }},
        .annotations = .{ .@"io.ziac.base.manifest" = input.base_manifest_digest },
    }, .{}) catch return error.OutOfMemory;
    errdefer allocator.free(config_blob);
    const config_digest = digest(config_blob);

    const layers = try allocator.alloc(JsonDescriptor, input.base_layers.len + 1);
    defer allocator.free(layers);
    for (input.base_layers, 0..) |layer, index| layers[index] = .{
        .mediaType = layer.media_type,
        .digest = layer.digest,
        .size = layer.size,
    };
    layers[input.base_layers.len] = .{
        .mediaType = layer_media_type,
        .digest = &layer_digest,
        .size = layer_blob.len,
    };
    const manifest_blob = std.json.Stringify.valueAlloc(allocator, .{
        .schemaVersion = @as(u8, 2),
        .mediaType = manifest_media_type,
        .config = JsonDescriptor{
            .mediaType = config_media_type,
            .digest = &config_digest,
            .size = config_blob.len,
        },
        .layers = layers,
        .annotations = .{ .@"io.ziac.base.manifest" = input.base_manifest_digest },
    }, .{}) catch return error.OutOfMemory;
    errdefer allocator.free(manifest_blob);
    const manifest_digest = digest(manifest_blob);
    const image_ref = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ input.repository, &manifest_digest });
    errdefer allocator.free(image_ref);

    return .{
        .allocator = allocator,
        .repository = repository,
        .layer_digest = layer_digest,
        .config_digest = config_digest,
        .manifest_digest = manifest_digest,
        .layer_blob = layer_blob,
        .config_blob = config_blob,
        .manifest_blob = manifest_blob,
        .image_ref = image_ref,
    };
}

pub const Registry = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        has_blob: *const fn (*anyopaque, []const u8, []const u8) anyerror!bool,
        upload_blob: *const fn (*anyopaque, []const u8, []const u8, []const u8, []const u8) anyerror!void,
    };

    pub fn hasBlob(self: Registry, repository: []const u8, blob_digest: []const u8) !bool {
        return self.vtable.has_blob(self.ptr, repository, blob_digest);
    }

    pub fn uploadBlob(self: Registry, repository: []const u8, blob_digest: []const u8, media_type: []const u8, bytes: []const u8) !void {
        try self.vtable.upload_blob(self.ptr, repository, blob_digest, media_type, bytes);
    }
};

pub const PushReceipt = struct {
    schema: []const u8 = "ziac.oci-push.v1",
    image_ref: []const u8,
    uploaded_blobs: usize,
    reused_blobs: usize,
    uploaded_bytes: usize,
};

pub fn push(plan: *const Plan, registry: Registry) !PushReceipt {
    var uploaded: usize = 0;
    var reused: usize = 0;
    var uploaded_bytes: usize = 0;
    const blobs = [_]struct { digest: []const u8, media_type: []const u8, bytes: []const u8 }{
        .{ .digest = &plan.layer_digest, .media_type = layer_media_type, .bytes = plan.layer_blob },
        .{ .digest = &plan.config_digest, .media_type = config_media_type, .bytes = plan.config_blob },
        .{ .digest = &plan.manifest_digest, .media_type = manifest_media_type, .bytes = plan.manifest_blob },
    };
    for (blobs) |blob| {
        if (try registry.hasBlob(plan.repository, blob.digest)) {
            reused += 1;
            continue;
        }
        try registry.uploadBlob(plan.repository, blob.digest, blob.media_type, blob.bytes);
        uploaded += 1;
        uploaded_bytes += blob.bytes.len;
    }
    return .{
        .image_ref = plan.image_ref,
        .uploaded_blobs = uploaded,
        .reused_blobs = reused,
        .uploaded_bytes = uploaded_bytes,
    };
}

pub const ScriptedRegistry = struct {
    allocator: std.mem.Allocator,
    blobs: std.StringHashMap(void),
    upload_count: usize = 0,
    uploaded_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator) ScriptedRegistry {
        return .{ .allocator = allocator, .blobs = std.StringHashMap(void).init(allocator) };
    }

    pub fn deinit(self: *ScriptedRegistry) void {
        var iterator = self.blobs.keyIterator();
        while (iterator.next()) |key| self.allocator.free(key.*);
        self.blobs.deinit();
        self.* = undefined;
    }

    pub fn registry(self: *ScriptedRegistry) Registry {
        return .{ .ptr = self, .vtable = &scripted_registry_vtable };
    }

    fn hasBlob(raw: *anyopaque, _: []const u8, blob_digest: []const u8) !bool {
        const self: *ScriptedRegistry = @ptrCast(@alignCast(raw));
        return self.blobs.contains(blob_digest);
    }

    fn uploadBlob(raw: *anyopaque, _: []const u8, blob_digest: []const u8, _: []const u8, bytes: []const u8) !void {
        const self: *ScriptedRegistry = @ptrCast(@alignCast(raw));
        if (self.blobs.contains(blob_digest)) return;
        const owned = try self.allocator.dupe(u8, blob_digest);
        errdefer self.allocator.free(owned);
        try self.blobs.put(owned, {});
        self.upload_count += 1;
        self.uploaded_bytes += bytes.len;
    }
};

pub const Cache = struct {
    allocator: std.mem.Allocator,
    files: local_state.FileStore,

    pub fn init(allocator: std.mem.Allocator, files: local_state.FileStore) Cache {
        return .{ .allocator = allocator, .files = files };
    }

    pub fn putBlob(self: Cache, blob_digest: []const u8, bytes: []const u8) !void {
        const path = try self.blobPathAlloc(blob_digest);
        defer self.allocator.free(path);
        try self.files.atomicWriteFile(self.allocator, path, bytes);
    }

    pub fn hasBlob(self: Cache, blob_digest: []const u8) !bool {
        const path = try self.blobPathAlloc(blob_digest);
        defer self.allocator.free(path);
        return self.files.exists(path);
    }

    pub fn getBlobAlloc(self: Cache, blob_digest: []const u8) ![]const u8 {
        const path = try self.blobPathAlloc(blob_digest);
        defer self.allocator.free(path);
        return self.files.readFileAllocBounded(self.allocator, path, 512 * 1024 * 1024);
    }

    pub fn lockBase(self: Cache, repository: []const u8, manifest_digest: []const u8) !void {
        if (!isDigest(manifest_digest)) return error.UnpinnedBaseManifest;
        const path = try self.basePathAlloc(repository);
        defer self.allocator.free(path);
        if (try self.files.exists(path)) return self.requireBase(repository, manifest_digest);
        const content = std.json.Stringify.valueAlloc(self.allocator, .{
            .schema = "ziac.oci-base-lock.v1",
            .repository = repository,
            .manifest_digest = manifest_digest,
        }, .{}) catch return error.OutOfMemory;
        defer self.allocator.free(content);
        try self.files.atomicWriteFile(self.allocator, path, content);
    }

    pub fn requireBase(self: Cache, repository: []const u8, manifest_digest: []const u8) !void {
        if (!isDigest(manifest_digest)) return error.UnpinnedBaseManifest;
        const path = try self.basePathAlloc(repository);
        defer self.allocator.free(path);
        const content = try self.files.readFileAllocBounded(self.allocator, path, 64 * 1024);
        defer self.allocator.free(content);
        const Lock = struct { schema: []const u8, repository: []const u8, manifest_digest: []const u8 };
        var parsed = std.json.parseFromSlice(Lock, self.allocator, content, .{}) catch return error.InvalidBaseManifestLock;
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.schema, "ziac.oci-base-lock.v1") or
            !std.mem.eql(u8, parsed.value.repository, repository)) return error.InvalidBaseManifestLock;
        if (!std.mem.eql(u8, parsed.value.manifest_digest, manifest_digest)) return error.BaseManifestLockMismatch;
    }

    fn blobPathAlloc(self: Cache, blob_digest: []const u8) ![]u8 {
        if (!isDigest(blob_digest)) return error.InvalidBlobDigest;
        return std.fmt.allocPrint(self.allocator, ".ziac/oci/blobs/sha256/{s}", .{blob_digest[7..]});
    }

    fn basePathAlloc(self: Cache, repository: []const u8) ![]u8 {
        if (repository.len == 0) return error.InvalidRepository;
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(repository, &hash, .{});
        const hex = std.fmt.bytesToHex(hash, .lower);
        return std.fmt.allocPrint(self.allocator, ".ziac/oci/bases/{s}.json", .{&hex});
    }
};

const scripted_registry_vtable: Registry.VTable = .{
    .has_blob = ScriptedRegistry.hasBlob,
    .upload_blob = ScriptedRegistry.uploadBlob,
};

fn digest(bytes: []const u8) Digest {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    const hex = std.fmt.bytesToHex(hash, .lower);
    var result: Digest = undefined;
    @memcpy(result[0..7], "sha256:");
    @memcpy(result[7..], &hex);
    return result;
}

fn isDigest(value: []const u8) bool {
    if (value.len != 71 or !std.mem.startsWith(u8, value, "sha256:")) return false;
    for (value[7..]) |character| if (!std.ascii.isHex(character)) return false;
    return true;
}
