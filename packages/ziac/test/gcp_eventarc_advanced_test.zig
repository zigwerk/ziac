const std = @import("std");
const ziac = @import("ziac");

const eventarc = ziac.gcp.eventarc_advanced;

test "Eventarc Advanced declarations type a complete regional event route" {
    var bus = try eventarc.MessageBus.build(std.testing.allocator, config(), .{
        .name = "application-events",
        .location = "europe-west1",
        .display_name = "Application events",
        .crypto_key_name = .{ .value = "projects/events-prod/locations/europe-west1/keyRings/events/cryptoKeys/payloads" },
        .logging_severity = .info,
    });
    defer bus.deinit(std.testing.allocator);

    var pipeline = try eventarc.Pipeline.build(std.testing.allocator, config(), .{
        .name = "orders-delivery",
        .location = "europe-west1",
        .display_name = "Orders delivery",
        .destination = .{ .https = .{
            .uri = "https://orders.example.com/events",
            .authentication = .{ .oidc = .{ .service_account_email = "eventarc-delivery@events-prod.iam.gserviceaccount.com", .audience = "https://orders.example.com" } },
            .network_attachment = "projects/events-prod/regions/europe-west1/networkAttachments/private-egress",
        } },
        .retry = .{ .max_attempts = 8, .min_delay_seconds = 5, .max_delay_seconds = 90 },
        .transformation_cel = "message.data",
    });
    defer pipeline.deinit(std.testing.allocator);

    var enrollment = try eventarc.Enrollment.build(std.testing.allocator, config(), .{
        .name = "orders-created",
        .location = "europe-west1",
        .message_bus = bus.name,
        .destination_pipeline = pipeline.name,
        .cel_match = "message.type == 'com.example.order.created'",
    });
    defer enrollment.deinit(std.testing.allocator);

    var source = try eventarc.GoogleApiSource.build(std.testing.allocator, config(), .{
        .name = "google-events",
        .location = "europe-west1",
        .destination_message_bus = bus.name,
        .subscriptions = .{ .projects = &.{ "123456789012", "234567890123" } },
    });
    defer source.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.eventarc.MessageBus.europe-west1.application-events", bus.node.id);
    try std.testing.expectEqualStrings("gcp.eventarc.Pipeline.europe-west1.orders-delivery", pipeline.node.id);
    try std.testing.expectEqualStrings("gcp.eventarc.Enrollment.europe-west1.orders-created", enrollment.node.id);
    try std.testing.expectEqualStrings("gcp.eventarc.GoogleApiSource.europe-west1.google-events", source.node.id);
    try std.testing.expectEqual(@as(usize, 2), countOutputRefs(enrollment.node.inputs));
}

test "Eventarc Advanced rejects unsafe locality destination and expression boundaries" {
    try std.testing.expectError(error.InvalidDestination, eventarc.Pipeline.build(std.testing.allocator, config(), .{
        .name = "insecure",
        .location = "europe-west1",
        .destination = .{ .https = .{ .uri = "http://public.example.com/events" } },
    }));
    try std.testing.expectError(error.InvalidRetryPolicy, eventarc.Pipeline.build(std.testing.allocator, config(), .{
        .name = "unbounded",
        .location = "europe-west1",
        .destination = .{ .pubsub_topic = .{ .value = "projects/events-prod/topics/orders" } },
        .retry = .{ .max_attempts = 101 },
    }));
    try std.testing.expectError(error.InvalidExpression, eventarc.Enrollment.build(std.testing.allocator, config(), .{
        .name = "bad-filter",
        .location = "europe-west1",
        .message_bus = .{ .value = "projects/events-prod/locations/europe-west1/messageBuses/application-events" },
        .destination_pipeline = .{ .value = "projects/events-prod/locations/europe-west1/pipelines/orders" },
        .cel_match = "",
    }));
    try std.testing.expectError(error.InvalidSubscription, eventarc.GoogleApiSource.build(std.testing.allocator, config(), .{
        .name = "bad-source",
        .location = "europe-west1",
        .destination_message_bus = .{ .value = "projects/events-prod/locations/europe-west1/messageBuses/application-events" },
        .subscriptions = .{ .projects = &.{} },
    }));
}

test "Eventarc Advanced additive IAM declarations stay resource scoped" {
    var member = try eventarc.MessageBusIamMember.build(std.testing.allocator, config(), .{
        .location = "europe-west1",
        .message_bus = .{ .value = "projects/events-prod/locations/europe-west1/messageBuses/application-events" },
        .role = "roles/eventarc.publisher",
        .member = "serviceAccount:publisher@events-prod.iam.gserviceaccount.com",
    });
    defer member.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("gcp.eventarc.MessageBusIamMember.europe-west1.application-events.roles-eventarc-publisher-serviceaccount-publisher-events-prod-iam-gserviceaccount-com", member.node.id);
    try std.testing.expect(member.node.lifecycle.protect);
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "events-prod", .primary_region = "europe-west1", .service_regions = &.{ "europe-west1", "us-central1" }, .network_tier = .premium };
}

fn countOutputRefs(input: ziac.value.Value) usize {
    return switch (input) {
        .output_ref => 1,
        .list => |items| blk: {
            var count: usize = 0;
            for (items) |item| count += countOutputRefs(item);
            break :blk count;
        },
        .object => |fields| blk: {
            var count: usize = 0;
            for (fields) |field| count += countOutputRefs(field.value);
            break :blk count;
        },
        else => 0,
    };
}
