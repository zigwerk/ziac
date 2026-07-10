const std = @import("std");
const ziac = @import("ziac");

const config = ziac.gcp.config.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
};
const digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

test "GCS build bucket and source object preserve content-addressed integrity" {
    var bucket = try ziac.gcp.storage.BuildBucket.build(std.testing.allocator, config, .{
        .name = "ziac-builds-ziac-dev",
        .location = "europe-west1",
        .lifecycle_age_days = 30,
    });
    defer bucket.deinit(std.testing.allocator);
    const integrity = ziac.gcp.storage.integrity("archive-bytes");
    var object = try ziac.gcp.storage.SourceObject.build(std.testing.allocator, config, .{
        .name = "api-source",
        .bucket = bucket.name,
        .object_name = "api/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.tar.gz",
        .source_path = "apps/api",
        .source_digest = digest,
        .size = integrity.size,
        .crc32c = &integrity.crc32c,
    });
    defer object.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.storage.BuildBucket.ziac-builds-ziac-dev", bucket.node.id);
    try std.testing.expect(bucket.node.lifecycle.retain_on_delete);
    try std.testing.expectEqualStrings("europe-west1", inputString(bucket.node, "location"));
    try std.testing.expectEqual(@as(i64, 30), inputInteger(bucket.node, "lifecycle_age_days"));
    try std.testing.expect(inputBoolean(bucket.node, "uniform_bucket_level_access"));
    try std.testing.expect(inputBoolean(bucket.node, "public_access_prevention"));
    try std.testing.expect(inputBoolean(bucket.node, "versioning"));

    try std.testing.expectEqualStrings("gcp.storage.SourceObject.api-source", object.node.id);
    try std.testing.expect(object.node.lifecycle.retain_on_delete);
    try std.testing.expect(inputValue(object.node, "bucket") == .output_ref);
    try std.testing.expectEqualStrings(bucket.node.id, inputValue(object.node, "bucket").output_ref.resource_id);
    try std.testing.expectEqualStrings(digest, inputString(object.node, "source_digest"));
    try std.testing.expectEqual(@as(i64, @intCast(integrity.size)), inputInteger(object.node, "size"));
    try std.testing.expectEqualStrings(&integrity.crc32c, inputString(object.node, "crc32c"));
    try std.testing.expectEqualStrings("generation", object.generation.resource_ref.field);
    try std.testing.expectEqualStrings("gs_uri", object.gs_uri.resource_ref.field);
}

test "GCS source object rejects non-content-addressed or malformed inputs" {
    const integrity = ziac.gcp.storage.integrity("archive-bytes");
    try std.testing.expectError(error.InvalidObjectName, ziac.gcp.storage.SourceObject.build(std.testing.allocator, config, .{
        .name = "api-source",
        .bucket = ziac.PublicOutput([]const u8).known("ziac-builds-ziac-dev"),
        .object_name = "api/not-the-digest.tar.gz",
        .source_path = "apps/api",
        .source_digest = digest,
        .size = integrity.size,
        .crc32c = &integrity.crc32c,
    }));
    try std.testing.expectError(error.InvalidCrc32c, ziac.gcp.storage.SourceObject.build(std.testing.allocator, config, .{
        .name = "api-source",
        .bucket = ziac.PublicOutput([]const u8).known("ziac-builds-ziac-dev"),
        .object_name = "api/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.tar.gz",
        .source_path = "apps/api",
        .source_digest = digest,
        .size = integrity.size,
        .crc32c = "bad",
    }));
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

fn inputBoolean(node: ziac.ResourceNode, name: []const u8) bool {
    return inputValue(node, name).boolean;
}
