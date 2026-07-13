const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;

test "live BigQuery provider manages datasets and tables with normalized import" {
    const dataset_json =
        "{\"kind\":\"bigquery#dataset\",\"etag\":\"etag-d1\",\"id\":\"ziac-dev:analytics\",\"selfLink\":\"https://bigquery.googleapis.com/bigquery/v2/projects/ziac-dev/datasets/analytics\",\"datasetReference\":{\"datasetId\":\"analytics\",\"projectId\":\"ziac-dev\"},\"friendlyName\":\"Analytics\",\"description\":\"Product data\",\"location\":\"EU\",\"defaultTableExpirationMs\":\"86400000\",\"labels\":{\"owner\":\"platform\"}}";
    const table_json =
        "{\"kind\":\"bigquery#table\",\"etag\":\"etag-t1\",\"id\":\"ziac-dev:analytics.events\",\"tableReference\":{\"projectId\":\"ziac-dev\",\"datasetId\":\"analytics\",\"tableId\":\"events\"},\"schema\":{\"fields\":[{\"name\":\"id\",\"type\":\"STRING\",\"mode\":\"REQUIRED\"}]},\"numBytes\":\"2048\",\"numRows\":\"12\",\"type\":\"TABLE\"}";
    const responses = [_]zstd.Http.Response{
        notFound(),                     ok(dataset_json),               ok(dataset_json), ok(dataset_json),
        notFound(),                     ok(table_json),                 ok(table_json),   ok(table_json),
        .{ .status = 204, .body = "" }, .{ .status = 204, .body = "" },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var dataset = try ziac.gcp.bigquery.Dataset.build(std.testing.allocator, config(), .{
        .dataset_id = "analytics",
        .location = "EU",
        .friendly_name = "Analytics",
        .description = "Product data",
        .default_table_expiration_ms = 86_400_000,
        .labels = &.{.{ .key = "owner", .value = "platform" }},
        .retain_on_delete = false,
    });
    defer dataset.deinit(std.testing.allocator);
    var table = try ziac.gcp.bigquery.Table.build(std.testing.allocator, config(), .{
        .dataset = .{ .value = "projects/ziac-dev/datasets/analytics" },
        .dataset_id = "analytics",
        .table_id = "events",
        .schema = &.{.{ .name = "id", .field_type = .string, .mode = .required }},
        .retain_on_delete = false,
    });
    defer table.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var dataset_absent = try live.readWithContext(&context, dataset.node);
    defer dataset_absent.deinit();
    try std.testing.expect(dataset_absent == .absent);
    var dataset_created = try live.createWithContext(&context, dataset.node);
    defer dataset_created.deinit();
    try std.testing.expectEqualStrings("projects/ziac-dev/datasets/analytics", dataset_created.physical_id);
    try std.testing.expectEqualStrings("etag-d1", outputString(dataset_created, "etag"));
    var dataset_read = try live.readWithContext(&context, dataset.node);
    defer dataset_read.deinit();
    var dataset_diff = try live.diffWithContext(&context, dataset.node, &dataset_read.present);
    defer dataset_diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.noop, dataset_diff.kind);
    var dataset_imported = try live.importWithContext(&context, dataset.node, "ziac-dev:analytics");
    defer dataset_imported.deinit();

    var table_absent = try live.readWithContext(&context, table.node);
    defer table_absent.deinit();
    var table_created = try live.createWithContext(&context, table.node);
    defer table_created.deinit();
    try std.testing.expectEqual(@as(i64, 12), outputInteger(table_created, "num_rows"));
    var table_read = try live.readWithContext(&context, table.node);
    defer table_read.deinit();
    var table_imported = try live.importWithContext(&context, table.node, "ziac-dev:analytics.events");
    defer table_imported.deinit();
    try live.deleteWithContext(&context, table.node, table_imported.physical_id);
    try live.deleteWithContext(&context, dataset.node, dataset_imported.physical_id);

    try std.testing.expectEqualStrings("POST", harness.transport.requests.items[1].method);
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[1].url, "/bigquery/v2/projects/ziac-dev/datasets"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"datasetReference\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[5].url, "/bigquery/v2/projects/ziac-dev/datasets/analytics/tables"));
    try std.testing.expectEqualStrings("DELETE", harness.transport.requests.items[8].method);
}

test "live BigQuery provider updates connections and reservations with field masks" {
    const connection_before = "{\"name\":\"projects/ziac-dev/locations/EU/connections/vertex\",\"friendlyName\":\"Vertex\",\"description\":\"ML access\",\"cloudResource\":{\"serviceAccountId\":\"bqcx-123@gcp-sa-bigquery-condel.iam.gserviceaccount.com\"},\"hasCredential\":false}";
    const connection_after = "{\"name\":\"projects/ziac-dev/locations/EU/connections/vertex\",\"friendlyName\":\"Vertex\",\"description\":\"ML and object access\",\"cloudResource\":{\"serviceAccountId\":\"bqcx-123@gcp-sa-bigquery-condel.iam.gserviceaccount.com\"},\"hasCredential\":false}";
    const reservation_before = "{\"name\":\"projects/ziac-dev/locations/EU/reservations/analytics\",\"slotCapacity\":\"50\",\"maxSlots\":\"100\",\"ignoreIdleSlots\":false,\"edition\":\"ENTERPRISE\"}";
    const reservation_after = "{\"name\":\"projects/ziac-dev/locations/EU/reservations/analytics\",\"slotCapacity\":\"75\",\"maxSlots\":\"100\",\"ignoreIdleSlots\":false,\"edition\":\"ENTERPRISE\"}";
    const responses = [_]zstd.Http.Response{
        ok(connection_before),  ok(connection_after),  ok(connection_after),
        ok(reservation_before), ok(reservation_after), ok(reservation_after),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var connection = try connectionWithDescription("ML access");
    defer connection.deinit(std.testing.allocator);
    var changed_connection = try connectionWithDescription("ML and object access");
    defer changed_connection.deinit(std.testing.allocator);
    var reservation = try reservationWithSlots(50);
    defer reservation.deinit(std.testing.allocator);
    var changed_reservation = try reservationWithSlots(75);
    defer changed_reservation.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var connection_read = try live.readWithContext(&context, connection.node);
    defer connection_read.deinit();
    var connection_diff = try live.diffWithContext(&context, changed_connection.node, &connection_read.present);
    defer connection_diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, connection_diff.kind);
    var connection_updated = try live.updateWithContext(&context, changed_connection.node, &connection_read.present);
    defer connection_updated.deinit();
    var connection_imported = try live.importWithContext(&context, changed_connection.node, connection_updated.physical_id);
    defer connection_imported.deinit();

    var reservation_read = try live.readWithContext(&context, reservation.node);
    defer reservation_read.deinit();
    var reservation_diff = try live.diffWithContext(&context, changed_reservation.node, &reservation_read.present);
    defer reservation_diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, reservation_diff.kind);
    var reservation_updated = try live.updateWithContext(&context, changed_reservation.node, &reservation_read.present);
    defer reservation_updated.deinit();
    var reservation_imported = try live.importWithContext(&context, changed_reservation.node, reservation_updated.physical_id);
    defer reservation_imported.deinit();

    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].url, "updateMask=friendlyName%2Cdescription") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[4].url, "updateMask=slotCapacity%2CmaxSlots%2CignoreIdleSlots%2Cedition%2CsecondaryLocation") != null);
    try std.testing.expect(std.mem.startsWith(u8, harness.transport.requests.items[0].url, "https://connection.example.test/"));
    try std.testing.expect(std.mem.startsWith(u8, harness.transport.requests.items[3].url, "https://reservation.example.test/"));
}

test "live BigQuery provider uses contract-specific verbs and etag preconditions" {
    const dataset_before = "{\"etag\":\"etag-d1\",\"datasetReference\":{\"datasetId\":\"analytics\",\"projectId\":\"ziac-dev\"},\"friendlyName\":\"Analytics\",\"location\":\"EU\"}";
    const dataset_after = "{\"etag\":\"etag-d2\",\"datasetReference\":{\"datasetId\":\"analytics\",\"projectId\":\"ziac-dev\"},\"friendlyName\":\"Analytics warehouse\",\"location\":\"EU\"}";
    const routine_before = "{\"etag\":\"etag-r1\",\"routineReference\":{\"projectId\":\"ziac-dev\",\"datasetId\":\"analytics\",\"routineId\":\"normalize\"},\"routineType\":\"SCALAR_FUNCTION\",\"language\":\"SQL\",\"arguments\":[],\"returnType\":{\"typeKind\":\"STRING\"},\"definitionBody\":\"LOWER('A')\",\"determinismLevel\":\"DETERMINISTIC\"}";
    const routine_after = "{\"etag\":\"etag-r2\",\"routineReference\":{\"projectId\":\"ziac-dev\",\"datasetId\":\"analytics\",\"routineId\":\"normalize\"},\"routineType\":\"SCALAR_FUNCTION\",\"language\":\"SQL\",\"arguments\":[],\"returnType\":{\"typeKind\":\"STRING\"},\"definitionBody\":\"LOWER('B')\",\"determinismLevel\":\"DETERMINISTIC\"}";
    const responses = [_]zstd.Http.Response{ ok(dataset_before), ok(dataset_after), ok(routine_before), ok(routine_after) };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var dataset = try datasetWithName("Analytics");
    defer dataset.deinit(std.testing.allocator);
    var changed_dataset = try datasetWithName("Analytics warehouse");
    defer changed_dataset.deinit(std.testing.allocator);
    var routine = try routineWithBody("LOWER('A')");
    defer routine.deinit(std.testing.allocator);
    var changed_routine = try routineWithBody("LOWER('B')");
    defer changed_routine.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var dataset_read = try live.readWithContext(&context, dataset.node);
    defer dataset_read.deinit();
    var dataset_updated = try live.updateWithContext(&context, changed_dataset.node, &dataset_read.present);
    defer dataset_updated.deinit();
    var routine_read = try live.readWithContext(&context, routine.node);
    defer routine_read.deinit();
    var routine_updated = try live.updateWithContext(&context, changed_routine.node, &routine_read.present);
    defer routine_updated.deinit();

    try std.testing.expectEqualStrings("PATCH", harness.transport.requests.items[1].method);
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[1].url, "?updateMode=UPDATE_METADATA"));
    try std.testing.expectEqualStrings("etag-d1", harness.transport.requests.items[1].if_match.?);
    try std.testing.expectEqualStrings("PUT", harness.transport.requests.items[3].method);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].url, "updateMask") == null);
    try std.testing.expectEqualStrings("etag-r1", harness.transport.requests.items[3].if_match.?);
}

test "live BigQuery provider preserves unrelated IAM members" {
    const before = "{\"version\":3,\"etag\":\"BwA=\",\"bindings\":[{\"role\":\"roles/bigquery.dataViewer\",\"members\":[\"user:owner@example.com\"]}]}";
    const after = "{\"version\":3,\"etag\":\"BwB=\",\"bindings\":[{\"role\":\"roles/bigquery.dataViewer\",\"members\":[\"user:owner@example.com\",\"group:analytics@example.com\"]}]}";
    const responses = [_]zstd.Http.Response{ ok(before), ok(after), ok(after), ok(after), ok(before) };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var member = try ziac.gcp.bigquery.DatasetIamMember.build(std.testing.allocator, config(), .{
        .name = "analytics-readers",
        .dataset = .{ .value = "projects/ziac-dev/datasets/analytics" },
        .dataset_id = "analytics",
        .role = "roles/bigquery.dataViewer",
        .member = "group:analytics@example.com",
    });
    defer member.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try live.createWithContext(&context, member.node);
    defer created.deinit();
    var read = try live.readWithContext(&context, member.node);
    defer read.deinit();
    try std.testing.expect(read == .present);
    try live.deleteWithContext(&context, member.node, created.physical_id);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "owner@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[4].body, "analytics@example.com") == null);
}

const Harness = struct {
    token_source: FixedTokenSource,
    cache: auth.TokenCache,
    transport: @import("gcp_client_test.zig").RecordingTransport,
    client: gclient.Client,
    live: ziac.gcp.live_provider.LiveProvider,

    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.token_source = .{};
        self.cache = auth.TokenCache.init(self.token_source.tokenSource(), 300);
        self.transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{
            .bigquery = "https://bigquery.example.test",
            .bigquery_connection = "https://connection.example.test",
            .bigquery_reservation = "https://reservation.example.test",
        });
        self.live = ziac.gcp.live_provider.LiveProvider.init(&self.client);
    }

    fn deinit(self: *Harness) void {
        self.transport.deinit();
        self.cache.deinit(std.testing.allocator);
        self.* = undefined;
    }
};

const FixedTokenSource = struct {
    fn tokenSource(self: *FixedTokenSource) auth.TokenSource {
        return .{ .ptr = self, .fetchFn = fetch };
    }

    fn fetch(_: *anyopaque, allocator: std.mem.Allocator, now_seconds: u64) auth.AuthError!auth.AccessToken {
        return auth.AccessToken.initOwned(allocator, .{
            .access_token = "dummy-google-token",
            .token_type = "Bearer",
            .expires_at_seconds = now_seconds + 3_600,
        });
    }
};

fn connectionWithDescription(description: []const u8) !ziac.gcp.bigquery.Connection {
    return ziac.gcp.bigquery.Connection.build(std.testing.allocator, config(), .{
        .connection_id = "vertex",
        .location = "EU",
        .kind = .cloud_resource,
        .friendly_name = "Vertex",
        .description = description,
        .retain_on_delete = false,
    });
}

fn datasetWithName(friendly_name: []const u8) !ziac.gcp.bigquery.Dataset {
    return ziac.gcp.bigquery.Dataset.build(std.testing.allocator, config(), .{
        .dataset_id = "analytics",
        .location = "EU",
        .friendly_name = friendly_name,
        .retain_on_delete = false,
    });
}

fn routineWithBody(definition_body: []const u8) !ziac.gcp.bigquery.Routine {
    return ziac.gcp.bigquery.Routine.build(std.testing.allocator, config(), .{
        .dataset = .{ .value = "projects/ziac-dev/datasets/analytics" },
        .dataset_id = "analytics",
        .routine_id = "normalize",
        .routine_type = .scalar_function,
        .language = .sql,
        .return_type_json = "{\"typeKind\":\"STRING\"}",
        .definition_body = definition_body,
        .deterministic = true,
        .retain_on_delete = false,
    });
}

fn reservationWithSlots(slots: u64) !ziac.gcp.bigquery.Reservation {
    return ziac.gcp.bigquery.Reservation.build(std.testing.allocator, config(), .{
        .reservation_id = "analytics",
        .location = "EU",
        .slot_capacity = slots,
        .max_slots = 100,
        .edition = .enterprise,
        .retain_on_delete = false,
    });
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
}

fn outputString(result: ziac.provider.ResourceResult, name: []const u8) []const u8 {
    for (result.outputs) |entry| if (std.mem.eql(u8, entry.name, name)) return switch (entry.value) {
        .string => |text| text,
        else => unreachable,
    };
    unreachable;
}

fn outputInteger(result: ziac.provider.ResourceResult, name: []const u8) i64 {
    for (result.outputs) |entry| if (std.mem.eql(u8, entry.name, name)) return switch (entry.value) {
        .integer => |number| number,
        else => unreachable,
    };
    unreachable;
}

fn ok(body: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = body };
}

fn notFound() zstd.Http.Response {
    return .{ .status = 404, .body = "{\"error\":{\"code\":404,\"status\":\"NOT_FOUND\",\"message\":\"missing\"}}" };
}
