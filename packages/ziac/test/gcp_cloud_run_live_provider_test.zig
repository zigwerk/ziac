const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;

test "live GCP Cloud Run lifecycle checkpoints and resumes operations" {
    const old_service = comptime serviceJson("api:v1", "api-00001-old");
    const new_service = comptime serviceJson("api:v2", "api-00002-new");
    const responses = [_]zstd.Http.Response{
        notFound(),
        operationStarted("create-api"),
        operationDone("create-api", old_service),
        operationStarted("update-api"),
        operationDone("update-api", new_service),
        operationStarted("delete-api"),
        .{ .status = 200, .body = "{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/delete-api\",\"done\":true}" },
        notFound(),
        .{ .status = 200, .body = new_service },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var service = try ziac.gcp.cloud_run.Service.build(std.testing.allocator, providerConfig(), .{
        .name = "api",
        .image = "api:v1",
    });
    defer service.deinit(std.testing.allocator);
    var changed = try ziac.gcp.cloud_run.Service.build(std.testing.allocator, providerConfig(), .{
        .name = "api",
        .image = "api:v2",
    });
    defer changed.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var before = try live.readWithContext(&context, service.node);
    defer before.deinit();
    try std.testing.expect(before == .absent);
    var creating = try live.createWithContext(&context, service.node);
    defer creating.deinit();
    try std.testing.expect(!creating.completed);
    try std.testing.expectEqualStrings("projects/ziac-dev/locations/europe-west1/operations/create-api", creating.operation_handle.?);
    context.physical_id = creating.physical_id;
    context.operation_handle = creating.operation_handle;
    var present = try live.readWithContext(&context, service.node);
    defer present.deinit();
    try std.testing.expect(present == .present);
    try std.testing.expectEqualStrings("https://api-europe-west1.example.run.app", present.present.outputs[0].value.string);
    try std.testing.expectEqualStrings("api-00001-old", present.present.outputs[2].value.string);
    var noop = try live.diffWithContext(&context, service.node, &present.present);
    defer noop.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.noop, noop.kind);
    var update_diff = try live.diffWithContext(&context, changed.node, &present.present);
    defer update_diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, update_diff.kind);

    context.operation_handle = null;
    var updating = try live.updateWithContext(&context, changed.node, &present.present);
    defer updating.deinit();
    try std.testing.expect(!updating.completed);
    context.physical_id = updating.physical_id;
    context.operation_handle = updating.operation_handle;
    var updated = try live.readWithContext(&context, changed.node);
    defer updated.deinit();
    try std.testing.expectEqual(changed.node.inputs_hash, updated.present.observed_hash);
    try std.testing.expectEqualStrings("api-00002-new", updated.present.outputs[2].value.string);

    context.operation_handle = null;
    try live.deleteWithContext(&context, changed.node, updating.physical_id);
    var gone = try live.readWithContext(&context, changed.node);
    defer gone.deinit();
    try std.testing.expect(gone == .absent);
    var imported = try live.importWithContext(&context, changed.node, updating.physical_id);
    defer imported.deinit();
    try std.testing.expectEqualStrings(updating.physical_id, imported.physical_id);

    try std.testing.expectEqualStrings(
        "https://run.example.test/v2/projects/ziac-dev/locations/europe-west1/services?serviceId=api",
        harness.transport.requests.items[1].url,
    );
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].url, "updateMask=") != null);
    try std.testing.expectEqualStrings(
        "https://run.example.test/v2/projects/ziac-dev/locations/europe-west1/operations/create-api",
        harness.transport.requests.items[2].url,
    );
}

test "live GCP Cloud Run request encodes runtime secrets probes volumes and Direct VPC" {
    const responses = [_]zstd.Http.Response{operationStarted("create-rich")};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const tags = [_][]const u8{"database"};
    const env = [_]ziac.gcp.cloud_run.EnvVar{
        .{ .name = "MODE", .value = "production" },
        .{
            .name = "DATABASE_URL",
            .value = "sentinel-secret-for-tests",
            .secret = true,
            .secret_name = "projects/ziac-dev/secrets/database-url",
            .secret_version = "7",
        },
    };
    const volumes = [_]ziac.gcp.cloud_run.SecretVolume{.{
        .name = "database-ca",
        .secret = "projects/ziac-dev/secrets/database-ca",
        .version = "3",
        .path = "ca.crt",
        .mount_path = "/var/run/secrets/database",
    }};
    var service = try ziac.gcp.cloud_run.Service.build(std.testing.allocator, providerConfig(), .{
        .name = "api",
        .image = "api@sha256:abc",
        .command = &.{"/app/server"},
        .args = &.{"serve"},
        .cpu = "2",
        .memory = "1Gi",
        .concurrency = 40,
        .timeout_seconds = 90,
        .min_instances = 2,
        .max_instances = 20,
        .startup_probe = .{ .path = "/startup" },
        .liveness_probe = .{ .path = "/live" },
        .readiness_probe = .{ .path = "/ready" },
        .env = &env,
        .secret_volumes = &volumes,
        .direct_vpc = .{
            .network = "projects/ziac-dev/global/networks/runtime",
            .subnetwork = "projects/ziac-dev/regions/europe-west1/subnetworks/runtime",
            .tags = &tags,
            .egress = .all_traffic,
        },
    });
    defer service.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var creating = try harness.live.provider().createWithContext(&context, service.node);
    defer creating.deinit();
    const body = harness.transport.requests.items[0].body;

    for ([_][]const u8{
        "\"ingress\":\"INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER\"",
        "\"image\":\"api@sha256:abc\"",
        "\"containerPort\":8080",
        "\"cpu\":\"2\"",
        "\"memory\":\"1Gi\"",
        "\"maxInstanceRequestConcurrency\":40",
        "\"timeout\":\"90s\"",
        "\"minInstanceCount\":2",
        "\"maxInstanceCount\":20",
        "\"startupProbe\"",
        "\"livenessProbe\"",
        "\"readinessProbe\"",
        "\"secretKeyRef\":{\"secret\":\"projects/ziac-dev/secrets/database-url\",\"version\":\"7\"}",
        "\"mountPath\":\"/var/run/secrets/database\"",
        "\"networkInterfaces\"",
        "\"egress\":\"ALL_TRAFFIC\"",
    }) |expected| try std.testing.expect(std.mem.indexOf(u8, body, expected) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "sentinel-secret-for-tests") == null);
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
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{ .run = "https://run.example.test" });
        self.live = ziac.gcp.live_provider.LiveProvider.init(&self.client);
        self.live.operation_policy = .{ .poll_interval_millis = 10 };
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

fn providerConfig() ziac.gcp.config.ProviderConfig {
    return .{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
        .service_account = "runtime@ziac-dev.iam.gserviceaccount.com",
    };
}

fn notFound() zstd.Http.Response {
    return .{ .status = 404, .body = "{\"error\":{\"code\":404,\"status\":\"NOT_FOUND\",\"message\":\"missing\"}}" };
}

fn operationStarted(comptime operation_id: []const u8) zstd.Http.Response {
    return .{
        .status = 200,
        .body = "{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/" ++ operation_id ++ "\"}",
    };
}

fn operationDone(comptime operation_id: []const u8, comptime service: []const u8) zstd.Http.Response {
    return .{
        .status = 200,
        .body = "{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/" ++ operation_id ++ "\",\"done\":true,\"response\":" ++ service ++ "}",
    };
}

fn serviceJson(comptime image: []const u8, comptime revision: []const u8) []const u8 {
    return "{\"name\":\"projects/ziac-dev/locations/europe-west1/services/api\",\"labels\":{},\"ingress\":\"INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER\",\"invokerIamDisabled\":false,\"uri\":\"https://api-europe-west1.example.run.app\",\"latestReadyRevision\":\"" ++ revision ++ "\",\"template\":{\"serviceAccount\":\"runtime@ziac-dev.iam.gserviceaccount.com\",\"timeout\":\"300s\",\"maxInstanceRequestConcurrency\":80,\"scaling\":{\"minInstanceCount\":0,\"maxInstanceCount\":100},\"containers\":[{\"image\":\"" ++ image ++ "\",\"command\":[],\"args\":[],\"env\":[],\"resources\":{\"limits\":{\"cpu\":\"1\",\"memory\":\"512Mi\"}},\"ports\":[{\"containerPort\":8080}],\"volumeMounts\":[]}],\"volumes\":[]}}";
}
