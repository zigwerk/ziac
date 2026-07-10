const std = @import("std");
const ziac = @import("ziac");

test "Cockroach authorized network binds only a reserved static address as SQL /32" {
    const address = ziac.PublicOutput([]const u8).fromResource(
        "gcp.compute.RegionalAddress.europe-west1.api-egress",
        "address",
    );
    var rule = try ziac.cockroach.authorized_network.AuthorizedNetwork.build(std.testing.allocator, .{}, .{
        .name = "api-europe-west1",
        .cluster_id = "cluster-1",
        .ip_address = address,
    });
    defer rule.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("cockroach.AuthorizedNetwork.cluster-1.api-europe-west1", rule.node.id);
    try std.testing.expect(inputValue(rule.node, "ip_address") == .output_ref);
    try std.testing.expectEqual(@as(i64, 32), inputValue(rule.node, "cidr_mask").integer);
    try std.testing.expect(inputValue(rule.node, "sql").boolean);
    try std.testing.expect(!inputValue(rule.node, "ui").boolean);
}

test "Cockroach production authorized networks reject unrestricted CIDRs" {
    try std.testing.expectError(error.UnrestrictedCidr, ziac.cockroach.authorized_network.AuthorizedNetwork.build(std.testing.allocator, .{}, .{
        .name = "unsafe",
        .cluster_id = "cluster-1",
        .ip_address = ziac.PublicOutput([]const u8).known("0.0.0.0"),
        .cidr_mask = 0,
        .production = true,
    }));
}

fn inputValue(node: ziac.ResourceNode, name: []const u8) ziac.value.Value {
    for (node.inputs.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    unreachable;
}
