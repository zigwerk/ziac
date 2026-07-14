const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{ .project_id = "ziac-dev", .primary_region = "europe-west1" };

test "network delivery synthesizes exact Compute API permissions" {
    var topology = try buildTopology(false, false);
    defer topology.deinit();
    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &topology.graph);
    defer requirements.deinit(std.testing.allocator);

    try std.testing.expect(contains(requirements.apis, "compute.googleapis.com"));
    try std.testing.expect(requirements.hasPermission("compute.firewalls.create"));
    try std.testing.expect(requirements.hasPermission("compute.routes.create"));
    try std.testing.expect(requirements.hasPermission("compute.regionHealthChecks.create"));
    try std.testing.expect(requirements.hasPermission("compute.addresses.createInternal"));
    try std.testing.expect(requirements.hasPermission("compute.addresses.deleteInternal"));
    try std.testing.expect(requirements.hasPermission("compute.regionBackendServices.create"));
    try std.testing.expect(requirements.hasPermission("compute.regionUrlMaps.create"));
    try std.testing.expect(requirements.hasPermission("compute.regionTargetHttpProxies.create"));
    try std.testing.expect(requirements.hasPermission("compute.forwardingRules.create"));
    try std.testing.expect(requirements.hasPermission("compute.networks.use"));
    try std.testing.expect(requirements.hasPermission("compute.subnetworks.use"));
    try std.testing.expect(requirements.hasPermission("compute.addresses.useInternal"));
    try std.testing.expect(!requirements.hasPermission("compute.healthChecks.create"));
    try std.testing.expect(!requirements.hasPermission("compute.backendServices.create"));
    try std.testing.expect(!requirements.hasPermission("compute.urlMaps.create"));
    try std.testing.expect(!requirements.hasPermission("compute.targetHttpProxies.create"));
}

test "network delivery canvas identifies private frontends policy and health paths" {
    var topology = try buildTopology(true, true);
    defer topology.deinit();
    var artifact = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &topology.graph, null, .{
        .stack = "private-delivery",
        .stage = "prod",
        .created_at_millis = 7,
    });
    defer artifact.deinit();

    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"network_delivery\":{\"kind\":\"firewall\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"network_delivery\":{\"kind\":\"region_health_check\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"load_balancing_scheme\":\"INTERNAL_MANAGED\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"request_path\":\"/ready\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"allow_global_access\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"private_traffic\"") != null);
}

test "estate scan maps proven network delivery asset identities" {
    var client = ziac.estate.ScriptedClient.init(std.testing.allocator);
    defer client.deinit();
    try client.addPage(
        \\{"results":[
        \\{"name":"//compute.googleapis.com/projects/acme-prod/global/firewalls/allow-health","assetType":"compute.googleapis.com/Firewall","project":"projects/123","location":"global"},
        \\{"name":"//compute.googleapis.com/projects/acme-prod/global/routes/private-egress","assetType":"compute.googleapis.com/Route","project":"projects/123","location":"global"},
        \\{"name":"//compute.googleapis.com/projects/acme-prod/global/healthChecks/public-health","assetType":"compute.googleapis.com/HealthCheck","project":"projects/123","location":"global"},
        \\{"name":"//compute.googleapis.com/projects/acme-prod/regions/europe-west1/healthChecks/api-health","assetType":"compute.googleapis.com/HealthCheck","project":"projects/123","location":"europe-west1"},
        \\{"name":"//compute.googleapis.com/projects/acme-prod/regions/europe-west1/addresses/api-vip","assetType":"compute.googleapis.com/Address","project":"projects/123","location":"europe-west1","resource":{"data":{"addressType":"INTERNAL","purpose":"SHARED_LOADBALANCER_VIP"}}},
        \\{"name":"//compute.googleapis.com/projects/acme-prod/regions/europe-west1/backendServices/api-backend","assetType":"compute.googleapis.com/BackendService","project":"projects/123","location":"europe-west1","resource":{"data":{"loadBalancingScheme":"INTERNAL_MANAGED"}}},
        \\{"name":"//compute.googleapis.com/projects/acme-prod/regions/europe-west1/urlMaps/api-map","assetType":"compute.googleapis.com/UrlMap","project":"projects/123","location":"europe-west1"},
        \\{"name":"//compute.googleapis.com/projects/acme-prod/regions/europe-west1/targetHttpProxies/api-http","assetType":"compute.googleapis.com/TargetHttpProxy","project":"projects/123","location":"europe-west1"},
        \\{"name":"//compute.googleapis.com/projects/acme-prod/regions/europe-west1/forwardingRules/api","assetType":"compute.googleapis.com/ForwardingRule","project":"projects/123","location":"europe-west1","resource":{"data":{"loadBalancingScheme":"INTERNAL_MANAGED"}}}
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
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.compute.Firewall") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.compute.RegionHealthCheck") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.compute.InternalAddress") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.compute.RegionBackendService") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.compute.ForwardingRule") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "\"physical_id\":\"projects/acme-prod/regions/europe-west1/forwardingRules/api\"") != null);
}

test "network delivery estimate keeps frontend data and probe assumptions explicit" {
    const prices = [_]ziac.cost.SkuPrice{
        .{ .sku_id = "rule", .region = "europe-west1", .unit = "rule hour", .unit_quantity = 1, .unit_price_micros = 25 },
        .{ .sku_id = "data", .region = "europe-west1", .unit = "GiB", .unit_quantity = 1, .unit_price_micros = 100 },
        .{ .sku_id = "probe", .region = "europe-west1", .unit = "probe", .unit_quantity = 1_000, .unit_price_micros = 5 },
    };
    const estimate = try ziac.cost.networkDeliveryConfigurationEstimate(&prices, .{
        .resource_id = "gcp.compute.ForwardingRule.europe-west1.api",
        .region = "europe-west1",
        .forwarding_rule_sku_id = "rule",
        .data_processed_sku_id = "data",
        .health_probe_sku_id = "probe",
        .forwarding_rule_hours = 730,
        .data_processed_gib = 250,
        .health_probes = 86_400,
        .observed_at_millis = 7,
    });
    try std.testing.expectEqual(@as(?i64, 43_682), estimate.amount_micros);
    try std.testing.expectEqual(ziac.cost.Origin.configuration_estimate, estimate.origin);
    try std.testing.expect(!estimate.provenance.is_billing_export);
}

test "network delivery applies imports refreshes no-op and emits qualification evidence" {
    var topology = try buildTopology(false, false);
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
    for (imported_plan.operations) |item| try std.testing.expectEqual(ziac.plan.OperationKind.noop, item.kind);
    var refreshed = try ziac.plan.buildRefreshedPlan(std.testing.allocator, &topology.graph, &imported_state, imported_providers);
    defer refreshed.deinit();
    for (refreshed.operations) |item| try std.testing.expectEqual(ziac.plan.OperationKind.noop, item.kind);

    var destroy = try ziac.plan.buildDestroyPlan(std.testing.allocator, &state);
    defer destroy.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &destroy, &state, providers, .{ .destructive_confirmation = true });
    var receipt = try ziac.gcp.network_delivery_qualification.serializeLocalAlloc(std.testing.allocator, &topology.graph, .{
        .created = remote.creates,
        .imported = imported_remote.imports,
        .no_op = imported_plan.operations.len,
        .retained = 0,
        .deleted = remote.deletes,
    });
    defer receipt.deinit();
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"schema\":\"ziac.gcp.network-delivery-qualification.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"status\":\"passed\"") != null);
}

fn buildTopology(protect: bool, retain: bool) !ziac.gcp.RegionalInternalApplicationLoadBalancer {
    var base = ziac.ResourceGraph.init(std.testing.allocator);
    defer base.deinit();
    var network = try ziac.gcp.network.Network.build(std.testing.allocator, provider, .{ .name = "platform" });
    defer network.deinit(std.testing.allocator);
    try base.addResource(network.node);
    const network_id = base.resources.items[0].id;
    var app_subnet = try ziac.gcp.network.Subnetwork.build(std.testing.allocator, provider, .{
        .name = "application",
        .region = "europe-west1",
        .ip_cidr_range = "10.42.0.0/24",
        .network = ziac.gcp.network.Network.Outputs.SelfLink.fromResource(network_id),
    });
    defer app_subnet.deinit(std.testing.allocator);
    try base.addResource(app_subnet.node);
    const app_subnet_id = base.resources.items[1].id;
    var proxy_subnet = try ziac.gcp.network.Subnetwork.build(std.testing.allocator, provider, .{
        .name = "proxy-only",
        .region = "europe-west1",
        .ip_cidr_range = "10.42.1.0/24",
        .network = ziac.gcp.network.Network.Outputs.SelfLink.fromResource(network_id),
    });
    defer proxy_subnet.deinit(std.testing.allocator);
    try base.addResource(proxy_subnet.node);
    const proxy_subnet_id = base.resources.items[2].id;
    var policy = try ziac.gcp.NetworkPolicy.build(std.testing.allocator, provider, .{
        .base_graph = &base,
        .network = ziac.gcp.network.Network.Outputs.SelfLink.fromResource(network_id),
        .firewalls = &.{.{
            .name = "allow-health",
            .direction = .ingress,
            .action = .{ .allow = &.{.{ .protocol = "tcp", .ports = &.{"8080"} }} },
            .source_ranges = &.{"35.191.0.0/16"},
        }},
        .routes = &.{.{
            .name = "private-egress",
            .destination_range = "10.80.0.0/16",
            .next_hop = .{ .ip_address = "10.0.0.1" },
        }},
        .protect = protect,
        .retain_on_delete = retain,
    });
    defer policy.deinit();
    var l4 = try ziac.gcp.InternalPassthroughLoadBalancer.build(std.testing.allocator, provider, .{
        .base_graph = &policy.graph,
        .name = "api-l4",
        .region = "europe-west1",
        .network = ziac.gcp.network.Network.Outputs.SelfLink.fromResource(network_id),
        .subnetwork = ziac.gcp.network.Subnetwork.Outputs.SelfLink.fromResource(app_subnet_id),
        .backend_group = ziac.PublicOutput([]const u8).known("projects/ziac-dev/regions/europe-west1/instanceGroups/api"),
        .health_port = 8080,
        .protocol = .tcp,
        .ports = &.{"443"},
        .allow_global_access = true,
        .protect = protect,
        .retain_address = retain,
    });
    defer l4.deinit();
    return ziac.gcp.RegionalInternalApplicationLoadBalancer.build(std.testing.allocator, provider, .{
        .base_graph = &l4.graph,
        .name = "api-l7",
        .region = "europe-west1",
        .network = ziac.gcp.network.Network.Outputs.SelfLink.fromResource(network_id),
        .subnetwork = ziac.gcp.network.Subnetwork.Outputs.SelfLink.fromResource(app_subnet_id),
        .proxy_only_subnet = ziac.gcp.network.Subnetwork.Outputs.SelfLink.fromResource(proxy_subnet_id),
        .backend_group = ziac.PublicOutput([]const u8).known("projects/ziac-dev/regions/europe-west1/instanceGroups/api"),
        .health_port = 8080,
        .backend_port_name = "http",
        .frontend_port = 80,
        .allow_global_access = true,
        .protect = protect,
        .retain_address = retain,
    });
}

fn contains(values: []const []const u8, expected: []const u8) bool {
    for (values) |present| if (std.mem.eql(u8, present, expected)) return true;
    return false;
}
