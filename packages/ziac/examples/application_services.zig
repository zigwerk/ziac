const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{
    .project_id = "example-project",
    .primary_region = "europe-west1",
};

fn build(allocator: std.mem.Allocator) !ziac.gcp.ParameterBundle {
    var workflow = try ziac.gcp.WorkflowProgram.build(allocator, provider, .{
        .name = "global-rollout",
        .source_contents = "main:\n  return: ready\n",
        .service_account = ziac.PublicOutput([]const u8).known("projects/example-project/serviceAccounts/workflows@example-project.iam.gserviceaccount.com"),
    });
    defer workflow.deinit();

    var gateway = try ziac.gcp.ManagedApiGateway.build(allocator, provider, .{
        .base_graph = &workflow.graph,
        .name = "public-api",
        .api_id = "public-api",
        .config_id = "release-1",
        .gateway_id = "public-api",
        .document = .{
            .path = "openapi.yaml",
            .contents = secretReference("api-spec"),
            .sha256 = payload_digest,
        },
    });
    defer gateway.deinit();

    var realm = try ziac.gcp.IdentityRealm.build(allocator, provider, .{
        .base_graph = &gateway.graph,
        .name = "customers",
        .realm = .{ .tenant = .{
            .tenant_id = "customers",
            .display_name = "Customers",
        } },
        .oidc_providers = &.{.{
            .provider_id = "oidc.customers",
            .display_name = "Customer identity",
            .issuer = "https://identity.example.com",
            .client_id = "ziac-example",
            .client_secret = secretReference("oidc-client"),
        }},
    });
    defer realm.deinit();

    return ziac.gcp.ParameterBundle.build(allocator, provider, .{
        .base_graph = &realm.graph,
        .name = "runtime-config",
        .target = .{ .parameter = .{
            .parameter_id = "runtime-config",
            .location = "global",
            .format = .json,
        } },
        .versions = &.{.{
            .version_id = "release-1",
            .payload = secretReference("runtime-config"),
            .payload_sha256 = payload_digest,
        }},
    });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var platform = try build(allocator);
    defer platform.deinit();
    var permissions = try ziac.gcp.intelligence.synthesizePermissionPlan(allocator, &platform.graph);
    defer permissions.deinit(allocator);
    std.debug.print("application services: {d} resources, {d} deployer permissions\n", .{
        platform.graph.resources.items.len,
        permissions.deployer_permissions.len,
    });
}

test "application-services example compiles orchestration gateway identity and configuration" {
    var platform = try build(std.testing.allocator);
    defer platform.deinit();
    try platform.graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 8), platform.graph.resources.items.len);
}

const payload_digest = "344e4b2f7f15b76b5606be45d8031fc43f473f8d63f0e02c61dbf89a97f85e69";

fn secretReference(name: []const u8) ziac.SecretOutput(ziac.value.SecretReference) {
    return .known(.{ .provider = "gcp-secret-manager", .resource = name, .version = "1" });
}
