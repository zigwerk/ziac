const std = @import("std");
const ziac = @import("ziac");

test "governance canvas exposes policy tag access and dry-run semantics at zero direct charge" {
    var boundary = try ziac.gcp.GovernedProjectBoundary.build(std.testing.allocator, config(), .{
        .name = "payments-prod",
        .project = ziac.PublicOutput([]const u8).known("projects/payments-prod-123"),
        .project_full_name = ziac.PublicOutput([]const u8).known("//cloudresourcemanager.googleapis.com/projects/987654321"),
        .policies = &.{.{ .name = "allowed-regions", .constraint = "gcp.resourceLocations", .spec = .{ .rules = &.{.{ .effect = .{ .values = .{ .allowed = &.{"in:eu-locations"} } } }} }, .dry_run_spec = .{ .rules = &.{.{ .effect = .{ .values = .{ .allowed = &.{"in:europe-west1-locations"} } } }} } }},
        .tag_value = ziac.PublicOutput([]const u8).known("tagValues/222"),
        .access_policy = ziac.PublicOutput([]const u8).known("accessPolicies/123"),
        .restricted_services = &.{ "bigquery.googleapis.com", "storage.googleapis.com" },
        .dry_run_restricted_services = &.{ "bigquery.googleapis.com", "storage.googleapis.com", "secretmanager.googleapis.com" },
    });
    defer boundary.deinit();
    var artifact = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &boundary.graph, null, .{
        .stack = "governance",
        .stage = "prod",
        .created_at_millis = 7,
    });
    defer artifact.deinit();

    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"governance\":{\"kind\":\"organization_policy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"has_dry_run_spec\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"enforced_rule_count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"governance\":{\"kind\":\"service_perimeter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"dry_run_restricted_service_count\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"amount_micros\":0") != null);
}

test "estate scan maps official governance assets to managed Ziac identities" {
    var client = ziac.estate.ScriptedClient.init(std.testing.allocator);
    defer client.deinit();
    try client.addPage(
        \\{"results":[
        \\{"name":"//orgpolicy.googleapis.com/organizations/123456789/policies/gcp.resourceLocations","assetType":"orgpolicy.googleapis.com/Policy","project":"","location":"global"},
        \\{"name":"//orgpolicy.googleapis.com/organizations/123456789/customConstraints/custom.requireCmek","assetType":"orgpolicy.googleapis.com/CustomConstraint","project":"","location":"global"},
        \\{"name":"//cloudresourcemanager.googleapis.com/tagKeys/111","assetType":"cloudresourcemanager.googleapis.com/TagKey","project":"","location":"global"},
        \\{"name":"//cloudresourcemanager.googleapis.com/tagValues/222","assetType":"cloudresourcemanager.googleapis.com/TagValue","project":"","location":"global"},
        \\{"name":"//cloudresourcemanager.googleapis.com/tagBindings/binding-333","assetType":"cloudresourcemanager.googleapis.com/TagBinding","project":"projects/987654321","location":"global"},
        \\{"name":"//cloudresourcemanager.googleapis.com/tagValues/222/tagHolds/444","assetType":"cloudresourcemanager.googleapis.com/TagHold","project":"","location":"global"},
        \\{"name":"//accesscontextmanager.googleapis.com/accessPolicies/123","assetType":"accesscontextmanager.googleapis.com/AccessPolicy","project":"","location":"global"},
        \\{"name":"//accesscontextmanager.googleapis.com/accessPolicies/123/accessLevels/trusted_engineers","assetType":"accesscontextmanager.googleapis.com/AccessLevel","project":"","location":"global"},
        \\{"name":"//accesscontextmanager.googleapis.com/accessPolicies/123/servicePerimeters/production_data","assetType":"accesscontextmanager.googleapis.com/ServicePerimeter","project":"","location":"global"},
        \\{"name":"//accesscontextmanager.googleapis.com/organizations/123456789/gcpUserAccessBindings/555","assetType":"accesscontextmanager.googleapis.com/GcpUserAccessBinding","project":"","location":"global"}
        \\]}
    );
    var scan = try ziac.estate.scanAlloc(std.testing.allocator, client.client(), .{
        .identity = .{ .provider = .google, .verified = true, .subject = "subject" },
        .entitlement = .pro,
        .connection = .{ .status = .connected, .project_id = "acme-prod" },
        .observed_at_millis = 1_783_764_000_000,
    });
    defer scan.deinit();

    try std.testing.expectEqual(@as(usize, 10), scan.resource_count);
    inline for (.{
        "gcp.orgpolicy.Policy",
        "gcp.orgpolicy.CustomConstraint",
        "gcp.tags.TagKey",
        "gcp.tags.TagValue",
        "gcp.tags.TagBinding",
        "gcp.tags.TagHold",
        "gcp.accesscontextmanager.AccessPolicy",
        "gcp.accesscontextmanager.AccessLevel",
        "gcp.accesscontextmanager.ServicePerimeter",
        "gcp.accesscontextmanager.GcpUserAccessBinding",
    }) |type_name| try std.testing.expect(std.mem.indexOf(u8, scan.artifact, type_name) != null);
}

test "governance cost is an honest zero configuration estimate" {
    const estimate = try ziac.cost.governanceConfigurationEstimate("ziac.governance.boundary", 7);
    try std.testing.expectEqual(@as(?i64, 0), estimate.amount_micros);
    try std.testing.expectEqual(ziac.cost.Origin.configuration_estimate, estimate.origin);
    try std.testing.expect(!estimate.provenance.is_billing_export);
}

test "governance canvas names policy tag and access boundary relationships" {
    var graph = try qualificationGraph();
    defer graph.deinit();
    var artifact = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &graph, null, .{
        .stack = "governance",
        .stage = "local-qualification",
        .created_at_millis = 0,
    });
    defer artifact.deinit();

    inline for (.{
        "\"kind\":\"policy_scope\"",
        "\"kind\":\"tag_membership\"",
        "\"kind\":\"tag_assignment\"",
        "\"kind\":\"access_policy_membership\"",
        "\"kind\":\"perimeter_membership\"",
        "\"kind\":\"perimeter_access\"",
    }) |needle| try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"scope\":\"organization\"") != null);
}

test "local governance qualification proves bounded deterministic evidence" {
    var graph = try qualificationGraph();
    defer graph.deinit();
    var retained: usize = 0;
    for (graph.resources.items) |node| if (node.lifecycle.retain_on_delete) {
        retained += 1;
    };
    var receipt = try ziac.gcp.governance_qualification.serializeLocalAlloc(std.testing.allocator, &graph, .{
        .created = graph.resources.items.len,
        .imported = graph.resources.items.len,
        .no_op = graph.resources.items.len,
        .retained = retained,
        .resumable_operations = 6,
        .list_discoveries = 1,
        .enforced_resources = 2,
        .dry_run_resources = 2,
    });
    defer receipt.deinit();

    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"schema\":\"ziac.gcp.governance-boundary-qualification.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"authenticated\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"enforced_resources\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"dry_run_resources\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "destructive_governance_actions_not_exercised") != null);
}

fn qualificationGraph() !ziac.ResourceGraph {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    errdefer graph.deinit();

    var project = try ziac.gcp.organization.Project.build(std.testing.allocator, config(), .{
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .project_id = "payments-prod-123",
        .display_name = "Payments production",
    });
    defer project.deinit(std.testing.allocator);
    try graph.addResource(project.node);

    var tag_key = try ziac.gcp.governance.TagKey.build(std.testing.allocator, config(), .{
        .name = "environment",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .short_name = "environment",
    });
    defer tag_key.deinit(std.testing.allocator);
    try graph.addResource(tag_key.node);
    var tag_value = try ziac.gcp.governance.TagValue.build(std.testing.allocator, config(), .{
        .name = "production",
        .parent = tag_key.name,
        .short_name = "production",
    });
    defer tag_value.deinit(std.testing.allocator);
    try graph.addResource(tag_value.node);

    var access_policy = try ziac.gcp.governance.AccessPolicy.build(std.testing.allocator, config(), .{
        .name = "production-boundary",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .title = "Production boundary",
    });
    defer access_policy.deinit(std.testing.allocator);
    try graph.addResource(access_policy.node);
    var access_level = try ziac.gcp.governance.AccessLevel.build(std.testing.allocator, config(), .{
        .name = "trusted_engineers",
        .policy = access_policy.name,
        .title = "Trusted engineers",
        .level = .{ .basic = .{ .conditions = &.{.{ .members = &.{"user:platform@example.com"} }} } },
    });
    defer access_level.deinit(std.testing.allocator);
    try graph.addResource(access_level.node);

    var boundary = try ziac.gcp.GovernedProjectBoundary.build(std.testing.allocator, config(), .{
        .base_graph = &graph,
        .name = "payments-prod",
        .project = project.name,
        .project_full_name = ziac.PublicOutput([]const u8).known("//cloudresourcemanager.googleapis.com/projects/987654321"),
        .policies = &.{.{
            .name = "allowed-regions",
            .constraint = "gcp.resourceLocations",
            .spec = .{ .rules = &.{.{ .effect = .{ .values = .{ .allowed = &.{"in:eu-locations"} } } }} },
            .dry_run_spec = .{ .rules = &.{.{ .effect = .{ .values = .{ .allowed = &.{"in:europe-west1-locations"} } } }} },
        }},
        .tag_value = tag_value.name,
        .access_policy = access_policy.name,
        .access_level = access_level.name,
        .restricted_services = &.{ "bigquery.googleapis.com", "storage.googleapis.com" },
        .dry_run_restricted_services = &.{ "bigquery.googleapis.com", "storage.googleapis.com", "secretmanager.googleapis.com" },
    });
    graph.deinit();
    try boundary.graph.addDependency("gcp.tags.TagBinding.payments-prod-tag", "gcp.resourcemanager.Project.payments-prod-123");
    return boundary.graph;
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "host-project", .primary_region = "europe-west1" };
}
