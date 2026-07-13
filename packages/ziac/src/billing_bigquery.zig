const std = @import("std");
const billing_worker = @import("billing_worker.zig");
const cost = @import("cost.zig");
const gcp_billing = @import("gcp/billing.zig");

pub const Reader = struct {
    adapter: *gcp_billing.Adapter,
    max_pages: usize = 256,

    pub fn reader(self: *Reader) billing_worker.Reader {
        return .{ .ptr = self, .read_fn = read };
    }

    fn read(raw: *anyopaque, allocator: std.mem.Allocator, config: billing_worker.Config) !billing_worker.OwnedRows {
        const self: *Reader = @ptrCast(@alignCast(raw));
        const query = try cost.detailedBillingQueryAlloc(allocator, config.export_table, config.resource_project);
        defer allocator.free(query);
        var page = try self.adapter.queryAlloc(config.billing_project, query);
        defer page.deinit();
        var rows = std.ArrayList(cost.BillingRow).empty;
        errdefer deinitRows(allocator, &rows);
        var pages: usize = 0;
        while (true) {
            pages += 1;
            if (pages > self.max_pages) return error.BillingPaginationLimit;
            try appendRows(allocator, &rows, page.rows);
            if (page.complete and page.next_page_token == null) break;
            const project_id = try allocator.dupe(u8, page.project_id);
            defer allocator.free(project_id);
            const job_id = try allocator.dupe(u8, page.job_id);
            defer allocator.free(job_id);
            const location = if (page.location) |value| try allocator.dupe(u8, value) else null;
            defer if (location) |value| allocator.free(value);
            const token = if (page.next_page_token) |value| try allocator.dupe(u8, value) else null;
            defer if (token) |value| allocator.free(value);
            page.deinit();
            page = try self.adapter.resultsPageAlloc(project_id, job_id, location, token);
        }
        return .{ .allocator = allocator, .rows = try rows.toOwnedSlice(allocator) };
    }
};

fn appendRows(allocator: std.mem.Allocator, output: *std.ArrayList(cost.BillingRow), rows: []const cost.BillingRow) !void {
    for (rows) |row| {
        const resource_id = try allocator.dupe(u8, row.resource_id);
        errdefer allocator.free(resource_id);
        try output.append(allocator, .{
            .resource_id = resource_id,
            .cost_micros = row.cost_micros,
            .credit_micros = row.credit_micros,
        });
    }
}

fn deinitRows(allocator: std.mem.Allocator, rows: *std.ArrayList(cost.BillingRow)) void {
    for (rows.items) |row| allocator.free(row.resource_id);
    rows.deinit(allocator);
}
