const std = @import("std");
const ziac = @import("ziac");

const image = "europe-west1-docker.pkg.dev/example-project/apps/platform@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

fn build(allocator: std.mem.Allocator) !ziac.gcp.ApplicationPlatform {
    return ziac.gcp.ApplicationPlatform.build(allocator, .{
        .project_id = "example-project",
        .primary_region = "europe-west1",
    }, .{
        .name = "platform",
        .project_number = "123456789012",
        .image = image,
        .service_origin = "https://platform-api.example.run.app",
        .bucket_name = "example-project-platform-uploads",
        .location = "EU",
        .allowed_persistence_regions = &.{ "europe-west1", "europe-west4" },
        .cors_origins = &.{"https://app.example.com"},
    });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var platform = try build(allocator);
    defer platform.deinit();
    var requirements = try ziac.gcp.intelligence.synthesizeGraph(allocator, &platform.graph);
    defer requirements.deinit(allocator);
    std.debug.print("application platform: {d} resources, {d} APIs\n", .{
        platform.graph.resources.items.len,
        requirements.apis.len,
    });
}

test "application platform example compiles a private asynchronous backend" {
    var platform = try build(std.testing.allocator);
    defer platform.deinit();
    try platform.graph.validateAcyclic();
    try std.testing.expect(platform.graph.resources.items.len > 20);
}
