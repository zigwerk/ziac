const std = @import("std");
const ziac = @import("ziac");

test "local security foundation qualification proves bounded deterministic evidence" {
    var graph = try qualificationGraph();
    defer graph.deinit();
    var retained: usize = 0;
    for (graph.resources.items) |node| if (node.lifecycle.retain_on_delete) {
        retained += 1;
    };

    var receipt = try ziac.gcp.security_foundation_qualification.serializeLocalAlloc(std.testing.allocator, &graph, .{
        .created = graph.resources.items.len,
        .imported = graph.resources.items.len,
        .no_op = graph.resources.items.len,
        .retained = retained,
        .resumable_operations = 3,
        .finding_routes = 2,
        .admission_policies = 1,
        .private_trust_resources = 4,
        .governed_action_boundaries = 1,
    });
    defer receipt.deinit();

    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"schema\":\"ziac.gcp.security-foundation-qualification.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"authenticated\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"finding_routes\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"admission_policies\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"private_trust_resources\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"estimated_management_cost_micros\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "authenticated_security_mutation_not_exercised") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "certificate_revocation_not_exercised") != null);
}

fn qualificationGraph() !ziac.ResourceGraph {
    const provider = ziac.gcp.ProviderConfig{ .project_id = "security-prod", .primary_region = "europe-west1" };
    var findings = try ziac.gcp.SecurityFindingPipeline.build(std.testing.allocator, provider, .{
        .name = "production",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .topic = ziac.PublicOutput([]const u8).known("projects/security-prod/topics/security-findings"),
        .dataset = ziac.PublicOutput([]const u8).known("projects/security-prod/datasets/security_findings"),
        .filter = "severity=\"HIGH\" OR severity=\"CRITICAL\"",
    });
    defer findings.deinit();

    var artifacts = try ziac.gcp.TrustedArtifactPolicy.build(std.testing.allocator, provider, .{
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
    defer artifacts.deinit();

    const trust = try ziac.gcp.PrivateCertificateAuthority.build(std.testing.allocator, provider, .{
        .base_graph = &artifacts.graph,
        .name = "workload",
        .project = ziac.PublicOutput([]const u8).known("projects/security-prod"),
        .location = "europe-west1",
        .subject = .{ .common_name = "Ziac Workload Root", .organization = "Ziac" },
        .requester_members = &.{"serviceAccount:runtime@security-prod.iam.gserviceaccount.com"},
    });
    return trust.graph;
}
