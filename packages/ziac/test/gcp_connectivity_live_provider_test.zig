const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const connectivity = ziac.gcp.connectivity;
const gclient = ziac.gcp.client;

test "VPN tunnels resolve PSKs only in the mutation body and resume regional operations" {
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"insert-tunnel\"}"),
        ok("{\"name\":\"insert-tunnel\",\"status\":\"DONE\"}"),
        ok(tunnelJson()),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var secrets = FixedSecretSource{};
    const handler = ziac.gcp.connectivity_provider.Handler{
        .client = &harness.client,
        .operation_policy = .{ .poll_interval_millis = 0 },
        .secret_source = secrets.secretSource(),
    };
    var tunnel = try buildTunnel();
    defer tunnel.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.create(&context, tunnel.node);
    defer pending.deinit();
    try std.testing.expect(!pending.completed);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "super-secret-psk") != null);
    const state_json = try pending.observed_inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(state_json);
    try std.testing.expect(std.mem.indexOf(u8, state_json, "super-secret-psk") == null);
    try std.testing.expect(std.mem.indexOf(u8, state_json, "gcp-secret-manager") != null);

    context.operation_handle = pending.operation_handle;
    var read = try handler.read(&context, tunnel.node, null);
    defer read.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].url, "/regions/europe-west1/operations/insert-tunnel") != null);
    try std.testing.expectEqualStrings("ESTABLISHED", outputValue(read.present, "status").string);
    try std.testing.expectEqualStrings("hash-only", outputValue(read.present, "shared_secret_hash").string);
    try std.testing.expect(inputValue(read.present.observed_inputs, "shared_secret") == .secret_ref);
}

test "router interfaces retry fingerprints and preserve unrelated router children" {
    const responses = [_]zstd.Http.Response{
        ok(routerJson("fingerprint-a")),
        precondition(),
        ok(routerJson("fingerprint-b")),
        ok("{\"name\":\"patch-router\"}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.connectivity_provider.Handler{ .client = &harness.client, .conflict_retries = 1 };
    var interface = try buildRouterInterface();
    defer interface.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.create(&context, interface.node);
    defer pending.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "unowned-interface") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "corp-0") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].body, "fingerprint-b") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].body, "unowned-peer") != null);
}

test "network peering uses native add update and remove action methods" {
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"add-peering\"}"),
        ok("{\"name\":\"update-peering\"}"),
        ok("{\"name\":\"remove-peering\"}"),
        ok("{\"name\":\"remove-peering\",\"status\":\"DONE\"}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.connectivity_provider.Handler{ .client = &harness.client, .operation_policy = .{ .poll_interval_millis = 0 } };
    var peering = try buildPeering(true);
    defer peering.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try handler.create(&context, peering.node);
    defer created.deinit();
    var observed = try ziac.provider.ResourceResult.init(std.testing.allocator, "projects/ziac-dev/global/networks/platform/peerings/platform-to-data", peering.node.inputs, &.{}, null);
    defer observed.deinit();
    var updated = try handler.update(&context, peering.node, &observed);
    defer updated.deinit();
    try handler.delete(&context, peering.node, observed.physical_id);

    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[0].url, "/networks/platform/addPeering"));
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[1].url, "/networks/platform/updatePeering"));
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[2].url, "/networks/platform/removePeering"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "projects/data-prod/global/networks/data") != null);
}

test "NCC hubs checkpoint generic operations and patch with field masks and etags" {
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"projects/ziac-dev/locations/global/operations/create-hub\",\"done\":false}"),
        ok("{\"name\":\"projects/ziac-dev/locations/global/operations/create-hub\",\"done\":true}"),
        ok(hubJson("etag-a", "old description")),
        ok("{\"name\":\"projects/ziac-dev/locations/global/operations/update-hub\",\"done\":false}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.connectivity_provider.Handler{ .client = &harness.client, .operation_policy = .{ .poll_interval_millis = 0 } };
    var hub = try buildHub("new description");
    defer hub.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.create(&context, hub.node);
    defer pending.deinit();
    context.operation_handle = pending.operation_handle;
    var current_read = try handler.read(&context, hub.node, null);
    defer current_read.deinit();
    context.operation_handle = null;
    var updating = try handler.update(&context, hub.node, &current_read.present);
    defer updating.deinit();

    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].url, "/v1/projects/ziac-dev/locations/global/hubs?hubId=global-mesh") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].url, "/v1/projects/ziac-dev/locations/global/operations/create-hub") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].url, "updateMask=description%2Clabels%2CpolicyMode%2CpresetTopology%2CexportPsc") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].body, "etag-a") != null);
}

test "NCC router appliances and PSC producer allowlists use descriptor-shaped bodies" {
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/create-spoke\",\"done\":false}"),
        ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/create-policy\",\"done\":false}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.connectivity_provider.Handler{ .client = &harness.client };
    var spoke = try connectivity.Spoke.build(std.testing.allocator, config(), .{
        .name = "router-appliance",
        .location = "europe-west1",
        .hub = known("projects/ziac-dev/locations/global/hubs/global-mesh"),
        .link = .{ .router_appliances = &.{.{
            .virtual_machine = known("projects/ziac-dev/zones/europe-west1-b/instances/router-0"),
            .ip_address = "10.42.0.10",
        }} },
    });
    defer spoke.deinit(std.testing.allocator);
    var policy = try connectivity.ServiceConnectionPolicy.build(std.testing.allocator, config(), .{
        .name = "alloydb",
        .location = "europe-west1",
        .network = known("projects/ziac-dev/global/networks/platform"),
        .service_class = "gcp-alloydb",
        .subnetworks = &.{known("projects/ziac-dev/regions/europe-west1/subnetworks/psc")},
        .producer_location = .custom,
        .allowed_producer_hierarchy = &.{ "projects/producer-prod", "organizations/123456" },
    });
    defer policy.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var spoke_pending = try handler.create(&context, spoke.node);
    defer spoke_pending.deinit();
    var policy_pending = try handler.create(&context, policy.node);
    defer policy_pending.deinit();

    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "\"virtualMachine\":\"projects/ziac-dev/zones/europe-west1-b/instances/router-0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "\"ipAddress\":\"10.42.0.10\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"producerInstanceLocation\":\"CUSTOM_RESOURCE_HIERARCHY_LEVELS\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "projects/producer-prod") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "organizations/123456") != null);
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
}

fn buildTunnel() !connectivity.VpnTunnel {
    return connectivity.VpnTunnel.build(std.testing.allocator, config(), .{
        .name = "corp-0",
        .region = "europe-west1",
        .vpn_gateway = known("projects/ziac-dev/regions/europe-west1/vpnGateways/corp-ha"),
        .vpn_gateway_interface = 0,
        .peer = .{ .external = .{ .gateway = known("projects/ziac-dev/global/externalVpnGateways/corp-peer"), .interface = 0 } },
        .router = known("projects/ziac-dev/regions/europe-west1/routers/corp"),
        .shared_secret = .known(.{ .provider = "gcp-secret-manager", .resource = "projects/ziac-dev/secrets/vpn-psk-0", .version = "1" }),
    });
}

fn buildRouterInterface() !connectivity.RouterInterface {
    return connectivity.RouterInterface.build(std.testing.allocator, config(), .{
        .name = "corp-0",
        .region = "europe-west1",
        .router_name = "corp",
        .router = known("projects/ziac-dev/regions/europe-west1/routers/corp"),
        .vpn_tunnel = known("projects/ziac-dev/regions/europe-west1/vpnTunnels/corp-0"),
        .ip_range = "169.254.10.1/30",
    });
}

fn buildPeering(import_routes: bool) !connectivity.NetworkPeering {
    return connectivity.NetworkPeering.build(std.testing.allocator, config(), .{
        .name = "platform-to-data",
        .network_name = "platform",
        .network = known("projects/ziac-dev/global/networks/platform"),
        .peer_network = known("projects/data-prod/global/networks/data"),
        .import_custom_routes = import_routes,
    });
}

fn buildHub(description: []const u8) !connectivity.Hub {
    return connectivity.Hub.build(std.testing.allocator, config(), .{ .name = "global-mesh", .description = description });
}

fn known(text: []const u8) ziac.PublicOutput([]const u8) {
    return .known(text);
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
            .network_connectivity = "https://networkconnectivity.example.test",
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

const FixedSecretSource = struct {
    fn secretSource(self: *FixedSecretSource) ziac.secret.SecretSource {
        return .{ .ptr = self, .resolveFn = resolve };
    }
    fn resolve(_: *anyopaque, _: *ziac.provider.OperationContext, allocator: std.mem.Allocator, _: ziac.value.SecretReference) ziac.provider.ProviderError!ziac.secret.SecretPayload {
        return ziac.secret.SecretPayload.initOwned(allocator, "super-secret-psk", null);
    }
};

fn outputValue(result: ziac.provider.ResourceResult, name: []const u8) ziac.value.Value {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name)) return item.value;
    unreachable;
}

fn inputValue(inputs: ziac.value.Value, name: []const u8) ziac.value.Value {
    for (inputs.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    unreachable;
}

fn tunnelJson() []const u8 {
    return "{\"name\":\"corp-0\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/regions/europe-west1/vpnTunnels/corp-0\",\"description\":\"\",\"ikeVersion\":2,\"vpnGateway\":\"projects/ziac-dev/regions/europe-west1/vpnGateways/corp-ha\",\"vpnGatewayInterface\":0,\"peerExternalGateway\":\"projects/ziac-dev/global/externalVpnGateways/corp-peer\",\"peerExternalGatewayInterface\":0,\"router\":\"projects/ziac-dev/regions/europe-west1/routers/corp\",\"status\":\"ESTABLISHED\",\"detailedStatus\":\"Tunnel is up\",\"sharedSecretHash\":\"hash-only\"}";
}

fn routerJson(fingerprint: []const u8) []const u8 {
    return if (std.mem.eql(u8, fingerprint, "fingerprint-a"))
        "{\"name\":\"corp\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/regions/europe-west1/routers/corp\",\"fingerprint\":\"fingerprint-a\",\"network\":\"projects/ziac-dev/global/networks/platform\",\"interfaces\":[{\"name\":\"unowned-interface\",\"ipRange\":\"169.254.20.1/30\"}],\"bgpPeers\":[{\"name\":\"unowned-peer\",\"interfaceName\":\"unowned-interface\",\"peerAsn\":64530,\"ipAddress\":\"169.254.20.1\",\"peerIpAddress\":\"169.254.20.2\"}]}"
    else
        "{\"name\":\"corp\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/regions/europe-west1/routers/corp\",\"fingerprint\":\"fingerprint-b\",\"network\":\"projects/ziac-dev/global/networks/platform\",\"interfaces\":[{\"name\":\"unowned-interface\",\"ipRange\":\"169.254.20.1/30\"}],\"bgpPeers\":[{\"name\":\"unowned-peer\",\"interfaceName\":\"unowned-interface\",\"peerAsn\":64530,\"ipAddress\":\"169.254.20.1\",\"peerIpAddress\":\"169.254.20.2\"}]}";
}

fn hubJson(etag: []const u8, description: []const u8) []const u8 {
    if (std.mem.eql(u8, etag, "etag-a") and std.mem.eql(u8, description, "old description")) return "{\"name\":\"projects/ziac-dev/locations/global/hubs/global-mesh\",\"description\":\"old description\",\"labels\":{},\"policyMode\":\"PRESET\",\"presetTopology\":\"MESH\",\"exportPsc\":false,\"state\":\"ACTIVE\",\"etag\":\"etag-a\"}";
    unreachable;
}

fn ok(body: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = @constCast(body) };
}

fn precondition() zstd.Http.Response {
    return .{ .status = 412, .body = @constCast("{\"error\":{\"code\":412,\"status\":\"FAILED_PRECONDITION\",\"message\":\"fingerprint changed\"}}") };
}
