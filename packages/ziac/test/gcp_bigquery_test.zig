const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
};

test "BigQuery primitives compile a contained analytics graph with explicit capacity" {
    var dataset = try ziac.gcp.bigquery.Dataset.build(std.testing.allocator, provider, .{
        .dataset_id = "product_analytics",
        .location = "EU",
        .description = "Product analytics data",
        .default_table_expiration_ms = 30 * 24 * 60 * 60 * 1000,
        .default_partition_expiration_ms = 7 * 24 * 60 * 60 * 1000,
        .default_kms_key_name = "projects/ziac-dev/locations/europe-west1/keyRings/data/cryptoKeys/bigquery",
        .labels = &.{.{ .key = "owner", .value = "platform" }},
    });
    defer dataset.deinit(std.testing.allocator);

    const fields = [_]ziac.gcp.bigquery.FieldSchema{
        .{ .name = "event_id", .field_type = .string, .mode = .required },
        .{ .name = "occurred_at", .field_type = .timestamp, .mode = .required },
        .{ .name = "account", .field_type = .record, .fields = &.{
            .{ .name = "id", .field_type = .string, .mode = .required },
            .{ .name = "country", .field_type = .string },
        } },
    };
    var table = try ziac.gcp.bigquery.Table.build(std.testing.allocator, provider, .{
        .dataset = dataset.name,
        .dataset_id = "product_analytics",
        .table_id = "events",
        .schema = &fields,
        .time_partitioning = .{ .field = "occurred_at", .granularity = .day, .expiration_ms = 7 * 24 * 60 * 60 * 1000 },
        .clustering_fields = &.{"account.id"},
        .require_partition_filter = true,
    });
    defer table.deinit(std.testing.allocator);

    var view = try ziac.gcp.bigquery.View.build(std.testing.allocator, provider, .{
        .dataset = dataset.name,
        .dataset_id = "product_analytics",
        .view_id = "daily_events",
        .query = "SELECT DATE(occurred_at) day, COUNT(*) events FROM `ziac-dev.product_analytics.events` GROUP BY day",
    });
    defer view.deinit(std.testing.allocator);

    var routine = try ziac.gcp.bigquery.Routine.build(std.testing.allocator, provider, .{
        .dataset = dataset.name,
        .dataset_id = "product_analytics",
        .routine_id = "normalize_country",
        .routine_type = .scalar_function,
        .language = .sql,
        .arguments = &.{.{ .name = "country", .data_type_json = "{\"typeKind\":\"STRING\"}" }},
        .return_type_json = "{\"typeKind\":\"STRING\"}",
        .definition_body = "UPPER(country)",
    });
    defer routine.deinit(std.testing.allocator);

    var connection = try ziac.gcp.bigquery.Connection.build(std.testing.allocator, provider, .{
        .connection_id = "vertex",
        .location = "EU",
        .kind = .cloud_resource,
    });
    defer connection.deinit(std.testing.allocator);

    var commitment = try ziac.gcp.bigquery.CapacityCommitment.build(std.testing.allocator, provider, .{
        .commitment_id = "analytics-slots",
        .location = "EU",
        .slot_count = 100,
        .plan = .monthly,
        .edition = .enterprise,
    });
    defer commitment.deinit(std.testing.allocator);
    var reservation = try ziac.gcp.bigquery.Reservation.build(std.testing.allocator, provider, .{
        .reservation_id = "analytics",
        .location = "EU",
        .slot_capacity = 50,
        .max_slots = 100,
        .edition = .enterprise,
    });
    defer reservation.deinit(std.testing.allocator);
    var assignment = try ziac.gcp.bigquery.ReservationAssignment.build(std.testing.allocator, provider, .{
        .name = "analytics-project",
        .reservation = reservation.name,
        .location = "EU",
        .reservation_id = "analytics",
        .assignee = "projects/123456789012",
        .job_type = .query,
    });
    defer assignment.deinit(std.testing.allocator);
    var reader = try ziac.gcp.bigquery.DatasetIamMember.build(std.testing.allocator, provider, .{
        .name = "analytics-readers",
        .dataset = dataset.name,
        .dataset_id = "product_analytics",
        .role = "roles/bigquery.dataViewer",
        .member = "group:analytics@example.com",
    });
    defer reader.deinit(std.testing.allocator);

    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    for ([_]ziac.ResourceNode{
        dataset.node,
        table.node,
        view.node,
        routine.node,
        connection.node,
        commitment.node,
        reservation.node,
        assignment.node,
        reader.node,
    }) |node| try graph.addResource(node);

    try graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 9), graph.resources.items.len);
    try std.testing.expect(hasDependency(&graph, table.node.id, dataset.node.id));
    try std.testing.expect(hasDependency(&graph, view.node.id, dataset.node.id));
    try std.testing.expect(hasDependency(&graph, routine.node.id, dataset.node.id));
    try std.testing.expect(hasDependency(&graph, assignment.node.id, reservation.node.id));
    try std.testing.expect(hasDependency(&graph, reader.node.id, dataset.node.id));
    try std.testing.expect(dataset.node.lifecycle.retain_on_delete);
    try std.testing.expect(commitment.node.lifecycle.protect);
    try std.testing.expect(commitment.node.lifecycle.retain_on_delete);
    try std.testing.expectEqualStrings("member", stringField(reader.node.inputs, "ownership_mode"));
}

test "BigQuery declarations reject unsafe schemas views reservations and connection secrets" {
    const dataset = ziac.PublicOutput([]const u8).known("projects/ziac-dev/datasets/product_analytics");
    try std.testing.expectError(error.DuplicateField, ziac.gcp.bigquery.Table.build(std.testing.allocator, provider, .{
        .dataset = dataset,
        .dataset_id = "product_analytics",
        .table_id = "events",
        .schema = &.{
            .{ .name = "id", .field_type = .string },
            .{ .name = "id", .field_type = .integer },
        },
    }));
    try std.testing.expectError(error.InvalidView, ziac.gcp.bigquery.View.build(std.testing.allocator, provider, .{
        .dataset = dataset,
        .dataset_id = "product_analytics",
        .view_id = "legacy",
        .query = "SELECT 1",
        .use_legacy_sql = true,
    }));
    try std.testing.expectError(error.InvalidReservation, ziac.gcp.bigquery.Reservation.build(std.testing.allocator, provider, .{
        .reservation_id = "analytics",
        .location = "EU",
        .slot_capacity = 100,
        .max_slots = 50,
    }));
    try std.testing.expectError(error.CredentialMaterialRejected, ziac.gcp.bigquery.Connection.build(std.testing.allocator, provider, .{
        .connection_id = "unsafe",
        .location = "EU",
        .kind = .cloud_sql,
        .credential_json = "{\"password\":\"sentinel-secret-for-tests\"}",
    }));
}

fn hasDependency(graph: *const ziac.ResourceGraph, from: []const u8, to: []const u8) bool {
    for (graph.dependencies.items) |edge| {
        if (std.mem.eql(u8, edge.from, from) and std.mem.eql(u8, edge.to, to)) return true;
    }
    return false;
}

fn stringField(input: ziac.value.Value, name: []const u8) []const u8 {
    for (input.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value.string;
    unreachable;
}
