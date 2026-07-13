const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const gclient = ziac.gcp.client;
const auth = ziac.gcp.auth;

test "GCP JSON client authorizes requests and uses injected API endpoint" {
    const responses = [_]zstd.Http.Response{.{
        .status = 200,
        .headers = &.{.{ .name = "x-request-id", .value = "request-ok" }},
        .body = "{\"name\":\"service\"}",
    }};
    var transport = RecordingTransport.init(std.testing.allocator, &responses);
    defer transport.deinit();
    var token_source = FixedTokenSource{};
    var cache = auth.TokenCache.init(token_source.tokenSource(), 300);
    defer cache.deinit(std.testing.allocator);
    var client = gclient.Client.init(transport.client(), &cache, .{
        .run = "https://run.example.test",
    });
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var diagnostic = gclient.Diagnostic.init(std.testing.allocator);
    defer diagnostic.deinit();

    var response = try client.requestJsonAlloc(&context, .{
        .api = .run,
        .method = "POST",
        .path = "/v2/projects/p/locations/r/services?serviceId=api",
        .body = "{\"ingress\":\"INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER\"}",
    }, &diagnostic);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("{\"name\":\"service\"}", response.body);
    try std.testing.expectEqual(@as(usize, 1), transport.requests.items.len);
    const request = transport.requests.items[0];
    try std.testing.expectEqualStrings(
        "https://run.example.test/v2/projects/p/locations/r/services?serviceId=api",
        request.url,
    );
    try std.testing.expectEqualStrings("Bearer dummy-google-token", request.authorization.?);
    try std.testing.expectEqualStrings("application/json", request.content_type.?);
    try std.testing.expectEqualStrings("application/json", request.accept.?);
    try std.testing.expect(std.mem.startsWith(u8, request.user_agent.?, "ziac/"));
    try std.testing.expectEqualStrings("request-ok", diagnostic.request_id.?);
}

test "GCP JSON client maps Google failures and retains redacted diagnostics" {
    const responses = [_]zstd.Http.Response{
        .{ .status = 401, .body = "{\"error\":{\"code\":401,\"status\":\"UNAUTHENTICATED\",\"message\":\"bad token\"}}" },
        .{ .status = 403, .body = "{\"error\":{\"code\":403,\"status\":\"PERMISSION_DENIED\",\"message\":\"denied\"}}" },
        .{ .status = 404, .body = "{\"error\":{\"code\":404,\"status\":\"NOT_FOUND\",\"message\":\"missing\"}}" },
        .{ .status = 409, .body = "{\"error\":{\"code\":409,\"status\":\"ALREADY_EXISTS\",\"message\":\"exists\"}}" },
        .{
            .status = 429,
            .headers = &.{
                .{ .name = "Retry-After", .value = "2" },
                .{ .name = "X-Request-Id", .value = "request-limited" },
            },
            .body = "{\"error\":{\"code\":429,\"status\":\"RESOURCE_EXHAUSTED\",\"message\":\"sentinel-secret-for-tests\",\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.QuotaInfo\",\"service\":\"compute.googleapis.com\",\"quotaMetric\":\"compute.googleapis.com/backend_services\",\"quotaId\":\"BACKEND-SERVICES-per-project\"},{\"@type\":\"type.googleapis.com/google.rpc.QuotaFailure\",\"violations\":[{\"subject\":\"project:ziac-dev\",\"description\":\"backend service quota exhausted\"}]}]}}",
        },
        .{ .status = 503, .body = "{\"error\":{\"code\":503,\"status\":\"UNAVAILABLE\",\"message\":\"later\"}}" },
    };
    const expected = [_]ziac.provider_error.ProviderError{
        error.AuthenticationFailed,
        error.AuthorizationFailed,
        error.NotFound,
        error.Conflict,
        error.RateLimited,
        error.TransientFailure,
    };
    var transport = RecordingTransport.init(std.testing.allocator, &responses);
    defer transport.deinit();
    var token_source = FixedTokenSource{};
    var cache = auth.TokenCache.init(token_source.tokenSource(), 300);
    defer cache.deinit(std.testing.allocator);
    var client = gclient.Client.init(transport.client(), &cache, .{});
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var recorder = ziac.provider_error.DiagnosticRecorder.init(std.testing.allocator);
    defer recorder.deinit();
    context.diagnostics = &recorder;
    var diagnostic = gclient.Diagnostic.init(std.testing.allocator);
    defer diagnostic.deinit();

    for (expected, 0..) |expected_error, index| {
        try std.testing.expectError(
            expected_error,
            client.requestJsonAlloc(&context, .{ .api = .run, .method = "GET", .path = "/v2/resource" }, &diagnostic),
        );
        if (index == 4) {
            try std.testing.expectEqualStrings("request-limited", diagnostic.request_id.?);
            try std.testing.expectEqual(@as(?u64, 2_000), diagnostic.retry_after_millis);
            try std.testing.expectEqualStrings("[REDACTED]", diagnostic.message.?);
            try std.testing.expect(std.mem.indexOf(u8, diagnostic.message.?, "sentinel-secret-for-tests") == null);
            var recorded = (try recorder.snapshotAlloc(std.testing.allocator)).?;
            defer recorded.deinit();
            try std.testing.expectEqual(ziac.provider_error.Category.rate_limited, recorded.category);
            try std.testing.expectEqualStrings("compute.googleapis.com", recorded.service.?);
            try std.testing.expectEqualStrings("compute.googleapis.com/backend_services", recorded.quota_metric.?);
            try std.testing.expectEqualStrings("BACKEND-SERVICES-per-project", recorded.quota_limit.?);
            try std.testing.expectEqualStrings("project:ziac-dev", recorded.quota_subject.?);
            try std.testing.expectEqualStrings("[REDACTED]", recorded.message.?);
        }
    }
}

const FixedTokenSource = struct {
    fn tokenSource(self: *FixedTokenSource) auth.TokenSource {
        return .{ .ptr = self, .fetchFn = fetch };
    }

    fn fetch(_: *anyopaque, allocator: std.mem.Allocator, now_seconds: u64) auth.AuthError!auth.AccessToken {
        return auth.AccessToken.initOwned(allocator, .{
            .access_token = "dummy-google-token",
            .token_type = "Bearer",
            .expires_at_seconds = now_seconds + 3_600,
        });
    }
};

pub const ObservedRequest = struct {
    method: []const u8,
    url: []const u8,
    body: []const u8,
    authorization: ?[]const u8,
    content_type: ?[]const u8,
    accept: ?[]const u8,
    user_agent: ?[]const u8,
    if_match: ?[]const u8,

    fn deinit(self: *ObservedRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
        allocator.free(self.url);
        allocator.free(self.body);
        if (self.authorization) |value| allocator.free(value);
        if (self.content_type) |value| allocator.free(value);
        if (self.accept) |value| allocator.free(value);
        if (self.user_agent) |value| allocator.free(value);
        if (self.if_match) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const RecordingTransport = struct {
    allocator: std.mem.Allocator,
    responses: []const zstd.Http.Response,
    cursor: usize = 0,
    requests: std.ArrayList(ObservedRequest) = .empty,

    pub fn init(allocator: std.mem.Allocator, responses: []const zstd.Http.Response) RecordingTransport {
        return .{ .allocator = allocator, .responses = responses };
    }

    pub fn deinit(self: *RecordingTransport) void {
        for (self.requests.items) |*request| request.deinit(self.allocator);
        self.requests.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn client(self: *RecordingTransport) zstd.Http.Client {
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
        if (self.cursor >= self.responses.len) return error.ScriptExhausted;
        const observed = ObservedRequest{
            .method = try self.allocator.dupe(u8, request.method),
            .url = try self.allocator.dupe(u8, request.url),
            .body = try self.allocator.dupe(u8, request.body),
            .authorization = try cloneHeader(self.allocator, request.headers, "authorization"),
            .content_type = try cloneHeader(self.allocator, request.headers, "content-type"),
            .accept = try cloneHeader(self.allocator, request.headers, "accept"),
            .user_agent = try cloneHeader(self.allocator, request.headers, "user-agent"),
            .if_match = try cloneHeader(self.allocator, request.headers, "if-match"),
        };
        self.requests.append(self.allocator, observed) catch |err| {
            var mutable = observed;
            mutable.deinit(self.allocator);
            return err;
        };
        const response = self.responses[self.cursor];
        self.cursor += 1;
        if (response.body.len > options.response_body_limit) return error.ResponseBodyTooLarge;
        return zstd.Http.cloneResponseAlloc(allocator, response);
    }
};

fn cloneHeader(
    allocator: std.mem.Allocator,
    headers: []const zstd.Http.Header,
    name: []const u8,
) std.mem.Allocator.Error!?[]const u8 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) {
            const value: []const u8 = try allocator.dupe(u8, header.value);
            return value;
        }
    }
    return null;
}
