const std = @import("std");
const ziac = @import("ziac");

fn build(allocator: std.mem.Allocator) !ziac.gcp.GovernedProjectBoundary {
    const provider = ziac.gcp.ProviderConfig{
        .project_id = "bootstrap-host",
        .primary_region = "europe-west1",
    };
    return ziac.gcp.GovernedProjectBoundary.build(allocator, provider, .{
        .name = "payments-prod",
        .project = ziac.PublicOutput([]const u8).known("projects/payments-prod-123"),
        .project_full_name = ziac.PublicOutput([]const u8).known("//cloudresourcemanager.googleapis.com/projects/987654321"),
        .policies = &.{.{
            .name = "allowed-regions",
            .constraint = "gcp.resourceLocations",
            .spec = .{ .rules = &.{.{ .effect = .{ .values = .{ .allowed = &.{"in:eu-locations"} } } }} },
            .dry_run_spec = .{ .rules = &.{.{ .effect = .{ .values = .{ .allowed = &.{"in:europe-west1-locations"} } } }} },
        }},
        // Organization-wide singletons are supplied as typed outputs and can be
        // shared by many independently deployed project boundaries.
        .tag_value = ziac.PublicOutput([]const u8).known("tagValues/222"),
        .access_policy = ziac.PublicOutput([]const u8).known("accessPolicies/123"),
        .access_level = ziac.PublicOutput([]const u8).known("accessPolicies/123/accessLevels/trusted_engineers"),
        .restricted_services = &.{ "bigquery.googleapis.com", "storage.googleapis.com" },
        .dry_run_restricted_services = &.{ "bigquery.googleapis.com", "storage.googleapis.com", "secretmanager.googleapis.com" },
    });
}

pub fn main() !void {
    var boundary = try build(std.heap.page_allocator);
    defer boundary.deinit();
    var permissions = try ziac.gcp.intelligence.synthesizePermissionPlan(std.heap.page_allocator, &boundary.graph);
    defer permissions.deinit(std.heap.page_allocator);
    std.debug.print("Governed boundary: {d} resources, {d} dependencies, {d} exact deployer permissions\n", .{
        boundary.graph.resources.items.len,
        boundary.graph.dependencies.items.len,
        permissions.deployer_permissions.len,
    });
}

test "governed project boundary keeps enforcement and dry-run in one graph" {
    var boundary = try build(std.testing.allocator);
    defer boundary.deinit();
    try boundary.graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 3), boundary.graph.resources.items.len);
}
