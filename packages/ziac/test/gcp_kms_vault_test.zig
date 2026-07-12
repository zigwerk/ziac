const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

test "Cloud KMS vault encrypts refresh credentials and persists only ciphertext metadata" {
    var transport = RecordingTransport.init(std.testing.allocator, &.{.{
        .status = 200,
        .body = "{\"name\":\"projects/ziac-control/locations/global/keyRings/estate/cryptoKeys/oauth/cryptoKeyVersions/7\",\"ciphertext\":\"ZW5jcnlwdGVkLWJ5dGVz\",\"ciphertextCrc32c\":\"42\",\"verifiedPlaintextCrc32c\":true,\"protectionLevel\":\"HSM\"}",
    }});
    defer transport.deinit();
    var token_source = FixedTokenSource{};
    var cache = ziac.gcp.auth.TokenCache.init(token_source.tokenSource(), 300);
    defer cache.deinit(std.testing.allocator);
    var client = ziac.gcp.client.Client.init(transport.client(), &cache, .{
        .cloud_kms = "https://kms.example.test",
    });
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var persisted = RecordingCiphertextStore{};
    var vault = try ziac.gcp.kms_vault.Vault.init(
        std.testing.allocator,
        &client,
        &context,
        "projects/ziac-control/locations/global/keyRings/estate/cryptoKeys/oauth",
        persisted.store(),
    );
    defer vault.deinit();

    try vault.credentialVault().seal_fn(vault.credentialVault().ptr, "google-subject-42", "refresh-secret");

    try std.testing.expectEqual(@as(usize, 1), transport.requests.items.len);
    try std.testing.expectEqualStrings(
        "https://kms.example.test/v1/projects/ziac-control/locations/global/keyRings/estate/cryptoKeys/oauth:encrypt",
        transport.requests.items[0].url,
    );
    try std.testing.expect(std.mem.indexOf(u8, transport.requests.items[0].body, "refresh-secret") == null);
    try std.testing.expectEqual(@as(usize, 1), persisted.calls);
    try std.testing.expectEqualStrings("ZW5jcnlwdGVkLWJ5dGVz", persisted.ciphertextSlice());
    try std.testing.expectEqualStrings("projects/ziac-control/locations/global/keyRings/estate/cryptoKeys/oauth/cryptoKeyVersions/7", persisted.keyVersionSlice());
    try std.testing.expect(!std.mem.eql(u8, &persisted.digest, &([_]u8{0} ** 32)));
}

const RecordingCiphertextStore = struct {
    calls: usize = 0,
    ciphertext: [256]u8 = undefined,
    ciphertext_len: usize = 0,
    key_version: [1024]u8 = undefined,
    key_version_len: usize = 0,
    digest: [32]u8 = [_]u8{0} ** 32,

    fn store(self: *RecordingCiphertextStore) ziac.gcp.kms_vault.CiphertextStore {
        return .{ .ptr = self, .persist_fn = persist };
    }

    fn ciphertextSlice(self: *const RecordingCiphertextStore) []const u8 {
        return self.ciphertext[0..self.ciphertext_len];
    }

    fn keyVersionSlice(self: *const RecordingCiphertextStore) []const u8 {
        return self.key_version[0..self.key_version_len];
    }

    fn persist(raw: *anyopaque, subject: []const u8, ciphertext: []const u8, key_version: []const u8, digest: [32]u8) !void {
        const self: *RecordingCiphertextStore = @ptrCast(@alignCast(raw));
        if (!std.mem.eql(u8, subject, "google-subject-42")) return error.InvalidSubject;
        self.calls += 1;
        if (ciphertext.len > self.ciphertext.len or key_version.len > self.key_version.len) return error.ValueTooLong;
        @memcpy(self.ciphertext[0..ciphertext.len], ciphertext);
        self.ciphertext_len = ciphertext.len;
        @memcpy(self.key_version[0..key_version.len], key_version);
        self.key_version_len = key_version.len;
        self.digest = digest;
    }
};

const FixedTokenSource = struct {
    fn tokenSource(self: *FixedTokenSource) ziac.gcp.auth.TokenSource {
        return .{ .ptr = self, .fetchFn = fetch };
    }

    fn fetch(_: *anyopaque, allocator: std.mem.Allocator, now_seconds: u64) ziac.gcp.auth.AuthError!ziac.gcp.auth.AccessToken {
        return ziac.gcp.auth.AccessToken.initOwned(allocator, .{
            .access_token = "dummy-google-token",
            .token_type = "Bearer",
            .expires_at_seconds = now_seconds + 3600,
        });
    }
};

const Request = struct {
    url: []u8,
    body: []u8,
    fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.body);
    }
};

const RecordingTransport = struct {
    allocator: std.mem.Allocator,
    responses: []const zstd.Http.Response,
    cursor: usize = 0,
    requests: std.ArrayList(Request) = .empty,

    fn init(allocator: std.mem.Allocator, responses: []const zstd.Http.Response) RecordingTransport {
        return .{ .allocator = allocator, .responses = responses };
    }
    fn deinit(self: *RecordingTransport) void {
        for (self.requests.items) |*request| request.deinit(self.allocator);
        self.requests.deinit(self.allocator);
    }
    fn client(self: *RecordingTransport) zstd.Http.Client {
        return .{ .ptr = self, .sendFn = send };
    }
    fn send(raw: *anyopaque, allocator: std.mem.Allocator, request: zstd.Http.Request, options: zstd.Http.SendOptions) zstd.Http.ClientError!zstd.Http.Response {
        const self: *RecordingTransport = @ptrCast(@alignCast(raw));
        try options.checkActive();
        if (self.cursor >= self.responses.len) return error.ScriptExhausted;
        try self.requests.append(self.allocator, .{
            .url = try self.allocator.dupe(u8, request.url),
            .body = try self.allocator.dupe(u8, request.body),
        });
        const response = self.responses[self.cursor];
        self.cursor += 1;
        return zstd.Http.cloneResponseAlloc(allocator, response);
    }
};
