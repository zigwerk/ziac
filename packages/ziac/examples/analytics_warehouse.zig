const std = @import("std");
const ziac = @import("ziac");

fn build(allocator: std.mem.Allocator) !ziac.gcp.AnalyticsWarehouse {
    return ziac.gcp.AnalyticsWarehouse.build(allocator, .{
        .project_id = "example-project",
        .primary_region = "europe-west1",
    }, .{
        .name = "product-analytics",
        .dataset_id = "product_analytics",
        .location = "EU",
        .tables = &.{.{
            .table_id = "events",
            .schema = &.{
                .{ .name = "event_id", .field_type = .string, .mode = .required },
                .{ .name = "occurred_at", .field_type = .timestamp, .mode = .required },
            },
            .time_partitioning = .{ .field = "occurred_at" },
            .require_partition_filter = true,
        }},
        .views = &.{.{
            .view_id = "daily_events",
            .query = "SELECT DATE(occurred_at) AS day, COUNT(*) AS events FROM `example-project.product_analytics.events` GROUP BY day",
        }},
        .readers = &.{"group:analytics@example.com"},
        .writers = &.{"serviceAccount:ingest@example-project.iam.gserviceaccount.com"},
    });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var warehouse = try build(allocator);
    defer warehouse.deinit();
    var requirements = try ziac.gcp.intelligence.synthesizeGraph(allocator, &warehouse.graph);
    defer requirements.deinit(allocator);
    std.debug.print("analytics warehouse: {d} resources, {d} APIs\n", .{
        warehouse.graph.resources.items.len,
        requirements.apis.len,
    });
}

test "analytics warehouse example compiles a governed dataset" {
    var warehouse = try build(std.testing.allocator);
    defer warehouse.deinit();
    try warehouse.graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 5), warehouse.graph.resources.items.len);
}
