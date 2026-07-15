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
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"iam\",\"access\":\"read\",\"permissions\":[\"storage.objects.get\"]") != null);
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

test "visual artifact projects Cloud Tasks and Eventarc delivery metadata" {
    const provider = ziac.gcp.ProviderConfig{ .project_id = "ziac-prod", .primary_region = "europe-west1" };
    var queue = try ziac.gcp.tasks.Queue.build(std.testing.allocator, provider, .{
        .name = "invoice-worker",
        .rate_limits = .{ .max_dispatches_per_second = 25, .max_concurrent_dispatches = 50 },
        .retry_config = .{ .max_attempts = 8 },
        .http_target = .{
            .uri_override = .{ .scheme = .https, .host = "invoice.example.run.app" },
            .authorization = .{ .oidc = .{
                .service_account_email = "tasks@ziac-prod.iam.gserviceaccount.com",
                .audience = "https://invoice.example.run.app",
            } },
        },
    });
    defer queue.deinit(std.testing.allocator);
    var trigger = try ziac.gcp.eventarc.Trigger.build(std.testing.allocator, provider, .{
        .name = "orders-created",
        .event_filters = &.{.{ .attribute = "type", .value = "google.cloud.pubsub.topic.v1.messagePublished" }},
        .service_account = "events@ziac-prod.iam.gserviceaccount.com",
        .destination = .{ .cloud_run = .{ .service = "orders-worker", .region = "europe-west1" } },
        .transport_topic = ziac.PublicOutput([]const u8).known("projects/ziac-prod/topics/orders"),
    });
    defer trigger.deinit(std.testing.allocator);
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.addResource(queue.node);
    try graph.addResource(trigger.node);

    var artifact = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &graph, null, .{
        .stack = "async",
        .stage = "prod",
        .created_at_millis = 7,
    });
    defer artifact.deinit();
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"async_delivery\":{\"kind\":\"queue\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"max_concurrent_dispatches\":50") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"authorization_kind\":\"oidc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"async_delivery\":{\"kind\":\"trigger\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"event_filter_count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"destination_kind\":\"cloud_run\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"region\":\"europe-west1\"") != null);
}

test "visual artifact projects Cloud Run Job Worker Pool and workload IAM metadata" {
    const provider = ziac.gcp.ProviderConfig{ .project_id = "ziac-prod", .primary_region = "europe-west1" };
    var scheduled = try ziac.gcp.ScheduledZigJob.build(std.testing.allocator, provider, .{
        .workload = .{
            .name = "nightly-report",
            .containers = &.{.{
                .name = "main",
                .image = "example.invalid/report@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            }},
            .task_count = 12,
            .parallelism = 3,
            .max_retries = 2,
            .timeout_seconds = 900,
        },
        .schedule = "0 2 * * *",
    });
    defer scheduled.deinit();
    var worker = try ziac.gcp.ZigWorkerPool.build(std.testing.allocator, provider, .{
        .workload = .{
            .name = "events",
            .containers = &.{.{
                .name = "worker",
                .image = "example.invalid/events@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            }},
            .manual_instance_count = 4,
            .instance_splits = &.{.{ .allocation = .latest, .percent = 100 }},
        },
    });
    defer worker.deinit();
    for (worker.graph.resources.items) |node| try scheduled.graph.addResource(node);
    for (worker.graph.dependencies.items) |edge| try scheduled.graph.addDependency(edge.from, edge.to);

    var artifact = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &scheduled.graph, null, .{
        .stack = "workloads",
        .stage = "prod",
        .created_at_millis = 7,
    });
    defer artifact.deinit();

    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"run_workload\":{\"kind\":\"job\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"task_count\":12") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"parallelism\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"run_workload\":{\"kind\":\"worker_pool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"manual_instance_count\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"instance_split_count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"run_workload\":{\"kind\":\"job_iam_member\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"iam_role\":\"roles/run.invoker\"") != null);
}

test "visual artifact exposes IAM authority and blast radius" {
    var binding = try ziac.gcp.iam.ProjectBinding.build(std.testing.allocator, .{
        .project_id = "ziac-prod",
        .primary_region = "europe-west1",
    }, .{
        .name = "artifact-readers",
        .role = "roles/artifactregistry.reader",
        .members = &.{
            "group:platform@example.com",
            "serviceAccount:api@ziac-prod.iam.gserviceaccount.com",
        },
        .condition = .{
            .title = "production-window",
            .expression = "request.time < timestamp('2027-01-01T00:00:00Z')",
        },
    });
    defer binding.deinit(std.testing.allocator);
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.addResource(binding.node);

    var artifact = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &graph, null, .{
        .stack = "global-api",
        .stage = "prod",
        .created_at_millis = 42,
    });
    defer artifact.deinit();
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"iam\":{\"ownership\":\"binding\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"target\":\"projects/ziac-prod\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"role\":\"roles/artifactregistry.reader\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"condition_title\":\"production-window\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"principal_count\":2") != null);
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

test "visual artifact projects security foundation semantics and trust edges" {
    var policy = try ziac.gcp.TrustedArtifactPolicy.build(std.testing.allocator, .{
        .project_id = "security-prod",
        .primary_region = "europe-west1",
    }, .{
        .name = "runtime",
        .project = ziac.PublicOutput([]const u8).known("projects/security-prod"),
        .note = ziac.PublicOutput([]const u8).known("projects/security-prod/notes/release-attestations"),
        .public_keys = &.{.{ .key = .{ .pgp = "-----BEGIN PGP PUBLIC KEY BLOCK-----\nYWJj\n-----END PGP PUBLIC KEY BLOCK-----" } }},
    });
    defer policy.deinit();
    var artifact = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &policy.graph, null, .{
        .stack = "security",
        .stage = "prod",
        .created_at_millis = 0,
    });
    defer artifact.deinit();
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"artifact_attestor\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"admission_policy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"admission_attestor\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"amount_micros\":0") != null);
}
