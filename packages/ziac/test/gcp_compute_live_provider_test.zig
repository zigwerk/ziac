const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;

const regions = [_][]const u8{ "europe-west1", "us-central1" };
const config = ziac.gcp.config.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
    .service_regions = &regions,
    .network_tier = .premium,
};

test "live Compute provider manages all global load balancer primitives" {
    var network = try ziac.gcp.network.Network.build(std.testing.allocator, config, .{ .name = "api-egress" });
    defer network.deinit(std.testing.allocator);
    try exerciseLifecycle(
        network.node,
        "{\"name\":\"api-egress\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/global/networks/api-egress\",\"autoCreateSubnetworks\":false,\"routingConfig\":{\"routingMode\":\"GLOBAL\"}}",
        "/global/networks",
        false,
    );

    const network_link = ziac.PublicOutput([]const u8).known("https://compute.googleapis.com/compute/v1/projects/ziac-dev/global/networks/api-egress");
    var subnet = try ziac.gcp.network.Subnetwork.build(std.testing.allocator, config, .{
        .name = "api-europe-west1",
        .region = "europe-west1",
        .ip_cidr_range = "10.42.0.0/24",
        .network = network_link,
    });
    defer subnet.deinit(std.testing.allocator);
    try exerciseLifecycle(
        subnet.node,
        "{\"name\":\"api-europe-west1\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/regions/europe-west1/subnetworks/api-europe-west1\",\"network\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/global/networks/api-egress\",\"ipCidrRange\":\"10.42.0.0/24\",\"privateIpGoogleAccess\":true}",
        "/regions/europe-west1/subnetworks",
        true,
    );

    var router = try ziac.gcp.network.Router.build(std.testing.allocator, config, .{
        .name = "api-europe-west1",
        .region = "europe-west1",
        .network = network_link,
    });
    defer router.deinit(std.testing.allocator);
    try exerciseLifecycle(
        router.node,
        "{\"name\":\"api-europe-west1\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/regions/europe-west1/routers/api-europe-west1\",\"network\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/global/networks/api-egress\"}",
        "/regions/europe-west1/routers",
        true,
    );

    var regional_address = try ziac.gcp.network.RegionalAddress.build(std.testing.allocator, config, .{
        .name = "api-europe-west1",
        .region = "europe-west1",
    });
    defer regional_address.deinit(std.testing.allocator);
    try exerciseLifecycle(
        regional_address.node,
        "{\"name\":\"api-europe-west1\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/regions/europe-west1/addresses/api-europe-west1\",\"address\":\"203.0.113.10\",\"addressType\":\"EXTERNAL\",\"networkTier\":\"PREMIUM\"}",
        "/regions/europe-west1/addresses",
        true,
    );

    var address = try ziac.gcp.compute.GlobalAddress.build(std.testing.allocator, config, .{ .name = "api-ip" });
    defer address.deinit(std.testing.allocator);
    try exerciseLifecycle(
        address.node,
        "{\"name\":\"api-ip\",\"address\":\"203.0.113.10\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/global/addresses/api-ip\",\"networkTier\":\"PREMIUM\"}",
        "/global/addresses",
        false,
    );

    var neg = try ziac.gcp.compute.RegionServerlessNeg.build(std.testing.allocator, config, .{
        .name = "api-europe-west1",
        .region = "europe-west1",
        .cloud_run_service = "api",
    });
    defer neg.deinit(std.testing.allocator);
    try exerciseLifecycle(
        neg.node,
        "{\"name\":\"api-europe-west1\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/regions/europe-west1/networkEndpointGroups/api-europe-west1\",\"networkEndpointType\":\"SERVERLESS\",\"cloudRun\":{\"service\":\"api\"}}",
        "/regions/europe-west1/networkEndpointGroups",
        true,
    );

    const backends = [_]ziac.gcp.compute.ServerlessBackend{
        .{ .region = "europe-west1", .group = "projects/ziac-dev/regions/europe-west1/networkEndpointGroups/api-europe-west1" },
        .{ .region = "us-central1", .group = "projects/ziac-dev/regions/us-central1/networkEndpointGroups/api-us-central1" },
    };
    var backend = try ziac.gcp.compute.BackendService.build(std.testing.allocator, config, .{ .name = "api-backend", .backends = &backends });
    defer backend.deinit(std.testing.allocator);
    try exerciseLifecycle(
        backend.node,
        backendJson("fingerprint-a", "api-europe-west1", "api-us-central1"),
        "/global/backendServices",
        false,
    );

    var url_map = try ziac.gcp.compute.UrlMap.build(std.testing.allocator, config, .{
        .name = "api-map",
        .default_service = "projects/ziac-dev/global/backendServices/api-backend",
    });
    defer url_map.deinit(std.testing.allocator);
    try exerciseLifecycle(
        url_map.node,
        "{\"name\":\"api-map\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/global/urlMaps/api-map\",\"defaultService\":\"projects/ziac-dev/global/backendServices/api-backend\",\"fingerprint\":\"map-fingerprint\"}",
        "/global/urlMaps",
        false,
    );

    var redirect_url_map = try ziac.gcp.compute.HttpRedirectUrlMap.build(std.testing.allocator, config, .{
        .name = "api-http-redirect",
        .strip_query = true,
    });
    defer redirect_url_map.deinit(std.testing.allocator);
    try exerciseLifecycle(
        redirect_url_map.node,
        "{\"name\":\"api-http-redirect\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/global/urlMaps/api-http-redirect\",\"defaultUrlRedirect\":{\"httpsRedirect\":true,\"stripQuery\":true,\"redirectResponseCode\":\"MOVED_PERMANENTLY_DEFAULT\"},\"fingerprint\":\"redirect-map-fingerprint\"}",
        "/global/urlMaps",
        false,
    );

    var http_proxy = try ziac.gcp.compute.TargetHttpProxy.build(std.testing.allocator, config, .{
        .name = "api-http",
        .url_map = "projects/ziac-dev/global/urlMaps/api-http-redirect",
    });
    defer http_proxy.deinit(std.testing.allocator);
    try exerciseLifecycle(
        http_proxy.node,
        "{\"name\":\"api-http\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/global/targetHttpProxies/api-http\",\"urlMap\":\"projects/ziac-dev/global/urlMaps/api-http-redirect\",\"fingerprint\":\"http-proxy-fingerprint\"}",
        "/global/targetHttpProxies",
        false,
    );

    var proxy = try ziac.gcp.compute.TargetHttpsProxy.build(std.testing.allocator, config, .{
        .name = "api-https",
        .url_map = "projects/ziac-dev/global/urlMaps/api-map",
        .ssl_certificates = &.{"projects/ziac-dev/global/sslCertificates/api-cert"},
    });
    defer proxy.deinit(std.testing.allocator);
    try exerciseLifecycle(
        proxy.node,
        "{\"name\":\"api-https\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/global/targetHttpsProxies/api-https\",\"urlMap\":\"projects/ziac-dev/global/urlMaps/api-map\",\"sslCertificates\":[\"projects/ziac-dev/global/sslCertificates/api-cert\"],\"fingerprint\":\"proxy-fingerprint\"}",
        "/global/targetHttpsProxies",
        false,
    );

    var forwarding = try ziac.gcp.compute.GlobalForwardingRule.build(std.testing.allocator, config, .{
        .name = "api-https",
        .address = "203.0.113.10",
        .target = "projects/ziac-dev/global/targetHttpsProxies/api-https",
    });
    defer forwarding.deinit(std.testing.allocator);
    try exerciseLifecycle(
        forwarding.node,
        "{\"name\":\"api-https\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/global/forwardingRules/api-https\",\"IPAddress\":\"203.0.113.10\",\"IPProtocol\":\"TCP\",\"portRange\":\"443-443\",\"target\":\"projects/ziac-dev/global/targetHttpsProxies/api-https\",\"loadBalancingScheme\":\"EXTERNAL_MANAGED\",\"networkTier\":\"PREMIUM\"}",
        "/global/forwardingRules",
        false,
    );
}

test "live Compute backend update preserves fields and retries fingerprint conflicts" {
    const old_backends = [_]ziac.gcp.compute.ServerlessBackend{
        .{ .region = "europe-west1", .group = "projects/ziac-dev/regions/europe-west1/networkEndpointGroups/api-europe-west1" },
        .{ .region = "us-central1", .group = "projects/ziac-dev/regions/us-central1/networkEndpointGroups/api-us-central1" },
    };
    const new_backends = [_]ziac.gcp.compute.ServerlessBackend{
        .{ .region = "europe-west1", .group = "projects/ziac-dev/regions/europe-west1/networkEndpointGroups/api-europe-west1-v2" },
        .{ .region = "us-central1", .group = "projects/ziac-dev/regions/us-central1/networkEndpointGroups/api-us-central1" },
    };
    var old = try ziac.gcp.compute.BackendService.build(std.testing.allocator, config, .{ .name = "api-backend", .backends = &old_backends });
    defer old.deinit(std.testing.allocator);
    var changed = try ziac.gcp.compute.BackendService.build(std.testing.allocator, config, .{ .name = "api-backend", .backends = &new_backends });
    defer changed.deinit(std.testing.allocator);
    const responses = [_]zstd.Http.Response{
        .{ .status = 200, .body = backendJson("fingerprint-a", "api-europe-west1", "api-us-central1") },
        .{ .status = 200, .body = backendJson("fingerprint-a", "api-europe-west1", "api-us-central1") },
        .{ .status = 412, .body = "{\"error\":{\"code\":412,\"message\":\"fingerprint mismatch\"}}" },
        .{ .status = 200, .body = backendJson("fingerprint-b", "api-europe-west1", "api-us-central1") },
        operation("update-backend"),
        done("update-backend"),
        .{ .status = 200, .body = backendJson("fingerprint-c", "api-europe-west1-v2", "api-us-central1") },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    harness.live.compute_conflict_retries = 1;
    const provider = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var present = try provider.readWithContext(&context, old.node);
    defer present.deinit();
    var diff = try provider.diffWithContext(&context, changed.node, &present.present);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, diff.kind);
    var updating = try provider.updateWithContext(&context, changed.node, &present.present);
    defer updating.deinit();
    try std.testing.expect(!updating.completed);
    context.physical_id = updating.physical_id;
    context.operation_handle = updating.operation_handle;
    var updated = try provider.readWithContext(&context, changed.node);
    defer updated.deinit();
    try std.testing.expectEqual(changed.node.inputs_hash, updated.present.observed_hash);

    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[2].body, "\"customField\":\"preserve-me\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[2].body, "\"fingerprint\":\"fingerprint-a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[4].body, "\"fingerprint\":\"fingerprint-b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[4].body, "api-europe-west1-v2") != null);
}

test "live Compute forwarding rules resolve and normalize allocated address outputs" {
    const address = ziac.Output([]const u8, .public).fromResource("gcp.compute.GlobalAddress.api-ip", "address");
    var forwarding = try ziac.gcp.compute.GlobalForwardingRule.build(std.testing.allocator, config, .{
        .name = "api-https",
        .address_output = address,
        .target = "projects/ziac-dev/global/targetHttpsProxies/api-https",
    });
    defer forwarding.deinit(std.testing.allocator);
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    try state.put(.{
        .resource_id = "gcp.compute.GlobalAddress.api-ip",
        .type_name = "gcp.compute.GlobalAddress",
        .logical_id = "api-ip",
        .desired_hash = "address-hash",
        .outputs = &.{.{ .name = "address", .value = .{ .string = "203.0.113.10" } }},
        .status = .created,
    });
    const forwarding_json = "{\"name\":\"api-https\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/global/forwardingRules/api-https\",\"IPAddress\":\"203.0.113.10\",\"IPProtocol\":\"TCP\",\"portRange\":\"443-443\",\"target\":\"projects/ziac-dev/global/targetHttpsProxies/api-https\",\"loadBalancingScheme\":\"EXTERNAL_MANAGED\",\"networkTier\":\"PREMIUM\"}";
    const responses = [_]zstd.Http.Response{
        operation("insert-forwarding"),
        .{ .status = 200, .body = forwarding_json },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const provider = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    context.state = &state;

    var creating = try provider.createWithContext(&context, forwarding.node);
    defer creating.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "\"IPAddress\":\"203.0.113.10\"") != null);
    var observed = try provider.readWithContext(&context, forwarding.node);
    defer observed.deinit();
    try std.testing.expectEqual(forwarding.node.inputs_hash, observed.present.observed_hash);
}

test "live Compute provider encodes serverless outlier detection" {
    const backends = [_]ziac.gcp.compute.ServerlessBackend{
        .{ .region = "europe-west1", .group = "projects/ziac-dev/regions/europe-west1/networkEndpointGroups/api-eu" },
        .{ .region = "us-central1", .group = "projects/ziac-dev/regions/us-central1/networkEndpointGroups/api-us" },
    };
    var backend = try ziac.gcp.compute.BackendService.build(std.testing.allocator, config, .{
        .name = "api-backend",
        .backends = &backends,
        .outlier_detection = .{},
    });
    defer backend.deinit(std.testing.allocator);
    const responses = [_]zstd.Http.Response{
        operation("insert-backend"),
        .{ .status = 200, .body = "{\"name\":\"api-backend\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/global/backendServices/api-backend\",\"protocol\":\"HTTP\",\"loadBalancingScheme\":\"EXTERNAL_MANAGED\",\"backends\":[{\"group\":\"projects/ziac-dev/regions/europe-west1/networkEndpointGroups/api-eu\"},{\"group\":\"projects/ziac-dev/regions/us-central1/networkEndpointGroups/api-us\"}],\"outlierDetection\":{\"consecutiveErrors\":5,\"consecutiveGatewayFailure\":3,\"interval\":{\"seconds\":\"1\",\"nanos\":0},\"baseEjectionTime\":{\"seconds\":\"180\",\"nanos\":0},\"maxEjectionPercent\":100,\"enforcingConsecutiveErrors\":100,\"enforcingConsecutiveGatewayFailure\":100}}" },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var creating = try harness.live.provider().createWithContext(&context, backend.node);
    defer creating.deinit();

    const body = harness.transport.requests.items[0].body;
    try std.testing.expect(std.mem.indexOf(u8, body, "\"consecutiveErrors\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"baseEjectionTime\":{\"seconds\":\"180\",\"nanos\":0}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"enforcingConsecutiveErrors\":100") != null);
    var observed = try harness.live.provider().readWithContext(&context, backend.node);
    defer observed.deinit();
    try std.testing.expectEqual(backend.node.inputs_hash, observed.present.observed_hash);
}

fn exerciseLifecycle(
    node: ziac.ResourceNode,
    resource_json: []const u8,
    collection_suffix: []const u8,
    regional: bool,
) !void {
    const responses = [_]zstd.Http.Response{
        notFound(),
        operation("insert-resource"),
        done("insert-resource"),
        .{ .status = 200, .body = resource_json },
        operation("delete-resource"),
        done("delete-resource"),
        notFound(),
        .{ .status = 200, .body = resource_json },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const provider = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var before = try provider.readWithContext(&context, node);
    defer before.deinit();
    try std.testing.expect(before == .absent);
    var creating = try provider.createWithContext(&context, node);
    defer creating.deinit();
    try std.testing.expect(!creating.completed);
    context.physical_id = creating.physical_id;
    context.operation_handle = creating.operation_handle;
    var present = try provider.readWithContext(&context, node);
    defer present.deinit();
    try std.testing.expect(present == .present);
    try std.testing.expect(present.present.outputs.len >= 1);
    var diff = try provider.diffWithContext(&context, node, &present.present);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.noop, diff.kind);
    context.operation_handle = null;
    try provider.deleteWithContext(&context, node, creating.physical_id);
    var gone = try provider.readWithContext(&context, node);
    defer gone.deinit();
    try std.testing.expect(gone == .absent);
    var imported = try provider.importWithContext(&context, node, creating.physical_id);
    defer imported.deinit();
    try std.testing.expectEqualStrings(creating.physical_id, imported.physical_id);

    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].url, collection_suffix) != null);
    const operation_url = harness.transport.requests.items[2].url;
    if (regional) {
        try std.testing.expect(std.mem.indexOf(u8, operation_url, "/regions/europe-west1/operations/insert-resource") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, operation_url, "/global/operations/insert-resource") != null);
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

fn notFound() zstd.Http.Response {
    return .{ .status = 404, .body = "{\"error\":{\"code\":404,\"status\":\"NOT_FOUND\",\"message\":\"missing\"}}" };
}

fn operation(comptime name: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = "{\"name\":\"" ++ name ++ "\"}" };
}

fn done(comptime name: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = "{\"name\":\"" ++ name ++ "\",\"status\":\"DONE\"}" };
}

fn backendJson(
    comptime fingerprint: []const u8,
    comptime europe_neg: []const u8,
    comptime us_neg: []const u8,
) []const u8 {
    return "{\"name\":\"api-backend\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/global/backendServices/api-backend\",\"protocol\":\"HTTP\",\"loadBalancingScheme\":\"EXTERNAL_MANAGED\",\"fingerprint\":\"" ++ fingerprint ++ "\",\"customField\":\"preserve-me\",\"backends\":[{\"group\":\"projects/ziac-dev/regions/europe-west1/networkEndpointGroups/" ++ europe_neg ++ "\",\"capacityScaler\":1},{\"group\":\"projects/ziac-dev/regions/us-central1/networkEndpointGroups/" ++ us_neg ++ "\",\"capacityScaler\":1}]}";
}
