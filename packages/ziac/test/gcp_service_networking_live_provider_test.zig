const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;

test "private service range lifecycle uses Compute global operations" {
    const remote = "{\"name\":\"redis-range\",\"address\":\"10.40.0.0\",\"prefixLength\":20,\"addressType\":\"INTERNAL\",\"purpose\":\"VPC_PEERING\",\"network\":\"projects/ziac-dev/global/networks/platform\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/global/addresses/redis-range\"}";
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"insert-range\",\"status\":\"PENDING\"}"),
        ok("{\"name\":\"insert-range\",\"status\":\"DONE\"}"),
        ok(remote),
        ok(remote),
        ok("{\"name\":\"delete-range\",\"status\":\"PENDING\"}"),
        ok("{\"name\":\"delete-range\",\"status\":\"DONE\"}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.service_networking_provider.Handler{ .client = &harness.client, .operation_policy = .{ .poll_interval_millis = 0 } };
    var range = try buildRange("redis-range");
    defer range.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.create(&context, range.node);
    defer pending.deinit();
    context.operation_handle = pending.operation_handle;
    var created = try handler.read(&context, range.node, null);
    defer created.deinit();
    context.operation_handle = null;
    var diff = try ziac.gcp.service_networking_provider.Handler.diff(&context, range.node, &created.present);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.noop, diff.kind);
    var imported = try handler.importResource(&context, range.node, created.present.physical_id);
    defer imported.deinit();
    try handler.delete(&context, range.node, created.present.physical_id);

    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[0].url, "/compute/v1/projects/ziac-dev/global/addresses"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "VPC_PEERING") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].url, "/global/operations/insert-range") != null);
    try std.testing.expectEqualStrings("10.40.0.0", outputString(created.present, "address"));
}

test "private service connection reconciles reserved ranges with force-safe patch" {
    const initial = connectionJson("redis-range");
    const changed = connectionJson("redis-range,spanner-range");
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"operations/connect\",\"done\":false}"),
        ok("{\"name\":\"operations/connect\",\"done\":true}"),
        ok(initial),
        ok("{\"name\":\"operations/patch\",\"done\":false}"),
        ok("{\"name\":\"operations/patch\",\"done\":true}"),
        ok(changed),
        ok("{\"name\":\"operations/delete\",\"done\":false}"),
        ok("{\"name\":\"operations/delete\",\"done\":true}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.service_networking_provider.Handler{ .client = &harness.client, .operation_policy = .{ .poll_interval_millis = 0 } };
    var connection = try buildConnection(&.{"redis-range"});
    defer connection.deinit(std.testing.allocator);
    var changed_connection = try buildConnection(&.{ "spanner-range", "redis-range" });
    defer changed_connection.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.create(&context, connection.node);
    defer pending.deinit();
    context.operation_handle = pending.operation_handle;
    var created = try handler.read(&context, connection.node, null);
    defer created.deinit();
    context.operation_handle = null;
    var diff = try ziac.gcp.service_networking_provider.Handler.diff(&context, changed_connection.node, &created.present);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, diff.kind);
    var update = try handler.update(&context, changed_connection.node, &created.present);
    defer update.deinit();
    context.operation_handle = update.operation_handle;
    var updated = try handler.read(&context, changed_connection.node, null);
    defer updated.deinit();
    context.operation_handle = null;
    try handler.delete(&context, changed_connection.node, updated.present.physical_id);

    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].url, "/v1/services/servicenetworking.googleapis.com/connections") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[2].url, "network=projects%2Fziac-dev%2Fglobal%2Fnetworks%2Fplatform") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].url, "updateMask=reservedPeeringRanges") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].url, "force=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[6].body, "projects/ziac-dev/global/networks/platform") != null);
    try std.testing.expectEqualStrings("servicenetworking-googleapis-com", outputString(updated.present, "peering"));
}

const Harness = struct {
    source: FixedTokenSource,
    cache: auth.TokenCache,
    transport: @import("gcp_client_test.zig").RecordingTransport,
    client: gclient.Client,

    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.source = .{};
        self.cache = auth.TokenCache.init(self.source.tokenSource(), 300);
        self.transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{
            .compute = "https://compute.example.test",
            .service_networking = "https://servicenetworking.example.test",
        });
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

fn buildRange(name: []const u8) !ziac.gcp.service_networking.PrivateServiceRange {
    return ziac.gcp.service_networking.PrivateServiceRange.build(std.testing.allocator, config(), .{
        .name = name,
        .network = "projects/ziac-dev/global/networks/platform",
        .prefix_length = 20,
        .protect = false,
        .retain_on_delete = false,
    });
}

fn buildConnection(names: []const []const u8) !ziac.gcp.service_networking.Connection {
    const ranges = try std.testing.allocator.alloc(ziac.gcp.service_networking.ReservedRange, names.len);
    defer std.testing.allocator.free(ranges);
    for (names, 0..) |name, index| ranges[index] = .{ .name = name, .dependency = ziac.PublicOutput([]const u8).known(name) };
    return ziac.gcp.service_networking.Connection.build(std.testing.allocator, config(), .{
        .name = "google-managed-services",
        .network = "projects/ziac-dev/global/networks/platform",
        .reserved_ranges = ranges,
        .protect = false,
        .retain_on_delete = false,
    });
}

fn config() ziac.gcp.config.ProviderConfig {
    return .{ .project_id = "ziac-dev", .primary_region = "europe-west1", .service_regions = &.{"europe-west1"} };
}

fn connectionJson(comma_ranges: []const u8) []const u8 {
    if (std.mem.eql(u8, comma_ranges, "redis-range")) return "{\"connections\":[{\"network\":\"projects/ziac-dev/global/networks/platform\",\"reservedPeeringRanges\":[\"redis-range\"],\"peering\":\"servicenetworking-googleapis-com\",\"service\":\"services/servicenetworking.googleapis.com\"}]}";
    return "{\"connections\":[{\"network\":\"projects/ziac-dev/global/networks/platform\",\"reservedPeeringRanges\":[\"redis-range\",\"spanner-range\"],\"peering\":\"servicenetworking-googleapis-com\",\"service\":\"services/servicenetworking.googleapis.com\"}]}";
}

fn outputString(result: ziac.provider.ResourceResult, name: []const u8) []const u8 {
    for (result.outputs) |candidate| if (std.mem.eql(u8, candidate.name, name)) return candidate.value.string;
    unreachable;
}

fn ok(body: []const u8) zstd.Http.Response {
    return .{ .status = 200, .headers = &.{}, .body = body };
}
