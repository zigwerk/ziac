const std = @import("std");
const ziac = @import("ziac");

fn build(allocator: std.mem.Allocator) !ziac.gcp.GlobalCloudRunDelivery {
    return ziac.gcp.GlobalCloudRunDelivery.build(allocator, .{
        .project_id = "example-project",
        .primary_region = "europe-west1",
        .service_regions = &.{ "europe-west1", "us-central1", "asia-northeast1" },
        .network_tier = .premium,
    }, .{
        .name = "global-api",
        .location = "europe-west1",
        .regions = &.{
            .{ .region = "europe-west1", .profile = "europe" },
            .{ .region = "us-central1", .profile = "americas" },
            .{ .region = "asia-northeast1", .profile = "asia", .require_approval = true },
        },
        .service_account = "cloud-deploy@example-project.iam.gserviceaccount.com",
        .canary_percentages = &.{ 10, 50 },
        .automation = .{ .enabled = true, .wait_seconds = 300, .repair_attempts = 3 },
        .production_freeze = .{
            .target_region = "asia-northeast1",
            .time_zone = "UTC",
            .days = &.{ .saturday, .sunday },
        },
    });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var delivery = try build(allocator);
    defer delivery.deinit();
    var permissions = try ziac.gcp.intelligence.synthesizePermissionPlan(allocator, &delivery.graph);
    defer permissions.deinit(allocator);
    std.debug.print("Cloud Deploy: {d} resources, {d} causal edges, {d} exact permissions\n", .{
        delivery.graph.resources.items.len,
        delivery.graph.dependencies.items.len,
        permissions.deployer_permissions.len,
    });
}

test "Cloud Deploy example compiles regional progression automation and policy" {
    var delivery = try build(std.testing.allocator);
    defer delivery.deinit();
    try delivery.graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 6), delivery.graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 4), delivery.graph.dependencies.items.len);
}
