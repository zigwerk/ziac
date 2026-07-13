const std = @import("std");
const billing_worker = @import("billing_worker.zig");
const cost = @import("cost.zig");
const estate_cockroach = @import("estate_cockroach.zig");

pub const Repository = struct {
    allocator: std.mem.Allocator,
    database: estate_cockroach.Database,

    pub fn init(allocator: std.mem.Allocator, database: estate_cockroach.Database) Repository {
        return .{ .allocator = allocator, .database = database };
    }

    pub fn store(self: *Repository) billing_worker.Store {
        return .{ .ptr = self, .persist_fn = persist };
    }

    fn persist(raw: *anyopaque, config: billing_worker.Config, result: *const cost.AttributionResult) !void {
        const self: *Repository = @ptrCast(@alignCast(raw));
        const owner = try literalAlloc(self.allocator, config.resource_project);
        defer self.allocator.free(owner);
        const billing_project = try literalAlloc(self.allocator, config.billing_project);
        defer self.allocator.free(billing_project);
        const export_table = try literalAlloc(self.allocator, config.export_table);
        defer self.allocator.free(export_table);
        const currency = try literalAlloc(self.allocator, config.currency);
        defer self.allocator.free(currency);
        const source_statement = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO ziac_billing_sources (source_kind, owner_project_id, billing_project_id, export_table, currency) VALUES ('self_host', {s}, {s}, {s}, {s}) ON CONFLICT (owner_project_id, export_table) DO UPDATE SET billing_project_id = excluded.billing_project_id, currency = excluded.currency, enabled = true RETURNING source_id::STRING",
            .{ owner, billing_project, export_table, currency },
        );
        defer self.allocator.free(source_statement);
        const source_id = (try self.database.query_json_fn(self.database.ptr, self.allocator, source_statement)) orelse return error.BillingSourceUnavailable;
        defer self.allocator.free(source_id);
        const source = try literalAlloc(self.allocator, source_id);
        defer self.allocator.free(source);
        const run_statement = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO ziac_billing_ingestion_runs (source_id, window_start, window_end, status) VALUES ({s}::UUID, to_timestamp({d} / 1000.0), to_timestamp({d} / 1000.0), 'running') ON CONFLICT (source_id, window_start, window_end) DO UPDATE SET status = 'running', error_code = NULL, started_at = now(), completed_at = NULL RETURNING run_id::STRING",
            .{ source, config.window_start_millis, config.window_end_millis },
        );
        defer self.allocator.free(run_statement);
        const run_id = (try self.database.query_json_fn(self.database.ptr, self.allocator, run_statement)) orelse return error.BillingRunUnavailable;
        defer self.allocator.free(run_id);
        const run = try literalAlloc(self.allocator, run_id);
        defer self.allocator.free(run);
        const clear_statement = try std.fmt.allocPrint(self.allocator, "DELETE FROM ziac_billing_resource_costs WHERE run_id = {s}::UUID", .{run});
        defer self.allocator.free(clear_statement);
        _ = try self.database.execute_fn(self.database.ptr, clear_statement);
        for (result.costs) |resource_cost| {
            const resource_id = try literalAlloc(self.allocator, resource_cost.resource_id);
            defer self.allocator.free(resource_id);
            const resource_currency = try literalAlloc(self.allocator, resource_cost.currency);
            defer self.allocator.free(resource_currency);
            const statement = try std.fmt.allocPrint(
                self.allocator,
                "INSERT INTO ziac_billing_resource_costs (run_id, resource_id, google_global_name, amount_micros, currency, attribution, observed_at) VALUES ({s}::UUID, {s}, {s}, {d}, {s}, 'global_name', to_timestamp({d} / 1000.0))",
                .{ run, resource_id, resource_id, resource_cost.amount_micros orelse 0, resource_currency, result.observed_at_millis },
            );
            defer self.allocator.free(statement);
            _ = try self.database.execute_fn(self.database.ptr, statement);
        }
        const complete_statement = try std.fmt.allocPrint(
            self.allocator,
            "UPDATE ziac_billing_ingestion_runs SET status = 'complete', billed_total_micros = {d}, attributed_total_micros = {d}, unattributed_total_micros = {d}, coverage_basis_points = {d}, completed_at = now() WHERE run_id = {s}::UUID",
            .{ result.billed_total_micros, result.attributed_total_micros, result.unattributed_total_micros, result.coverage_basis_points, run },
        );
        defer self.allocator.free(complete_statement);
        if (try self.database.execute_fn(self.database.ptr, complete_statement) != 1) return error.BillingRunUnavailable;
    }
};

fn literalAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    if (input.len == 0 or input.len > 4096 or std.mem.indexOfAny(u8, input, "\x00\r\n") != null) return error.InvalidBillingValue;
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.append(allocator, '\'');
    for (input) |byte| {
        if (byte == '\'') try output.append(allocator, '\'');
        try output.append(allocator, byte);
    }
    try output.append(allocator, '\'');
    return output.toOwnedSlice(allocator);
}
