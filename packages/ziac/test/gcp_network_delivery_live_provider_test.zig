const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const delivery = ziac.gcp.network_delivery;
const gclient = ziac.gcp.client;

test "firewall lifecycle resumes global operations and patches current fingerprint" {
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"insert-firewall\"}"),
        ok("{\"name\":\"insert-firewall\",\"status\":\"DONE\"}"),
        ok(firewallJson("fingerprint-a", false)),
        ok(firewallJson("fingerprint-a", false)),
        ok("{\"name\":\"patch-firewall\"}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.network_delivery_provider.Handler{
        .client = &harness.client,
        .operation_policy = .{ .poll_interval_millis = 0 },
        .conflict_retries = 1,
    };
    var firewall = try buildFirewall(false);
    defer firewall.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.create(&context, firewall.node);
    defer pending.deinit();
    context.operation_handle = pending.operation_handle;
    var read = try handler.read(&context, firewall.node, null);
    defer read.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].url, "/global/operations/insert-firewall") != null);

    var disabled = try buildFirewall(true);
    defer disabled.deinit(std.testing.allocator);
    var diff = try ziac.gcp.network_delivery_provider.Handler.diff(&context, disabled.node, &read.present);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, diff.kind);
    context.operation_handle = null;
    var updating = try handler.update(&context, disabled.node, &read.present);
    defer updating.deinit();
    try std.testing.expectEqualStrings("PATCH", harness.transport.requests.items[4].method);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[4].body, "\"fingerprint\":\"fingerprint-a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[4].body, "\"disabled\":true") != null);
}

test "route imports canonical global identity and any policy change replaces" {
    const responses = [_]zstd.Http.Response{ok(routeJson())};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.network_delivery_provider.Handler{ .client = &harness.client };
    var route = try buildRoute(900);
    defer route.deinit(std.testing.allocator);
    var changed = try buildRoute(901);
    defer changed.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var imported = try handler.importResource(&context, route.node, "projects/ziac-dev/global/routes/private-egress");
    defer imported.deinit();
    var diff = try ziac.gcp.network_delivery_provider.Handler.diff(&context, changed.node, &imported);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.replace, diff.kind);
}

test "regional backend updates retry fingerprint conflicts without losing desired backends" {
    const responses = [_]zstd.Http.Response{
        ok(backendJson("fingerprint-a", 30)),
        precondition(),
        ok(backendJson("fingerprint-b", 30)),
        ok("{\"name\":\"patch-backend\"}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.network_delivery_provider.Handler{ .client = &harness.client, .conflict_retries = 1 };
    var backend = try buildBackend(45);
    defer backend.deinit(std.testing.allocator);
    var observed_backend = try buildBackend(30);
    defer observed_backend.deinit(std.testing.allocator);
    var observed = try ziac.provider.ResourceResult.init(std.testing.allocator, "projects/ziac-dev/regions/europe-west1/backendServices/api-l4", observed_backend.node.inputs, &.{}, null);
    defer observed.deinit();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.update(&context, backend.node, &observed);
    defer pending.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "fingerprint-a") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].body, "fingerprint-b") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].body, "\"timeoutSec\":45") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].body, "instanceGroups/api") != null);
}

test "regional internal address and forwarding rule expose allocated address and immutable drift" {
    const responses = [_]zstd.Http.Response{ ok(addressJson()), ok(forwardingJson("80")) };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.network_delivery_provider.Handler{ .client = &harness.client };
    var address = try buildAddress();
    defer address.deinit(std.testing.allocator);
    var forwarding = try buildForwarding(&.{"80"});
    defer forwarding.deinit(std.testing.allocator);
    var changed = try buildForwarding(&.{"8080"});
    defer changed.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var address_read = try handler.read(&context, address.node, null);
    defer address_read.deinit();
    try std.testing.expectEqualStrings("10.42.0.9", outputValue(address_read.present, "address").string);
    var forwarding_read = try handler.read(&context, forwarding.node, null);
    defer forwarding_read.deinit();
    var diff = try ziac.gcp.network_delivery_provider.Handler.diff(&context, changed.node, &forwarding_read.present);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.replace, diff.kind);
}

test "shared live provider dispatches network delivery resources" {
    const responses = [_]zstd.Http.Response{ok("{\"name\":\"insert-firewall\"}")};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var live = ziac.gcp.live_provider.LiveProvider.init(&harness.client);
    const provider = live.provider();
    var firewall = try buildFirewall(false);
    defer firewall.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try provider.createWithContext(&context, firewall.node);
    defer pending.deinit();
    try std.testing.expect(!pending.completed);
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[0].url, "/compute/v1/projects/ziac-dev/global/firewalls"));
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
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{ .compute = "https://compute.example.test" });
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

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
}

fn known(text: []const u8) ziac.PublicOutput([]const u8) {
    return ziac.PublicOutput([]const u8).known(text);
}

fn buildFirewall(disabled: bool) !delivery.Firewall {
    return delivery.Firewall.build(std.testing.allocator, config(), .{
        .name = "allow-health",
        .network = known("projects/ziac-dev/global/networks/api"),
        .direction = .ingress,
        .action = .{ .allow = &.{.{ .protocol = "tcp", .ports = &.{"8080"} }} },
        .source_ranges = &.{"35.191.0.0/16"},
        .target_tags = &.{"api"},
        .disabled = disabled,
        .logging = true,
    });
}

fn buildRoute(priority: u16) !delivery.Route {
    return delivery.Route.build(std.testing.allocator, config(), .{
        .name = "private-egress",
        .network = known("projects/ziac-dev/global/networks/api"),
        .destination_range = "10.80.0.0/16",
        .next_hop = .{ .gateway = known("projects/ziac-dev/global/gateways/default-internet-gateway") },
        .priority = priority,
    });
}

fn buildBackend(timeout: u32) !delivery.RegionBackendService {
    return delivery.RegionBackendService.build(std.testing.allocator, config(), .{
        .name = "api-l4",
        .region = "europe-west1",
        .mode = .internal_passthrough,
        .protocol = .tcp,
        .network = known("projects/ziac-dev/global/networks/api"),
        .health_check = known("projects/ziac-dev/regions/europe-west1/healthChecks/api"),
        .backends = &.{.{ .group = known("projects/ziac-dev/regions/europe-west1/instanceGroups/api") }},
        .timeout_seconds = timeout,
    });
}

fn buildAddress() !delivery.InternalAddress {
    return delivery.InternalAddress.build(std.testing.allocator, config(), .{
        .name = "api-vip",
        .region = "europe-west1",
        .subnetwork = known("projects/ziac-dev/regions/europe-west1/subnetworks/api"),
        .purpose = .shared_load_balancer_vip,
    });
}

fn buildForwarding(ports: []const []const u8) !delivery.ForwardingRule {
    return delivery.ForwardingRule.build(std.testing.allocator, config(), .{
        .name = "api-l4",
        .region = "europe-west1",
        .scheme = .internal,
        .network = known("projects/ziac-dev/global/networks/api"),
        .subnetwork = known("projects/ziac-dev/regions/europe-west1/subnetworks/api"),
        .address = known("10.42.0.9"),
        .target = .{ .backend_service = known("projects/ziac-dev/regions/europe-west1/backendServices/api-l4") },
        .protocol = .tcp,
        .ports = ports,
    });
}

fn firewallJson(fingerprint: []const u8, disabled: bool) []const u8 {
    if (std.mem.eql(u8, fingerprint, "fingerprint-a") and !disabled) return "{\"name\":\"allow-health\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/global/firewalls/allow-health\",\"fingerprint\":\"fingerprint-a\",\"network\":\"projects/ziac-dev/global/networks/api\",\"direction\":\"INGRESS\",\"priority\":1000,\"disabled\":false,\"sourceRanges\":[\"35.191.0.0/16\"],\"targetTags\":[\"api\"],\"allowed\":[{\"IPProtocol\":\"tcp\",\"ports\":[\"8080\"]}],\"logConfig\":{\"enable\":true}}";
    unreachable;
}

fn routeJson() []const u8 {
    return "{\"name\":\"private-egress\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/global/routes/private-egress\",\"status\":\"ACTIVE\",\"network\":\"projects/ziac-dev/global/networks/api\",\"destRange\":\"10.80.0.0/16\",\"nextHopGateway\":\"projects/ziac-dev/global/gateways/default-internet-gateway\",\"priority\":900,\"tags\":[]}";
}

fn backendJson(fingerprint: []const u8, timeout: u32) []const u8 {
    if (std.mem.eql(u8, fingerprint, "fingerprint-a") and timeout == 30) return "{\"name\":\"api-l4\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/regions/europe-west1/backendServices/api-l4\",\"fingerprint\":\"fingerprint-a\",\"loadBalancingScheme\":\"INTERNAL\",\"protocol\":\"TCP\",\"network\":\"projects/ziac-dev/global/networks/api\",\"healthChecks\":[\"projects/ziac-dev/regions/europe-west1/healthChecks/api\"],\"timeoutSec\":30,\"backends\":[{\"group\":\"projects/ziac-dev/regions/europe-west1/instanceGroups/api\",\"balancingMode\":\"CONNECTION\",\"capacityScaler\":1.0,\"failover\":false}]}";
    if (std.mem.eql(u8, fingerprint, "fingerprint-b") and timeout == 30) return "{\"name\":\"api-l4\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/regions/europe-west1/backendServices/api-l4\",\"fingerprint\":\"fingerprint-b\",\"loadBalancingScheme\":\"INTERNAL\",\"protocol\":\"TCP\",\"network\":\"projects/ziac-dev/global/networks/api\",\"healthChecks\":[\"projects/ziac-dev/regions/europe-west1/healthChecks/api\"],\"timeoutSec\":30,\"backends\":[{\"group\":\"projects/ziac-dev/regions/europe-west1/instanceGroups/api\",\"balancingMode\":\"CONNECTION\",\"capacityScaler\":1.0,\"failover\":false}]}";
    unreachable;
}

fn addressJson() []const u8 {
    return "{\"name\":\"api-vip\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/regions/europe-west1/addresses/api-vip\",\"address\":\"10.42.0.9\",\"addressType\":\"INTERNAL\",\"purpose\":\"SHARED_LOADBALANCER_VIP\",\"subnetwork\":\"projects/ziac-dev/regions/europe-west1/subnetworks/api\",\"status\":\"RESERVED\"}";
}

fn forwardingJson(port: []const u8) []const u8 {
    if (std.mem.eql(u8, port, "80")) return "{\"name\":\"api-l4\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/regions/europe-west1/forwardingRules/api-l4\",\"IPAddress\":\"10.42.0.9\",\"IPProtocol\":\"TCP\",\"loadBalancingScheme\":\"INTERNAL\",\"network\":\"projects/ziac-dev/global/networks/api\",\"subnetwork\":\"projects/ziac-dev/regions/europe-west1/subnetworks/api\",\"backendService\":\"projects/ziac-dev/regions/europe-west1/backendServices/api-l4\",\"ports\":[\"80\"],\"allowGlobalAccess\":false}";
    unreachable;
}

fn outputValue(result: ziac.provider.ResourceResult, name: []const u8) ziac.value.Value {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name)) return item.value;
    unreachable;
}

fn ok(body: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = @constCast(body) };
}

fn precondition() zstd.Http.Response {
    return .{ .status = 412, .body = @constCast("{\"error\":{\"code\":412,\"message\":\"fingerprint mismatch\"}}") };
}
