const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const private_ca = ziac.gcp.private_ca;
const gclient = ziac.gcp.client;

test "Private CA pool creation checkpoints and resumes the Google operation" {
    const operation_name = "projects/security-prod/locations/europe-west1/operations/create-pool";
    const pool_json = "{\"name\":\"projects/security-prod/locations/europe-west1/caPools/workload-trust\",\"tier\":\"ENTERPRISE\",\"issuancePolicy\":{\"maximumLifetime\":\"2592000s\"},\"publishingOptions\":{\"publishCaCert\":true,\"publishCrl\":true},\"labels\":{}}";
    const operation = "{\"name\":\"" ++ operation_name ++ "\"}";
    const complete = "{\"name\":\"" ++ operation_name ++ "\",\"done\":true,\"response\":" ++ pool_json ++ "}";
    const responses = [_]zstd.Http.Response{ ok(operation), ok(complete) };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.private_ca_provider.Handler{ .client = &harness.client, .operation_policy = .{ .poll_interval_millis = 0 } };
    var pool = try buildPool(.retain);
    defer pool.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.create(&context, pool.node);
    defer pending.deinit();
    try std.testing.expect(!pending.completed);
    try std.testing.expectEqualStrings(operation_name, pending.operation_handle.?);
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[0].url, "/v1/projects/security-prod/locations/europe-west1/caPools?caPoolId=workload-trust"));

    context.operation_handle = pending.operation_handle;
    var observed = try handler.read(&context, pool.node, pending.physical_id);
    defer observed.deinit();
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[1].url, "/v1/" ++ operation_name));
    try std.testing.expectEqualStrings("projects/security-prod/locations/europe-west1/caPools/workload-trust", observed.present.physical_id);
}

test "Private CA certificates are issued synchronously and never deleted by reconciliation" {
    const certificate_json = "{\"name\":\"projects/security-prod/locations/europe-west1/caPools/workload-trust/certificates/payments-api\",\"pemCertificate\":\"CERT\",\"pemCertificateChain\":[\"CHAIN\"],\"issuerCertificateAuthority\":\"projects/security-prod/locations/europe-west1/caPools/workload-trust/certificateAuthorities/root\",\"lifetime\":\"3600s\",\"labels\":{}}";
    const responses = [_]zstd.Http.Response{ok(certificate_json)};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.private_ca_provider.Handler{ .client = &harness.client };
    var certificate = try buildCertificate();
    defer certificate.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try handler.create(&context, certificate.node);
    defer created.deinit();
    try std.testing.expect(created.completed);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "\"config\"") != null);
    try std.testing.expectError(error.DestructiveConfirmationRequired, handler.delete(&context, certificate.node, created.physical_id));
    context.destructive_confirmation = true;
    try std.testing.expectError(error.InvalidConfiguration, handler.delete(&context, certificate.node, created.physical_id));
}

test "Private CA pool IAM preserves unrelated bindings" {
    const policy = "{\"version\":3,\"etag\":\"iam-etag\",\"bindings\":[{\"role\":\"roles/viewer\",\"members\":[\"user:owner@example.com\"]}]}";
    const updated = "{\"version\":3,\"etag\":\"iam-new\",\"bindings\":[{\"role\":\"roles/viewer\",\"members\":[\"user:owner@example.com\"]},{\"role\":\"roles/privateca.certificateRequester\",\"members\":[\"serviceAccount:payments@security-prod.iam.gserviceaccount.com\"]}]}";
    const responses = [_]zstd.Http.Response{ ok(policy), ok(updated) };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.private_ca_provider.Handler{ .client = &harness.client };
    var member = try private_ca.CaPoolIamMember.build(std.testing.allocator, config(), .{
        .name = "payments-issuer",
        .resource = ziac.PublicOutput([]const u8).known("projects/security-prod/locations/europe-west1/caPools/workload-trust"),
        .role = "roles/privateca.certificateRequester",
        .member = "serviceAccount:payments@security-prod.iam.gserviceaccount.com",
    });
    defer member.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try handler.create(&context, member.node);
    defer created.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "roles/viewer") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "roles/privateca.certificateRequester") != null);
}

fn buildPool(removal_policy: private_ca.RemovalPolicy) !private_ca.CaPool {
    return private_ca.CaPool.build(std.testing.allocator, config(), .{
        .name = "workload-trust",
        .project = ziac.PublicOutput([]const u8).known("projects/security-prod"),
        .location = "europe-west1",
        .tier = .enterprise,
        .maximum_lifetime_seconds = 2_592_000,
        .removal_policy = removal_policy,
    });
}

fn buildCertificate() !private_ca.Certificate {
    return private_ca.Certificate.build(std.testing.allocator, config(), .{
        .name = "payments-api",
        .pool = ziac.PublicOutput([]const u8).known("projects/security-prod/locations/europe-west1/caPools/workload-trust"),
        .lifetime_seconds = 3_600,
        .request = .{ .config = .{
            .subject = .{ .common_name = "payments.internal", .organization = "Ziac" },
            .dns_names = &.{"payments.internal"},
        } },
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
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{ .private_ca = "https://privateca.example.test" });
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
