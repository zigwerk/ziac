const std = @import("std");
const ziac = @import("ziac");

test "KMS and Secret Manager graph synthesizes exact APIs and permissions" {
    var graph = try securityGraph();
    defer graph.deinit();
    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &graph);
    defer requirements.deinit(std.testing.allocator);

    try std.testing.expect(contains(requirements.apis, "cloudkms.googleapis.com"));
    try std.testing.expect(contains(requirements.apis, "secretmanager.googleapis.com"));
    try std.testing.expect(requirements.hasPermission("cloudkms.cryptoKeys.create"));
    try std.testing.expect(requirements.hasPermission("cloudkms.cryptoKeyVersions.update"));
    try std.testing.expect(requirements.hasPermission("cloudkms.cryptoKeys.setIamPolicy"));
    try std.testing.expect(requirements.hasPermission("secretmanager.secrets.update"));
    try std.testing.expect(requirements.hasPermission("secretmanager.versions.disable"));
    try std.testing.expect(requirements.hasPermission("secretmanager.secrets.setIamPolicy"));
}

test "KMS and Secret Manager canvas exposes security topology and lifecycle" {
    var graph = try securityGraph();
    defer graph.deinit();
    var artifact = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &graph, null, .{
        .stack = "security",
        .stage = "prod",
        .created_at_millis = 7,
    });
    defer artifact.deinit();

    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kms_secret\":{\"kind\":\"key_ring\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kms_secret\":{\"kind\":\"crypto_key\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kms_secret\":{\"kind\":\"secret\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"replica_count\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"key_membership\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"key_version\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"customer_managed_encryption\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"secret_version\"") != null);
}

test "estate scan maps official KMS and Secret Manager assets" {
    var client = ziac.estate.ScriptedClient.init(std.testing.allocator);
    defer client.deinit();
    try client.addPage(
        \\{"results":[
        \\{"name":"//cloudkms.googleapis.com/projects/acme-prod/locations/europe-west1/keyRings/app","assetType":"cloudkms.googleapis.com/KeyRing","project":"projects/123","location":"europe-west1"},
        \\{"name":"//cloudkms.googleapis.com/projects/acme-prod/locations/europe-west1/keyRings/app/cryptoKeys/data","assetType":"cloudkms.googleapis.com/CryptoKey","project":"projects/123","location":"europe-west1"},
        \\{"name":"//cloudkms.googleapis.com/projects/acme-prod/locations/europe-west1/keyRings/app/cryptoKeys/data/cryptoKeyVersions/1","assetType":"cloudkms.googleapis.com/CryptoKeyVersion","project":"projects/123","location":"europe-west1"},
        \\{"name":"//secretmanager.googleapis.com/projects/123/secrets/database","assetType":"secretmanager.googleapis.com/Secret","project":"projects/123","location":"global","additionalAttributes":{"replication":{"userManaged":{"replicas":[{"location":"europe-west1"},{"location":"us-central1"}]}}}},
        \\{"name":"//secretmanager.googleapis.com/projects/123/secrets/database/versions/1","assetType":"secretmanager.googleapis.com/SecretVersion","project":"projects/123","location":"global"}
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
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.kms.KeyRing") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.kms.CryptoKey") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.kms.CryptoKeyVersion") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.secret.Secret") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.secret.SecretVersion") != null);
}

test "KMS and Secret Manager estimate is explicitly configuration based" {
    const prices = [_]ziac.cost.SkuPrice{
        .{ .sku_id = "kms-software", .region = "global", .unit = "active version month", .unit_quantity = 1, .unit_price_micros = 600_000 },
        .{ .sku_id = "kms-hsm", .region = "europe-west1", .unit = "active version month", .unit_quantity = 1, .unit_price_micros = 2_500_000 },
        .{ .sku_id = "secret-replica", .region = "global", .unit = "active replica version month", .unit_quantity = 1, .unit_price_micros = 60_000 },
        .{ .sku_id = "secret-access", .region = "global", .unit = "10000 accesses", .unit_quantity = 10_000, .unit_price_micros = 30_000 },
    };
    const estimate = try ziac.cost.kmsSecretConfigurationEstimate(&prices, .{
        .resource_id = "ziac.security.data",
        .region = "europe-west1",
        .kms_software_version_sku_id = "kms-software",
        .kms_hsm_version_sku_id = "kms-hsm",
        .secret_replica_version_sku_id = "secret-replica",
        .secret_access_sku_id = "secret-access",
        .kms_software_active_versions = 2,
        .kms_hsm_active_versions = 1,
        .secret_active_replica_versions = 4,
        .secret_access_operations = 20_000,
        .observed_at_millis = 7,
    });
    try std.testing.expectEqual(@as(?i64, 4_000_000), estimate.amount_micros);
    try std.testing.expectEqual(ziac.cost.Origin.configuration_estimate, estimate.origin);
}

test "KMS and Secret Manager local qualification is explicit about destructive exclusions" {
    var graph = try securityGraph();
    defer graph.deinit();
    var receipt = try ziac.gcp.kms_secret_qualification.serializeLocalAlloc(std.testing.allocator, &graph, .{
        .created = graph.resources.items.len,
        .imported = graph.resources.items.len,
        .no_op = graph.resources.items.len,
        .retained = 4,
        .reversible_transitions = 2,
    });
    defer receipt.deinit();
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"schema\":\"ziac.gcp.kms-secret-qualification.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"authenticated\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "irreversible_actions_not_exercised") != null);
}

fn securityGraph() !ziac.ResourceGraph {
    const provider = ziac.gcp.ProviderConfig{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
    var ring = try ziac.gcp.kms.KeyRing.build(std.testing.allocator, provider, .{ .name = "app", .location = "europe-west1" });
    defer ring.deinit(std.testing.allocator);
    var key = try ziac.gcp.kms.CryptoKey.build(std.testing.allocator, provider, .{
        .name = "data",
        .key_ring = ring.name,
        .version_template = .{ .protection_level = .hsm },
    });
    defer key.deinit(std.testing.allocator);
    var key_version = try ziac.gcp.kms.CryptoKeyVersion.build(std.testing.allocator, provider, .{ .name = "primary", .crypto_key = key.name });
    defer key_version.deinit(std.testing.allocator);
    var key_access = try ziac.gcp.kms.CryptoKeyIamMember.build(std.testing.allocator, provider, .{
        .name = "runtime-decrypt",
        .crypto_key = key.name,
        .role = "roles/cloudkms.cryptoKeyDecrypter",
        .member = "serviceAccount:runtime@ziac-dev.iam.gserviceaccount.com",
    });
    defer key_access.deinit(std.testing.allocator);
    const replicas = [_]ziac.gcp.secret_manager.Replica{
        .{ .location = "europe-west1", .kms_key_name = "projects/ziac-dev/locations/europe-west1/keyRings/app/cryptoKeys/data" },
        .{ .location = "us-central1", .kms_key_name = "projects/ziac-dev/locations/us-central1/keyRings/app/cryptoKeys/data" },
    };
    var secret = try ziac.gcp.secret_manager.Secret.build(std.testing.allocator, provider, .{
        .name = "database",
        .replication = .{ .user_managed = &replicas },
        .topics = &.{"projects/ziac-dev/topics/secret-rotation"},
        .rotation = .{ .next_rotation_time = "2026-08-01T00:00:00Z", .period_seconds = 86_400 },
        .version_aliases = &.{.{ .alias = "current", .version = 1 }},
    });
    defer secret.deinit(std.testing.allocator);
    var secret_version = try ziac.gcp.secret_manager.SecretVersion.build(std.testing.allocator, provider, .{
        .name = "initial",
        .secret_id = "database",
        .source = .{ .provider = "env", .resource = "DATABASE_URL", .version = "1" },
        .source_dependencies = &.{secret.resource_name},
        .removal_policy = .disable,
    });
    defer secret_version.deinit(std.testing.allocator);
    var secret_access = try ziac.gcp.secret_manager.SecretIamMember.build(std.testing.allocator, provider, .{
        .name = "runtime-access",
        .secret_id = "database",
        .role = "roles/secretmanager.secretAccessor",
        .member = "serviceAccount:runtime@ziac-dev.iam.gserviceaccount.com",
    });
    defer secret_access.deinit(std.testing.allocator);

    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    errdefer graph.deinit();
    try graph.addResource(ring.node);
    try graph.addResource(key.node);
    try graph.addResource(key_version.node);
    try graph.addResource(key_access.node);
    try graph.addResource(secret.node);
    try graph.addResource(secret_version.node);
    try graph.addResource(secret_access.node);
    try graph.addDependency(secret.node.id, key.node.id);
    try graph.addDependency(secret_access.node.id, secret.node.id);
    return graph;
}

fn contains(values: []const []const u8, expected: []const u8) bool {
    for (values) |present| if (std.mem.eql(u8, present, expected)) return true;
    return false;
}
