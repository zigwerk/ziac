const std = @import("std");
const ziac = @import("ziac");

test "ApplicationLogPlatform composes storage access routing exclusions and metrics" {
    var platform = try ziac.gcp.ApplicationLogPlatform.build(std.testing.allocator, config(), .{
        .name = "global-api",
        .location = "global",
        .retention_days = 90,
        .analytics_enabled = true,
        .views = &.{
            .{ .name = "errors", .filter = "severity>=ERROR" },
            .{ .name = "audit", .filter = "logName:\"cloudaudit.googleapis.com\"" },
        },
        .route_filter = "resource.type=\"cloud_run_revision\"",
        .route_exclusions = &.{.{ .name = "health-checks", .filter = "httpRequest.userAgent=\"GoogleHC/1.0\"" }},
        .project_exclusions = &.{.{ .name = "debug-sample", .filter = "severity=DEBUG AND sample(insertId, 0.9)" }},
        .metrics = &.{
            .{ .name = "errors", .filter = "severity>=ERROR" },
            .{ .name = "latency", .filter = "jsonPayload.latency_ms:*", .mode = .{ .distribution = .{
                .value_extractor = "EXTRACT(jsonPayload.latency_ms)",
                .buckets = .{ .linear = .{ .count = 10, .width_micros = 100_000 } },
            } } },
        },
        .protect = false,
    });
    defer platform.deinit();

    try std.testing.expectEqual(@as(usize, 7), platform.graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 5), platform.graph.dependencies.items.len);
    try std.testing.expectEqual(@as(usize, 2), platform.views.len);
    try std.testing.expectEqual(@as(usize, 2), platform.metrics.len);
    try std.testing.expect(hasType(&platform.graph, "gcp.logging.Bucket"));
    try std.testing.expect(hasType(&platform.graph, "gcp.logging.View"));
    try std.testing.expect(hasType(&platform.graph, "gcp.logging.Sink"));
    try std.testing.expect(hasType(&platform.graph, "gcp.logging.Exclusion"));
    try std.testing.expect(hasType(&platform.graph, "gcp.logging.Metric"));
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
}

fn hasType(graph: *const ziac.ResourceGraph, type_name: []const u8) bool {
    for (graph.resources.items) |node| if (std.mem.eql(u8, node.type_name, type_name)) return true;
    return false;
}
