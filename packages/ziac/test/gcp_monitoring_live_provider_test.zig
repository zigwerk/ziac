const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;
const monitoring = ziac.gcp.monitoring;

test "notification channel creation resolves secrets only into the request" {
    const responses = [_]zstd.Http.Response{ok(channelJson("Platform Slack"))};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var secrets = FixedSecretSource{};
    const handler = ziac.gcp.monitoring_provider.Handler{
        .client = &harness.client,
        .secret_source = secrets.secretSource(),
    };
    var channel = try buildChannel("Platform Slack");
    defer channel.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try handler.create(&context, channel.node);
    defer created.deinit();

    try std.testing.expect(created.completed);
    try std.testing.expectEqualStrings("projects/ziac-dev/notificationChannels/123", created.physical_id);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].url, "/v3/projects/ziac-dev/notificationChannels") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "live-channel-token") != null);
    const observed = try created.observed_inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(observed);
    try std.testing.expect(std.mem.indexOf(u8, observed, "live-channel-token") == null);
    try std.testing.expect(std.mem.indexOf(u8, observed, "channel-token") != null);
    try std.testing.expectEqualStrings("UNVERIFIED", outputValue(created, "verification_status").string);
}

test "generated monitoring IDs import canonically and public drift patches with masks" {
    const responses = [_]zstd.Http.Response{
        ok(channelJson("Remote drift")),
        ok(channelJson("Platform Slack")),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var secrets = FixedSecretSource{};
    const handler = ziac.gcp.monitoring_provider.Handler{
        .client = &harness.client,
        .secret_source = secrets.secretSource(),
    };
    var desired = try buildChannel("Platform Slack");
    defer desired.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var imported = try handler.importResource(&context, desired.node, "projects/ziac-dev/notificationChannels/123");
    defer imported.deinit();
    var diff = try ziac.gcp.monitoring_provider.Handler.diff(&context, desired.node, &imported);
    defer diff.deinit();
    try std.testing.expect(diff.kind == .update);
    var updated = try handler.update(&context, desired.node, &imported);
    defer updated.deinit();

    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].url, "updateMask=description%2CdisplayName%2Cenabled%2Clabels%2Ctype%2CuserLabels") != null);
    try std.testing.expectError(error.InvalidConfiguration, handler.importResource(&context, desired.node, "projects/other/notificationChannels/123"));
}

test "dashboard updates carry fresh etags and retry one precondition conflict" {
    const responses = [_]zstd.Http.Response{
        ok(dashboardJson("etag-a")),
        precondition(),
        ok(dashboardJson("etag-b")),
        ok(dashboardJson("etag-c")),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.monitoring_provider.Handler{ .client = &harness.client, .conflict_retries = 1 };
    var dashboard = try buildDashboard();
    defer dashboard.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var observed = try ziac.provider.ResourceResult.init(
        std.testing.allocator,
        "projects/ziac-dev/dashboards/abc",
        dashboard.node.inputs,
        &.{.{ .name = "etag", .value = .{ .string = "stale" } }},
        null,
    );
    defer observed.deinit();

    var updated = try handler.update(&context, dashboard.node, &observed);
    defer updated.deinit();

    try std.testing.expectEqualStrings("GET", harness.transport.requests.items[0].method);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "etag-a") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].body, "etag-b") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].url, "updateMask=displayName%2Clabels%2CmosaicLayout") != null);
    try std.testing.expectEqualStrings("etag-c", outputValue(updated, "etag").string);
}

test "services and SLOs use caller selected IDs and synchronous REST paths" {
    const responses = [_]zstd.Http.Response{
        ok(serviceJson()),
        ok(sloJson()),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.monitoring_provider.Handler{ .client = &harness.client };
    var service = try buildService();
    defer service.deinit(std.testing.allocator);
    var slo = try buildSlo(service.name);
    defer slo.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created_service = try handler.create(&context, service.node);
    defer created_service.deinit();
    var created_slo = try handler.create(&context, slo.node);
    defer created_slo.deinit();

    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[0].url, "/v3/projects/ziac-dev/services?serviceId=global-api"));
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[1].url, "/v3/projects/ziac-dev/services/global-api/serviceLevelObjectives?serviceLevelObjectiveId=availability-999"));
    try std.testing.expectEqualStrings("projects/ziac-dev/services/global-api", created_service.physical_id);
    try std.testing.expectEqualStrings("projects/ziac-dev/services/global-api/serviceLevelObjectives/availability-999", created_slo.physical_id);
}

fn buildChannel(display_name: []const u8) !monitoring.NotificationChannel {
    return monitoring.NotificationChannel.build(std.testing.allocator, config(), .{
        .name = "platform-slack",
        .display_name = display_name,
        .type = "slack",
        .labels = &.{.{ .key = "channel_name", .value = "#platform" }},
        .secret_labels = &.{.{ .key = "auth_token", .value = secret("projects/ziac-dev/secrets/channel-token") }},
        .user_labels = &.{.{ .key = "environment", .value = "prod" }},
    });
}

fn buildDashboard() !monitoring.Dashboard {
    return monitoring.Dashboard.build(std.testing.allocator, config(), .{
        .name = "global-api",
        .display_name = "Global API",
        .tiles = &.{.{
            .x = 0,
            .y = 0,
            .width = 24,
            .height = 8,
            .widget = .{ .text = .{ .content = "## Global API" } },
        }},
    });
}

fn buildService() !monitoring.Service {
    return monitoring.Service.build(std.testing.allocator, config(), .{
        .name = "global-api",
        .display_name = "Global API",
        .kind = .{ .cloud_run = .{ .service_name = "global-api", .location = "europe-west1" } },
    });
}

fn buildSlo(service: ziac.PublicOutput([]const u8)) !monitoring.ServiceLevelObjective {
    return monitoring.ServiceLevelObjective.build(std.testing.allocator, config(), .{
        .name = "availability-999",
        .service_name = "global-api",
        .service = service,
        .display_name = "99.9% availability",
        .goal = 0.999,
        .period = .{ .rolling = 2_592_000 },
        .indicator = .{ .basic = .availability },
    });
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
}

fn known(text: []const u8) ziac.PublicOutput([]const u8) {
    return .known(text);
}

fn secret(resource_name: []const u8) ziac.SecretOutput(ziac.value.SecretReference) {
    return .known(.{ .provider = "gcp-secret-manager", .resource = resource_name, .version = "1" });
}

fn channelJson(display_name: []const u8) []const u8 {
    if (std.mem.eql(u8, display_name, "Platform Slack")) return "{\"name\":\"projects/ziac-dev/notificationChannels/123\",\"type\":\"slack\",\"displayName\":\"Platform Slack\",\"description\":\"\",\"labels\":{\"channel_name\":\"#platform\",\"auth_token\":\"******\"},\"userLabels\":{\"environment\":\"prod\"},\"enabled\":true,\"verificationStatus\":\"UNVERIFIED\"}";
    return "{\"name\":\"projects/ziac-dev/notificationChannels/123\",\"type\":\"slack\",\"displayName\":\"Remote drift\",\"description\":\"\",\"labels\":{\"channel_name\":\"#platform\",\"auth_token\":\"******\"},\"userLabels\":{\"environment\":\"prod\"},\"enabled\":true,\"verificationStatus\":\"UNVERIFIED\"}";
}

fn dashboardJson(etag: []const u8) []const u8 {
    if (std.mem.eql(u8, etag, "etag-a")) return "{\"name\":\"projects/ziac-dev/dashboards/abc\",\"displayName\":\"Global API\",\"etag\":\"etag-a\",\"mosaicLayout\":{\"columns\":48,\"tiles\":[]}}";
    if (std.mem.eql(u8, etag, "etag-b")) return "{\"name\":\"projects/ziac-dev/dashboards/abc\",\"displayName\":\"Global API\",\"etag\":\"etag-b\",\"mosaicLayout\":{\"columns\":48,\"tiles\":[]}}";
    return "{\"name\":\"projects/ziac-dev/dashboards/abc\",\"displayName\":\"Global API\",\"etag\":\"etag-c\",\"mosaicLayout\":{\"columns\":48,\"tiles\":[]}}";
}

fn serviceJson() []const u8 {
    return "{\"name\":\"projects/ziac-dev/services/global-api\",\"displayName\":\"Global API\",\"cloudRun\":{\"serviceName\":\"global-api\",\"location\":\"europe-west1\"}}";
}

fn sloJson() []const u8 {
    return "{\"name\":\"projects/ziac-dev/services/global-api/serviceLevelObjectives/availability-999\",\"displayName\":\"99.9% availability\",\"goal\":0.999,\"rollingPeriod\":\"2592000s\",\"serviceLevelIndicator\":{\"basicSli\":{\"availability\":{}}}}";
}

const FixedSecretSource = struct {
    fn secretSource(self: *FixedSecretSource) ziac.secret.SecretSource {
        return .{ .ptr = self, .resolveFn = resolve };
    }
    fn resolve(_: *anyopaque, _: *ziac.provider.OperationContext, allocator: std.mem.Allocator, _: ziac.value.SecretReference) ziac.provider.ProviderError!ziac.secret.SecretPayload {
        return ziac.secret.SecretPayload.initOwned(allocator, "live-channel-token", null);
    }
};

const Harness = struct {
    source: FixedTokenSource,
    cache: auth.TokenCache,
    transport: @import("gcp_client_test.zig").RecordingTransport,
    client: gclient.Client,

    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.source = .{};
        self.cache = auth.TokenCache.init(self.source.tokenSource(), 300);
        self.transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{ .monitoring = "https://monitoring.example.test" });
    }

    fn deinit(self: *Harness) void {
        self.transport.deinit();
        self.cache.deinit(std.testing.allocator);
    }
};

const FixedTokenSource = struct {
    fn tokenSource(self: *FixedTokenSource) auth.TokenSource {
        return .{ .ptr = self, .fetchFn = fetch };
    }
    fn fetch(_: *anyopaque, allocator: std.mem.Allocator, now: u64) auth.AuthError!auth.AccessToken {
        return auth.AccessToken.initOwned(allocator, .{ .access_token = "token", .token_type = "Bearer", .expires_at_seconds = now + 3600 });
    }
};

fn outputValue(result: ziac.provider.ResourceResult, name: []const u8) ziac.value.Value {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name)) return item.value;
    unreachable;
}

fn ok(body: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = @constCast(body) };
}

fn precondition() zstd.Http.Response {
    return .{ .status = 412, .body = @constCast("{\"error\":{\"code\":412,\"message\":\"etag mismatch\",\"status\":\"FAILED_PRECONDITION\"}}") };
}
