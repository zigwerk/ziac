const std = @import("std");
const ziac = @import("ziac");

test "GCP intelligence synthesizes exact API and IAM preflight requirements" {
    const intelligence = ziac.gcp.intelligence;
    const usages = [_]intelligence.RpcUsage{
        .{ .service = "run.googleapis.com", .method = "google.cloud.run.v2.Services.CreateService" },
        .{ .service = "compute.googleapis.com", .method = "compute.backendServices.insert" },
        .{ .service = "run.googleapis.com", .method = "google.cloud.run.v2.Services.GetService" },
    };
    var requirements = try intelligence.synthesize(std.testing.allocator, &usages);
    defer requirements.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), requirements.apis.len);
    try std.testing.expectEqual(@as(usize, 3), requirements.methods.len);
    try std.testing.expect(requirements.hasPermission("run.services.create"));
    try std.testing.expect(requirements.hasPermission("run.services.get"));
    try std.testing.expect(requirements.hasPermission("compute.backendServices.create"));

    var report = try intelligence.evaluatePreflight(std.testing.allocator, requirements, .{
        .enabled_apis = &.{"run.googleapis.com"},
        .granted_permissions = &.{ "run.services.create", "run.services.get" },
        .billing_enabled = true,
        .available_regions = &.{ "europe-west1", "us-central1" },
        .requested_regions = &.{ "europe-west1", "us-central1" },
    });
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(!report.ready);
    try std.testing.expect(report.hasFinding(.api_disabled));
    try std.testing.expect(report.hasFinding(.permission_denied));
}

test "ZigSubscriber graph synthesizes Pub/Sub Run IAM and identity preflight" {
    var subscriber = try ziac.gcp.ZigSubscriber.build(std.testing.allocator, .{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    }, .{
        .name = "orders",
        .project_number = "123456789012",
        .service = ziac.PublicOutput([]const u8).known("projects/ziac-dev/locations/europe-west1/services/orders-worker"),
        .push_endpoint = "https://orders-worker.example.run.app/events/orders",
        .oidc_audience = "https://orders-worker.example.run.app",
        .publishers = &.{"serviceAccount:orders-api@ziac-dev.iam.gserviceaccount.com"},
    });
    defer subscriber.deinit();

    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &subscriber.graph);
    defer requirements.deinit(std.testing.allocator);
    try std.testing.expect(contains(requirements.apis, "pubsub.googleapis.com"));
    try std.testing.expect(contains(requirements.apis, "run.googleapis.com"));
    try std.testing.expect(contains(requirements.apis, "iam.googleapis.com"));
    try std.testing.expect(requirements.hasPermission("pubsub.topics.create"));
    try std.testing.expect(requirements.hasPermission("pubsub.topics.setIamPolicy"));
    try std.testing.expect(requirements.hasPermission("pubsub.subscriptions.create"));
    try std.testing.expect(requirements.hasPermission("pubsub.subscriptions.setIamPolicy"));
    try std.testing.expect(requirements.hasPermission("run.services.getIamPolicy"));
    try std.testing.expect(requirements.hasPermission("run.services.setIamPolicy"));
    try std.testing.expect(requirements.hasPermission("iam.serviceAccounts.create"));
}

test "async delivery graph synthesizes Cloud Tasks Eventarc and act-as preflight" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    var queue = try ziac.gcp.tasks.Queue.build(std.testing.allocator, .{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    }, .{ .name = "invoice-worker" });
    defer queue.deinit(std.testing.allocator);
    var queue_member = try ziac.gcp.tasks.QueueIamMember.build(std.testing.allocator, .{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    }, .{
        .name = "invoice-enqueuer",
        .queue = queue.name,
        .role = "roles/cloudtasks.enqueuer",
        .member = "serviceAccount:api@ziac-dev.iam.gserviceaccount.com",
    });
    defer queue_member.deinit(std.testing.allocator);
    var trigger = try ziac.gcp.eventarc.Trigger.build(std.testing.allocator, .{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    }, .{
        .name = "orders-created",
        .event_filters = &.{.{ .attribute = "type", .value = "google.cloud.pubsub.topic.v1.messagePublished" }},
        .service_account = "orders-events@ziac-dev.iam.gserviceaccount.com",
        .destination = .{ .cloud_run = .{ .service = "orders-worker", .region = "europe-west1" } },
    });
    defer trigger.deinit(std.testing.allocator);
    try graph.addResource(queue.node);
    try graph.addResource(queue_member.node);
    try graph.addResource(trigger.node);

    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &graph);
    defer requirements.deinit(std.testing.allocator);
    try std.testing.expect(contains(requirements.apis, "cloudtasks.googleapis.com"));
    try std.testing.expect(contains(requirements.apis, "eventarc.googleapis.com"));
    try std.testing.expect(contains(requirements.apis, "iam.googleapis.com"));
    try std.testing.expect(requirements.hasPermission("cloudtasks.queues.create"));
    try std.testing.expect(requirements.hasPermission("cloudtasks.queues.setIamPolicy"));
    try std.testing.expect(requirements.hasPermission("eventarc.triggers.create"));
    try std.testing.expect(requirements.hasPermission("iam.serviceAccounts.actAs"));
}

test "topology advice respects residency and Cockroach locality without mutating policy" {
    const intelligence = ziac.gcp.intelligence;
    var advice = try intelligence.adviseTopology(std.testing.allocator, .{
        .cloud_run_regions = &.{ "europe-west1", "us-central1", "asia-northeast1" },
        .cockroach_regions = &.{ "europe-west1", "us-central1" },
        .allowed_regions = &.{ "europe-west1", "us-central1" },
        .require_private_connectivity = true,
        .independent_canary = false,
    });
    defer advice.deinit(std.testing.allocator);
    try std.testing.expectEqual(ziac.gcp.global.Realization.controlled_regional_fleet, advice.realization);
    try std.testing.expect(advice.hasFinding(.residency_violation));
    try std.testing.expect(advice.hasFinding(.database_locality_gap));
    try std.testing.expectEqual(@as(usize, 3), advice.declared_regions.len);
}

fn contains(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, expected)) return true;
    return false;
}
