const std = @import("std");
const ziac = @import("ziac");

const connectors = ziac.gcp.connectors;

test "Integration Connectors declarations keep credentials reference-only" {
    var regional = try connectors.RegionalSettings.build(std.testing.allocator, config(), .{
        .location = "europe-west1",
        .egress_mode = .private_ip,
        .kms_key_name = .{ .value = "projects/integration-prod/locations/europe-west1/keyRings/connectors/cryptoKeys/runtime" },
    });
    defer regional.deinit(std.testing.allocator);

    var zone = try connectors.ManagedZone.build(std.testing.allocator, config(), .{
        .name = "crm-internal",
        .target_project = "network-host",
        .target_vpc = "shared-services",
        .dns = "crm.internal.",
    });
    defer zone.deinit(std.testing.allocator);

    var endpoint = try connectors.EndpointAttachment.build(std.testing.allocator, config(), .{
        .name = "crm-psc",
        .location = "europe-west1",
        .service_attachment = .{ .value = "projects/vendor/regions/europe-west1/serviceAttachments/crm" },
        .endpoint_global_access = true,
    });
    defer endpoint.deinit(std.testing.allocator);

    var connection = try connectors.Connection.build(std.testing.allocator, config(), .{
        .name = "crm",
        .location = "europe-west1",
        .connector_version = "projects/integration-prod/locations/global/providers/salesforce/connectors/salesforce/versions/1",
        .service_account_email = "connectors-runtime@integration-prod.iam.gserviceaccount.com",
        .authentication = .{ .user_password = .{
            .username = "ziac-runtime",
            .password_secret_version = .{ .value = "projects/integration-prod/secrets/crm-password/versions/3" },
        } },
        .config_variables = &.{
            .{ .key = "instance", .value = .{ .string = "production" } },
            .{ .key = "api_token", .value = .{ .secret_version = .{ .value = "projects/integration-prod/secrets/crm-token/versions/5" } } },
        },
        .node_config = .{ .min_nodes = 1, .max_nodes = 3 },
    });
    defer connection.deinit(std.testing.allocator);

    var subscription = try connectors.EventSubscription.build(std.testing.allocator, config(), .{
        .name = "account-updated",
        .location = "europe-west1",
        .connection = connection.name,
        .event_type_id = "AccountUpdated",
        .destination = .{ .pubsub = .{ .project_id = "integration-prod", .topic_id = "crm-events" } },
        .filter = "data.region == 'eu'",
    });
    defer subscription.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.connectors.RegionalSettings.europe-west1", regional.node.id);
    try std.testing.expectEqualStrings("gcp.connectors.ManagedZone.global.crm-internal", zone.node.id);
    try std.testing.expectEqualStrings("gcp.connectors.EndpointAttachment.europe-west1.crm-psc", endpoint.node.id);
    try std.testing.expectEqualStrings("gcp.connectors.Connection.europe-west1.crm", connection.node.id);
    try std.testing.expectEqualStrings("gcp.connectors.EventSubscription.europe-west1.crm.account-updated", subscription.node.id);
    try std.testing.expectEqual(@as(usize, 1), countOutputRefs(subscription.node.inputs));
}

test "Integration Connectors rejects inline secrets invalid versions and unsafe destinations" {
    try std.testing.expectError(error.InvalidSecretReference, connectors.Connection.build(std.testing.allocator, config(), .{
        .name = "inline-secret",
        .location = "europe-west1",
        .connector_version = "projects/integration-prod/locations/global/providers/salesforce/connectors/salesforce/versions/1",
        .config_variables = &.{.{ .key = "password", .value = .{ .string = "plain-text-password" } }},
    }));
    try std.testing.expectError(error.InvalidConnectorVersion, connectors.Connection.build(std.testing.allocator, config(), .{
        .name = "bad-version",
        .location = "europe-west1",
        .connector_version = "salesforce/latest",
    }));
    try std.testing.expectError(error.InvalidNodeConfig, connectors.Connection.build(std.testing.allocator, config(), .{
        .name = "bad-nodes",
        .location = "europe-west1",
        .connector_version = "projects/integration-prod/locations/global/providers/salesforce/connectors/salesforce/versions/1",
        .node_config = .{ .min_nodes = 4, .max_nodes = 2 },
    }));
    try std.testing.expectError(error.InvalidDestination, connectors.EventSubscription.build(std.testing.allocator, config(), .{
        .name = "bad-endpoint",
        .location = "europe-west1",
        .connection = .{ .value = "projects/integration-prod/locations/europe-west1/connections/crm" },
        .event_type_id = "AccountUpdated",
        .destination = .{ .https = .{ .uri = "http://example.com/events" } },
    }));
}

test "Connection IAM is additive and scoped to the connection" {
    var member = try connectors.ConnectionIamMember.build(std.testing.allocator, config(), .{
        .location = "europe-west1",
        .connection = .{ .value = "projects/integration-prod/locations/europe-west1/connections/crm" },
        .role = "roles/connectors.invoker",
        .member = "serviceAccount:agent@integration-prod.iam.gserviceaccount.com",
    });
    defer member.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("gcp.connectors.ConnectionIamMember.europe-west1.crm.roles-connectors-invoker-serviceaccount-agent-integration-prod-iam-gserviceaccount-com", member.node.id);
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "integration-prod", .primary_region = "europe-west1", .service_regions = &.{"europe-west1"} };
}

fn countOutputRefs(input: ziac.value.Value) usize {
    return switch (input) {
        .output_ref => 1,
        .list => |items| blk: {
            var count: usize = 0;
            for (items) |item| count += countOutputRefs(item);
            break :blk count;
        },
        .object => |fields| blk: {
            var count: usize = 0;
            for (fields) |field| count += countOutputRefs(field.value);
            break :blk count;
        },
        else => 0,
    };
}
