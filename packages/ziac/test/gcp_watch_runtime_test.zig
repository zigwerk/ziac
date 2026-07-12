const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const immutable_image = "europe-west1-docker.pkg.dev/ziac-dev/apps/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

test "GCP watch runtime creates a zero-traffic revision before promotion" {
    const old_service = comptime serviceJson("old@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "api-00001-old", "etag-old");
    const new_service = comptime serviceJson(immutable_image, "api-00002-new", "etag-new");
    const responses = [_]zstd.Http.Response{
        .{ .status = 200, .body = old_service },
        operationStarted("watch-create"),
        operationDone("watch-create", new_service),
        .{ .status = 200, .body = new_service },
        operationStarted("watch-promote"),
        operationDone("watch-promote", new_service),
    };
    var transport = RecordingTransport.init(std.testing.allocator, &responses);
    defer transport.deinit();
    var token_source = FixedTokenSource{};
    var token_cache = ziac.gcp.auth.TokenCache.init(token_source.tokenSource(), 300);
    defer token_cache.deinit(std.testing.allocator);
    var client = ziac.gcp.client.Client.init(transport.client(), &token_cache, .{
        .run = "https://run.example.test",
    });
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    const inputs = [_]ziac.value.Field{
        .{ .name = "project_id", .value = .{ .string = "ziac-dev" } },
        .{ .name = "region", .value = .{ .string = "europe-west1" } },
        .{ .name = "name", .value = .{ .string = "api" } },
    };
    try graph.addResource(.{
        .id = "gcp.run.Service.europe-west1.api",
        .provider = .gcp,
        .type_name = "gcp.run.Service",
        .logical_id = "api",
        .inputs = .{ .object = &inputs },
    });
    var runtime = try ziac.gcp.watch_runtime.LiveRuntime.initAlloc(&client, &context, &graph);
    defer runtime.deinit();

    try runtime.runtime().pushImage(immutable_image);
    try runtime.runtime().createRevision(immutable_image, true);
    try std.testing.expect(try runtime.runtime().waitReady(immutable_image));
    try runtime.runtime().promoteTraffic(immutable_image);

    try std.testing.expectEqual(@as(usize, 6), transport.requests.items.len);
    try std.testing.expectEqualStrings("GET", transport.requests.items[0].method);
    try std.testing.expectEqualStrings(
        "https://run.example.test/v2/projects/ziac-dev/locations/europe-west1/services/api",
        transport.requests.items[0].url,
    );
    const revision_patch = transport.requests.items[1];
    try std.testing.expectEqualStrings("PATCH", revision_patch.method);
    try std.testing.expect(std.mem.indexOf(u8, revision_patch.url, "updateMask=template%2Ctraffic") != null);
    try std.testing.expect(std.mem.indexOf(u8, revision_patch.body, immutable_image) != null);
    try std.testing.expect(std.mem.indexOf(u8, revision_patch.body, "api-00001-old") != null);
    try std.testing.expect(std.mem.indexOf(u8, revision_patch.body, "\"percent\":100") != null);
    const promotion_patch = transport.requests.items[4];
    try std.testing.expect(std.mem.indexOf(u8, promotion_patch.url, "updateMask=traffic") != null);
    try std.testing.expect(std.mem.indexOf(u8, promotion_patch.body, "api-00002-new") != null);
    try std.testing.expect(std.mem.indexOf(u8, promotion_patch.body, "api-00001-old") == null);
}

test "GCP watch runtime rejects unresolved and cross-project service targets" {
    var transport = RecordingTransport.init(std.testing.allocator, &.{});
    defer transport.deinit();
    var token_source = FixedTokenSource{};
    var token_cache = ziac.gcp.auth.TokenCache.init(token_source.tokenSource(), 300);
    defer token_cache.deinit(std.testing.allocator);
    var client = ziac.gcp.client.Client.init(transport.client(), &token_cache, .{});
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    const inputs = [_]ziac.value.Field{
        .{ .name = "project_id", .value = .{ .string = "other-project" } },
        .{ .name = "region", .value = .{ .string = "europe-west1" } },
        .{ .name = "name", .value = .{ .string = "api" } },
    };
    try graph.addResource(.{
        .id = "gcp.run.Service.europe-west1.api",
        .provider = .gcp,
        .type_name = "gcp.run.Service",
        .logical_id = "api",
        .inputs = .{ .object = &inputs },
    });
    try std.testing.expectError(
        error.WatchProjectMismatch,
        ziac.gcp.watch_runtime.LiveRuntime.initForProjectAlloc(&client, &context, &graph, "ziac-dev"),
    );
}

const FixedTokenSource = struct {
    fn tokenSource(self: *FixedTokenSource) ziac.gcp.auth.TokenSource {
        return .{ .ptr = self, .fetchFn = fetch };
    }

    fn fetch(_: *anyopaque, allocator: std.mem.Allocator, now_seconds: u64) ziac.gcp.auth.AuthError!ziac.gcp.auth.AccessToken {
        return ziac.gcp.auth.AccessToken.initOwned(allocator, .{
            .access_token = "dummy-google-token",
            .token_type = "Bearer",
            .expires_at_seconds = now_seconds + 3_600,
        });
    }
};

const Request = struct {
    method: []const u8,
    url: []const u8,
    body: []const u8,

    fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
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
            .method = try self.allocator.dupe(u8, request.method),
            .url = try self.allocator.dupe(u8, request.url),
            .body = try self.allocator.dupe(u8, request.body),
        });
        const response = self.responses[self.cursor];
        self.cursor += 1;
        return zstd.Http.cloneResponseAlloc(allocator, response);
    }
};

fn operationStarted(comptime id: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = "{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/" ++ id ++ "\"}" };
}

fn operationDone(comptime id: []const u8, comptime service: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = "{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/" ++ id ++ "\",\"done\":true,\"response\":" ++ service ++ "}" };
}

fn serviceJson(comptime image: []const u8, comptime revision: []const u8, comptime etag: []const u8) []const u8 {
    return "{\"name\":\"projects/ziac-dev/locations/europe-west1/services/api\",\"etag\":\"" ++ etag ++ "\",\"reconciling\":false,\"terminalCondition\":{\"state\":\"CONDITION_SUCCEEDED\"},\"latestCreatedRevision\":\"" ++ revision ++ "\",\"latestReadyRevision\":\"" ++ revision ++ "\",\"template\":{\"serviceAccount\":\"runtime@ziac-dev.iam.gserviceaccount.com\",\"containers\":[{\"image\":\"" ++ image ++ "\"}]}}";
}
