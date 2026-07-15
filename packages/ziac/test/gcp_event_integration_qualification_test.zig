const std = @import("std");
const ziac = @import("ziac");

test "local event integration qualification proves bounded deterministic evidence" {
    var graph = try qualificationGraph();
    defer graph.deinit();
    var retained: usize = 0;
    var resumable: usize = 0;
    var estimates: usize = 0;
    for (graph.resources.items) |node| {
        if (node.lifecycle.retain_on_delete) retained += 1;
        if (std.mem.indexOf(u8, node.type_name, "IamMember") == null and (std.mem.startsWith(u8, node.type_name, "gcp.eventarc.") or std.mem.startsWith(u8, node.type_name, "gcp.connectors."))) resumable += 1;
        if (std.mem.eql(u8, node.type_name, "gcp.eventarc.MessageBus") or std.mem.eql(u8, node.type_name, "gcp.eventarc.Pipeline") or std.mem.eql(u8, node.type_name, "gcp.eventarc.Enrollment") or std.mem.eql(u8, node.type_name, "gcp.eventarc.GoogleApiSource") or std.mem.eql(u8, node.type_name, "gcp.connectors.Connection") or std.mem.eql(u8, node.type_name, "gcp.connectors.EventSubscription")) estimates += 1;
    }
    var receipt = try ziac.gcp.event_integration_qualification.serializeLocalAlloc(std.testing.allocator, &graph, .{
        .created = graph.resources.items.len,
        .imported = graph.resources.items.len,
        .no_op = graph.resources.items.len,
        .retained = retained,
        .resumable_operations = resumable,
        .supported_asset_identities = 9,
        .governed_action_boundaries = ziac.gcp.intelligence.eventIntegrationActionUsages().len,
        .estimates_requiring_usage = estimates,
    });
    defer receipt.deinit();
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"schema\":\"ziac.gcp.event-integration-qualification.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"resource_count\":10") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"governed_action_boundaries\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "authenticated_event_integration_mutation_not_exercised") != null);
}

fn qualificationGraph() !ziac.ResourceGraph {
    const provider = ziac.gcp.ProviderConfig{ .project_id = "events-prod", .primary_region = "europe-west1", .service_regions = &.{"europe-west1"} };
    var route = try ziac.gcp.event_integration_components.AdvancedEventRoute.build(std.testing.allocator, provider, .{
        .bus = .{ .name = "application-events", .location = "europe-west1" },
        .pipeline = .{ .name = "orders", .location = "europe-west1", .destination = .{ .https = .{ .uri = "https://orders.example.com/events" } } },
        .enrollment_name = "orders-created",
        .cel_match = "message.type == 'com.example.orders.created'",
        .publishers = &.{"serviceAccount:api@events-prod.iam.gserviceaccount.com"},
    });
    defer route.deinit();
    var private = try ziac.gcp.event_integration_components.PrivateConnector.build(std.testing.allocator, provider, .{
        .base_graph = &route.graph,
        .settings = .{ .location = "europe-west1", .egress_mode = .private_ip },
        .connection = .{ .name = "crm", .location = "europe-west1", .connector_version = "projects/events-prod/locations/global/providers/salesforce/connectors/salesforce/versions/1" },
        .endpoint = .{ .name = "crm-psc", .location = "europe-west1", .service_attachment = .{ .value = "projects/events-prod/regions/europe-west1/serviceAttachments/crm" } },
        .operators = &.{"group:integration@example.com"},
    });
    defer private.deinit();
    const bridge = try ziac.gcp.event_integration_components.ConnectorEventBridge.build(std.testing.allocator, provider, .{
        .base_graph = &private.graph,
        .connection = .{ .name = "erp", .location = "europe-west1", .connector_version = "projects/events-prod/locations/global/providers/sap/connectors/sap/versions/1" },
        .subscription = .{ .name = "invoices", .location = "europe-west1", .connection = .{ .value = "placeholder" }, .event_type_id = "invoice.created", .destination = .{ .pubsub = .{ .project_id = "events-prod", .topic_id = "erp-events" } } },
    });
    return bridge.graph;
}
