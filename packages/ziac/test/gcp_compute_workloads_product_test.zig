const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{ .project_id = "ziac-dev", .primary_region = "europe-west1" };

test "Compute fleets synthesize exact APIs and workload permissions" {
    var fleet = try buildFleet(false, false);
    defer fleet.deinit();
    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &fleet.graph);
    defer requirements.deinit(std.testing.allocator);

    try std.testing.expect(contains(requirements.apis, "compute.googleapis.com"));
    try std.testing.expect(requirements.hasPermission("compute.instanceTemplates.create"));
    try std.testing.expect(requirements.hasPermission("compute.instanceGroupManagers.create"));
    try std.testing.expect(requirements.hasPermission("compute.autoscalers.create"));
    try std.testing.expect(requirements.hasPermission("compute.images.useReadOnly"));
    try std.testing.expect(requirements.hasPermission("compute.networks.use"));
    try std.testing.expect(requirements.hasPermission("compute.subnetworks.use"));
    try std.testing.expect(requirements.hasPermission("iam.serviceAccounts.actAs"));
}

test "Compute workload canvas metadata is useful and secret safe" {
    var fleet = try buildFleet(true, true);
    defer fleet.deinit();
    var artifact = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &fleet.graph, null, .{ .stack = "compute-fleet", .stage = "prod", .created_at_millis = 7 });
    defer artifact.deinit();

    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"compute_workload\":{\"kind\":\"instance_template\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"compute_workload\":{\"kind\":\"regional_instance_group_manager\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"compute_workload\":{\"kind\":\"regional_autoscaler\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"machine_type\":\"e2-standard-2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"$secret\":\"redacted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "startup-source-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "echo private startup") == null);
}

test "estate scan maps official Compute workload asset identities and canonical import ids" {
    var client = ziac.estate.ScriptedClient.init(std.testing.allocator);
    defer client.deinit();
    try client.addPage(
        \\{"results":[
        \\{"name":"//compute.googleapis.com/projects/acme-prod/zones/europe-west1-b/disks/api-data","assetType":"compute.googleapis.com/Disk","project":"projects/123","location":"europe-west1-b","displayName":"api-data"},
        \\{"name":"//compute.googleapis.com/projects/acme-prod/regions/europe-west1/disks/api-regional","assetType":"compute.googleapis.com/Disk","project":"projects/123","location":"europe-west1","displayName":"api-regional"},
        \\{"name":"//compute.googleapis.com/projects/acme-prod/global/images/api-image","assetType":"compute.googleapis.com/Image","project":"projects/123","location":"global","displayName":"api-image"},
        \\{"name":"//compute.googleapis.com/projects/acme-prod/zones/europe-west1-b/instances/api","assetType":"compute.googleapis.com/Instance","project":"projects/123","location":"europe-west1-b","displayName":"api"},
        \\{"name":"//compute.googleapis.com/projects/acme-prod/global/instanceTemplates/api-template","assetType":"compute.googleapis.com/InstanceTemplate","project":"projects/123","location":"global","displayName":"api-template"},
        \\{"name":"//compute.googleapis.com/projects/acme-prod/zones/europe-west1-b/instanceGroupManagers/api","assetType":"compute.googleapis.com/InstanceGroupManager","project":"projects/123","location":"europe-west1-b","displayName":"api"},
        \\{"name":"//compute.googleapis.com/projects/acme-prod/regions/europe-west1/instanceGroupManagers/api-global","assetType":"compute.googleapis.com/InstanceGroupManager","project":"projects/123","location":"europe-west1","displayName":"api-global"},
        \\{"name":"//compute.googleapis.com/projects/acme-prod/zones/europe-west1-b/autoscalers/api","assetType":"compute.googleapis.com/Autoscaler","project":"projects/123","location":"europe-west1-b","displayName":"api"},
        \\{"name":"//compute.googleapis.com/projects/acme-prod/regions/europe-west1/autoscalers/api-global","assetType":"compute.googleapis.com/Autoscaler","project":"projects/123","location":"europe-west1","displayName":"api-global"}
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
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.compute.RegionDisk") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.compute.RegionInstanceGroupManager") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.compute.RegionAutoscaler") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "\"physical_id\":\"projects/acme-prod/regions/europe-west1/disks/api-regional\"") != null);
}

test "Compute estimates keep CPU memory accelerator disk and image assumptions explicit" {
    const prices = [_]ziac.cost.SkuPrice{
        .{ .sku_id = "cpu", .region = "europe-west1", .unit = "vcpu hour", .unit_quantity = 1, .unit_price_micros = 100 },
        .{ .sku_id = "memory", .region = "europe-west1", .unit = "GiB hour", .unit_quantity = 1, .unit_price_micros = 20 },
        .{ .sku_id = "gpu", .region = "europe-west1", .unit = "GPU hour", .unit_quantity = 1, .unit_price_micros = 500 },
        .{ .sku_id = "disk", .region = "europe-west1", .unit = "GiB month", .unit_quantity = 1, .unit_price_micros = 4 },
        .{ .sku_id = "image", .region = "europe-west1", .unit = "GiB month", .unit_quantity = 1, .unit_price_micros = 2 },
    };
    const estimate = try ziac.cost.computeWorkloadConfigurationEstimate(&prices, .{
        .resource_id = "gcp.compute.RegionInstanceGroupManager.europe-west1.api",
        .region = "europe-west1",
        .cpu_sku_id = "cpu",
        .memory_sku_id = "memory",
        .gpu_sku_id = "gpu",
        .disk_sku_id = "disk",
        .image_storage_sku_id = "image",
        .instance_hours = 1_460,
        .vcpu_per_instance = 2,
        .memory_gib_per_instance = 8,
        .gpu_per_instance = 1,
        .disk_gib_month = 100,
        .image_gib_month = 20,
        .observed_at_millis = 7,
    });
    try std.testing.expectEqual(@as(?i64, 1_256_040), estimate.amount_micros);
    try std.testing.expectEqual(ziac.cost.Origin.configuration_estimate, estimate.origin);
    try std.testing.expect(!estimate.provenance.is_billing_export);
}

test "Compute fleet applies imports refreshes no-op and emits qualification evidence" {
    var fleet = try buildFleet(false, false);
    defer fleet.deinit();
    var remote = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer remote.deinit();
    var providers = ziac.provider.ProviderRegistry{};
    providers.register(.gcp, remote.provider());
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    var create_plan = try ziac.plan.buildPlan(std.testing.allocator, &fleet.graph, &state);
    defer create_plan.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &create_plan, &state, providers, .{});

    var imported_remote = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer imported_remote.deinit();
    var imported_providers = ziac.provider.ProviderRegistry{};
    imported_providers.register(.gcp, imported_remote.provider());
    var imported_state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer imported_state.deinit();
    for (fleet.graph.resources.items) |node| {
        const record = state.get(node.id) orelse return error.MissingRecord;
        try ziac.importer.importResource(std.testing.allocator, node, record.physical_id orelse return error.MissingRecord, &imported_state, imported_providers, null);
    }
    var imported_plan = try ziac.plan.buildPlan(std.testing.allocator, &fleet.graph, &imported_state);
    defer imported_plan.deinit();
    for (imported_plan.operations) |item| try std.testing.expectEqual(ziac.plan.OperationKind.noop, item.kind);
    var refreshed = try ziac.plan.buildRefreshedPlan(std.testing.allocator, &fleet.graph, &imported_state, imported_providers);
    defer refreshed.deinit();
    for (refreshed.operations) |item| try std.testing.expectEqual(ziac.plan.OperationKind.noop, item.kind);

    var destroy = try ziac.plan.buildDestroyPlan(std.testing.allocator, &state);
    defer destroy.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &destroy, &state, providers, .{ .destructive_confirmation = true });
    var receipt = try ziac.gcp.compute_workloads_qualification.serializeLocalAlloc(std.testing.allocator, &fleet.graph, .{
        .created = remote.creates,
        .imported = imported_remote.imports,
        .no_op = imported_plan.operations.len,
        .retained = 0,
        .deleted = remote.deletes,
    });
    defer receipt.deinit();
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"schema\":\"ziac.gcp.compute-workloads-qualification.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"status\":\"passed\"") != null);
}

fn buildFleet(protect: bool, retain: bool) !ziac.gcp.ManagedInstanceFleet {
    return ziac.gcp.ManagedInstanceFleet.build(std.testing.allocator, provider, .{
        .name = "api",
        .scope = .{ .regional = .{ .region = "europe-west1", .zones = &.{ "europe-west1-b", "europe-west1-c" } } },
        .machine_type = "e2-standard-2",
        .source_image = ziac.PublicOutput([]const u8).known("projects/ziac-dev/global/images/api-image"),
        .network_interfaces = &.{.{
            .network = ziac.PublicOutput([]const u8).known("projects/ziac-dev/global/networks/platform"),
            .subnetwork = ziac.PublicOutput([]const u8).known("projects/ziac-dev/regions/europe-west1/subnetworks/platform"),
        }},
        .service_account = ziac.PublicOutput([]const u8).known("api@ziac-dev.iam.gserviceaccount.com"),
        .startup_script = ziac.SecretOutput(ziac.value.SecretReference).known(.{ .provider = "gcp-secret-manager", .resource = "startup-source-secret", .version = "1" }),
        .startup_script_sha256 = "52e6a26d1835b1d555a7701bf98e54d67f74fef5ea39c7f4422351137eab3cbd",
        .target_size = 2,
        .min_replicas = 2,
        .max_replicas = 12,
        .protect = protect,
        .retain_on_delete = retain,
    });
}

fn contains(values: []const []const u8, expected: []const u8) bool {
    for (values) |present| if (std.mem.eql(u8, present, expected)) return true;
    return false;
}
