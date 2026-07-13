const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
};

test "AnalyticsWarehouse compiles tables views routines and least privilege dataset access" {
    var warehouse = try ziac.gcp.AnalyticsWarehouse.build(std.testing.allocator, provider, .{
        .name = "product-analytics",
        .dataset_id = "product_analytics",
        .location = "EU",
        .tables = &.{.{
            .table_id = "events",
            .schema = &.{
                .{ .name = "event_id", .field_type = .string, .mode = .required },
                .{ .name = "occurred_at", .field_type = .timestamp, .mode = .required },
            },
            .time_partitioning = .{ .field = "occurred_at" },
            .require_partition_filter = true,
        }},
        .views = &.{.{
            .view_id = "daily_events",
            .query = "SELECT DATE(occurred_at) day, COUNT(*) events FROM `ziac-dev.product_analytics.events` GROUP BY day",
        }},
        .routines = &.{.{
            .routine_id = "normalize_id",
            .routine_type = .scalar_function,
            .language = .sql,
            .arguments = &.{.{ .name = "value", .data_type_json = "{\"typeKind\":\"STRING\"}" }},
            .return_type_json = "{\"typeKind\":\"STRING\"}",
            .definition_body = "LOWER(value)",
        }},
        .readers = &.{"group:analytics@example.com"},
        .writers = &.{"serviceAccount:ingest@ziac-dev.iam.gserviceaccount.com"},
    });
    defer warehouse.deinit();

    try warehouse.graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 6), warehouse.graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 1), warehouse.table_names.len);
    try std.testing.expectEqual(@as(usize, 1), warehouse.view_names.len);
    try std.testing.expectEqual(@as(usize, 1), warehouse.routine_names.len);
    try std.testing.expect(hasType(&warehouse.graph, "gcp.bigquery.Dataset"));
    try std.testing.expect(hasType(&warehouse.graph, "gcp.bigquery.Table"));
    try std.testing.expect(hasType(&warehouse.graph, "gcp.bigquery.View"));
    try std.testing.expect(hasType(&warehouse.graph, "gcp.bigquery.Routine"));
    try std.testing.expect(hasRole(&warehouse.graph, "roles/bigquery.dataViewer"));
    try std.testing.expect(hasRole(&warehouse.graph, "roles/bigquery.dataEditor"));
}

test "AnalyticsWarehouse rejects table and view physical identity overlap" {
    try std.testing.expectError(error.DuplicateWarehouseObject, ziac.gcp.AnalyticsWarehouse.build(std.testing.allocator, provider, .{
        .name = "analytics",
        .dataset_id = "analytics",
        .location = "EU",
        .tables = &.{.{
            .table_id = "events",
            .schema = &.{.{ .name = "id", .field_type = .string }},
        }},
        .views = &.{.{
            .view_id = "events",
            .query = "SELECT 1",
        }},
    }));
}

test "AnalyticsWarehouse graph identity is byte deterministic" {
    var first = try buildWarehouse();
    defer first.deinit();
    var second = try buildWarehouse();
    defer second.deinit();
    const first_digest = try ziac.plan.desiredGraphDigestAlloc(std.testing.allocator, &first.graph);
    const second_digest = try ziac.plan.desiredGraphDigestAlloc(std.testing.allocator, &second.graph);
    try std.testing.expectEqualSlices(u8, &first_digest, &second_digest);
}

test "BigQuery graph synthesizes exact API and runtime data permissions" {
    var warehouse = try ziac.gcp.AnalyticsWarehouse.build(std.testing.allocator, provider, .{
        .name = "analytics",
        .dataset_id = "analytics",
        .location = "EU",
        .tables = &.{.{
            .table_id = "events",
            .schema = &.{.{ .name = "id", .field_type = .string }},
        }},
        .readers = &.{"serviceAccount:api@ziac-dev.iam.gserviceaccount.com"},
    });
    defer warehouse.deinit();
    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &warehouse.graph);
    defer requirements.deinit(std.testing.allocator);
    try std.testing.expect(contains(requirements.apis, "bigquery.googleapis.com"));
    try std.testing.expect(requirements.hasPermission("bigquery.datasets.create"));
    try std.testing.expect(requirements.hasPermission("bigquery.tables.create"));
    try std.testing.expect(requirements.hasPermission("bigquery.datasets.setIamPolicy"));
    var permission_plan = try ziac.gcp.intelligence.synthesizePermissionPlan(std.testing.allocator, &warehouse.graph);
    defer permission_plan.deinit(std.testing.allocator);
    try std.testing.expect(permission_plan.hasPermission(.runtime, "bigquery.tables.getData"));
}

test "BigQuery visual artifact exposes warehouse topology and IAM access" {
    var warehouse = try ziac.gcp.AnalyticsWarehouse.build(std.testing.allocator, provider, .{
        .name = "analytics",
        .dataset_id = "analytics",
        .location = "EU",
        .tables = &.{.{
            .table_id = "events",
            .schema = &.{.{ .name = "id", .field_type = .string }},
        }},
        .readers = &.{"group:analytics@example.com"},
    });
    defer warehouse.deinit();
    var artifact = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &warehouse.graph, null, .{
        .stack = "analytics",
        .stage = "prod",
        .created_at_millis = 7,
    });
    defer artifact.deinit();
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"bigquery\":{\"kind\":\"dataset\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"bigquery\":{\"kind\":\"table\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"location\":\"EU\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"schema_field_count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"iam\",\"access\":\"read\",\"permissions\":[\"bigquery.tables.getData\"]") != null);
}

test "BigQuery cost model separates query storage and reserved slot assumptions" {
    const prices = [_]ziac.cost.SkuPrice{
        .{ .sku_id = "query", .region = "EU", .unit = "TiBy", .unit_quantity = 1, .unit_price_micros = 5_000_000 },
        .{ .sku_id = "storage", .region = "EU", .unit = "GiBy.mo", .unit_quantity = 1, .unit_price_micros = 20_000 },
        .{ .sku_id = "slots", .region = "EU", .unit = "slot.h", .unit_quantity = 1, .unit_price_micros = 40_000 },
    };
    const estimate = try ziac.cost.bigqueryConfigurationEstimate(&prices, .{
        .resource_id = "gcp.bigquery.Dataset.analytics",
        .region = "EU",
        .query_sku_id = "query",
        .storage_sku_id = "storage",
        .slot_sku_id = "slots",
        .query_tib = 2,
        .stored_gib_month = 100,
        .reserved_slot_hours = 50,
        .observed_at_millis = 7,
    });
    try std.testing.expectEqual(@as(?i64, 14_000_000), estimate.amount_micros);
    try std.testing.expectEqual(ziac.cost.Origin.configuration_estimate, estimate.origin);
    try std.testing.expect(!estimate.provenance.is_billing_export);
}

test "AnalyticsWarehouse applies imports refreshes no-op and preserves retained data" {
    var warehouse = try buildWarehouse();
    defer warehouse.deinit();

    var remote = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer remote.deinit();
    var providers = ziac.provider.ProviderRegistry{};
    providers.register(.gcp, remote.provider());
    var primary_state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer primary_state.deinit();
    var create_plan = try ziac.plan.buildPlan(std.testing.allocator, &warehouse.graph, &primary_state);
    defer create_plan.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &create_plan, &primary_state, providers, .{});
    try std.testing.expectEqual(warehouse.graph.resources.items.len, remote.creates);

    var imported_remote = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer imported_remote.deinit();
    var imported_providers = ziac.provider.ProviderRegistry{};
    imported_providers.register(.gcp, imported_remote.provider());
    var imported_state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer imported_state.deinit();
    for (warehouse.graph.resources.items) |node| {
        const record = primary_state.get(node.id) orelse return error.MissingRecord;
        try ziac.importer.importResource(
            std.testing.allocator,
            node,
            record.physical_id orelse return error.MissingRecord,
            &imported_state,
            imported_providers,
            null,
        );
    }
    var imported_plan = try ziac.plan.buildPlan(std.testing.allocator, &warehouse.graph, &imported_state);
    defer imported_plan.deinit();
    for (imported_plan.operations) |operation| try std.testing.expectEqual(ziac.plan.OperationKind.noop, operation.kind);
    var refreshed_plan = try ziac.plan.buildRefreshedPlan(std.testing.allocator, &warehouse.graph, &imported_state, imported_providers);
    defer refreshed_plan.deinit();
    for (refreshed_plan.operations) |operation| try std.testing.expectEqual(ziac.plan.OperationKind.noop, operation.kind);

    var retained_count: usize = 0;
    for (warehouse.graph.resources.items) |node| retained_count += @intFromBool(node.lifecycle.retain_on_delete);
    var destroy_plan = try ziac.plan.buildDestroyPlan(std.testing.allocator, &primary_state);
    defer destroy_plan.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &destroy_plan, &primary_state, providers, .{
        .destructive_confirmation = true,
    });
    try std.testing.expectEqual(warehouse.graph.resources.items.len - retained_count, remote.deletes);

    var receipt = try ziac.gcp.bigquery_qualification.serializeLocalAlloc(std.testing.allocator, &warehouse.graph, .{
        .created = remote.creates,
        .imported = imported_remote.imports,
        .no_op = imported_plan.operations.len,
        .retained = retained_count,
        .deleted = remote.deletes,
    });
    defer receipt.deinit();
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"schema\":\"ziac.gcp.bigquery-qualification.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"status\":\"passed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"authenticated\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"cost_origin\":\"configuration_estimate\"") != null);
}

fn buildWarehouse() !ziac.gcp.AnalyticsWarehouse {
    return ziac.gcp.AnalyticsWarehouse.build(std.testing.allocator, provider, .{
        .name = "analytics",
        .dataset_id = "analytics",
        .location = "EU",
        .tables = &.{.{
            .table_id = "events",
            .schema = &.{.{ .name = "id", .field_type = .string }},
        }},
        .views = &.{.{
            .view_id = "event_ids",
            .query = "SELECT id FROM `ziac-dev.analytics.events`",
        }},
        .readers = &.{"group:analytics@example.com"},
        .writers = &.{"serviceAccount:ingest@ziac-dev.iam.gserviceaccount.com"},
    });
}

fn hasType(graph: *const ziac.ResourceGraph, type_name: []const u8) bool {
    for (graph.resources.items) |node| if (std.mem.eql(u8, node.type_name, type_name)) return true;
    return false;
}

fn hasRole(graph: *const ziac.ResourceGraph, role: []const u8) bool {
    for (graph.resources.items) |node| if (inputString(node, "role")) |value| {
        if (std.mem.eql(u8, value, role)) return true;
    };
    return false;
}

fn inputString(node: ziac.ResourceNode, name: []const u8) ?[]const u8 {
    if (node.inputs != .object) return null;
    for (node.inputs.object) |field| if (std.mem.eql(u8, field.name, name)) return switch (field.value) {
        .string => |text| text,
        else => null,
    };
    return null;
}

fn contains(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, expected)) return true;
    return false;
}
