const std = @import("std");
const ziac = @import("ziac");

test "Logging graph synthesizes exact API and lifecycle permissions" {
    var platform = try buildPlatform();
    defer platform.deinit();
    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &platform.graph);
    defer requirements.deinit(std.testing.allocator);

    try std.testing.expect(contains(requirements.apis, "logging.googleapis.com"));
    try std.testing.expect(requirements.hasPermission("logging.buckets.create"));
    try std.testing.expect(requirements.hasPermission("logging.buckets.update"));
    try std.testing.expect(requirements.hasPermission("logging.views.create"));
    try std.testing.expect(requirements.hasPermission("logging.sinks.create"));
    try std.testing.expect(requirements.hasPermission("logging.exclusions.create"));
    try std.testing.expect(requirements.hasPermission("logging.logMetrics.create"));
}

test "Logging canvas exposes resource roles and flat routing edges" {
    var platform = try buildPlatform();
    defer platform.deinit();
    var artifact = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &platform.graph, null, .{
        .stack = "logging",
        .stage = "prod",
        .created_at_millis = 7,
    });
    defer artifact.deinit();

    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"logging\":{\"kind\":\"bucket\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"logging\":{\"kind\":\"view\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"logging\":{\"kind\":\"sink\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"logging\":{\"kind\":\"exclusion\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"logging\":{\"kind\":\"metric\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"log_view\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"log_route\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"log_metric\"") != null);
}

test "estate scan maps only official Logging Cloud Asset types" {
    var client = ziac.estate.ScriptedClient.init(std.testing.allocator);
    defer client.deinit();
    try client.addPage(
        \\{"results":[
        \\{"name":"//logging.googleapis.com/projects/acme-prod/locations/global/buckets/app","assetType":"logging.googleapis.com/LogBucket","project":"projects/123","location":"global"},
        \\{"name":"//logging.googleapis.com/projects/acme-prod/locations/global/buckets/app/views/errors","assetType":"logging.googleapis.com/LogView","project":"projects/123","location":"global"},
        \\{"name":"//logging.googleapis.com/projects/acme-prod/metrics/errors","assetType":"logging.googleapis.com/LogMetric","project":"projects/123","location":"global"},
        \\{"name":"//logging.googleapis.com/projects/acme-prod/sinks/archive","assetType":"logging.googleapis.com/LogSink","project":"projects/123","location":"global"}
        \\]}
    );
    var scan = try ziac.estate.scanAlloc(std.testing.allocator, client.client(), .{
        .identity = .{ .provider = .google, .verified = true, .subject = "subject" },
        .entitlement = .pro,
        .connection = .{ .status = .connected, .project_id = "acme-prod" },
        .observed_at_millis = 1_783_764_000_000,
    });
    defer scan.deinit();

    try std.testing.expectEqual(@as(usize, 4), scan.resource_count);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.logging.Bucket") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.logging.View") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.logging.Metric") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.logging.Sink") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.logging.Exclusion") == null);
}

test "Logging estimate separates free normal ingestion vended logs retention and metrics" {
    const prices = [_]ziac.cost.SkuPrice{
        .{ .sku_id = "normal-ingestion", .region = "global", .unit = "GiB", .unit_quantity = 1, .unit_price_micros = 500_000 },
        .{ .sku_id = "vended-ingestion", .region = "global", .unit = "GiB", .unit_quantity = 1, .unit_price_micros = 250_000 },
        .{ .sku_id = "excess-retention", .region = "global", .unit = "GiB month", .unit_quantity = 1, .unit_price_micros = 10_000 },
        .{ .sku_id = "custom-metric-bytes", .region = "global", .unit = "MiB month", .unit_quantity = 1, .unit_price_micros = 258_000 },
    };
    const estimate = try ziac.cost.loggingConfigurationEstimate(&prices, .{
        .resource_id = "ziac.logging.prod",
        .normal_ingestion_sku_id = "normal-ingestion",
        .vended_ingestion_sku_id = "vended-ingestion",
        .excess_retention_sku_id = "excess-retention",
        .custom_metric_bytes_sku_id = "custom-metric-bytes",
        .normal_ingestion_gib = 80,
        .free_normal_ingestion_gib = 50,
        .vended_ingestion_gib = 10,
        .retained_gib_months_beyond_30_days = 100,
        .custom_metric_mib_months = 2,
        .observed_at_millis = 7,
    });
    try std.testing.expectEqual(@as(?i64, 19_016_000), estimate.amount_micros);
    try std.testing.expectEqual(ziac.cost.Origin.configuration_estimate, estimate.origin);
}

test "Logging local qualification records import refresh no-op and cleanup evidence" {
    var platform = try buildPlatform();
    defer platform.deinit();
    var remote = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer remote.deinit();
    var providers = ziac.provider.ProviderRegistry{};
    providers.register(.gcp, remote.provider());
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    var create_plan = try ziac.plan.buildPlan(std.testing.allocator, &platform.graph, &state);
    defer create_plan.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &create_plan, &state, providers, .{});

    var imported_remote = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer imported_remote.deinit();
    var imported_providers = ziac.provider.ProviderRegistry{};
    imported_providers.register(.gcp, imported_remote.provider());
    var imported_state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer imported_state.deinit();
    for (platform.graph.resources.items) |node| {
        const record = state.get(node.id) orelse return error.MissingRecord;
        try ziac.importer.importResource(std.testing.allocator, node, record.physical_id orelse return error.MissingRecord, &imported_state, imported_providers, null);
    }
    var refreshed = try ziac.plan.buildRefreshedPlan(std.testing.allocator, &platform.graph, &imported_state, imported_providers);
    defer refreshed.deinit();
    for (refreshed.operations) |item| try std.testing.expectEqual(ziac.plan.OperationKind.noop, item.kind);
    var destroy = try ziac.plan.buildDestroyPlan(std.testing.allocator, &state);
    defer destroy.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &destroy, &state, providers, .{ .destructive_confirmation = true });

    var receipt = try ziac.gcp.logging_qualification.serializeLocalAlloc(std.testing.allocator, &platform.graph, .{
        .created = remote.creates,
        .imported = imported_remote.imports,
        .no_op = refreshed.operations.len,
        .deleted = remote.deletes,
    });
    defer receipt.deinit();
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"schema\":\"ziac.gcp.logging-qualification.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"authenticated\":false") != null);
}

fn buildPlatform() !ziac.gcp.ApplicationLogPlatform {
    return ziac.gcp.ApplicationLogPlatform.build(std.testing.allocator, .{ .project_id = "ziac-dev", .primary_region = "europe-west1" }, .{
        .name = "global-api",
        .location = "global",
        .retention_days = 90,
        .views = &.{.{ .name = "errors", .filter = "severity>=ERROR" }},
        .route_filter = "resource.type=\"cloud_run_revision\"",
        .project_exclusions = &.{.{ .name = "debug-sample", .filter = "severity=DEBUG AND sample(insertId, 0.9)" }},
        .metrics = &.{.{ .name = "errors", .filter = "severity>=ERROR" }},
        .protect = false,
    });
}

fn contains(values: []const []const u8, expected: []const u8) bool {
    for (values) |present| if (std.mem.eql(u8, present, expected)) return true;
    return false;
}
