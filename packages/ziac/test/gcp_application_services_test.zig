const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
};

const secret_source = ziac.SecretOutput(ziac.value.SecretReference).known(.{
    .provider = "gcp-secret-manager",
    .resource = "projects/ziac-dev/secrets/application-source",
    .version = "1",
});

test "application services declarations compile all M67 resources into one graph" {
    var workflow = try ziac.gcp.workflows.Workflow.build(std.testing.allocator, provider, .{
        .workflow_id = "global-rollout",
        .source_contents = "main:\n  steps:\n    - done:\n        return: ok\n",
        .service_account = ziac.PublicOutput([]const u8).known("projects/ziac-dev/serviceAccounts/workflows@ziac-dev.iam.gserviceaccount.com"),
        .call_log_level = .errors_only,
        .execution_history = .detailed,
        .user_env = &.{.{ .key = "ENVIRONMENT", .value = "prod" }},
    });
    defer workflow.deinit(std.testing.allocator);

    var api = try ziac.gcp.api_gateway.Api.build(std.testing.allocator, provider, .{
        .api_id = "global-api",
        .display_name = "Global API",
    });
    defer api.deinit(std.testing.allocator);
    var config = try ziac.gcp.api_gateway.ApiConfig.build(std.testing.allocator, provider, .{
        .api = api.name,
        .api_id = "global-api",
        .config_id = "v1-4f14",
        .display_name = "Release v1",
        .documents = &.{.{
            .path = "openapi.yaml",
            .contents = secret_source,
            .sha256 = "4f14a29c7a1c9cc167faba9f489d2cbf7e5fe7f51f9d8a47f8255a8b79fcb6f1",
        }},
    });
    defer config.deinit(std.testing.allocator);
    var gateway = try ziac.gcp.api_gateway.Gateway.build(std.testing.allocator, provider, .{
        .gateway_id = "global",
        .api_config = config.name,
        .api_id = "global-api",
        .config_id = "v1-4f14",
    });
    defer gateway.deinit(std.testing.allocator);
    var api_member = try ziac.gcp.api_gateway.ApiIamMember.build(std.testing.allocator, provider, .{
        .name = "api-viewer",
        .resource_name = api.name,
        .api_id = "global-api",
        .role = "roles/apigateway.viewer",
        .member = "group:platform@example.com",
    });
    defer api_member.deinit(std.testing.allocator);
    var config_member = try ziac.gcp.api_gateway.ApiConfigIamMember.build(std.testing.allocator, provider, .{
        .name = "config-viewer",
        .resource_name = config.name,
        .api_id = "global-api",
        .config_id = "v1-4f14",
        .role = "roles/apigateway.viewer",
        .member = "group:platform@example.com",
    });
    defer config_member.deinit(std.testing.allocator);
    var gateway_member = try ziac.gcp.api_gateway.GatewayIamMember.build(std.testing.allocator, provider, .{
        .name = "gateway-viewer",
        .resource_name = gateway.name,
        .location = "europe-west1",
        .gateway_id = "global",
        .role = "roles/apigateway.viewer",
        .member = "group:platform@example.com",
    });
    defer gateway_member.deinit(std.testing.allocator);

    var project_config = try ziac.gcp.identity.ProjectConfig.build(std.testing.allocator, provider, .{
        .authorized_domains = &.{ "app.example.com", "localhost" },
        .email_privacy = true,
        .multi_tenant = true,
    });
    defer project_config.deinit(std.testing.allocator);
    var tenant = try ziac.gcp.identity.Tenant.build(std.testing.allocator, provider, .{
        .tenant_id = "enterprise",
        .display_name = "Enterprise users",
        .allow_password_signup = false,
    });
    defer tenant.deinit(std.testing.allocator);
    var project_oidc = try ziac.gcp.identity.ProjectOAuthIdpConfig.build(std.testing.allocator, provider, .{
        .provider_id = "oidc.workforce",
        .display_name = "Workforce",
        .issuer = "https://identity.example.com",
        .client_id = "ziac",
        .client_secret = secret_source,
    });
    defer project_oidc.deinit(std.testing.allocator);
    var project_saml = try ziac.gcp.identity.ProjectInboundSamlConfig.build(std.testing.allocator, provider, .{
        .provider_id = "saml.workforce",
        .display_name = "Workforce SAML",
        .idp_entity_id = "https://identity.example.com/saml",
        .sso_url = "https://identity.example.com/sso",
        .idp_certificates = &.{"-----BEGIN CERTIFICATE-----\nTEST\n-----END CERTIFICATE-----"},
        .sp_entity_id = "https://app.example.com/saml",
        .callback_uri = "https://app.example.com/__/auth/handler",
        .sp_private_key = secret_source,
    });
    defer project_saml.deinit(std.testing.allocator);
    var tenant_oidc = try ziac.gcp.identity.TenantOAuthIdpConfig.build(std.testing.allocator, provider, .{
        .tenant = tenant.name,
        .tenant_id = "enterprise",
        .provider_id = "oidc.customer",
        .display_name = "Customer OIDC",
        .issuer = "https://customer.example.com",
        .client_id = "enterprise",
        .client_secret = secret_source,
    });
    defer tenant_oidc.deinit(std.testing.allocator);
    var tenant_saml = try ziac.gcp.identity.TenantInboundSamlConfig.build(std.testing.allocator, provider, .{
        .tenant = tenant.name,
        .tenant_id = "enterprise",
        .provider_id = "saml.customer",
        .display_name = "Customer SAML",
        .idp_entity_id = "https://customer.example.com/saml",
        .sso_url = "https://customer.example.com/sso",
        .idp_certificates = &.{"-----BEGIN CERTIFICATE-----\nTEST\n-----END CERTIFICATE-----"},
        .sp_entity_id = "https://app.example.com/saml",
        .callback_uri = "https://app.example.com/__/auth/handler",
        .sp_private_key = secret_source,
    });
    defer tenant_saml.deinit(std.testing.allocator);
    var tenant_member = try ziac.gcp.identity.TenantIamMember.build(std.testing.allocator, provider, .{
        .name = "tenant-admin",
        .tenant = tenant.name,
        .tenant_id = "enterprise",
        .role = "roles/identitytoolkit.admin",
        .member = "group:identity@example.com",
    });
    defer tenant_member.deinit(std.testing.allocator);

    var parameter = try ziac.gcp.parameter_manager.Parameter.build(std.testing.allocator, provider, .{
        .parameter_id = "application-config",
        .format = .json,
    });
    defer parameter.deinit(std.testing.allocator);
    var parameter_version = try ziac.gcp.parameter_manager.ParameterVersion.build(std.testing.allocator, provider, .{
        .parameter = parameter.name,
        .parameter_id = "application-config",
        .version_id = "release-1",
        .payload = secret_source,
        .payload_sha256 = "4f14a29c7a1c9cc167faba9f489d2cbf7e5fe7f51f9d8a47f8255a8b79fcb6f1",
    });
    defer parameter_version.deinit(std.testing.allocator);
    var template = try ziac.gcp.parameter_manager.Template.build(std.testing.allocator, provider, .{
        .template_id = "runtime-template",
        .format = .yaml,
    });
    defer template.deinit(std.testing.allocator);
    var template_version = try ziac.gcp.parameter_manager.TemplateVersion.build(std.testing.allocator, provider, .{
        .template = template.name,
        .template_id = "runtime-template",
        .version_id = "release-1",
        .payload = secret_source,
        .payload_sha256 = "4f14a29c7a1c9cc167faba9f489d2cbf7e5fe7f51f9d8a47f8255a8b79fcb6f1",
    });
    defer template_version.deinit(std.testing.allocator);

    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    for ([_]ziac.ResourceNode{
        workflow.node,       api.node,               config.node,       gateway.node,          api_member.node,  config_member.node, gateway_member.node,
        project_config.node, tenant.node,            project_oidc.node, project_saml.node,     tenant_oidc.node, tenant_saml.node,   tenant_member.node,
        parameter.node,      parameter_version.node, template.node,     template_version.node,
    }) |node| try graph.addResource(node);
    try graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 18), graph.resources.items.len);
    try std.testing.expect(hasDependency(&graph, config.node.id, api.node.id));
    try std.testing.expect(hasDependency(&graph, gateway.node.id, config.node.id));
    try std.testing.expect(hasDependency(&graph, tenant_oidc.node.id, tenant.node.id));
    try std.testing.expect(hasDependency(&graph, parameter_version.node.id, parameter.node.id));
    try std.testing.expect(inputValue(parameter_version.node.inputs, "payload") == .secret_ref);
    try std.testing.expect(parameter_version.node.lifecycle.protect);
    try std.testing.expect(parameter_version.node.lifecycle.retain_on_delete);
    try std.testing.expect(project_config.node.lifecycle.protect);
    try std.testing.expect(project_config.node.lifecycle.retain_on_delete);
}

test "application services reject leaked source ambiguous identity and public payloads" {
    try std.testing.expectError(error.PotentialSecretInSource, ziac.gcp.workflows.Workflow.build(std.testing.allocator, provider, .{
        .workflow_id = "unsafe",
        .source_contents = "main:\n  return: password=sentinel-secret\n",
        .service_account = ziac.PublicOutput([]const u8).known("projects/ziac-dev/serviceAccounts/workflows@ziac-dev.iam.gserviceaccount.com"),
    }));
    try std.testing.expectError(error.InvalidProviderId, ziac.gcp.identity.TenantOAuthIdpConfig.build(std.testing.allocator, provider, .{
        .tenant = ziac.PublicOutput([]const u8).known("projects/other/tenants/enterprise"),
        .tenant_id = "enterprise",
        .provider_id = "google.com",
        .display_name = "Reserved",
        .issuer = "https://identity.example.com",
        .client_id = "ziac",
        .client_secret = secret_source,
    }));
    try std.testing.expectError(error.InvalidDigest, ziac.gcp.parameter_manager.ParameterVersion.build(std.testing.allocator, provider, .{
        .parameter = ziac.PublicOutput([]const u8).known("projects/ziac-dev/locations/global/parameters/application-config"),
        .parameter_id = "application-config",
        .version_id = "release-1",
        .payload = secret_source,
        .payload_sha256 = "not-a-digest",
    }));
}

fn hasDependency(graph: *const ziac.ResourceGraph, from: []const u8, to: []const u8) bool {
    for (graph.dependencies.items) |edge| if (std.mem.eql(u8, edge.from, from) and std.mem.eql(u8, edge.to, to)) return true;
    return false;
}

fn inputValue(input: ziac.value.Value, name: []const u8) ziac.value.Value {
    for (input.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    unreachable;
}
