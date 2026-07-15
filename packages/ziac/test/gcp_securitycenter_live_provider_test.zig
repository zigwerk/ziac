const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;
const scc = ziac.gcp.securitycenter;

test "SCC notification lifecycle uses v2 regional identity and exact update mask" {
    const remote = "{\"name\":\"organizations/123456789/locations/eu/notificationConfigs/critical-findings\",\"description\":\"Critical findings\",\"pubsubTopic\":\"projects/security-prod/topics/scc-critical\",\"streamingConfig\":{\"filter\":\"severity=\\\"CRITICAL\\\"\"},\"serviceAccount\":\"service-org@gcp-sa-scc-notification.iam.gserviceaccount.com\"}";
    const responses = [_]zstd.Http.Response{ ok(remote), ok(remote), ok(remote), ok("{}") };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.securitycenter_provider.Handler{ .client = &harness.client };
    var notification = try scc.NotificationConfig.build(std.testing.allocator, config(), .{
        .name = "critical-findings",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .location = "eu",
        .description = "Critical findings",
        .pubsub_topic = ziac.PublicOutput([]const u8).known("projects/security-prod/topics/scc-critical"),
        .filter = "severity=\"CRITICAL\"",
        .removal_policy = .delete,
    });
    defer notification.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try handler.create(&context, notification.node);
    defer created.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].url, "/v2/organizations/123456789/locations/eu/notificationConfigs?configId=critical-findings") != null);
    var observed = try handler.read(&context, notification.node, created.physical_id);
    defer observed.deinit();
    var updated = try handler.update(&context, notification.node, &observed.present);
    defer updated.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[2].url, "updateMask=description%2CpubsubTopic%2CstreamingConfig.filter") != null);
    try std.testing.expectError(error.DestructiveConfirmationRequired, handler.delete(&context, notification.node, updated.physical_id));
    context.destructive_confirmation = true;
    try handler.delete(&context, notification.node, updated.physical_id);
}

test "SCC permanent source is list-discovered and cannot be deleted" {
    const responses = [_]zstd.Http.Response{ok("{\"sources\":[{\"name\":\"organizations/123456789/sources/456\",\"displayName\":\"Platform detector\",\"description\":\"Findings emitted by Ziac\",\"canonicalName\":\"projects/123/sources/456\"}]}")};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.securitycenter_provider.Handler{ .client = &harness.client };
    var source = try scc.Source.build(std.testing.allocator, config(), .{
        .name = "platform-detector",
        .organization = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .display_name = "Platform detector",
        .description = "Findings emitted by Ziac",
    });
    defer source.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var found = try handler.read(&context, source.node, null);
    defer found.deinit();
    try std.testing.expectEqualStrings("organizations/123456789/sources/456", found.present.physical_id);
    try std.testing.expectError(error.InvalidConfiguration, handler.delete(&context, source.node, found.present.physical_id));
}

test "SCC resource value wraps one typed config in batch create" {
    const responses = [_]zstd.Http.Response{ok("{\"resourceValueConfigs\":[{\"name\":\"organizations/123456789/locations/eu/resourceValueConfigs/789\",\"resourceValue\":\"HIGH\",\"cloudProvider\":\"GOOGLE_CLOUD_PLATFORM\",\"resourceType\":\"sqladmin.googleapis.com/Instance\",\"tagValues\":[\"tagValues/222\"]}]}")};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.securitycenter_provider.Handler{ .client = &harness.client };
    var resource_value = try scc.ResourceValueConfig.build(std.testing.allocator, config(), .{
        .name = "production-databases",
        .organization = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .location = "eu",
        .resource_value = .high,
        .resource_type = "sqladmin.googleapis.com/Instance",
        .tag_values = &.{"tagValues/222"},
    });
    defer resource_value.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try handler.create(&context, resource_value.node);
    defer created.deinit();
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[0].url, "/v2/organizations/123456789/locations/eu/resourceValueConfigs:batchCreate"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "\"requests\":[{\"resourceValueConfig\":") != null);
    try std.testing.expectEqualStrings("organizations/123456789/locations/eu/resourceValueConfigs/789", created.physical_id);
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "security-host", .primary_region = "europe-west1" };
}

const Harness = struct {
    source: FixedTokenSource,
    cache: auth.TokenCache,
    transport: @import("gcp_client_test.zig").RecordingTransport,
    client: gclient.Client,

    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.source = .{};
        self.cache = auth.TokenCache.init(self.source.tokenSource(), 300);
        self.transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{ .security_center = "https://securitycenter.example.test" });
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

fn ok(body: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = body };
}
