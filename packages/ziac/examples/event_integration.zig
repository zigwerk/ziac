const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{ .project_id = "events-prod", .primary_region = "europe-west1", .service_regions = &.{"europe-west1"} };

fn build(allocator: std.mem.Allocator) !ziac.gcp.event_integration_components.ConnectorEventBridge {
    var route = try ziac.gcp.event_integration_components.AdvancedEventRoute.build(allocator, provider, .{
        .bus = .{ .name = "application-events", .location = "europe-west1" },
        .pipeline = .{ .name = "orders", .location = "europe-west1", .destination = .{ .https = .{ .uri = "https://orders.example.com/events" } } },
        .enrollment_name = "orders-created",
        .cel_match = "message.type == 'com.example.orders.created'",
        .publishers = &.{"serviceAccount:api@events-prod.iam.gserviceaccount.com"},
    });
    defer route.deinit();
    var private = try ziac.gcp.event_integration_components.PrivateConnector.build(allocator, provider, .{
        .base_graph = &route.graph,
        .settings = .{ .location = "europe-west1", .egress_mode = .private_ip },
        .connection = .{ .name = "crm", .location = "europe-west1", .connector_version = "projects/events-prod/locations/global/providers/salesforce/connectors/salesforce/versions/1" },
        .endpoint = .{ .name = "crm-psc", .location = "europe-west1", .service_attachment = .{ .value = "projects/events-prod/regions/europe-west1/serviceAttachments/crm" } },
        .operators = &.{"group:integration@example.com"},
    });
    defer private.deinit();
    return ziac.gcp.event_integration_components.ConnectorEventBridge.build(allocator, provider, .{
        .base_graph = &private.graph,
        .connection = .{ .name = "erp", .location = "europe-west1", .connector_version = "projects/events-prod/locations/global/providers/sap/connectors/sap/versions/1" },
        .subscription = .{ .name = "invoices", .location = "europe-west1", .connection = .{ .value = "placeholder" }, .event_type_id = "invoice.created", .destination = .{ .pubsub = .{ .project_id = "events-prod", .topic_id = "erp-events" } } },
    });
}

pub fn main() !void {
    var platform = try build(std.heap.page_allocator);
    defer platform.deinit();
    var permissions = try ziac.gcp.intelligence.synthesizePermissionPlan(std.heap.page_allocator, &platform.graph);
    defer permissions.deinit(std.heap.page_allocator);
    std.debug.print("event integration: {d} resources, {d} dependencies, {d} deployer permissions, {d} runtime permissions\n", .{ platform.graph.resources.items.len, platform.graph.dependencies.items.len, permissions.deployer_permissions.len, permissions.runtime_permissions.len });
}

test "event integration example composes Eventarc Advanced and private connectors" {
    var platform = try build(std.testing.allocator);
    defer platform.deinit();
    try platform.graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 10), platform.graph.resources.items.len);
    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &platform.graph);
    defer requirements.deinit(std.testing.allocator);
    try std.testing.expect(requirements.hasPermission("eventarc.messageBuses.create"));
    try std.testing.expect(requirements.hasPermission("connectors.connections.create"));
}
