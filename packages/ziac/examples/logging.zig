const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{
    .project_id = "example-project",
    .primary_region = "europe-west1",
};

fn build(allocator: std.mem.Allocator) !ziac.gcp.ApplicationLogPlatform {
    return ziac.gcp.ApplicationLogPlatform.build(allocator, provider, .{
        .name = "global-api",
        .location = "global",
        .description = "Global API application logs",
        .retention_days = 90,
        .analytics_enabled = true,
        .views = &.{.{
            .name = "production-errors",
            .description = "Errors visible to the production response team",
            .filter = "severity>=ERROR AND resource.type=\"cloud_run_revision\"",
        }},
        .route_filter = "resource.type=\"cloud_run_revision\"",
        .route_exclusions = &.{.{
            .name = "health-checks",
            .filter = "httpRequest.userAgent=\"GoogleHC/1.0\"",
        }},
        .project_exclusions = &.{.{
            .name = "debug-sample",
            .filter = "severity=DEBUG AND sample(insertId, 0.9)",
        }},
        .metrics = &.{.{
            .name = "application-errors",
            .description = "Cloud Run application errors",
            .filter = "severity>=ERROR resource.type=\"cloud_run_revision\"",
            .labels = &.{.{ .key = "region", .description = "Serving region" }},
            .label_extractors = &.{.{ .key = "region", .extractor = "EXTRACT(resource.labels.location)" }},
        }},
    });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var platform = try build(allocator);
    defer platform.deinit();
    var permissions = try ziac.gcp.intelligence.synthesizePermissionPlan(allocator, &platform.graph);
    defer permissions.deinit(allocator);
    std.debug.print("Logging: {d} resources, {d} causal edges, {d} exact permissions\n", .{
        platform.graph.resources.items.len,
        platform.graph.dependencies.items.len,
        permissions.deployer_permissions.len,
    });
}

test "logging example compiles bucket views route exclusions and metrics" {
    var platform = try build(std.testing.allocator);
    defer platform.deinit();
    try platform.graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 5), platform.graph.resources.items.len);
}
