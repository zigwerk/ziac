const std = @import("std");
const ziac = @import("ziac");

test "diagnosis links App Env binding secret identity IAM network and Cockroach evidence" {
    const evidence = ziac.diagnosis.Evidence{
        .request_event_id = "request-500",
        .revision = "api-00042",
        .deployment_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .env_field = "DATABASE_URL",
        .binding_resource = "gcp.secret.Secret.database-url",
        .secret_version = "projects/p/secrets/database-url/versions/7",
        .runtime_identity = "api@project.iam.gserviceaccount.com",
        .required_permission = "secretmanager.versions.access",
        .granted_permissions = &.{"run.services.get"},
        .network_path = "Cloud Run -> public Cockroach gateway",
        .cockroach_locality = "gcp-europe-west1",
        .provider_event_id = "iam-403",
    };
    var result = try ziac.diagnosis.analyzeAlloc(std.testing.allocator, evidence);
    defer result.deinit();
    try std.testing.expectEqual(ziac.diagnosis.RootCause.missing_runtime_iam, result.root_cause);
    try std.testing.expect(std.mem.indexOf(u8, result.json, "DATABASE_URL") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.json, "secretmanager.versions.access") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.json, "iam-403") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.json, "sentinel-secret") == null);

    var proposal = try ziac.diagnosis.proposeRepairAlloc(std.testing.allocator, evidence, result);
    defer proposal.deinit();
    try std.testing.expect(std.mem.indexOf(u8, proposal.json, "roles/secretmanager.secretAccessor") != null);
    try std.testing.expect(std.mem.indexOf(u8, proposal.json, "apply_authorized\":false") != null);
}

test "diagnosis verification closes only after the required permission and data path are healthy" {
    const repaired = ziac.diagnosis.Evidence{
        .request_event_id = "request-200",
        .revision = "api-00043",
        .deployment_digest = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .env_field = "DATABASE_URL",
        .binding_resource = "gcp.secret.Secret.database-url",
        .secret_version = "projects/p/secrets/database-url/versions/7",
        .runtime_identity = "api@project.iam.gserviceaccount.com",
        .required_permission = "secretmanager.versions.access",
        .granted_permissions = &.{ "run.services.get", "secretmanager.versions.access" },
        .network_path = "healthy",
        .cockroach_locality = "gcp-europe-west1",
        .provider_event_id = "iam-200",
        .secret_binding_ready = true,
        .database_ready = true,
    };
    const verification = ziac.diagnosis.verify(repaired);
    try std.testing.expect(verification.complete);
    try std.testing.expect(verification.requirement_satisfied);
}
