const std = @import("std");
const ziac = @import("ziac");

fn addNode(graph: *ziac.ResourceGraph, image: []const u8) !void {
    try graph.addResource(.{
        .id = "service",
        .provider = .gcp,
        .type_name = "gcp.run.Service",
        .logical_id = "service",
        .inputs = .{ .object = &.{
            .{ .name = "image", .value = .{ .string = image } },
        } },
    });
}

test "refresh updates observed state without mutating desired infrastructure" {
    var desired = ziac.ResourceGraph.init(std.testing.allocator);
    defer desired.deinit();
    try addNode(&desired, "example/service:v1");
    var drifted = ziac.ResourceGraph.init(std.testing.allocator);
    defer drifted.deinit();
    try addNode(&drifted, "example/service:manual");
    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    var remote = try fake.provider().create(std.testing.allocator, drifted.resources.items[0]);
    defer remote.deinit();
    var providers = ziac.provider.ProviderRegistry{};
    providers.register(.gcp, fake.provider());
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();

    try ziac.refresh.refreshGraph(
        std.testing.allocator,
        &desired,
        &state,
        providers,
        null,
    );

    const record = state.get("service").?;
    const desired_hash = std.fmt.bytesToHex(desired.resources.items[0].inputs_hash, .lower);
    const observed_hash = std.fmt.bytesToHex(remote.observed_hash, .lower);
    try std.testing.expectEqualStrings(desired_hash[0..], record.desired_hash);
    try std.testing.expectEqualStrings(observed_hash[0..], record.observed_hash.?);
    try std.testing.expectEqual(ziac.ResourceStatus.adopted, record.status);
    try std.testing.expectEqual(@as(usize, 1), fake.creates);
    try std.testing.expectEqual(@as(usize, 0), fake.updates);
    try std.testing.expectEqual(@as(usize, 0), fake.deletes);
    try std.testing.expectEqual(@as(usize, 1), fake.reads);
}

test "import validates provider identifiers before provider mutation" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try addNode(&graph, "example/service:v1");
    const node = graph.resources.items[0];
    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    var providers = ziac.provider.ProviderRegistry{};
    providers.register(.gcp, fake.provider());
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();

    try std.testing.expectError(
        error.InvalidProviderIdentifier,
        ziac.importer.importResource(
            std.testing.allocator,
            node,
            "",
            &state,
            providers,
            null,
        ),
    );
    try std.testing.expectError(
        error.InvalidProviderIdentifier,
        ziac.importer.importResource(
            std.testing.allocator,
            node,
            "projects/example services/service",
            &state,
            providers,
            null,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.imports);

    try ziac.importer.importResource(
        std.testing.allocator,
        node,
        "projects/example/locations/europe-west1/services/service",
        &state,
        providers,
        null,
    );
    try std.testing.expectEqual(@as(usize, 1), fake.imports);
    const imported = state.get("service").?;
    try std.testing.expectEqual(ziac.ResourceStatus.adopted, imported.status);
    try std.testing.expectEqualStrings(
        "projects/example/locations/europe-west1/services/service",
        imported.physical_id.?,
    );
}
