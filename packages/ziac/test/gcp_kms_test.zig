const std = @import("std");
const ziac = @import("ziac");

test "Cloud KMS resources form an applyable retained bootstrap chain" {
    const provider = ziac.gcp.ProviderConfig{ .project_id = "ziac-cloud-prod", .primary_region = "europe-west1" };
    var ring = try ziac.gcp.kms.KeyRing.build(std.testing.allocator, provider, .{ .name = "ziac-cloud", .location = "europe-west1" });
    defer ring.deinit(std.testing.allocator);
    var key = try ziac.gcp.kms.CryptoKey.build(std.testing.allocator, provider, .{ .name = "connection-vault", .key_ring = ring.name });
    defer key.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("gcp.kms.KeyRing", ring.node.type_name);
    try std.testing.expectEqualStrings("gcp.kms.CryptoKey", key.node.type_name);
    try std.testing.expect(ring.node.lifecycle.retain_on_delete);
    try std.testing.expect(key.node.lifecycle.retain_on_delete);
    try std.testing.expect(ziac.gcp.live_provider.supports(ring.node));
    try std.testing.expect(ziac.gcp.live_provider.supports(key.node));
}

test "Cloud KMS declarations model templates versions and conditional resource IAM" {
    const provider = ziac.gcp.ProviderConfig{ .project_id = "ziac-cloud-prod", .primary_region = "europe-west1" };
    var ring = try ziac.gcp.kms.KeyRing.build(std.testing.allocator, provider, .{ .name = "ziac-cloud", .location = "europe-west1" });
    defer ring.deinit(std.testing.allocator);
    var key = try ziac.gcp.kms.CryptoKey.build(std.testing.allocator, provider, .{
        .name = "signing-key",
        .key_ring = ring.name,
        .purpose = .asymmetric_sign,
        .version_template = .{ .algorithm = .ec_sign_p256_sha256, .protection_level = .hsm },
        .rotation_period_seconds = null,
        .destroy_scheduled_duration_seconds = 604_800,
    });
    defer key.deinit(std.testing.allocator);
    var version = try ziac.gcp.kms.CryptoKeyVersion.build(std.testing.allocator, provider, .{
        .name = "primary",
        .crypto_key = key.name,
        .state = .disabled,
    });
    defer version.deinit(std.testing.allocator);
    var ring_member = try ziac.gcp.kms.KeyRingIamMember.build(std.testing.allocator, provider, .{
        .name = "security-auditor",
        .key_ring = ring.name,
        .role = "roles/cloudkms.viewer",
        .member = "group:security@example.com",
        .condition = .{
            .title = "production-only",
            .expression = "resource.name.startsWith('projects/ziac-cloud-prod/')",
        },
    });
    defer ring_member.deinit(std.testing.allocator);
    var key_member = try ziac.gcp.kms.CryptoKeyIamMember.build(std.testing.allocator, provider, .{
        .name = "runtime-decrypter",
        .crypto_key = key.name,
        .role = "roles/cloudkms.cryptoKeyDecrypter",
        .member = "serviceAccount:runtime@ziac-cloud-prod.iam.gserviceaccount.com",
    });
    defer key_member.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.kms.CryptoKeyVersion", version.node.type_name);
    try std.testing.expect(version.node.lifecycle.retain_on_delete);
    try std.testing.expectEqualStrings("gcp.kms.KeyRingIamMember", ring_member.node.type_name);
    try std.testing.expectEqualStrings("gcp.kms.CryptoKeyIamMember", key_member.node.type_name);
    const key_json = try key.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(key_json);
    try std.testing.expect(std.mem.indexOf(u8, key_json, "\"purpose\":\"ASYMMETRIC_SIGN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, key_json, "\"algorithm\":\"EC_SIGN_P256_SHA256\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, key_json, "rotation_period_seconds") == null);
}

test "Cloud KMS declarations reject incompatible rotation and algorithms" {
    const provider = ziac.gcp.ProviderConfig{ .project_id = "ziac-cloud-prod", .primary_region = "europe-west1" };
    const ring = ziac.output.Output([]const u8, .public).known("projects/p/locations/global/keyRings/r");
    try std.testing.expectError(error.InvalidConfiguration, ziac.gcp.kms.CryptoKey.build(std.testing.allocator, provider, .{
        .name = "bad-signing-key",
        .key_ring = ring,
        .purpose = .asymmetric_sign,
        .version_template = .{ .algorithm = .ec_sign_p256_sha256 },
    }));
    try std.testing.expectError(error.InvalidConfiguration, ziac.gcp.kms.CryptoKey.build(std.testing.allocator, provider, .{
        .name = "bad-symmetric-key",
        .key_ring = ring,
        .purpose = .encrypt_decrypt,
        .version_template = .{ .algorithm = .ec_sign_p256_sha256 },
        .rotation_period_seconds = null,
    }));
}
