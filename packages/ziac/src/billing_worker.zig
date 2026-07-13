const std = @import("std");
const cost = @import("cost.zig");

pub const Config = struct {
    billing_project: []const u8,
    export_table: []const u8,
    resource_project: []const u8,
    currency: []const u8,
    window_start_millis: u64,
    window_end_millis: u64,
};

pub const OwnedRows = struct {
    allocator: std.mem.Allocator,
    rows: []cost.BillingRow,

    pub fn cloneAlloc(allocator: std.mem.Allocator, source: []const cost.BillingRow) !OwnedRows {
        const rows = try allocator.alloc(cost.BillingRow, source.len);
        errdefer allocator.free(rows);
        var initialized: usize = 0;
        errdefer for (rows[0..initialized]) |row| allocator.free(row.resource_id);
        for (source, 0..) |row, index| {
            rows[index] = .{
                .resource_id = try allocator.dupe(u8, row.resource_id),
                .cost_micros = row.cost_micros,
                .credit_micros = row.credit_micros,
            };
            initialized += 1;
        }
        return .{ .allocator = allocator, .rows = rows };
    }

    pub fn deinit(self: *OwnedRows) void {
        for (self.rows) |row| self.allocator.free(row.resource_id);
        self.allocator.free(self.rows);
        self.* = undefined;
    }
};

pub const Reader = struct {
    ptr: *anyopaque,
    read_fn: *const fn (*anyopaque, std.mem.Allocator, Config) anyerror!OwnedRows,
};

pub const Store = struct {
    ptr: *anyopaque,
    persist_fn: *const fn (*anyopaque, Config, *const cost.AttributionResult) anyerror!void,
};

pub const Receipt = struct {
    billed_total_micros: i64,
    attributed_total_micros: i64,
    unattributed_total_micros: i64,
    coverage_basis_points: u16,
    resource_count: usize,
};

pub fn ingestAlloc(
    allocator: std.mem.Allocator,
    reader: Reader,
    store: Store,
    config: Config,
    declared_targets: []const cost.AttributionTarget,
    observed_at_millis: u64,
) !Receipt {
    try validate(config, observed_at_millis);
    var rows = try reader.read_fn(reader.ptr, allocator, config);
    defer rows.deinit();

    var derived = std.ArrayList(cost.AttributionTarget).empty;
    defer derived.deinit(allocator);
    const targets = if (declared_targets.len > 0) declared_targets else target_block: {
        for (rows.rows) |row| {
            if (std.mem.startsWith(u8, row.resource_id, "//unattributed.googleapis.com/")) continue;
            try derived.append(allocator, .{
                .ziac_resource_id = row.resource_id,
                .global_name = row.resource_id,
            });
        }
        break :target_block derived.items;
    };

    var result = try cost.attributeActualAlloc(allocator, rows.rows, targets, config.currency, observed_at_millis);
    defer result.deinit();
    try store.persist_fn(store.ptr, config, &result);
    return .{
        .billed_total_micros = result.billed_total_micros,
        .attributed_total_micros = result.attributed_total_micros,
        .unattributed_total_micros = result.unattributed_total_micros,
        .coverage_basis_points = result.coverage_basis_points,
        .resource_count = result.costs.len,
    };
}

fn validate(config: Config, observed_at_millis: u64) !void {
    if (config.billing_project.len == 0 or config.export_table.len == 0 or config.resource_project.len == 0 or
        config.currency.len != 3 or config.window_start_millis == 0 or
        config.window_end_millis <= config.window_start_millis or observed_at_millis == 0)
    {
        return error.InvalidBillingWorkerConfig;
    }
    for (config.currency) |byte| if (!std.ascii.isUpper(byte)) return error.InvalidBillingWorkerConfig;
}
