const std = @import("std");
const ziac = @import("ziac");

const config = ziac.gcp.config.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
};

test "GCP static egress resources wire typed network subnet and address outputs" {
    var network = try ziac.gcp.network.Network.build(std.testing.allocator, config, .{ .name = "api-egress" });
    defer network.deinit(std.testing.allocator);
    var subnet = try ziac.gcp.network.Subnetwork.build(std.testing.allocator, config, .{
        .name = "api-europe-west1",
        .region = "europe-west1",
        .ip_cidr_range = "10.42.0.0/24",
        .network = network.self_link,
    });
    defer subnet.deinit(std.testing.allocator);
    var router = try ziac.gcp.network.Router.build(std.testing.allocator, config, .{
        .name = "api-europe-west1",
        .region = "europe-west1",
        .network = network.self_link,
    });
    defer router.deinit(std.testing.allocator);
    var address = try ziac.gcp.network.RegionalAddress.build(std.testing.allocator, config, .{
        .name = "api-europe-west1",
        .region = "europe-west1",
    });
    defer address.deinit(std.testing.allocator);
    var nat = try ziac.gcp.network.RouterNat.build(std.testing.allocator, config, .{
        .name = "api-europe-west1",
        .region = "europe-west1",
        .router_name = "api-europe-west1",
        .router = router.self_link,
        .subnetwork = subnet.self_link,
        .nat_ip = address.self_link,
    });
    defer nat.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.compute.Network.api-egress", network.node.id);
    try std.testing.expectEqualStrings("gcp.compute.Subnetwork.europe-west1.api-europe-west1", subnet.node.id);
    try std.testing.expectEqualStrings("gcp.compute.RouterNat.europe-west1.api-europe-west1.api-europe-west1", nat.node.id);
    try std.testing.expect(inputValue(subnet.node, "network") == .output_ref);
    try std.testing.expect(inputValue(nat.node, "router") == .output_ref);
    try std.testing.expect(inputValue(nat.node, "subnetwork") == .output_ref);
    try std.testing.expect(inputValue(nat.node, "nat_ip") == .output_ref);
    try std.testing.expectEqual(@as(i64, 64), inputValue(nat.node, "min_ports_per_vm").integer);

    const direct = ziac.gcp.cloud_run.DirectVpc{
        .network_output = network.self_link,
        .subnetwork_output = subnet.self_link,
        .egress = .all_traffic,
    };
    var service = try ziac.gcp.cloud_run.Service.build(std.testing.allocator, config, .{
        .name = "api",
        .image = "example/api@sha256:abc",
        .direct_vpc = direct,
    });
    defer service.deinit(std.testing.allocator);
    const vpc = inputValue(service.node, "vpc_access").object;
    try std.testing.expect(objectValue(vpc, "network") == .output_ref);
    try std.testing.expect(objectValue(vpc, "subnetwork") == .output_ref);
    try std.testing.expectEqualStrings("ALL_TRAFFIC", objectValue(vpc, "egress").string);
}

test "GCP static egress resources reject unsafe names CIDRs and NAT sizing" {
    const network = ziac.PublicOutput([]const u8).known("projects/ziac-dev/global/networks/api");
    try std.testing.expectError(error.InvalidCidr, ziac.gcp.network.Subnetwork.build(std.testing.allocator, config, .{
        .name = "api",
        .region = "europe-west1",
        .ip_cidr_range = "0.0.0.0/0",
        .network = network,
    }));
    try std.testing.expectError(error.InvalidMinPorts, ziac.gcp.network.RouterNat.build(std.testing.allocator, config, .{
        .name = "api",
        .region = "europe-west1",
        .router_name = "api",
        .router = ziac.PublicOutput([]const u8).known("projects/ziac-dev/regions/europe-west1/routers/api"),
        .subnetwork = ziac.PublicOutput([]const u8).known("projects/ziac-dev/regions/europe-west1/subnetworks/api"),
        .nat_ip = ziac.PublicOutput([]const u8).known("projects/ziac-dev/regions/europe-west1/addresses/api"),
        .min_ports_per_vm = 63,
    }));
}

fn inputValue(node: ziac.ResourceNode, name: []const u8) ziac.value.Value {
    return objectValue(node.inputs.object, name);
}

fn objectValue(fields: []const ziac.value.Field, name: []const u8) ziac.value.Value {
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    unreachable;
}
