const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;
const storage_provider = ziac.gcp.storage_provider;

test "live GCP provider manages a general bucket with metageneration-safe updates" {
    const responses = [_]zstd.Http.Response{
        notFound(),
        .{ .status = 200, .body = generalBucketJson(2, 365) },
        .{ .status = 200, .body = generalBucketJson(2, 365) },
        .{ .status = 200, .body = generalBucketJson(2, 365) },
        .{ .status = 200, .body = generalBucketWithoutRetentionJson(3, 30) },
        .{ .status = 200, .body = generalBucketWithoutRetentionJson(3, 30) },
        .{ .status = 204, .body = "" },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var bucket = try generalBucket(365);
    defer bucket.deinit(std.testing.allocator);
    var changed = try generalBucketWithoutRetention(30);
    defer changed.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var before = try live.readWithContext(&context, bucket.node);
    defer before.deinit();
    try std.testing.expect(before == .absent);
    var created = try live.createWithContext(&context, bucket.node);
    defer created.deinit();
    try std.testing.expectEqualStrings("buckets/ziac-user-uploads", created.physical_id);
    try std.testing.expectEqualStrings("2", outputString(created, "metageneration"));
    var present = try live.readWithContext(&context, bucket.node);
    defer present.deinit();
    var update_diff = try live.diffWithContext(&context, changed.node, &present.present);
    defer update_diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, update_diff.kind);
    var updated = try live.updateWithContext(&context, changed.node, &present.present);
    defer updated.deinit();
    try std.testing.expectEqualStrings("3", outputString(updated, "metageneration"));
    var imported = try live.importWithContext(&context, changed.node, "gs://ziac-user-uploads");
    defer imported.deinit();
    try std.testing.expectEqual(changed.node.inputs_hash, imported.observed_hash);
    try live.deleteWithContext(&context, changed.node, updated.physical_id);

    try std.testing.expectEqualStrings("POST", harness.transport.requests.items[1].method);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"softDeletePolicy\":{\"retentionDurationSeconds\":1209600}") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"defaultKmsKeyName\":\"projects/ziac-dev/") != null);
    try std.testing.expectEqualStrings(
        "https://storage.example.test/storage/v1/b/ziac-user-uploads?ifMetagenerationMatch=2",
        harness.transport.requests.items[4].url,
    );
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[4].body, "\"retentionPolicy\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[4].body, "\"defaultKmsKeyName\":null") != null);
    try std.testing.expectEqualStrings("DELETE", harness.transport.requests.items[6].method);
}

test "live GCP provider preserves unrelated bucket IAM members" {
    const without_member = "{\"version\":3,\"etag\":\"BwA=\",\"bindings\":[{\"role\":\"roles/storage.objectViewer\",\"members\":[\"user:owner@example.com\"]}]}";
    const with_member = "{\"version\":3,\"etag\":\"BwB=\",\"bindings\":[{\"role\":\"roles/storage.objectViewer\",\"members\":[\"user:owner@example.com\",\"serviceAccount:api@ziac-dev.iam.gserviceaccount.com\"]}]}";
    const responses = [_]zstd.Http.Response{
        .{ .status = 200, .body = without_member },
        .{ .status = 200, .body = without_member },
        .{ .status = 200, .body = with_member },
        .{ .status = 200, .body = with_member },
        .{ .status = 200, .body = with_member },
        .{ .status = 200, .body = with_member },
        .{ .status = 200, .body = without_member },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var member = try bucketIamMember();
    defer member.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var before = try live.readWithContext(&context, member.node);
    defer before.deinit();
    try std.testing.expect(before == .absent);
    var created = try live.createWithContext(&context, member.node);
    defer created.deinit();
    try std.testing.expectEqualStrings("buckets/ziac-user-uploads/iam/api-object-viewer", created.physical_id);
    var present = try live.readWithContext(&context, member.node);
    defer present.deinit();
    try std.testing.expect(present == .present);
    var imported = try live.importWithContext(&context, member.node, created.physical_id);
    defer imported.deinit();
    try live.deleteWithContext(&context, member.node, created.physical_id);

    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[2].body, "user:owner@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[2].body, "serviceAccount:api@ziac-dev.iam.gserviceaccount.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[6].body, "user:owner@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[6].body, "serviceAccount:api@ziac-dev.iam.gserviceaccount.com") == null);
}

test "live GCP provider serializes and normalizes multi-rule lifecycle and CORS" {
    const advanced_json =
        "{\"id\":\"ziac-user-assets\",\"name\":\"ziac-user-assets\",\"selfLink\":\"https://storage.googleapis.com/storage/v1/b/ziac-user-assets\",\"location\":\"EU\",\"storageClass\":\"STANDARD\",\"metageneration\":\"7\",\"iamConfiguration\":{\"uniformBucketLevelAccess\":{\"enabled\":true},\"publicAccessPrevention\":\"enforced\"},\"versioning\":{\"enabled\":true},\"softDeletePolicy\":{\"retentionDurationSeconds\":\"604800\"},\"lifecycle\":{\"rule\":[{\"action\":{\"type\":\"SetStorageClass\",\"storageClass\":\"NEARLINE\"},\"condition\":{\"age\":30,\"matchesPrefix\":[\"archive/\"],\"matchesStorageClass\":[\"STANDARD\"]}},{\"action\":{\"type\":\"Delete\"},\"condition\":{\"daysSinceNoncurrentTime\":14,\"isLive\":false,\"numNewerVersions\":2}}]},\"cors\":[{\"origin\":[\"https://app.example.com\"],\"method\":[\"GET\",\"HEAD\",\"PUT\"],\"responseHeader\":[\"content-type\"],\"maxAgeSeconds\":3600}],\"labels\":{}}";
    const responses = [_]zstd.Http.Response{
        notFound(),
        .{ .status = 200, .body = advanced_json },
        .{ .status = 200, .body = advanced_json },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var bucket = try advancedBucket();
    defer bucket.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var absent = try live.readWithContext(&context, bucket.node);
    defer absent.deinit();
    var created = try live.createWithContext(&context, bucket.node);
    defer created.deinit();
    var present = try live.readWithContext(&context, bucket.node);
    defer present.deinit();
    var diff = try live.diffWithContext(&context, bucket.node, &present.present);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.noop, diff.kind);
    const body = harness.transport.requests.items[1].body;
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"SetStorageClass\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"matchesPrefix\":[\"archive/\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"daysSinceNoncurrentTime\":14") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"cors\":[{\"maxAgeSeconds\":3600") != null);
}

test "live GCP provider owns only the exact conditional bucket IAM member" {
    const before = "{\"version\":3,\"etag\":\"BwA=\",\"bindings\":[{\"role\":\"roles/storage.objectCreator\",\"members\":[\"user:owner@example.com\"]},{\"role\":\"roles/storage.objectCreator\",\"members\":[\"serviceAccount:other@ziac-dev.iam.gserviceaccount.com\"],\"condition\":{\"title\":\"other-window\",\"description\":\"Other\",\"expression\":\"request.time < timestamp('2028-01-01T00:00:00Z')\"}}]}";
    const with_target = "{\"version\":3,\"etag\":\"BwB=\",\"bindings\":[{\"role\":\"roles/storage.objectCreator\",\"members\":[\"user:owner@example.com\"]},{\"role\":\"roles/storage.objectCreator\",\"members\":[\"serviceAccount:other@ziac-dev.iam.gserviceaccount.com\"],\"condition\":{\"title\":\"other-window\",\"description\":\"Other\",\"expression\":\"request.time < timestamp('2028-01-01T00:00:00Z')\"}},{\"role\":\"roles/storage.objectCreator\",\"members\":[\"serviceAccount:uploader@ziac-dev.iam.gserviceaccount.com\"],\"condition\":{\"title\":\"upload-window\",\"description\":\"Temporary upload authority\",\"expression\":\"request.time < timestamp('2027-01-01T00:00:00Z')\"}}]}";
    const responses = [_]zstd.Http.Response{
        .{ .status = 200, .body = before },
        .{ .status = 200, .body = with_target },
        .{ .status = 200, .body = with_target },
        .{ .status = 200, .body = before },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var member = try conditionalBucketIamMember();
    defer member.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try live.createWithContext(&context, member.node);
    defer created.deinit();
    try live.deleteWithContext(&context, member.node, created.physical_id);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"version\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"title\":\"upload-window\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "other-window") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].body, "upload-window") == null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].body, "other-window") != null);
}

test "live GCP provider uploads imports and generation-deletes a general object" {
    const payload = "hello from Ziac";
    const object_integrity = ziac.gcp.storage.integrity(payload);
    const object_json = try generalObjectJsonAlloc(std.testing.allocator, object_integrity, "42");
    defer std.testing.allocator.free(object_json);
    const responses = [_]zstd.Http.Response{
        .{ .status = 200, .body = object_json },
        .{ .status = 200, .body = object_json },
        .{ .status = 200, .body = object_json },
        .{ .status = 204, .body = "" },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var source = FixedPayloadSource{ .bytes = payload, .expected_path = "site/index.html" };
    harness.live.payload_source = source.payloadSource();
    var object = try generalObject(object_integrity);
    defer object.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try live.createWithContext(&context, object.node);
    defer created.deinit();
    try std.testing.expectEqualStrings("gs://ziac-user-assets/public/index.html#42", created.physical_id);
    var read = try live.readWithContext(&context, object.node);
    defer read.deinit();
    var imported = try live.importWithContext(&context, object.node, created.physical_id);
    defer imported.deinit();
    try live.deleteWithContext(&context, object.node, created.physical_id);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", harness.transport.requests.items[0].content_type.?);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].url, "ifGenerationMatch=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].url, "generation=42") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].url, "ifGenerationMatch=42") != null);
}

test "live GCP provider requires explicit authority before cleaning a non-empty bucket" {
    const non_empty = "{\"items\":[{\"name\":\"a.txt\",\"generation\":\"1\"},{\"name\":\"archive/b.txt\",\"generation\":\"2\"}]}";
    var ordinary_harness: Harness = undefined;
    ordinary_harness.init(&.{conflict()});
    defer ordinary_harness.deinit();
    var ordinary = try generalBucketWithoutRetention(30);
    defer ordinary.deinit(std.testing.allocator);
    var ordinary_context = ziac.provider.OperationContext.init(std.testing.allocator);
    try std.testing.expectError(error.ResourceNotEmpty, ordinary_harness.live.provider().deleteWithContext(
        &ordinary_context,
        ordinary.node,
        "buckets/ziac-user-uploads",
    ));

    var guarded_harness: Harness = undefined;
    guarded_harness.init(&.{});
    defer guarded_harness.deinit();
    var forced = try forceDestroyBucket();
    defer forced.deinit(std.testing.allocator);
    var guarded_context = ziac.provider.OperationContext.init(std.testing.allocator);
    try std.testing.expectError(error.DestructiveConfirmationRequired, guarded_harness.live.provider().deleteWithContext(
        &guarded_context,
        forced.node,
        "buckets/ziac-user-uploads",
    ));
    try std.testing.expectEqual(@as(usize, 0), guarded_harness.transport.requests.items.len);

    const cleanup_responses = [_]zstd.Http.Response{
        .{ .status = 200, .body = non_empty },
        .{ .status = 204, .body = "" },
        .{ .status = 204, .body = "" },
        .{ .status = 204, .body = "" },
    };
    var cleanup_harness: Harness = undefined;
    cleanup_harness.init(&cleanup_responses);
    defer cleanup_harness.deinit();
    var cleanup_context = ziac.provider.OperationContext.init(std.testing.allocator);
    cleanup_context.destructive_confirmation = true;
    try cleanup_harness.live.provider().deleteWithContext(&cleanup_context, forced.node, "buckets/ziac-user-uploads");
    try std.testing.expect(std.mem.indexOf(u8, cleanup_harness.transport.requests.items[0].url, "versions=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, cleanup_harness.transport.requests.items[1].url, "a.txt?generation=1&ifGenerationMatch=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, cleanup_harness.transport.requests.items[2].url, "archive%2Fb.txt?generation=2&ifGenerationMatch=2") != null);
    try std.testing.expect(std.mem.endsWith(u8, cleanup_harness.transport.requests.items[3].url, "/storage/v1/b/ziac-user-uploads"));
}

test "live GCP provider manages a protected retained build bucket" {
    const responses = [_]zstd.Http.Response{
        notFound(),
        .{ .status = 200, .body = bucketJson(30) },
        .{ .status = 200, .body = bucketJson(30) },
        .{ .status = 200, .body = bucketJson(14) },
        .{ .status = 200, .body = bucketJson(14) },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var bucket = try ziac.gcp.storage.BuildBucket.build(std.testing.allocator, config(), .{
        .name = "ziac-dev-builds",
        .location = "europe-west1",
    });
    defer bucket.deinit(std.testing.allocator);
    var changed = try ziac.gcp.storage.BuildBucket.build(std.testing.allocator, config(), .{
        .name = "ziac-dev-builds",
        .location = "europe-west1",
        .lifecycle_age_days = 14,
    });
    defer changed.deinit(std.testing.allocator);
    var relocated = try ziac.gcp.storage.BuildBucket.build(std.testing.allocator, config(), .{
        .name = "ziac-dev-builds",
        .location = "europe-west4",
    });
    defer relocated.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var before = try live.readWithContext(&context, bucket.node);
    defer before.deinit();
    try std.testing.expect(before == .absent);
    var created = try live.createWithContext(&context, bucket.node);
    defer created.deinit();
    try std.testing.expectEqualStrings("buckets/ziac-dev-builds", created.physical_id);
    try std.testing.expectEqualStrings("ziac-dev-builds", outputString(created, "name"));
    var present = try live.readWithContext(&context, bucket.node);
    defer present.deinit();
    var noop = try live.diffWithContext(&context, bucket.node, &present.present);
    defer noop.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.noop, noop.kind);
    var update_diff = try live.diffWithContext(&context, changed.node, &present.present);
    defer update_diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, update_diff.kind);
    var replace_diff = try live.diffWithContext(&context, relocated.node, &present.present);
    defer replace_diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.replace, replace_diff.kind);
    var updated = try live.updateWithContext(&context, changed.node, &present.present);
    defer updated.deinit();
    try std.testing.expectEqual(changed.node.inputs_hash, updated.observed_hash);

    const request_count = harness.transport.requests.items.len;
    try live.deleteWithContext(&context, changed.node, updated.physical_id);
    try std.testing.expectEqual(request_count, harness.transport.requests.items.len);
    var imported = try live.importWithContext(&context, changed.node, "buckets/ziac-dev-builds");
    defer imported.deinit();
    try std.testing.expectEqualStrings("buckets/ziac-dev-builds", imported.physical_id);

    try std.testing.expectEqualStrings(
        "https://storage.example.test/storage/v1/b/ziac-dev-builds",
        harness.transport.requests.items[0].url,
    );
    try std.testing.expectEqualStrings(
        "https://storage.example.test/storage/v1/b?project=ziac-dev",
        harness.transport.requests.items[1].url,
    );
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"publicAccessPrevention\":\"enforced\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"uniformBucketLevelAccess\":{\"enabled\":true}") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].body, "\"age\":14") != null);
}

test "live GCP provider uploads source archives ephemerally with generation preconditions" {
    const archive = "deterministic-zig-archive";
    const integrity = ziac.gcp.storage.integrity(archive);
    const object_name = try std.fmt.allocPrint(std.testing.allocator, "sources/{s}.tar.gz", .{integrity.sha256});
    defer std.testing.allocator.free(object_name);
    const object_json = try objectJsonAlloc(std.testing.allocator, object_name, integrity, "171234");
    defer std.testing.allocator.free(object_json);
    const responses = [_]zstd.Http.Response{.{ .status = 200, .body = object_json }};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var source = FixedPayloadSource{ .bytes = archive };
    harness.live.payload_source = source.payloadSource();
    var object = try sourceObjectBuild(object_name, integrity);
    defer object.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try live.createWithContext(&context, object.node);
    defer created.deinit();
    try std.testing.expect(std.mem.startsWith(u8, created.physical_id, "gs://ziac-dev-builds/"));
    try std.testing.expect(std.mem.endsWith(u8, created.physical_id, "#171234"));
    try std.testing.expectEqualStrings("171234", outputString(created, "generation"));
    try std.testing.expectEqualStrings(integrity.sha256[0..], outputString(created, "source_digest"));
    try std.testing.expectEqual(@as(usize, 1), source.resolves);
    try std.testing.expectEqual(@as(usize, 1), source.deinits);

    const request = harness.transport.requests.items[0];
    try std.testing.expectEqualStrings("POST", request.method);
    try std.testing.expectEqualStrings("application/gzip", request.content_type.?);
    try std.testing.expectEqualStrings(archive, request.body);
    try std.testing.expect(std.mem.indexOf(u8, request.url, "/upload/storage/v1/b/ziac-dev-builds/o?") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.url, "uploadType=media") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.url, "ifGenerationMatch=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.url, "name=sources%2F") != null);

    const observed_json = try created.observed_inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(observed_json);
    try std.testing.expect(std.mem.indexOf(u8, observed_json, archive) == null);
    const request_count = harness.transport.requests.items.len;
    try live.deleteWithContext(&context, object.node, created.physical_id);
    try std.testing.expectEqual(request_count, harness.transport.requests.items.len);
    try std.testing.expectError(
        error.InvalidConfiguration,
        live.importWithContext(&context, object.node, "gs://another-bucket/sources/wrong.tar.gz#1"),
    );
    try std.testing.expectEqual(request_count, harness.transport.requests.items.len);
}

test "live GCP source object import requires the requested generation" {
    const archive = "generation-pinned-source";
    const integrity = ziac.gcp.storage.integrity(archive);
    const object_name = try std.fmt.allocPrint(std.testing.allocator, "sources/{s}.tar.gz", .{integrity.sha256});
    defer std.testing.allocator.free(object_name);
    const object_json = try objectJsonAlloc(std.testing.allocator, object_name, integrity, "89");
    defer std.testing.allocator.free(object_json);
    const responses = [_]zstd.Http.Response{.{ .status = 200, .body = object_json }};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var object = try sourceObjectBuild(object_name, integrity);
    defer object.deinit(std.testing.allocator);
    const physical_id = try std.fmt.allocPrint(std.testing.allocator, "gs://ziac-dev-builds/{s}#88", .{object_name});
    defer std.testing.allocator.free(physical_id);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    try std.testing.expectError(error.InvalidConfiguration, live.importWithContext(&context, object.node, physical_id));
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[0].url, "?generation=88"));
}

test "live GCP source object adopts a matching precondition conflict" {
    const archive = "same-source-content";
    const integrity = ziac.gcp.storage.integrity(archive);
    const object_name = try std.fmt.allocPrint(std.testing.allocator, "sources/{s}.tar.gz", .{integrity.sha256});
    defer std.testing.allocator.free(object_name);
    const object_json = try objectJsonAlloc(std.testing.allocator, object_name, integrity, "88");
    defer std.testing.allocator.free(object_json);
    const responses = [_]zstd.Http.Response{
        conflict(),
        .{ .status = 200, .body = object_json },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var source = FixedPayloadSource{ .bytes = archive };
    harness.live.payload_source = source.payloadSource();
    var object = try sourceObjectBuild(object_name, integrity);
    defer object.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var adopted = try live.createWithContext(&context, object.node);
    defer adopted.deinit();
    try std.testing.expectEqualStrings("88", outputString(adopted, "generation"));
    try std.testing.expectEqual(@as(usize, 2), harness.transport.requests.items.len);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].url, "/storage/v1/b/ziac-dev-builds/o/sources%2F") != null);
}

test "live GCP source object rejects payload or remote integrity mismatches" {
    const archive = "expected-source";
    const integrity = ziac.gcp.storage.integrity(archive);
    const object_name = try std.fmt.allocPrint(std.testing.allocator, "sources/{s}.tar.gz", .{integrity.sha256});
    defer std.testing.allocator.free(object_name);
    var object = try sourceObjectBuild(object_name, integrity);
    defer object.deinit(std.testing.allocator);

    var preflight_harness: Harness = undefined;
    preflight_harness.init(&.{});
    defer preflight_harness.deinit();
    var tampered_source = FixedPayloadSource{ .bytes = "tampered" };
    preflight_harness.live.payload_source = tampered_source.payloadSource();
    const preflight_live = preflight_harness.live.provider();
    var preflight_context = ziac.provider.OperationContext.init(std.testing.allocator);
    try std.testing.expectError(error.InvalidConfiguration, preflight_live.createWithContext(&preflight_context, object.node));
    try std.testing.expectEqual(@as(usize, 0), preflight_harness.transport.requests.items.len);
    try std.testing.expectEqual(@as(usize, 1), tampered_source.deinits);

    const wrong_integrity = ziac.gcp.storage.integrity("different-source");
    const wrong_json = try objectJsonAlloc(std.testing.allocator, object_name, wrong_integrity, "89");
    defer std.testing.allocator.free(wrong_json);
    const responses = [_]zstd.Http.Response{
        conflict(),
        .{ .status = 200, .body = wrong_json },
    };
    var conflict_harness: Harness = undefined;
    conflict_harness.init(&responses);
    defer conflict_harness.deinit();
    var valid_source = FixedPayloadSource{ .bytes = archive };
    conflict_harness.live.payload_source = valid_source.payloadSource();
    const conflict_live = conflict_harness.live.provider();
    var conflict_context = ziac.provider.OperationContext.init(std.testing.allocator);
    try std.testing.expectError(error.Conflict, conflict_live.createWithContext(&conflict_context, object.node));
}

const Harness = struct {
    token_source: FixedTokenSource,
    cache: auth.TokenCache,
    transport: @import("gcp_client_test.zig").RecordingTransport,
    client: gclient.Client,
    live: ziac.gcp.live_provider.LiveProvider,

    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.token_source = .{};
        self.cache = auth.TokenCache.init(self.token_source.tokenSource(), 300);
        self.transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{
            .storage = "https://storage.example.test",
        });
        self.live = ziac.gcp.live_provider.LiveProvider.init(&self.client);
    }

    fn deinit(self: *Harness) void {
        self.transport.deinit();
        self.cache.deinit(std.testing.allocator);
        self.* = undefined;
    }
};

const FixedTokenSource = struct {
    fn tokenSource(self: *FixedTokenSource) auth.TokenSource {
        return .{ .ptr = self, .fetchFn = fetch };
    }

    fn fetch(_: *anyopaque, allocator: std.mem.Allocator, now_seconds: u64) auth.AuthError!auth.AccessToken {
        return auth.AccessToken.initOwned(allocator, .{
            .access_token = "dummy-google-token",
            .token_type = "Bearer",
            .expires_at_seconds = now_seconds + 3_600,
        });
    }
};

const FixedPayloadSource = struct {
    bytes: []const u8,
    expected_path: []const u8 = ".ziac/build/api.tar.gz",
    resolves: usize = 0,
    deinits: usize = 0,

    fn payloadSource(self: *FixedPayloadSource) storage_provider.PayloadSource {
        return .{ .ptr = self, .resolveFn = resolve };
    }

    fn resolve(
        raw: *anyopaque,
        _: *ziac.provider.OperationContext,
        allocator: std.mem.Allocator,
        source_path: []const u8,
    ) ziac.provider.ProviderError!storage_provider.Payload {
        const self: *FixedPayloadSource = @ptrCast(@alignCast(raw));
        if (!std.mem.eql(u8, source_path, self.expected_path)) return error.NotFound;
        self.resolves += 1;
        return storage_provider.Payload.initOwned(allocator, self.bytes, .{
            .ptr = self,
            .deinitFn = payloadDeinit,
        });
    }

    fn payloadDeinit(raw: *anyopaque) void {
        const self: *FixedPayloadSource = @ptrCast(@alignCast(raw));
        self.deinits += 1;
    }
};

fn sourceObjectBuild(object_name: []const u8, integrity: ziac.gcp.storage.Integrity) !ziac.gcp.storage.SourceObject {
    return ziac.gcp.storage.SourceObject.build(std.testing.allocator, config(), .{
        .name = "api-source",
        .bucket = .{ .value = "ziac-dev-builds" },
        .object_name = object_name,
        .source_path = ".ziac/build/api.tar.gz",
        .source_digest = integrity.sha256[0..],
        .size = integrity.size,
        .crc32c = integrity.crc32c[0..],
    });
}

fn generalBucket(delete_after_days: u32) !ziac.gcp.storage.Bucket {
    return ziac.gcp.storage.Bucket.build(std.testing.allocator, config(), .{
        .name = "ziac-user-uploads",
        .location = "EU",
        .versioning = true,
        .soft_delete_retention_seconds = 14 * 24 * 60 * 60,
        .retention_period_seconds = 24 * 60 * 60,
        .delete_after_days = delete_after_days,
        .default_kms_key_name = "projects/ziac-dev/locations/europe-west1/keyRings/app/cryptoKeys/storage",
        .retain_on_delete = false,
    });
}

fn generalBucketWithoutRetention(delete_after_days: u32) !ziac.gcp.storage.Bucket {
    return ziac.gcp.storage.Bucket.build(std.testing.allocator, config(), .{
        .name = "ziac-user-uploads",
        .location = "EU",
        .versioning = true,
        .soft_delete_retention_seconds = 14 * 24 * 60 * 60,
        .delete_after_days = delete_after_days,
        .retain_on_delete = false,
    });
}

fn advancedBucket() !ziac.gcp.storage.Bucket {
    return ziac.gcp.storage.Bucket.build(std.testing.allocator, config(), .{
        .name = "ziac-user-assets",
        .location = "EU",
        .versioning = true,
        .lifecycle_rules = &.{
            .{ .action = .{ .set_storage_class = .nearline }, .condition = .{ .age_days = 30, .matches_prefixes = &.{"archive/"}, .matches_storage_classes = &.{.standard} } },
            .{ .action = .delete, .condition = .{ .days_since_noncurrent_time = 14, .is_live = false, .num_newer_versions = 2 } },
        },
        .cors = &.{.{ .origins = &.{"https://app.example.com"}, .methods = &.{ .get, .head, .put }, .response_headers = &.{"content-type"}, .max_age_seconds = 3600 }},
    });
}

fn forceDestroyBucket() !ziac.gcp.storage.Bucket {
    return ziac.gcp.storage.Bucket.build(std.testing.allocator, config(), .{
        .name = "ziac-user-uploads",
        .location = "EU",
        .force_destroy = true,
        .retain_on_delete = false,
    });
}

fn bucketIamMember() !ziac.gcp.storage.BucketIamMember {
    return ziac.gcp.storage.BucketIamMember.build(std.testing.allocator, config(), .{
        .name = "api-object-viewer",
        .bucket = .{ .value = "ziac-user-uploads" },
        .role = "roles/storage.objectViewer",
        .member = "serviceAccount:api@ziac-dev.iam.gserviceaccount.com",
    });
}

fn conditionalBucketIamMember() !ziac.gcp.storage.BucketIamMember {
    return ziac.gcp.storage.BucketIamMember.build(std.testing.allocator, config(), .{
        .name = "temporary-uploader",
        .bucket = .{ .value = "ziac-user-uploads" },
        .role = "roles/storage.objectCreator",
        .member = "serviceAccount:uploader@ziac-dev.iam.gserviceaccount.com",
        .condition = .{
            .title = "upload-window",
            .description = "Temporary upload authority",
            .expression = "request.time < timestamp('2027-01-01T00:00:00Z')",
        },
    });
}

fn generalObject(object_integrity: ziac.gcp.storage.Integrity) !ziac.gcp.storage.Object {
    return ziac.gcp.storage.Object.build(std.testing.allocator, config(), .{
        .name = "site-index",
        .bucket = .{ .value = "ziac-user-assets" },
        .object_name = "public/index.html",
        .source_path = "site/index.html",
        .source_digest = &object_integrity.sha256,
        .size = object_integrity.size,
        .crc32c = &object_integrity.crc32c,
        .content_type = "text/html; charset=utf-8",
        .retain_on_delete = false,
    });
}

fn generalObjectJsonAlloc(allocator: std.mem.Allocator, object_integrity: ziac.gcp.storage.Integrity, generation: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"bucket\":\"ziac-user-assets\",\"name\":\"public/index.html\",\"generation\":\"{s}\",\"size\":\"{d}\",\"crc32c\":\"{s}\",\"contentType\":\"text/html; charset=utf-8\",\"selfLink\":\"https://storage.example/object\"}}",
        .{ generation, object_integrity.size, object_integrity.crc32c },
    );
}

fn objectJsonAlloc(
    allocator: std.mem.Allocator,
    object_name: []const u8,
    integrity: ziac.gcp.storage.Integrity,
    generation: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"bucket\":\"ziac-dev-builds\",\"name\":\"{s}\",\"generation\":\"{s}\",\"size\":\"{d}\",\"crc32c\":\"{s}\",\"selfLink\":\"https://storage.example/object\"}}",
        .{ object_name, generation, integrity.size, integrity.crc32c },
    );
}

fn outputString(result: ziac.provider.ResourceResult, name: []const u8) []const u8 {
    for (result.outputs) |item| {
        if (!std.mem.eql(u8, item.name, name)) continue;
        return switch (item.value) {
            .string => |text| text,
            else => unreachable,
        };
    }
    unreachable;
}

fn config() ziac.gcp.config.ProviderConfig {
    return .{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
        .service_regions = &.{"europe-west4"},
    };
}

fn notFound() zstd.Http.Response {
    return .{ .status = 404, .body = "{\"error\":{\"code\":404,\"status\":\"NOT_FOUND\",\"message\":\"missing\"}}" };
}

fn conflict() zstd.Http.Response {
    return .{ .status = 412, .body = "{\"error\":{\"code\":412,\"status\":\"FAILED_PRECONDITION\",\"message\":\"exists\"}}" };
}

fn bucketJson(comptime age: u32) []const u8 {
    return std.fmt.comptimePrint(
        "{{\"id\":\"ziac-dev-builds\",\"name\":\"ziac-dev-builds\",\"selfLink\":\"https://storage.googleapis.com/storage/v1/b/ziac-dev-builds\",\"location\":\"EUROPE-WEST1\",\"iamConfiguration\":{{\"uniformBucketLevelAccess\":{{\"enabled\":true}},\"publicAccessPrevention\":\"enforced\"}},\"versioning\":{{\"enabled\":true}},\"lifecycle\":{{\"rule\":[{{\"action\":{{\"type\":\"Delete\"}},\"condition\":{{\"age\":{d}}}}}]}}}}",
        .{age},
    );
}

fn generalBucketJson(comptime metageneration: u32, comptime delete_after_days: u32) []const u8 {
    return std.fmt.comptimePrint(
        "{{\"id\":\"ziac-user-uploads\",\"name\":\"ziac-user-uploads\",\"selfLink\":\"https://storage.googleapis.com/storage/v1/b/ziac-user-uploads\",\"location\":\"EU\",\"storageClass\":\"STANDARD\",\"metageneration\":\"{d}\",\"iamConfiguration\":{{\"uniformBucketLevelAccess\":{{\"enabled\":true}},\"publicAccessPrevention\":\"enforced\"}},\"versioning\":{{\"enabled\":true}},\"softDeletePolicy\":{{\"retentionDurationSeconds\":\"1209600\"}},\"retentionPolicy\":{{\"retentionPeriod\":\"86400\"}},\"lifecycle\":{{\"rule\":[{{\"action\":{{\"type\":\"Delete\"}},\"condition\":{{\"age\":{d}}}}}]}},\"encryption\":{{\"defaultKmsKeyName\":\"projects/ziac-dev/locations/europe-west1/keyRings/app/cryptoKeys/storage\"}},\"labels\":{{}}}}",
        .{ metageneration, delete_after_days },
    );
}

fn generalBucketWithoutRetentionJson(comptime metageneration: u32, comptime delete_after_days: u32) []const u8 {
    return std.fmt.comptimePrint(
        "{{\"id\":\"ziac-user-uploads\",\"name\":\"ziac-user-uploads\",\"selfLink\":\"https://storage.googleapis.com/storage/v1/b/ziac-user-uploads\",\"location\":\"EU\",\"storageClass\":\"STANDARD\",\"metageneration\":\"{d}\",\"iamConfiguration\":{{\"uniformBucketLevelAccess\":{{\"enabled\":true}},\"publicAccessPrevention\":\"enforced\"}},\"versioning\":{{\"enabled\":true}},\"softDeletePolicy\":{{\"retentionDurationSeconds\":\"1209600\"}},\"lifecycle\":{{\"rule\":[{{\"action\":{{\"type\":\"Delete\"}},\"condition\":{{\"age\":{d}}}}}]}},\"labels\":{{}}}}",
        .{ metageneration, delete_after_days },
    );
}
