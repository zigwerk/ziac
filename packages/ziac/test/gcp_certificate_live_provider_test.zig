const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;

const regions = [_][]const u8{ "europe-west1", "us-central1" };
const config = ziac.gcp.config.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
    .service_regions = &regions,
    .network_tier = .premium,
};

test "live Compute provider exposes managed certificate provisioning status" {
    var certificate = try ziac.gcp.compute.ManagedSslCertificate.build(std.testing.allocator, config, .{
        .name = "api-cert",
        .domains = &.{"api.example.com"},
    });
    defer certificate.deinit(std.testing.allocator);
    const responses = [_]zstd.Http.Response{
        notFound(),
        operation("insert-certificate"),
        done("insert-certificate"),
        certificateResponse("PROVISIONING", "PROVISIONING"),
        operation("delete-certificate"),
        done("delete-certificate"),
        notFound(),
        certificateResponse("ACTIVE", "ACTIVE"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const provider = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var before = try provider.readWithContext(&context, certificate.node);
    defer before.deinit();
    try std.testing.expect(before == .absent);
    var creating = try provider.createWithContext(&context, certificate.node);
    defer creating.deinit();
    try std.testing.expect(!creating.completed);
    context.physical_id = creating.physical_id;
    context.operation_handle = creating.operation_handle;
    var provisioning = try provider.readWithContext(&context, certificate.node);
    defer provisioning.deinit();
    try std.testing.expectEqualStrings("PROVISIONING", outputString(provisioning.present, "status"));
    try std.testing.expect(!outputBool(provisioning.present, "domains_ready"));

    context.operation_handle = null;
    try provider.deleteWithContext(&context, certificate.node, creating.physical_id);
    var gone = try provider.readWithContext(&context, certificate.node);
    defer gone.deinit();
    try std.testing.expect(gone == .absent);
    var imported = try provider.importWithContext(&context, certificate.node, creating.physical_id);
    defer imported.deinit();
    try std.testing.expectEqualStrings("ACTIVE", outputString(imported, "status"));
    try std.testing.expect(outputBool(imported, "domains_ready"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"type\":\"MANAGED\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"domains\":[\"api.example.com\"]") != null);
}

test "managed certificate readiness polling is explicit and separate from create" {
    const responses = [_]zstd.Http.Response{
        .{ .status = 503, .body = "{\"error\":{\"code\":503,\"status\":\"UNAVAILABLE\",\"message\":\"retry\"}}" },
        certificateResponse("PROVISIONING", "PROVISIONING"),
        certificateResponse("ACTIVE", "ACTIVE"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    try ziac.gcp.compute_provider.waitManagedSslCertificateReady(
        &harness.client,
        &context,
        "projects/ziac-dev/global/sslCertificates/api-cert",
        .{ .poll_interval_millis = 1 },
    );
    try std.testing.expectEqual(@as(usize, 3), harness.transport.requests.items.len);
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[2].url, "/compute/v1/projects/ziac-dev/global/sslCertificates/api-cert"));
}

test "managed certificate readiness reports terminal provisioning failure" {
    const responses = [_]zstd.Http.Response{certificateResponse("FAILED_NOT_VISIBLE", "FAILED_NOT_VISIBLE")};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    try std.testing.expectError(
        error.InvalidConfiguration,
        ziac.gcp.compute_provider.waitManagedSslCertificateReady(
            &harness.client,
            &context,
            "projects/ziac-dev/global/sslCertificates/api-cert",
            .{ .poll_interval_millis = 1 },
        ),
    );
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
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{ .compute = "https://compute.example.test" });
        self.live = ziac.gcp.live_provider.LiveProvider.init(&self.client);
        self.live.operation_policy = .{ .poll_interval_millis = 1 };
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

fn outputString(result: ziac.provider.ResourceResult, name: []const u8) []const u8 {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name)) return item.value.string;
    unreachable;
}

fn outputBool(result: ziac.provider.ResourceResult, name: []const u8) bool {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name)) return item.value.boolean;
    unreachable;
}

fn notFound() zstd.Http.Response {
    return .{ .status = 404, .body = "{\"error\":{\"code\":404,\"status\":\"NOT_FOUND\",\"message\":\"missing\"}}" };
}

fn operation(comptime name: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = "{\"name\":\"" ++ name ++ "\"}" };
}

fn done(comptime name: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = "{\"name\":\"" ++ name ++ "\",\"status\":\"DONE\"}" };
}

fn certificateResponse(comptime status: []const u8, comptime domain_status: []const u8) zstd.Http.Response {
    return .{
        .status = 200,
        .body = "{\"name\":\"api-cert\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/global/sslCertificates/api-cert\",\"type\":\"MANAGED\",\"managed\":{\"domains\":[\"api.example.com\"],\"status\":\"" ++ status ++ "\",\"domainStatus\":{\"api.example.com\":\"" ++ domain_status ++ "\"}}}",
    };
}
