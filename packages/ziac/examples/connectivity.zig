const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{
    .project_id = "example-project",
    .primary_region = "europe-west1",
};

const Topology = struct {
    graph: ziac.ResourceGraph,
    fn deinit(self: *Topology) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

fn build(allocator: std.mem.Allocator) !Topology {
    var vpn = try ziac.gcp.HaVpnConnection.build(allocator, provider, .{
        .name = "office",
        .region = "europe-west1",
        .network = ziac.PublicOutput([]const u8).known("projects/example-project/global/networks/platform"),
        .local_asn = 64_520,
        .peer_asn = 64_530,
        .peer_gateway_ips = .{ "203.0.113.10", "203.0.113.11" },
        .interface_cidrs = .{ "169.254.10.1/30", "169.254.20.1/30" },
        .local_bgp_ips = .{ "169.254.10.1", "169.254.20.1" },
        .peer_bgp_ips = .{ "169.254.10.2", "169.254.20.2" },
        .shared_secrets = .{
            secret("projects/example-project/secrets/office-vpn-0"),
            secret("projects/example-project/secrets/office-vpn-1"),
        },
    });
    defer vpn.deinit();

    var mesh = try ziac.gcp.VpcConnectivityMesh.build(allocator, provider, .{
        .base_graph = &vpn.graph,
        .name = "global-mesh",
        .spokes = &.{
            .{
                .name = "platform",
                .location = "global",
                .link = .{ .vpc_network = ziac.PublicOutput([]const u8).known("projects/example-project/global/networks/platform") },
            },
            .{
                .name = "office",
                .location = "europe-west1",
                .link = .{ .vpn_tunnels = &vpn.tunnels },
            },
        },
    });
    defer mesh.deinit();

    const psc_subnets = [_]ziac.PublicOutput([]const u8){
        ziac.PublicOutput([]const u8).known("projects/example-project/regions/europe-west1/subnetworks/psc"),
    };
    var policy = try ziac.gcp.PrivateServiceConnectivityPolicy.build(allocator, provider, .{
        .base_graph = &mesh.graph,
        .name = "alloydb",
        .location = "europe-west1",
        .network = ziac.PublicOutput([]const u8).known("projects/example-project/global/networks/platform"),
        .service_class = "gcp-alloydb",
        .subnetworks = &psc_subnets,
    });
    defer policy.deinit();

    var graph = ziac.ResourceGraph.init(allocator);
    errdefer graph.deinit();
    try graph.appendGraph(&policy.graph);
    return .{ .graph = graph };
}

fn secret(resource_name: []const u8) ziac.SecretOutput(ziac.value.SecretReference) {
    return .known(.{ .provider = "gcp-secret-manager", .resource = resource_name, .version = "1" });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var topology = try build(allocator);
    defer topology.deinit();
    var permissions = try ziac.gcp.intelligence.synthesizePermissionPlan(allocator, &topology.graph);
    defer permissions.deinit(allocator);
    std.debug.print("Connectivity: {d} resources, {d} causal edges, {d} exact permissions\n", .{
        topology.graph.resources.items.len,
        topology.graph.dependencies.items.len,
        permissions.deployer_permissions.len,
    });
}

test "connectivity example compiles HA VPN NCC and PSC policy" {
    var topology = try build(std.testing.allocator);
    defer topology.deinit();
    try topology.graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 13), topology.graph.resources.items.len);
}
