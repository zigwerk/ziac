const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
const digest = "4f14a29c7a1c9cc167faba9f489d2cbf7e5fe7f51f9d8a47f8255a8b79fcb6f1";

test "application service components compose workflow gateway identity and parameter graphs" {
    var workflow = try ziac.gcp.WorkflowProgram.build(std.testing.allocator, provider, .{
        .name = "global-rollout",
        .source_contents = "main:\n  return: ok\n",
        .service_account = ziac.PublicOutput([]const u8).known("projects/ziac-dev/serviceAccounts/workflows@ziac-dev.iam.gserviceaccount.com"),
    });
    defer workflow.deinit();
    try std.testing.expectEqual(@as(usize, 1), workflow.graph.resources.items.len);

    var gateway = try ziac.gcp.ManagedApiGateway.build(std.testing.allocator, provider, .{
        .name = "global-api",
        .api_id = "global-api",
        .config_id = "release-4f14",
        .gateway_id = "global",
        .document = .{ .path = "openapi.yaml", .contents = secret(), .sha256 = digest },
        .management_members = &.{.{ .name = "platform-viewer", .role = "roles/apigateway.viewer", .member = "group:platform@example.com" }},
    });
    defer gateway.deinit();
    try std.testing.expectEqual(@as(usize, 4), gateway.graph.resources.items.len);
    try std.testing.expect(gateway.default_hostname == .resource_ref);

    var identity = try ziac.gcp.IdentityRealm.build(std.testing.allocator, provider, .{
        .name = "enterprise",
        .realm = .{ .tenant = .{ .tenant_id = "enterprise", .display_name = "Enterprise" } },
        .oidc_providers = &.{.{
            .provider_id = "oidc.customer",
            .display_name = "Customer",
            .issuer = "https://identity.example.com",
            .client_id = "enterprise",
            .client_secret = secret(),
        }},
    });
    defer identity.deinit();
    try std.testing.expectEqual(@as(usize, 2), identity.graph.resources.items.len);

    var bundle = try ziac.gcp.ParameterBundle.build(std.testing.allocator, provider, .{
        .name = "runtime",
        .target = .{ .parameter = .{ .parameter_id = "runtime-config", .format = .json } },
        .versions = &.{
            .{ .version_id = "release-1", .payload = secret(), .payload_sha256 = digest },
            .{ .version_id = "release-2", .payload = secret(), .payload_sha256 = "5f14a29c7a1c9cc167faba9f489d2cbf7e5fe7f51f9d8a47f8255a8b79fcb6f2" },
        },
    });
    defer bundle.deinit();
    try std.testing.expectEqual(@as(usize, 3), bundle.graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 2), bundle.version_names.len);
}

test "application service components reject duplicate versions and unsafe component identity" {
    try std.testing.expectError(error.DuplicateVersion, ziac.gcp.ParameterBundle.build(std.testing.allocator, provider, .{
        .name = "runtime",
        .target = .{ .template = .{ .template_id = "runtime-template", .format = .yaml } },
        .versions = &.{
            .{ .version_id = "release-1", .payload = secret(), .payload_sha256 = digest },
            .{ .version_id = "release-1", .payload = secret(), .payload_sha256 = digest },
        },
    }));
    try std.testing.expectError(error.InvalidComponentName, ziac.gcp.ManagedApiGateway.build(std.testing.allocator, provider, .{
        .name = "bad/name",
        .api_id = "global-api",
        .config_id = "release-4f14",
        .gateway_id = "global",
        .document = .{ .path = "openapi.yaml", .contents = secret(), .sha256 = digest },
    }));
}

fn secret() ziac.SecretOutput(ziac.value.SecretReference) {
    return .known(.{ .provider = "gcp-secret-manager", .resource = "projects/ziac-dev/secrets/application-source", .version = "1" });
}
