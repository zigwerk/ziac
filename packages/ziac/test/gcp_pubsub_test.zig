const std = @import("std");
const ziac = @import("ziac");

const config = ziac.gcp.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
    .labels = &.{.{ .key = "managed-by", .value = "ziac" }},
};

test "Pub/Sub declarations compose schema topic push subscription snapshot and exact IAM" {
    var schema = try ziac.gcp.pubsub.Schema.build(std.testing.allocator, config, .{
        .name = "orders-v1",
        .schema_type = .protocol_buffer,
        .definition = "syntax = \"proto3\"; message Order { string id = 1; }",
    });
    defer schema.deinit(std.testing.allocator);

    var dead_letter = try ziac.gcp.pubsub.Topic.build(std.testing.allocator, config, .{
        .name = "orders-dead-letter",
        .message_retention_seconds = 7 * 24 * 60 * 60,
    });
    defer dead_letter.deinit(std.testing.allocator);

    var topic = try ziac.gcp.pubsub.Topic.build(std.testing.allocator, config, .{
        .name = "orders",
        .kms_key_name = "projects/ziac-dev/locations/europe-west1/keyRings/events/cryptoKeys/pubsub",
        .message_retention_seconds = 24 * 60 * 60,
        .allowed_persistence_regions = &.{ "europe-west1", "europe-west4" },
        .schema_name = schema.name,
        .schema_encoding = .json,
    });
    defer topic.deinit(std.testing.allocator);

    var subscription = try ziac.gcp.pubsub.Subscription.build(std.testing.allocator, config, .{
        .name = "orders-worker",
        .topic = topic.name,
        .delivery = .{ .push = .{
            .endpoint = "https://orders-worker.example.run.app/events/orders",
            .oidc_service_account_email = "orders-worker@ziac-dev.iam.gserviceaccount.com",
            .oidc_audience = "https://orders-worker.example.run.app",
        } },
        .ack_deadline_seconds = 30,
        .message_retention_seconds = 2 * 24 * 60 * 60,
        .expiration = .never,
        .enable_message_ordering = true,
        .filter = "attributes.tenant != \"\"",
        .dead_letter_topic = dead_letter.name,
        .max_delivery_attempts = 10,
        .retry_policy = .{ .minimum_backoff_seconds = 10, .maximum_backoff_seconds = 300 },
    });
    defer subscription.deinit(std.testing.allocator);

    var snapshot = try ziac.gcp.pubsub.Snapshot.build(std.testing.allocator, config, .{
        .name = "orders-before-migration",
        .subscription = subscription.name,
    });
    defer snapshot.deinit(std.testing.allocator);

    var publisher = try ziac.gcp.pubsub.TopicIamMember.build(std.testing.allocator, config, .{
        .name = "api-publisher",
        .topic = topic.name,
        .role = "roles/pubsub.publisher",
        .member = "serviceAccount:api@ziac-dev.iam.gserviceaccount.com",
        .condition = .{
            .title = "orders-only",
            .expression = "resource.name.endsWith('/topics/orders')",
        },
    });
    defer publisher.deinit(std.testing.allocator);

    var subscriber = try ziac.gcp.pubsub.SubscriptionIamMember.build(std.testing.allocator, config, .{
        .name = "worker-subscriber",
        .subscription = subscription.name,
        .role = "roles/pubsub.subscriber",
        .member = "serviceAccount:orders-worker@ziac-dev.iam.gserviceaccount.com",
    });
    defer subscriber.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.pubsub.Schema.orders-v1", schema.node.id);
    try std.testing.expectEqualStrings("gcp.pubsub.Topic.orders", topic.node.id);
    try std.testing.expectEqualStrings("gcp.pubsub.Subscription.orders-worker", subscription.node.id);
    try std.testing.expectEqualStrings("gcp.pubsub.Snapshot.orders-before-migration", snapshot.node.id);
    try std.testing.expect(topic.node.lifecycle.retain_on_delete);
    try std.testing.expect(subscription.node.lifecycle.retain_on_delete);
    try std.testing.expect(snapshot.node.lifecycle.retain_on_delete);

    const topic_json = try topic.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(topic_json);
    try std.testing.expect(std.mem.indexOf(u8, topic_json, "\"schema_encoding\":\"JSON\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, topic_json, "gcp.pubsub.Schema.orders-v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, topic_json, "\"allowed_persistence_regions\":[\"europe-west1\",\"europe-west4\"]") != null);

    const subscription_json = try subscription.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(subscription_json);
    try std.testing.expect(std.mem.indexOf(u8, subscription_json, "\"delivery_kind\":\"push\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, subscription_json, "\"max_delivery_attempts\":10") != null);
    try std.testing.expect(std.mem.indexOf(u8, subscription_json, "gcp.pubsub.Topic.orders-dead-letter") != null);

    const iam_json = try publisher.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(iam_json);
    try std.testing.expect(std.mem.indexOf(u8, iam_json, "resource.name.endsWith") != null);
    try std.testing.expect(ziac.gcp.live_provider.supports(publisher.node));
    try std.testing.expect(ziac.gcp.live_provider.supports(subscriber.node));
}

test "Pub/Sub declarations reject unsafe retention push and retry policy" {
    try std.testing.expectError(error.InvalidRetention, ziac.gcp.pubsub.Topic.build(std.testing.allocator, config, .{
        .name = "orders",
        .message_retention_seconds = 599,
    }));
    try std.testing.expectError(error.InvalidPushEndpoint, ziac.gcp.pubsub.Subscription.build(std.testing.allocator, config, .{
        .name = "orders-worker",
        .topic = ziac.PublicOutput([]const u8).known("projects/ziac-dev/topics/orders"),
        .delivery = .{ .push = .{
            .endpoint = "http://orders.internal/events",
            .oidc_service_account_email = "orders-worker@ziac-dev.iam.gserviceaccount.com",
        } },
    }));
    try std.testing.expectError(error.InvalidDeliveryAttempts, ziac.gcp.pubsub.Subscription.build(std.testing.allocator, config, .{
        .name = "orders-worker",
        .topic = ziac.PublicOutput([]const u8).known("projects/ziac-dev/topics/orders"),
        .delivery = .pull,
        .dead_letter_topic = ziac.PublicOutput([]const u8).known("projects/ziac-dev/topics/orders-dead-letter"),
        .max_delivery_attempts = 4,
    }));
    try std.testing.expectError(error.InvalidRetryPolicy, ziac.gcp.pubsub.Subscription.build(std.testing.allocator, config, .{
        .name = "orders-worker",
        .topic = ziac.PublicOutput([]const u8).known("projects/ziac-dev/topics/orders"),
        .delivery = .pull,
        .retry_policy = .{ .minimum_backoff_seconds = 300, .maximum_backoff_seconds = 10 },
    }));
}
