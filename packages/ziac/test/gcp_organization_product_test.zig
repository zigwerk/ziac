const std = @import("std");
const ziac = @import("ziac");

test "project foundation synthesizes hierarchy billing service and identity authority" {
    var graph = try foundationGraph();
    defer graph.deinit();
    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &graph);
    defer requirements.deinit(std.testing.allocator);

    try std.testing.expect(contains(requirements.apis, "cloudresourcemanager.googleapis.com"));
    try std.testing.expect(contains(requirements.apis, "cloudbilling.googleapis.com"));
    try std.testing.expect(contains(requirements.apis, "serviceusage.googleapis.com"));
    try std.testing.expect(requirements.hasPermission("resourcemanager.folders.create"));
    try std.testing.expect(requirements.hasPermission("resourcemanager.projects.create"));
    try std.testing.expect(requirements.hasPermission("resourcemanager.projects.move"));
    try std.testing.expect(requirements.hasPermission("resourcemanager.projects.updateLiens"));
    try std.testing.expect(requirements.hasPermission("billing.resourceAssociations.create"));
    try std.testing.expect(requirements.hasPermission("resourcemanager.projects.createBillingAssignment"));
    try std.testing.expect(requirements.hasPermission("serviceusage.services.list"));
    try std.testing.expect(requirements.hasPermission("serviceusage.effectivepolicy.get"));
    try std.testing.expect(requirements.hasPermission("serviceusage.services.use"));
}

test "project foundation canvas exposes hierarchy ownership and billing topology" {
    var graph = try foundationGraph();
    defer graph.deinit();
    var artifact = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &graph, null, .{
        .stack = "foundation",
        .stage = "prod",
        .created_at_millis = 7,
    });
    defer artifact.deinit();

    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"organization_foundation\":{\"kind\":\"folder\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"organization_foundation\":{\"kind\":\"project\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"hierarchy_parent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"billing_attachment\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"api_enablement\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"service_identity\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"amount_micros\":0") != null);
}

test "estate scan maps official Resource Manager hierarchy assets" {
    var client = ziac.estate.ScriptedClient.init(std.testing.allocator);
    defer client.deinit();
    try client.addPage(
        \\{"results":[
        \\{"name":"//cloudresourcemanager.googleapis.com/folders/123456789","assetType":"cloudresourcemanager.googleapis.com/Folder","project":"","location":"global"},
        \\{"name":"//cloudresourcemanager.googleapis.com/projects/987654321","assetType":"cloudresourcemanager.googleapis.com/Project","project":"projects/987654321","location":"global"},
        \\{"name":"//cloudresourcemanager.googleapis.com/liens/112233","assetType":"cloudresourcemanager.googleapis.com/Lien","project":"projects/987654321","location":"global"}
        \\]}
    );
    var scan = try ziac.estate.scanAlloc(std.testing.allocator, client.client(), .{
        .identity = .{ .provider = .google, .verified = true, .subject = "subject" },
        .entitlement = .pro,
        .connection = .{ .status = .connected, .project_id = "acme-prod" },
        .observed_at_millis = 1_783_764_000_000,
    });
    defer scan.deinit();

    try std.testing.expectEqual(@as(usize, 3), scan.resource_count);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.resourcemanager.Folder") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.resourcemanager.Project") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.resourcemanager.Lien") != null);
}

test "organization foundation cost is an honest zero configuration estimate" {
    const estimate = try ziac.cost.organizationFoundationEstimate("ziac.foundation.project", 7);
    try std.testing.expectEqual(@as(?i64, 0), estimate.amount_micros);
    try std.testing.expectEqual(ziac.cost.Origin.configuration_estimate, estimate.origin);
    try std.testing.expect(!estimate.provenance.is_billing_export);
}

test "destructive permissions appear only when destructive policy is declared" {
    var retained = try ziac.gcp.organization.Project.build(std.testing.allocator, config(), .{
        .project_id = "ziac-retained-123",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
    });
    defer retained.deinit(std.testing.allocator);
    var deletable = try ziac.gcp.organization.Project.build(std.testing.allocator, config(), .{
        .project_id = "ziac-delete-123",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .request_delete = true,
        .protect = false,
        .retain_on_delete = false,
    });
    defer deletable.deinit(std.testing.allocator);
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.addResource(retained.node);
    var retained_requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &graph);
    defer retained_requirements.deinit(std.testing.allocator);
    try std.testing.expect(!retained_requirements.hasPermission("resourcemanager.projects.delete"));

    graph.deinit();
    graph = ziac.ResourceGraph.init(std.testing.allocator);
    try graph.addResource(deletable.node);
    var destructive_requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &graph);
    defer destructive_requirements.deinit(std.testing.allocator);
    try std.testing.expect(destructive_requirements.hasPermission("resourcemanager.projects.delete"));
}

test "billing detach selects the project-side unlink authority" {
    var billing = try ziac.gcp.organization.ProjectBillingAssociation.build(std.testing.allocator, config(), .{
        .project = ziac.PublicOutput([]const u8).known("projects/ziac-platform-prod"),
        .billing_account = "billingAccounts/000000-111111-222222",
        .removal_policy = .detach,
    });
    defer billing.deinit(std.testing.allocator);
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.addResource(billing.node);
    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &graph);
    defer requirements.deinit(std.testing.allocator);

    try std.testing.expect(requirements.hasPermission("resourcemanager.projects.deleteBillingAssignment"));
    try std.testing.expect(!requirements.hasPermission("billing.resourceAssociations.delete"));
}

test "local organization qualification records bounded non-destructive evidence" {
    var graph = try foundationGraph();
    defer graph.deinit();
    var retained: usize = 0;
    for (graph.resources.items) |node| if (node.lifecycle.retain_on_delete) {
        retained += 1;
    };
    var receipt = try ziac.gcp.organization_qualification.serializeLocalAlloc(std.testing.allocator, &graph, .{
        .created = graph.resources.items.len,
        .imported = graph.resources.items.len,
        .no_op = graph.resources.items.len,
        .retained = retained,
        .resumable_operations = 3,
    });
    defer receipt.deinit();
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"schema\":\"ziac.gcp.organization-foundation-qualification.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"authenticated\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "destructive_hierarchy_actions_not_exercised") != null);
}

fn foundationGraph() !ziac.ResourceGraph {
    var foundation = try ziac.gcp.ProjectFoundation.build(std.testing.allocator, config(), .{
        .name = "platform",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .folder = .{ .display_name = "Platform" },
        .project_id = "ziac-platform-prod",
        .project_display_name = "Ziac Platform",
        .billing_account = "billingAccounts/000000-111111-222222",
        .services = &.{"run.googleapis.com"},
        .service_identities = &.{"run.googleapis.com"},
    });
    defer foundation.deinit();
    var lien = try ziac.gcp.organization.Lien.build(std.testing.allocator, config(), .{
        .name = "production-protection",
        .parent = foundation.project,
        .reason = "Prevent accidental production project deletion",
        .origin = "ziac",
        .restrictions = &.{"resourcemanager.projects.delete"},
    });
    defer lien.deinit(std.testing.allocator);
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    errdefer graph.deinit();
    try graph.appendGraph(&foundation.graph);
    try graph.addResource(lien.node);
    return graph;
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "host-project", .primary_region = "europe-west1" };
}

fn contains(values: []const []const u8, expected: []const u8) bool {
    for (values) |present| if (std.mem.eql(u8, present, expected)) return true;
    return false;
}
