const std = @import("std");
const ziac = @import("ziac");

fn testNode(image: []const u8) !ziac.ResourceNode {
    return ziac.ResourceNode.initOwned(std.testing.allocator, .{
        .id = "gcp.run.Service.europe-west1.api",
        .provider = .gcp,
        .type_name = "gcp.run.Service",
        .logical_id = "api",
        .inputs = .{ .object = &.{
            .{ .name = "image", .value = .{ .string = image } },
            .{ .name = "region", .value = .{ .string = "europe-west1" } },
        } },
    });
}

test "fake provider implements read diff create update and idempotent delete" {
    var node = try testNode("example/api:v1");
    defer node.deinit(std.testing.allocator);

    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    const provider = fake.provider();

    var before = try provider.read(std.testing.allocator, node);
    defer before.deinit();
    try std.testing.expect(before == .absent);

    var created = try provider.create(std.testing.allocator, node);
    defer created.deinit();
    try std.testing.expectEqualStrings("fake/gcp.run.Service.europe-west1.api", created.physical_id);
    try std.testing.expectEqual(@as(usize, 1), created.outputs.len);
    try std.testing.expectEqualStrings("physical_id", created.outputs[0].name);

    var after = try provider.read(std.testing.allocator, node);
    defer after.deinit();
    try std.testing.expect(after == .present);
    var no_change = try provider.diff(std.testing.allocator, node, &after.present);
    defer no_change.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.noop, no_change.kind);

    var changed = try testNode("example/api:v2");
    defer changed.deinit(std.testing.allocator);
    var update_diff = try provider.diff(std.testing.allocator, changed, &after.present);
    defer update_diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, update_diff.kind);
    try std.testing.expectEqualStrings("desired inputs changed", update_diff.reasons[0]);

    var updated = try provider.update(std.testing.allocator, changed, &after.present);
    defer updated.deinit();
    try std.testing.expectEqual(changed.inputs_hash, updated.observed_hash);

    try provider.delete(changed, updated.physical_id);
    try provider.delete(changed, updated.physical_id);
    var deleted = try provider.read(std.testing.allocator, changed);
    defer deleted.deinit();
    try std.testing.expect(deleted == .absent);
}

test "fake provider classifies replacement and imports physical resources" {
    var node = try testNode("example/api:v1");
    defer node.deinit(std.testing.allocator);

    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    fake.replace_changes = true;
    const provider = fake.provider();

    var imported = try provider.importResource(std.testing.allocator, node, "projects/example/services/api");
    defer imported.deinit();
    try std.testing.expectEqualStrings("projects/example/services/api", imported.physical_id);

    var changed = try testNode("example/api:v2");
    defer changed.deinit(std.testing.allocator);
    var diff = try provider.diff(std.testing.allocator, changed, &imported);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.replace, diff.kind);
}

test "provider errors have stable failure categories" {
    try std.testing.expectEqual(
        ziac.provider_error.Category.authentication,
        ziac.provider_error.category(error.AuthenticationFailed),
    );
    try std.testing.expectEqual(
        ziac.provider_error.Category.rate_limited,
        ziac.provider_error.category(error.RateLimited),
    );
    try std.testing.expectEqual(
        ziac.provider_error.Category.transient,
        ziac.provider_error.category(error.TransientFailure),
    );
}

test "apply persists provider physical state outputs and observed hash" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    var source = try testNode("example/api:v1");
    defer source.deinit(std.testing.allocator);
    try graph.addResource(source);

    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    var planned = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer planned.deinit();

    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    try ziac.apply.applyPlan(std.testing.allocator, &planned, &state, fake.provider());

    const record = state.get(source.id) orelse return error.MissingRecord;
    try std.testing.expectEqual(ziac.ResourceStatus.created, record.status);
    try std.testing.expectEqualStrings("fake/gcp.run.Service.europe-west1.api", record.physical_id.?);
    try std.testing.expect(record.observed_hash != null);
    try std.testing.expectEqual(@as(usize, 1), record.outputs.len);
    try std.testing.expectEqualStrings("fake/gcp.run.Service.europe-west1.api", record.outputs[0].value.string);
}

test "provider failure marks state failed with typed error" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    var source = try testNode("example/api:v1");
    defer source.deinit(std.testing.allocator);
    try graph.addResource(source);

    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    var planned = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer planned.deinit();

    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    fake.fail_next = error.RateLimited;

    try std.testing.expectError(
        error.RateLimited,
        ziac.apply.applyPlan(std.testing.allocator, &planned, &state, fake.provider()),
    );
    const record = state.get(source.id) orelse return error.MissingRecord;
    try std.testing.expectEqual(ziac.ResourceStatus.failed, record.status);
}
