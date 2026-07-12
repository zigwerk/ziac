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
