const std = @import("std");
const ziac = @import("ziac");

test "GlobalCloudRunDelivery compiles regional targets guarded progression and automation" {
    var delivery = try ziac.gcp.GlobalCloudRunDelivery.build(std.testing.allocator, .{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
        .service_regions = &.{ "europe-west1", "us-central1", "asia-east1" },
        .network_tier = .premium,
    }, .{
        .name = "global-api",
        .location = "europe-west1",
        .regions = &.{
            .{ .region = "europe-west1", .profile = "eu" },
            .{ .region = "us-central1", .profile = "us" },
            .{ .region = "asia-east1", .profile = "asia", .require_approval = true },
        },
        .service_account = "deploy@ziac-dev.iam.gserviceaccount.com",
        .canary_percentages = &.{ 10, 50 },
        .automation = .{ .enabled = false, .wait_seconds = 60, .repair_attempts = 2 },
        .production_freeze = .{ .target_region = "asia-east1", .time_zone = "Europe/London", .days = &.{ .saturday, .sunday } },
    });
    defer delivery.deinit();

    try delivery.graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 6), delivery.graph.resources.items.len);
    try std.testing.expect(delivery.pipeline == .resource_ref);
}
