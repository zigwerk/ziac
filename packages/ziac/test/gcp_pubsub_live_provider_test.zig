const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;

test "live Pub/Sub provider manages topics with canonical update masks" {
    const topic_json = "{\"name\":\"projects/ziac-dev/topics/orders\",\"labels\":{\"managed-by\":\"ziac\"},\"kmsKeyName\":\"projects/ziac-dev/locations/europe-west1/keyRings/events/cryptoKeys/pubsub\",\"messageRetentionDuration\":\"86400s\",\"messageStoragePolicy\":{\"allowedPersistenceRegions\":[\"europe-west1\"],\"enforceInTransit\":true}}";
    const changed_json = "{\"name\":\"projects/ziac-dev/topics/orders\",\"labels\":{\"managed-by\":\"ziac\"},\"kmsKeyName\":\"projects/ziac-dev/locations/europe-west1/keyRings/events/cryptoKeys/pubsub\",\"messageRetentionDuration\":\"172800s\",\"messageStoragePolicy\":{\"allowedPersistenceRegions\":[\"europe-west1\"],\"enforceInTransit\":true}}";
    const responses = [_]zstd.Http.Response{
        notFound(),
        ok(topic_json),
        ok(topic_json),
        ok(changed_json),
        ok(changed_json),
        .{ .status = 200, .body = "{}" },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var topic = try topicWithRetention(86_400);
    defer topic.deinit(std.testing.allocator);
    var changed = try topicWithRetention(172_800);
    defer changed.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var absent = try live.readWithContext(&context, topic.node);
    defer absent.deinit();
    try std.testing.expect(absent == .absent);
    var created = try live.createWithContext(&context, topic.node);
    defer created.deinit();
    try std.testing.expectEqualStrings("projects/ziac-dev/topics/orders", created.physical_id);
    var read = try live.readWithContext(&context, topic.node);
    defer read.deinit();
    var update_diff = try live.diffWithContext(&context, changed.node, &read.present);
    defer update_diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, update_diff.kind);
    var updated = try live.updateWithContext(&context, changed.node, &read.present);
    defer updated.deinit();
    var imported = try live.importWithContext(&context, changed.node, updated.physical_id);
    defer imported.deinit();
    try live.deleteWithContext(&context, changed.node, imported.physical_id);

    try std.testing.expectEqualStrings("PUT", harness.transport.requests.items[1].method);
    try std.testing.expectEqualStrings("https://pubsub.example.test/v1/projects/ziac-dev/topics/orders", harness.transport.requests.items[1].url);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"messageRetentionDuration\":\"86400s\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].url, "updateMask=labels%2CkmsKeyName%2CmessageRetentionDuration%2CmessageStoragePolicy") != null);
    try std.testing.expectEqualStrings("DELETE", harness.transport.requests.items[5].method);
}

test "live Pub/Sub provider creates and commits schema revisions" {
    const initial = "{\"name\":\"projects/ziac-dev/schemas/orders-v1\",\"type\":\"PROTOCOL_BUFFER\",\"definition\":\"syntax = \\\"proto3\\\"; message Order { string id = 1; }\",\"revisionId\":\"r1\",\"revisionCreateTime\":\"2026-07-13T10:00:00Z\"}";
    const changed = "{\"name\":\"projects/ziac-dev/schemas/orders-v1\",\"type\":\"PROTOCOL_BUFFER\",\"definition\":\"syntax = \\\"proto3\\\"; message Order { string id = 1; string tenant = 2; }\",\"revisionId\":\"r2\",\"revisionCreateTime\":\"2026-07-13T11:00:00Z\"}";
    const responses = [_]zstd.Http.Response{
        notFound(),
        ok(initial),
        ok(initial),
        ok(changed),
        ok(changed),
        .{ .status = 200, .body = "{}" },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var schema = try schemaWithDefinition("syntax = \"proto3\"; message Order { string id = 1; }");
    defer schema.deinit(std.testing.allocator);
    var next = try schemaWithDefinition("syntax = \"proto3\"; message Order { string id = 1; string tenant = 2; }");
    defer next.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var absent = try live.readWithContext(&context, schema.node);
    defer absent.deinit();
    var created = try live.createWithContext(&context, schema.node);
    defer created.deinit();
    try std.testing.expectEqualStrings("r1", outputString(created, "revision_id"));
    var read = try live.readWithContext(&context, schema.node);
    defer read.deinit();
    var updated = try live.updateWithContext(&context, next.node, &read.present);
    defer updated.deinit();
    try std.testing.expectEqualStrings("r2", outputString(updated, "revision_id"));
    var imported = try live.importWithContext(&context, next.node, updated.physical_id);
    defer imported.deinit();
    try live.deleteWithContext(&context, next.node, imported.physical_id);

    try std.testing.expectEqualStrings("POST", harness.transport.requests.items[1].method);
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[1].url, "/v1/projects/ziac-dev/schemas?schemaId=orders-v1"));
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[3].url, "/v1/projects/ziac-dev/schemas/orders-v1:commit"));
}

test "live Pub/Sub provider manages push subscriptions and snapshots" {
    const subscription_json = "{\"name\":\"projects/ziac-dev/subscriptions/orders-worker\",\"topic\":\"projects/ziac-dev/topics/orders\",\"pushConfig\":{\"pushEndpoint\":\"https://orders.example.run.app/events\",\"oidcToken\":{\"serviceAccountEmail\":\"orders-worker@ziac-dev.iam.gserviceaccount.com\",\"audience\":\"https://orders.example.run.app\"}},\"ackDeadlineSeconds\":30,\"messageRetentionDuration\":\"172800s\",\"expirationPolicy\":{},\"enableMessageOrdering\":true,\"filter\":\"attributes.tenant != \\\"\\\"\",\"deadLetterPolicy\":{\"deadLetterTopic\":\"projects/ziac-dev/topics/orders-dead-letter\",\"maxDeliveryAttempts\":10},\"retryPolicy\":{\"minimumBackoff\":\"10s\",\"maximumBackoff\":\"300s\"},\"labels\":{\"managed-by\":\"ziac\"},\"state\":\"ACTIVE\"}";
    const snapshot_json = "{\"name\":\"projects/ziac-dev/snapshots/orders-before-migration\",\"topic\":\"projects/ziac-dev/topics/orders\",\"expireTime\":\"2026-07-20T10:00:00Z\",\"labels\":{\"managed-by\":\"ziac\"}}";
    const responses = [_]zstd.Http.Response{
        notFound(),
        ok(subscription_json),
        ok(subscription_json),
        ok(subscription_json),
        .{ .status = 200, .body = "{}" },
        notFound(),
        ok(snapshot_json),
        ok(snapshot_json),
        ok(snapshot_json),
        .{ .status = 200, .body = "{}" },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var subscription = try pushSubscription();
    defer subscription.deinit(std.testing.allocator);
    var snapshot = try ziac.gcp.pubsub.Snapshot.build(std.testing.allocator, config(), .{
        .name = "orders-before-migration",
        .subscription = .{ .value = "projects/ziac-dev/subscriptions/orders-worker" },
        .retain_on_delete = false,
    });
    defer snapshot.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var sub_absent = try live.readWithContext(&context, subscription.node);
    defer sub_absent.deinit();
    var sub_created = try live.createWithContext(&context, subscription.node);
    defer sub_created.deinit();
    var sub_read = try live.readWithContext(&context, subscription.node);
    defer sub_read.deinit();
    var sub_imported = try live.importWithContext(&context, subscription.node, sub_created.physical_id);
    defer sub_imported.deinit();
    try live.deleteWithContext(&context, subscription.node, sub_imported.physical_id);

    var snapshot_absent = try live.readWithContext(&context, snapshot.node);
    defer snapshot_absent.deinit();
    var snapshot_created = try live.createWithContext(&context, snapshot.node);
    defer snapshot_created.deinit();
    try std.testing.expectEqualStrings("2026-07-20T10:00:00Z", outputString(snapshot_created, "expire_time"));
    var snapshot_read = try live.readWithContext(&context, snapshot.node);
    defer snapshot_read.deinit();
    var snapshot_imported = try live.importWithContext(&context, snapshot.node, snapshot_created.physical_id);
    defer snapshot_imported.deinit();
    try live.deleteWithContext(&context, snapshot.node, snapshot_imported.physical_id);

    try std.testing.expectEqualStrings("PUT", harness.transport.requests.items[1].method);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"oidcToken\"") != null);
    try std.testing.expectEqualStrings("PUT", harness.transport.requests.items[6].method);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[6].body, "\"subscription\":\"projects/ziac-dev/subscriptions/orders-worker\"") != null);
}

test "live Pub/Sub provider mutates only its exact conditional IAM member" {
    const before = "{\"version\":3,\"etag\":\"BwA=\",\"bindings\":[{\"role\":\"roles/pubsub.publisher\",\"members\":[\"user:owner@example.com\"]},{\"role\":\"roles/pubsub.publisher\",\"members\":[\"serviceAccount:other@ziac-dev.iam.gserviceaccount.com\"],\"condition\":{\"title\":\"other\",\"expression\":\"resource.name.endsWith('/topics/other')\"}}]}";
    const after = "{\"version\":3,\"etag\":\"BwB=\",\"bindings\":[{\"role\":\"roles/pubsub.publisher\",\"members\":[\"user:owner@example.com\"]},{\"role\":\"roles/pubsub.publisher\",\"members\":[\"serviceAccount:other@ziac-dev.iam.gserviceaccount.com\"],\"condition\":{\"title\":\"other\",\"expression\":\"resource.name.endsWith('/topics/other')\"}},{\"role\":\"roles/pubsub.publisher\",\"members\":[\"serviceAccount:api@ziac-dev.iam.gserviceaccount.com\"],\"condition\":{\"title\":\"orders-only\",\"expression\":\"resource.name.endsWith('/topics/orders')\"}}]}";
    const responses = [_]zstd.Http.Response{
        ok(before),
        ok(after),
        ok(after),
        ok(after),
        ok(before),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var member = try ziac.gcp.pubsub.TopicIamMember.build(std.testing.allocator, config(), .{
        .name = "api-publisher",
        .topic = .{ .value = "projects/ziac-dev/topics/orders" },
        .role = "roles/pubsub.publisher",
        .member = "serviceAccount:api@ziac-dev.iam.gserviceaccount.com",
        .condition = .{ .title = "orders-only", .expression = "resource.name.endsWith('/topics/orders')" },
    });
    defer member.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try live.createWithContext(&context, member.node);
    defer created.deinit();
    var read = try live.readWithContext(&context, member.node);
    defer read.deinit();
    try std.testing.expect(read == .present);
    try live.deleteWithContext(&context, member.node, created.physical_id);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "other") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "orders-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[4].body, "orders-only") == null);
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
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{ .pubsub = "https://pubsub.example.test" });
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

fn topicWithRetention(seconds: u32) !ziac.gcp.pubsub.Topic {
    return ziac.gcp.pubsub.Topic.build(std.testing.allocator, config(), .{
        .name = "orders",
        .kms_key_name = "projects/ziac-dev/locations/europe-west1/keyRings/events/cryptoKeys/pubsub",
        .message_retention_seconds = seconds,
        .allowed_persistence_regions = &.{"europe-west1"},
        .enforce_in_transit = true,
        .retain_on_delete = false,
    });
}

fn schemaWithDefinition(definition: []const u8) !ziac.gcp.pubsub.Schema {
    return ziac.gcp.pubsub.Schema.build(std.testing.allocator, config(), .{
        .name = "orders-v1",
        .schema_type = .protocol_buffer,
        .definition = definition,
        .retain_on_delete = false,
    });
}

fn pushSubscription() !ziac.gcp.pubsub.Subscription {
    return ziac.gcp.pubsub.Subscription.build(std.testing.allocator, config(), .{
        .name = "orders-worker",
        .topic = .{ .value = "projects/ziac-dev/topics/orders" },
        .delivery = .{ .push = .{
            .endpoint = "https://orders.example.run.app/events",
            .oidc_service_account_email = "orders-worker@ziac-dev.iam.gserviceaccount.com",
            .oidc_audience = "https://orders.example.run.app",
        } },
        .ack_deadline_seconds = 30,
        .message_retention_seconds = 2 * 24 * 60 * 60,
        .expiration = .never,
        .enable_message_ordering = true,
        .filter = "attributes.tenant != \"\"",
        .dead_letter_topic = .{ .value = "projects/ziac-dev/topics/orders-dead-letter" },
        .max_delivery_attempts = 10,
        .retry_policy = .{ .minimum_backoff_seconds = 10, .maximum_backoff_seconds = 300 },
        .retain_on_delete = false,
    });
}

fn config() ziac.gcp.ProviderConfig {
    return .{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
        .labels = &.{.{ .key = "managed-by", .value = "ziac" }},
    };
}

fn outputString(result: ziac.provider.ResourceResult, name: []const u8) []const u8 {
    for (result.outputs) |entry| if (std.mem.eql(u8, entry.name, name)) return switch (entry.value) {
        .string => |text| text,
        else => unreachable,
    };
    unreachable;
}

fn ok(body: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = body };
}

fn notFound() zstd.Http.Response {
    return .{ .status = 404, .body = "{\"error\":{\"code\":404,\"status\":\"NOT_FOUND\",\"message\":\"missing\"}}" };
}
