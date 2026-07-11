const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

test "GCP estate adapter calls Cloud Asset Inventory with encoded pagination" {
    var transport = RecordingTransport.init(std.testing.allocator, .{
        .status = 200,
        .body = "{\"results\":[]}",
    });
    defer transport.deinit();
    var token_source = FixedTokenSource{};
    var token_cache = ziac.gcp.auth.TokenCache.init(token_source.tokenSource(), 300);
    defer token_cache.deinit(std.testing.allocator);
    var gcp_client = ziac.gcp.client.Client.init(transport.client(), &token_cache, .{
        .cloud_asset = "https://cloudasset.example.test",
    });
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var adapter = ziac.gcp.estate_client.Adapter.init(&gcp_client, &context);
    defer adapter.deinit();

    const response = try adapter.client().searchAlloc(std.testing.allocator, .{
        .project_id = "acme-prod",
        .page_token = "page +/2",
        .page_size = 500,
    });
    defer std.testing.allocator.free(response);

    try std.testing.expectEqualStrings("{\"results\":[]}", response);
    try std.testing.expectEqualStrings("GET", transport.method.?);
    try std.testing.expectEqualStrings(
        "https://cloudasset.example.test/v1/projects/acme-prod:searchAllResources?pageSize=500&pageToken=page%20%2B%2F2",
        transport.url.?,
    );
    try std.testing.expectEqualStrings("Bearer test-google-token", transport.authorization.?);
}

const FixedTokenSource = struct {
    fn tokenSource(self: *FixedTokenSource) ziac.gcp.auth.TokenSource {
        return .{ .ptr = self, .fetchFn = fetch };
    }

    fn fetch(_: *anyopaque, allocator: std.mem.Allocator, now_seconds: u64) ziac.gcp.auth.AuthError!ziac.gcp.auth.AccessToken {
        return ziac.gcp.auth.AccessToken.initOwned(allocator, .{
            .access_token = "test-google-token",
            .token_type = "Bearer",
            .expires_at_seconds = now_seconds + 3_600,
        });
    }
};

const RecordingTransport = struct {
    allocator: std.mem.Allocator,
    response: zstd.Http.Response,
    method: ?[]u8 = null,
    url: ?[]u8 = null,
    authorization: ?[]u8 = null,

    fn init(allocator: std.mem.Allocator, response: zstd.Http.Response) RecordingTransport {
        return .{ .allocator = allocator, .response = response };
    }

    fn deinit(self: *RecordingTransport) void {
        if (self.method) |value| self.allocator.free(value);
        if (self.url) |value| self.allocator.free(value);
        if (self.authorization) |value| self.allocator.free(value);
        self.* = undefined;
    }

    fn client(self: *RecordingTransport) zstd.Http.Client {
        return .{ .ptr = self, .sendFn = send };
    }

    fn send(
        raw: *anyopaque,
        allocator: std.mem.Allocator,
        request: zstd.Http.Request,
        options: zstd.Http.SendOptions,
    ) zstd.Http.ClientError!zstd.Http.Response {
        const self: *RecordingTransport = @ptrCast(@alignCast(raw));
        try options.checkActive();
        self.method = try self.allocator.dupe(u8, request.method);
        self.url = try self.allocator.dupe(u8, request.url);
        for (request.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
                self.authorization = try self.allocator.dupe(u8, header.value);
            }
        }
        return zstd.Http.cloneResponseAlloc(allocator, self.response);
    }
};
