const std = @import("std");
const ziac = @import("ziac");

test "container platform synthesizes exact GKE Fleet Functions Batch and actAs permissions" {
    var topology = try buildTopology();
    defer topology.deinit();
    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &topology.graph);
    defer requirements.deinit(std.testing.allocator);

    try std.testing.expect(contains(requirements.apis, "container.googleapis.com"));
    try std.testing.expect(contains(requirements.apis, "gkehub.googleapis.com"));
    try std.testing.expect(contains(requirements.apis, "cloudfunctions.googleapis.com"));
    try std.testing.expect(contains(requirements.apis, "batch.googleapis.com"));
    try std.testing.expect(requirements.hasPermission("container.clusters.create"));
    try std.testing.expect(requirements.hasPermission("container.clusters.update"));
    try std.testing.expect(requirements.hasPermission("gkehub.fleet.create"));
    try std.testing.expect(requirements.hasPermission("gkehub.memberships.create"));
    try std.testing.expect(requirements.hasPermission("cloudfunctions.functions.create"));
    try std.testing.expect(requirements.hasPermission("batch.jobs.create"));
    try std.testing.expect(requirements.hasPermission("iam.serviceAccounts.actAs"));
}

test "container platform canvas exposes workload groups and semantic dependency edges" {
    var topology = try buildTopology();
    defer topology.deinit();
    var artifact = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &topology.graph, null, .{
        .stack = "container-platform",
        .stage = "prod",
        .created_at_millis = 7,
    });
    defer artifact.deinit();

    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"container_platform\":{\"kind\":\"cluster\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"container_platform\":{\"kind\":\"node_pool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"container_platform\":{\"kind\":\"fleet\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"container_platform\":{\"kind\":\"function\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"container_platform\":{\"kind\":\"batch_job\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"node_pool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"fleet_membership\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"runtime_identity\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"workload_identity\"") != null);
}

test "estate scan maps only official container Fleet membership and CloudFunction assets" {
    var client = ziac.estate.ScriptedClient.init(std.testing.allocator);
    defer client.deinit();
    try client.addPage(
        \\{"results":[
        \\{"name":"//container.googleapis.com/projects/acme-prod/locations/europe-west1/clusters/platform","assetType":"container.googleapis.com/Cluster","project":"projects/123","location":"europe-west1"},
        \\{"name":"//container.googleapis.com/projects/acme-prod/locations/europe-west1/clusters/platform/nodePools/general","assetType":"container.googleapis.com/NodePool","project":"projects/123","location":"europe-west1"},
        \\{"name":"//gkehub.googleapis.com/projects/acme-prod/locations/global/fleets/default","assetType":"gkehub.googleapis.com/Fleet","project":"projects/123","location":"global"},
        \\{"name":"//gkehub.googleapis.com/projects/acme-prod/locations/global/memberships/platform","assetType":"gkehub.googleapis.com/Membership","project":"projects/123","location":"global"},
        \\{"name":"//cloudfunctions.googleapis.com/projects/acme-prod/locations/europe-west1/functions/image-api","assetType":"cloudfunctions.googleapis.com/CloudFunction","project":"projects/123","location":"europe-west1"}
        \\]}
    );
    var scan = try ziac.estate.scanAlloc(std.testing.allocator, client.client(), .{
        .identity = .{ .provider = .google, .verified = true, .subject = "subject" },
        .entitlement = .pro,
        .connection = .{ .status = .connected, .project_id = "acme-prod" },
        .observed_at_millis = 1_783_764_000_000,
    });
    defer scan.deinit();

    try std.testing.expectEqual(@as(usize, 5), scan.resource_count);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.container.Cluster") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.container.NodePool") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.gkehub.Fleet") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.gkehub.Membership") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.functions.FunctionV2") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.batch.Job") == null);
}

test "container platform estimate separates GKE Functions and Batch resource usage" {
    const prices = [_]ziac.cost.SkuPrice{
        .{ .sku_id = "gke-management", .region = "global", .unit = "cluster hour", .unit_quantity = 1, .unit_price_micros = 100_000 },
        .{ .sku_id = "node-cpu", .region = "europe-west1", .unit = "vCPU hour", .unit_quantity = 1, .unit_price_micros = 10_000 },
        .{ .sku_id = "node-memory", .region = "europe-west1", .unit = "GiB hour", .unit_quantity = 1, .unit_price_micros = 1_000 },
        .{ .sku_id = "function-invocations", .region = "europe-west1", .unit = "invocation", .unit_quantity = 1, .unit_price_micros = 1 },
        .{ .sku_id = "function-cpu", .region = "europe-west1", .unit = "vCPU second", .unit_quantity = 1, .unit_price_micros = 2 },
        .{ .sku_id = "function-memory", .region = "europe-west1", .unit = "GiB second", .unit_quantity = 1, .unit_price_micros = 1 },
        .{ .sku_id = "batch-cpu", .region = "europe-west1", .unit = "vCPU hour", .unit_quantity = 1, .unit_price_micros = 10_000 },
        .{ .sku_id = "batch-memory", .region = "europe-west1", .unit = "GiB hour", .unit_quantity = 1, .unit_price_micros = 1_000 },
    };
    const estimate = try ziac.cost.containerPlatformConfigurationEstimate(&prices, .{
        .resource_id = "ziac.container-platform.prod",
        .region = "europe-west1",
        .gke_management_sku_id = "gke-management",
        .node_cpu_sku_id = "node-cpu",
        .node_memory_sku_id = "node-memory",
        .function_invocation_sku_id = "function-invocations",
        .function_cpu_sku_id = "function-cpu",
        .function_memory_sku_id = "function-memory",
        .batch_cpu_sku_id = "batch-cpu",
        .batch_memory_sku_id = "batch-memory",
        .gke_management_hours = 730,
        .node_vcpu_hours = 1_460,
        .node_memory_gib_hours = 5_840,
        .function_invocations = 1_000_000,
        .function_vcpu_seconds = 100_000,
        .function_memory_gib_seconds = 200_000,
        .batch_vcpu_hours = 100,
        .batch_memory_gib_hours = 400,
        .observed_at_millis = 7,
    });
    try std.testing.expectEqual(@as(?i64, 96_240_000), estimate.amount_micros);
    try std.testing.expectEqual(ziac.cost.Origin.configuration_estimate, estimate.origin);
    try std.testing.expect(!estimate.provenance.is_billing_export);
}

test "container platform local qualification records import refresh no-op and cleanup evidence" {
    var topology = try buildTopology();
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
    var refreshed = try ziac.plan.buildRefreshedPlan(std.testing.allocator, &topology.graph, &imported_state, imported_providers);
    defer refreshed.deinit();
    for (refreshed.operations) |item| try std.testing.expectEqual(ziac.plan.OperationKind.noop, item.kind);
    var destroy = try ziac.plan.buildDestroyPlan(std.testing.allocator, &state);
    defer destroy.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &destroy, &state, providers, .{ .destructive_confirmation = true });

    var receipt = try ziac.gcp.container_platform_qualification.serializeLocalAlloc(std.testing.allocator, &topology.graph, .{
        .created = remote.creates,
        .imported = imported_remote.imports,
        .no_op = refreshed.operations.len,
        .deleted = remote.deletes,
    });
    defer receipt.deinit();
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"schema\":\"ziac.gcp.container-platform-qualification.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"authenticated\":false") != null);
}

const Topology = struct {
    graph: ziac.ResourceGraph,
    fn deinit(self: *Topology) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

fn buildTopology() !Topology {
    const provider = ziac.gcp.ProviderConfig{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
    var gke = try ziac.gcp.GkePlatform.build(std.testing.allocator, provider, .{
        .cluster = .{
            .name = "platform",
            .location = "europe-west1",
            .mode = .standard,
            .network = known("projects/ziac-dev/global/networks/platform"),
            .subnetwork = known("projects/ziac-dev/regions/europe-west1/subnetworks/gke"),
            .deletion_protection = false,
        },
        .node_pools = &.{.{ .name = "general", .machine_type = "e2-standard-4" }},
        .fleet = .{},
        .workload_identities = &.{.{ .namespace = "api", .kubernetes_service_account = "backend" }},
        .protect_identity = false,
    });
    defer gke.deinit();
    var function = try ziac.gcp.ZigFunction.build(std.testing.allocator, provider, .{
        .base_graph = &gke.graph,
        .name = "image-api",
        .location = "europe-west1",
        .runtime = "custom",
        .entry_point = "main",
        .source = .{ .bucket = "ziac-source", .object = "image-api.zip" },
        .invokers = &.{"group:platform@example.com"},
        .protect_identity = false,
    });
    defer function.deinit();
    var batch = try ziac.gcp.ZigBatchJob.build(std.testing.allocator, provider, .{
        .base_graph = &function.graph,
        .name = "daily-rollup",
        .location = "europe-west1",
        .image = "example/rollup@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .protect_identity = false,
    });
    defer batch.deinit();
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    errdefer graph.deinit();
    try graph.appendGraph(&batch.graph);
    return .{ .graph = graph };
}

fn known(text: []const u8) ziac.PublicOutput([]const u8) {
    return .known(text);
}

fn contains(values: []const []const u8, expected: []const u8) bool {
    for (values) |present| if (std.mem.eql(u8, present, expected)) return true;
    return false;
}
