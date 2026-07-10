const std = @import("std");
const ziac = @import("ziac");

test "planner creates missing resources" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();

    try graph.addResource(.{
        .id = "gcp.run.Service.api",
        .type_name = "gcp.run.Service",
        .logical_id = "api",
    });

    var plan = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer plan.deinit();

    try std.testing.expectEqual(@as(usize, 1), plan.operations.len);
    try std.testing.expectEqual(ziac.plan.OperationKind.create, plan.operations[0].kind);
}

test "planner noops resources with matching state" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();

    try graph.addResource(.{
        .id = "gcp.run.Service.api",
        .type_name = "gcp.run.Service",
        .logical_id = "api",
    });
    try state.put(.{
        .resource_id = "gcp.run.Service.api",
        .type_name = "gcp.run.Service",
        .logical_id = "api",
        .desired_hash = "v1",
        .status = .created,
    });

    var plan = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer plan.deinit();

    try std.testing.expectEqual(@as(usize, 1), plan.operations.len);
    try std.testing.expectEqual(ziac.plan.OperationKind.noop, plan.operations[0].kind);
}

test "destroy planner deletes managed resources from state" {
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();

    try state.put(.{
        .resource_id = "gcp.run.Service.api",
        .type_name = "gcp.run.Service",
        .logical_id = "api",
        .desired_hash = "v1",
        .status = .created,
    });

    var destroy_plan = try ziac.plan.buildDestroyPlan(std.testing.allocator, &state);
    defer destroy_plan.deinit();

    try std.testing.expectEqual(@as(usize, 1), destroy_plan.operations.len);
    try std.testing.expectEqual(ziac.plan.OperationKind.delete, destroy_plan.operations[0].kind);
    try std.testing.expectEqualStrings("gcp.run.Service.api", destroy_plan.operations[0].resource.id);
}
