const std = @import("std");
const ziac = @import("ziac");

fn fixture(
    graph: *ziac.ResourceGraph,
    state: *ziac.InMemoryStateStore,
) !void {
    try graph.addResource(.{
        .id = "service",
        .provider = .gcp,
        .type_name = "gcp.run.Service",
        .logical_id = "service",
    });
    state.setLineage("stack/dev");
}

fn providersFor(fake: *ziac.provider.FakeProvider) ziac.provider.ProviderRegistry {
    var providers = ziac.provider.ProviderRegistry{};
    providers.register(.gcp, fake.provider());
    return providers;
}

test "plan captures lineage serial and desired graph digest" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    try fixture(&graph, &state);

    var plan = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer plan.deinit();

    try std.testing.expectEqual(@as(u64, 0), plan.preconditions.state_serial);
    try std.testing.expectEqualSlices(u8, &state.metadata().lineage_hash, &plan.preconditions.lineage_hash);
    try std.testing.expect(!std.mem.allEqual(u8, &plan.preconditions.desired_graph_digest, 0));
}

test "executor rejects stale state serial before provider access" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    try fixture(&graph, &state);
    var plan = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer plan.deinit();
    try state.put(.{
        .resource_id = "other",
        .type_name = "test.Resource",
        .logical_id = "other",
        .desired_hash = "hash",
        .status = .created,
    });
    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();

    try std.testing.expectError(
        error.StalePlan,
        ziac.executor.executePlan(
            std.testing.allocator,
            &plan,
            &state,
            providersFor(&fake),
            .{},
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.operationAttempts());
}

test "executor rejects lineage mismatch before provider access" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    try fixture(&graph, &state);
    var plan = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer plan.deinit();
    state.setLineage("another/dev");
    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();

    try std.testing.expectError(
        error.PlanLineageMismatch,
        ziac.executor.executePlan(
            std.testing.allocator,
            &plan,
            &state,
            providersFor(&fake),
            .{},
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.operationAttempts());
}

test "executor rejects a plan whose desired operation data was modified" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    try fixture(&graph, &state);
    var plan = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer plan.deinit();
    plan.operations[0].resource.inputs_hash = [_]u8{0xaa} ** 32;
    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();

    try std.testing.expectError(
        error.PlanIntegrityMismatch,
        ziac.executor.executePlan(
            std.testing.allocator,
            &plan,
            &state,
            providersFor(&fake),
            .{},
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.operationAttempts());
}

test "desired graph digest is independent of resource and edge insertion order" {
    var first = ziac.ResourceGraph.init(std.testing.allocator);
    defer first.deinit();
    try first.addResource(.{ .id = "consumer", .type_name = "test.Consumer", .logical_id = "consumer" });
    try first.addResource(.{ .id = "alpha", .type_name = "test.Dependency", .logical_id = "alpha" });
    try first.addResource(.{ .id = "bravo", .type_name = "test.Dependency", .logical_id = "bravo" });
    try first.addDependency("consumer", "bravo");
    try first.addDependency("consumer", "alpha");

    var second = ziac.ResourceGraph.init(std.testing.allocator);
    defer second.deinit();
    try second.addResource(.{ .id = "bravo", .type_name = "test.Dependency", .logical_id = "bravo" });
    try second.addResource(.{ .id = "alpha", .type_name = "test.Dependency", .logical_id = "alpha" });
    try second.addResource(.{ .id = "consumer", .type_name = "test.Consumer", .logical_id = "consumer" });
    try second.addDependency("consumer", "alpha");
    try second.addDependency("consumer", "bravo");

    var first_state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer first_state.deinit();
    var second_state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer second_state.deinit();
    var first_plan = try ziac.plan.buildPlan(std.testing.allocator, &first, &first_state);
    defer first_plan.deinit();
    var second_plan = try ziac.plan.buildPlan(std.testing.allocator, &second, &second_state);
    defer second_plan.deinit();

    try std.testing.expectEqualSlices(
        u8,
        &first_plan.preconditions.desired_graph_digest,
        &second_plan.preconditions.desired_graph_digest,
    );
}
