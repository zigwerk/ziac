const std = @import("std");
const ziac = @import("ziac");

test "ZigBuildPipeline composes source private execution trigger and protected artifacts" {
    const cleanup = [_]ziac.gcp.build_delivery.artifact.CleanupPolicy{
        .{ .name = "keep-releases", .rule = .{ .keep_most_recent = .{ .count = 20 } } },
    };
    var pipeline = try ziac.gcp.ZigBuildPipeline.build(std.testing.allocator, config(), .{
        .name = "api",
        .location = "europe-west1",
        .connection = .{ .github = .{ .oauth_token_secret_version = "projects/ziac-dev/secrets/github/versions/1", .app_installation_id = "123" } },
        .remote_uri = "https://github.com/acme/api.git",
        .filename = "platform/cloudbuild.yaml",
        .private_pool = .{ .network = .{ .peered = .{ .network = "projects/123/global/networks/build" } } },
        .cleanup_policies = &cleanup,
    });
    defer pipeline.deinit();

    try std.testing.expectEqual(@as(usize, 5), pipeline.graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 4), pipeline.graph.dependencies.items.len);
    try std.testing.expect(hasType(&pipeline.graph, "gcp.cloudbuild.Connection"));
    try std.testing.expect(hasType(&pipeline.graph, "gcp.cloudbuild.Repository"));
    try std.testing.expect(hasType(&pipeline.graph, "gcp.cloudbuild.WorkerPool"));
    try std.testing.expect(hasType(&pipeline.graph, "gcp.cloudbuild.Trigger"));
    try std.testing.expect(hasType(&pipeline.graph, "gcp.artifact.Repository"));
    try std.testing.expect(pipeline.worker_pool != null);
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
}

fn hasType(graph: *const ziac.ResourceGraph, type_name: []const u8) bool {
    for (graph.resources.items) |node| if (std.mem.eql(u8, node.type_name, type_name)) return true;
    return false;
}
