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

test "resource graph clones and owns complete desired resources" {
    var source = try ziac.ResourceNode.initOwned(std.testing.allocator, .{
        .id = "gcp.run.Service.europe-west1.api",
        .provider = .gcp,
        .type_name = "gcp.run.Service",
        .schema_version = 1,
        .logical_id = "api",
        .inputs = .{ .object = &.{
            .{ .name = "image", .value = .{ .string = "example/api:v1" } },
            .{ .name = "port", .value = .{ .integer = 8080 } },
        } },
        .lifecycle = .{
            .protect = true,
            .ignore_changes = &.{"labels.generated"},
        },
    });

    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.addResource(source);
    source.deinit(std.testing.allocator);

    const stored = graph.resources.items[0];
    try std.testing.expectEqual(ziac.resource.ProviderId.gcp, stored.provider);
    try std.testing.expectEqual(@as(u32, 1), stored.schema_version);
    try std.testing.expect(stored.lifecycle.protect);
    try std.testing.expectEqualStrings("labels.generated", stored.lifecycle.ignore_changes[0]);

    const json = try stored.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("{\"image\":\"example/api:v1\",\"port\":8080}", json);

    const expected_hash = try stored.inputs.sha256(std.testing.allocator);
    try std.testing.expectEqual(expected_hash, stored.inputs_hash);
}

test "dependency edges use graph owned resource ids" {
    var dependency = try ziac.ResourceNode.initOwned(std.testing.allocator, .{
        .id = "dependency",
        .type_name = "test.Dependency",
        .logical_id = "dependency",
    });
    var consumer = try ziac.ResourceNode.initOwned(std.testing.allocator, .{
        .id = "consumer",
        .type_name = "test.Consumer",
        .logical_id = "consumer",
    });

    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.addResource(dependency);
    try graph.addResource(consumer);
    try graph.addDependency(consumer.id, dependency.id);
    dependency.deinit(std.testing.allocator);
    consumer.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(graph.resources.items[1].id, graph.dependencies.items[0].from);
    try std.testing.expectEqualStrings(graph.resources.items[0].id, graph.dependencies.items[0].to);
}
