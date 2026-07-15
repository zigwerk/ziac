const std = @import("std");
const ziac = @import("ziac");

const components = ziac.gcp.event_integration_components;
const eventarc = ziac.gcp.eventarc_advanced;
const connectors = ziac.gcp.connectors;

test "advanced event route wires bus pipeline enrollment and publishers" {
    var built = try components.AdvancedEventRoute.build(std.testing.allocator, provider(), .{
        .bus = .{ .name = "application-events", .location = "europe-west1" },
        .pipeline = .{ .name = "orders", .location = "europe-west1", .destination = .{ .https = .{ .uri = "https://orders.example.com/events" } } },
        .enrollment_name = "orders-created",
        .cel_match = "message.type == 'com.example.orders.created'",
        .publishers = &.{"serviceAccount:api@events-prod.iam.gserviceaccount.com"},
    });
    defer built.deinit();
    try std.testing.expectEqual(@as(usize, 4), built.graph.resources.items.len);
    try built.graph.validateAcyclic();
    try std.testing.expectEqualStrings("gcp.eventarc.Enrollment.europe-west1.orders-created", built.graph.resources.items[2].id);
}

test "private connector composes regional settings connection and PSC attachment" {
    var built = try components.PrivateConnector.build(std.testing.allocator, provider(), .{
        .settings = .{ .location = "europe-west1", .egress_mode = .private_ip },
        .connection = .{ .name = "crm", .location = "europe-west1", .connector_version = "projects/events-prod/locations/global/providers/salesforce/connectors/salesforce/versions/1", .node_config = .{ .min_nodes = 1, .max_nodes = 2 } },
        .endpoint = .{ .name = "crm-psc", .location = "europe-west1", .service_attachment = .{ .value = "projects/events-prod/regions/europe-west1/serviceAttachments/crm" } },
        .operators = &.{"group:integration@example.com"},
    });
    defer built.deinit();
    try std.testing.expectEqual(@as(usize, 4), built.graph.resources.items.len);
    try built.graph.validateAcyclic();
}

test "connector event bridge binds subscription to managed connection" {
    var built = try components.ConnectorEventBridge.build(std.testing.allocator, provider(), .{
        .connection = .{ .name = "crm", .location = "europe-west1", .connector_version = "projects/events-prod/locations/global/providers/salesforce/connectors/salesforce/versions/1" },
        .subscription = .{ .name = "accounts", .location = "europe-west1", .connection = .{ .value = "placeholder" }, .event_type_id = "account.updated", .destination = .{ .pubsub = .{ .project_id = "events-prod", .topic_id = "crm-events" } } },
    });
    defer built.deinit();
    try std.testing.expectEqual(@as(usize, 2), built.graph.resources.items.len);
    try built.graph.validateAcyclic();
    const dependency = built.graph.dependencies.items[0];
    try std.testing.expectEqualStrings("gcp.connectors.Connection.europe-west1.crm", dependency.to);
}

fn provider() ziac.gcp.config.ProviderConfig {
    return .{ .project_id = "events-prod", .primary_region = "europe-west1", .service_regions = &.{"europe-west1"} };
}
