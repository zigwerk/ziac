const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
};

test "application services synthesize exact APIs permissions and runtime access" {
    var platform = try buildApplicationPlatform(true, true);
    defer platform.deinit();

    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &platform.graph);
    defer requirements.deinit(std.testing.allocator);
    try std.testing.expect(contains(requirements.apis, "workflows.googleapis.com"));
    try std.testing.expect(contains(requirements.apis, "apigateway.googleapis.com"));
    try std.testing.expect(contains(requirements.apis, "identitytoolkit.googleapis.com"));
    try std.testing.expect(contains(requirements.apis, "parametermanager.googleapis.com"));
    try std.testing.expect(requirements.hasPermission("workflows.workflows.create"));
    try std.testing.expect(requirements.hasPermission("apigateway.apis.create"));
    try std.testing.expect(requirements.hasPermission("apigateway.apiconfigs.create"));
    try std.testing.expect(requirements.hasPermission("apigateway.gateways.create"));
    try std.testing.expect(requirements.hasPermission("identitytoolkit.tenants.create"));
    try std.testing.expect(requirements.hasPermission("identitytoolkit.oauthIdpConfigs.create"));
    try std.testing.expect(requirements.hasPermission("parametermanager.parameters.create"));
    try std.testing.expect(requirements.hasPermission("parametermanager.parameterVersions.create"));

    var permission_plan = try ziac.gcp.intelligence.synthesizePermissionPlan(std.testing.allocator, &platform.graph);
    defer permission_plan.deinit(std.testing.allocator);
    try std.testing.expect(permission_plan.hasPermission(.runtime, "workflows.executions.create"));
    try std.testing.expect(permission_plan.hasPermission(.runtime, "parametermanager.parameterVersions.render"));
}

test "application services visual artifact exposes topology without secret material" {
    var platform = try buildApplicationPlatform(true, true);
    defer platform.deinit();
    var artifact = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &platform.graph, null, .{
        .stack = "application-platform",
        .stage = "prod",
        .created_at_millis = 7,
    });
    defer artifact.deinit();

    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"workflow\":{\"kind\":\"workflow\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"api_gateway\":{\"kind\":\"api\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"api_gateway\":{\"kind\":\"config\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"api_gateway\":{\"kind\":\"gateway\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"identity\":{\"kind\":\"tenant\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"identity\":{\"kind\":\"oidc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"parameter_manager\":{\"kind\":\"parameter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"parameter_manager\":{\"kind\":\"parameter_version\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "344e4b2f7f15b76b5606be45d8031fc43f473f8d63f0e02c61dbf89a97f85e69") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "openapi: 3.0.0") == null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "super-secret-client") == null);
}

test "estate scan maps only officially supported application-service asset identities" {
    var client = ziac.estate.ScriptedClient.init(std.testing.allocator);
    defer client.deinit();
    try client.addPage(
        \\{"results":[
        \\{"name":"//workflows.googleapis.com/projects/acme-prod/locations/europe-west1/workflows/global-rollout","assetType":"workflows.googleapis.com/Workflow","project":"projects/123","location":"europe-west1","displayName":"global-rollout"},
        \\{"name":"//apigateway.googleapis.com/projects/acme-prod/locations/global/apis/global-api","assetType":"apigateway.googleapis.com/Api","project":"projects/123","location":"global","displayName":"global-api"},
        \\{"name":"//apigateway.googleapis.com/projects/acme-prod/locations/global/apis/global-api/configs/release-1","assetType":"apigateway.googleapis.com/ApiConfig","project":"projects/123","location":"global","displayName":"release-1"},
        \\{"name":"//apigateway.googleapis.com/projects/acme-prod/locations/europe-west1/gateways/global-api","assetType":"apigateway.googleapis.com/Gateway","project":"projects/123","location":"europe-west1","displayName":"global-api"},
        \\{"name":"//identitytoolkit.googleapis.com/projects/acme-prod/config","assetType":"identitytoolkit.googleapis.com/Config","project":"projects/123","location":"global","displayName":"config"},
        \\{"name":"//identitytoolkit.googleapis.com/projects/acme-prod/tenants/workforce","assetType":"identitytoolkit.googleapis.com/Tenant","project":"projects/123","location":"global","displayName":"workforce"},
        \\{"name":"//identitytoolkit.googleapis.com/projects/acme-prod/tenants/workforce/oauthIdpConfigs/oidc.workforce","assetType":"identitytoolkit.googleapis.com/OauthIdpConfig","project":"projects/123","location":"global","displayName":"oidc.workforce"},
        \\{"name":"//identitytoolkit.googleapis.com/projects/acme-prod/inboundSamlConfigs/saml.workforce","assetType":"identitytoolkit.googleapis.com/InboundSamlConfig","project":"projects/123","location":"global","displayName":"saml.workforce"},
        \\{"name":"//parametermanager.googleapis.com/projects/acme-prod/locations/global/parameters/application-config","assetType":"parametermanager.googleapis.com/Parameter","project":"projects/123","location":"global","displayName":"application-config"},
        \\{"name":"//parametermanager.googleapis.com/projects/acme-prod/locations/global/parameters/application-config/versions/release-1","assetType":"parametermanager.googleapis.com/ParameterVersion","project":"projects/123","location":"global","displayName":"release-1"},
        \\{"name":"//parametermanager.googleapis.com/projects/acme-prod/locations/global/templates/rendered","assetType":"parametermanager.googleapis.com/Template","project":"projects/123","location":"global","displayName":"rendered"}
        \\]}
    );
    var scan = try ziac.estate.scanAlloc(std.testing.allocator, client.client(), .{
        .identity = .{ .provider = .google, .verified = true, .subject = "subject" },
        .entitlement = .pro,
        .connection = .{ .status = .connected, .project_id = "acme-prod" },
        .observed_at_millis = 1_783_764_000_000,
    });
    defer scan.deinit();

    try std.testing.expectEqual(@as(usize, 11), scan.resource_count);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.workflows.Workflow") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.apigateway.ApiConfig") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.identity.TenantOAuthIdpConfig") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.identity.ProjectInboundSamlConfig") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.parametermanager.ParameterVersion") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "\"physical_id\":\"projects/acme-prod/locations/global/apis/global-api/configs/release-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "\"type\":\"gcp.asset.Resource\",\"logical_id\":\"rendered\"") != null);
}

test "application-service estimates preserve explicit workload assumptions" {
    const prices = [_]ziac.cost.SkuPrice{
        .{ .sku_id = "workflow-internal", .region = "global", .unit = "1k steps", .unit_quantity = 1_000, .unit_price_micros = 10_000 },
        .{ .sku_id = "workflow-external", .region = "global", .unit = "1k steps", .unit_quantity = 1_000, .unit_price_micros = 25_000 },
        .{ .sku_id = "gateway-calls", .region = "global", .unit = "1m calls", .unit_quantity = 1_000_000, .unit_price_micros = 3_000_000 },
        .{ .sku_id = "identity-tier1", .region = "global", .unit = "MAU", .unit_quantity = 1, .unit_price_micros = 5_500 },
        .{ .sku_id = "identity-tier2", .region = "global", .unit = "MAU", .unit_quantity = 1, .unit_price_micros = 15_000 },
    };
    const estimate = try ziac.cost.applicationServicesConfigurationEstimate(&prices, .{
        .resource_id = "gcp.application.Platform.global-api",
        .region = "global",
        .workflow_internal_steps_sku_id = "workflow-internal",
        .workflow_external_steps_sku_id = "workflow-external",
        .gateway_calls_sku_id = "gateway-calls",
        .identity_tier1_mau_sku_id = "identity-tier1",
        .identity_tier2_mau_sku_id = "identity-tier2",
        .workflow_internal_steps = 10_000,
        .workflow_external_steps = 2_000,
        .gateway_calls = 4_000_000,
        .identity_tier1_mau = 1_000,
        .identity_tier2_mau = 100,
        .observed_at_millis = 7,
    });
    try std.testing.expectEqual(@as(?i64, 19_150_000), estimate.amount_micros);
    try std.testing.expectEqual(ziac.cost.Origin.configuration_estimate, estimate.origin);
    try std.testing.expect(!estimate.provenance.is_billing_export);
}

test "application platform applies imports refreshes no-op and emits local qualification evidence" {
    var platform = try buildApplicationPlatform(false, false);
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
    var imported_plan = try ziac.plan.buildPlan(std.testing.allocator, &platform.graph, &imported_state);
    defer imported_plan.deinit();
    for (imported_plan.operations) |operation| try std.testing.expectEqual(ziac.plan.OperationKind.noop, operation.kind);
    var refreshed_plan = try ziac.plan.buildRefreshedPlan(std.testing.allocator, &platform.graph, &imported_state, imported_providers);
    defer refreshed_plan.deinit();
    for (refreshed_plan.operations) |operation| try std.testing.expectEqual(ziac.plan.OperationKind.noop, operation.kind);

    var destroy_plan = try ziac.plan.buildDestroyPlan(std.testing.allocator, &state);
    defer destroy_plan.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &destroy_plan, &state, providers, .{ .destructive_confirmation = true });

    var retained: usize = 0;
    for (platform.graph.resources.items) |node| retained += @intFromBool(node.lifecycle.retain_on_delete);
    var receipt = try ziac.gcp.application_services_qualification.serializeLocalAlloc(std.testing.allocator, &platform.graph, .{
        .created = remote.creates,
        .imported = imported_remote.imports,
        .no_op = imported_plan.operations.len,
        .retained = retained,
        .deleted = remote.deletes,
    });
    defer receipt.deinit();
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"schema\":\"ziac.gcp.application-services-qualification.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"status\":\"passed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"authenticated\":false") != null);
}

fn buildApplicationPlatform(protect: bool, retain_on_delete: bool) !ziac.gcp.ParameterBundle {
    var workflow = try ziac.gcp.WorkflowProgram.build(std.testing.allocator, provider, .{
        .name = "global-rollout",
        .source_contents = "main:\n  return: ok\n",
        .service_account = ziac.PublicOutput([]const u8).known("projects/ziac-dev/serviceAccounts/workflows@ziac-dev.iam.gserviceaccount.com"),
        .protect = protect,
        .retain_on_delete = retain_on_delete,
    });
    defer workflow.deinit();
    var gateway = try ziac.gcp.ManagedApiGateway.build(std.testing.allocator, provider, .{
        .base_graph = &workflow.graph,
        .name = "global-api",
        .api_id = "global-api",
        .config_id = "release-1",
        .gateway_id = "global-api",
        .document = .{ .path = "openapi.yaml", .contents = secretReference("api-source"), .sha256 = payload_digest },
        .management_members = &.{.{ .name = "runtime-invoker", .role = "roles/workflows.invoker", .member = "serviceAccount:runtime@ziac-dev.iam.gserviceaccount.com" }},
        .protect = protect,
        .retain_on_delete = retain_on_delete,
    });
    defer gateway.deinit();
    var identity = try ziac.gcp.IdentityRealm.build(std.testing.allocator, provider, .{
        .base_graph = &gateway.graph,
        .name = "workforce",
        .realm = .{ .tenant = .{ .tenant_id = "workforce", .display_name = "Workforce", .protect = protect, .retain_on_delete = retain_on_delete } },
        .oidc_providers = &.{.{
            .provider_id = "oidc.workforce",
            .display_name = "Workforce",
            .issuer = "https://identity.example.com",
            .client_id = "ziac",
            .client_secret = secretReference("oidc-client"),
        }},
    });
    defer identity.deinit();
    var bundle = try ziac.gcp.ParameterBundle.build(std.testing.allocator, provider, .{
        .base_graph = &identity.graph,
        .name = "application-config",
        .target = .{ .parameter = .{
            .parameter_id = "application-config",
            .location = "global",
            .format = .json,
            .protect = protect,
            .retain_on_delete = retain_on_delete,
        } },
        .versions = &.{.{
            .version_id = "release-1",
            .payload = secretReference("application-config"),
            .payload_sha256 = payload_digest,
            .protect = protect,
            .retain_on_delete = retain_on_delete,
        }},
    });
    var runtime_member = try ziac.gcp.iam.ProjectMember.build(std.testing.allocator, provider, .{
        .name = "parameter-runtime",
        .role = "roles/parametermanager.parameterAccessor",
        .member = "serviceAccount:runtime@ziac-dev.iam.gserviceaccount.com",
    });
    defer runtime_member.deinit(std.testing.allocator);
    try bundle.graph.addResource(runtime_member.node);
    try bundle.graph.validateAcyclic();
    return bundle;
}

const payload_digest = "344e4b2f7f15b76b5606be45d8031fc43f473f8d63f0e02c61dbf89a97f85e69";

fn secretReference(name: []const u8) ziac.SecretOutput(ziac.value.SecretReference) {
    return .known(.{ .provider = "gcp-secret-manager", .resource = name, .version = "1" });
}

fn contains(values: []const []const u8, expected: []const u8) bool {
    for (values) |present| if (std.mem.eql(u8, present, expected)) return true;
    return false;
}
