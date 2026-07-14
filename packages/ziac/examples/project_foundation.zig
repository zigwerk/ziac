const std = @import("std");
const ziac = @import("ziac");

fn build(allocator: std.mem.Allocator) !ziac.gcp.ProjectFoundation {
    const provider = ziac.gcp.ProviderConfig{
        .project_id = "bootstrap-host",
        .primary_region = "europe-west1",
    };
    return ziac.gcp.ProjectFoundation.build(allocator, provider, .{
        .name = "platform",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .folder = .{ .display_name = "Platform" },
        .project_id = "example-platform-prod",
        .project_display_name = "Example Platform",
        .project_labels = &.{.{ .key = "managed-by", .value = "ziac" }},
        .billing_account = "billingAccounts/000000-111111-222222",
        .services = &.{
            "run.googleapis.com",
            "secretmanager.googleapis.com",
            "cloudbuild.googleapis.com",
        },
        .service_identities = &.{
            "run.googleapis.com",
            "cloudbuild.googleapis.com",
        },
    });
}

pub fn main() !void {
    var foundation = try build(std.heap.page_allocator);
    defer foundation.deinit();
    var permissions = try ziac.gcp.intelligence.synthesizePermissionPlan(std.heap.page_allocator, &foundation.graph);
    defer permissions.deinit(std.heap.page_allocator);
    std.debug.print("Project foundation: {d} resources, {d} dependencies, {d} exact deployer permissions\n", .{
        foundation.graph.resources.items.len,
        foundation.graph.dependencies.items.len,
        permissions.deployer_permissions.len,
    });
}

test "project foundation example compiles a retained hierarchy" {
    var foundation = try build(std.testing.allocator);
    defer foundation.deinit();
    try foundation.graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 8), foundation.graph.resources.items.len);
    try std.testing.expect(foundation.folder != null);
}
