const std = @import("std");
const ziac = @import("ziac");

const image_v1 = "europe-west1-docker.pkg.dev/ziac-dev/apps/api@sha256:1111111111111111111111111111111111111111111111111111111111111111";
const image_v2 = "europe-west1-docker.pkg.dev/ziac-dev/apps/api@sha256:2222222222222222222222222222222222222222222222222222222222222222";
const regions = [_][]const u8{ "europe-west1", "us-central1" };
const provider = ziac.gcp.config.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = regions[0],
    .service_regions = &regions,
    .network_tier = .premium,
};

test "rollback graph replaces every fully rolled out service with its previous digest" {
    var desired = try serviceGraph(image_v2);
    defer desired.deinit();
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    for (desired.resources.items) |node| try putServiceState(&state, node, image_v2, image_v1, node.inputs_hash, .updated);

    var rollback = try ziac.rollout.buildRollbackGraphAlloc(std.testing.allocator, &desired, &state);
    defer rollback.deinit();

    try std.testing.expectEqual(@as(usize, 2), rollback.target_count);
    try std.testing.expectEqual(desired.resources.items.len, rollback.graph.resources.items.len);
    try std.testing.expectEqual(desired.dependencies.items.len, rollback.graph.dependencies.items.len);
    for (rollback.graph.resources.items) |node| {
        try std.testing.expectEqualStrings(image_v1, inputString(node, "image"));
    }
}

test "rollback graph changes the completed canary and preserves an untouched fleet region" {
    var desired = try serviceGraph(image_v2);
    defer desired.deinit();
    var previous = try serviceGraph(image_v1);
    defer previous.deinit();
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    try putServiceState(&state, desired.resources.items[0], image_v2, image_v1, desired.resources.items[0].inputs_hash, .updated);
    try putServiceState(&state, desired.resources.items[1], image_v1, null, previous.resources.items[1].inputs_hash, .failed);

    var rollback = try ziac.rollout.buildRollbackGraphAlloc(std.testing.allocator, &desired, &state);
    defer rollback.deinit();

    try std.testing.expectEqual(@as(usize, 1), rollback.target_count);
    try std.testing.expectEqualStrings(image_v1, inputString(rollback.graph.resources.items[0], "image"));
    try std.testing.expectEqualStrings(image_v1, inputString(rollback.graph.resources.items[1], "image"));
}

test "rollback graph rejects absent history and mutable image tags" {
    var desired = try serviceGraph(image_v2);
    defer desired.deinit();
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    for (desired.resources.items) |node| try putServiceState(&state, node, image_v2, null, node.inputs_hash, .updated);
    try std.testing.expectError(
        error.RollbackHistoryIncomplete,
        ziac.rollout.buildRollbackGraphAlloc(std.testing.allocator, &desired, &state),
    );

    var tagged = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer tagged.deinit();
    for (desired.resources.items) |node| try putServiceState(&tagged, node, image_v2, "example/api:latest", node.inputs_hash, .updated);
    try std.testing.expectError(
        error.RollbackImageNotImmutable,
        ziac.rollout.buildRollbackGraphAlloc(std.testing.allocator, &desired, &tagged),
    );
}

fn serviceGraph(image: []const u8) !ziac.ResourceGraph {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    errdefer graph.deinit();
    for (regions) |region| {
        var service = try ziac.gcp.cloud_run.Service.build(std.testing.allocator, provider, .{
            .name = "api",
            .region = region,
            .image = image,
        });
        defer service.deinit(std.testing.allocator);
        try graph.addResource(service.node);
    }
    try graph.addDependency(graph.resources.items[1].id, graph.resources.items[0].id);
    return graph;
}

fn putServiceState(
    state: *ziac.InMemoryStateStore,
    node: ziac.ResourceNode,
    current_image: []const u8,
    previous_image: ?[]const u8,
    observed_inputs_hash: [32]u8,
    status: ziac.state.ResourceStatus,
) !void {
    const desired_hash = std.fmt.bytesToHex(node.inputs_hash, .lower);
    const observed_hash = std.fmt.bytesToHex(observed_inputs_hash, .lower);
    const outputs_with_previous = [_]ziac.state.StateOutput{
        .{ .name = "image_ref", .value = .{ .string = current_image } },
        .{ .name = "previous_image_ref", .value = .{ .string = previous_image orelse current_image } },
    };
    const outputs_without_previous = [_]ziac.state.StateOutput{
        .{ .name = "image_ref", .value = .{ .string = current_image } },
        .{ .name = "previous_image_ref", .value = .{ .unknown_reason = "No previous Cloud Run image" } },
    };
    try state.put(.{
        .resource_id = node.id,
        .provider = .gcp,
        .type_name = node.type_name,
        .schema_version = node.schema_version,
        .logical_id = node.logical_id,
        .physical_id = node.id,
        .desired_hash = desired_hash[0..],
        .observed_hash = observed_hash[0..],
        .outputs = if (previous_image == null) &outputs_without_previous else &outputs_with_previous,
        .status = status,
    });
}

fn inputString(node: ziac.ResourceNode, name: []const u8) []const u8 {
    for (node.inputs.object) |field| {
        if (std.mem.eql(u8, field.name, name)) return field.value.string;
    }
    unreachable;
}
