const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const actions = ziac.gcp.private_ca_actions;
const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;
const authority_name = "projects/security-prod/locations/europe-west1/caPools/workload/certificateAuthorities/root";

test "Private CA actions require target-bound capability digests" {
    var harness: Harness = undefined;
    harness.init(&.{});
    defer harness.deinit();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    const runner = actions.Runner{ .client = &harness.client };
    const target = authorityTarget();
    const digest = actions.actionDigest(.disable_authority, target);
    try std.testing.expectError(error.ActionDigestMismatch, runner.runAlloc(&context, capability(digest[0..]), .disable_authority, target, "wrong"));
    try std.testing.expectEqual(@as(usize, 0), harness.transport.requests.items.len);
}

test "Private CA lifecycle and revocation emit governed receipts" {
    const certificate_name = "projects/security-prod/locations/europe-west1/caPools/workload/certificates/payments";
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"" ++ authority_name ++ "\",\"state\":\"ENABLED\"}"),
        ok("{\"name\":\"projects/security-prod/locations/europe-west1/operations/disable-root\"}"),
        ok("{\"name\":\"" ++ certificate_name ++ "\"}"),
        ok("{\"name\":\"projects/security-prod/locations/europe-west1/operations/revoke-payments\"}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    const runner = actions.Runner{ .client = &harness.client };
    var disabled = try run(&runner, &context, .disable_authority, authorityTarget());
    defer disabled.deinit();
    try std.testing.expectEqualStrings("DISABLE_PENDING", disabled.resulting_state);
    const certificate = actions.Target{ .stage = "prod", .project = "security-prod", .resource_name = certificate_name, .reason = .key_compromise, .now_millis = 1000, .started_at_millis = 900 };
    var revoked = try run(&runner, &context, .revoke_certificate, certificate);
    defer revoked.deinit();
    try std.testing.expectEqualStrings("REVOCATION_PENDING", revoked.resulting_state);
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[1].url, ":disable"));
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[3].url, ":revoke"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].body, "KEY_COMPROMISE") != null);
}

fn run(runner: *const actions.Runner, context: *ziac.provider.OperationContext, action: actions.Action, target: actions.Target) !actions.Receipt {
    const digest = actions.actionDigest(action, target);
    return runner.runAlloc(context, capability(digest[0..]), action, target, digest[0..]);
}
fn authorityTarget() actions.Target {
    return .{ .stage = "prod", .project = "security-prod", .resource_name = authority_name, .now_millis = 1000, .started_at_millis = 900 };
}
fn capability(digest: []const u8) ziac.agent_contract.CapabilityEnvelope {
    return .{ .id = "private-ca-action", .stages = &.{"prod"}, .projects = &.{"security-prod"}, .providers = &.{.gcp}, .permissions = .{ .read = true, .apply = true, .delete = true }, .budget = .{ .max_creates = 0, .max_updates = 1, .max_deletes = 1, .max_regions = 1 }, .expires_at_millis = 10_000, .approved_plan_digest = digest };
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
