const std = @import("std");
const ziac = @import("ziac");

fn build(allocator: std.mem.Allocator) !ziac.gcp.PrivateCertificateAuthority {
    const provider = ziac.gcp.ProviderConfig{
        .project_id = "security-prod",
        .primary_region = "europe-west1",
    };
    var findings = try ziac.gcp.SecurityFindingPipeline.build(allocator, provider, .{
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

    var admission = try ziac.gcp.TrustedArtifactPolicy.build(allocator, provider, .{
        .base_graph = &findings.graph,
        .name = "runtime",
        .project = ziac.PublicOutput([]const u8).known("projects/security-prod"),
        .note = ziac.PublicOutput([]const u8).known("projects/security-prod/notes/release-attestations"),
        .public_keys = &.{.{ .id = "https://security.example/keys/release", .key = .{ .pkix = .{
            .public_key_pem = "-----BEGIN PUBLIC KEY-----\nYWJj\n-----END PUBLIC KEY-----",
            .signature_algorithm = .ecdsa_p256_sha256,
        } } }},
        .verifier_members = &.{"serviceAccount:runtime@security-prod.iam.gserviceaccount.com"},
    });
    defer admission.deinit();

    return ziac.gcp.PrivateCertificateAuthority.build(allocator, provider, .{
        .base_graph = &admission.graph,
        .name = "workload",
        .project = ziac.PublicOutput([]const u8).known("projects/security-prod"),
        .location = "europe-west1",
        .subject = .{ .common_name = "Ziac Workload Root", .organization = "Ziac" },
        .requester_members = &.{"serviceAccount:runtime@security-prod.iam.gserviceaccount.com"},
    });
}

pub fn main() !void {
    var foundation = try build(std.heap.page_allocator);
    defer foundation.deinit();
    var permissions = try ziac.gcp.intelligence.synthesizePermissionPlan(std.heap.page_allocator, &foundation.graph);
    defer permissions.deinit(std.heap.page_allocator);
    std.debug.print("Security foundation: {d} resources, {d} dependencies, {d} deployer permissions, {d} runtime permissions\n", .{
        foundation.graph.resources.items.len,
        foundation.graph.dependencies.items.len,
        permissions.deployer_permissions.len,
        permissions.runtime_permissions.len,
    });
}

test "security foundation compiles finding admission and private trust policy" {
    var foundation = try build(std.testing.allocator);
    defer foundation.deinit();
    try foundation.graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 11), foundation.graph.resources.items.len);
}
