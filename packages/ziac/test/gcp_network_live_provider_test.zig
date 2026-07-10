const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;

const config = ziac.gcp.config.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
};
const router_link = "https://compute.googleapis.com/compute/v1/projects/ziac-dev/regions/europe-west1/routers/api-europe-west1";
const subnet_link = "https://compute.googleapis.com/compute/v1/projects/ziac-dev/regions/europe-west1/subnetworks/api-europe-west1";
const address_link = "https://compute.googleapis.com/compute/v1/projects/ziac-dev/regions/europe-west1/addresses/api-europe-west1";
const unrelated_nat = "{\"name\":\"unrelated-nat\",\"type\":\"PUBLIC\",\"natIpAllocateOption\":\"AUTO_ONLY\",\"sourceSubnetworkIpRangesToNat\":\"ALL_SUBNETWORKS_ALL_IP_RANGES\",\"natIps\":[],\"subnetworks\":[],\"minPortsPerVm\":64,\"enableEndpointIndependentMapping\":true}";
const target_nat = "{\"name\":\"api-europe-west1\",\"type\":\"PUBLIC\",\"natIpAllocateOption\":\"MANUAL_ONLY\",\"sourceSubnetworkIpRangesToNat\":\"LIST_OF_SUBNETWORKS\",\"natIps\":[\"" ++ address_link ++ "\"],\"subnetworks\":[{\"name\":\"" ++ subnet_link ++ "\",\"sourceIpRangesToNat\":[\"ALL_IP_RANGES\"]}],\"minPortsPerVm\":64,\"enableEndpointIndependentMapping\":true}";

test "Cloud NAT lifecycle preserves router fingerprint and unrelated NATs" {
    var nat = try ziac.gcp.network.RouterNat.build(std.testing.allocator, config, .{
        .name = "api-europe-west1",
        .region = "europe-west1",
        .router_name = "api-europe-west1",
        .router = ziac.PublicOutput([]const u8).fromResource("gcp.compute.Router.europe-west1.api-europe-west1", "self_link"),
        .subnetwork = ziac.PublicOutput([]const u8).fromResource("gcp.compute.Subnetwork.europe-west1.api-europe-west1", "self_link"),
        .nat_ip = ziac.PublicOutput([]const u8).fromResource("gcp.compute.RegionalAddress.europe-west1.api-europe-west1", "self_link"),
    });
    defer nat.deinit(std.testing.allocator);
    var store = try dependencyState();
    defer store.deinit();
    const responses = [_]zstd.Http.Response{
        routerJson(false, "fingerprint-a"),
        routerJson(false, "fingerprint-a"),
        operation("patch-nat"),
        done("patch-nat"),
        routerJson(true, "fingerprint-b"),
        routerJson(true, "fingerprint-b"),
        operation("delete-nat"),
        done("delete-nat"),
        routerJson(false, "fingerprint-c"),
        routerJson(true, "fingerprint-d"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const provider = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    context.state = &store;

    var before = try provider.readWithContext(&context, nat.node);
    defer before.deinit();
    try std.testing.expect(before == .absent);
    var creating = try provider.createWithContext(&context, nat.node);
    defer creating.deinit();
    try std.testing.expect(!creating.completed);
    context.physical_id = creating.physical_id;
    context.operation_handle = creating.operation_handle;
    var present = try provider.readWithContext(&context, nat.node);
    defer present.deinit();
    try std.testing.expect(present == .present);
    try std.testing.expectEqual(nat.node.inputs_hash, present.present.observed_hash);
    var noop = try provider.diffWithContext(&context, nat.node, &present.present);
    defer noop.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.noop, noop.kind);

    context.operation_handle = null;
    try provider.deleteWithContext(&context, nat.node, creating.physical_id);
    var gone = try provider.readWithContext(&context, nat.node);
    defer gone.deinit();
    try std.testing.expect(gone == .absent);
    var imported = try provider.importWithContext(&context, nat.node, creating.physical_id);
    defer imported.deinit();
    try std.testing.expectEqualStrings(creating.physical_id, imported.physical_id);

    const create_body = harness.transport.requests.items[2].body;
    try std.testing.expect(std.mem.indexOf(u8, create_body, "\"fingerprint\":\"fingerprint-a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, create_body, "unrelated-nat") != null);
    try std.testing.expect(std.mem.indexOf(u8, create_body, "api-europe-west1") != null);
    const delete_body = harness.transport.requests.items[6].body;
    try std.testing.expect(std.mem.indexOf(u8, delete_body, "\"fingerprint\":\"fingerprint-b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, delete_body, "unrelated-nat") != null);
    try expectNatAbsent(delete_body, "api-europe-west1");
}

fn expectNatAbsent(router_json: []const u8, name: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, router_json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const nats = root.get("nats").?.array;
    for (nats.items) |nat| {
        try std.testing.expect(!std.mem.eql(u8, nat.object.get("name").?.string, name));
    }
}

const Harness = struct {
    token_source: FixedTokenSource,
    cache: auth.TokenCache,
    transport: @import("gcp_client_test.zig").RecordingTransport,
    client: gclient.Client,
    live: ziac.gcp.live_provider.LiveProvider,

    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.token_source = .{};
        self.cache = auth.TokenCache.init(self.token_source.tokenSource(), 300);
        self.transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{ .compute = "https://compute.example.test" });
        self.live = ziac.gcp.live_provider.LiveProvider.init(&self.client);
        self.live.operation_policy = .{ .poll_interval_millis = 1 };
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

fn dependencyState() !ziac.InMemoryStateStore {
    var store = ziac.InMemoryStateStore.init(std.testing.allocator);
    errdefer store.deinit();
    try putOutput(&store, "gcp.compute.Router.europe-west1.api-europe-west1", "self_link", router_link);
    try putOutput(&store, "gcp.compute.Subnetwork.europe-west1.api-europe-west1", "self_link", subnet_link);
    try putOutput(&store, "gcp.compute.RegionalAddress.europe-west1.api-europe-west1", "self_link", address_link);
    return store;
}

fn putOutput(store: *ziac.InMemoryStateStore, resource_id: []const u8, name: []const u8, output_value: []const u8) !void {
    try store.put(.{
        .resource_id = resource_id,
        .provider = .gcp,
        .type_name = resource_id,
        .logical_id = resource_id,
        .desired_hash = "hash",
        .outputs = &.{.{ .name = name, .value = .{ .string = output_value } }},
        .status = .created,
    });
}

fn routerJson(comptime include_target: bool, comptime fingerprint: []const u8) zstd.Http.Response {
    const target = if (include_target) "," ++ target_nat else "";
    return .{
        .status = 200,
        .body = "{\"name\":\"api-europe-west1\",\"selfLink\":\"" ++ router_link ++ "\",\"fingerprint\":\"" ++ fingerprint ++ "\",\"customField\":\"preserve-me\",\"nats\":[" ++ unrelated_nat ++ target ++ "]}",
    };
}

fn operation(comptime name: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = "{\"name\":\"" ++ name ++ "\"}" };
}

fn done(comptime name: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = "{\"name\":\"" ++ name ++ "\",\"status\":\"DONE\"}" };
}
