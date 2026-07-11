const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

test "GCP logging adapter uses the authenticated entries list API" {
    var transport = CaptureTransport{};
    var token_source = FixedTokenSource{};
    var cache = ziac.gcp.auth.TokenCache.init(token_source.tokenSource(), 300);
    defer cache.deinit(std.testing.allocator);
    var api = ziac.gcp.client.Client.init(transport.client(), &cache, .{
        .logging = "https://logging.example.test",
    });
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var adapter = ziac.gcp.logging_client.Adapter.init(std.testing.allocator, &api, &context);
    defer adapter.deinit();

    const response = try adapter.client().list("{\"resourceNames\":[\"projects/acme-prod\"]}");
    try std.testing.expectEqualStrings("{\"entries\":[]}", response);
    try std.testing.expectEqualStrings("https://logging.example.test/v2/entries:list", transport.url.?);
    try std.testing.expectEqualStrings("Bearer test-token", transport.authorization.?);
}

const FixedTokenSource = struct {
    fn tokenSource(self: *FixedTokenSource) ziac.gcp.auth.TokenSource {
        return .{ .ptr = self, .fetchFn = fetch };
    }
    fn fetch(_: *anyopaque, allocator: std.mem.Allocator, now: u64) ziac.gcp.auth.AuthError!ziac.gcp.auth.AccessToken {
        return ziac.gcp.auth.AccessToken.initOwned(allocator, .{ .access_token = "test-token", .token_type = "Bearer", .expires_at_seconds = now + 3600 });
    }
};

const CaptureTransport = struct {
    url_buffer: [512]u8 = undefined,
    authorization_buffer: [256]u8 = undefined,
    url: ?[]const u8 = null,
    authorization: ?[]const u8 = null,
    fn client(self: *CaptureTransport) zstd.Http.Client {
        return .{ .ptr = self, .sendFn = send };
    }
    fn send(raw: *anyopaque, allocator: std.mem.Allocator, request: zstd.Http.Request, _: zstd.Http.SendOptions) zstd.Http.ClientError!zstd.Http.Response {
        const self: *CaptureTransport = @ptrCast(@alignCast(raw));
        @memcpy(self.url_buffer[0..request.url.len], request.url);
        self.url = self.url_buffer[0..request.url.len];
        for (request.headers) |header| if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
            @memcpy(self.authorization_buffer[0..header.value.len], header.value);
            self.authorization = self.authorization_buffer[0..header.value.len];
        };
        return zstd.Http.cloneResponseAlloc(allocator, .{ .status = 200, .body = "{\"entries\":[]}" });
    }
};
