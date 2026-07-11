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
