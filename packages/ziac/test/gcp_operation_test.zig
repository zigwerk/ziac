const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;
const operation = ziac.gcp.operation;

test "GCP operation targets build generic global and regional poll URLs" {
    var generic = try operation.Target.genericAlloc(
        std.testing.allocator,
        "https://run.example.test/v2",
        "projects/p/locations/r/operations/op-generic",
    );
    defer generic.deinit(std.testing.allocator);
    var global = try operation.Target.computeGlobalAlloc(
        std.testing.allocator,
        "https://compute.example.test/compute/v1",
        "p",
        "op-global",
    );
    defer global.deinit(std.testing.allocator);
    var regional = try operation.Target.computeRegionalAlloc(
        std.testing.allocator,
        "https://compute.example.test/compute/v1",
        "p",
        "europe-west1",
        "op-regional",
    );
    defer regional.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("https://run.example.test/v2/projects/p/locations/r/operations/op-generic", generic.url);
    try std.testing.expectEqualStrings("https://compute.example.test/compute/v1/projects/p/global/operations/op-global", global.url);
    try std.testing.expectEqualStrings("https://compute.example.test/compute/v1/projects/p/regions/europe-west1/operations/op-regional", regional.url);
}

test "GCP operation polling completes generic global and regional operations" {
    const responses = [_]zstd.Http.Response{
        .{ .status = 200, .body = "{\"name\":\"op-generic\",\"done\":false}" },
        .{ .status = 200, .body = "{\"name\":\"op-generic\",\"done\":true,\"response\":{\"name\":\"service\"}}" },
        .{ .status = 200, .body = "{\"name\":\"op-global\",\"status\":\"PENDING\"}" },
        .{ .status = 200, .body = "{\"name\":\"op-global\",\"status\":\"DONE\"}" },
        .{ .status = 200, .body = "{\"name\":\"op-regional\",\"status\":\"DONE\"}" },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var clock = ziac.fx.Clock.fake(0);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    context.clock = &clock;

    var generic = try operation.Target.genericAlloc(std.testing.allocator, "https://run.example.test/v2", "projects/p/locations/r/operations/op-generic");
    defer generic.deinit(std.testing.allocator);
    var generic_result = try operation.waitAlloc(&harness.client, &context, generic, .{ .poll_interval_millis = 10 });
    defer generic_result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, generic_result.payload, "service") != null);

    var global = try operation.Target.computeGlobalAlloc(std.testing.allocator, "https://compute.example.test/compute/v1", "p", "op-global");
    defer global.deinit(std.testing.allocator);
    var global_result = try operation.waitAlloc(&harness.client, &context, global, .{ .poll_interval_millis = 10 });
    defer global_result.deinit(std.testing.allocator);

    var regional = try operation.Target.computeRegionalAlloc(std.testing.allocator, "https://compute.example.test/compute/v1", "p", "europe-west1", "op-regional");
    defer regional.deinit(std.testing.allocator);
    var regional_result = try operation.waitAlloc(&harness.client, &context, regional, .{ .poll_interval_millis = 10 });
    defer regional_result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 20), clock.nowMs());
    try std.testing.expectEqual(@as(usize, 5), harness.transport.cursor);
}

test "GCP operation polling retries transient failures with retry-after" {
    const responses = [_]zstd.Http.Response{
        .{
            .status = 503,
            .headers = &.{.{ .name = "Retry-After", .value = "1" }},
            .body = "{\"error\":{\"code\":503,\"status\":\"UNAVAILABLE\",\"message\":\"later\"}}",
        },
        .{ .status = 200, .body = "{\"name\":\"op\",\"done\":false}" },
        .{ .status = 200, .body = "{\"name\":\"op\",\"done\":true}" },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var clock = ziac.fx.Clock.fake(0);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    context.clock = &clock;
    var target = try operation.Target.genericAlloc(std.testing.allocator, "https://run.example.test/v2", "operations/op");
    defer target.deinit(std.testing.allocator);

    var result = try operation.waitAlloc(&harness.client, &context, target, .{
        .poll_interval_millis = 100,
        .max_transient_failures = 2,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 1_100), clock.nowMs());
}

test "GCP operation polling honors timeout and cancellation" {
    const responses = [_]zstd.Http.Response{.{ .status = 200, .body = "{\"name\":\"op\",\"done\":false}" }};
    var timeout_harness: Harness = undefined;
    timeout_harness.init(&responses);
    defer timeout_harness.deinit();
    var clock = ziac.fx.Clock.fake(0);
    var timeout_context = ziac.provider.OperationContext.init(std.testing.allocator);
    timeout_context.clock = &clock;
    timeout_context.deadline_millis = 50;
    var target = try operation.Target.genericAlloc(std.testing.allocator, "https://run.example.test/v2", "operations/op");
    defer target.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.ProviderTimeout,
        operation.waitAlloc(&timeout_harness.client, &timeout_context, target, .{ .poll_interval_millis = 100 }),
    );

    var cancelled = true;
    var cancel_harness: Harness = undefined;
    cancel_harness.init(&responses);
    defer cancel_harness.deinit();
    var cancel_context = ziac.provider.OperationContext.init(std.testing.allocator);
    cancel_context.cancellation = .{ .ptr = &cancelled, .isCancelledFn = boolCancelled };
    try std.testing.expectError(
        error.ProviderCancelled,
        operation.waitAlloc(&cancel_harness.client, &cancel_context, target, .{}),
    );
    try std.testing.expectEqual(@as(usize, 0), cancel_harness.transport.cursor);
}

const Harness = struct {
    token_source: FixedTokenSource,
    cache: auth.TokenCache,
    transport: @import("gcp_client_test.zig").RecordingTransport,
    client: gclient.Client,

    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.token_source = .{};
        self.cache = auth.TokenCache.init(self.token_source.tokenSource(), 300);
        self.transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{
            .run = "https://run.example.test",
            .compute = "https://compute.example.test",
        });
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
            .access_token = "dummy-google-token",
            .token_type = "Bearer",
            .expires_at_seconds = now_seconds + 3_600,
        });
    }
};

fn boolCancelled(raw: *const anyopaque) bool {
    const value: *const bool = @ptrCast(@alignCast(raw));
    return value.*;
}
