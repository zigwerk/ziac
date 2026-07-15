const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const binary = ziac.gcp.binary_authorization;
const gclient = ziac.gcp.client;

test "Binary Authorization policy owns singleton with etag-safe full replacement" {
    const old = "{\"name\":\"projects/runtime-prod/policy\",\"description\":\"Runtime policy\",\"globalPolicyEvaluationMode\":\"ENABLE\",\"admissionWhitelistPatterns\":[],\"defaultAdmissionRule\":{\"evaluationMode\":\"REQUIRE_ATTESTATION\",\"requireAttestationsBy\":[\"projects/runtime-prod/attestors/release-signer\"],\"enforcementMode\":\"ENFORCED_BLOCK_AND_AUDIT_LOG\"},\"clusterAdmissionRules\":{},\"kubernetesNamespaceAdmissionRules\":{},\"kubernetesServiceAccountAdmissionRules\":{},\"istioServiceIdentityAdmissionRules\":{},\"etag\":\"etag-old\"}";
    const updated = "{\"name\":\"projects/runtime-prod/policy\",\"description\":\"Runtime policy\",\"globalPolicyEvaluationMode\":\"ENABLE\",\"admissionWhitelistPatterns\":[],\"defaultAdmissionRule\":{\"evaluationMode\":\"REQUIRE_ATTESTATION\",\"requireAttestationsBy\":[\"projects/runtime-prod/attestors/release-signer\"],\"enforcementMode\":\"ENFORCED_BLOCK_AND_AUDIT_LOG\"},\"clusterAdmissionRules\":{},\"kubernetesNamespaceAdmissionRules\":{},\"kubernetesServiceAccountAdmissionRules\":{},\"istioServiceIdentityAdmissionRules\":{},\"etag\":\"etag-new\"}";
    const responses = [_]zstd.Http.Response{ ok(updated), ok(old), ok(updated) };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.binary_authorization_provider.Handler{ .client = &harness.client };
    var policy = try buildPolicy();
    defer policy.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try handler.create(&context, policy.node);
    defer created.deinit();
    try std.testing.expectEqualStrings("PUT", harness.transport.requests.items[0].method);
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[0].url, "/v1/projects/runtime-prod/policy"));
    var observed = try handler.read(&context, policy.node, created.physical_id);
    defer observed.deinit();
    var result = try handler.update(&context, policy.node, &observed.present);
    defer result.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[2].body, "\"etag\":\"etag-old\"") != null);
    try std.testing.expectError(error.InvalidConfiguration, handler.delete(&context, policy.node, result.physical_id));
}

test "Binary Authorization attestor update keeps note immutable and delete guarded" {
    const remote = "{\"name\":\"projects/runtime-prod/attestors/release-signer\",\"description\":\"Release signer\",\"userOwnedGrafeasNote\":{\"noteReference\":\"projects/security-prod/notes/release-attestations\",\"publicKeys\":[{\"id\":\"https://security.example/keys/release\",\"pkixPublicKey\":{\"publicKeyPem\":\"-----BEGIN PUBLIC KEY-----\\nYWJj\\n-----END PUBLIC KEY-----\",\"signatureAlgorithm\":\"ECDSA_P256_SHA256\"}}],\"delegationServiceAccountEmail\":\"service@binaryauthorization.iam.gserviceaccount.com\"},\"etag\":\"etag-attestor\"}";
    const responses = [_]zstd.Http.Response{ ok(remote), ok(remote), ok("{}") };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.binary_authorization_provider.Handler{ .client = &harness.client };
    var attestor = try buildAttestor(.delete);
    defer attestor.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try handler.create(&context, attestor.node);
    defer created.deinit();
    var observed = try handler.read(&context, attestor.node, created.physical_id);
    defer observed.deinit();
    var diff = try ziac.gcp.binary_authorization_provider.Handler.diff(&context, attestor.node, &observed.present);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.noop, diff.kind);
    try std.testing.expectError(error.DestructiveConfirmationRequired, handler.delete(&context, attestor.node, created.physical_id));
    context.destructive_confirmation = true;
    try handler.delete(&context, attestor.node, created.physical_id);
}

test "Binary Authorization attestor IAM preserves unrelated bindings" {
    const policy = "{\"version\":3,\"etag\":\"iam-etag\",\"bindings\":[{\"role\":\"roles/viewer\",\"members\":[\"user:owner@example.com\"]}]}";
    const updated = "{\"version\":3,\"etag\":\"iam-new\",\"bindings\":[{\"role\":\"roles/viewer\",\"members\":[\"user:owner@example.com\"]},{\"role\":\"roles/binaryauthorization.attestorsVerifier\",\"members\":[\"serviceAccount:runtime@runtime-prod.iam.gserviceaccount.com\"]}]}";
    const responses = [_]zstd.Http.Response{ ok(policy), ok(updated) };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.binary_authorization_provider.Handler{ .client = &harness.client };
    var member = try binary.AttestorIamMember.build(std.testing.allocator, config(), .{
        .name = "runtime-verifier",
        .attestor = ziac.PublicOutput([]const u8).known("projects/runtime-prod/attestors/release-signer"),
        .role = "roles/binaryauthorization.attestorsVerifier",
        .member = "serviceAccount:runtime@runtime-prod.iam.gserviceaccount.com",
    });
    defer member.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try handler.create(&context, member.node);
    defer created.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "roles/viewer") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "roles/binaryauthorization.attestorsVerifier") != null);
}

fn buildPolicy() !binary.Policy {
    return binary.Policy.build(std.testing.allocator, config(), .{
        .name = "runtime-admission",
        .project = ziac.PublicOutput([]const u8).known("projects/runtime-prod"),
        .description = "Runtime policy",
        .default_rule = .{
            .evaluation = .require_attestation,
            .enforcement = .block_and_audit,
            .attestors = &.{ziac.PublicOutput([]const u8).known("projects/runtime-prod/attestors/release-signer")},
        },
    });
}

fn buildAttestor(removal_policy: binary.RemovalPolicy) !binary.Attestor {
    return binary.Attestor.build(std.testing.allocator, config(), .{
        .name = "release-signer",
        .project = ziac.PublicOutput([]const u8).known("projects/runtime-prod"),
        .note_reference = ziac.PublicOutput([]const u8).known("projects/security-prod/notes/release-attestations"),
        .description = "Release signer",
        .public_keys = &.{.{ .id = "https://security.example/keys/release", .key = .{ .pkix = .{
            .public_key_pem = "-----BEGIN PUBLIC KEY-----\nYWJj\n-----END PUBLIC KEY-----",
            .signature_algorithm = .ecdsa_p256_sha256,
        } } }},
        .removal_policy = removal_policy,
    });
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "security-host", .primary_region = "europe-west1" };
}

const Harness = struct {
    source: FixedTokenSource,
    cache: auth.TokenCache,
    transport: @import("gcp_client_test.zig").RecordingTransport,
    client: gclient.Client,

    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.source = .{};
        self.cache = auth.TokenCache.init(self.source.tokenSource(), 300);
        self.transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{ .binary_authorization = "https://binaryauthorization.example.test" });
    }

    fn deinit(self: *Harness) void {
        self.transport.deinit();
        self.cache.deinit(std.testing.allocator);
    }
};

const FixedTokenSource = struct {
    fn tokenSource(self: *FixedTokenSource) auth.TokenSource {
        return .{ .ptr = self, .fetchFn = fetch };
    }
    fn fetch(_: *anyopaque, allocator: std.mem.Allocator, now: u64) auth.AuthError!auth.AccessToken {
        return auth.AccessToken.initOwned(allocator, .{ .access_token = "token", .token_type = "Bearer", .expires_at_seconds = now + 3600 });
    }
};

fn ok(body: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = body };
}
