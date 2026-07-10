const std = @import("std");
const ziac = @import("ziac");
const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;
const zstd = ziac.zstd;

const state_key = "ziac/state/api/prod/resources.json";

test "GCS state read pins media bytes to metadata generation" {
    const responses = [_]zstd.Http.Response{
        .{ .status = 200, .body = "{\"generation\":\"41\"}" },
        .{ .status = 200, .body = "{\"format_version\":2}" },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const objects = harness.gcs.objectStore();

    var object = try objects.get(state_key);
    defer object.deinit();
    try std.testing.expectEqualStrings("41", object.generation);
    try std.testing.expectEqualStrings("{\"format_version\":2}", object.bytes);
    try std.testing.expectEqual(@as(usize, 2), harness.transport.requests.items.len);
    try expectUrl(harness.transport.requests.items[0].url, "/storage/v1/b/ziac-state-bucket/o/ziac%2Fstate%2Fapi%2Fprod%2Fresources.json?fields=generation");
    try expectUrl(harness.transport.requests.items[1].url, "/storage/v1/b/ziac-state-bucket/o/ziac%2Fstate%2Fapi%2Fprod%2Fresources.json?alt=media&generation=41");
}

test "GCS state writes use generation zero then exact observed generation" {
    const responses = [_]zstd.Http.Response{
        .{ .status = 200, .body = "{\"generation\":\"41\"}" },
        .{ .status = 200, .body = "{\"generation\":\"42\"}" },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const objects = harness.gcs.objectStore();

    var created = try objects.put(state_key, "first", .absent);
    defer created.deinit();
    var updated = try objects.put(state_key, "second", .{ .generation = created.generation });
    defer updated.deinit();
    try std.testing.expectEqualStrings("41", created.generation);
    try std.testing.expectEqualStrings("42", updated.generation);
    try std.testing.expectEqualStrings("POST", harness.transport.requests.items[0].method);
    try std.testing.expectEqualStrings("first", harness.transport.requests.items[0].body);
    try expectUrl(harness.transport.requests.items[0].url, "/upload/storage/v1/b/ziac-state-bucket/o?uploadType=media&name=ziac%2Fstate%2Fapi%2Fprod%2Fresources.json&ifGenerationMatch=0");
    try expectUrl(harness.transport.requests.items[1].url, "/upload/storage/v1/b/ziac-state-bucket/o?uploadType=media&name=ziac%2Fstate%2Fapi%2Fprod%2Fresources.json&ifGenerationMatch=41");
    try std.testing.expectEqualStrings("application/json", harness.transport.requests.items[0].content_type.?);
}

test "GCS state maps precondition failures and conditionally deletes" {
    const responses = [_]zstd.Http.Response{
        .{ .status = 412, .body = "{\"error\":{\"status\":\"FAILED_PRECONDITION\"}}" },
        .{ .status = 204, .body = "" },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const objects = harness.gcs.objectStore();

    try std.testing.expectError(error.Conflict, objects.put(state_key, "stale", .{ .generation = "40" }));
    try objects.delete(state_key, "41");
    try std.testing.expectEqualStrings("DELETE", harness.transport.requests.items[1].method);
    try expectUrl(harness.transport.requests.items[1].url, "/storage/v1/b/ziac-state-bucket/o/ziac%2Fstate%2Fapi%2Fprod%2Fresources.json?ifGenerationMatch=41");
}

test "GCS state validates bucket keys and generations before HTTP" {
    var harness: Harness = undefined;
    harness.init(&.{});
    defer harness.deinit();
    const objects = harness.gcs.objectStore();

    try std.testing.expectError(error.InvalidObjectKey, objects.get("../state.json"));
    try std.testing.expectError(error.InvalidGeneration, objects.put(state_key, "state", .{ .generation = "not-a-generation" }));
    try std.testing.expectError(error.InvalidGeneration, objects.delete(state_key, ""));
    try std.testing.expectEqual(@as(usize, 0), harness.transport.requests.items.len);
    try std.testing.expectError(
        error.InvalidBucket,
        ziac.gcp.gcs_state.Store.init(&harness.client, &harness.context, "Not_A_Bucket"),
    );
    var bounded = try ziac.gcp.gcs_state.Store.initWithOptions(
        &harness.client,
        &harness.context,
        "ziac-state-bucket",
        .{ .max_object_bytes = 4 },
    );
    try std.testing.expectError(error.ObjectTooLarge, bounded.objectStore().put(state_key, "12345", .absent));
    try std.testing.expectEqual(@as(usize, 0), harness.transport.requests.items.len);
}

const Harness = struct {
    token_source: FixedTokenSource,
    cache: auth.TokenCache,
    transport: @import("gcp_client_test.zig").RecordingTransport,
    client: gclient.Client,
    context: ziac.provider.OperationContext,
    gcs: ziac.gcp.gcs_state.Store,

    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.token_source = .{};
        self.cache = auth.TokenCache.init(self.token_source.tokenSource(), 300);
        self.transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{
            .storage = "https://storage.example.test",
        });
        self.context = ziac.provider.OperationContext.init(std.testing.allocator);
        self.gcs = ziac.gcp.gcs_state.Store.init(&self.client, &self.context, "ziac-state-bucket") catch unreachable;
    }

    fn deinit(self: *Harness) void {
        self.transport.deinit();
        self.cache.deinit(std.testing.allocator);
        self.* = undefined;
    }
};

const FixedTokenSource = struct {
    fn tokenSource(self: *FixedTokenSource) auth.TokenSource {
        return .{ .ptr = self, .fetchFn = fetch };
    }

    fn fetch(_: *anyopaque, allocator: std.mem.Allocator, now_seconds: u64) auth.AuthError!auth.AccessToken {
        return auth.AccessToken.initOwned(allocator, .{
            .access_token = "state-token",
            .token_type = "Bearer",
            .expires_at_seconds = now_seconds + 3_600,
        });
    }
};

fn expectUrl(actual: []const u8, suffix: []const u8) !void {
    try std.testing.expect(std.mem.endsWith(u8, actual, suffix));
}
