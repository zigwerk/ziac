const std = @import("std");
const ziac = @import("ziac");

test "build delivery graph synthesizes exact APIs and lifecycle permissions" {
    var pipeline = try buildPipeline();
    defer pipeline.deinit();
    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &pipeline.graph);
    defer requirements.deinit(std.testing.allocator);

    try std.testing.expect(contains(requirements.apis, "cloudbuild.googleapis.com"));
    try std.testing.expect(contains(requirements.apis, "artifactregistry.googleapis.com"));
    try std.testing.expect(requirements.hasPermission("cloudbuild.connections.create"));
    try std.testing.expect(requirements.hasPermission("cloudbuild.repositories.create"));
    try std.testing.expect(requirements.hasPermission("cloudbuild.workerpools.create"));
    try std.testing.expect(requirements.hasPermission("cloudbuild.builds.create"));
    try std.testing.expect(requirements.hasPermission("artifactregistry.repositories.create"));
    try std.testing.expect(requirements.hasPermission("artifactregistry.repositories.update"));
}

test "build delivery canvas exposes source execution trigger and artifact topology" {
    var pipeline = try buildPipeline();
    defer pipeline.deinit();
    var artifact = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &pipeline.graph, null, .{
        .stack = "delivery",
        .stage = "prod",
        .created_at_millis = 7,
    });
    defer artifact.deinit();

    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"build_delivery\":{\"kind\":\"connection\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"build_delivery\":{\"kind\":\"source_repository\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"build_delivery\":{\"kind\":\"worker_pool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"build_delivery\":{\"kind\":\"trigger\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"build_delivery\":{\"kind\":\"artifact_repository\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"source_connection\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"trigger_source\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"private_execution\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"build_artifact\"") != null);
}

test "estate scan maps only supported Cloud Build and Artifact Registry assets" {
    var client = ziac.estate.ScriptedClient.init(std.testing.allocator);
    defer client.deinit();
    try client.addPage(
        \\{"results":[
        \\{"name":"//cloudbuild.googleapis.com/projects/acme-prod/locations/europe-west1/connections/github","assetType":"cloudbuild.googleapis.com/Connection","project":"projects/123","location":"europe-west1"},
        \\{"name":"//cloudbuild.googleapis.com/projects/acme-prod/locations/europe-west1/connections/github/repositories/api","assetType":"cloudbuild.googleapis.com/Repository","project":"projects/123","location":"europe-west1"},
        \\{"name":"//cloudbuild.googleapis.com/projects/acme-prod/locations/europe-west1/workerPools/build","assetType":"cloudbuild.googleapis.com/WorkerPool","project":"projects/123","location":"europe-west1"},
        \\{"name":"//cloudbuild.googleapis.com/projects/acme-prod/locations/europe-west1/triggers/api-main","assetType":"cloudbuild.googleapis.com/BuildTrigger","project":"projects/123","location":"europe-west1"},
        \\{"name":"//artifactregistry.googleapis.com/projects/acme-prod/locations/europe-west1/repositories/api-artifacts","assetType":"artifactregistry.googleapis.com/Repository","project":"projects/123","location":"europe-west1"}
        \\]}
    );
    var scan = try ziac.estate.scanAlloc(std.testing.allocator, client.client(), .{
        .identity = .{ .provider = .google, .verified = true, .subject = "subject" },
        .entitlement = .pro,
        .connection = .{ .status = .connected, .project_id = "acme-prod" },
        .observed_at_millis = 1_783_764_000_000,
    });
    defer scan.deinit();

    try std.testing.expectEqual(@as(usize, 5), scan.resource_count);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.cloudbuild.Connection") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.cloudbuild.Repository") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.cloudbuild.WorkerPool") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.cloudbuild.Trigger") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.artifact.Repository") != null);
}

test "build delivery estimate separates minutes disk storage transfer and scans" {
    const prices = [_]ziac.cost.SkuPrice{
        .{ .sku_id = "default-minutes", .region = "europe-west1", .unit = "minute", .unit_quantity = 1, .unit_price_micros = 3_000 },
        .{ .sku_id = "private-minutes", .region = "europe-west1", .unit = "minute", .unit_quantity = 1, .unit_price_micros = 10_000 },
        .{ .sku_id = "private-disk", .region = "europe-west1", .unit = "GiB hour", .unit_quantity = 1, .unit_price_micros = 100 },
        .{ .sku_id = "artifact-storage", .region = "europe-west1", .unit = "GiB month", .unit_quantity = 1, .unit_price_micros = 100_000 },
        .{ .sku_id = "artifact-transfer", .region = "europe-west1", .unit = "GiB", .unit_quantity = 1, .unit_price_micros = 120_000 },
        .{ .sku_id = "artifact-scan", .region = "europe-west1", .unit = "scan", .unit_quantity = 1, .unit_price_micros = 260_000 },
    };
    const estimate = try ziac.cost.buildDeliveryConfigurationEstimate(&prices, .{
        .resource_id = "ziac.delivery.api",
        .region = "europe-west1",
        .default_build_minute_sku_id = "default-minutes",
        .private_build_minute_sku_id = "private-minutes",
        .private_disk_sku_id = "private-disk",
        .artifact_storage_sku_id = "artifact-storage",
        .artifact_transfer_sku_id = "artifact-transfer",
        .vulnerability_scan_sku_id = "artifact-scan",
        .default_build_minutes = 200,
        .free_default_build_minutes = 100,
        .private_build_minutes = 50,
        .private_disk_gib_hours = 1000,
        .artifact_storage_gib_month = 20,
        .artifact_transfer_gib = 5,
        .vulnerability_scans = 2,
        .observed_at_millis = 7,
    });
    try std.testing.expectEqual(@as(?i64, 4_020_000), estimate.amount_micros);
    try std.testing.expectEqual(ziac.cost.Origin.configuration_estimate, estimate.origin);
}

test "build delivery local qualification records import refresh no-op and cleanup" {
    var pipeline = try ziac.gcp.ZigBuildPipeline.build(std.testing.allocator, .{ .project_id = "ziac-dev", .primary_region = "europe-west1" }, .{
        .name = "qualification",
        .location = "europe-west1",
        .connection = .{ .github = .{ .oauth_token_secret_version = "projects/ziac-dev/secrets/github/versions/1", .app_installation_id = "123" } },
        .remote_uri = "https://github.com/acme/qualification.git",
        .private_pool = .{ .network = .{ .peered = .{ .network = "projects/123/global/networks/build" } } },
        .protect = false,
    });
    defer pipeline.deinit();
    var remote = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer remote.deinit();
    var providers = ziac.provider.ProviderRegistry{};
    providers.register(.gcp, remote.provider());
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    var create_plan = try ziac.plan.buildPlan(std.testing.allocator, &pipeline.graph, &state);
    defer create_plan.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &create_plan, &state, providers, .{});

    var imported_remote = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer imported_remote.deinit();
    var imported_providers = ziac.provider.ProviderRegistry{};
    imported_providers.register(.gcp, imported_remote.provider());
    var imported_state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer imported_state.deinit();
    for (pipeline.graph.resources.items) |node| {
        const record = state.get(node.id) orelse return error.MissingRecord;
        try ziac.importer.importResource(std.testing.allocator, node, record.physical_id orelse return error.MissingRecord, &imported_state, imported_providers, null);
    }
    var refreshed = try ziac.plan.buildRefreshedPlan(std.testing.allocator, &pipeline.graph, &imported_state, imported_providers);
    defer refreshed.deinit();
    for (refreshed.operations) |item| try std.testing.expectEqual(ziac.plan.OperationKind.noop, item.kind);
    var destroy = try ziac.plan.buildDestroyPlan(std.testing.allocator, &state);
    defer destroy.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &destroy, &state, providers, .{ .destructive_confirmation = true });

    var receipt = try ziac.gcp.build_delivery_qualification.serializeLocalAlloc(std.testing.allocator, &pipeline.graph, .{
        .created = remote.creates,
        .imported = imported_remote.imports,
        .no_op = refreshed.operations.len,
        .deleted = remote.deletes,
    });
    defer receipt.deinit();
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"schema\":\"ziac.gcp.build-delivery-qualification.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"authenticated\":false") != null);
}

fn buildPipeline() !ziac.gcp.ZigBuildPipeline {
    return ziac.gcp.ZigBuildPipeline.build(std.testing.allocator, .{ .project_id = "ziac-dev", .primary_region = "europe-west1" }, .{
        .name = "api",
        .location = "europe-west1",
        .connection = .{ .github = .{ .oauth_token_secret_version = "projects/ziac-dev/secrets/github/versions/1", .app_installation_id = "123" } },
        .remote_uri = "https://github.com/acme/api.git",
        .private_pool = .{ .network = .{ .peered = .{ .network = "projects/123/global/networks/build" } } },
        .cleanup_policies = &.{.{ .name = "keep-releases", .rule = .{ .keep_most_recent = .{ .count = 20 } } }},
    });
}

fn contains(values: []const []const u8, expected: []const u8) bool {
    for (values) |present| if (std.mem.eql(u8, present, expected)) return true;
    return false;
}
