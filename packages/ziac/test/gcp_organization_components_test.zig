const std = @import("std");
const ziac = @import("ziac");

test "ProjectFoundation wires folder project billing services and identities in one graph" {
    var foundation = try ziac.gcp.ProjectFoundation.build(std.testing.allocator, config(), .{
        .name = "payments",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .folder = .{ .display_name = "Payments" },
        .project_id = "payments-prod-123",
        .project_display_name = "Payments Production",
        .billing_account = "billingAccounts/000000-111111-222222",
        .services = &.{ "run.googleapis.com", "secretmanager.googleapis.com" },
        .service_identities = &.{"run.googleapis.com"},
    });
    defer foundation.deinit();

    try std.testing.expectEqual(@as(usize, 6), foundation.graph.resources.items.len);
    try std.testing.expect(hasType(&foundation.graph, "gcp.resourcemanager.Folder"));
    try std.testing.expect(hasType(&foundation.graph, "gcp.resourcemanager.Project"));
    try std.testing.expect(hasType(&foundation.graph, "gcp.billing.ProjectBillingAssociation"));
    try std.testing.expectEqual(@as(usize, 2), countType(&foundation.graph, "gcp.project.Service"));
    try std.testing.expect(hasType(&foundation.graph, "gcp.serviceusage.ServiceIdentity"));
    try std.testing.expect(foundation.graph.dependencies.items.len >= 5);
}

test "ProjectFoundation supports direct project placement and rejects duplicate declarations" {
    var foundation = try ziac.gcp.ProjectFoundation.build(std.testing.allocator, config(), .{
        .name = "api",
        .parent = ziac.PublicOutput([]const u8).known("folders/123456789"),
        .project_id = "api-prod-123",
        .billing_account = "billingAccounts/000000-111111-222222",
        .services = &.{"run.googleapis.com"},
    });
    defer foundation.deinit();
    try std.testing.expectEqual(@as(usize, 3), foundation.graph.resources.items.len);

    try std.testing.expectError(error.DuplicateService, ziac.gcp.ProjectFoundation.build(std.testing.allocator, config(), .{
        .name = "api",
        .parent = ziac.PublicOutput([]const u8).known("folders/123456789"),
        .project_id = "api-prod-123",
        .billing_account = "billingAccounts/000000-111111-222222",
        .services = &.{ "run.googleapis.com", "run.googleapis.com" },
    }));
}

test "ProjectFoundation scopes shared service resources across merged project graphs" {
    var payments = try ziac.gcp.ProjectFoundation.build(std.testing.allocator, config(), .{
        .name = "payments",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .project_id = "payments-prod-123",
        .billing_account = "billingAccounts/000000-111111-222222",
        .services = &.{ "run.googleapis.com", "secretmanager.googleapis.com" },
        .service_identities = &.{"run.googleapis.com"},
    });
    defer payments.deinit();

    var accounts = try ziac.gcp.ProjectFoundation.build(std.testing.allocator, config(), .{
        .base_graph = &payments.graph,
        .name = "accounts",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .project_id = "accounts-prod-123",
        .billing_account = "billingAccounts/000000-111111-222222",
        .services = &.{ "run.googleapis.com", "secretmanager.googleapis.com" },
        .service_identities = &.{"run.googleapis.com"},
    });
    defer accounts.deinit();

    try accounts.graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 10), accounts.graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 2), countType(&accounts.graph, "gcp.billing.ProjectBillingAssociation"));
    try std.testing.expectEqual(@as(usize, 4), countType(&accounts.graph, "gcp.project.Service"));
    try std.testing.expectEqual(@as(usize, 2), countType(&accounts.graph, "gcp.serviceusage.ServiceIdentity"));
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "host-project", .primary_region = "europe-west1" };
}

fn hasType(graph: *const ziac.ResourceGraph, type_name: []const u8) bool {
    return countType(graph, type_name) != 0;
}

fn countType(graph: *const ziac.ResourceGraph, type_name: []const u8) usize {
    var count: usize = 0;
    for (graph.resources.items) |node| {
        if (std.mem.eql(u8, node.type_name, type_name)) count += 1;
    }
    return count;
}
