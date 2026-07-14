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
    var base = ziac.ResourceGraph.init(allocator);
    defer base.deinit();
    var origin = try ziac.gcp.storage.Bucket.build(allocator, provider, .{
        .name = "example-edge-assets",
        .location = "US",
        .public_access_prevention = .enforced,
    });
    defer origin.deinit(allocator);
    try base.addResource(origin.node);
    const origin_id = base.resources.items[0].id;

    var cdn = try ziac.gcp.ProtectedCdnBucket.build(allocator, provider, .{
        .base_graph = &base,
        .name = "assets",
        .bucket = ziac.gcp.storage.Bucket.Outputs.Name.fromResource(origin_id),
        .rules = &.{
            .{ .priority = 1000, .description = "block scanner range", .match = .{ .src_ip_ranges = &.{"203.0.113.0/24"} }, .action = .{ .deny = .forbidden } },
            .{ .priority = 2_147_483_647, .description = "default allow", .match = .{ .src_ip_ranges = &.{"*"} }, .action = .{ .allow = {} } },
        },
    });
    defer cdn.deinit();

    var certificates = try ziac.gcp.ManagedCertificateMap.build(allocator, provider, .{
        .base_graph = &cdn.graph,
        .name = "public",
        .domains = &.{ "api.example.com", "www.example.com" },
    });
    defer certificates.deinit();

    var graph = ziac.ResourceGraph.init(allocator);
    errdefer graph.deinit();
    try graph.appendGraph(&certificates.graph);
    var tls = try ziac.gcp.edge_security.SslPolicy.build(allocator, provider, .{ .name = "modern" });
    defer tls.deinit(allocator);
    try graph.addResource(tls.node);
    const tls_id = graph.resources.items[graph.resources.items.len - 1].id;
    var proxy = try ziac.gcp.edge_security.CertificateMapTargetHttpsProxy.build(allocator, provider, .{
        .name = "public-https",
        .url_map = ziac.PublicOutput([]const u8).known("projects/example-project/global/urlMaps/public"),
        .certificate_map = certificates.map,
        .ssl_policy = ziac.gcp.edge_security.SslPolicy.Outputs.SelfLink.fromResource(tls_id),
    });
    defer proxy.deinit(allocator);
    try graph.addResource(proxy.node);
    try graph.validateAcyclic();
    return .{ .graph = graph };
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var topology = try build(allocator);
    defer topology.deinit();
    var permissions = try ziac.gcp.intelligence.synthesizePermissionPlan(allocator, &topology.graph);
    defer permissions.deinit(allocator);
    std.debug.print("Secure edge: {d} resources, {d} causal edges, {d} exact permissions\n", .{
        topology.graph.resources.items.len,
        topology.graph.dependencies.items.len,
        permissions.deployer_permissions.len,
    });
}

test "secure-edge example compiles a protected CDN and managed certificate map" {
    var topology = try build(std.testing.allocator);
    defer topology.deinit();
    try topology.graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 12), topology.graph.resources.items.len);
}
