const std = @import("std");
const ziac = @import("ziac");

test "fake provider records reconcile for create operations" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();

    try graph.addResource(.{
        .id = "gcp.run.Service.api",
        .type_name = "gcp.run.Service",
        .logical_id = "api",
    });

    var planned = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer planned.deinit();

    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();

    try ziac.apply.applyPlan(std.testing.allocator, &planned, &state, fake.provider());

    try std.testing.expectEqual(@as(usize, 1), fake.reconciled.items.len);
    try std.testing.expectEqualStrings("gcp.run.Service.api", fake.reconciled.items[0]);

    const record = state.get("gcp.run.Service.api") orelse return error.MissingRecord;
    try std.testing.expectEqual(ziac.ResourceStatus.created, record.status);
}

test "fake provider failure marks state failed" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();

    try graph.addResource(.{
        .id = "gcp.run.Service.api",
        .type_name = "gcp.run.Service",
        .logical_id = "api",
    });

    var planned = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer planned.deinit();

    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    fake.fail_reconcile = true;

    try std.testing.expectError(
        error.ProviderFailed,
        ziac.apply.applyPlan(std.testing.allocator, &planned, &state, fake.provider()),
    );

    const record = state.get("gcp.run.Service.api") orelse return error.MissingRecord;
    try std.testing.expectEqual(ziac.ResourceStatus.failed, record.status);
}
