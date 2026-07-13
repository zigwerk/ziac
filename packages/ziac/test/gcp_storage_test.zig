const std = @import("std");
const ziac = @import("ziac");

test "general bucket declares application storage policy independently from build storage" {
    var bucket = try ziac.gcp.storage.Bucket.build(std.testing.allocator, config, .{
        .name = "ziac-user-uploads",
        .location = "EU",
        .storage_class = .standard,
        .versioning = true,
        .soft_delete_retention_seconds = 14 * 24 * 60 * 60,
        .retention_period_seconds = 24 * 60 * 60,
        .delete_after_days = 365,
        .default_kms_key_name = "projects/ziac-dev/locations/europe-west1/keyRings/app/cryptoKeys/storage",
        .retain_on_delete = false,
    });
    defer bucket.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.storage.Bucket.ziac-user-uploads", bucket.node.id);
    try std.testing.expectEqualStrings("gcp.storage.Bucket", bucket.node.type_name);
    try std.testing.expect(!bucket.node.lifecycle.retain_on_delete);
    const json = try bucket.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"location\":\"EU\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"storage_class\":\"STANDARD\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"soft_delete_retention_seconds\":1209600") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"delete_after_days\":365") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"default_kms_key_name\":\"projects/ziac-dev/") != null);
}

test "general bucket rejects invalid safety and encryption policy" {
    try std.testing.expectError(error.InvalidSoftDeleteRetention, ziac.gcp.storage.Bucket.build(std.testing.allocator, config, .{
        .name = "ziac-user-uploads",
        .location = "EU",
        .soft_delete_retention_seconds = 42,
    }));
    try std.testing.expectError(error.InvalidKmsKey, ziac.gcp.storage.Bucket.build(std.testing.allocator, config, .{
        .name = "ziac-user-uploads",
        .location = "EU",
        .default_kms_key_name = "not-a-kms-resource-name",
    }));
}

test "general bucket declares typed multi-rule lifecycle and CORS policy" {
    const lifecycle = [_]ziac.gcp.storage.LifecycleRule{
        .{
            .action = .{ .set_storage_class = .nearline },
            .condition = .{ .age_days = 30, .matches_prefixes = &.{"archive/"}, .matches_storage_classes = &.{.standard} },
        },
        .{
            .action = .delete,
            .condition = .{ .days_since_noncurrent_time = 14, .is_live = false, .num_newer_versions = 2 },
        },
    };
    const cors = [_]ziac.gcp.storage.CorsRule{.{
        .origins = &.{"https://app.example.com"},
        .methods = &.{ .get, .head, .put },
        .response_headers = &.{ "content-type", "x-goog-meta-upload-id" },
        .max_age_seconds = 3600,
    }};
    var bucket = try ziac.gcp.storage.Bucket.build(std.testing.allocator, config, .{
        .name = "ziac-user-assets",
        .location = "EU",
        .versioning = true,
        .lifecycle_rules = &lifecycle,
        .cors = &cors,
        .force_destroy = true,
        .retain_on_delete = false,
    });
    defer bucket.deinit(std.testing.allocator);

    const json = try bucket.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"action_type\":\"SetStorageClass\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"storage_class\":\"NEARLINE\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"matches_prefixes\":[\"archive/\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"days_since_noncurrent_time\":14") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"methods\":[\"GET\",\"HEAD\",\"PUT\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"force_destroy\":true") != null);

    try std.testing.expectError(error.ConflictingLifecyclePolicy, ziac.gcp.storage.Bucket.build(std.testing.allocator, config, .{
        .name = "ziac-user-assets",
        .location = "EU",
        .delete_after_days = 30,
        .lifecycle_rules = &lifecycle,
    }));
    try std.testing.expectError(error.InvalidCorsOrigin, ziac.gcp.storage.Bucket.build(std.testing.allocator, config, .{
        .name = "ziac-user-assets",
        .location = "EU",
        .cors = &.{.{ .origins = &.{"javascript:alert(1)"}, .methods = &.{.get} }},
    }));
}

test "bucket IAM member accepts a bucket output dependency" {
    var bucket = try ziac.gcp.storage.Bucket.build(std.testing.allocator, config, .{
        .name = "ziac-user-uploads",
        .location = "EU",
    });
    defer bucket.deinit(std.testing.allocator);
    var member = try ziac.gcp.storage.BucketIamMember.build(std.testing.allocator, config, .{
        .name = "api-object-viewer",
        .bucket = bucket.name,
        .role = "roles/storage.objectViewer",
        .member = "serviceAccount:api@ziac-dev.iam.gserviceaccount.com",
    });
    defer member.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.storage.BucketIamMember", member.node.type_name);
    const json = try member.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "gcp.storage.Bucket.ziac-user-uploads") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "roles/storage.objectViewer") != null);
}

test "bucket IAM member owns an exact conditional binding" {
    var member = try ziac.gcp.storage.BucketIamMember.build(std.testing.allocator, config, .{
        .name = "temporary-uploader",
        .bucket = ziac.PublicOutput([]const u8).known("ziac-user-uploads"),
        .role = "roles/storage.objectCreator",
        .member = "serviceAccount:uploader@ziac-dev.iam.gserviceaccount.com",
        .condition = .{
            .title = "upload-window",
            .description = "Temporary upload authority",
            .expression = "request.time < timestamp('2027-01-01T00:00:00Z')",
        },
    });
    defer member.deinit(std.testing.allocator);

    const json = try member.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"condition_title\":\"upload-window\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "request.time < timestamp") != null);
    try std.testing.expectError(error.InvalidIamCondition, ziac.gcp.storage.BucketIamMember.build(std.testing.allocator, config, .{
        .name = "public-condition",
        .bucket = ziac.PublicOutput([]const u8).known("ziac-user-uploads"),
        .role = "roles/storage.objectViewer",
        .member = "allUsers",
        .condition = .{ .title = "not-supported", .expression = "true" },
    }));
}

test "general immutable object declares payload integrity and generation-safe lifecycle" {
    const object_integrity = ziac.gcp.storage.integrity("hello from Ziac");
    var object = try ziac.gcp.storage.Object.build(std.testing.allocator, config, .{
        .name = "site-index",
        .bucket = ziac.PublicOutput([]const u8).known("ziac-user-assets"),
        .object_name = "public/index.html",
        .source_path = "site/index.html",
        .source_digest = &object_integrity.sha256,
        .size = object_integrity.size,
        .crc32c = &object_integrity.crc32c,
        .content_type = "text/html; charset=utf-8",
        .retain_on_delete = false,
    });
    defer object.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.storage.Object", object.node.type_name);
    try std.testing.expect(!object.node.lifecycle.retain_on_delete);
    try std.testing.expectEqualStrings("generation", object.generation.resource_ref.field);
    try std.testing.expectEqualStrings("gs_uri", object.gs_uri.resource_ref.field);
    const json = try object.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"object_name\":\"public/index.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"content_type\":\"text/html; charset=utf-8\"") != null);
    try std.testing.expectError(error.InvalidObjectName, ziac.gcp.storage.Object.build(std.testing.allocator, config, .{
        .name = "bad-object",
        .bucket = ziac.PublicOutput([]const u8).known("ziac-user-assets"),
        .object_name = "../escape",
        .source_path = "site/index.html",
        .source_digest = &object_integrity.sha256,
        .size = object_integrity.size,
        .crc32c = &object_integrity.crc32c,
    }));
}

test "opinionated storage components compile safe asset upload and static bucket graphs" {
    var assets = try ziac.gcp.AssetBucket.build(std.testing.allocator, config, .{
        .name = "ziac-assets",
        .location = "EU",
        .readers = &.{"serviceAccount:api@ziac-dev.iam.gserviceaccount.com"},
    });
    defer assets.deinit();
    try std.testing.expectEqual(@as(usize, 2), assets.graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 1), assets.graph.dependencies.items.len);

    var uploads = try ziac.gcp.UploadBucket.build(std.testing.allocator, config, .{
        .name = "ziac-uploads",
        .location = "EU",
        .writers = &.{"serviceAccount:api@ziac-dev.iam.gserviceaccount.com"},
        .cors_origins = &.{"https://app.example.com"},
        .transition_after_days = 30,
        .delete_after_days = 365,
    });
    defer uploads.deinit();
    const upload_json = try uploads.graph.resources.items[0].inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(upload_json);
    try std.testing.expect(std.mem.indexOf(u8, upload_json, "\"versioning\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, upload_json, "SetStorageClass") != null);
    try std.testing.expect(std.mem.indexOf(u8, upload_json, "https://app.example.com") != null);

    var static = try ziac.gcp.StaticAssetBucket.build(std.testing.allocator, config, .{
        .name = "ziac-static",
        .location = "EU",
        .public = true,
    });
    defer static.deinit();
    try std.testing.expectEqual(@as(usize, 2), static.graph.resources.items.len);
    const public_json = try static.graph.resources.items[1].inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(public_json);
    try std.testing.expect(std.mem.indexOf(u8, public_json, "allUsers") != null);
    try std.testing.expect(std.mem.indexOf(u8, public_json, "roles/storage.objectViewer") != null);
}

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
