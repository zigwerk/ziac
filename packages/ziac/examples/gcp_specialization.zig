const std = @import("std");
const ziac = @import("ziac");

const regions = [_][]const u8{ "europe-west1", "us-central1", "asia-northeast1" };

fn build(allocator: std.mem.Allocator) !ziac.gcp.global.ContainerService {
    return ziac.gcp.global.ContainerService.build(allocator, .{
        .project_id = "example-project",
        .primary_region = regions[0],
        .service_regions = &regions,
        .network_tier = .premium,
        .service_account = "api@example-project.iam.gserviceaccount.com",
    }, .{
        .name = "api",
        .image = "europe-west1-docker.pkg.dev/example-project/apps/api@sha256:example",
        .regions = &regions,
        .domain = "api.example.com",
        .realization = .automatic,
    });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var component = try build(allocator);
    defer component.deinit();
    var requirements = try ziac.gcp.intelligence.synthesizeGraph(allocator, &component.graph);
    defer requirements.deinit(allocator);
    std.debug.print("{s}: {s}; {d} RPC methods and {d} permissions\n", .{
        @tagName(component.realization),
        component.realization_reason,
        requirements.methods.len,
        requirements.permissions.len,
    });
}

test "GCP specialization example compiles native topology and exact preflight" {
    var component = try build(std.testing.allocator);
    defer component.deinit();
    try std.testing.expectEqual(ziac.gcp.global.Realization.native_multi_region, component.realization);

    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &component.graph);
    defer requirements.deinit(std.testing.allocator);
    try std.testing.expect(requirements.hasPermission("run.services.create"));
    try std.testing.expect(requirements.hasPermission("compute.backendServices.create"));

    var report = try ziac.gcp.intelligence.evaluatePreflight(std.testing.allocator, requirements, .{
        .enabled_apis = requirements.apis,
        .granted_permissions = requirements.permissions,
        .billing_enabled = true,
        .available_regions = &regions,
        .requested_regions = &regions,
    });
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.ready);
}
