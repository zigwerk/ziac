const std = @import("std");
const ziac = @import("ziac");

const regions = [_][]const u8{ "europe-west1", "us-central1" };

test "Ziac Cloud bootstrap owns remote state KMS APIs and deployer identity" {
    var program = try ziac.self_host.buildBootstrap(std.testing.allocator, .{
        .project_id = "ziac-cloud-prod",
        .primary_region = regions[0],
        .regions = &regions,
        .state_bucket = "ziac-cloud-prod-state",
    });
    defer program.deinit();
    try program.graph.validateAcyclic();
    try std.testing.expect(hasType(&program.graph, "gcp.storage.BuildBucket"));
    try std.testing.expect(hasType(&program.graph, "gcp.artifact.Repository"));
    try std.testing.expect(hasType(&program.graph, "gcp.kms.KeyRing"));
    try std.testing.expect(hasType(&program.graph, "gcp.kms.CryptoKey"));
    try std.testing.expect(hasType(&program.graph, "gcp.iam.ServiceAccount"));
    try std.testing.expectEqual(@as(usize, 3), countType(&program.graph, "gcp.secret.Secret"));
    for (program.graph.resources.items) |node| try std.testing.expect(ziac.gcp.live_provider.supports(node));
}

test "Ziac Cloud control plane is a global service with explicit secret bindings" {
    var program = try ziac.self_host.buildControlPlane(std.testing.allocator, .{
        .project_id = "ziac-cloud-prod",
        .primary_region = regions[0],
        .regions = &regions,
        .domain = "api.ziac.dev",
        .dns_zone = "ziac-dev",
        .image = "europe-west1-docker.pkg.dev/ziac-cloud-prod/ziac/control-plane@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .database_secret = "projects/ziac-cloud-prod/secrets/database-url/versions/latest",
        .oauth_client_id_secret = "projects/ziac-cloud-prod/secrets/google-oauth-client-id/versions/latest",
        .oauth_client_secret = "projects/ziac-cloud-prod/secrets/google-oauth-client-secret/versions/latest",
        .kms_key = "projects/ziac-cloud-prod/locations/europe-west1/keyRings/ziac-cloud/cryptoKeys/connection-vault",
    });
    defer program.deinit();
    try program.graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 2), countType(&program.graph, "gcp.run.Service"));
    try std.testing.expect(hasSecretEnv(&program.graph, "DATABASE_URL"));
    try std.testing.expect(hasSecretEnv(&program.graph, "GOOGLE_OAUTH_CLIENT_SECRET"));
    for (program.graph.resources.items) |node| try std.testing.expect(ziac.gcp.live_provider.supports(node));
}

test "Ziac Cloud data project owns Cockroach database users secrets and migrations" {
    var program = try ziac.self_host.buildData(std.testing.allocator, .{
        .project_id = "ziac-cloud-prod",
        .primary_region = regions[0],
        .regions = &regions,
        .cluster_id = "8e9f4f46-example-cluster-id",
        .admin_secret_version = "1",
    });
    defer program.deinit();
    try program.graph.validateAcyclic();
    try std.testing.expect(hasType(&program.graph, "cockroach.Database"));
    try std.testing.expect(hasType(&program.graph, "cockroach.SqlUser"));
    try std.testing.expectEqual(@as(usize, 2), countType(&program.graph, "cockroach.Migration"));
    try std.testing.expect(hasType(&program.graph, "gcp.secret.SecretVersion"));
    for (program.graph.resources.items) |node| try std.testing.expect(supported(node));

    const artifact = try ziac.program_format.encodeAlloc(std.testing.allocator, "data", "prod", &program);
    defer std.testing.allocator.free(artifact);
    var decoded = try ziac.program_format.decodeAlloc(std.testing.allocator, artifact, .{ .stack = "data", .stage = "prod" });
    defer decoded.deinit();
    try std.testing.expectEqual(program.graph.resources.items.len, decoded.graph.resources.items.len);
}

test "Ziac Cloud billing worker has authoritative data access without public ingress" {
    var program = try ziac.self_host.buildBilling(std.testing.allocator, .{
        .project_id = "ziac-cloud-prod",
        .region = "europe-west1",
        .image = "europe-west1-docker.pkg.dev/ziac-cloud-prod/ziac/billing@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .billing_project = "ziac-cloud-billing",
        .export_table = "billing_export.gcp_billing_export_resource_v1_123",
        .control_plane_url = "https://api.ziac.dev",
        .database_secret = "projects/ziac-cloud-prod/secrets/database-url/versions/latest",
    });
    defer program.deinit();
    try program.graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 1), countType(&program.graph, "gcp.run.Service"));
    try std.testing.expectEqual(@as(usize, 1), countType(&program.graph, "gcp.scheduler.Job"));
    try std.testing.expect(hasSecretEnv(&program.graph, "DATABASE_URL"));
    for (program.graph.resources.items) |node| try std.testing.expect(ziac.gcp.live_provider.supports(node));
}

fn hasType(graph: *const ziac.ResourceGraph, type_name: []const u8) bool {
    return countType(graph, type_name) > 0;
}

fn supported(node: ziac.ResourceNode) bool {
    return switch (node.provider) {
        .gcp => ziac.gcp.live_provider.supports(node),
        .cockroach => ziac.cockroach.live_provider.supports(node),
        else => false,
    };
}

fn countType(graph: *const ziac.ResourceGraph, type_name: []const u8) usize {
    var count: usize = 0;
    for (graph.resources.items) |node| {
        if (std.mem.eql(u8, node.type_name, type_name)) count += 1;
    }
    return count;
}

fn hasSecretEnv(graph: *const ziac.ResourceGraph, name: []const u8) bool {
    for (graph.resources.items) |node| {
        if (!std.mem.eql(u8, node.type_name, "gcp.run.Service")) continue;
        for (node.inputs.object) |field| {
            if (!std.mem.eql(u8, field.name, "env")) continue;
            for (field.value.list) |entry| {
                var matched = false;
                var secret = false;
                for (entry.object) |env_field| {
                    if (std.mem.eql(u8, env_field.name, "name") and std.mem.eql(u8, env_field.value.string, name)) matched = true;
                    if (std.mem.eql(u8, env_field.name, "secret")) secret = env_field.value.boolean;
                }
                if (matched and secret) return true;
            }
        }
    }
    return false;
}
