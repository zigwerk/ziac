const std = @import("std");
const ziac = @import("ziac");

const regions = [_][]const u8{"europe-west1"};
const config = ziac.gcp.config.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
    .service_regions = &regions,
};
const source_digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const build_digest = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
const pinned_builder = "gcr.io/cloud-builders/docker@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

test "Cloud Build Zig image carries typed source and immutable image outputs" {
    var image = try ziac.gcp.cloud_build.ZigImage.build(std.testing.allocator, config, .{
        .name = "api",
        .location = "europe-west1",
        .source_bucket = ziac.PublicOutput([]const u8).fromResource("gcp.storage.BuildBucket.api", "name"),
        .source_object = ziac.PublicOutput([]const u8).fromResource("gcp.storage.SourceObject.api", "object_name"),
        .source_generation = ziac.PublicOutput([]const u8).fromResource("gcp.storage.SourceObject.api", "generation"),
        .source_digest = source_digest,
        .build_digest = build_digest,
        .repository = ziac.PublicOutput([]const u8).fromResource("gcp.artifact.Repository.api", "repository_url"),
        .image_name = "api",
        .docker_builder = pinned_builder,
        .timeout_seconds = 1200,
    });
    defer image.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.cloudbuild.ZigImage.api", image.node.id);
    try std.testing.expect(image.node.lifecycle.retain_on_delete);
    try std.testing.expectEqualStrings(source_digest, inputString(image.node, "source_digest"));
    try std.testing.expectEqualStrings(build_digest, inputString(image.node, "build_digest"));
    try std.testing.expectEqualStrings(pinned_builder, inputString(image.node, "docker_builder"));
    try std.testing.expectEqual(@as(i64, 1200), inputInteger(image.node, "timeout_seconds"));
    try std.testing.expect(inputValue(image.node, "source_generation") == .output_ref);
    try std.testing.expectEqualStrings("image_ref", image.image_ref.resource_ref.field);
    try std.testing.expectEqualStrings("image_digest", image.image_digest.resource_ref.field);
    try std.testing.expectEqualStrings("build_id", image.build_id.resource_ref.field);
    try std.testing.expectEqualStrings("log_url", image.log_url.resource_ref.field);
}

test "Cloud Build Zig image rejects mutable builders and invalid digests" {
    try std.testing.expectError(error.UnpinnedBuilder, buildImage("gcr.io/cloud-builders/docker:latest", source_digest));
    try std.testing.expectError(error.InvalidDigest, buildImage(pinned_builder, "not-a-digest"));
}

fn buildImage(builder: []const u8, digest: []const u8) !ziac.gcp.cloud_build.ZigImage {
    return ziac.gcp.cloud_build.ZigImage.build(std.testing.allocator, config, .{
        .name = "api",
        .location = "europe-west1",
        .source_bucket = ziac.PublicOutput([]const u8).known("ziac-builds-ziac-dev"),
        .source_object = ziac.PublicOutput([]const u8).known("api/source.tar.gz"),
        .source_generation = ziac.PublicOutput([]const u8).known("42"),
        .source_digest = digest,
        .build_digest = build_digest,
        .repository = ziac.PublicOutput([]const u8).known("europe-west1-docker.pkg.dev/ziac-dev/apps"),
        .image_name = "api",
        .docker_builder = builder,
    });
}

fn inputValue(node: ziac.ResourceNode, name: []const u8) ziac.value.Value {
    for (node.inputs.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    unreachable;
}

fn inputString(node: ziac.ResourceNode, name: []const u8) []const u8 {
    return inputValue(node, name).string;
}

fn inputInteger(node: ziac.ResourceNode, name: []const u8) i64 {
    return inputValue(node, name).integer;
}
