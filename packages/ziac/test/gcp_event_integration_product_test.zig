const std = @import("std");
const ziac = @import("ziac");

test "event integration graph synthesizes exact APIs and deployer permissions" {
    var route = try ziac.gcp.event_integration_components.AdvancedEventRoute.build(std.testing.allocator, provider(), .{
        .bus = .{ .name = "application-events", .location = "europe-west1" },
        .pipeline = .{ .name = "orders", .location = "europe-west1", .destination = .{ .https = .{ .uri = "https://orders.example.com/events" } } },
        .enrollment_name = "orders-created",
        .cel_match = "message.type == 'com.example.orders.created'",
        .publishers = &.{"serviceAccount:api@events-prod.iam.gserviceaccount.com"},
    });
    defer route.deinit();
    var connector = try ziac.gcp.event_integration_components.ConnectorEventBridge.build(std.testing.allocator, provider(), .{
        .connection = .{ .name = "crm", .location = "europe-west1", .connector_version = "projects/events-prod/locations/global/providers/salesforce/connectors/salesforce/versions/1" },
        .subscription = .{ .name = "accounts", .location = "europe-west1", .connection = .{ .value = "placeholder" }, .event_type_id = "account.updated", .destination = .{ .pubsub = .{ .project_id = "events-prod", .topic_id = "crm-events" } } },
    });
    defer connector.deinit();
    try route.graph.appendGraph(&connector.graph);
    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &route.graph);
    defer requirements.deinit(std.testing.allocator);
    try std.testing.expect(contains(requirements.apis, "eventarc.googleapis.com"));
    try std.testing.expect(contains(requirements.apis, "connectors.googleapis.com"));
    try std.testing.expect(requirements.hasPermission("eventarc.messageBuses.create"));
    try std.testing.expect(requirements.hasPermission("eventarc.enrollments.create"));
    try std.testing.expect(requirements.hasPermission("connectors.connections.create"));
    try std.testing.expect(requirements.hasPermission("connectors.eventSubscriptions.create"));
}

test "estate scan maps Eventarc Advanced and Connectors assets to managed identities" {
    var client = ziac.estate.ScriptedClient.init(std.testing.allocator);
    defer client.deinit();
    try client.addPage(
        \\{"results":[
        \\{"name":"//eventarc.googleapis.com/projects/events-prod/locations/europe-west1/messageBuses/application-events","assetType":"eventarc.googleapis.com/MessageBus","project":"projects/123","location":"europe-west1"},
        \\{"name":"//eventarc.googleapis.com/projects/events-prod/locations/europe-west1/pipelines/orders","assetType":"eventarc.googleapis.com/Pipeline","project":"projects/123","location":"europe-west1"},
        \\{"name":"//connectors.googleapis.com/projects/events-prod/locations/europe-west1/connections/crm","assetType":"connectors.googleapis.com/Connection","project":"projects/123","location":"europe-west1"},
        \\{"name":"//connectors.googleapis.com/projects/events-prod/locations/europe-west1/connections/crm/eventSubscriptions/accounts","assetType":"connectors.googleapis.com/EventSubscription","project":"projects/123","location":"europe-west1"}
        \\]}
    );
    var scan = try ziac.estate.scanAlloc(std.testing.allocator, client.client(), .{
        .identity = .{ .provider = .google, .verified = true, .subject = "subject" },
        .entitlement = .pro,
        .connection = .{ .status = .connected, .project_id = "events-prod" },
        .observed_at_millis = 1,
    });
    defer scan.deinit();
    try std.testing.expectEqual(@as(usize, 4), scan.resource_count);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.eventarc.MessageBus") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.connectors.EventSubscription") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "projects/events-prod/locations/europe-west1/connections/crm") != null);
}

test "visual artifact projects event integration topology and honest estimates" {
    var route = try ziac.gcp.event_integration_components.AdvancedEventRoute.build(std.testing.allocator, provider(), .{
        .bus = .{ .name = "application-events", .location = "europe-west1" },
        .pipeline = .{ .name = "orders", .location = "europe-west1", .destination = .{ .https = .{ .uri = "https://orders.example.com/events" } } },
        .enrollment_name = "orders-created",
        .cel_match = "message.type == 'com.example.orders.created'",
    });
    defer route.deinit();
    var artifact = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &route.graph, null, .{ .stack = "events", .stage = "prod", .created_at_millis = 1 });
    defer artifact.deinit();
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"event_integration\":{\"kind\":\"message_bus\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"event_integration\":{\"kind\":\"event_pipeline\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"basis\":\"usage_assumptions_required\"") != null);
}

fn provider() ziac.gcp.ProviderConfig {
    return .{ .project_id = "events-prod", .primary_region = "europe-west1", .service_regions = &.{"europe-west1"} };
}
fn contains(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, expected)) return true;
    return false;
}
