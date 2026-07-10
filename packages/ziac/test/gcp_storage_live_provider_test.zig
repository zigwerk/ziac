const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;
const storage_provider = ziac.gcp.storage_provider;

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
        if (!std.mem.eql(u8, source_path, ".ziac/build/api.tar.gz")) return error.NotFound;
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
