const std = @import("std");
const config_mod = @import("config.zig");
const resource = @import("../resource.zig");
const storage = @import("storage.zig");

pub const BuildError = storage.BuildError || resource.ResourceGraphError;

pub const AssetBucketArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    location: []const u8,
    readers: []const []const u8 = &.{},
    storage_class: storage.StorageClass = .standard,
    transition_after_days: u32 = 0,
    delete_after_days: u32 = 0,
    default_kms_key_name: ?[]const u8 = null,
    retain_on_delete: bool = true,
};

pub const UploadBucketArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    location: []const u8,
    writers: []const []const u8,
    cors_origins: []const []const u8 = &.{},
    transition_after_days: u32 = 30,
    delete_after_days: u32 = 365,
    default_kms_key_name: ?[]const u8 = null,
    retain_on_delete: bool = true,
};

pub const StaticAssetBucketArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    location: []const u8,
    readers: []const []const u8 = &.{},
    cors_origins: []const []const u8 = &.{},
    public: bool = false,
    default_kms_key_name: ?[]const u8 = null,
    retain_on_delete: bool = true,
};

const ComponentFields = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    name: storage.Bucket.Outputs.Name.OutputType,
    url: storage.Bucket.Outputs.Url.OutputType,
};

pub const AssetBucket = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    name: storage.Bucket.Outputs.Name.OutputType,
    url: storage.Bucket.Outputs.Url.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: AssetBucketArgs) BuildError!AssetBucket {
        var lifecycle: [2]storage.LifecycleRule = undefined;
        const rules = lifecycleRules(&lifecycle, args.transition_after_days, args.delete_after_days);
        const built = try buildBucketGraph(allocator, provider, args.base_graph, .{
            .name = args.name,
            .location = args.location,
            .storage_class = args.storage_class,
            .versioning = true,
            .lifecycle_rules = rules,
            .default_kms_key_name = args.default_kms_key_name,
            .retain_on_delete = args.retain_on_delete,
        }, args.readers, "reader", "roles/storage.objectViewer");
        return fromFields(AssetBucket, built);
    }

    pub fn deinit(self: *AssetBucket) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

pub const UploadBucket = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    name: storage.Bucket.Outputs.Name.OutputType,
    url: storage.Bucket.Outputs.Url.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: UploadBucketArgs) BuildError!UploadBucket {
        var lifecycle: [2]storage.LifecycleRule = undefined;
        const rules = lifecycleRules(&lifecycle, args.transition_after_days, args.delete_after_days);
        const cors: []const storage.CorsRule = if (args.cors_origins.len == 0) &.{} else &.{.{
            .origins = args.cors_origins,
            .methods = &.{ .put, .post, .options },
            .response_headers = &.{ "content-type", "x-goog-resumable" },
        }};
        const built = try buildBucketGraph(allocator, provider, args.base_graph, .{
            .name = args.name,
            .location = args.location,
            .versioning = true,
            .lifecycle_rules = rules,
            .cors = cors,
            .default_kms_key_name = args.default_kms_key_name,
            .retain_on_delete = args.retain_on_delete,
        }, args.writers, "writer", "roles/storage.objectCreator");
        return fromFields(UploadBucket, built);
    }

    pub fn deinit(self: *UploadBucket) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

pub const StaticAssetBucket = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    name: storage.Bucket.Outputs.Name.OutputType,
    url: storage.Bucket.Outputs.Url.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: StaticAssetBucketArgs) BuildError!StaticAssetBucket {
        const members = try allocator.alloc([]const u8, args.readers.len + @intFromBool(args.public));
        defer allocator.free(members);
        @memcpy(members[0..args.readers.len], args.readers);
        if (args.public) members[members.len - 1] = "allUsers";
        const cors: []const storage.CorsRule = if (args.cors_origins.len == 0) &.{} else &.{.{
            .origins = args.cors_origins,
            .methods = &.{ .get, .head },
            .response_headers = &.{ "content-type", "etag" },
        }};
        const built = try buildBucketGraph(allocator, provider, args.base_graph, .{
            .name = args.name,
            .location = args.location,
            .versioning = true,
            .public_access_prevention = if (args.public) .inherited else .enforced,
            .cors = cors,
            .default_kms_key_name = args.default_kms_key_name,
            .retain_on_delete = args.retain_on_delete,
        }, members, "reader", "roles/storage.objectViewer");
        return fromFields(StaticAssetBucket, built);
    }

    pub fn deinit(self: *StaticAssetBucket) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

fn buildBucketGraph(
    allocator: std.mem.Allocator,
    provider: config_mod.ProviderConfig,
    base_graph: ?*const resource.ResourceGraph,
    bucket_args: storage.BucketArgs,
    members: []const []const u8,
    member_kind: []const u8,
    role: []const u8,
) BuildError!ComponentFields {
    var graph = resource.ResourceGraph.init(allocator);
    errdefer graph.deinit();
    if (base_graph) |base| try graph.appendGraph(base);
    const bucket_index = graph.resources.items.len;
    var bucket = try storage.Bucket.build(allocator, provider, bucket_args);
    defer bucket.deinit(allocator);
    try graph.addResource(bucket.node);
    const bucket_id = graph.resources.items[bucket_index].id;
    for (members, 0..) |member, index| {
        const member_name = try memberNameAlloc(allocator, bucket_args.name, member_kind, index);
        defer allocator.free(member_name);
        var binding = try storage.BucketIamMember.build(allocator, provider, .{
            .name = member_name,
            .bucket = storage.Bucket.Outputs.Name.fromResource(bucket_id),
            .role = role,
            .member = member,
        });
        defer binding.deinit(allocator);
        try graph.addResource(binding.node);
    }
    return .{
        .allocator = allocator,
        .graph = graph,
        .name = storage.Bucket.Outputs.Name.fromResource(bucket_id),
        .url = storage.Bucket.Outputs.Url.fromResource(bucket_id),
    };
}

fn lifecycleRules(buffer: *[2]storage.LifecycleRule, transition_days: u32, delete_days: u32) []const storage.LifecycleRule {
    var count: usize = 0;
    if (transition_days > 0) {
        buffer[count] = .{ .action = .{ .set_storage_class = .nearline }, .condition = .{ .age_days = transition_days } };
        count += 1;
    }
    if (delete_days > 0) {
        buffer[count] = .{ .action = .delete, .condition = .{ .age_days = delete_days } };
        count += 1;
    }
    return buffer[0..count];
}

fn fromFields(comptime T: type, fields: ComponentFields) T {
    return .{
        .allocator = fields.allocator,
        .graph = fields.graph,
        .name = fields.name,
        .url = fields.url,
    };
}

fn memberNameAlloc(
    allocator: std.mem.Allocator,
    bucket_name: []const u8,
    member_kind: []const u8,
    index: usize,
) std.mem.Allocator.Error![]const u8 {
    const candidate = try std.fmt.allocPrint(allocator, "{s}-{s}-{d}", .{ bucket_name, member_kind, index + 1 });
    if (candidate.len <= 63) return candidate;
    defer allocator.free(candidate);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(candidate, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ bucket_name[0..48], hex[0..14] });
}
