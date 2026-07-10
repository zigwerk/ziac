const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const cockroach = ziac.cockroach.client;

test "Cockroach client reads API key and sends pinned version headers" {
    var env = zstd.Env.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("COCKROACH_API_KEY", "dummy-cockroach-secret-key");
    var api_key = try cockroach.ApiKey.fromEnvAlloc(std.testing.allocator, env, "COCKROACH_API_KEY");
    defer api_key.deinit(std.testing.allocator);
    const responses = [_]zstd.Http.Response{.{ .status = 200, .body = "{}" }};
    var transport = RecordingTransport.init(std.testing.allocator, &responses);
    defer transport.deinit();
    var client = cockroach.Client.init(transport.client(), api_key.value, .{
        .base_url = "https://cockroach.example.test/api",
    });
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var diagnostic = cockroach.Diagnostic.init(std.testing.allocator);
    defer diagnostic.deinit();

    var response = try client.requestJsonAlloc(&context, .{
        .method = "GET",
        .path = "/v1/clusters",
    }, &diagnostic);
    defer response.deinit(std.testing.allocator);

    const request = transport.requests.items[0];
    try std.testing.expectEqualStrings("https://cockroach.example.test/api/v1/clusters", request.url);
    try std.testing.expectEqualStrings("Bearer dummy-cockroach-secret-key", request.authorization.?);
    try std.testing.expectEqualStrings("2024-09-16", request.cc_version.?);
    try std.testing.expectEqualStrings("application/json", request.content_type.?);
}

test "Cockroach client distinguishes auth permission rate limit and transient failures" {
    const responses = [_]zstd.Http.Response{
        .{ .status = 401, .body = "{\"message\":\"invalid api key\"}" },
        .{ .status = 403, .body = "{\"message\":\"permission denied\"}" },
        .{
            .status = 429,
            .headers = &.{
                .{ .name = "Retry-After", .value = "3" },
                .{ .name = "X-Request-Id", .value = "cc-limited" },
            },
            .body = "{\"message\":\"sentinel-secret-for-tests\"}",
        },
        .{ .status = 503, .body = "{\"message\":\"unavailable\"}" },
    };
    const expected = [_]ziac.provider_error.ProviderError{
        error.AuthenticationFailed,
        error.AuthorizationFailed,
        error.RateLimited,
        error.TransientFailure,
    };
    var transport = RecordingTransport.init(std.testing.allocator, &responses);
    defer transport.deinit();
    var client = cockroach.Client.init(transport.client(), "dummy-key", .{});
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var diagnostic = cockroach.Diagnostic.init(std.testing.allocator);
    defer diagnostic.deinit();

    for (expected, 0..) |expected_error, index| {
        try std.testing.expectError(
            expected_error,
            client.requestJsonAlloc(&context, .{ .method = "GET", .path = "/v1/clusters" }, &diagnostic),
        );
        if (index == 2) {
            try std.testing.expectEqual(@as(?u64, 3_000), diagnostic.retry_after_millis);
            try std.testing.expectEqualStrings("cc-limited", diagnostic.request_id.?);
            try std.testing.expectEqualStrings("[REDACTED]", diagnostic.message.?);
        }
    }
}

test "Cockroach retrying requests honor retry-after with bounded retries" {
    const responses = [_]zstd.Http.Response{
        .{
            .status = 429,
            .headers = &.{.{ .name = "Retry-After", .value = "2" }},
            .body = "{\"message\":\"rate limit exceeded\"}",
        },
        .{ .status = 200, .body = "{}" },
    };
    var transport = RecordingTransport.init(std.testing.allocator, &responses);
    defer transport.deinit();
    var client = cockroach.Client.init(transport.client(), "dummy-key", .{ .max_retries = 2 });
    var clock = ziac.fx.Clock.fake(0);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    context.clock = &clock;
    var diagnostic = cockroach.Diagnostic.init(std.testing.allocator);
    defer diagnostic.deinit();

    var response = try client.requestJsonWithRetryAlloc(
        &context,
        .{ .method = "GET", .path = "/v1/clusters" },
        &diagnostic,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), transport.cursor);
    try std.testing.expectEqual(@as(u64, 2_000), clock.nowMs());
}

test "Cockroach client decodes typed cluster responses with unknown fields" {
    const responses = [_]zstd.Http.Response{.{
        .status = 200,
        .body =
        \\{"id":"cluster-1","name":"ziac-prod","cloud_provider":"GCP","plan":"STANDARD","state":"CREATED","sql_dns":"ziac-prod.cockroachlabs.cloud","regions":[{"name":"europe-west1","sql_dns":"ziac-prod.gcp-europe-west1.cockroachlabs.cloud","internal_dns":"internal-ziac-prod.gcp-europe-west1.cockroachlabs.cloud","private_endpoint_dns":"private-ziac-prod.gcp-europe-west1.cockroachlabs.cloud","ui_dns":"admin-ziac-prod.gcp-europe-west1.cockroachlabs.cloud","node_count":0,"primary":true},{"name":"us-central1","sql_dns":"ziac-prod.gcp-us-central1.cockroachlabs.cloud","internal_dns":"internal-ziac-prod.gcp-us-central1.cockroachlabs.cloud","private_endpoint_dns":"private-ziac-prod.gcp-us-central1.cockroachlabs.cloud","ui_dns":"admin-ziac-prod.gcp-us-central1.cockroachlabs.cloud","node_count":0}],"future_field":true}
        ,
    }};
    var transport = RecordingTransport.init(std.testing.allocator, &responses);
    defer transport.deinit();
    var client = cockroach.Client.init(transport.client(), "dummy-key", .{});
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var diagnostic = cockroach.Diagnostic.init(std.testing.allocator);
    defer diagnostic.deinit();

    var cluster = try client.getClusterAlloc(&context, "cluster-1", &diagnostic);
    defer cluster.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("cluster-1", cluster.id);
    try std.testing.expectEqualStrings("ziac-prod", cluster.name);
    try std.testing.expectEqualStrings("GCP", cluster.cloud_provider.?);
    try std.testing.expectEqualStrings("STANDARD", cluster.plan.?);
    try std.testing.expectEqualStrings("CREATED", cluster.state.?);
    try std.testing.expectEqualStrings("ziac-prod.cockroachlabs.cloud", cluster.sql_dns.?);
    try std.testing.expectEqual(@as(usize, 2), cluster.regions.len);
    try std.testing.expectEqualStrings("europe-west1", cluster.regions[0].name);
    try std.testing.expectEqualStrings("ziac-prod.gcp-europe-west1.cockroachlabs.cloud", cluster.regions[0].sql_dns);
    try std.testing.expectEqualStrings("internal-ziac-prod.gcp-europe-west1.cockroachlabs.cloud", cluster.regions[0].internal_dns);
    try std.testing.expectEqualStrings("private-ziac-prod.gcp-europe-west1.cockroachlabs.cloud", cluster.regions[0].private_endpoint_dns);
    try std.testing.expectEqualStrings("admin-ziac-prod.gcp-europe-west1.cockroachlabs.cloud", cluster.regions[0].ui_dns);
    try std.testing.expectEqual(@as(i64, 0), cluster.regions[0].node_count);
    try std.testing.expectEqual(true, cluster.regions[0].primary.?);
    try std.testing.expectEqualStrings("us-central1", cluster.regions[1].name);
    try std.testing.expectEqual(@as(?bool, null), cluster.regions[1].primary);
}

test "Cockroach SQL user pagination is stable and percent encodes next page" {
    const responses = [_]zstd.Http.Response{
        .{
            .status = 200,
            .body = "{\"users\":[{\"name\":\"app\"},{\"name\":\"migration\"}],\"pagination\":{\"next_page\":\"next+token/1\"}}",
        },
        .{
            .status = 200,
            .body = "{\"users\":[{\"name\":\"readonly\"}],\"pagination\":{\"next_page\":\"\"}}",
        },
    };
    var transport = RecordingTransport.init(std.testing.allocator, &responses);
    defer transport.deinit();
    var client = cockroach.Client.init(transport.client(), "dummy-key", .{});
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var diagnostic = cockroach.Diagnostic.init(std.testing.allocator);
    defer diagnostic.deinit();

    const users = try client.listAllSqlUsersAlloc(&context, "cluster-1", &diagnostic);
    defer cockroach.freeSqlUsers(std.testing.allocator, users);

    try std.testing.expectEqual(@as(usize, 3), users.len);
    try std.testing.expectEqualStrings("app", users[0].name);
    try std.testing.expectEqualStrings("migration", users[1].name);
    try std.testing.expectEqualStrings("readonly", users[2].name);
    try std.testing.expectEqualStrings(
        "https://cockroachlabs.cloud/api/v1/clusters/cluster-1/sql-users?page=next%2Btoken%2F1",
        transport.requests.items[1].url,
    );
}

test "Cockroach client creates resets and deletes SQL users without retaining request passwords" {
    const responses = [_]zstd.Http.Response{
        .{ .status = 200, .body = "{}" },
        .{ .status = 200, .body = "{}" },
        .{ .status = 204, .body = "" },
        .{ .status = 404, .body = "{\"message\":\"missing\"}" },
    };
    var transport = RecordingTransport.init(std.testing.allocator, &responses);
    defer transport.deinit();
    var client = cockroach.Client.init(transport.client(), "dummy-key", .{});
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var diagnostic = cockroach.Diagnostic.init(std.testing.allocator);
    defer diagnostic.deinit();

    try client.createSqlUser(&context, "cluster-1", "app_user", "p@ss:/?#[]", &diagnostic);
    try client.resetSqlUserPassword(&context, "cluster-1", "app_user", "next-password", &diagnostic);
    try client.deleteSqlUser(&context, "cluster-1", "app_user", &diagnostic);
    try client.deleteSqlUser(&context, "cluster-1", "app_user", &diagnostic);

    try std.testing.expectEqualStrings("POST", transport.requests.items[0].method);
    try std.testing.expectEqualStrings(
        "https://cockroachlabs.cloud/api/v1/clusters/cluster-1/sql-users",
        transport.requests.items[0].url,
    );
    try std.testing.expect(std.mem.indexOf(u8, transport.requests.items[0].body, "\"name\":\"app_user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.requests.items[0].body, "p@ss:/?#[]") != null);
    try std.testing.expectEqualStrings("PUT", transport.requests.items[1].method);
    try std.testing.expect(std.mem.endsWith(u8, transport.requests.items[1].url, "/sql-users/app_user/password"));
    try std.testing.expectEqualStrings("DELETE", transport.requests.items[2].method);
}

test "Cockroach client lists puts patches and deletes allowlist entries" {
    const responses = [_]zstd.Http.Response{
        .{ .status = 200, .body = "{\"allowlist\":[{\"cidr_ip\":\"203.0.113.10\",\"cidr_mask\":32,\"name\":\"api-eu\",\"sql\":true,\"ui\":false}],\"propagating\":false}" },
        .{ .status = 200, .body = "{}" },
        .{ .status = 200, .body = "{}" },
        .{ .status = 204, .body = "" },
        .{ .status = 404, .body = "{\"message\":\"missing\"}" },
    };
    var transport = RecordingTransport.init(std.testing.allocator, &responses);
    defer transport.deinit();
    var client = cockroach.Client.init(transport.client(), "dummy-key", .{});
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var diagnostic = cockroach.Diagnostic.init(std.testing.allocator);
    defer diagnostic.deinit();

    const entries = try client.listAllowlistEntriesAlloc(&context, "cluster-1", &diagnostic);
    defer cockroach.freeAllowlistEntries(std.testing.allocator, entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("203.0.113.10", entries[0].cidr_ip);
    try std.testing.expectEqual(@as(u8, 32), entries[0].cidr_mask);
    try std.testing.expect(entries[0].sql);
    try client.putAllowlistEntry(&context, "cluster-1", entries[0], &diagnostic);
    try client.updateAllowlistEntry(&context, "cluster-1", .{
        .cidr_ip = "203.0.113.10",
        .cidr_mask = 32,
        .name = "api-eu-renamed",
        .sql = true,
        .ui = false,
    }, &diagnostic);
    try client.deleteAllowlistEntry(&context, "cluster-1", "203.0.113.10", 32, &diagnostic);
    try client.deleteAllowlistEntry(&context, "cluster-1", "203.0.113.10", 32, &diagnostic);

    try std.testing.expectEqualStrings("PUT", transport.requests.items[1].method);
    try std.testing.expect(std.mem.endsWith(u8, transport.requests.items[1].url, "/networking/allowlist/203.0.113.10/32"));
    try std.testing.expect(std.mem.indexOf(u8, transport.requests.items[1].body, "\"sql\":true") != null);
    try std.testing.expectEqualStrings("PATCH", transport.requests.items[2].method);
    try std.testing.expectEqualStrings("DELETE", transport.requests.items[3].method);
}

const ObservedRequest = struct {
    method: []const u8,
    url: []const u8,
    body: []const u8,
    authorization: ?[]const u8,
    cc_version: ?[]const u8,
    content_type: ?[]const u8,

    fn deinit(self: *ObservedRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
        allocator.free(self.url);
        std.crypto.secureZero(u8, @constCast(self.body));
        allocator.free(self.body);
        if (self.authorization) |value| allocator.free(value);
        if (self.cc_version) |value| allocator.free(value);
        if (self.content_type) |value| allocator.free(value);
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
            .cc_version = try cloneHeader(self.allocator, request.headers, "cc-version"),
            .content_type = try cloneHeader(self.allocator, request.headers, "content-type"),
        };
        self.requests.append(self.allocator, observed) catch |err| {
            var mutable = observed;
            mutable.deinit(self.allocator);
            return err;
        };
        const response = self.responses[self.cursor];
        self.cursor += 1;
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
