const std = @import("std");
const ziac = @import("ziac");

const regions = [_][]const u8{ "europe-west1", "us-central1" };

pub fn buildGlobalService(allocator: std.mem.Allocator) !ziac.gcp.global.ContainerService {
    return ziac.gcp.global.ContainerService.build(allocator, .{
        .project_id = "example-project",
        .primary_region = regions[0],
        .service_regions = &regions,
        .network_tier = .premium,
        .service_account = "api@example-project.iam.gserviceaccount.com",
    }, .{
        .name = "api",
        .image = "europe-west1-docker.pkg.dev/example-project/apps/api@sha256:example",
        .regions = &regions,
        .domain = "api.example.com",
        .dns_zone = "example-com",
    });
}

pub fn main() !void {
    var component = try buildGlobalService(std.heap.page_allocator);
    defer component.deinit();
    std.debug.print("{s}: {d} resources, {d} dependencies\n", .{
        component.url.value,
        component.graph.resources.items.len,
        component.graph.dependencies.items.len,
    });
}

test "global ContainerService example builds the complete graph" {
    var component = try buildGlobalService(std.testing.allocator);
    defer component.deinit();
    try std.testing.expectEqualStrings("https://api.example.com", component.url.value);
    try std.testing.expectEqual(@as(usize, 14), component.graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 13), component.graph.dependencies.items.len);
}
