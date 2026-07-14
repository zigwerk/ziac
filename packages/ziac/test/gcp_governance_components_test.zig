const std = @import("std");
const ziac = @import("ziac");

test "GovernedProjectBoundary composes policies tags and enforced plus dry-run perimeter state" {
    var boundary = try ziac.gcp.GovernedProjectBoundary.build(std.testing.allocator, config(), .{
        .name = "payments-prod",
        .project = ziac.PublicOutput([]const u8).known("projects/payments-prod-123"),
        .project_full_name = ziac.PublicOutput([]const u8).known("//cloudresourcemanager.googleapis.com/projects/987654321"),
        .policies = &.{
            .{ .name = "allowed-regions", .constraint = "gcp.resourceLocations", .spec = .{ .rules = &.{.{ .effect = .{ .values = .{ .allowed = &.{"in:eu-locations"} } } }} } },
            .{ .name = "disable-service-keys", .constraint = "iam.disableServiceAccountKeyCreation", .spec = .{ .rules = &.{.{ .effect = .{ .enforce = true } }} } },
        },
        .tag_value = ziac.PublicOutput([]const u8).known("tagValues/222"),
        .access_policy = ziac.PublicOutput([]const u8).known("accessPolicies/123"),
        .access_level = ziac.PublicOutput([]const u8).known("accessPolicies/123/accessLevels/trusted_engineers"),
        .restricted_services = &.{ "bigquery.googleapis.com", "storage.googleapis.com" },
        .dry_run_restricted_services = &.{ "bigquery.googleapis.com", "storage.googleapis.com", "secretmanager.googleapis.com" },
    });
    defer boundary.deinit();

    try boundary.graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 4), boundary.graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 2), countType(&boundary.graph, "gcp.orgpolicy.Policy"));
    try std.testing.expectEqual(@as(usize, 1), countType(&boundary.graph, "gcp.tags.TagBinding"));
    try std.testing.expectEqual(@as(usize, 1), countType(&boundary.graph, "gcp.accesscontextmanager.ServicePerimeter"));
    try std.testing.expect(boundary.tag_binding.referenceOrNull() != null);
    try std.testing.expect(boundary.perimeter.referenceOrNull() != null);
}

test "GovernedProjectBoundary appends to a shared graph and rejects duplicate policy names" {
    var base = ziac.ResourceGraph.init(std.testing.allocator);
    defer base.deinit();
    var tag_key = try ziac.gcp.governance.TagKey.build(std.testing.allocator, config(), .{
        .name = "environment",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .short_name = "environment",
    });
    defer tag_key.deinit(std.testing.allocator);
    try base.addResource(tag_key.node);

    var boundary = try ziac.gcp.GovernedProjectBoundary.build(std.testing.allocator, config(), .{
        .base_graph = &base,
        .name = "accounts-prod",
        .project = ziac.PublicOutput([]const u8).known("projects/accounts-prod-123"),
        .project_full_name = ziac.PublicOutput([]const u8).known("//cloudresourcemanager.googleapis.com/projects/123123123"),
        .policies = &.{},
        .tag_value = ziac.PublicOutput([]const u8).known("tagValues/333"),
        .access_policy = ziac.PublicOutput([]const u8).known("accessPolicies/123"),
        .restricted_services = &.{"storage.googleapis.com"},
    });
    defer boundary.deinit();
    try std.testing.expectEqual(@as(usize, 3), boundary.graph.resources.items.len);

    try std.testing.expectError(error.DuplicatePolicy, ziac.gcp.GovernedProjectBoundary.build(std.testing.allocator, config(), .{
        .name = "invalid",
        .project = ziac.PublicOutput([]const u8).known("projects/accounts-prod-123"),
        .project_full_name = ziac.PublicOutput([]const u8).known("//cloudresourcemanager.googleapis.com/projects/123123123"),
        .policies = &.{
            .{ .name = "regions", .constraint = "gcp.resourceLocations", .spec = .{ .rules = &.{.{ .effect = .{ .allow_all = {} } }} } },
            .{ .name = "regions", .constraint = "gcp.resourceLocations", .spec = .{ .rules = &.{.{ .effect = .{ .deny_all = {} } }} } },
        },
        .tag_value = ziac.PublicOutput([]const u8).known("tagValues/333"),
        .access_policy = ziac.PublicOutput([]const u8).known("accessPolicies/123"),
        .restricted_services = &.{"storage.googleapis.com"},
    }));
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "host-project", .primary_region = "europe-west1" };
}

fn countType(graph: *const ziac.ResourceGraph, type_name: []const u8) usize {
    var count: usize = 0;
    for (graph.resources.items) |node| {
        if (std.mem.eql(u8, node.type_name, type_name)) count += 1;
    }
    return count;
}
