const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;

const source_digest = "1111111111111111111111111111111111111111111111111111111111111111";
const build_digest = "2222222222222222222222222222222222222222222222222222222222222222";
const changed_build_digest = "5555555555555555555555555555555555555555555555555555555555555555";
const image_digest = "sha256:3333333333333333333333333333333333333333333333333333333333333333";
const docker_builder = "gcr.io/cloud-builders/docker@sha256:4444444444444444444444444444444444444444444444444444444444444444";
const repository = "europe-west1-docker.pkg.dev/ziac-dev/services";
const target_image = repository ++ "/api:ziac-" ++ build_digest;
const final_image = repository ++ "/api@" ++ image_digest;
const physical_id = "projects/ziac-dev/locations/europe-west1/builds/build-123";
const operation_id = "operations/build/ziac-dev/europe-west1/build-123";

test "live GCP provider starts a regional generation-pinned Zig image build" {
    const build_service_account = "projects/ziac-dev/serviceAccounts/ziac-build@ziac-dev.iam.gserviceaccount.com";
    const queued = try buildJsonAlloc(std.testing.allocator, .{ .status = "QUEUED", .service_account = build_service_account });
    defer std.testing.allocator.free(queued);
    const operation_json = try operationJsonAlloc(std.testing.allocator, queued);
    defer std.testing.allocator.free(operation_json);
    const responses = [_]zstd.Http.Response{.{ .status = 200, .body = operation_json }};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var image = try buildImageWithServiceAccount(build_digest, build_service_account);
    defer image.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try live.createWithContext(&context, image.node);
    defer pending.deinit();
    try std.testing.expect(!pending.completed);
    try std.testing.expectEqualStrings(physical_id, pending.physical_id);
    try std.testing.expectEqualStrings(operation_id, pending.operation_handle.?);
    try std.testing.expectEqual(@as(usize, 0), pending.outputs.len);

    const request = harness.transport.requests.items[0];
    try std.testing.expectEqualStrings("POST", request.method);
    try std.testing.expectEqualStrings(
        "https://cloudbuild.example.test/v1/projects/ziac-dev/locations/europe-west1/builds",
        request.url,
    );
    try expectContains(request.body, "\"bucket\":\"ziac-dev-builds\"");
    try expectContains(request.body, "\"object\":\"sources/" ++ source_digest ++ ".tar.gz\"");
    try expectContains(request.body, "\"generation\":\"171234\"");
    try expectContains(request.body, "\"sourceFetcher\":\"GCS_FETCHER\"");
    try expectContains(request.body, "\"name\":\"" ++ docker_builder ++ "\"");
    try expectContains(request.body, "\"Dockerfile.ziac\"");
    try expectContains(request.body, "\"images\":[\"" ++ target_image ++ "\"]");
    try expectContains(request.body, "\"timeout\":\"1200s\"");
    try expectContains(request.body, "\"queueTtl\":\"3600s\"");
    try expectContains(request.body, "\"logging\":\"CLOUD_LOGGING_ONLY\"");
    try expectContains(request.body, "\"machineType\":\"E2_HIGHCPU_8\"");
    try expectContains(request.body, "\"dynamicSubstitutions\":false");
    try expectContains(request.body, "\"serviceAccount\":\"" ++ build_service_account ++ "\"");
    try expectContains(request.body, "\"ziac-build-" ++ build_digest ++ "\"");
    try expectContains(request.body, "\"ziac-source-" ++ source_digest ++ "\"");

    const request_count = harness.transport.requests.items.len;
    try live.deleteWithContext(&context, image.node, pending.physical_id);
    try std.testing.expectEqual(request_count, harness.transport.requests.items.len);
}

test "live GCP provider polls a build and returns only the immutable image digest" {
    const working = try buildJsonAlloc(std.testing.allocator, .{ .status = "WORKING" });
    defer std.testing.allocator.free(working);
    const success = try buildJsonAlloc(std.testing.allocator, .{ .status = "SUCCESS", .include_result = true });
    defer std.testing.allocator.free(success);
    const responses = [_]zstd.Http.Response{
        .{ .status = 200, .body = working },
        .{ .status = 200, .body = success },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    harness.live.cloud_build_poll_policy = .{ .poll_interval_millis = 25 };
    var image = try buildImage(build_digest);
    defer image.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var clock = ziac.fx.Clock.fake(0);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    context.clock = &clock;
    context.physical_id = physical_id;
    context.operation_handle = operation_id;

    var read = try live.readWithContext(&context, image.node);
    defer read.deinit();
    try std.testing.expect(read == .present);
    try std.testing.expectEqualStrings(final_image, outputString(read.present, "image_ref"));
    try std.testing.expectEqualStrings(image_digest, outputString(read.present, "image_digest"));
    try std.testing.expectEqualStrings("build-123", outputString(read.present, "build_id"));
    try std.testing.expectEqualStrings("https://console.cloud.google.com/cloud-build/builds;region=europe-west1/build-123", outputString(read.present, "log_url"));
    try std.testing.expectEqual(@as(u64, 25), clock.nowMs());
    try std.testing.expectEqualStrings(harness.transport.requests.items[0].url, harness.transport.requests.items[1].url);

    var noop = try live.diffWithContext(&context, image.node, &read.present);
    defer noop.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.noop, noop.kind);
    var changed = try buildImage(changed_build_digest);
    defer changed.deinit(std.testing.allocator);
    var replacement = try live.diffWithContext(&context, changed.node, &read.present);
    defer replacement.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.replace, replacement.kind);
}

test "live GCP provider recovers an uncheckpointed build by content tag" {
    const queued = try buildJsonAlloc(std.testing.allocator, .{ .status = "QUEUED" });
    defer std.testing.allocator.free(queued);
    const success = try buildJsonAlloc(std.testing.allocator, .{ .status = "SUCCESS", .include_result = true });
    defer std.testing.allocator.free(success);
    const list_json = try listJsonAlloc(std.testing.allocator, queued);
    defer std.testing.allocator.free(list_json);
    const responses = [_]zstd.Http.Response{
        .{ .status = 200, .body = list_json },
        .{ .status = 200, .body = success },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var image = try buildImage(build_digest);
    defer image.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var recovered = try live.readWithContext(&context, image.node);
    defer recovered.deinit();
    try std.testing.expect(recovered == .present);
    try std.testing.expectEqualStrings(final_image, outputString(recovered.present, "image_ref"));
    try expectContains(harness.transport.requests.items[0].url, "/v1/projects/ziac-dev/locations/europe-west1/builds?");
    try expectContains(harness.transport.requests.items[0].url, "filter=tags%3D%27ziac-build-");
    try expectContains(harness.transport.requests.items[0].url, "pageSize=20");
    try std.testing.expectEqualStrings(
        "https://cloudbuild.example.test/v1/" ++ physical_id,
        harness.transport.requests.items[1].url,
    );
}

test "live GCP provider refuses tag collisions and failed builds" {
    const collision = try buildJsonAlloc(std.testing.allocator, .{
        .status = "SUCCESS",
        .source_object = "sources/not-the-requested-object.tar.gz",
        .include_result = true,
    });
    defer std.testing.allocator.free(collision);
    const collision_list = try listJsonAlloc(std.testing.allocator, collision);
    defer std.testing.allocator.free(collision_list);
    const collision_responses = [_]zstd.Http.Response{.{ .status = 200, .body = collision_list }};
    var collision_harness: Harness = undefined;
    collision_harness.init(&collision_responses);
    defer collision_harness.deinit();
    var image = try buildImage(build_digest);
    defer image.deinit(std.testing.allocator);
    const collision_live = collision_harness.live.provider();
    var collision_context = ziac.provider.OperationContext.init(std.testing.allocator);
    try std.testing.expectError(error.Conflict, collision_live.readWithContext(&collision_context, image.node));

    const failed = try buildJsonAlloc(std.testing.allocator, .{ .status = "FAILURE", .failure_detail = "compile failed: sentinel-secret-for-tests" });
    defer std.testing.allocator.free(failed);
    const failed_responses = [_]zstd.Http.Response{.{ .status = 200, .body = failed }};
    var failed_harness: Harness = undefined;
    failed_harness.init(&failed_responses);
    defer failed_harness.deinit();
    const failed_live = failed_harness.live.provider();
    var failed_context = ziac.provider.OperationContext.init(std.testing.allocator);
    failed_context.physical_id = physical_id;
    try std.testing.expectError(error.RemoteOperationFailed, failed_live.readWithContext(&failed_context, image.node));
    try std.testing.expectEqual(@as(usize, 1), failed_harness.failure_reporter.reports);
    try std.testing.expect(failed_harness.failure_reporter.was_redacted);
    try std.testing.expect(failed_harness.failure_reporter.has_log_url);
}

test "live GCP provider classifies every terminal Cloud Build status" {
    const statuses = [_][]const u8{ "FAILURE", "INTERNAL_ERROR", "TIMEOUT", "CANCELLED", "EXPIRED" };
    const expected = [_]ziac.provider.ProviderError{
        error.RemoteOperationFailed,
        error.RemoteOperationFailed,
        error.ProviderTimeout,
        error.ProviderCancelled,
        error.ProviderTimeout,
    };
    var image = try buildImage(build_digest);
    defer image.deinit(std.testing.allocator);

    for (statuses, expected) |status_name, expected_error| {
        const terminal = try buildJsonAlloc(std.testing.allocator, .{
            .status = status_name,
            .failure_detail = "bounded terminal failure detail",
        });
        defer std.testing.allocator.free(terminal);
        const responses = [_]zstd.Http.Response{.{ .status = 200, .body = terminal }};
        var harness: Harness = undefined;
        harness.init(&responses);
        defer harness.deinit();
        const live = harness.live.provider();
        var context = ziac.provider.OperationContext.init(std.testing.allocator);
        context.physical_id = physical_id;
        try std.testing.expectError(expected_error, live.readWithContext(&context, image.node));
    }
}

test "live GCP build polling honors caller deadlines and cancellation" {
    const working = try buildJsonAlloc(std.testing.allocator, .{ .status = "PENDING" });
    defer std.testing.allocator.free(working);
    const responses = [_]zstd.Http.Response{.{ .status = 200, .body = working }};
    var timeout_harness: Harness = undefined;
    timeout_harness.init(&responses);
    defer timeout_harness.deinit();
    timeout_harness.live.cloud_build_poll_policy = .{ .poll_interval_millis = 25 };
    var image = try buildImage(build_digest);
    defer image.deinit(std.testing.allocator);
    const timeout_live = timeout_harness.live.provider();
    var clock = ziac.fx.Clock.fake(0);
    var timeout_context = ziac.provider.OperationContext.init(std.testing.allocator);
    timeout_context.clock = &clock;
    timeout_context.deadline_millis = 20;
    timeout_context.physical_id = physical_id;
    try std.testing.expectError(error.ProviderTimeout, timeout_live.readWithContext(&timeout_context, image.node));
    try std.testing.expectEqual(@as(usize, 1), timeout_harness.transport.requests.items.len);

    var cancelled_harness: Harness = undefined;
    cancelled_harness.init(&.{});
    defer cancelled_harness.deinit();
    const cancelled_live = cancelled_harness.live.provider();
    var cancelled = true;
    var cancelled_context = ziac.provider.OperationContext.init(std.testing.allocator);
    cancelled_context.physical_id = physical_id;
    cancelled_context.cancellation = .{ .ptr = &cancelled, .isCancelledFn = boolCancelled };
    try std.testing.expectError(error.ProviderCancelled, cancelled_live.readWithContext(&cancelled_context, image.node));
    try std.testing.expectEqual(@as(usize, 0), cancelled_harness.transport.requests.items.len);
}

test "live GCP build import validates its canonical project and region before HTTP" {
    var harness: Harness = undefined;
    harness.init(&.{});
    defer harness.deinit();
    var image = try buildImage(build_digest);
    defer image.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    try std.testing.expectError(
        error.InvalidConfiguration,
        live.importWithContext(&context, image.node, "projects/another/locations/us-central1/builds/build-123"),
    );
    try std.testing.expectEqual(@as(usize, 0), harness.transport.requests.items.len);
}

const Harness = struct {
    token_source: FixedTokenSource,
    cache: auth.TokenCache,
    transport: @import("gcp_client_test.zig").RecordingTransport,
    client: gclient.Client,
    live: ziac.gcp.live_provider.LiveProvider,
    failure_reporter: RecordingFailureReporter,

    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.token_source = .{};
        self.cache = auth.TokenCache.init(self.token_source.tokenSource(), 300);
        self.transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{
            .cloud_build = "https://cloudbuild.example.test",
        });
        self.live = ziac.gcp.live_provider.LiveProvider.init(&self.client);
        self.failure_reporter = .{};
        self.live.cloud_build_failure_reporter = self.failure_reporter.reporter();
    }

    fn deinit(self: *Harness) void {
        self.transport.deinit();
        self.cache.deinit(std.testing.allocator);
        self.* = undefined;
    }
};

const RecordingFailureReporter = struct {
    reports: usize = 0,
    was_redacted: bool = false,
    has_log_url: bool = false,

    fn reporter(self: *RecordingFailureReporter) ziac.gcp.cloud_build_provider.FailureReporter {
        return .{ .ptr = self, .reportFn = report };
    }

    fn report(raw: *anyopaque, _: []const u8, diagnostic: []const u8) void {
        const self: *RecordingFailureReporter = @ptrCast(@alignCast(raw));
        self.reports += 1;
        self.was_redacted = std.mem.indexOf(u8, diagnostic, "sentinel-secret-for-tests") == null and
            std.mem.indexOf(u8, diagnostic, "[REDACTED]") != null;
        self.has_log_url = std.mem.indexOf(u8, diagnostic, "https://console.cloud.google.com/cloud-build/") != null;
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

fn buildImage(digest: []const u8) !ziac.gcp.cloud_build.ZigImage {
    return buildImageWithServiceAccount(digest, null);
}

fn buildImageWithServiceAccount(digest: []const u8, service_account: ?[]const u8) !ziac.gcp.cloud_build.ZigImage {
    return ziac.gcp.cloud_build.ZigImage.build(std.testing.allocator, config(), .{
        .name = "api-image",
        .location = "europe-west1",
        .source_bucket = .{ .value = "ziac-dev-builds" },
        .source_object = .{ .value = "sources/" ++ source_digest ++ ".tar.gz" },
        .source_generation = .{ .value = "171234" },
        .source_digest = source_digest,
        .build_digest = digest,
        .repository = .{ .value = repository },
        .image_name = "api",
        .docker_builder = docker_builder,
        .service_account = service_account,
    });
}

const BuildFixture = struct {
    status: []const u8,
    source_object: []const u8 = "sources/" ++ source_digest ++ ".tar.gz",
    include_result: bool = false,
    failure_detail: ?[]const u8 = null,
    service_account: ?[]const u8 = null,
};

const StorageSource = struct {
    bucket: []const u8,
    object: []const u8,
    generation: []const u8,
    sourceFetcher: []const u8,
};

const Source = struct { storageSource: StorageSource };
const BuildStep = struct { name: []const u8, args: []const []const u8 };
const BuildOptions = struct {
    logging: []const u8,
    machineType: []const u8,
    dynamicSubstitutions: bool,
};
const BuiltImage = struct { name: []const u8, digest: []const u8, artifactRegistryPackage: []const u8 };
const BuildResults = struct { images: []const BuiltImage };
const FailureInfo = struct { detail: []const u8, type: []const u8 = "USER_BUILD_STEP" };

const RemoteBuild = struct {
    name: []const u8,
    id: []const u8,
    projectId: []const u8,
    status: []const u8,
    source: Source,
    steps: []const BuildStep,
    results: ?BuildResults,
    timeout: []const u8,
    images: []const []const u8,
    queueTtl: []const u8,
    options: BuildOptions,
    logUrl: []const u8,
    tags: []const []const u8,
    failureInfo: ?FailureInfo,
    serviceAccount: ?[]const u8,
};

fn buildJsonAlloc(allocator: std.mem.Allocator, fixture: BuildFixture) ![]const u8 {
    const args = [_][]const u8{ "build", "--file", "Dockerfile.ziac", "--tag", target_image, "." };
    const steps = [_]BuildStep{.{ .name = docker_builder, .args = &args }};
    const images = [_][]const u8{target_image};
    const tags = [_][]const u8{ "ziac", "ziac-build-" ++ build_digest, "ziac-source-" ++ source_digest };
    const built_images = [_]BuiltImage{.{
        .name = target_image,
        .digest = image_digest,
        .artifactRegistryPackage = "projects/ziac-dev/locations/europe-west1/repositories/services/packages/api/versions/sha256:3333",
    }};
    const remote = RemoteBuild{
        .name = physical_id,
        .id = "build-123",
        .projectId = "ziac-dev",
        .status = fixture.status,
        .source = .{ .storageSource = .{
            .bucket = "ziac-dev-builds",
            .object = fixture.source_object,
            .generation = "171234",
            .sourceFetcher = "GCS_FETCHER",
        } },
        .steps = &steps,
        .results = if (fixture.include_result) .{ .images = &built_images } else null,
        .timeout = "1200s",
        .images = &images,
        .queueTtl = "3600s",
        .options = .{
            .logging = "CLOUD_LOGGING_ONLY",
            .machineType = "E2_HIGHCPU_8",
            .dynamicSubstitutions = false,
        },
        .logUrl = "https://console.cloud.google.com/cloud-build/builds;region=europe-west1/build-123",
        .tags = &tags,
        .failureInfo = if (fixture.failure_detail) |detail| .{ .detail = detail } else null,
        .serviceAccount = fixture.service_account,
    };
    return std.json.Stringify.valueAlloc(allocator, remote, .{});
}

fn operationJsonAlloc(allocator: std.mem.Allocator, build_json: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{{\"name\":\"{s}\",\"metadata\":{{\"@type\":\"type.googleapis.com/google.devtools.cloudbuild.v1.BuildOperationMetadata\",\"build\":{s}}}}}", .{ operation_id, build_json });
}

fn listJsonAlloc(allocator: std.mem.Allocator, build_json: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{{\"builds\":[{s}]}}", .{build_json});
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

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn config() ziac.gcp.config.ProviderConfig {
    return .{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
}

fn boolCancelled(raw: *const anyopaque) bool {
    const cancelled: *const bool = @ptrCast(@alignCast(raw));
    return cancelled.*;
}
