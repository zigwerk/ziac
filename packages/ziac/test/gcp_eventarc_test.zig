const std = @import("std");
const ziac = @import("ziac");

const config = ziac.gcp.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
    .labels = &.{.{ .key = "managed-by", .value = "ziac" }},
};

test "Eventarc trigger captures exact filters Cloud Run destination channel and transport" {
    var trigger = try ziac.gcp.eventarc.Trigger.build(std.testing.allocator, config, .{
        .name = "orders-created",
        .event_filters = &.{
            .{ .attribute = "type", .value = "google.cloud.pubsub.topic.v1.messagePublished" },
            .{ .attribute = "subject", .value = "orders/*", .operator = .match_path_pattern },
        },
        .service_account = "orders-events@ziac-dev.iam.gserviceaccount.com",
        .destination = .{ .cloud_run = .{
            .service = "orders-worker",
            .region = "europe-west1",
            .path = "/events/orders",
        } },
        .transport_topic = ziac.PublicOutput([]const u8).known("projects/ziac-dev/topics/orders"),
        .channel = "projects/ziac-dev/locations/europe-west1/channels/partners",
        .event_data_content_type = "application/json",
        .retain_on_delete = false,
    });
    defer trigger.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.eventarc.Trigger.europe-west1.orders-created", trigger.node.id);
    const json = try trigger.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "google.cloud.pubsub.topic.v1.messagePublished") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "MATCH_PATH_PATTERN") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "projects/ziac-dev/topics/orders") != null);
    try std.testing.expect(ziac.gcp.live_provider.supports(trigger.node));
}

test "Eventarc trigger validates required type filters and writable destination contracts" {
    try std.testing.expectError(error.MissingTypeFilter, ziac.gcp.eventarc.Trigger.build(std.testing.allocator, config, .{
        .name = "orders-created",
        .event_filters = &.{.{ .attribute = "subject", .value = "orders" }},
        .service_account = "orders-events@ziac-dev.iam.gserviceaccount.com",
        .destination = .{ .cloud_run = .{ .service = "orders", .region = "europe-west1" } },
    }));
    try std.testing.expectError(error.InvalidDestination, ziac.gcp.eventarc.Trigger.build(std.testing.allocator, config, .{
        .name = "orders-created",
        .event_filters = &.{.{ .attribute = "type", .value = "example.created" }},
        .service_account = "orders-events@ziac-dev.iam.gserviceaccount.com",
        .destination = .{ .http_endpoint = .{ .uri = "https://private.example/events" } },
    }));
}
