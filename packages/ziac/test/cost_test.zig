const std = @import("std");
const ziac = @import("ziac");

test "cost intelligence keeps estimates actuals and projections semantically distinct" {
    const skus = [_]ziac.cost.SkuPrice{
        .{ .sku_id = "run-cpu", .region = "europe-west1", .unit = "vCPU-second", .unit_quantity = 1, .unit_price_micros = 24 },
        .{ .sku_id = "run-memory", .region = "europe-west1", .unit = "GiB-second", .unit_quantity = 1, .unit_price_micros = 3 },
    };
    const usage = [_]ziac.cost.UsageAssumption{
        .{ .sku_id = "run-cpu", .region = "europe-west1", .quantity = 1_000_000 },
        .{ .sku_id = "run-memory", .region = "europe-west1", .quantity = 2_000_000 },
    };
    const estimate = try ziac.cost.configurationEstimate("gcp.run.Service.api", &skus, &usage, 1_000);
    try std.testing.expectEqual(ziac.cost.Origin.configuration_estimate, estimate.origin);
    try std.testing.expectEqual(@as(i64, 30_000_000), estimate.amount_micros.?);
    try std.testing.expectEqual(ziac.cost.Confidence.explicit_usage, estimate.confidence);

    const rows = [_]ziac.cost.BillingRow{
        .{ .resource_id = "gcp.run.Service.api", .cost_micros = 12_000_000, .credit_micros = -2_000_000 },
        .{ .resource_id = "gcp.run.Service.api", .cost_micros = 3_000_000, .credit_micros = 0 },
    };
    const actual = try ziac.cost.actualBilled("gcp.run.Service.api", &rows, 2_000);
    try std.testing.expectEqual(ziac.cost.Origin.actual_billed, actual.origin);
    try std.testing.expectEqual(@as(i64, 13_000_000), actual.amount_micros.?);

    const projected = try ziac.cost.projectMonthEnd(actual, 10, 30, 2_000);
    try std.testing.expectEqual(ziac.cost.Origin.projected_month_end, projected.origin);
    try std.testing.expectEqual(@as(i64, 39_000_000), projected.amount_micros.?);
    try std.testing.expect(projected.provenance.is_billing_export);
}

test "cost intelligence reports unavailable instead of inventing missing usage" {
    const result = ziac.cost.configurationEstimate("gcp.run.Service.api", &.{}, &.{}, 1_000) catch |err| switch (err) {
        error.PricingUnavailable => return,
        else => return err,
    };
    _ = result;
    return error.ExpectedUnavailable;
}
