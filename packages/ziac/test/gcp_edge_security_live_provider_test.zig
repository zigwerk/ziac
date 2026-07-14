const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const edge = ziac.gcp.edge_security;
const gclient = ziac.gcp.client;

test "backend bucket retries stale fingerprints and preserves desired CDN policy" {
    const responses = [_]zstd.Http.Response{
        ok(backendBucketJson("fingerprint-a", 3600)),
        precondition(),
        ok(backendBucketJson("fingerprint-b", 3600)),
        ok("{\"name\":\"patch-cdn\"}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.edge_security_provider.Handler{
        .client = &harness.client,
        .conflict_retries = 1,
    };
    var desired = try buildBackendBucket(7200);
    defer desired.deinit(std.testing.allocator);
    var prior = try buildBackendBucket(3600);
    defer prior.deinit(std.testing.allocator);
    var observed = try ziac.provider.ResourceResult.init(
        std.testing.allocator,
        "projects/ziac-dev/global/backendBuckets/assets",
        prior.node.inputs,
        &.{},
        null,
    );
    defer observed.deinit();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.update(&context, desired.node, &observed);
    defer pending.deinit();

    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"fingerprint\":\"fingerprint-a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].body, "\"fingerprint\":\"fingerprint-b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].body, "\"defaultTtl\":7200") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].body, "\"cacheMode\":\"CACHE_ALL_STATIC\"") != null);
}

test "managed certificate create checkpoints and resumes generic Google operation" {
    const certificate_json = "{\"name\":\"projects/ziac-dev/locations/global/certificates/api\",\"managed\":{\"domains\":[\"api.example.com\"],\"dnsAuthorizations\":[\"projects/ziac-dev/locations/global/dnsAuthorizations/api\"],\"state\":\"ACTIVE\"},\"scope\":\"DEFAULT\"}";
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"projects/ziac-dev/locations/global/operations/create-certificate\",\"done\":false}"),
        ok("{\"name\":\"projects/ziac-dev/locations/global/operations/create-certificate\",\"done\":true,\"response\":" ++ certificate_json ++ "}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.edge_security_provider.Handler{
        .client = &harness.client,
        .operation_policy = .{ .poll_interval_millis = 0 },
    };
    var certificate = try buildCertificate();
    defer certificate.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.create(&context, certificate.node);
    defer pending.deinit();
    try std.testing.expect(!pending.completed);
    context.operation_handle = pending.operation_handle;
    var completed = try handler.read(&context, certificate.node, null);
    defer completed.deinit();

    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].url, "/v1/projects/ziac-dev/locations/global/certificates?certificateId=api") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "dnsAuthorizations") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].url, "/v1/projects/ziac-dev/locations/global/operations/create-certificate") != null);
    try std.testing.expectEqualStrings("ACTIVE", outputValue(completed.present, "state").string);
}

test "certificate map import requires canonical identity and map entries resolve outputs" {
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"projects/ziac-dev/locations/global/certificateMaps/public\"}"),
        ok("{\"name\":\"projects/ziac-dev/locations/global/certificateMaps/public/certificateMapEntries/api\",\"hostname\":\"api.example.com\",\"certificates\":[\"projects/ziac-dev/locations/global/certificates/api\"]}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.edge_security_provider.Handler{ .client = &harness.client };
    var map = try edge.CertificateMap.build(std.testing.allocator, config(), .{ .name = "public" });
    defer map.deinit(std.testing.allocator);
    var entry = try buildMapEntry();
    defer entry.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var imported = try handler.importResource(&context, map.node, "projects/ziac-dev/locations/global/certificateMaps/public");
    defer imported.deinit();
    try std.testing.expectError(error.InvalidConfiguration, handler.importResource(&context, map.node, "public"));
    var imported_entry = try handler.importResource(&context, entry.node, "projects/ziac-dev/locations/global/certificateMaps/public/certificateMapEntries/api");
    defer imported_entry.deinit();

    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].url, "/v1/projects/ziac-dev/locations/global/certificateMaps/public/certificateMapEntries/api") != null);
}

test "shared live provider dispatches certificate-map HTTPS proxy" {
    const responses = [_]zstd.Http.Response{ok("{\"name\":\"insert-proxy\"}")};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var live = ziac.gcp.live_provider.LiveProvider.init(&harness.client);
    const provider = live.provider();
    var proxy = try buildProxy();
    defer proxy.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try provider.createWithContext(&context, proxy.node);
    defer pending.deinit();

    try std.testing.expect(!pending.completed);
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[0].url, "/compute/v1/projects/ziac-dev/global/targetHttpsProxies"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "certificateManagerCertificates") == null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "certificateMap") != null);
}

test "reads expose Cloud Armor rule and SSL feature drift" {
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"edge-policy\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/global/securityPolicies/edge-policy\",\"fingerprint\":\"policy-fingerprint\",\"type\":\"CLOUD_ARMOR_EDGE\",\"rules\":[{\"priority\":100,\"description\":\"block scanner\",\"action\":\"deny(403)\",\"preview\":false,\"match\":{\"versionedExpr\":\"SRC_IPS_V1\",\"config\":{\"srcIpRanges\":[\"203.0.113.0/24\"]}}},{\"priority\":2147483647,\"description\":\"default\",\"action\":\"allow\",\"preview\":false,\"match\":{\"versionedExpr\":\"SRC_IPS_V1\",\"config\":{\"srcIpRanges\":[\"*\"]}}}]}"),
        ok("{\"name\":\"modern\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/global/sslPolicies/modern\",\"fingerprint\":\"ssl-fingerprint\",\"minTlsVersion\":\"TLS_1_2\",\"profile\":\"CUSTOM\",\"customFeatures\":[\"TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256\"]}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.edge_security_provider.Handler{ .client = &harness.client };
    var policy = try buildSecurityPolicy();
    defer policy.deinit(std.testing.allocator);
    var ssl = try buildSslPolicy();
    defer ssl.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    const policy_read = try handler.read(&context, policy.node, null);
    var policy_present = switch (policy_read) {
        .present => |present| present,
        .absent => return error.TestUnexpectedResult,
    };
    defer policy_present.deinit();
    var policy_diff = try ziac.gcp.edge_security_provider.Handler.diff(&context, policy.node, &policy_present);
    defer policy_diff.deinit();

    const ssl_read = try handler.read(&context, ssl.node, null);
    var ssl_present = switch (ssl_read) {
        .present => |present| present,
        .absent => return error.TestUnexpectedResult,
    };
    defer ssl_present.deinit();
    var ssl_diff = try ziac.gcp.edge_security_provider.Handler.diff(&context, ssl.node, &ssl_present);
    defer ssl_diff.deinit();

    try std.testing.expectEqual(ziac.provider.DiffKind.update, policy_diff.kind);
    try std.testing.expectEqual(ziac.provider.DiffKind.update, ssl_diff.kind);
}

test "reads expose certificate map and HTTPS proxy wiring drift" {
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"projects/ziac-dev/locations/global/certificates/api\",\"managed\":{\"domains\":[\"other.example.com\"],\"dnsAuthorizations\":[\"projects/ziac-dev/locations/global/dnsAuthorizations/api\"],\"state\":\"ACTIVE\"},\"scope\":\"DEFAULT\"}"),
        ok("{\"name\":\"projects/ziac-dev/locations/global/certificateMaps/public/certificateMapEntries/api\",\"hostname\":\"api.example.com\",\"certificates\":[\"projects/ziac-dev/locations/global/certificates/other\"]}"),
        ok("{\"name\":\"api-https\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/global/targetHttpsProxies/api-https\",\"urlMap\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/global/urlMaps/api\",\"certificateMap\":\"//certificatemanager.googleapis.com/projects/ziac-dev/locations/global/certificateMaps/other\",\"sslPolicy\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/global/sslPolicies/modern\",\"quicOverride\":\"ENABLE\"}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.edge_security_provider.Handler{ .client = &harness.client };
    var certificate = try buildCertificate();
    defer certificate.deinit(std.testing.allocator);
    var entry = try buildMapEntry();
    defer entry.deinit(std.testing.allocator);
    var proxy = try buildProxy();
    defer proxy.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var certificate_present = try readPresent(handler, &context, certificate.node);
    defer certificate_present.deinit();
    var certificate_diff = try ziac.gcp.edge_security_provider.Handler.diff(&context, certificate.node, &certificate_present);
    defer certificate_diff.deinit();
    var entry_present = try readPresent(handler, &context, entry.node);
    defer entry_present.deinit();
    var entry_diff = try ziac.gcp.edge_security_provider.Handler.diff(&context, entry.node, &entry_present);
    defer entry_diff.deinit();
    var proxy_present = try readPresent(handler, &context, proxy.node);
    defer proxy_present.deinit();
    var proxy_diff = try ziac.gcp.edge_security_provider.Handler.diff(&context, proxy.node, &proxy_present);
    defer proxy_diff.deinit();

    try std.testing.expectEqual(ziac.provider.DiffKind.replace, certificate_diff.kind);
    try std.testing.expectEqual(ziac.provider.DiffKind.replace, entry_diff.kind);
    try std.testing.expectEqual(ziac.provider.DiffKind.replace, proxy_diff.kind);
}

test "matching certificate dependencies preserve typed output wiring" {
    const responses = [_]zstd.Http.Response{ok("{\"name\":\"projects/ziac-dev/locations/global/certificates/api\",\"managed\":{\"domains\":[\"api.example.com\"],\"dnsAuthorizations\":[\"projects/ziac-dev/locations/global/dnsAuthorizations/api\"],\"state\":\"ACTIVE\"},\"scope\":\"DEFAULT\"}")};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.edge_security_provider.Handler{ .client = &harness.client };
    var authorization = try edge.DnsAuthorization.build(std.testing.allocator, config(), .{
        .name = "api",
        .domain = "api.example.com",
    });
    defer authorization.deinit(std.testing.allocator);
    var certificate = try edge.Certificate.build(std.testing.allocator, config(), .{
        .name = "api",
        .domains = &.{"api.example.com"},
        .dns_authorizations = &.{authorization.name},
    });
    defer certificate.deinit(std.testing.allocator);
    var store = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer store.deinit();
    const desired_hash = std.fmt.bytesToHex(authorization.node.inputs_hash, .lower);
    try store.put(.{
        .resource_id = authorization.node.id,
        .provider = .gcp,
        .type_name = authorization.node.type_name,
        .logical_id = authorization.node.logical_id,
        .physical_id = "projects/ziac-dev/locations/global/dnsAuthorizations/api",
        .desired_hash = desired_hash[0..],
        .outputs = &.{.{ .name = "name", .value = .{ .string = "projects/ziac-dev/locations/global/dnsAuthorizations/api" } }},
        .status = .created,
    });
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    context.state = &store;

    var present = try readPresent(handler, &context, certificate.node);
    defer present.deinit();
    var diff = try ziac.gcp.edge_security_provider.Handler.diff(&context, certificate.node, &present);
    defer diff.deinit();

    try std.testing.expectEqual(ziac.provider.DiffKind.noop, diff.kind);
    try std.testing.expect(inputValue(present.observed_inputs, "dns_authorizations").list[0] == .output_ref);
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
            .certificate_manager = "https://certificatemanager.example.test",
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

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
}

fn known(text: []const u8) ziac.PublicOutput([]const u8) {
    return ziac.PublicOutput([]const u8).known(text);
}

fn buildBackendBucket(default_ttl: u32) !edge.BackendBucket {
    return edge.BackendBucket.build(std.testing.allocator, config(), .{
        .name = "assets",
        .bucket = known("assets.ziac-dev.appspot.com"),
        .edge_security_policy = known("projects/ziac-dev/global/securityPolicies/assets-edge"),
        .default_ttl_seconds = default_ttl,
        .max_ttl_seconds = 86_400,
    });
}

fn buildCertificate() !edge.Certificate {
    return edge.Certificate.build(std.testing.allocator, config(), .{
        .name = "api",
        .domains = &.{"api.example.com"},
        .dns_authorizations = &.{known("projects/ziac-dev/locations/global/dnsAuthorizations/api")},
    });
}

fn buildSecurityPolicy() !edge.SecurityPolicy {
    return edge.SecurityPolicy.build(std.testing.allocator, config(), .{
        .name = "edge-policy",
        .policy_type = .edge,
        .rules = &.{
            .{ .priority = 100, .description = "block scanner", .match = .{ .src_ip_ranges = &.{"203.0.113.0/24"} }, .action = .allow },
            .{ .priority = 2_147_483_647, .description = "default", .match = .{ .src_ip_ranges = &.{"*"} }, .action = .allow },
        },
    });
}

fn buildSslPolicy() !edge.SslPolicy {
    return edge.SslPolicy.build(std.testing.allocator, config(), .{
        .name = "modern",
        .profile = .custom,
        .custom_features = &.{"TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256"},
    });
}

fn buildMapEntry() !edge.CertificateMapEntry {
    return edge.CertificateMapEntry.build(std.testing.allocator, config(), .{
        .name = "api",
        .map = known("projects/ziac-dev/locations/global/certificateMaps/public"),
        .matcher = .{ .hostname = "api.example.com" },
        .certificates = &.{known("projects/ziac-dev/locations/global/certificates/api")},
    });
}

fn buildProxy() !edge.CertificateMapTargetHttpsProxy {
    return edge.CertificateMapTargetHttpsProxy.build(std.testing.allocator, config(), .{
        .name = "api-https",
        .url_map = known("projects/ziac-dev/global/urlMaps/api"),
        .certificate_map = known("projects/ziac-dev/locations/global/certificateMaps/public"),
        .ssl_policy = known("projects/ziac-dev/global/sslPolicies/modern"),
    });
}

fn outputValue(result: ziac.provider.ResourceResult, name: []const u8) ziac.value.Value {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name)) return item.value;
    unreachable;
}

fn inputValue(inputs: ziac.value.Value, name: []const u8) ziac.value.Value {
    for (inputs.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    unreachable;
}

fn readPresent(handler: ziac.gcp.edge_security_provider.Handler, context: *ziac.provider.OperationContext, node: ziac.ResourceNode) !ziac.provider.ResourceResult {
    return switch (try handler.read(context, node, null)) {
        .present => |present| present,
        .absent => error.TestUnexpectedResult,
    };
}

fn backendBucketJson(fingerprint: []const u8, default_ttl: u32) []const u8 {
    return if (default_ttl == 3600)
        if (std.mem.eql(u8, fingerprint, "fingerprint-a"))
            "{\"name\":\"assets\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/global/backendBuckets/assets\",\"fingerprint\":\"fingerprint-a\",\"bucketName\":\"assets.ziac-dev.appspot.com\",\"enableCdn\":true,\"cdnPolicy\":{\"cacheMode\":\"CACHE_ALL_STATIC\",\"defaultTtl\":3600}}"
        else
            "{\"name\":\"assets\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/global/backendBuckets/assets\",\"fingerprint\":\"fingerprint-b\",\"bucketName\":\"assets.ziac-dev.appspot.com\",\"enableCdn\":true,\"cdnPolicy\":{\"cacheMode\":\"CACHE_ALL_STATIC\",\"defaultTtl\":3600}}"
    else
        unreachable;
}

fn ok(body: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = @constCast(body) };
}

fn precondition() zstd.Http.Response {
    return .{ .status = 412, .body = @constCast("{\"error\":{\"code\":412,\"status\":\"FAILED_PRECONDITION\",\"message\":\"fingerprint changed\"}}") };
}
