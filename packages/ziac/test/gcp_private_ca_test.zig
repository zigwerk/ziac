const std = @import("std");
const ziac = @import("ziac");

test "Private CA declarations compile a retained trust hierarchy without private material" {
    var pool = try ziac.gcp.private_ca.CaPool.build(std.testing.allocator, config(), .{
        .name = "workload-trust",
        .project = ziac.PublicOutput([]const u8).known("projects/security-prod"),
        .location = "europe-west1",
        .tier = .enterprise,
        .maximum_lifetime_seconds = 2_592_000,
        .publish_ca_cert = true,
        .publish_crl = true,
    });
    defer pool.deinit(std.testing.allocator);
    try std.testing.expect(pool.node.lifecycle.retain_on_delete);

    var authority = try ziac.gcp.private_ca.CertificateAuthority.build(std.testing.allocator, config(), .{
        .name = "workload-root-2026",
        .pool = pool.name,
        .authority_type = .self_signed,
        .lifetime_seconds = 315_360_000,
        .key_algorithm = .ec_p384_sha384,
        .subject = .{ .common_name = "Ziac Workload Root 2026", .organization = "Ziac" },
    });
    defer authority.deinit(std.testing.allocator);
    try std.testing.expect(authority.state.referenceOrNull() != null);

    var template = try ziac.gcp.private_ca.CertificateTemplate.build(std.testing.allocator, config(), .{
        .name = "workload-mtls",
        .project = ziac.PublicOutput([]const u8).known("projects/security-prod"),
        .location = "europe-west1",
        .maximum_lifetime_seconds = 86_400,
        .allow_subject_passthrough = true,
        .key_usage = .{ .digital_signature = true, .client_auth = true, .server_auth = true },
    });
    defer template.deinit(std.testing.allocator);

    var certificate = try ziac.gcp.private_ca.Certificate.build(std.testing.allocator, config(), .{
        .name = "payments-api",
        .pool = pool.name,
        .lifetime_seconds = 3_600,
        .template = template.name,
        .request = .{ .config = .{
            .subject = .{ .common_name = "payments.internal", .organization = "Ziac" },
            .dns_names = &.{"payments.internal"},
        } },
    });
    defer certificate.deinit(std.testing.allocator);
    try std.testing.expect(certificate.node.lifecycle.retain_on_delete);

    var pool_member = try ziac.gcp.private_ca.CaPoolIamMember.build(std.testing.allocator, config(), .{
        .name = "workload-issuer",
        .resource = pool.name,
        .role = "roles/privateca.certificateRequester",
        .member = "serviceAccount:payments@security-prod.iam.gserviceaccount.com",
    });
    defer pool_member.deinit(std.testing.allocator);
}

test "Private CA rejects invalid lifetimes subjects and raw private keys" {
    try std.testing.expectError(error.InvalidLifetime, ziac.gcp.private_ca.CaPool.build(std.testing.allocator, config(), .{
        .name = "invalid",
        .project = ziac.PublicOutput([]const u8).known("projects/security-prod"),
        .location = "europe-west1",
        .tier = .enterprise,
        .maximum_lifetime_seconds = 0,
    }));
    try std.testing.expectError(error.InvalidCertificateRequest, ziac.gcp.private_ca.Certificate.build(std.testing.allocator, config(), .{
        .name = "invalid",
        .pool = ziac.PublicOutput([]const u8).known("projects/p/locations/europe-west1/caPools/pool"),
        .lifetime_seconds = 3600,
        .request = .{ .pem_csr = "-----BEGIN " ++ "PRIVATE KEY-----" },
    }));
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "security-host", .primary_region = "europe-west1" };
}
