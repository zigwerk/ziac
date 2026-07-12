const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

test "Google OAuth exchanges PKCE code and verifies OIDC identity before returning secrets" {
    const responses = [_]zstd.Http.Response{
        .{ .status = 200, .body = "{\"access_token\":\"access-secret\",\"refresh_token\":\"refresh-secret\",\"id_token\":\"id-token-secret\",\"token_type\":\"Bearer\",\"expires_in\":3600}" },
        .{ .status = 200, .body = "{\"aud\":\"client.apps.googleusercontent.com\",\"iss\":\"https://accounts.google.com\",\"sub\":\"google-subject-42\",\"email\":\"owner@example.com\",\"email_verified\":true,\"nonce\":\"nonce-73\",\"exp\":1783767600}" },
    };
    var transport = RecordingTransport.init(std.testing.allocator, &responses);
    defer transport.deinit();
    var client = try ziac.gcp.oauth.Client.init(std.testing.allocator, transport.client(), .{
        .client_id = "client.apps.googleusercontent.com",
        .client_secret = "google-client-secret",
    });
    defer client.deinit();

    var grant = try client.exchangeAlloc(std.testing.allocator, .{
        .code = "authorization-code",
        .code_verifier = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .redirect_uri = "http://127.0.0.1:48321/oauth/callback",
        .expected_nonce = "nonce-73",
        .now_seconds = 1_783_764_000,
    });
    defer grant.deinit();

    try std.testing.expectEqualStrings("google-subject-42", grant.subject);
    try std.testing.expectEqualStrings("owner@example.com", grant.email);
    try std.testing.expectEqualStrings("access-secret", grant.access_token);
    try std.testing.expectEqualStrings("refresh-secret", grant.refresh_token);
    try std.testing.expectEqual(@as(u64, 1_783_767_600), grant.expires_at_seconds);
    try std.testing.expectEqual(@as(usize, 2), transport.requests.items.len);
    try std.testing.expect(std.mem.indexOf(u8, transport.requests.items[0].body, "code_verifier=aaaaaaaa") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.requests.items[0].body, "client_secret=google-client-secret") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.requests.items[1].body, "id_token=id-token-secret") != null);
}

test "Google OAuth fails closed when the verified nonce or audience differs" {
    const responses = [_]zstd.Http.Response{
        .{ .status = 200, .body = "{\"access_token\":\"access-secret\",\"refresh_token\":\"refresh-secret\",\"id_token\":\"id-token-secret\",\"token_type\":\"Bearer\",\"expires_in\":3600}" },
        .{ .status = 200, .body = "{\"aud\":\"attacker.apps.googleusercontent.com\",\"iss\":\"https://accounts.google.com\",\"sub\":\"google-subject-42\",\"email\":\"owner@example.com\",\"email_verified\":true,\"nonce\":\"wrong-nonce\",\"exp\":1783767600}" },
    };
    var transport = RecordingTransport.init(std.testing.allocator, &responses);
    defer transport.deinit();
    var client = try ziac.gcp.oauth.Client.init(std.testing.allocator, transport.client(), .{
        .client_id = "client.apps.googleusercontent.com",
        .client_secret = "google-client-secret",
    });
    defer client.deinit();
    try std.testing.expectError(error.InvalidOidcIdentity, client.exchangeAlloc(std.testing.allocator, .{
        .code = "authorization-code",
        .code_verifier = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .redirect_uri = "http://127.0.0.1:48321/oauth/callback",
        .expected_nonce = "nonce-73",
        .now_seconds = 1_783_764_000,
    }));
}

const Request = struct {
    url: []u8,
    body: []u8,
    content_type: []u8,

    fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.body);
        allocator.free(self.content_type);
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
        var content_type: ?[]u8 = null;
        for (request.headers) |header| if (std.ascii.eqlIgnoreCase(header.name, "content-type")) {
            content_type = try self.allocator.dupe(u8, header.value);
        };
        try self.requests.append(self.allocator, .{
            .url = try self.allocator.dupe(u8, request.url),
            .body = try self.allocator.dupe(u8, request.body),
            .content_type = content_type orelse return error.TransportFailure,
        });
        const response = self.responses[self.cursor];
        self.cursor += 1;
        return zstd.Http.cloneResponseAlloc(allocator, response);
    }
};
