const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{
    .project_id = "example-project",
    .primary_region = "europe-west1",
};

fn build(allocator: std.mem.Allocator) !ziac.gcp.ZigBuildPipeline {
    return ziac.gcp.ZigBuildPipeline.build(allocator, provider, .{
        .name = "global-api",
        .location = "europe-west1",
        .connection = .{ .github = .{
            .oauth_token_secret_version = "projects/example-project/secrets/github-oauth/versions/1",
            .app_installation_id = "12345678",
        } },
        .remote_uri = "https://github.com/example/global-api.git",
        .event = .{ .push = .{ .branch = "^main$" } },
        .filename = "platform/cloudbuild.yaml",
        .private_pool = .{ .network = .{ .peered = .{
            .network = "projects/123456789/global/networks/build",
            .ip_range = "10.40.0.0/24",
            .egress = .no_public,
        } } },
        .cleanup_policies = &.{.{
            .name = "keep-releases",
            .rule = .{ .keep_most_recent = .{ .package_prefixes = &.{"global-api"}, .count = 20 } },
        }},
    });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var pipeline = try build(allocator);
    defer pipeline.deinit();
    var permissions = try ziac.gcp.intelligence.synthesizePermissionPlan(allocator, &pipeline.graph);
    defer permissions.deinit(allocator);
    std.debug.print("Build delivery: {d} resources, {d} causal edges, {d} exact permissions\n", .{
        pipeline.graph.resources.items.len,
        pipeline.graph.dependencies.items.len,
        permissions.deployer_permissions.len,
    });
}

test "build delivery example compiles source execution and artifact topology" {
    var pipeline = try build(std.testing.allocator);
    defer pipeline.deinit();
    try pipeline.graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 5), pipeline.graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 4), pipeline.graph.dependencies.items.len);
}
