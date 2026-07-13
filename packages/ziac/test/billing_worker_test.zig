const std = @import("std");
const ziac = @import("ziac");

test "billing worker ingests authoritative rows and persists exact attribution" {
    var reader = ScriptedReader{};
    var store = RecordingStore{};
    const receipt = try ziac.billing_worker.ingestAlloc(
        std.testing.allocator,
        reader.reader(),
        store.store(),
        .{
            .billing_project = "billing-host",
            .export_table = "billing_export.gcp_billing_export_resource_v1_123",
            .resource_project = "ziac-cloud-prod",
            .currency = "USD",
            .window_start_millis = 1_700_000_000_000,
            .window_end_millis = 1_700_003_600_000,
        },
        &.{},
        1_700_003_600_000,
    );

    try std.testing.expectEqual(@as(i64, 12_000_000), receipt.billed_total_micros);
    try std.testing.expectEqual(@as(i64, 10_000_000), receipt.attributed_total_micros);
    try std.testing.expectEqual(@as(i64, 2_000_000), receipt.unattributed_total_micros);
    try std.testing.expectEqual(@as(u16, 8333), receipt.coverage_basis_points);
    try std.testing.expect(store.persisted);
    try std.testing.expectEqual(@as(usize, 1), store.cost_count);
}

test "Cockroach billing store records source run resources and completion" {
    var database = ScriptedDatabase.init(std.testing.allocator, &.{ "source-1", "run-1" });
    defer database.deinit();
    var repository = ziac.billing_cockroach.Repository.init(std.testing.allocator, database.database());
    var costs = [_]ziac.cost.ResourceCost{.{
        .resource_id = "gcp.run.Service.api",
        .origin = .actual_billed,
        .currency = "USD",
        .amount_micros = 42,
        .confidence = .billing_complete,
        .provenance = .{ .is_billing_export = true, .includes_credits = true, .observed_at_millis = 1_700_003_600_000 },
    }};
    const result = ziac.cost.AttributionResult{
        .allocator = undefined,
        .arena = undefined,
        .costs = &costs,
        .currency = "USD",
        .billed_total_micros = 50,
        .attributed_total_micros = 42,
        .unattributed_total_micros = 8,
        .coverage_basis_points = 8400,
        .observed_at_millis = 1_700_003_600_000,
    };
    try repository.store().persist_fn(repository.store().ptr, .{
        .billing_project = "billing-host",
        .export_table = "billing_export.gcp_billing_export_resource_v1_123",
        .resource_project = "ziac-cloud-prod",
        .currency = "USD",
        .window_start_millis = 1_700_000_000_000,
        .window_end_millis = 1_700_003_600_000,
    }, &result);
    try std.testing.expectEqual(@as(usize, 2), database.queries.items.len);
    try std.testing.expect(database.executed.items.len >= 3);
    try std.testing.expect(std.mem.indexOf(u8, database.queries.items[0], "source_kind") != null);
    try std.testing.expect(std.mem.indexOf(u8, database.executed.items[database.executed.items.len - 1], "status = 'complete'") != null);
}

const ScriptedReader = struct {
    fn reader(self: *ScriptedReader) ziac.billing_worker.Reader {
        return .{ .ptr = self, .read_fn = read };
    }

    fn read(_: *anyopaque, allocator: std.mem.Allocator, _: ziac.billing_worker.Config) anyerror!ziac.billing_worker.OwnedRows {
        return ziac.billing_worker.OwnedRows.cloneAlloc(allocator, &.{
            .{ .resource_id = "//run.googleapis.com/projects/ziac-cloud-prod/locations/europe-west1/services/api", .cost_micros = 11_000_000, .credit_micros = -1_000_000 },
            .{ .resource_id = "//unattributed.googleapis.com/projects/ziac-cloud-prod/skus/network-egress", .cost_micros = 2_000_000, .credit_micros = 0 },
        });
    }
};

const RecordingStore = struct {
    persisted: bool = false,
    cost_count: usize = 0,

    fn store(self: *RecordingStore) ziac.billing_worker.Store {
        return .{ .ptr = self, .persist_fn = persist };
    }

    fn persist(raw: *anyopaque, _: ziac.billing_worker.Config, result: *const ziac.cost.AttributionResult) anyerror!void {
        const self: *RecordingStore = @ptrCast(@alignCast(raw));
        self.persisted = true;
        self.cost_count = result.costs.len;
    }
};

const ScriptedDatabase = struct {
    allocator: std.mem.Allocator,
    responses: []const []const u8,
    cursor: usize = 0,
    queries: std.ArrayList([]u8) = .empty,
    executed: std.ArrayList([]u8) = .empty,

    fn init(allocator: std.mem.Allocator, responses: []const []const u8) ScriptedDatabase {
        return .{ .allocator = allocator, .responses = responses };
    }
    fn deinit(self: *ScriptedDatabase) void {
        for (self.queries.items) |entry| self.allocator.free(entry);
        for (self.executed.items) |entry| self.allocator.free(entry);
        self.queries.deinit(self.allocator);
        self.executed.deinit(self.allocator);
    }
    fn database(self: *ScriptedDatabase) ziac.estate_cockroach.Database {
        return .{ .ptr = self, .query_json_fn = query, .execute_fn = execute };
    }
    fn query(raw: *anyopaque, allocator: std.mem.Allocator, statement: []const u8) anyerror!?[]u8 {
        const self: *ScriptedDatabase = @ptrCast(@alignCast(raw));
        try self.queries.append(self.allocator, try self.allocator.dupe(u8, statement));
        if (self.cursor >= self.responses.len) return null;
        defer self.cursor += 1;
        return @as(?[]u8, try allocator.dupe(u8, self.responses[self.cursor]));
    }
    fn execute(raw: *anyopaque, statement: []const u8) anyerror!u64 {
        const self: *ScriptedDatabase = @ptrCast(@alignCast(raw));
        try self.executed.append(self.allocator, try self.allocator.dupe(u8, statement));
        return 1;
    }
};
