const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const actions = ziac.gcp.event_integration_actions;

test "event integration actions bind capability to target and payload" {
    var harness: Harness = undefined;
    harness.init(&.{});
    defer harness.deinit();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    const runner = actions.Runner{ .client = &harness.client };
    const target = makeTarget("projects/events-prod/locations/europe-west1/messageBuses/application-events");
    const payload: actions.Payload = .{ .json_event = "{\"specversion\":\"1.0\",\"id\":\"evt-1\",\"source\":\"ziac\",\"type\":\"com.example.created\"}" };
    const digest = actions.actionDigest(.publish_json, target, payload);
    try std.testing.expectError(error.ActionDigestMismatch, runner.runAlloc(&context, capability(digest[0..]), .publish_json, target, payload, "wrong"));
    try std.testing.expectEqual(@as(usize, 0), harness.transport.requests.items.len);
}

test "event integration actions call only explicit Google action methods" {
    const responses = [_]zstd.Http.Response{
        ok("{}"),
        ok("{\"name\":\"projects/events-prod/locations/europe-west1/operations/repair\"}"),
        ok("{\"name\":\"projects/events-prod/locations/europe-west1/operations/retry\"}"),
        ok("{\"name\":\"projects/events-prod/locations/europe-west1/operations/refresh\"}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    const runner = actions.Runner{ .client = &harness.client };

    var published = try run(&runner, &context, .publish_json, makeTarget("projects/events-prod/locations/europe-west1/messageBuses/application-events"), .{ .json_event = "{\"specversion\":\"1.0\",\"id\":\"evt-1\",\"source\":\"ziac\",\"type\":\"com.example.created\"}" });
    defer published.deinit();
    var repaired = try run(&runner, &context, .repair_eventing, makeTarget("projects/events-prod/locations/europe-west1/connections/crm"), .none);
    defer repaired.deinit();
    var retried = try run(&runner, &context, .retry_subscription, makeTarget("projects/events-prod/locations/europe-west1/connections/crm/eventSubscriptions/accounts"), .none);
    defer retried.deinit();
    var refreshed = try run(&runner, &context, .refresh_schema, makeTarget("projects/events-prod/locations/europe-west1/connections/crm"), .none);
    defer refreshed.deinit();

    try std.testing.expect(std.mem.startsWith(u8, harness.transport.requests.items[0].url, "https://eventarc-publishing.example.test/"));
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[0].url, ":publish"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "jsonMessage") != null);
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[1].url, ":repairEventing"));
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[2].url, ":retry"));
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[3].url, "/connectionSchemaMetadata:refresh"));
}

fn run(runner: *const actions.Runner, context: *ziac.provider.OperationContext, action: actions.Action, target: actions.Target, payload: actions.Payload) !actions.Receipt {
    const digest = actions.actionDigest(action, target, payload);
    return runner.runAlloc(context, capability(digest[0..]), action, target, payload, digest[0..]);
}
fn makeTarget(name: []const u8) actions.Target {
    return .{ .stage = "prod", .project = "events-prod", .resource_name = name, .now_millis = 1_000, .started_at_millis = 900 };
}
fn capability(digest: []const u8) ziac.agent_contract.CapabilityEnvelope {
    return .{ .id = "event-action", .stages = &.{"prod"}, .projects = &.{"events-prod"}, .providers = &.{.gcp}, .permissions = .{ .apply = true }, .budget = .{ .max_creates = 1, .max_updates = 1, .max_regions = 1 }, .expires_at_millis = 10_000, .approved_plan_digest = digest };
}

const Harness = struct {
    source: FixedTokenSource,
    cache: ziac.gcp.auth.TokenCache,
    transport: @import("gcp_client_test.zig").RecordingTransport,
    client: ziac.gcp.client.Client,
    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.source = .{};
        self.cache = ziac.gcp.auth.TokenCache.init(self.source.tokenSource(), 300);
        self.transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = ziac.gcp.client.Client.init(self.transport.client(), &self.cache, .{ .eventarc_publishing = "https://eventarc-publishing.example.test", .connectors = "https://connectors.example.test" });
    }
    fn deinit(self: *Harness) void {
        self.transport.deinit();
        self.cache.deinit(std.testing.allocator);
    }
};
const FixedTokenSource = struct {
    fn tokenSource(self: *FixedTokenSource) ziac.gcp.auth.TokenSource {
        return .{ .ptr = self, .fetchFn = fetch };
    }
    fn fetch(_: *anyopaque, allocator: std.mem.Allocator, now: u64) ziac.gcp.auth.AuthError!ziac.gcp.auth.AccessToken {
        return ziac.gcp.auth.AccessToken.initOwned(allocator, .{ .access_token = "token", .token_type = "Bearer", .expires_at_seconds = now + 3600 });
    }
};
fn ok(body: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = body };
}
