const std = @import("std");
const ziac = @import("ziac");

test "security foundation components compile findings admission and private trust graphs" {
    const provider = ziac.gcp.ProviderConfig{ .project_id = "security-prod", .primary_region = "europe-west1" };
    var findings = try ziac.gcp.SecurityFindingPipeline.build(std.testing.allocator, provider, .{
        .name = "production",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .topic = ziac.PublicOutput([]const u8).known("projects/security-prod/topics/security-findings"),
        .dataset = ziac.PublicOutput([]const u8).known("projects/security-prod/datasets/security_findings"),
        .filter = "severity=\"HIGH\" OR severity=\"CRITICAL\"",
    });
    defer findings.deinit();
    try std.testing.expectEqual(@as(usize, 2), findings.graph.resources.items.len);

    var artifacts = try ziac.gcp.TrustedArtifactPolicy.build(std.testing.allocator, provider, .{
        .name = "runtime",
        .project = ziac.PublicOutput([]const u8).known("projects/security-prod"),
        .note = ziac.PublicOutput([]const u8).known("projects/security-prod/notes/release-attestations"),
        .public_keys = &.{.{ .id = "https://security.example/keys/release", .key = .{ .pkix = .{
            .public_key_pem = "-----BEGIN PUBLIC KEY-----\nYWJj\n-----END PUBLIC KEY-----",
            .signature_algorithm = .ecdsa_p256_sha256,
        } } }},
        .verifier_members = &.{"serviceAccount:runtime@security-prod.iam.gserviceaccount.com"},
    });
    defer artifacts.deinit();
    try std.testing.expectEqual(@as(usize, 3), artifacts.graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 2), artifacts.graph.dependencies.items.len);

    var trust = try ziac.gcp.PrivateCertificateAuthority.build(std.testing.allocator, provider, .{
        .name = "workload",
        .project = ziac.PublicOutput([]const u8).known("projects/security-prod"),
        .location = "europe-west1",
        .subject = .{ .common_name = "Ziac Workload Root", .organization = "Ziac" },
        .requester_members = &.{"serviceAccount:runtime@security-prod.iam.gserviceaccount.com"},
    });
    defer trust.deinit();
    try std.testing.expectEqual(@as(usize, 4), trust.graph.resources.items.len);
    try trust.graph.validateAcyclic();
}

test "security finding pipeline optionally installs typed mute and resource value policy" {
    const provider = ziac.gcp.ProviderConfig{ .project_id = "security-prod", .primary_region = "europe-west1" };
    var findings = try ziac.gcp.SecurityFindingPipeline.build(std.testing.allocator, provider, .{
        .name = "production",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .organization = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .topic = ziac.PublicOutput([]const u8).known("projects/security-prod/topics/security-findings"),
        .dataset = ziac.PublicOutput([]const u8).known("projects/security-prod/datasets/security_findings"),
        .filter = "severity=\"HIGH\" OR severity=\"CRITICAL\"",
        .mute_rules = &.{.{
            .name = "accepted-test-projects",
            .config_type = .static,
            .filter = "resource.project_display_name:\"test-\"",
        }},
        .resource_value_rules = &.{.{
            .name = "customer-data",
            .resource_value = .high,
            .resource_type = "storage.googleapis.com/Bucket",
            .tag_values = &.{"tagValues/123"},
        }},
    });
    defer findings.deinit();

    try std.testing.expectEqual(@as(usize, 4), findings.graph.resources.items.len);
    try std.testing.expect(std.mem.eql(u8, findings.graph.resources.items[2].type_name, "gcp.securitycenter.MuteConfig"));
    try std.testing.expect(std.mem.eql(u8, findings.graph.resources.items[3].type_name, "gcp.securitycenter.ResourceValueConfig"));
}
