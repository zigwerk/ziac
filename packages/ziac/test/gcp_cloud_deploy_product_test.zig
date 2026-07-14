const std = @import("std");
const ziac = @import("ziac");

test "Cloud Deploy graph synthesizes exact API and lifecycle permissions" {
    var delivery = try globalDelivery();
    defer delivery.deinit();
    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &delivery.graph);
    defer requirements.deinit(std.testing.allocator);

    try std.testing.expect(contains(requirements.apis, "clouddeploy.googleapis.com"));
    try std.testing.expect(requirements.hasPermission("clouddeploy.deliveryPipelines.create"));
    try std.testing.expect(requirements.hasPermission("clouddeploy.targets.create"));
    try std.testing.expect(requirements.hasPermission("clouddeploy.automations.create"));
    try std.testing.expect(requirements.hasPermission("clouddeploy.deployPolicies.create"));
    try std.testing.expect(requirements.hasPermission("iam.serviceAccounts.actAs"));
}

test "Cloud Deploy canvas exposes delivery topology and resource metadata" {
    var delivery = try globalDelivery();
    defer delivery.deinit();
    var artifact = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &delivery.graph, null, .{
        .stack = "delivery",
        .stage = "prod",
        .created_at_millis = 7,
    });
    defer artifact.deinit();

    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"cloud_deploy\":{\"kind\":\"target\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"cloud_deploy\":{\"kind\":\"delivery_pipeline\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"cloud_deploy\":{\"kind\":\"automation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"cloud_deploy\":{\"kind\":\"deploy_policy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"delivery_stage\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"pipeline_automation\"") != null);
}

test "estate scan separates managed Cloud Deploy resources from observed execution history" {
    var client = ziac.estate.ScriptedClient.init(std.testing.allocator);
    defer client.deinit();
    try client.addPage(
        \\{"results":[
        \\{"name":"//clouddeploy.googleapis.com/projects/acme-prod/locations/europe-west1/deliveryPipelines/api","assetType":"clouddeploy.googleapis.com/DeliveryPipeline","project":"projects/123","location":"europe-west1"},
        \\{"name":"//clouddeploy.googleapis.com/projects/acme-prod/locations/europe-west1/targets/prod","assetType":"clouddeploy.googleapis.com/Target","project":"projects/123","location":"europe-west1"},
        \\{"name":"//clouddeploy.googleapis.com/projects/acme-prod/locations/europe-west1/customTargetTypes/edge","assetType":"clouddeploy.googleapis.com/CustomTargetType","project":"projects/123","location":"europe-west1"},
        \\{"name":"//clouddeploy.googleapis.com/projects/acme-prod/locations/europe-west1/deliveryPipelines/api/automations/progress","assetType":"clouddeploy.googleapis.com/Automation","project":"projects/123","location":"europe-west1"},
        \\{"name":"//clouddeploy.googleapis.com/projects/acme-prod/locations/europe-west1/deployPolicies/freeze","assetType":"clouddeploy.googleapis.com/DeployPolicy","project":"projects/123","location":"europe-west1"},
        \\{"name":"//clouddeploy.googleapis.com/projects/acme-prod/locations/europe-west1/deliveryPipelines/api/releases/r1","assetType":"clouddeploy.googleapis.com/Release","project":"projects/123","location":"europe-west1"},
        \\{"name":"//clouddeploy.googleapis.com/projects/acme-prod/locations/europe-west1/deliveryPipelines/api/releases/r1/rollouts/prod-r1","assetType":"clouddeploy.googleapis.com/Rollout","project":"projects/123","location":"europe-west1"},
        \\{"name":"//clouddeploy.googleapis.com/projects/acme-prod/locations/europe-west1/deliveryPipelines/api/automations/progress/automationRuns/run-1","assetType":"clouddeploy.googleapis.com/AutomationRun","project":"projects/123","location":"europe-west1"},
        \\{"name":"//clouddeploy.googleapis.com/projects/acme-prod/locations/europe-west1/deliveryPipelines/api/releases/r1/rollouts/prod-r1/jobRuns/job-1","assetType":"clouddeploy.googleapis.com/JobRun","project":"projects/123","location":"europe-west1"}
        \\]}
    );
    var scan = try ziac.estate.scanAlloc(std.testing.allocator, client.client(), .{
        .identity = .{ .provider = .google, .verified = true, .subject = "subject" },
        .entitlement = .pro,
        .connection = .{ .status = .connected, .project_id = "acme-prod" },
        .observed_at_millis = 1_783_764_000_000,
    });
    defer scan.deinit();

    try std.testing.expectEqual(@as(usize, 9), scan.resource_count);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.deploy.DeliveryPipeline") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.deploy.Target") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.deploy.CustomTargetType") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.deploy.Automation") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.deploy.DeployPolicy") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.asset.Resource") != null);
}

test "Cloud Deploy estimate charges only active multi-target pipelines above the free allowance" {
    const prices = [_]ziac.cost.SkuPrice{
        .{ .sku_id = "active-pipeline", .region = "global", .unit = "pipeline month", .unit_quantity = 1, .unit_price_micros = 5_000_000 },
        .{ .sku_id = "build-minutes", .region = "europe-west1", .unit = "minute", .unit_quantity = 1, .unit_price_micros = 3_000 },
    };
    const estimate = try ziac.cost.cloudDeployConfigurationEstimate(&prices, .{
        .resource_id = "ziac.delivery.api",
        .region = "europe-west1",
        .active_pipeline_sku_id = "active-pipeline",
        .underlying_build_minute_sku_id = "build-minutes",
        .active_multi_target_pipelines = 3,
        .free_active_multi_target_pipelines = 1,
        .underlying_build_minutes = 100,
        .observed_at_millis = 7,
    });
    try std.testing.expectEqual(@as(?i64, 10_300_000), estimate.amount_micros);
    try std.testing.expectEqual(ziac.cost.Origin.configuration_estimate, estimate.origin);
}

test "Cloud Deploy local qualification records import refresh no-op and cleanup" {
    var delivery = try globalDelivery();
    defer delivery.deinit();
    var remote = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer remote.deinit();
    var providers = ziac.provider.ProviderRegistry{};
    providers.register(.gcp, remote.provider());
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    var create_plan = try ziac.plan.buildPlan(std.testing.allocator, &delivery.graph, &state);
    defer create_plan.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &create_plan, &state, providers, .{});

    var imported_remote = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer imported_remote.deinit();
    var imported_providers = ziac.provider.ProviderRegistry{};
    imported_providers.register(.gcp, imported_remote.provider());
    var imported_state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer imported_state.deinit();
    for (delivery.graph.resources.items) |node| {
        const record = state.get(node.id) orelse return error.MissingRecord;
        try ziac.importer.importResource(std.testing.allocator, node, record.physical_id orelse return error.MissingRecord, &imported_state, imported_providers, null);
    }
    var refreshed = try ziac.plan.buildRefreshedPlan(std.testing.allocator, &delivery.graph, &imported_state, imported_providers);
    defer refreshed.deinit();
    for (refreshed.operations) |item| try std.testing.expectEqual(ziac.plan.OperationKind.noop, item.kind);
    var destroy = try ziac.plan.buildDestroyPlan(std.testing.allocator, &state);
    defer destroy.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &destroy, &state, providers, .{ .destructive_confirmation = true });

    var receipt = try ziac.gcp.cloud_deploy_qualification.serializeLocalAlloc(std.testing.allocator, &delivery.graph, .{
        .created = remote.creates,
        .imported = imported_remote.imports,
        .no_op = refreshed.operations.len,
        .deleted = remote.deletes,
    });
    defer receipt.deinit();
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"schema\":\"ziac.gcp.cloud-deploy-qualification.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"authenticated\":false") != null);
}

fn globalDelivery() !ziac.gcp.GlobalCloudRunDelivery {
    return ziac.gcp.GlobalCloudRunDelivery.build(std.testing.allocator, .{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
        .service_regions = &.{ "europe-west1", "us-central1", "asia-northeast1" },
        .network_tier = .premium,
    }, .{
        .name = "api",
        .location = "europe-west1",
        .regions = &.{
            .{ .region = "europe-west1", .profile = "eu" },
            .{ .region = "us-central1", .profile = "us" },
            .{ .region = "asia-northeast1", .profile = "asia", .require_approval = true },
        },
        .service_account = "deploy@ziac-dev.iam.gserviceaccount.com",
        .canary_percentages = &.{ 10, 50 },
        .automation = .{ .enabled = true, .wait_seconds = 60, .repair_attempts = 3 },
        .production_freeze = .{ .target_region = "asia-northeast1", .time_zone = "UTC", .days = &.{ .saturday, .sunday } },
        .protect = false,
    });
}

fn contains(values: []const []const u8, expected: []const u8) bool {
    for (values) |present| if (std.mem.eql(u8, present, expected)) return true;
    return false;
}
