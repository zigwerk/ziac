const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{ .project_id = "ziac-dev", .primary_region = "europe-west1" };

test "edge components synthesize exact Compute and Certificate Manager permissions" {
    var topology = try buildTopology(false, false);
    defer topology.deinit();
    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &topology.graph);
    defer requirements.deinit(std.testing.allocator);

    try std.testing.expect(contains(requirements.apis, "compute.googleapis.com"));
    try std.testing.expect(contains(requirements.apis, "certificatemanager.googleapis.com"));
    try std.testing.expect(requirements.hasPermission("compute.backendBuckets.create"));
    try std.testing.expect(requirements.hasPermission("compute.securityPolicies.create"));
    try std.testing.expect(requirements.hasPermission("compute.sslPolicies.create"));
    try std.testing.expect(requirements.hasPermission("compute.targetHttpsProxies.create"));
    try std.testing.expect(requirements.hasPermission("certificatemanager.dnsauthorizations.create"));
    try std.testing.expect(requirements.hasPermission("certificatemanager.certs.create"));
    try std.testing.expect(requirements.hasPermission("certificatemanager.certmaps.create"));
    try std.testing.expect(requirements.hasPermission("certificatemanager.certmapentries.create"));
    try std.testing.expect(requirements.hasPermission("certificatemanager.dnsauthorizations.use"));
    try std.testing.expect(requirements.hasPermission("certificatemanager.certs.use"));
    try std.testing.expect(requirements.hasPermission("certificatemanager.certmaps.use"));
}

test "edge canvas exposes CDN Armor TLS DNS and certificate-selection semantics" {
    var topology = try buildTopology(true, true);
    defer topology.deinit();
    var artifact = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &topology.graph, null, .{
        .stack = "secure-edge",
        .stage = "prod",
        .created_at_millis = 7,
    });
    defer artifact.deinit();

    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"edge_security\":{\"kind\":\"backend_bucket\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"cache_mode\":\"CACHE_ALL_STATIC\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"edge_security\":{\"kind\":\"security_policy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"rule_count\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"edge_security\":{\"kind\":\"certificate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"cache_origin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"security_enforcement\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"dns_authorization\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"certificate_selection\"") != null);
}

test "estate scan maps official edge assets and only classifies certificate-map proxies with proof" {
    var client = ziac.estate.ScriptedClient.init(std.testing.allocator);
    defer client.deinit();
    try client.addPage(
        \\{"results":[
        \\{"name":"//compute.googleapis.com/projects/acme-prod/global/backendBuckets/assets","assetType":"compute.googleapis.com/BackendBucket","project":"projects/123","location":"global"},
        \\{"name":"//compute.googleapis.com/projects/acme-prod/global/securityPolicies/assets-edge","assetType":"compute.googleapis.com/SecurityPolicy","project":"projects/123","location":"global"},
        \\{"name":"//compute.googleapis.com/projects/acme-prod/global/sslPolicies/modern","assetType":"compute.googleapis.com/SslPolicy","project":"projects/123","location":"global"},
        \\{"name":"//certificatemanager.googleapis.com/projects/acme-prod/locations/global/dnsAuthorizations/api","assetType":"certificatemanager.googleapis.com/DnsAuthorization","project":"projects/123","location":"global"},
        \\{"name":"//certificatemanager.googleapis.com/projects/acme-prod/locations/global/certificates/api","assetType":"certificatemanager.googleapis.com/Certificate","project":"projects/123","location":"global"},
        \\{"name":"//certificatemanager.googleapis.com/projects/acme-prod/locations/global/certificateMaps/public","assetType":"certificatemanager.googleapis.com/CertificateMap","project":"projects/123","location":"global"},
        \\{"name":"//certificatemanager.googleapis.com/projects/acme-prod/locations/global/certificateMaps/public/certificateMapEntries/api","assetType":"certificatemanager.googleapis.com/CertificateMapEntry","project":"projects/123","location":"global"},
        \\{"name":"//compute.googleapis.com/projects/acme-prod/global/targetHttpsProxies/api","assetType":"compute.googleapis.com/TargetHttpsProxy","project":"projects/123","location":"global","resource":{"data":{"certificateMap":"//certificatemanager.googleapis.com/projects/acme-prod/locations/global/certificateMaps/public"}}},
        \\{"name":"//compute.googleapis.com/projects/acme-prod/global/targetHttpsProxies/legacy","assetType":"compute.googleapis.com/TargetHttpsProxy","project":"projects/123","location":"global"}
        \\]}
    );
    var scan = try ziac.estate.scanAlloc(std.testing.allocator, client.client(), .{
        .identity = .{ .provider = .google, .verified = true, .subject = "subject" },
        .entitlement = .pro,
        .connection = .{ .status = .connected, .project_id = "acme-prod" },
        .observed_at_millis = 1_783_764_000_000,
    });
    defer scan.deinit();

    try std.testing.expectEqual(@as(usize, 9), scan.resource_count);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.compute.BackendBucket") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.certificatemanager.CertificateMapEntry") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.compute.CertificateMapTargetHttpsProxy") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.compute.TargetHttpsProxy") != null);
}

test "edge estimate keeps CDN Armor and certificate assumptions explicit" {
    const prices = [_]ziac.cost.SkuPrice{
        .{ .sku_id = "cache-egress", .region = "global", .unit = "GiB", .unit_quantity = 1, .unit_price_micros = 80 },
        .{ .sku_id = "cache-fill", .region = "global", .unit = "GiB", .unit_quantity = 1, .unit_price_micros = 20 },
        .{ .sku_id = "lookup", .region = "global", .unit = "10k requests", .unit_quantity = 10_000, .unit_price_micros = 75 },
        .{ .sku_id = "armor", .region = "global", .unit = "request", .unit_quantity = 1_000_000, .unit_price_micros = 600_000 },
        .{ .sku_id = "certificate", .region = "global", .unit = "certificate month", .unit_quantity = 1, .unit_price_micros = 1_000_000 },
    };
    const estimate = try ziac.cost.edgeSecurityConfigurationEstimate(&prices, .{
        .resource_id = "gcp.compute.BackendBucket.assets",
        .cache_egress_sku_id = "cache-egress",
        .cache_fill_sku_id = "cache-fill",
        .cache_lookup_sku_id = "lookup",
        .armor_request_sku_id = "armor",
        .certificate_sku_id = "certificate",
        .cache_egress_gib = 100,
        .cache_fill_gib = 25,
        .cache_lookup_requests = 1_000_000,
        .armor_requests = 1_000_000,
        .certificate_months = 2,
        .observed_at_millis = 7,
    });
    try std.testing.expectEqual(@as(?i64, 2_616_000), estimate.amount_micros);
    try std.testing.expectEqual(ziac.cost.Origin.configuration_estimate, estimate.origin);
    try std.testing.expect(!estimate.provenance.is_billing_export);
}

test "edge topology imports refreshes no-op and emits local qualification evidence" {
    var topology = try buildTopology(false, true);
    defer topology.deinit();
    var remote = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer remote.deinit();
    var providers = ziac.provider.ProviderRegistry{};
    providers.register(.gcp, remote.provider());
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    var create_plan = try ziac.plan.buildPlan(std.testing.allocator, &topology.graph, &state);
    defer create_plan.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &create_plan, &state, providers, .{});

    var imported_remote = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer imported_remote.deinit();
    var imported_providers = ziac.provider.ProviderRegistry{};
    imported_providers.register(.gcp, imported_remote.provider());
    var imported_state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer imported_state.deinit();
    for (topology.graph.resources.items) |node| {
        const record = state.get(node.id) orelse return error.MissingRecord;
        try ziac.importer.importResource(std.testing.allocator, node, record.physical_id orelse return error.MissingRecord, &imported_state, imported_providers, null);
    }
    var imported_plan = try ziac.plan.buildPlan(std.testing.allocator, &topology.graph, &imported_state);
    defer imported_plan.deinit();
    var refreshed = try ziac.plan.buildRefreshedPlan(std.testing.allocator, &topology.graph, &imported_state, imported_providers);
    defer refreshed.deinit();
    for (refreshed.operations) |item| try std.testing.expectEqual(ziac.plan.OperationKind.noop, item.kind);
    var destroy = try ziac.plan.buildDestroyPlan(std.testing.allocator, &state);
    defer destroy.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &destroy, &state, providers, .{ .destructive_confirmation = true });
    var receipt = try ziac.gcp.edge_security_qualification.serializeLocalAlloc(std.testing.allocator, &topology.graph, .{
        .created = remote.creates,
        .imported = imported_remote.imports,
        .no_op = imported_plan.operations.len,
        .retained = topology.graph.resources.items.len,
        .deleted = remote.deletes,
    });
    defer receipt.deinit();
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"schema\":\"ziac.gcp.edge-security-qualification.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"status\":\"passed\"") != null);
}

const Topology = struct {
    graph: ziac.ResourceGraph,
    fn deinit(self: *Topology) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

fn buildTopology(protect: bool, retain: bool) !Topology {
    var base = ziac.ResourceGraph.init(std.testing.allocator);
    defer base.deinit();
    var bucket = try ziac.gcp.storage.Bucket.build(std.testing.allocator, provider, .{
        .name = "ziac-edge-assets",
        .location = "US",
        .retain_on_delete = retain,
    });
    defer bucket.deinit(std.testing.allocator);
    try base.addResource(bucket.node);
    const bucket_id = base.resources.items[0].id;
    var cdn = try ziac.gcp.ProtectedCdnBucket.build(std.testing.allocator, provider, .{
        .base_graph = &base,
        .name = "assets",
        .bucket = ziac.gcp.storage.Bucket.Outputs.Name.fromResource(bucket_id),
        .rules = &.{
            .{ .priority = 1000, .match = .{ .src_ip_ranges = &.{"203.0.113.0/24"} }, .action = .{ .deny = .forbidden } },
            .{ .priority = 2_147_483_647, .match = .{ .src_ip_ranges = &.{"*"} }, .action = .{ .allow = {} } },
        },
        .protect = protect,
        .retain_on_delete = retain,
    });
    defer cdn.deinit();
    var certificates = try ziac.gcp.ManagedCertificateMap.build(std.testing.allocator, provider, .{
        .base_graph = &cdn.graph,
        .name = "public",
        .domains = &.{ "api.example.com", "www.example.com" },
        .protect = protect,
        .retain_on_delete = retain,
    });
    defer certificates.deinit();
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    errdefer graph.deinit();
    try graph.appendGraph(&certificates.graph);
    var ssl = try ziac.gcp.edge_security.SslPolicy.build(std.testing.allocator, provider, .{
        .name = "modern",
        .protect = protect,
        .retain_on_delete = retain,
    });
    defer ssl.deinit(std.testing.allocator);
    try graph.addResource(ssl.node);
    const ssl_id = graph.resources.items[graph.resources.items.len - 1].id;
    var proxy = try ziac.gcp.edge_security.CertificateMapTargetHttpsProxy.build(std.testing.allocator, provider, .{
        .name = "api",
        .url_map = ziac.PublicOutput([]const u8).known("projects/ziac-dev/global/urlMaps/api"),
        .certificate_map = certificates.map,
        .ssl_policy = ziac.gcp.edge_security.SslPolicy.Outputs.SelfLink.fromResource(ssl_id),
        .protect = protect,
        .retain_on_delete = retain,
    });
    defer proxy.deinit(std.testing.allocator);
    try graph.addResource(proxy.node);
    try graph.validateAcyclic();
    return .{ .graph = graph };
}

fn contains(values: []const []const u8, expected: []const u8) bool {
    for (values) |present| if (std.mem.eql(u8, present, expected)) return true;
    return false;
}
