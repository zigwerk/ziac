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
    currency: []const u8 = "USD",
    effective_time: ?[]const u8 = null,
    tiers: []const TierRate = &.{},
};

pub const TierRate = struct {
    start_quantity: u64,
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

pub const AttributionTarget = struct {
    ziac_resource_id: []const u8,
    global_name: []const u8,
};

pub const AttributionResult = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    costs: []ResourceCost,
    currency: []const u8,
    billed_total_micros: i64,
    attributed_total_micros: i64,
    unattributed_total_micros: i64,
    coverage_basis_points: u16,
    observed_at_millis: u64,

    pub fn deinit(self: *AttributionResult) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.* = undefined;
    }
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
        const unit_quantity = jsonU64(expression.get("baseUnitConversionFactor")) orelse 1;
        const rates = jsonArray(expression.get("tieredRates")) orelse return error.InvalidCatalogResponse;
        if (rates.items.len == 0) continue;
        const tiers = try a.alloc(TierRate, rates.items.len);
        var currency: []const u8 = "USD";
        for (rates.items, 0..) |rate_value, rate_index| {
            const rate = jsonObject(rate_value) orelse return error.InvalidCatalogResponse;
            const money = jsonObject(rate.get("unitPrice") orelse return error.InvalidCatalogResponse) orelse return error.InvalidCatalogResponse;
            const units_text = jsonString(money.get("units")) orelse "0";
            const units = std.fmt.parseInt(i64, units_text, 10) catch return error.InvalidCatalogResponse;
            const nanos = jsonI64(money.get("nanos")) orelse 0;
            const micros = std.math.mul(i64, units, 1_000_000) catch return error.CostOverflow;
            currency = jsonString(money.get("currencyCode")) orelse currency;
            tiers[rate_index] = .{
                .start_quantity = jsonU64(rate.get("startUsageAmount")) orelse 0,
                .unit_price_micros = micros + @divTrunc(nanos, 1000),
            };
        }
        if (regions.items.len == 0) {
            try prices.append(a, .{
                .sku_id = try a.dupe(u8, sku_id),
                .region = try a.dupe(u8, "global"),
                .unit = try a.dupe(u8, unit),
                .unit_quantity = unit_quantity,
                .unit_price_micros = tiers[0].unit_price_micros,
                .currency = try a.dupe(u8, currency),
                .effective_time = if (jsonString(info.get("effectiveTime"))) |time| try a.dupe(u8, time) else null,
                .tiers = tiers,
            });
        } else for (regions.items) |region_value| {
            const region = switch (region_value) {
                .string => |text| text,
                else => return error.InvalidCatalogResponse,
            };
            try prices.append(a, .{
                .sku_id = try a.dupe(u8, sku_id),
                .region = try a.dupe(u8, region),
                .unit = try a.dupe(u8, unit),
                .unit_quantity = unit_quantity,
                .unit_price_micros = tiers[0].unit_price_micros,
                .currency = try a.dupe(u8, currency),
                .effective_time = if (jsonString(info.get("effectiveTime"))) |time| try a.dupe(u8, time) else null,
                .tiers = tiers,
            });
        }
    }
    const token = if (jsonString(root.get("nextPageToken"))) |value| try a.dupe(u8, value) else null;
    return .{ .allocator = allocator, .arena = arena, .prices = try prices.toOwnedSlice(a), .next_page_token = token };
}

pub fn detailedBillingQueryAlloc(allocator: std.mem.Allocator, normalized_view: []const u8, project_id: []const u8) ![]u8 {
    if (!validSqlIdentity(normalized_view) or !validProjectId(project_id)) return error.InvalidBillingQuery;
    return std.fmt.allocPrint(
        allocator,
        "WITH normalized AS (SELECT COALESCE(resource.global_name, CONCAT('//unattributed.googleapis.com/projects/', project.id, '/skus/', sku.id)) AS resource_id, cost, IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0) AS credits FROM `{s}` WHERE project.id = '{s}' AND usage_start_time >= TIMESTAMP_TRUNC(CURRENT_TIMESTAMP(), MONTH)) SELECT resource_id, CAST(ROUND(SUM(cost) * 1000000) AS INT64) AS cost_micros, CAST(ROUND(SUM(credits) * 1000000) AS INT64) AS credit_micros FROM normalized GROUP BY resource_id ORDER BY resource_id",
        .{ normalized_view, project_id },
    );
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
        total += if (price.tiers.len == 0)
            @divTrunc(@as(i128, @intCast(assumption.quantity)) * price.unit_price_micros, price.unit_quantity)
        else
            try tieredCost(price, assumption.quantity);
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

pub fn attributeActualAlloc(
    allocator: std.mem.Allocator,
    rows: []const BillingRow,
    targets: []const AttributionTarget,
    currency: []const u8,
    observed_at_millis: u64,
) !AttributionResult {
    if (currency.len != 3 or observed_at_millis == 0) return error.InvalidCostIdentity;
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var billed: i128 = 0;
    for (rows) |row| billed += @as(i128, row.cost_micros) + row.credit_micros;
    var costs = std.ArrayList(ResourceCost).empty;
    var attributed: i128 = 0;
    for (targets) |target| {
        try validateIdentity(target.ziac_resource_id, observed_at_millis);
        var matched = false;
        var amount: i128 = 0;
        for (rows) |row| if (std.mem.eql(u8, row.resource_id, target.global_name)) {
            matched = true;
            amount += @as(i128, row.cost_micros) + row.credit_micros;
        };
        if (!matched) continue;
        const cast_amount = std.math.cast(i64, amount) orelse return error.CostOverflow;
        attributed += amount;
        try costs.append(a, .{
            .resource_id = try a.dupe(u8, target.ziac_resource_id),
            .origin = .actual_billed,
            .currency = try a.dupe(u8, currency),
            .amount_micros = cast_amount,
            .confidence = .billing_complete,
            .provenance = .{ .is_billing_export = true, .includes_credits = true, .observed_at_millis = observed_at_millis },
        });
    }
    const billed_i64 = std.math.cast(i64, billed) orelse return error.CostOverflow;
    const attributed_i64 = std.math.cast(i64, attributed) orelse return error.CostOverflow;
    const coverage: u16 = if (billed == 0)
        0
    else
        @intCast(@min(@as(i128, 10_000), @divTrunc(@abs(attributed) * 10_000, @abs(billed))));
    return .{
        .allocator = allocator,
        .arena = arena,
        .costs = try costs.toOwnedSlice(a),
        .currency = try a.dupe(u8, currency),
        .billed_total_micros = billed_i64,
        .attributed_total_micros = attributed_i64,
        .unattributed_total_micros = std.math.sub(i64, billed_i64, attributed_i64) catch return error.CostOverflow,
        .coverage_basis_points = coverage,
        .observed_at_millis = observed_at_millis,
    };
}

fn tieredCost(price: SkuPrice, quantity: u64) !i128 {
    var total: i128 = 0;
    for (price.tiers, 0..) |tier, index| {
        if (quantity <= tier.start_quantity) break;
        const next = if (index + 1 < price.tiers.len) price.tiers[index + 1].start_quantity else quantity;
        const upper = @min(quantity, next);
        const tier_quantity = upper - tier.start_quantity;
        total += @divTrunc(@as(i128, @intCast(tier_quantity)) * tier.unit_price_micros, price.unit_quantity);
    }
    return total;
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
fn jsonU64(value: ?std.json.Value) ?u64 {
    const present = value orelse return null;
    return switch (present) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        .float => |number| if (number >= 0 and @floor(number) == number and number <= 9_007_199_254_740_991.0) @intFromFloat(number) else null,
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
