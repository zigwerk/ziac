const std = @import("std");
const ziac = @import("ziac");

const config = ziac.gcp.config.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
};

test "private Cloud DNS zone and record retain output-backed names" {
    const private_dns = ziac.PublicOutput([]const u8).fromResource(
        "cockroach.ClusterRegion.api-db.europe-west1",
        "private_endpoint_dns",
    );
    const network = ziac.PublicOutput([]const u8).fromResource("gcp.compute.Network.api-db", "self_link");
    var zone = try ziac.gcp.dns.ManagedZone.build(std.testing.allocator, config, .{
        .name = "api-db-eu",
        .dns_name = private_dns,
        .network = network,
    });
    defer zone.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("gcp.dns.ManagedZone.api-db-eu", zone.node.id);
    try std.testing.expect(inputValue(zone.node, "dns_name") == .output_ref);
    try std.testing.expect(inputValue(zone.node, "network") == .output_ref);
    try std.testing.expectEqualStrings("PRIVATE", inputValue(zone.node, "visibility").string);

    var record = try ziac.gcp.dns.RecordSet.build(std.testing.allocator, config, .{
        .zone = "api-db-eu",
        .name_output = private_dns,
        .logical_name = "apex-europe-west1",
        .record_type = .a,
        .ttl = 60,
        .rrdata_outputs = &.{ziac.PublicOutput([]const u8).fromResource(
            "gcp.compute.PscEndpoint.europe-west1.api-db-eu",
            "ip_address",
        )},
    });
    defer record.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "gcp.dns.RecordSet.api-db-eu.A.apex-europe-west1",
        record.node.id,
    );
    try std.testing.expect(inputValue(record.node, "name") == .output_ref);
    try std.testing.expect(inputValue(record.node, "rrdatas").list[0] == .output_ref);
}

test "private Cloud DNS known network and name inputs are validated" {
    try std.testing.expectError(error.InvalidNetwork, ziac.gcp.dns.ManagedZone.build(std.testing.allocator, config, .{
        .name = "api-db-eu",
        .dns_name = ziac.PublicOutput([]const u8).known("private.eu.example"),
        .network = ziac.PublicOutput([]const u8).known("projects/other/global/networks/api-db"),
    }));
    try std.testing.expectError(error.InvalidDnsName, ziac.gcp.dns.ManagedZone.build(std.testing.allocator, config, .{
        .name = "api-db-eu",
        .dns_name = ziac.PublicOutput([]const u8).known("not a hostname"),
        .network = ziac.PublicOutput([]const u8).known("projects/ziac-dev/global/networks/api-db"),
    }));
    try std.testing.expectError(error.InvalidRecordName, ziac.gcp.dns.RecordSet.build(std.testing.allocator, config, .{
        .zone = "api-db-eu",
        .name_output = ziac.PublicOutput([]const u8).known("private.eu.example"),
        .record_type = .a,
        .rrdatas = &.{"10.42.0.2"},
    }));
}

fn inputValue(node: ziac.ResourceNode, name: []const u8) ziac.value.Value {
    for (node.inputs.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    unreachable;
}
