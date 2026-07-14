const std = @import("std");
const ziac = @import("ziac");

test "Monitoring graph synthesizes exact APIs and lifecycle permissions" {
    var topology = try buildTopology();
    defer topology.deinit();
    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &topology.graph);
    defer requirements.deinit(std.testing.allocator);

    try std.testing.expect(contains(requirements.apis, "monitoring.googleapis.com"));
    try std.testing.expect(requirements.hasPermission("monitoring.services.create"));
    try std.testing.expect(requirements.hasPermission("monitoring.slos.create"));
    try std.testing.expect(requirements.hasPermission("monitoring.uptimeCheckConfigs.create"));
    try std.testing.expect(requirements.hasPermission("monitoring.alertPolicies.create"));
    try std.testing.expect(requirements.hasPermission("monitoring.notificationChannels.create"));
    try std.testing.expect(requirements.hasPermission("monitoring.dashboards.create"));
}

test "Monitoring canvas exposes resource roles and observability edges" {
    var topology = try buildTopology();
    defer topology.deinit();
    var artifact = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &topology.graph, null, .{
        .stack = "monitoring",
        .stage = "prod",
        .created_at_millis = 7,
    });
    defer artifact.deinit();

    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"monitoring\":{\"kind\":\"service\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"monitoring\":{\"kind\":\"slo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"monitoring\":{\"kind\":\"uptime_check\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"monitoring\":{\"kind\":\"alert_policy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"monitoring\":{\"kind\":\"notification_channel\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"monitoring\":{\"kind\":\"dashboard\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"service_slo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"probe_target\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"notification\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"dashboard_visualizes\"") != null);
}

test "estate scan maps only official Monitoring Cloud Asset types" {
    var client = ziac.estate.ScriptedClient.init(std.testing.allocator);
    defer client.deinit();
    try client.addPage(
        \\{"results":[
        \\{"name":"//monitoring.googleapis.com/projects/acme-prod/alertPolicies/123","assetType":"monitoring.googleapis.com/AlertPolicy","project":"projects/123","location":"global"},
        \\{"name":"//monitoring.googleapis.com/projects/acme-prod/dashboards/456","assetType":"monitoring.googleapis.com/Dashboard","project":"projects/123","location":"global"},
        \\{"name":"//monitoring.googleapis.com/projects/acme-prod/notificationChannels/789","assetType":"monitoring.googleapis.com/NotificationChannel","project":"projects/123","location":"global"},
        \\{"name":"//monitoring.googleapis.com/projects/acme-prod/uptimeCheckConfigs/abc","assetType":"monitoring.googleapis.com/UptimeCheckConfig","project":"projects/123","location":"global"}
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
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.monitoring.AlertPolicy") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.monitoring.Dashboard") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.monitoring.NotificationChannel") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.monitoring.UptimeCheck") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.monitoring.ServiceLevelObjective") == null);
}

test "Monitoring estimate subtracts free uptime executions and prices alert references" {
    const prices = [_]ziac.cost.SkuPrice{
        .{ .sku_id = "uptime-executions", .region = "global", .unit = "1,000 executions", .unit_quantity = 1_000, .unit_price_micros = 300_000 },
        .{ .sku_id = "alert-metric-references", .region = "global", .unit = "metric reference month", .unit_quantity = 1, .unit_price_micros = 350_000 },
    };
    const estimate = try ziac.cost.monitoringConfigurationEstimate(&prices, .{
        .resource_id = "ziac.monitoring.prod",
        .uptime_execution_sku_id = "uptime-executions",
        .alert_metric_reference_sku_id = "alert-metric-references",
        .uptime_executions = 1_500_000,
        .free_uptime_executions = 1_000_000,
        .alert_metric_reference_months = 2,
        .observed_at_millis = 7,
    });
    try std.testing.expectEqual(@as(?i64, 150_700_000), estimate.amount_micros);
    try std.testing.expectEqual(ziac.cost.Origin.configuration_estimate, estimate.origin);
    try std.testing.expect(!estimate.provenance.is_billing_export);
}

test "Monitoring local qualification records import refresh no-op and cleanup evidence" {
    var topology = try buildTopology();
    defer topology.deinit();
    var remote = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer remote.deinit();
    var providers = ziac.provider.ProviderRegistry{};
    providers.register(.gcp, remote.provider());
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    var create_plan = try ziac.plan.buildPlan(std.testing.allocator, &topology.graph, &state);
    defer create_plan.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &create_plan, &state, providers, .{});

    var imported_remote = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer imported_remote.deinit();
    var imported_providers = ziac.provider.ProviderRegistry{};
    imported_providers.register(.gcp, imported_remote.provider());
    var imported_state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer imported_state.deinit();
    for (topology.graph.resources.items) |node| {
        const record = state.get(node.id) orelse return error.MissingRecord;
        try ziac.importer.importResource(std.testing.allocator, node, record.physical_id orelse return error.MissingRecord, &imported_state, imported_providers, null);
    }
    var refreshed = try ziac.plan.buildRefreshedPlan(std.testing.allocator, &topology.graph, &imported_state, imported_providers);
    defer refreshed.deinit();
    for (refreshed.operations) |item| try std.testing.expectEqual(ziac.plan.OperationKind.noop, item.kind);
    var destroy = try ziac.plan.buildDestroyPlan(std.testing.allocator, &state);
    defer destroy.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &destroy, &state, providers, .{ .destructive_confirmation = true });

    var receipt = try ziac.gcp.monitoring_qualification.serializeLocalAlloc(std.testing.allocator, &topology.graph, .{
        .created = remote.creates,
        .imported = imported_remote.imports,
        .no_op = refreshed.operations.len,
        .deleted = remote.deletes,
    });
    defer receipt.deinit();
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"schema\":\"ziac.gcp.monitoring-qualification.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"authenticated\":false") != null);
}

const Topology = struct {
    graph: ziac.ResourceGraph,
    fn deinit(self: *Topology) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

fn buildTopology() !Topology {
    const provider = ziac.gcp.ProviderConfig{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
    var channel = try ziac.gcp.monitoring.NotificationChannel.build(std.testing.allocator, provider, .{
        .name = "platform-email",
        .display_name = "Platform email",
        .type = "email",
        .labels = &.{.{ .key = "email_address", .value = "platform@example.com" }},
    });
    defer channel.deinit(std.testing.allocator);
    var base = ziac.ResourceGraph.init(std.testing.allocator);
    defer base.deinit();
    try base.addResource(channel.node);
    const channels = [_]ziac.PublicOutput([]const u8){channel.name};
    var observability = try ziac.gcp.ServiceObservability.build(std.testing.allocator, provider, .{
        .base_graph = &base,
        .name = "global-api",
        .display_name = "Global API",
        .service_kind = .{ .cloud_run = .{ .service_name = "global-api", .location = "europe-west1" } },
        .endpoint = .{ .host = "api.example.com", .path = "/healthz" },
        .notification_channels = &channels,
        .latency = .{ .goal = 0.99, .threshold_seconds = 0.5 },
        .protect = false,
    });
    defer observability.deinit();
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    errdefer graph.deinit();
    try graph.appendGraph(&observability.graph);
    return .{ .graph = graph };
}

fn contains(values: []const []const u8, expected: []const u8) bool {
    for (values) |present| if (std.mem.eql(u8, present, expected)) return true;
    return false;
}
