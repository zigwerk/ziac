const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
};

test "DocumentStore compiles database indexes fields backups and least privilege access" {
    var store = try buildStore();
    defer store.deinit();

    try store.graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 7), store.graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.index_names.len);
    try std.testing.expectEqual(@as(usize, 1), store.field_names.len);
    try std.testing.expectEqual(@as(usize, 2), store.backup_schedule_names.len);
    try std.testing.expect(hasType(&store.graph, "gcp.firestore.Database"));
    try std.testing.expect(hasType(&store.graph, "gcp.firestore.Index"));
    try std.testing.expect(hasType(&store.graph, "gcp.firestore.Field"));
    try std.testing.expect(hasType(&store.graph, "gcp.firestore.BackupSchedule"));
    try std.testing.expect(hasRole(&store.graph, "roles/datastore.viewer"));
    try std.testing.expect(hasRole(&store.graph, "roles/datastore.user"));
}

test "DocumentStore rejects duplicate backup recurrences and remains deterministic" {
    try std.testing.expectError(error.DuplicateBackupRecurrence, ziac.gcp.DocumentStore.build(std.testing.allocator, provider, .{
        .name = "documents",
        .database_id = "documents",
        .location = "eur3",
        .backup_schedules = &.{
            .{ .name = "daily-a", .recurrence = .daily, .retention_seconds = 7 * 24 * 60 * 60 },
            .{ .name = "daily-b", .recurrence = .daily, .retention_seconds = 14 * 24 * 60 * 60 },
        },
    }));

    var first = try buildStore();
    defer first.deinit();
    var second = try buildStore();
    defer second.deinit();
    const first_digest = try ziac.plan.desiredGraphDigestAlloc(std.testing.allocator, &first.graph);
    const second_digest = try ziac.plan.desiredGraphDigestAlloc(std.testing.allocator, &second.graph);
    try std.testing.expectEqualSlices(u8, &first_digest, &second_digest);
}

test "Firestore graph synthesizes Admin API and runtime datastore permissions" {
    var store = try buildStore();
    defer store.deinit();
    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &store.graph);
    defer requirements.deinit(std.testing.allocator);
    try std.testing.expect(contains(requirements.apis, "firestore.googleapis.com"));
    try std.testing.expect(requirements.hasPermission("datastore.databases.create"));
    try std.testing.expect(requirements.hasPermission("datastore.indexes.create"));
    try std.testing.expect(requirements.hasPermission("datastore.fields.update"));
    try std.testing.expect(requirements.hasPermission("datastore.backupSchedules.create"));
    try std.testing.expect(requirements.hasPermission("datastore.databases.setIamPolicy"));
    var plan = try ziac.gcp.intelligence.synthesizePermissionPlan(std.testing.allocator, &store.graph);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expect(plan.hasPermission(.runtime, "datastore.entities.get"));
    try std.testing.expect(plan.hasPermission(.runtime, "datastore.entities.create"));
}

test "Firestore visual artifact exposes document topology backups TTL and IAM access" {
    var store = try buildStore();
    defer store.deinit();
    var artifact = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &store.graph, null, .{
        .stack = "documents",
        .stage = "prod",
        .created_at_millis = 7,
    });
    defer artifact.deinit();
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"firestore\":{\"kind\":\"database\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"firestore\":{\"kind\":\"index\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"firestore\":{\"kind\":\"field\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"ttl_enabled\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"firestore\":{\"kind\":\"backup_schedule\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"iam\",\"access\":\"read\",\"permissions\":[\"datastore.entities.get\"]") != null);
}

test "Firestore cost model separates operation storage and backup assumptions" {
    const prices = [_]ziac.cost.SkuPrice{
        .{ .sku_id = "reads", .region = "eur3", .unit = "100K ops", .unit_quantity = 100_000, .unit_price_micros = 30_000 },
        .{ .sku_id = "writes", .region = "eur3", .unit = "100K ops", .unit_quantity = 100_000, .unit_price_micros = 90_000 },
        .{ .sku_id = "deletes", .region = "eur3", .unit = "100K ops", .unit_quantity = 100_000, .unit_price_micros = 10_000 },
        .{ .sku_id = "storage", .region = "eur3", .unit = "GiBy.mo", .unit_quantity = 1, .unit_price_micros = 180_000 },
        .{ .sku_id = "backup", .region = "eur3", .unit = "GiBy.mo", .unit_quantity = 1, .unit_price_micros = 30_000 },
    };
    const estimate = try ziac.cost.firestoreConfigurationEstimate(&prices, .{
        .resource_id = "gcp.firestore.Database.documents",
        .region = "eur3",
        .read_sku_id = "reads",
        .write_sku_id = "writes",
        .delete_sku_id = "deletes",
        .storage_sku_id = "storage",
        .backup_sku_id = "backup",
        .document_reads = 1_000_000,
        .document_writes = 500_000,
        .document_deletes = 100_000,
        .stored_gib_month = 10,
        .backup_gib_month = 20,
        .observed_at_millis = 7,
    });
    try std.testing.expectEqual(@as(?i64, 3_160_000), estimate.amount_micros);
    try std.testing.expectEqual(ziac.cost.Origin.configuration_estimate, estimate.origin);
    try std.testing.expect(!estimate.provenance.is_billing_export);
}

test "DocumentStore applies imports refreshes no-op and preserves retained data" {
    var store = try buildStore();
    defer store.deinit();

    var remote = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer remote.deinit();
    var providers = ziac.provider.ProviderRegistry{};
    providers.register(.gcp, remote.provider());
    var primary_state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer primary_state.deinit();
    var create_plan = try ziac.plan.buildPlan(std.testing.allocator, &store.graph, &primary_state);
    defer create_plan.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &create_plan, &primary_state, providers, .{});
    try std.testing.expectEqual(store.graph.resources.items.len, remote.creates);

    var imported_remote = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer imported_remote.deinit();
    var imported_providers = ziac.provider.ProviderRegistry{};
    imported_providers.register(.gcp, imported_remote.provider());
    var imported_state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer imported_state.deinit();
    for (store.graph.resources.items) |node| {
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
    var imported_plan = try ziac.plan.buildPlan(std.testing.allocator, &store.graph, &imported_state);
    defer imported_plan.deinit();
    for (imported_plan.operations) |operation| try std.testing.expectEqual(ziac.plan.OperationKind.noop, operation.kind);
    var refreshed_plan = try ziac.plan.buildRefreshedPlan(std.testing.allocator, &store.graph, &imported_state, imported_providers);
    defer refreshed_plan.deinit();
    for (refreshed_plan.operations) |operation| try std.testing.expectEqual(ziac.plan.OperationKind.noop, operation.kind);

    var retained_count: usize = 0;
    for (store.graph.resources.items) |node| retained_count += @intFromBool(node.lifecycle.retain_on_delete);
    try std.testing.expectError(error.ProtectedResource, ziac.plan.buildDestroyPlan(std.testing.allocator, &primary_state));
    var unprotected = try buildStoreWithProtect(false);
    defer unprotected.deinit();
    var unprotect_plan = try ziac.plan.buildPlan(std.testing.allocator, &unprotected.graph, &primary_state);
    defer unprotect_plan.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &unprotect_plan, &primary_state, providers, .{});
    try std.testing.expect(!(primary_state.get("gcp.firestore.Database.documents") orelse return error.MissingRecord).protect);
    var destroy_plan = try ziac.plan.buildDestroyPlan(std.testing.allocator, &primary_state);
    defer destroy_plan.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &destroy_plan, &primary_state, providers, .{
        .destructive_confirmation = true,
    });
    try std.testing.expectEqual(store.graph.resources.items.len - retained_count, remote.deletes);

    var receipt = try ziac.gcp.firestore_qualification.serializeLocalAlloc(std.testing.allocator, &store.graph, .{
        .created = remote.creates,
        .imported = imported_remote.imports,
        .no_op = imported_plan.operations.len,
        .retained = retained_count,
        .deleted = remote.deletes,
    });
    defer receipt.deinit();
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"schema\":\"ziac.gcp.firestore-qualification.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"status\":\"passed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"authenticated\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"cost_origin\":\"configuration_estimate\"") != null);
}

fn buildStore() !ziac.gcp.DocumentStore {
    return buildStoreWithProtect(true);
}

fn buildStoreWithProtect(protect: bool) !ziac.gcp.DocumentStore {
    return ziac.gcp.DocumentStore.build(std.testing.allocator, provider, .{
        .name = "documents",
        .database_id = "documents",
        .location = "eur3",
        .point_in_time_recovery = true,
        .delete_protection = true,
        .protect = protect,
        .indexes = &.{.{
            .name = "matches-by-status",
            .collection_group = "matches",
            .query_scope = .collection_group,
            .fields = &.{
                .{ .field_path = "status", .mode = .ascending },
                .{ .field_path = "played_at", .mode = .descending },
            },
        }},
        .fields = &.{.{
            .collection_group = "sessions",
            .field_path = "expires_at",
            .ttl_enabled = true,
            .index_modes = &.{ .ascending, .descending },
        }},
        .backup_schedules = &.{
            .{ .name = "daily", .recurrence = .daily, .retention_seconds = 8 * 7 * 24 * 60 * 60 },
            .{ .name = "weekly", .recurrence = .{ .weekly = .sunday }, .retention_seconds = 14 * 7 * 24 * 60 * 60 },
        },
        .readers = &.{"group:analytics@example.com"},
        .writers = &.{"serviceAccount:api@ziac-dev.iam.gserviceaccount.com"},
    });
}

fn hasType(graph: *const ziac.ResourceGraph, type_name: []const u8) bool {
    for (graph.resources.items) |node| if (std.mem.eql(u8, node.type_name, type_name)) return true;
    return false;
}

fn hasRole(graph: *const ziac.ResourceGraph, role: []const u8) bool {
    for (graph.resources.items) |node| if (inputString(node, "role")) |present| {
        if (std.mem.eql(u8, present, role)) return true;
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
    for (values) |present| if (std.mem.eql(u8, present, expected)) return true;
    return false;
}
