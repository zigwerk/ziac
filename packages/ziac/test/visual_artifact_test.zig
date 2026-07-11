const std = @import("std");
const ziac = @import("ziac");

test "visual artifact deterministically projects topology plan and safe display inputs" {
    var graph = try fixtureGraph();
    defer graph.deinit();
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    state.setLineage("global-api/prod");
    var planned = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer planned.deinit();

    var first = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &graph, &planned, .{
        .stack = "global-api",
        .stage = "prod",
        .created_at_millis = 1_725_000_000_000,
    });
    defer first.deinit();
    var second = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &graph, &planned, .{
        .stack = "global-api",
        .stage = "prod",
        .created_at_millis = 1_725_000_000_000,
    });
    defer second.deinit();

    try std.testing.expectEqualStrings(first.bytes, second.bytes);
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, "\"schema\":\"ziac.visual.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, "\"truth_mode\":\"plan\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, "\"graph_digest\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, "\"operation\":\"create\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, "\"scope\":\"regional\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, "\"region\":\"europe-west1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, "\"regions\":[\"europe-west1\",\"us-central1\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, "\"kind\":\"traffic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, "\"kind\":\"output\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, "\"$secret\":\"redacted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, "sentinel-api-token-plaintext") == null);
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, "sentinel-secret-resource") == null);

    const run_index = std.mem.indexOf(u8, first.bytes, "gcp.run.Service.europe-west1.api").?;
    const forwarding_index = std.mem.indexOf(u8, first.bytes, "gcp.compute.GlobalForwardingRule.api").?;
    try std.testing.expect(forwarding_index < run_index);
}

test "visual artifact supports desired-only graphs and rejects unsafe targets" {
    var graph = try fixtureGraph();
    defer graph.deinit();

    var artifact = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &graph, null, .{
        .stack = "global-api",
        .stage = "dev",
        .created_at_millis = 7,
    });
    defer artifact.deinit();

    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"truth_mode\":\"desired\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"operation\":\"none\"") != null);
    try std.testing.expectError(error.InvalidVisualTarget, ziac.visual_artifact.serializeAlloc(
        std.testing.allocator,
        &graph,
        null,
        .{ .stack = "../global-api", .stage = "dev", .created_at_millis = 7 },
    ));
}

fn fixtureGraph() !ziac.ResourceGraph {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    errdefer graph.deinit();
    try graph.addResource(.{
        .id = "gcp.run.Service.europe-west1.api",
        .provider = .gcp,
        .type_name = "gcp.run.Service",
        .logical_id = "api",
        .inputs = .{ .object = &.{
            .{ .name = "api_token", .value = .{ .string = "sentinel-api-token-plaintext" } },
            .{ .name = "database_url", .value = .{ .secret_ref = .{
                .provider = "gcp-secret-manager",
                .resource = "sentinel-secret-resource",
                .version = "latest",
            } } },
            .{ .name = "project_id", .value = .{ .string = "ziac-prod" } },
            .{ .name = "region", .value = .{ .string = "europe-west1" } },
        } },
    });
    try graph.addResource(.{
        .id = "gcp.compute.RegionServerlessNeg.europe-west1.api",
        .provider = .gcp,
        .type_name = "gcp.compute.RegionServerlessNeg",
        .logical_id = "europe-west1.api",
        .inputs = .{ .object = &.{
            .{ .name = "project_id", .value = .{ .string = "ziac-prod" } },
            .{ .name = "region", .value = .{ .string = "europe-west1" } },
        } },
    });
    try graph.addResource(.{
        .id = "gcp.compute.GlobalAddress.api",
        .provider = .gcp,
        .type_name = "gcp.compute.GlobalAddress",
        .logical_id = "api",
        .inputs = .{ .object = &.{.{ .name = "project_id", .value = .{ .string = "ziac-prod" } }} },
    });
    try graph.addResource(.{
        .id = "gcp.compute.GlobalForwardingRule.api",
        .provider = .gcp,
        .type_name = "gcp.compute.GlobalForwardingRule",
        .logical_id = "api",
        .inputs = .{ .object = &.{
            .{ .name = "address", .value = .{ .output_ref = .{
                .resource_id = "gcp.compute.GlobalAddress.api",
                .field = "address",
            } } },
            .{ .name = "project_id", .value = .{ .string = "ziac-prod" } },
        } },
    });
    try graph.addResource(.{
        .id = "cockroach.Cluster.app-data",
        .provider = .cockroach,
        .type_name = "cockroach.Cluster",
        .logical_id = "app-data",
        .inputs = .{ .object = &.{
            .{ .name = "primary_region", .value = .{ .string = "europe-west1" } },
            .{ .name = "regions", .value = .{ .list = &.{
                .{ .object = &.{
                    .{ .name = "name", .value = .{ .string = "europe-west1" } },
                    .{ .name = "primary", .value = .{ .boolean = true } },
                } },
                .{ .object = &.{
                    .{ .name = "name", .value = .{ .string = "us-central1" } },
                    .{ .name = "primary", .value = .{ .boolean = false } },
                } },
            } } },
        } },
    });
    try graph.addDependency(
        "gcp.compute.RegionServerlessNeg.europe-west1.api",
        "gcp.run.Service.europe-west1.api",
    );
    try graph.addDependency(
        "gcp.compute.GlobalForwardingRule.api",
        "gcp.compute.RegionServerlessNeg.europe-west1.api",
    );
    return graph;
}
