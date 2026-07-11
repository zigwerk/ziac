const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

test "estate control plane resolves Google identity Pro entitlement and project connection over authenticated HTTPS" {
    const responses = [_]zstd.Http.Response{
        .{ .status = 200, .body = "{\"identity_provider\":\"google\",\"verified\":true,\"subject\":\"google-subject-42\"}" },
        .{ .status = 200, .body = "{\"tier\":\"pro\",\"active\":true,\"expires_at_millis\":1800000000000}" },
        .{ .status = 200, .body = "{\"status\":\"connected\",\"project_id\":\"acme-prod\"}" },
    };
    var transport = RecordingTransport.init(std.testing.allocator, &responses);
    defer transport.deinit();
    var control = try ziac.estate_access.HttpResolver.init(
        std.testing.allocator,
        transport.client(),
        "https://control.ziac.example",
        "opaque-session-assertion",
    );
    defer control.deinit();

    const access = try ziac.estate_access.resolve(control.resolver(), .{
        .session_assertion = "opaque-session-assertion",
        .connection_id = "gcp-connection-17",
        .now_millis = 1_783_764_000_000,
    });

    try std.testing.expectEqualStrings("acme-prod", access.scan_input.connection.project_id);
    try std.testing.expectEqual(@as(usize, 3), transport.requests.items.len);
    try std.testing.expectEqualStrings("https://control.ziac.example/v1/estate/identity:verify", transport.requests.items[0].url);
    try std.testing.expectEqualStrings("https://control.ziac.example/v1/estate/entitlements:lookup", transport.requests.items[1].url);
    try std.testing.expectEqualStrings("https://control.ziac.example/v1/estate/connections:resolve", transport.requests.items[2].url);
    for (transport.requests.items) |request| {
        try std.testing.expectEqualStrings("Bearer opaque-session-assertion", request.authorization);
    }
    try std.testing.expect(std.mem.indexOf(u8, transport.requests.items[2].body, "gcp-connection-17") != null);
}

const ObservedRequest = struct {
    url: []u8,
    body: []u8,
    authorization: []u8,

    fn deinit(self: *ObservedRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.body);
        allocator.free(self.authorization);
    }
};

const RecordingTransport = struct {
    allocator: std.mem.Allocator,
    responses: []const zstd.Http.Response,
    cursor: usize = 0,
    requests: std.ArrayList(ObservedRequest) = .empty,

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
        var authorization: ?[]u8 = null;
        for (request.headers) |header| if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
            authorization = try self.allocator.dupe(u8, header.value);
        };
        const observed = ObservedRequest{
            .url = try self.allocator.dupe(u8, request.url),
            .body = try self.allocator.dupe(u8, request.body),
            .authorization = authorization orelse return error.TransportFailure,
        };
        try self.requests.append(self.allocator, observed);
        const response = self.responses[self.cursor];
        self.cursor += 1;
        return zstd.Http.cloneResponseAlloc(allocator, response);
    }
};
