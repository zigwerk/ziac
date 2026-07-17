const std = @import("std");
const zstd = @import("zigeffect_std");
const ziac = @import("ziac");

test "semantic recorder creates a typed parented infrastructure path" {
    var store = zstd.fx.CausalStore.init(std.testing.allocator);
    defer store.deinit();
    const recorder = ziac.runtime_events.Recorder.fromStore(&store);
    const plan_id = recorder.plan("stack", "success", "deterministic-plan");
    const operation_id = recorder.child(plan_id).resourceOperation("gcp.test.Resource.service", "create", "started");
    const provider_id = recorder.child(operation_id).providerRpc("gcp.test.Resource.service", "create", "success");
    _ = recorder.child(provider_id).stateCommit("gcp.test.Resource.service", "created", "success");

    var snapshot = try store.snapshot(std.testing.allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 4), snapshot.events.len);
    try std.testing.expectEqual(ziac.runtime_events.Kind.plan, ziac.runtime_events.kindFromEvent(snapshot.events[0]).?);
    try std.testing.expectEqual(ziac.runtime_events.Kind.resource_operation, ziac.runtime_events.kindFromEvent(snapshot.events[1]).?);
    try std.testing.expectEqual(ziac.runtime_events.Kind.provider_rpc, ziac.runtime_events.kindFromEvent(snapshot.events[2]).?);
    try std.testing.expectEqual(ziac.runtime_events.Kind.state_commit, ziac.runtime_events.kindFromEvent(snapshot.events[3]).?);
    try std.testing.expectEqual(snapshot.events[0].id, snapshot.events[1].parent_id.?);
    try std.testing.expectEqual(snapshot.events[1].id, snapshot.events[2].parent_id.?);
    try std.testing.expectEqual(snapshot.events[2].id, snapshot.events[3].parent_id.?);
}
