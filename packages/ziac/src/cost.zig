const std = @import("std");

pub const Origin = enum {
    configuration_estimate,
    projected_month_end,
    actual_billed,
};

pub const Confidence = enum {
    explicit_usage,
    billing_partial_month,
    billing_complete,
};

pub const Provenance = struct {
    is_catalog_price: bool = false,
    is_billing_export: bool = false,
    includes_credits: bool = false,
    observed_at_millis: u64,
};

pub const ResourceCost = struct {
    schema: []const u8 = "ziac.resource-cost.v1",
    resource_id: []const u8,
    origin: Origin,
    currency: []const u8 = "USD",
    amount_micros: ?i64,
    confidence: Confidence,
    provenance: Provenance,
};

pub const SkuPrice = struct {
    sku_id: []const u8,
    region: []const u8,
    unit: []const u8,
    unit_quantity: u64,
    unit_price_micros: i64,
};

pub const UsageAssumption = struct {
    sku_id: []const u8,
    region: []const u8,
    quantity: u64,
};

pub const BillingRow = struct {
    resource_id: []const u8,
    cost_micros: i64,
    credit_micros: i64,
};

pub const CatalogPage = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    prices: []SkuPrice,
    next_page_token: ?[]const u8,

    pub fn deinit(self: *CatalogPage) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.* = undefined;
    }
};

pub fn parseCatalogPageAlloc(allocator: std.mem.Allocator, body: []const u8) !CatalogPage {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var parsed = std.json.parseFromSlice(std.json.Value, a, body, .{}) catch return error.InvalidCatalogResponse;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.InvalidCatalogResponse;
    const skus = jsonArray(root.get("skus")) orelse return error.InvalidCatalogResponse;
    var prices = std.ArrayList(SkuPrice).empty;
    for (skus.items) |sku_value| {
        const sku = jsonObject(sku_value) orelse return error.InvalidCatalogResponse;
        const sku_id = jsonString(sku.get("skuId")) orelse return error.InvalidCatalogResponse;
        const regions = jsonArray(sku.get("serviceRegions")) orelse return error.InvalidCatalogResponse;
        const infos = jsonArray(sku.get("pricingInfo")) orelse return error.InvalidCatalogResponse;
        if (infos.items.len == 0) continue;
        const info = jsonObject(infos.items[infos.items.len - 1]) orelse return error.InvalidCatalogResponse;
        const expression = jsonObject(info.get("pricingExpression") orelse return error.InvalidCatalogResponse) orelse return error.InvalidCatalogResponse;
        const unit = jsonString(expression.get("usageUnit")) orelse return error.InvalidCatalogResponse;
        const rates = jsonArray(expression.get("tieredRates")) orelse return error.InvalidCatalogResponse;
        if (rates.items.len == 0) continue;
        const rate = jsonObject(rates.items[0]) orelse return error.InvalidCatalogResponse;
        const money = jsonObject(rate.get("unitPrice") orelse return error.InvalidCatalogResponse) orelse return error.InvalidCatalogResponse;
        const units_text = jsonString(money.get("units")) orelse "0";
        const units = std.fmt.parseInt(i64, units_text, 10) catch return error.InvalidCatalogResponse;
        const nanos = jsonI64(money.get("nanos")) orelse 0;
        const micros = std.math.mul(i64, units, 1_000_000) catch return error.CostOverflow;
        for (regions.items) |region_value| {
            const region = switch (region_value) {
                .string => |text| text,
                else => return error.InvalidCatalogResponse,
            };
            try prices.append(a, .{
                .sku_id = try a.dupe(u8, sku_id),
                .region = try a.dupe(u8, region),
                .unit = try a.dupe(u8, unit),
                .unit_quantity = 1,
                .unit_price_micros = micros + @divTrunc(nanos, 1000),
            });
        }
    }
    const token = if (jsonString(root.get("nextPageToken"))) |value| try a.dupe(u8, value) else null;
    return .{ .allocator = allocator, .arena = arena, .prices = try prices.toOwnedSlice(a), .next_page_token = token };
}

pub fn detailedBillingQueryAlloc(allocator: std.mem.Allocator, normalized_view: []const u8, project_id: []const u8) ![]u8 {
    if (!validSqlIdentity(normalized_view) or !validProjectId(project_id)) return error.InvalidBillingQuery;
    return std.fmt.allocPrint(allocator, "WITH normalized AS (SELECT resource.global_name AS resource_id, cost, IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0) AS credits FROM `{s}` WHERE project.id = '{s}' AND usage_start_time >= TIMESTAMP_TRUNC(CURRENT_TIMESTAMP(), MONTH)) SELECT resource_id, SUM(cost + credits) AS actual_billed FROM normalized GROUP BY resource_id", .{ normalized_view, project_id });
}

pub fn configurationEstimate(
    resource_id: []const u8,
    prices: []const SkuPrice,
    usage: []const UsageAssumption,
    observed_at_millis: u64,
) !ResourceCost {
    try validateIdentity(resource_id, observed_at_millis);
    if (usage.len == 0) return error.PricingUnavailable;
    var total: i128 = 0;
    for (usage) |assumption| {
        const price = findPrice(prices, assumption.sku_id, assumption.region) orelse return error.PricingUnavailable;
        if (price.unit_quantity == 0 or assumption.quantity > std.math.maxInt(i64)) return error.InvalidPricing;
        total += @divTrunc(@as(i128, @intCast(assumption.quantity)) * price.unit_price_micros, price.unit_quantity);
    }
    const amount = std.math.cast(i64, total) orelse return error.CostOverflow;
    return .{
        .resource_id = resource_id,
        .origin = .configuration_estimate,
        .amount_micros = amount,
        .confidence = .explicit_usage,
        .provenance = .{ .is_catalog_price = true, .observed_at_millis = observed_at_millis },
    };
}

pub fn actualBilled(resource_id: []const u8, rows: []const BillingRow, observed_at_millis: u64) !ResourceCost {
    try validateIdentity(resource_id, observed_at_millis);
    var matched = false;
    var total: i128 = 0;
    for (rows) |row| {
        if (!std.mem.eql(u8, row.resource_id, resource_id)) continue;
        matched = true;
        total += @as(i128, row.cost_micros) + row.credit_micros;
    }
    if (!matched) return error.BillingDataUnavailable;
    return .{
        .resource_id = resource_id,
        .origin = .actual_billed,
        .amount_micros = std.math.cast(i64, total) orelse return error.CostOverflow,
        .confidence = .billing_complete,
        .provenance = .{
            .is_billing_export = true,
            .includes_credits = true,
            .observed_at_millis = observed_at_millis,
        },
    };
}

pub fn projectMonthEnd(actual: ResourceCost, elapsed_days: u8, month_days: u8, observed_at_millis: u64) !ResourceCost {
    if (actual.origin != .actual_billed or actual.amount_micros == null or elapsed_days == 0 or month_days < elapsed_days or month_days > 31 or observed_at_millis == 0) {
        return error.InvalidProjection;
    }
    const projected = @divTrunc(@as(i128, actual.amount_micros.?) * month_days, elapsed_days);
    return .{
        .resource_id = actual.resource_id,
        .origin = .projected_month_end,
        .currency = actual.currency,
        .amount_micros = std.math.cast(i64, projected) orelse return error.CostOverflow,
        .confidence = .billing_partial_month,
        .provenance = .{
            .is_billing_export = true,
            .includes_credits = actual.provenance.includes_credits,
            .observed_at_millis = observed_at_millis,
        },
    };
}

fn findPrice(prices: []const SkuPrice, sku_id: []const u8, region: []const u8) ?SkuPrice {
    for (prices) |price| {
        if (std.mem.eql(u8, price.sku_id, sku_id) and std.mem.eql(u8, price.region, region)) return price;
    }
    return null;
}

fn validateIdentity(resource_id: []const u8, observed_at_millis: u64) !void {
    if (resource_id.len == 0 or resource_id.len > 2048 or observed_at_millis == 0 or
        std.mem.indexOfAny(u8, resource_id, "\x00\r\n") != null) return error.InvalidCostIdentity;
}

fn jsonObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}
fn jsonArray(value: ?std.json.Value) ?std.json.Array {
    const present = value orelse return null;
    return switch (present) {
        .array => |array| array,
        else => null,
    };
}
fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const present = value orelse return null;
    return switch (present) {
        .string => |text| text,
        else => null,
    };
}
fn jsonI64(value: ?std.json.Value) ?i64 {
    const present = value orelse return null;
    return switch (present) {
        .integer => |number| number,
        else => null,
    };
}
fn validSqlIdentity(value: []const u8) bool {
    if (value.len < 5 or value.len > 512) return false;
    for (value) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return false;
    return true;
}
fn validProjectId(value: []const u8) bool {
    if (value.len < 6 or value.len > 63 or !std.ascii.isLower(value[0])) return false;
    for (value) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return false;
    return value[value.len - 1] != '-';
}
