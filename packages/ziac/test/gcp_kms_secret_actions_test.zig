const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const actions = ziac.gcp.kms_secret_actions;
const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;
const kms_version_name = "projects/ziac-dev/locations/europe-west1/keyRings/app/cryptoKeys/signing/cryptoKeyVersions/7";

test "destructive security actions require target-bound capability digests" {
    var harness: Harness = undefined;
    harness.init(&.{});
    defer harness.deinit();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    const runner = actions.Runner{ .client = &harness.client };
    const target = kmsTarget();
    const digest = actions.actionDigest(.schedule_kms_destroy, target);
    try std.testing.expectError(error.ActionDigestMismatch, runner.runAlloc(&context, capability(digest[0..]), .schedule_kms_destroy, target, "wrong"));
    var denied = capability(digest[0..]);
    denied.permissions.delete = false;
    try std.testing.expectError(error.ActionDenied, runner.runAlloc(&context, denied, .schedule_kms_destroy, target, digest[0..]));
    try std.testing.expectEqual(@as(usize, 0), harness.transport.requests.items.len);
}

test "security actions refresh state and emit governed destroy restore receipts" {
    const secret_name = "projects/ziac-dev/secrets/api-key/versions/9";
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"" ++ kms_version_name ++ "\",\"state\":\"DISABLED\"}"),
        ok("{\"name\":\"" ++ kms_version_name ++ "\",\"state\":\"DESTROY_SCHEDULED\",\"destroyTime\":\"2026-08-01T00:00:00Z\"}"),
        ok("{\"name\":\"" ++ kms_version_name ++ "\",\"state\":\"DESTROY_SCHEDULED\"}"),
        ok("{\"name\":\"" ++ kms_version_name ++ "\",\"state\":\"DISABLED\"}"),
        ok("{\"name\":\"" ++ secret_name ++ "\",\"state\":\"ENABLED\",\"etag\":\"secret-etag\"}"),
        ok("{\"name\":\"" ++ secret_name ++ "\",\"state\":\"DESTROYED\"}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    const runner = actions.Runner{ .client = &harness.client };
    const kms = kmsTarget();
    var scheduled = try run(&runner, &context, .schedule_kms_destroy, kms);
    defer scheduled.deinit();
    try std.testing.expectEqualStrings("DESTROY_SCHEDULED", scheduled.resulting_state);
    var restored = try run(&runner, &context, .restore_kms_version, kms);
    defer restored.deinit();
    try std.testing.expectEqualStrings("DISABLED", restored.resulting_state);
    const secret = actions.Target{ .stage = "prod", .project = "ziac-dev", .resource_name = secret_name, .now_millis = 1000, .started_at_millis = 900 };
    var destroyed = try run(&runner, &context, .destroy_secret_version, secret);
    defer destroyed.deinit();
    try std.testing.expectEqualStrings("DESTROYED", destroyed.resulting_state);
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[1].url, ":destroy"));
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[3].url, ":restore"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[5].body, "secret-etag") != null);
}

fn run(runner: *const actions.Runner, context: *ziac.provider.OperationContext, action: actions.Action, target: actions.Target) !actions.Receipt {
    const digest = actions.actionDigest(action, target);
    return runner.runAlloc(context, capability(digest[0..]), action, target, digest[0..]);
}
fn kmsTarget() actions.Target {
    return .{ .stage = "prod", .project = "ziac-dev", .resource_name = kms_version_name, .now_millis = 1000, .started_at_millis = 900 };
}
fn capability(digest: []const u8) ziac.agent_contract.CapabilityEnvelope {
    return .{ .id = "security-action", .stages = &.{"prod"}, .projects = &.{"ziac-dev"}, .providers = &.{.gcp}, .permissions = .{ .read = true, .apply = true, .delete = true }, .budget = .{ .max_creates = 0, .max_updates = 1, .max_deletes = 1, .max_regions = 1 }, .expires_at_millis = 10_000, .approved_plan_digest = digest };
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
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{ .cloud_kms = "https://kms.example.test", .secret_manager = "https://secret.example.test" });
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
