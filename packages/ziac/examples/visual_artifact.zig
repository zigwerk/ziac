const std = @import("std");
const ziac = @import("ziac");

const regions = [_][]const u8{ "europe-west1", "us-central1", "asia-northeast1" };
const google = ziac.gcp.ProviderConfig{
    .project_id = "ziac-visual-demo",
    .primary_region = regions[0],
    .service_regions = &regions,
    .network_tier = .premium,
    .service_account = "api@ziac-visual-demo.iam.gserviceaccount.com",
};

pub fn buildArtifact(allocator: std.mem.Allocator) !ziac.visual_artifact.SerializedArtifact {
    var cluster = try ziac.cockroach.cluster.Cluster.build(allocator, .{}, .{
        .name = "global-data",
        .plan = .{ .standard = .{
            .regions = &.{
                .{ .name = regions[0], .primary = true },
                .{ .name = regions[1] },
                .{ .name = regions[2] },
            },
            .provisioned_virtual_cpus = 6,
        } },
    });
    defer cluster.deinit(allocator);

    var foundation = ziac.ResourceGraph.init(allocator);
    defer foundation.deinit();
    try foundation.addResource(cluster.node);

    var service = try ziac.gcp.global.ContainerService.build(allocator, google, .{
        .base_graph = &foundation,
        .name = "api",
        .image = "europe-west1-docker.pkg.dev/ziac-visual-demo/apps/api@sha256:1111111111111111111111111111111111111111111111111111111111111111",
        .regions = &regions,
        .domain = "api.example.com",
        .dns_zone = "example-com",
        .health_mode = .production,
        .min_instances = 1,
        .startup_probe = .{ .path = "/startup", .initial_delay_seconds = 1 },
        .liveness_probe = .{ .path = "/health", .initial_delay_seconds = 2 },
        .readiness_probe = .{ .path = "/ready", .initial_delay_seconds = 2 },
        .rollout = .{ .strategy = .canary_then_fleet, .canary_region = regions[0] },
    });
    defer service.deinit();
    for (service.graph.resources.items) |node| {
        if (std.mem.eql(u8, node.type_name, "gcp.run.Service")) {
            try service.graph.addDependency(node.id, cluster.node.id);
        }
    }

    var state = ziac.InMemoryStateStore.init(allocator);
    defer state.deinit();
    state.setLineage("global-api/prod");
    var planned = try ziac.plan.buildPlan(allocator, &service.graph, &state);
    defer planned.deinit();
    return ziac.visual_artifact.serializeAlloc(allocator, &service.graph, &planned, .{
        .stack = "global-api",
        .stage = "prod",
        .created_at_millis = 1_783_728_000_000,
    });
}

pub fn main(init: std.process.Init) !void {
    var artifact = try buildArtifact(std.heap.page_allocator);
    defer artifact.deinit();
    try std.Io.File.stdout().writeStreamingAll(init.io, artifact.bytes);
}

test "visual artifact example contains global compute and database topology" {
    var artifact = try buildArtifact(std.testing.allocator);
    defer artifact.deinit();
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "gcp.run.Service") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "gcp.compute.GlobalForwardingRule") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "cockroach.Cluster") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"routes\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"from_resource\":\"gcp.compute.GlobalForwardingRule.api-https\"") != null);
}
