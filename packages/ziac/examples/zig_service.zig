const std = @import("std");
const ziac = @import("ziac");

const regions = [_][]const u8{ "europe-west1", "us-central1" };
const Providers = ziac.stack.ProviderSet(.{ziac.resource.ProviderId.gcp});

const DeploymentContract = struct {
    release: ziac.binding.Value([]const u8),
};

const Bindings = struct {
    release: ziac.PublicOutput([]const u8),
};

const Service = ziac.gcp.global.ZigService(DeploymentContract, Bindings, Providers);

pub fn buildZigService(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
) !Service {
    return Service.build(allocator, .{
        .project_id = "example-project",
        .primary_region = regions[0],
        .service_regions = &regions,
        .network_tier = .premium,
    }, .{
        .source = .{ .io = io, .root = source_dir },
        .name = "api",
        .artifact_name = "ziac-sample-api",
        .regions = &regions,
        .domain = "api.example.com",
        .dns_zone = "example-com",
        .bindings = .{
            .release = .{ .value = "example" },
        },
    });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var source_dir = try std.Io.Dir.cwd().openDir(io, "examples/zig-service-app", .{ .iterate = true });
    defer source_dir.close(io);
    var service = try buildZigService(std.heap.page_allocator, io, source_dir);
    defer service.deinit();
    std.debug.print("{s}: {d} resources, image {s}\n", .{
        service.url.value,
        service.graph.resources.items.len,
        service.image_resource_id,
    });
}

test "ZigService example builds source into a globally routed graph" {
    var source_dir = try std.Io.Dir.cwd().openDir(std.testing.io, "examples/zig-service-app", .{ .iterate = true });
    defer source_dir.close(std.testing.io);
    var service = try buildZigService(std.testing.allocator, std.testing.io, source_dir);
    defer service.deinit();

    try std.testing.expectEqualStrings("https://api.example.com", service.url.value);
    try std.testing.expect(service.image_ref == .resource_ref);
    try std.testing.expect(service.graph.resources.items.len > regions.len);
    try service.graph.validateAcyclic();
}
