const std = @import("std");
const ziac = @import("ziac");

const config = ziac.gcp.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
};

test "ZigTaskWorker synthesizes queue identity invoker and exact enqueuers" {
    var worker = try ziac.gcp.ZigTaskWorker.build(std.testing.allocator, config, .{
        .name = "invoice-worker",
        .service = ziac.PublicOutput([]const u8).known("projects/ziac-dev/locations/europe-west1/services/invoice-worker"),
        .endpoint = "https://invoice-worker.example.run.app/tasks/invoice",
        .enqueuers = &.{"serviceAccount:api@ziac-dev.iam.gserviceaccount.com"},
        .max_dispatches_per_second = 20,
        .max_concurrent_dispatches = 40,
        .retain_on_delete = false,
    });
    defer worker.deinit();

    try std.testing.expectEqual(@as(usize, 4), worker.graph.resources.items.len);
    try std.testing.expect(hasResource(&worker.graph, "gcp.tasks.Queue.europe-west1.invoice-worker"));
    try std.testing.expect(hasResource(&worker.graph, "gcp.run.ServiceIamMember.invoice-worker-invoker"));
    try std.testing.expect(hasResource(&worker.graph, "gcp.tasks.QueueIamMember.invoice-worker-enqueuer-1"));
    try worker.graph.validateAcyclic();
}

test "EventPipeline synthesizes transport trigger invocation identity and publisher access" {
    var pipeline = try ziac.gcp.EventPipeline.build(std.testing.allocator, config, .{
        .name = "orders-events",
        .service = ziac.PublicOutput([]const u8).known("projects/ziac-dev/locations/europe-west1/services/orders-worker"),
        .service_name = "orders-worker",
        .event_filters = &.{.{
            .attribute = "type",
            .value = "google.cloud.pubsub.topic.v1.messagePublished",
        }},
        .create_transport_topic = true,
        .publishers = &.{"serviceAccount:api@ziac-dev.iam.gserviceaccount.com"},
        .retain_on_delete = false,
    });
    defer pipeline.deinit();

    try std.testing.expectEqual(@as(usize, 5), pipeline.graph.resources.items.len);
    try std.testing.expect(hasResource(&pipeline.graph, "gcp.pubsub.Topic.orders-events"));
    try std.testing.expect(hasResource(&pipeline.graph, "gcp.eventarc.Trigger.europe-west1.orders-events"));
    try std.testing.expect(hasResource(&pipeline.graph, "gcp.pubsub.TopicIamMember.orders-events-publisher-1"));
    try std.testing.expect(pipeline.transport_topic != null);
    try pipeline.graph.validateAcyclic();
}

test "EventPipeline exposes a referenced transport topic without adopting it" {
    const existing = ziac.PublicOutput([]const u8).known("projects/ziac-dev/topics/shared-events");
    var pipeline = try ziac.gcp.EventPipeline.build(std.testing.allocator, config, .{
        .name = "audit-events",
        .service = ziac.PublicOutput([]const u8).known("projects/ziac-dev/locations/europe-west1/services/audit-worker"),
        .service_name = "audit-worker",
        .event_filters = &.{.{
            .attribute = "type",
            .value = "google.cloud.audit.log.v1.written",
        }},
        .transport_topic = existing,
    });
    defer pipeline.deinit();

    try std.testing.expectEqual(@as(usize, 3), pipeline.graph.resources.items.len);
    try std.testing.expect(pipeline.transport_topic != null);
    try std.testing.expectEqualStrings("projects/ziac-dev/topics/shared-events", pipeline.transport_topic.?.value);
    try std.testing.expect(!hasResource(&pipeline.graph, "gcp.pubsub.Topic.audit-events"));
}

fn hasResource(graph: *const ziac.resource.ResourceGraph, id: []const u8) bool {
    for (graph.resources.items) |node| if (std.mem.eql(u8, node.id, id)) return true;
    return false;
}
