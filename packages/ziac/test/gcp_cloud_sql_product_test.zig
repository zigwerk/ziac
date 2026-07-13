const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
};

test "ManagedPostgres compiles a private primary replica data model identities and certificate" {
    var database = try buildManagedPostgres(true);
    defer database.deinit();

    try database.graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 9), database.graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 1), database.database_names.len);
    try std.testing.expectEqual(@as(usize, 2), database.user_names.len);
    try std.testing.expectEqual(@as(usize, 1), database.replica_connection_names.len);
    try std.testing.expect(database.client_certificate_private_key != null);
    try std.testing.expect(hasType(&database.graph, "gcp.sql.Instance"));
    try std.testing.expect(hasType(&database.graph, "gcp.sql.ReadReplica"));
    try std.testing.expect(hasType(&database.graph, "gcp.sql.Database"));
    try std.testing.expect(hasType(&database.graph, "gcp.sql.User"));
    try std.testing.expect(hasType(&database.graph, "gcp.sql.ClientCertificate"));
    try std.testing.expect(hasType(&database.graph, "gcp.secret.Secret"));
    try std.testing.expect(hasRole(&database.graph, "roles/cloudsql.instanceUser"));
    try std.testing.expect(hasRole(&database.graph, "roles/cloudsql.client"));
    try std.testing.expect(!hasTypePrefix(&database.graph, "gcp.network."));
    try std.testing.expect(!hasTypePrefix(&database.graph, "gcp.compute."));
}

test "ManagedPostgres requires explicit private connectivity and remains deterministic" {
    try std.testing.expectError(error.MissingPrivateConnectivityDependency, ziac.gcp.ManagedPostgres.build(std.testing.allocator, provider, .{
        .name = "postgres",
        .primary = primaryArgs(true),
    }));
    var public_primary = primaryArgs(true);
    public_primary.private_network = "";
    try std.testing.expectError(error.MissingPrivateConnectivityDependency, ziac.gcp.ManagedPostgres.build(std.testing.allocator, provider, .{
        .name = "postgres",
        .primary = public_primary,
        .replicas = &.{.{
            .instance_id = "private-replica",
            .region = "us-central1",
            .tier = "db-custom-2-4096",
            .private_network = "projects/ziac-dev/global/networks/platform",
        }},
    }));

    var first = try buildManagedPostgres(true);
    defer first.deinit();
    var second = try buildManagedPostgres(true);
    defer second.deinit();
    const first_digest = try ziac.plan.desiredGraphDigestAlloc(std.testing.allocator, &first.graph);
    const second_digest = try ziac.plan.desiredGraphDigestAlloc(std.testing.allocator, &second.graph);
    try std.testing.expectEqualSlices(u8, &first_digest, &second_digest);
}

test "Cloud SQL graph synthesizes Admin API and exact login and connector permissions" {
    var database = try buildManagedPostgres(true);
    defer database.deinit();
    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &database.graph);
    defer requirements.deinit(std.testing.allocator);
    try std.testing.expect(contains(requirements.apis, "sqladmin.googleapis.com"));
    try std.testing.expect(requirements.hasPermission("cloudsql.instances.create"));
    try std.testing.expect(requirements.hasPermission("cloudsql.databases.create"));
    try std.testing.expect(requirements.hasPermission("cloudsql.users.create"));
    try std.testing.expect(requirements.hasPermission("cloudsql.sslCerts.create"));
    var plan = try ziac.gcp.intelligence.synthesizePermissionPlan(std.testing.allocator, &database.graph);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expect(plan.hasPermission(.runtime, "cloudsql.instances.login"));
    try std.testing.expect(plan.hasPermission(.runtime, "cloudsql.instances.connect"));
}

test "Cloud SQL visual artifact exposes engine topology resilience connectivity and TLS" {
    var database = try buildManagedPostgres(true);
    defer database.deinit();
    var artifact = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &database.graph, null, .{
        .stack = "postgres",
        .stage = "prod",
        .created_at_millis = 7,
    });
    defer artifact.deinit();
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"cloud_sql\":{\"kind\":\"instance\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"engine\":\"POSTGRES_17\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"availability\":\"REGIONAL\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"role\":\"primary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"private_ip\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"ssl_mode\":\"ENCRYPTED_ONLY\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"kind\":\"iam\",\"access\":\"connect\",\"permissions\":[\"cloudsql.instances.connect\"]") != null);
}

test "Cloud SQL cost model keeps compute storage backup and egress assumptions explicit" {
    const prices = [_]ziac.cost.SkuPrice{
        .{ .sku_id = "cpu", .region = "europe-west1", .unit = "h", .unit_quantity = 1, .unit_price_micros = 100_000 },
        .{ .sku_id = "memory", .region = "europe-west1", .unit = "GiBy.h", .unit_quantity = 1, .unit_price_micros = 20_000 },
        .{ .sku_id = "storage", .region = "europe-west1", .unit = "GiBy.mo", .unit_quantity = 1, .unit_price_micros = 170_000 },
        .{ .sku_id = "backup", .region = "europe-west1", .unit = "GiBy.mo", .unit_quantity = 1, .unit_price_micros = 80_000 },
        .{ .sku_id = "egress", .region = "europe-west1", .unit = "GiBy", .unit_quantity = 1, .unit_price_micros = 120_000 },
    };
    const estimate = try ziac.cost.cloudSqlConfigurationEstimate(&prices, .{
        .resource_id = "gcp.sql.Instance.postgres-primary",
        .region = "europe-west1",
        .cpu_sku_id = "cpu",
        .memory_sku_id = "memory",
        .storage_sku_id = "storage",
        .backup_sku_id = "backup",
        .egress_sku_id = "egress",
        .vcpu_hours = 1_460,
        .memory_gib_hours = 2_920,
        .stored_gib_month = 20,
        .backup_gib_month = 10,
        .egress_gib = 50,
        .observed_at_millis = 7,
    });
    try std.testing.expectEqual(@as(?i64, 214_600_000), estimate.amount_micros);
    try std.testing.expectEqual(ziac.cost.Origin.configuration_estimate, estimate.origin);
    try std.testing.expect(!estimate.provenance.is_billing_export);
}

test "ManagedPostgres applies imports refreshes no-op and preserves retained data" {
    var database = try buildManagedPostgres(true);
    defer database.deinit();

    var remote = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer remote.deinit();
    var providers = ziac.provider.ProviderRegistry{};
    providers.register(.gcp, remote.provider());
    var primary_state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer primary_state.deinit();
    var create_plan = try ziac.plan.buildPlan(std.testing.allocator, &database.graph, &primary_state);
    defer create_plan.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &create_plan, &primary_state, providers, .{});
    try std.testing.expectEqual(database.graph.resources.items.len, remote.creates);

    var imported_remote = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer imported_remote.deinit();
    var imported_providers = ziac.provider.ProviderRegistry{};
    imported_providers.register(.gcp, imported_remote.provider());
    var imported_state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer imported_state.deinit();
    for (database.graph.resources.items) |node| {
        const record = primary_state.get(node.id) orelse return error.MissingRecord;
        try ziac.importer.importResource(std.testing.allocator, node, record.physical_id orelse return error.MissingRecord, &imported_state, imported_providers, null);
    }
    var imported_plan = try ziac.plan.buildPlan(std.testing.allocator, &database.graph, &imported_state);
    defer imported_plan.deinit();
    for (imported_plan.operations) |operation| try std.testing.expectEqual(ziac.plan.OperationKind.noop, operation.kind);
    var refreshed_plan = try ziac.plan.buildRefreshedPlan(std.testing.allocator, &database.graph, &imported_state, imported_providers);
    defer refreshed_plan.deinit();
    for (refreshed_plan.operations) |operation| try std.testing.expectEqual(ziac.plan.OperationKind.noop, operation.kind);

    var retained_count: usize = 0;
    for (database.graph.resources.items) |node| retained_count += @intFromBool(node.lifecycle.retain_on_delete);
    try std.testing.expectError(error.ProtectedResource, ziac.plan.buildDestroyPlan(std.testing.allocator, &primary_state));
    var unprotected = try buildManagedPostgres(false);
    defer unprotected.deinit();
    var unprotect_plan = try ziac.plan.buildPlan(std.testing.allocator, &unprotected.graph, &primary_state);
    defer unprotect_plan.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &unprotect_plan, &primary_state, providers, .{});
    var destroy_plan = try ziac.plan.buildDestroyPlan(std.testing.allocator, &primary_state);
    defer destroy_plan.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &destroy_plan, &primary_state, providers, .{ .destructive_confirmation = true });
    try std.testing.expectEqual(database.graph.resources.items.len - retained_count, remote.deletes);

    var receipt = try ziac.gcp.sql_qualification.serializeLocalAlloc(std.testing.allocator, &database.graph, .{
        .created = remote.creates,
        .imported = imported_remote.imports,
        .no_op = imported_plan.operations.len,
        .retained = retained_count,
        .deleted = remote.deletes,
    });
    defer receipt.deinit();
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"schema\":\"ziac.gcp.cloud-sql-qualification.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"status\":\"passed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"authenticated\":false") != null);
}

fn buildManagedPostgres(protect: bool) !ziac.gcp.ManagedPostgres {
    return ziac.gcp.ManagedPostgres.build(std.testing.allocator, provider, .{
        .name = "postgres",
        .primary = primaryArgs(protect),
        .private_connectivity_dependency = ziac.PublicOutput([]const u8).known("projects/ziac-dev/global/networks/platform"),
        .databases = &.{.{ .name = "app" }},
        .builtin_users = &.{.{
            .name = "app",
            .password = ziac.SecretOutput(ziac.value.SecretReference).known(.{
                .provider = "gcp-secret-manager",
                .resource = "projects/ziac-dev/secrets/postgres-app-password",
                .version = "3",
            }),
        }},
        .iam_users = &.{.{
            .name = "api@ziac-dev.iam",
            .user_type = .cloud_iam_service_account,
            .member = "serviceAccount:api@ziac-dev.iam.gserviceaccount.com",
            .client = true,
        }},
        .replicas = &.{.{
            .instance_id = "postgres-replica",
            .region = "us-central1",
            .tier = "db-custom-2-4096",
            .private_network = "projects/ziac-dev/global/networks/platform",
            .protect = protect,
        }},
        .client_certificate = .{
            .common_name = "ziac-client",
            .secret_id = "postgres-client-key",
        },
    });
}

fn primaryArgs(protect: bool) ziac.gcp.sql.InstanceArgs {
    return .{
        .instance_id = "postgres-primary",
        .database_version = .postgres_17,
        .region = "europe-west1",
        .tier = "db-custom-2-4096",
        .availability = .regional,
        .point_in_time_recovery = true,
        .private_network = "projects/ziac-dev/global/networks/platform",
        .protect = protect,
    };
}

fn hasType(graph: *const ziac.ResourceGraph, type_name: []const u8) bool {
    for (graph.resources.items) |node| if (std.mem.eql(u8, node.type_name, type_name)) return true;
    return false;
}

fn hasTypePrefix(graph: *const ziac.ResourceGraph, prefix: []const u8) bool {
    for (graph.resources.items) |node| if (std.mem.startsWith(u8, node.type_name, prefix)) return true;
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
