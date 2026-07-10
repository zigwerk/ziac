const std = @import("std");
const ziac = @import("ziac");

pub fn buildStandardCluster(allocator: std.mem.Allocator) !ziac.cockroach.cluster.Cluster {
    return ziac.cockroach.cluster.Cluster.build(allocator, .{}, .{
        .name = "ziac-standard",
        .plan = .{ .standard = .{
            .regions = &.{
                .{ .name = "europe-west1", .primary = true },
                .{ .name = "us-central1" },
            },
            .provisioned_virtual_cpus = 4,
        } },
    });
}

pub fn main() !void {
    var cluster = try buildStandardCluster(std.heap.page_allocator);
    defer cluster.deinit(std.heap.page_allocator);
    std.debug.print("managed cluster resource: {s}\n", .{cluster.node.id});
}

test "managed Cockroach cluster example is protected and typed" {
    var cluster = try buildStandardCluster(std.testing.allocator);
    defer cluster.deinit(std.testing.allocator);
    try std.testing.expect(cluster.node.lifecycle.protect);
    try std.testing.expect(cluster.cluster_id == .resource_ref);
    try std.testing.expect(cluster.delete_protection == .resource_ref);
}
