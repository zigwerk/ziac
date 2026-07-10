const std = @import("std");
const ziac = @import("ziac");

const regions = [_][]const u8{"europe-west1"};
const provider = ziac.gcp.config.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
    .service_regions = &regions,
    .network_tier = .premium,
};

test "GCP PSC address and endpoint retain typed regional wiring" {
    const subnet = ziac.PublicOutput([]const u8).fromResource(
        "gcp.compute.Subnetwork.europe-west1.api-db",
        "self_link",
    );
    var address = try ziac.gcp.psc.Address.build(std.testing.allocator, provider, .{
        .name = "api-db-eu",
        .region = "europe-west1",
        .subnetwork = subnet,
    });
    defer address.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("gcp.compute.PscAddress.europe-west1.api-db-eu", address.node.id);
    try std.testing.expectEqualStrings("address", address.address.resource_ref.field);
    try std.testing.expect(inputValue(address.node, "subnetwork") == .output_ref);
    try std.testing.expectEqualStrings("INTERNAL", inputValue(address.node, "address_type").string);
    try std.testing.expectEqualStrings("IPV4", inputValue(address.node, "ip_version").string);

    var endpoint = try ziac.gcp.psc.Endpoint.build(std.testing.allocator, provider, .{
        .name = "api-db-eu",
        .region = "europe-west1",
        .network = ziac.PublicOutput([]const u8).fromResource("gcp.compute.Network.api-db", "self_link"),
        .address = address.address,
        .address_resource = address.self_link,
        .target = ziac.PublicOutput([]const u8).fromResource(
            "cockroach.PrivateEndpointService.api-db.europe-west1",
            "service_attachment",
        ),
    });
    defer endpoint.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("gcp.compute.PscEndpoint.europe-west1.api-db-eu", endpoint.node.id);
    try std.testing.expect(inputValue(endpoint.node, "network") == .output_ref);
    try std.testing.expect(inputValue(endpoint.node, "address") == .output_ref);
    try std.testing.expect(inputValue(endpoint.node, "address_resource") == .output_ref);
    try std.testing.expect(inputValue(endpoint.node, "target") == .output_ref);
    try std.testing.expect(inputValue(endpoint.node, "allow_psc_global_access").boolean);
    try std.testing.expect(inputValue(endpoint.node, "no_automate_dns_zone").boolean);
    try std.testing.expectEqualStrings("psc_connection_id", endpoint.psc_connection_id.resource_ref.field);
    try std.testing.expectEqualStrings("ip_address", endpoint.ip_address.resource_ref.field);
}

test "GCP PSC known inputs must match project and region" {
    try std.testing.expectError(error.InvalidSubnetwork, ziac.gcp.psc.Address.build(std.testing.allocator, provider, .{
        .name = "api-db-eu",
        .region = "europe-west1",
        .subnetwork = ziac.PublicOutput([]const u8).known(
            "projects/other-project/regions/europe-west1/subnetworks/api-db-eu",
        ),
    }));
    try std.testing.expectError(error.InvalidNetwork, ziac.gcp.psc.Endpoint.build(std.testing.allocator, provider, .{
        .name = "api-db-eu",
        .region = "europe-west1",
        .network = ziac.PublicOutput([]const u8).known("projects/other-project/global/networks/api-db"),
        .address = ziac.PublicOutput([]const u8).known("10.42.0.2"),
        .address_resource = ziac.PublicOutput([]const u8).known(
            "projects/ziac-dev/regions/europe-west1/addresses/api-db-eu",
        ),
        .target = ziac.PublicOutput([]const u8).known(
            "projects/crl-prod/regions/europe-west1/serviceAttachments/crdb-1",
        ),
    }));
    try std.testing.expectError(error.InvalidTarget, ziac.gcp.psc.Endpoint.build(std.testing.allocator, provider, .{
        .name = "api-db-eu",
        .region = "europe-west1",
        .network = ziac.PublicOutput([]const u8).known("projects/ziac-dev/global/networks/api-db"),
        .address = ziac.PublicOutput([]const u8).known("10.42.0.2"),
        .address_resource = ziac.PublicOutput([]const u8).known(
            "projects/ziac-dev/regions/europe-west1/addresses/api-db-eu",
        ),
        .target = ziac.PublicOutput([]const u8).known(
            "projects/crl-prod/regions/us-central1/serviceAttachments/crdb-1",
        ),
    }));
}

fn inputValue(node: ziac.ResourceNode, name: []const u8) ziac.value.Value {
    for (node.inputs.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    unreachable;
}
