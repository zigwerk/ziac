const std = @import("std");
const ziac = @import("ziac");

fn addService(graph: *ziac.ResourceGraph, image: []const u8, lifecycle: ziac.resource.Lifecycle) !void {
    try graph.addResource(.{
        .id = "gcp.run.Service.europe-west1.api",
        .provider = .gcp,
        .type_name = "gcp.run.Service",
        .logical_id = "api",
        .inputs = .{ .object = &.{
            .{ .name = "image", .value = .{ .string = image } },
        } },
        .lifecycle = lifecycle,
    });
}

test "planner creates missing resources with a stable reason" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try addService(&graph, "example/api:v1", .{});
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();

    var plan = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer plan.deinit();

    try std.testing.expectEqual(@as(usize, 1), plan.operations.len);
    try std.testing.expectEqual(ziac.plan.OperationKind.create, plan.operations[0].kind);
    try std.testing.expectEqualStrings("resource is not in state", plan.operations[0].reasons[0]);
}

test "local planner noops matching desired hashes and updates changed hashes" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try addService(&graph, "example/api:v1", .{});
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();

    const matching_hash = std.fmt.bytesToHex(graph.resources.items[0].inputs_hash, .lower);
    try state.put(.{
        .resource_id = graph.resources.items[0].id,
        .provider = .gcp,
        .type_name = "gcp.run.Service",
        .logical_id = "api",
        .desired_hash = matching_hash[0..],
        .status = .created,
    });
    var noops = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer noops.deinit();
    try std.testing.expectEqual(ziac.plan.OperationKind.noop, noops.operations[0].kind);

    var changed_graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer changed_graph.deinit();
    try addService(&changed_graph, "example/api:v2", .{});
    var changes = try ziac.plan.buildPlan(std.testing.allocator, &changed_graph, &state);
    defer changes.deinit();
    try std.testing.expectEqual(ziac.plan.OperationKind.update, changes.operations[0].kind);
    try std.testing.expectEqualStrings("desired inputs changed", changes.operations[0].reasons[0]);
}

test "refreshed planner uses provider diff for noop update and replace" {
    var original = ziac.ResourceGraph.init(std.testing.allocator);
    defer original.deinit();
    try addService(&original, "example/api:v1", .{});
    var changed = ziac.ResourceGraph.init(std.testing.allocator);
    defer changed.deinit();
    try addService(&changed, "example/api:v2", .{});

    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    var created = try fake.provider().create(std.testing.allocator, original.resources.items[0]);
    defer created.deinit();
    var registry = ziac.provider.ProviderRegistry{};
    registry.register(.gcp, fake.provider());
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    const original_hash = std.fmt.bytesToHex(original.resources.items[0].inputs_hash, .lower);
    try state.put(.{
        .resource_id = original.resources.items[0].id,
        .provider = .gcp,
        .type_name = original.resources.items[0].type_name,
        .logical_id = original.resources.items[0].logical_id,
        .physical_id = "projects/example/non-deterministic/7",
        .desired_hash = original_hash[0..],
        .status = .created,
    });

    var noops = try ziac.plan.buildRefreshedPlan(std.testing.allocator, &original, &state, registry);
    defer noops.deinit();
    try std.testing.expectEqual(ziac.plan.OperationKind.noop, noops.operations[0].kind);
    try std.testing.expectEqualStrings("projects/example/non-deterministic/7", fake.last_read_physical_id.?);

    var updates = try ziac.plan.buildRefreshedPlan(std.testing.allocator, &changed, &state, registry);
    defer updates.deinit();
    try std.testing.expectEqual(ziac.plan.OperationKind.update, updates.operations[0].kind);

    fake.replace_changes = true;
    var replacements = try ziac.plan.buildRefreshedPlan(std.testing.allocator, &changed, &state, registry);
    defer replacements.deinit();
    try std.testing.expectEqual(ziac.plan.OperationKind.replace, replacements.operations[0].kind);
}

test "refreshed planner detects remote drift independently of prior state" {
    var desired = ziac.ResourceGraph.init(std.testing.allocator);
    defer desired.deinit();
    try addService(&desired, "example/api:v1", .{});
    var drifted = ziac.ResourceGraph.init(std.testing.allocator);
    defer drifted.deinit();
    try addService(&drifted, "example/api:manual-change", .{});

    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    const provider = fake.provider();
    var created = try provider.create(std.testing.allocator, desired.resources.items[0]);
    defer created.deinit();
    var drift_result = try provider.update(std.testing.allocator, drifted.resources.items[0], &created);
    defer drift_result.deinit();

    var registry = ziac.provider.ProviderRegistry{};
    registry.register(.gcp, provider);
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    var plan = try ziac.plan.buildRefreshedPlan(std.testing.allocator, &desired, &state, registry);
    defer plan.deinit();

    try std.testing.expectEqual(ziac.plan.OperationKind.update, plan.operations[0].kind);
    try std.testing.expectEqualStrings("desired inputs changed", plan.operations[0].reasons[0]);
}

test "planner deletes resources removed from desired graph" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    try state.put(.{
        .resource_id = "gcp.run.Service.europe-west1.old",
        .provider = .gcp,
        .type_name = "gcp.run.Service",
        .logical_id = "old",
        .physical_id = "projects/example/services/old",
        .desired_hash = "old-hash",
        .status = .created,
    });

    var plan = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), plan.operations.len);
    try std.testing.expectEqual(ziac.plan.OperationKind.delete, plan.operations[0].kind);
    try std.testing.expectEqualStrings("resource was removed from desired graph", plan.operations[0].reasons[0]);
}

test "planner rejects protected deletes and replacements" {
    var empty = ziac.ResourceGraph.init(std.testing.allocator);
    defer empty.deinit();
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    try state.put(.{
        .resource_id = "gcp.run.Service.europe-west1.api",
        .provider = .gcp,
        .type_name = "gcp.run.Service",
        .logical_id = "api",
        .desired_hash = "hash",
        .status = .created,
        .protect = true,
    });
    try std.testing.expectError(
        error.ProtectedResource,
        ziac.plan.buildPlan(std.testing.allocator, &empty, &state),
    );

    var original = ziac.ResourceGraph.init(std.testing.allocator);
    defer original.deinit();
    try addService(&original, "example/api:v1", .{});
    var protected_change = ziac.ResourceGraph.init(std.testing.allocator);
    defer protected_change.deinit();
    try addService(&protected_change, "example/api:v2", .{ .protect = true });
    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    fake.replace_changes = true;
    var created = try fake.provider().create(std.testing.allocator, original.resources.items[0]);
    defer created.deinit();
    var registry = ziac.provider.ProviderRegistry{};
    registry.register(.gcp, fake.provider());
    try std.testing.expectError(
        error.ProtectedResource,
        ziac.plan.buildRefreshedPlan(std.testing.allocator, &protected_change, &state, registry),
    );
}

test "destroy planner deletes managed resources from state" {
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    try state.put(.{
        .resource_id = "gcp.run.Service.api",
        .provider = .gcp,
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
