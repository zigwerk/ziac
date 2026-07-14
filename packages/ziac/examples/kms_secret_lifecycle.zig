const std = @import("std");
const ziac = @import("ziac");

fn build(allocator: std.mem.Allocator) !ziac.ResourceGraph {
    const provider = ziac.gcp.ProviderConfig{
        .project_id = "example-project",
        .primary_region = "europe-west1",
        .labels = &.{.{ .key = "managed-by", .value = "ziac" }},
    };
    var ring = try ziac.gcp.kms.KeyRing.build(allocator, provider, .{ .name = "app", .location = "europe-west1" });
    defer ring.deinit(allocator);
    var key = try ziac.gcp.kms.CryptoKey.build(allocator, provider, .{
        .name = "application-data",
        .key_ring = ring.name,
        .version_template = .{ .protection_level = .hsm },
        .rotation_period_seconds = 2_592_000,
    });
    defer key.deinit(allocator);
    var version = try ziac.gcp.kms.CryptoKeyVersion.build(allocator, provider, .{ .name = "primary", .crypto_key = key.name });
    defer version.deinit(allocator);
    var key_access = try ziac.gcp.kms.CryptoKeyIamMember.build(allocator, provider, .{
        .name = "runtime-decrypt",
        .crypto_key = key.name,
        .role = "roles/cloudkms.cryptoKeyDecrypter",
        .member = "serviceAccount:runtime@example-project.iam.gserviceaccount.com",
    });
    defer key_access.deinit(allocator);
    const replicas = [_]ziac.gcp.secret_manager.Replica{
        .{ .location = "europe-west1", .kms_key_name = "projects/example-project/locations/europe-west1/keyRings/app/cryptoKeys/application-data" },
        .{ .location = "us-central1", .kms_key_name = "projects/example-project/locations/us-central1/keyRings/app/cryptoKeys/application-data" },
    };
    var secret = try ziac.gcp.secret_manager.Secret.build(allocator, provider, .{
        .name = "database-url",
        .replication = .{ .user_managed = &replicas },
        .topics = &.{"projects/example-project/topics/secret-rotation"},
        .rotation = .{ .next_rotation_time = "2026-08-01T00:00:00Z", .period_seconds = 2_592_000 },
        .version_aliases = &.{.{ .alias = "current", .version = 1 }},
    });
    defer secret.deinit(allocator);
    var secret_version = try ziac.gcp.secret_manager.SecretVersion.build(allocator, provider, .{
        .name = "initial",
        .secret_id = "database-url",
        .source = .{ .provider = "env", .resource = "DATABASE_URL", .version = "1" },
        .source_dependencies = &.{secret.resource_name},
        .removal_policy = .disable,
    });
    defer secret_version.deinit(allocator);
    var secret_access = try ziac.gcp.secret_manager.SecretIamMember.build(allocator, provider, .{
        .name = "runtime-access",
        .secret_id = "database-url",
        .role = "roles/secretmanager.secretAccessor",
        .member = "serviceAccount:runtime@example-project.iam.gserviceaccount.com",
    });
    defer secret_access.deinit(allocator);

    var graph = ziac.ResourceGraph.init(allocator);
    errdefer graph.deinit();
    try graph.addResource(ring.node);
    try graph.addResource(key.node);
    try graph.addResource(version.node);
    try graph.addResource(key_access.node);
    try graph.addResource(secret.node);
    try graph.addResource(secret_version.node);
    try graph.addResource(secret_access.node);
    try graph.addDependency(secret.node.id, key.node.id);
    try graph.addDependency(secret_access.node.id, secret.node.id);
    return graph;
}

pub fn main() !void {
    var graph = try build(std.heap.page_allocator);
    defer graph.deinit();
    var permissions = try ziac.gcp.intelligence.synthesizePermissionPlan(std.heap.page_allocator, &graph);
    defer permissions.deinit(std.heap.page_allocator);
    std.debug.print("KMS and Secret Manager: {d} resources, {d} security edges, {d} exact permissions\n", .{
        graph.resources.items.len,
        graph.dependencies.items.len,
        permissions.deployer_permissions.len,
    });
}

test "KMS and Secret Manager example compiles a retained security graph" {
    var graph = try build(std.testing.allocator);
    defer graph.deinit();
    try graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 7), graph.resources.items.len);
    var retained: usize = 0;
    for (graph.resources.items) |node| if (node.lifecycle.retain_on_delete) {
        retained += 1;
    };
    try std.testing.expectEqual(@as(usize, 4), retained);
}
