const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    InvalidDigest,
    InvalidGeneration,
    InvalidImageName,
    InvalidName,
    InvalidRegion,
    InvalidRepository,
    InvalidSource,
    InvalidTimeout,
    OutputNotKnown,
    UnpinnedBuilder,
};

pub const ZigImageArgs = struct {
    name: []const u8,
    location: []const u8,
    source_bucket: output.Output([]const u8, .public),
    source_object: output.Output([]const u8, .public),
    source_generation: output.Output([]const u8, .public),
    source_digest: []const u8,
    build_digest: []const u8,
    repository: output.Output([]const u8, .public),
    image_name: []const u8,
    docker_builder: []const u8,
    timeout_seconds: u32 = 1200,
};

pub const ZigImage = struct {
    pub const Outputs = struct {
        pub const ImageRef = output.Descriptor("image_ref", []const u8, .public);
        pub const ImageDigest = output.Descriptor("image_digest", []const u8, .public);
        pub const BuildId = output.Descriptor("build_id", []const u8, .public);
        pub const LogUrl = output.Descriptor("log_url", []const u8, .public);

        pub fn field(comptime name: []const u8) type {
            if (std.mem.eql(u8, name, "image_ref")) return ImageRef;
            if (std.mem.eql(u8, name, "image_digest")) return ImageDigest;
            if (std.mem.eql(u8, name, "build_id")) return BuildId;
            if (std.mem.eql(u8, name, "log_url")) return LogUrl;
            @compileError("ZIAC120 unknown gcp.cloudbuild.ZigImage output field: " ++ name);
        }
    };

    node: resource.ResourceNode,
    image_ref: Outputs.ImageRef.OutputType,
    image_digest: Outputs.ImageDigest.OutputType,
    build_id: Outputs.BuildId.OutputType,
    log_url: Outputs.LogUrl.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: ZigImageArgs,
    ) BuildError!ZigImage {
        try provider.validate();
        try validateName(args.name);
        if (!isConfiguredRegion(provider, args.location)) return error.InvalidRegion;
        if (!isDigest(args.source_digest) or !isDigest(args.build_digest)) return error.InvalidDigest;
        if (!isPinnedImage(args.docker_builder)) return error.UnpinnedBuilder;
        if (!isImageName(args.image_name)) return error.InvalidImageName;
        if (args.timeout_seconds < 60 or args.timeout_seconds > 7200) return error.InvalidTimeout;
        const fields = [_]value.Field{
            .{ .name = "build_digest", .value = .{ .string = args.build_digest } },
            .{ .name = "docker_builder", .value = .{ .string = args.docker_builder } },
            .{ .name = "image_name", .value = .{ .string = args.image_name } },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "repository", .value = try outputValue(args.repository, validateRepository, error.InvalidRepository) },
            .{ .name = "source_bucket", .value = try outputValue(args.source_bucket, validateSource, error.InvalidSource) },
            .{ .name = "source_digest", .value = .{ .string = args.source_digest } },
            .{ .name = "source_generation", .value = try outputValue(args.source_generation, validateGeneration, error.InvalidGeneration) },
            .{ .name = "source_object", .value = try outputValue(args.source_object, validateSource, error.InvalidSource) },
            .{ .name = "timeout_seconds", .value = .{ .integer = args.timeout_seconds } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.cloudbuild.ZigImage.{s}", .{args.name});
        defer allocator.free(id);
        const node = resource.ResourceNode.initOwned(allocator, .{
            .id = id,
            .provider = .gcp,
            .type_name = "gcp.cloudbuild.ZigImage",
            .logical_id = args.name,
            .inputs = .{ .object = &fields },
            .lifecycle = .{ .retain_on_delete = true, .operation_timeout_millis = (@as(u64, args.timeout_seconds) + 300) * 1000 },
        }) catch |err| switch (err) {
            error.DuplicateField => return error.DuplicateField,
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
        };
        return .{
            .node = node,
            .image_ref = Outputs.ImageRef.fromResource(node.id),
            .image_digest = Outputs.ImageDigest.fromResource(node.id),
            .build_id = Outputs.BuildId.fromResource(node.id),
            .log_url = Outputs.LogUrl.fromResource(node.id),
        };
    }

    pub fn deinit(self: *ZigImage, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn outputValue(
    result: output.Output([]const u8, .public),
    comptime validate: fn ([]const u8) bool,
    invalid: BuildError,
) BuildError!value.Value {
    return switch (result) {
        .value => |known| if (validate(known)) .{ .string = known } else invalid,
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn validateName(name: []const u8) BuildError!void {
    if (!isImageName(name)) return error.InvalidName;
}

fn isImageName(name: []const u8) bool {
    if (name.len == 0 or name.len > 63 or !std.ascii.isLower(name[0])) return false;
    for (name) |character| {
        if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-' and character != '_') return false;
    }
    return true;
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

fn isPinnedImage(image: []const u8) bool {
    const marker = "@sha256:";
    const start = std.mem.lastIndexOf(u8, image, marker) orelse return false;
    return start > 0 and start + marker.len + 64 == image.len and isDigest(image[start + marker.len ..]);
}

fn validateGeneration(generation: []const u8) bool {
    if (generation.len == 0) return false;
    for (generation) |character| if (!std.ascii.isDigit(character)) return false;
    return true;
}

fn validateRepository(repository: []const u8) bool {
    return repository.len > 0 and std.mem.indexOf(u8, repository, "-docker.pkg.dev/") != null and
        repository[repository.len - 1] != '/';
}

fn validateSource(source: []const u8) bool {
    return source.len > 0 and source[0] != '/' and std.mem.indexOf(u8, source, "..") == null;
}
