const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
};

test "data services synthesize provider APIs least privilege and runtime access" {
    var platform = try buildDataPlatform(true, true);
    defer platform.deinit();

    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &platform.graph);
    defer requirements.deinit(std.testing.allocator);
    try std.testing.expect(contains(requirements.apis, "spanner.googleapis.com"));
    try std.testing.expect(contains(requirements.apis, "redis.googleapis.com"));
    try std.testing.expect(contains(requirements.apis, "servicenetworking.googleapis.com"));
    try std.testing.expect(contains(requirements.apis, "compute.googleapis.com"));
    try std.testing.expect(contains(requirements.apis, "secretmanager.googleapis.com"));
    try std.testing.expect(requirements.hasPermission("spanner.instances.create"));
    try std.testing.expect(requirements.hasPermission("spanner.databases.create"));
    try std.testing.expect(requirements.hasPermission("spanner.backups.create"));
    try std.testing.expect(requirements.hasPermission("spanner.backupSchedules.create"));
    try std.testing.expect(requirements.hasPermission("spanner.databases.setIamPolicy"));
    try std.testing.expect(requirements.hasPermission("redis.instances.create"));
    try std.testing.expect(requirements.hasPermission("redis.instances.upgrade"));
    try std.testing.expect(requirements.hasPermission("secretmanager.versions.add"));
    try std.testing.expect(requirements.hasPermission("compute.globalAddresses.create"));
    try std.testing.expect(requirements.hasPermission("servicenetworking.services.addPeering"));

    var permission_plan = try ziac.gcp.intelligence.synthesizePermissionPlan(std.testing.allocator, &platform.graph);
    defer permission_plan.deinit(std.testing.allocator);
    try std.testing.expect(permission_plan.hasPermission(.runtime, "spanner.databases.read"));
}

test "data services visual artifact carries capacity resilience connectivity and access semantics" {
    var platform = try buildDataPlatform(true, true);
    defer platform.deinit();
    var artifact = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &platform.graph, null, .{
        .stack = "data-platform",
        .stage = "prod",
        .created_at_millis = 7,
    });
    defer artifact.deinit();

    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"spanner\":{\"kind\":\"instance\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"capacity_mode\":\"autoscaling_processing_units\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"spanner\":{\"kind\":\"database\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"spanner\":{\"kind\":\"backup_schedule\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"memorystore\":{\"kind\":\"instance\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"tier\":\"STANDARD_HA\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"auth_enabled\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"private_connectivity\":{\"kind\":\"range\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"private_connectivity\":{\"kind\":\"connection\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"iam\",\"access\":\"read_write\",\"permissions\":[\"spanner.databases.read\"]") != null);
}

test "estate scan maps only Cloud Asset identities that Google exposes for adoption" {
    var client = ziac.estate.ScriptedClient.init(std.testing.allocator);
    defer client.deinit();
    try client.addPage(
        \\{"results":[
        \\{"name":"//spanner.googleapis.com/projects/acme-prod/instances/global-app","assetType":"spanner.googleapis.com/Instance","project":"projects/123","location":"global","displayName":"global-app"},
        \\{"name":"//spanner.googleapis.com/projects/acme-prod/instances/global-app/databases/app","assetType":"spanner.googleapis.com/Database","project":"projects/123","location":"global","displayName":"app"},
        \\{"name":"//spanner.googleapis.com/projects/acme-prod/instances/global-app/backups/release","assetType":"spanner.googleapis.com/Backup","project":"projects/123","location":"global","displayName":"release"},
        \\{"name":"//spanner.googleapis.com/projects/acme-prod/instances/global-app/databases/app/backupSchedules/daily","assetType":"spanner.googleapis.com/BackupSchedule","project":"projects/123","location":"global","displayName":"daily"},
        \\{"name":"//redis.googleapis.com/projects/acme-prod/locations/europe-west1/instances/sessions","assetType":"redis.googleapis.com/Instance","project":"projects/123","location":"europe-west1","displayName":"sessions"},
        \\{"name":"//redis.googleapis.com/projects/acme-prod/locations/us-central1/clusters/global-cache","assetType":"redis.googleapis.com/Cluster","project":"projects/123","location":"us-central1","displayName":"global-cache"},
        \\{"name":"//servicenetworking.googleapis.com/services/servicenetworking.googleapis.com/connections/managed-services","assetType":"servicenetworking.googleapis.com/Connection","project":"projects/123","location":"global","displayName":"managed-services"}
        \\]}
    );
    var scan = try ziac.estate.scanAlloc(std.testing.allocator, client.client(), .{
        .identity = .{ .provider = .google, .verified = true, .subject = "subject" },
        .entitlement = .pro,
        .connection = .{ .status = .connected, .project_id = "acme-prod" },
        .observed_at_millis = 1_783_764_000_000,
    });
    defer scan.deinit();

    try std.testing.expectEqual(@as(usize, 7), scan.resource_count);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.spanner.Instance") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.spanner.Database") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.spanner.Backup") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.redis.Instance") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.redis.Cluster") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.servicenetworking.Connection") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "\"physical_id\":\"projects/acme-prod/instances/global-app/databases/app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "\"type\":\"gcp.asset.Resource\"") != null);
}

test "Spanner and Memorystore estimates preserve explicit service assumptions" {
    const prices = [_]ziac.cost.SkuPrice{
        .{ .sku_id = "spanner-compute", .region = "nam-eur-asia1", .unit = "100 processing units.h", .unit_quantity = 100, .unit_price_micros = 10_000 },
        .{ .sku_id = "spanner-storage", .region = "nam-eur-asia1", .unit = "GiBy.mo", .unit_quantity = 1, .unit_price_micros = 300_000 },
        .{ .sku_id = "spanner-backup", .region = "nam-eur-asia1", .unit = "GiBy.mo", .unit_quantity = 1, .unit_price_micros = 100_000 },
        .{ .sku_id = "redis-capacity", .region = "europe-west1", .unit = "GiBy.h", .unit_quantity = 1, .unit_price_micros = 50_000 },
        .{ .sku_id = "redis-egress", .region = "europe-west1", .unit = "GiBy", .unit_quantity = 1, .unit_price_micros = 120_000 },
    };
    const spanner = try ziac.cost.spannerConfigurationEstimate(&prices, .{
        .resource_id = "gcp.spanner.Instance.global-app",
        .region = "nam-eur-asia1",
        .compute_sku_id = "spanner-compute",
        .storage_sku_id = "spanner-storage",
        .backup_sku_id = "spanner-backup",
        .processing_unit_hours = 10_000,
        .stored_gib_month = 20,
        .backup_gib_month = 10,
        .observed_at_millis = 7,
    });
    try std.testing.expectEqual(@as(?i64, 8_000_000), spanner.amount_micros);
    try std.testing.expectEqual(ziac.cost.Origin.configuration_estimate, spanner.origin);

    const memorystore = try ziac.cost.memorystoreConfigurationEstimate(&prices, .{
        .resource_id = "gcp.redis.Instance.europe-west1.sessions",
        .region = "europe-west1",
        .capacity_sku_id = "redis-capacity",
        .egress_sku_id = "redis-egress",
        .capacity_gib_hours = 5_840,
        .egress_gib = 50,
        .observed_at_millis = 7,
    });
    try std.testing.expectEqual(@as(?i64, 298_000_000), memorystore.amount_micros);
    try std.testing.expect(!memorystore.provenance.is_billing_export);
}

test "data platform applies imports refreshes no-op and emits local qualification evidence" {
    var platform = try buildDataPlatform(false, false);
    defer platform.deinit();
    var remote = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer remote.deinit();
    var providers = ziac.provider.ProviderRegistry{};
    providers.register(.gcp, remote.provider());
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    var create_plan = try ziac.plan.buildPlan(std.testing.allocator, &platform.graph, &state);
    defer create_plan.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &create_plan, &state, providers, .{});

    var imported_remote = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer imported_remote.deinit();
    var imported_providers = ziac.provider.ProviderRegistry{};
    imported_providers.register(.gcp, imported_remote.provider());
    var imported_state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer imported_state.deinit();
    for (platform.graph.resources.items) |node| {
        const record = state.get(node.id) orelse return error.MissingRecord;
        try ziac.importer.importResource(std.testing.allocator, node, record.physical_id orelse return error.MissingRecord, &imported_state, imported_providers, null);
    }
    var imported_plan = try ziac.plan.buildPlan(std.testing.allocator, &platform.graph, &imported_state);
    defer imported_plan.deinit();
    for (imported_plan.operations) |operation| try std.testing.expectEqual(ziac.plan.OperationKind.noop, operation.kind);
    var refreshed_plan = try ziac.plan.buildRefreshedPlan(std.testing.allocator, &platform.graph, &imported_state, imported_providers);
    defer refreshed_plan.deinit();
    for (refreshed_plan.operations) |operation| try std.testing.expectEqual(ziac.plan.OperationKind.noop, operation.kind);

    var destroy_plan = try ziac.plan.buildDestroyPlan(std.testing.allocator, &state);
    defer destroy_plan.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &destroy_plan, &state, providers, .{ .destructive_confirmation = true });
    try std.testing.expectEqual(platform.graph.resources.items.len, remote.deletes);

    var receipt = try ziac.gcp.data_services_qualification.serializeLocalAlloc(std.testing.allocator, &platform.graph, .{
        .created = remote.creates,
        .imported = imported_remote.imports,
        .no_op = imported_plan.operations.len,
        .retained = 0,
        .deleted = remote.deletes,
    });
    defer receipt.deinit();
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"schema\":\"ziac.gcp.data-services-qualification.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"status\":\"passed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"authenticated\":false") != null);
}

fn buildDataPlatform(protect: bool, retain_on_delete: bool) !ziac.gcp.MemorystoreCache {
    var access = try ziac.gcp.PrivateServiceAccess.build(std.testing.allocator, provider, .{
        .name = "managed-services",
        .network = "projects/ziac-dev/global/networks/platform",
        .prefix_length = 16,
        .protect = protect,
        .retain_on_delete = retain_on_delete,
    });
    defer access.deinit();
    var database = try ziac.gcp.SpannerDatabase.build(std.testing.allocator, provider, .{
        .base_graph = &access.graph,
        .name = "global-app",
        .instance = .{
            .instance_id = "global-app",
            .config = "nam-eur-asia1",
            .display_name = "Global application",
            .edition = .enterprise_plus,
            .capacity = .{ .autoscaling_processing_units = .{ .min = 1_000, .max = 5_000 } },
            .default_backup_schedule = .none,
            .protect = protect,
            .retain_on_delete = retain_on_delete,
        },
        .database_id = "app",
        .ddl = &.{"CREATE TABLE users (id STRING(36) NOT NULL) PRIMARY KEY (id)"},
        .protect = protect,
        .retain_on_delete = retain_on_delete,
        .backup_schedule = .{
            .schedule_id = "daily",
            .cron = "0 2 * * *",
            .retention_seconds = 14 * 24 * 60 * 60,
            .retain_on_delete = retain_on_delete,
        },
        .backups = &.{.{
            .backup_id = "release",
            .expire_time = "2027-07-13T12:00:00Z",
            .protect = protect,
            .retain_on_delete = retain_on_delete,
        }},
        .database_members = &.{.{
            .name = "api-runtime",
            .role = "roles/spanner.databaseUser",
            .member = "serviceAccount:api@ziac-dev.iam.gserviceaccount.com",
        }},
    });
    defer database.deinit();
    return ziac.gcp.MemorystoreCache.build(std.testing.allocator, provider, .{
        .base_graph = &database.graph,
        .name = "sessions",
        .cache = .{ .classic = .{
            .instance_id = "sessions",
            .location = "europe-west1",
            .tier = .standard_ha,
            .memory_size_gb = 8,
            .network = "projects/ziac-dev/global/networks/platform",
            .connect_mode = .private_service_access,
            .connectivity_dependency = access.connection_name,
            .auth_secret = ziac.PublicOutput([]const u8).known("projects/ziac-dev/secrets/redis-auth"),
            .read_replicas = 1,
            .persistence = .{ .rdb = .twelve_hours },
            .maintenance_day = "MONDAY",
            .maintenance_hour_utc = 2,
            .protect = protect,
            .retain_on_delete = retain_on_delete,
        } },
    });
}

fn contains(values: []const []const u8, expected: []const u8) bool {
    for (values) |present| if (std.mem.eql(u8, present, expected)) return true;
    return false;
}
