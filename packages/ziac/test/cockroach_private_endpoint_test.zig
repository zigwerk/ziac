const std = @import("std");
const ziac = @import("ziac");

const private_endpoint = ziac.cockroach.private_endpoint;

test "Cockroach private endpoint resources retain typed cross-provider inputs" {
    const cluster_id = ziac.PublicOutput([]const u8).fromResource("cockroach.Cluster.ziac-prod", "cluster_id");
    var region = try private_endpoint.ClusterRegion.build(std.testing.allocator, .{}, .{
        .name = "api-db",
        .cluster_id = cluster_id,
        .region = "europe-west1",
    });
    defer region.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("cockroach.ClusterRegion.api-db.europe-west1", region.node.id);
    try std.testing.expect(region.node.lifecycle.retain_on_delete);
    try std.testing.expect(inputValue(region.node, "cluster_id") == .output_ref);
    try std.testing.expectEqualStrings("private_endpoint_dns", region.private_endpoint_dns.resource_ref.field);

    var service = try private_endpoint.PrivateEndpointService.build(std.testing.allocator, .{}, .{
        .name = "api-db",
        .cluster_id = cluster_id,
        .plan = .advanced,
        .region = "europe-west1",
    });
    defer service.deinit(std.testing.allocator);
    try std.testing.expect(service.node.lifecycle.retain_on_delete);
    try std.testing.expectEqualStrings("ADVANCED", inputValue(service.node, "plan").string);
    try std.testing.expectEqualStrings("service_attachment", service.service_attachment.resource_ref.field);

    const endpoint_id = ziac.PublicOutput([]const u8).fromResource(
        "gcp.compute.PscEndpoint.api-db.europe-west1",
        "psc_connection_id",
    );
    var connection = try private_endpoint.PrivateEndpointConnection.build(std.testing.allocator, .{}, .{
        .name = "api-db",
        .cluster_id = cluster_id,
        .endpoint_id = endpoint_id,
        .endpoint_service_id = service.endpoint_service_id,
        .region = "europe-west1",
    });
    defer connection.deinit(std.testing.allocator);
    try std.testing.expect(!connection.node.lifecycle.retain_on_delete);
    try std.testing.expect(inputValue(connection.node, "endpoint_id") == .output_ref);
    try std.testing.expect(inputValue(connection.node, "endpoint_service_id") == .output_ref);
    try std.testing.expectEqualStrings("status", connection.status.resource_ref.field);

    const json = try connection.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        "{\"cluster_id\":{\"$output\":{\"field\":\"cluster_id\",\"resource\":\"cockroach.Cluster.ziac-prod\"}},\"endpoint_id\":{\"$output\":{\"field\":\"psc_connection_id\",\"resource\":\"gcp.compute.PscEndpoint.api-db.europe-west1\"}},\"endpoint_service_id\":{\"$output\":{\"field\":\"endpoint_service_id\",\"resource\":\"cockroach.PrivateEndpointService.api-db.europe-west1\"}},\"region\":\"europe-west1\"}",
        json,
    );
}

test "Cockroach private endpoint resources validate known identities" {
    try std.testing.expectError(error.MissingName, private_endpoint.ClusterRegion.build(std.testing.allocator, .{}, .{
        .name = "",
        .cluster_id = ziac.PublicOutput([]const u8).known("cluster-1"),
        .region = "europe-west1",
    }));
    try std.testing.expectError(error.InvalidClusterId, private_endpoint.PrivateEndpointService.build(std.testing.allocator, .{}, .{
        .name = "api-db",
        .cluster_id = ziac.PublicOutput([]const u8).known("cluster-1/services"),
        .plan = .standard,
        .region = "europe-west1",
    }));
    try std.testing.expectError(error.InvalidRegion, private_endpoint.PrivateEndpointConnection.build(std.testing.allocator, .{}, .{
        .name = "api-db",
        .cluster_id = ziac.PublicOutput([]const u8).known("cluster-1"),
        .endpoint_id = ziac.PublicOutput([]const u8).known("1234"),
        .endpoint_service_id = ziac.PublicOutput([]const u8).known("service-1"),
        .region = "Europe-west1",
    }));
    try std.testing.expectError(error.InvalidEndpointId, private_endpoint.PrivateEndpointConnection.build(std.testing.allocator, .{}, .{
        .name = "api-db",
        .cluster_id = ziac.PublicOutput([]const u8).known("cluster-1"),
        .endpoint_id = ziac.PublicOutput([]const u8).known("not-numeric"),
        .endpoint_service_id = ziac.PublicOutput([]const u8).known("service-1"),
        .region = "europe-west1",
    }));
}

fn inputValue(node: ziac.ResourceNode, name: []const u8) ziac.value.Value {
    for (node.inputs.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    unreachable;
}
