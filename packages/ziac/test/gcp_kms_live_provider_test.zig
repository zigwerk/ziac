const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;

test "KMS version creation records Google identity and reconciles reversible state" {
    const version_name = "projects/ziac-dev/locations/europe-west1/keyRings/app/cryptoKeys/signing/cryptoKeyVersions/7";
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"" ++ version_name ++ "\",\"state\":\"ENABLED\",\"algorithm\":\"EC_SIGN_P256_SHA256\",\"protectionLevel\":\"HSM\"}"),
        ok("{\"name\":\"" ++ version_name ++ "\",\"state\":\"DISABLED\",\"algorithm\":\"EC_SIGN_P256_SHA256\",\"protectionLevel\":\"HSM\"}"),
        ok("{\"name\":\"" ++ version_name ++ "\",\"state\":\"DISABLED\",\"algorithm\":\"EC_SIGN_P256_SHA256\",\"protectionLevel\":\"HSM\"}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const provider = ziac.gcp.ProviderConfig{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
    var version = try ziac.gcp.kms.CryptoKeyVersion.build(std.testing.allocator, provider, .{
        .name = "signing-primary",
        .crypto_key = .{ .value = "projects/ziac-dev/locations/europe-west1/keyRings/app/cryptoKeys/signing" },
        .state = .disabled,
    });
    defer version.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    const handler = ziac.gcp.kms_provider.Handler{ .client = &harness.client };
    var created = try handler.create(&context, version.node);
    defer created.deinit();
    try std.testing.expectEqualStrings(version_name, created.physical_id);
    try std.testing.expectEqualStrings("DISABLED", created.outputs[1].value.string);
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[0].url, "/cryptoKeyVersions"));
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[1].url, "?updateMask=state"));
    context.physical_id = created.physical_id;
    var read = try handler.read(&context, version.node, null);
    defer read.deinit();
    var diff = try ziac.gcp.kms_provider.Handler.diff(&context, version.node, &read.present);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.noop, diff.kind);
    try handler.delete(&context, version.node, created.physical_id);
    try std.testing.expectEqual(@as(usize, 3), harness.transport.requests.items.len);
}

test "KMS key update derives the exact mask and uses the canonical resource name" {
    const key_name = "projects/ziac-dev/locations/europe-west1/keyRings/app/cryptoKeys/signing";
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"" ++ key_name ++ "\",\"purpose\":\"ENCRYPT_DECRYPT\",\"versionTemplate\":{\"algorithm\":\"GOOGLE_SYMMETRIC_ENCRYPTION\",\"protectionLevel\":\"SOFTWARE\"},\"importOnly\":false,\"destroyScheduledDuration\":\"2592000s\",\"labels\":{},\"rotationPeriod\":\"172800s\"}"),
        ok("{\"name\":\"" ++ key_name ++ "\",\"purpose\":\"ENCRYPT_DECRYPT\",\"versionTemplate\":{\"algorithm\":\"GOOGLE_SYMMETRIC_ENCRYPTION\",\"protectionLevel\":\"SOFTWARE\"},\"importOnly\":false,\"destroyScheduledDuration\":\"2592000s\",\"labels\":{},\"rotationPeriod\":\"86400s\"}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const provider = ziac.gcp.ProviderConfig{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
    var key = try ziac.gcp.kms.CryptoKey.build(std.testing.allocator, provider, .{
        .name = "signing",
        .key_ring = .{ .value = "projects/ziac-dev/locations/europe-west1/keyRings/app" },
        .rotation_period_seconds = 86_400,
    });
    defer key.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    const handler = ziac.gcp.kms_provider.Handler{ .client = &harness.client };
    var read = try handler.read(&context, key.node, key_name);
    defer read.deinit();
    var updated = try handler.update(&context, key.node, &read.present);
    defer updated.deinit();

    const request = harness.transport.requests.items[1];
    try std.testing.expect(std.mem.endsWith(u8, request.url, "?updateMask=rotationPeriod"));
    try std.testing.expect(std.mem.indexOf(u8, request.body, "\"name\":\"" ++ key_name ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.body, "rotationPeriod") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.body, "\"labels\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, request.body, "versionTemplate") == null);
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
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{ .cloud_kms = "https://kms.example.test" });
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
