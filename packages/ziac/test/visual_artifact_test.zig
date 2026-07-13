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

test "visual artifact projects Cloud Storage inspector details and location" {
    const provider = ziac.gcp.config.ProviderConfig{
        .project_id = "ziac-prod",
        .primary_region = "europe-west1",
        .service_regions = &.{"europe-west1"},
    };
    var bucket = try ziac.gcp.storage.Bucket.build(std.testing.allocator, provider, .{
        .name = "ziac-assets",
        .location = "europe-west1",
        .storage_class = .nearline,
        .retention_period_seconds = 86_400,
        .soft_delete_retention_seconds = 604_800,
        .lifecycle_rules = &.{.{ .action = .delete, .condition = .{ .age_days = 365 } }},
    });
    defer bucket.deinit(std.testing.allocator);
    var member = try ziac.gcp.storage.BucketIamMember.build(std.testing.allocator, provider, .{
        .name = "api-assets-reader",
        .bucket = bucket.name,
        .role = "roles/storage.objectViewer",
        .member = "serviceAccount:api@ziac-prod.iam.gserviceaccount.com",
    });
    defer member.deinit(std.testing.allocator);
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.addResource(bucket.node);
    try graph.addResource(member.node);

    var artifact = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &graph, null, .{
        .stack = "assets",
        .stage = "prod",
        .created_at_millis = 7,
    });
    defer artifact.deinit();
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"region\":\"europe-west1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"storage\":{\"kind\":\"bucket\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"storage_class\":\"NEARLINE\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"retention_period_seconds\":86400") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"soft_delete_retention_seconds\":604800") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"iam_role\":\"roles/storage.objectViewer\"") != null);
}

test "visual artifact projects Pub/Sub inspector metadata and event edges" {
    const provider = ziac.gcp.ProviderConfig{ .project_id = "ziac-prod", .primary_region = "europe-west1" };
    var topic = try ziac.gcp.pubsub.Topic.build(std.testing.allocator, provider, .{
        .name = "orders",
        .message_retention_seconds = 86_400,
        .allowed_persistence_regions = &.{ "europe-west1", "europe-west4" },
    });
    defer topic.deinit(std.testing.allocator);
    var subscription = try ziac.gcp.pubsub.Subscription.build(std.testing.allocator, provider, .{
        .name = "orders-worker",
        .topic = topic.name,
        .delivery = .pull,
        .ack_deadline_seconds = 30,
    });
    defer subscription.deinit(std.testing.allocator);
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.addResource(topic.node);
    try graph.addResource(subscription.node);

    var artifact = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &graph, null, .{
        .stack = "events",
        .stage = "prod",
        .created_at_millis = 7,
    });
    defer artifact.deinit();
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"pubsub\":{\"kind\":\"topic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"message_retention_seconds\":86400") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"delivery_kind\":\"pull\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"event\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"regions\":[\"europe-west1\",\"europe-west4\"]") != null);
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
