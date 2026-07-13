const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;

test "live Eventarc provider resumes LROs preserves etags and normalizes transport outputs" {
    const operation_create = "{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/create-trigger\",\"done\":false}";
    const operation_done = "{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/create-trigger\",\"done\":true,\"response\":{\"name\":\"projects/ziac-dev/locations/europe-west1/triggers/orders-created\",\"uid\":\"uid-1\",\"eventFilters\":[{\"attribute\":\"type\",\"value\":\"google.cloud.pubsub.topic.v1.messagePublished\"}],\"serviceAccount\":\"orders-events@ziac-dev.iam.gserviceaccount.com\",\"destination\":{\"cloudRun\":{\"service\":\"orders-worker\",\"region\":\"europe-west1\",\"path\":\"/events/orders\"}},\"transport\":{\"pubsub\":{\"topic\":\"projects/ziac-dev/topics/orders\",\"subscription\":\"projects/ziac-dev/subscriptions/eventarc-orders\"}},\"eventDataContentType\":\"application/json\",\"etag\":\"etag-1\"}}";
    const trigger_json = "{\"name\":\"projects/ziac-dev/locations/europe-west1/triggers/orders-created\",\"uid\":\"uid-1\",\"eventFilters\":[{\"attribute\":\"type\",\"value\":\"google.cloud.pubsub.topic.v1.messagePublished\"}],\"serviceAccount\":\"orders-events@ziac-dev.iam.gserviceaccount.com\",\"destination\":{\"cloudRun\":{\"service\":\"orders-worker\",\"region\":\"europe-west1\",\"path\":\"/events/orders\"}},\"transport\":{\"pubsub\":{\"topic\":\"projects/ziac-dev/topics/orders\",\"subscription\":\"projects/ziac-dev/subscriptions/eventarc-orders\"}},\"eventDataContentType\":\"application/json\",\"etag\":\"etag-1\"}";
    const operation_update = "{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/update-trigger\",\"done\":false}";
    const operation_update_done = "{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/update-trigger\",\"done\":true,\"response\":" ++ trigger_json ++ "}";
    const operation_delete = "{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/delete-trigger\",\"done\":false}";
    const operation_delete_done = "{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/delete-trigger\",\"done\":true,\"response\":{}}";
    const responses = [_]zstd.Http.Response{
        notFound(), ok(operation_create), ok(operation_done), ok(trigger_json), ok(operation_update), ok(operation_update_done), ok(trigger_json), ok(trigger_json), ok(operation_delete), ok(operation_delete_done),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var trigger = try buildTrigger("/events/orders");
    defer trigger.deinit(std.testing.allocator);
    var changed = try buildTrigger("/events/orders/v2");
    defer changed.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var absent = try live.readWithContext(&context, trigger.node);
    defer absent.deinit();
    var pending = try live.createWithContext(&context, trigger.node);
    defer pending.deinit();
    try std.testing.expect(!pending.completed);
    context.operation_handle = pending.operation_handle;
    var completed = try live.readWithContext(&context, trigger.node);
    defer completed.deinit();
    context.operation_handle = null;
    try std.testing.expectEqualStrings("projects/ziac-dev/subscriptions/eventarc-orders", outputString(completed.present, "transport_subscription"));
    var read = try live.readWithContext(&context, trigger.node);
    defer read.deinit();
    var stable = try live.diffWithContext(&context, trigger.node, &read.present);
    defer stable.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.noop, stable.kind);
    var diff = try live.diffWithContext(&context, changed.node, &read.present);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, diff.kind);
    var update = try live.updateWithContext(&context, changed.node, &read.present);
    defer update.deinit();
    context.operation_handle = update.operation_handle;
    var update_done = try live.readWithContext(&context, changed.node);
    defer update_done.deinit();
    context.operation_handle = null;
    var imported = try live.importWithContext(&context, trigger.node, read.present.physical_id);
    defer imported.deinit();
    try live.deleteWithContext(&context, trigger.node, imported.physical_id);

    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].url, "triggerId=orders-created") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[4].url, "updateMask=eventFilters,serviceAccount,destination,transport,labels,channel,eventDataContentType,retryPolicy") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[4].body, "\"etag\":\"etag-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[8].url, "etag=etag-1") != null);
}

test "live Eventarc reads normalize remote destination drift" {
    const remote = "{\"name\":\"projects/ziac-dev/locations/europe-west1/triggers/orders-created\",\"eventFilters\":[{\"attribute\":\"type\",\"value\":\"google.cloud.pubsub.topic.v1.messagePublished\"}],\"serviceAccount\":\"orders-events@ziac-dev.iam.gserviceaccount.com\",\"destination\":{\"cloudRun\":{\"service\":\"orders-worker\",\"region\":\"europe-west1\",\"path\":\"/events/orders/v2\"}},\"transport\":{\"pubsub\":{\"topic\":\"projects/ziac-dev/topics/orders\"}},\"eventDataContentType\":\"application/json\",\"conditions\":{\"transport\":{\"code\":0}},\"etag\":\"etag-2\"}";
    const responses = [_]zstd.Http.Response{ok(remote)};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var desired = try buildTrigger("/events/orders");
    defer desired.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var read = try live.readWithContext(&context, desired.node);
    defer read.deinit();
    try std.testing.expectEqualStrings("/events/orders/v2", inputString(read.present.observed_inputs, "destination_path"));
    var diff = try live.diffWithContext(&context, desired.node, &read.present);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, diff.kind);
}

const Harness = struct {
    source: FixedTokenSource,
    cache: auth.TokenCache,
    transport: @import("gcp_client_test.zig").RecordingTransport,
    client: gclient.Client,
    live: ziac.gcp.live_provider.LiveProvider,
    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.source = .{};
        self.cache = auth.TokenCache.init(self.source.tokenSource(), 300);
        self.transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{ .eventarc = "https://eventarc.example.test" });
        self.live = ziac.gcp.live_provider.LiveProvider.init(&self.client);
        self.live.operation_policy.poll_interval_millis = 0;
    }
    fn deinit(self: *Harness) void {
        self.transport.deinit();
        self.cache.deinit(std.testing.allocator);
    }
};

const FixedTokenSource = struct {
    fn tokenSource(self: *FixedTokenSource) auth.TokenSource {
        return .{ .ptr = self, .fetchFn = fetch };
    }
    fn fetch(_: *anyopaque, allocator: std.mem.Allocator, now: u64) auth.AuthError!auth.AccessToken {
        return auth.AccessToken.initOwned(allocator, .{ .access_token = "token", .token_type = "Bearer", .expires_at_seconds = now + 3600 });
    }
};

fn buildTrigger(path: []const u8) !ziac.gcp.eventarc.Trigger {
    return ziac.gcp.eventarc.Trigger.build(std.testing.allocator, .{ .project_id = "ziac-dev", .primary_region = "europe-west1" }, .{
        .name = "orders-created",
        .event_filters = &.{.{ .attribute = "type", .value = "google.cloud.pubsub.topic.v1.messagePublished" }},
        .service_account = "orders-events@ziac-dev.iam.gserviceaccount.com",
        .destination = .{ .cloud_run = .{ .service = "orders-worker", .region = "europe-west1", .path = path } },
        .transport_topic = ziac.PublicOutput([]const u8).known("projects/ziac-dev/topics/orders"),
        .retain_on_delete = false,
    });
}

fn outputString(result: ziac.provider.ResourceResult, name: []const u8) []const u8 {
    for (result.outputs) |entry| if (std.mem.eql(u8, entry.name, name)) return switch (entry.value) {
        .string => |text| text,
        else => unreachable,
    };
    unreachable;
}
fn ok(body: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = body };
}
fn notFound() zstd.Http.Response {
    return .{ .status = 404, .body = "{\"error\":{\"code\":404,\"status\":\"NOT_FOUND\"}}" };
}

fn inputString(input: ziac.value.Value, name: []const u8) []const u8 {
    for (input.object) |field| if (std.mem.eql(u8, field.name, name)) return switch (field.value) {
        .string => |text| text,
        else => unreachable,
    };
    unreachable;
}
