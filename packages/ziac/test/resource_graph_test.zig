const std = @import("std");
const ziac = @import("ziac");

test "resource graph registers resources and dependencies" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();

    try graph.addResource(.{
        .id = "gcp.run.Service.api",
        .type_name = "gcp.run.Service",
        .logical_id = "api",
    });
    try graph.addResource(.{
        .id = "gcp.loadbalancing.BackendService.api",
        .type_name = "gcp.loadbalancing.BackendService",
        .logical_id = "api-backend",
    });
    try graph.addDependency("gcp.loadbalancing.BackendService.api", "gcp.run.Service.api");

    try std.testing.expectEqual(@as(usize, 2), graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 1), graph.dependencies.items.len);
    try graph.validateAcyclic();
}

test "resource graph rejects duplicate resource ids" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();

    try graph.addResource(.{
        .id = "gcp.run.Service.api",
        .type_name = "gcp.run.Service",
        .logical_id = "api",
    });
    try std.testing.expectError(error.DuplicateResource, graph.addResource(.{
        .id = "gcp.run.Service.api",
        .type_name = "gcp.run.Service",
        .logical_id = "api-copy",
    }));
}

test "resource graph detects a dependency cycle" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();

    try graph.addResource(.{ .id = "a", .type_name = "test.A", .logical_id = "a" });
    try graph.addResource(.{ .id = "b", .type_name = "test.B", .logical_id = "b" });
    try graph.addDependency("a", "b");
    try graph.addDependency("b", "a");

    try std.testing.expectError(error.DependencyCycle, graph.validateAcyclic());
}
