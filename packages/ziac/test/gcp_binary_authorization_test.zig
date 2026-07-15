const std = @import("std");
const ziac = @import("ziac");

test "Binary Authorization declarations require typed attestation and audit rules" {
    const project = ziac.PublicOutput([]const u8).known("projects/runtime-prod");
    var attestor = try ziac.gcp.binary_authorization.Attestor.build(std.testing.allocator, config(), .{
        .name = "release-signer",
        .project = project,
        .note_reference = ziac.PublicOutput([]const u8).known("projects/security-prod/notes/release-attestations"),
        .public_keys = &.{.{ .id = "https://security.example/keys/release", .key = .{ .pkix = .{
            .public_key_pem = "-----BEGIN PUBLIC KEY-----\nYWJj\n-----END PUBLIC KEY-----",
            .signature_algorithm = .ecdsa_p256_sha256,
        } } }},
    });
    defer attestor.deinit(std.testing.allocator);

    var policy = try ziac.gcp.binary_authorization.Policy.build(std.testing.allocator, config(), .{
        .name = "runtime-admission",
        .project = project,
        .global_policy_evaluation = true,
        .default_rule = .{
            .evaluation = .require_attestation,
            .enforcement = .block_and_audit,
            .attestors = &.{attestor.name},
        },
        .namespace_rules = &.{.{
            .selector = "development",
            .rule = .{ .evaluation = .require_attestation, .enforcement = .audit_only, .attestors = &.{attestor.name} },
        }},
    });
    defer policy.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("gcp.binaryauthorization.Policy.runtime-admission", policy.node.id);

    var member = try ziac.gcp.binary_authorization.AttestorIamMember.build(std.testing.allocator, config(), .{
        .name = "runtime-verifier",
        .attestor = attestor.name,
        .role = "roles/binaryauthorization.attestorsVerifier",
        .member = "serviceAccount:service-123@gcp-sa-binaryauthorization.iam.gserviceaccount.com",
    });
    defer member.deinit(std.testing.allocator);
}

test "Binary Authorization rejects missing and extraneous attestors" {
    try std.testing.expectError(error.InvalidAdmissionRule, ziac.gcp.binary_authorization.Policy.build(std.testing.allocator, config(), .{
        .name = "invalid",
        .project = ziac.PublicOutput([]const u8).known("projects/runtime-prod"),
        .default_rule = .{ .evaluation = .require_attestation, .enforcement = .block_and_audit },
    }));
    try std.testing.expectError(error.InvalidAdmissionRule, ziac.gcp.binary_authorization.Policy.build(std.testing.allocator, config(), .{
        .name = "invalid",
        .project = ziac.PublicOutput([]const u8).known("projects/runtime-prod"),
        .default_rule = .{
            .evaluation = .always_allow,
            .enforcement = .audit_only,
            .attestors = &.{ziac.PublicOutput([]const u8).known("projects/p/attestors/a")},
        },
    }));
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "security-host", .primary_region = "europe-west1" };
}
