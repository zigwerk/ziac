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

test "Cloud Storage estimates keep capacity operations and egress assumptions explicit" {
    const prices = [_]ziac.cost.SkuPrice{
        .{ .sku_id = "storage-nearline", .region = "europe-west1", .unit = "GiBy.mo", .unit_quantity = 1, .unit_price_micros = 20 },
        .{ .sku_id = "storage-class-a", .region = "europe-west1", .unit = "1k requests", .unit_quantity = 1000, .unit_price_micros = 5_000 },
        .{ .sku_id = "storage-egress", .region = "europe-west1", .unit = "GiBy", .unit_quantity = 1, .unit_price_micros = 120_000 },
    };
    const estimate = try ziac.cost.storageConfigurationEstimate(&prices, .{
        .resource_id = "gcp.storage.Bucket.ziac-assets",
        .region = "europe-west1",
        .storage_sku_id = "storage-nearline",
        .operations_sku_id = "storage-class-a",
        .egress_sku_id = "storage-egress",
        .stored_gib_month = 100,
        .operations = 2_000,
        .egress_gib = 10,
        .observed_at_millis = 1_000,
    });
    try std.testing.expectEqual(@as(?i64, 1_212_000), estimate.amount_micros);
    try std.testing.expectEqual(ziac.cost.Origin.configuration_estimate, estimate.origin);
    try std.testing.expect(estimate.provenance.is_catalog_price);
}

test "Pub/Sub estimates keep throughput retention and transfer assumptions explicit" {
    const prices = [_]ziac.cost.SkuPrice{
        .{ .sku_id = "pubsub-throughput", .region = "global", .unit = "GiBy", .unit_quantity = 1, .unit_price_micros = 40_000 },
        .{ .sku_id = "pubsub-retained", .region = "global", .unit = "GiBy.mo", .unit_quantity = 1, .unit_price_micros = 27_000 },
        .{ .sku_id = "pubsub-transfer", .region = "global", .unit = "GiBy", .unit_quantity = 1, .unit_price_micros = 120_000 },
    };
    const estimate = try ziac.cost.pubsubConfigurationEstimate(&prices, .{
        .resource_id = "gcp.pubsub.Subscription.orders-worker",
        .region = "global",
        .throughput_sku_id = "pubsub-throughput",
        .storage_sku_id = "pubsub-retained",
        .egress_sku_id = "pubsub-transfer",
        .throughput_gib = 100,
        .retained_gib_month = 20,
        .egress_gib = 10,
        .observed_at_millis = 1_000,
    });
    try std.testing.expectEqual(@as(?i64, 5_740_000), estimate.amount_micros);
    try std.testing.expectEqual(ziac.cost.Origin.configuration_estimate, estimate.origin);
    try std.testing.expect(estimate.provenance.is_catalog_price);
}

test "Cloud Tasks estimates separate billable operations from network transfer" {
    const prices = [_]ziac.cost.SkuPrice{
        .{ .sku_id = "tasks-operations", .region = "global", .unit = "operation", .unit_quantity = 1_000_000, .unit_price_micros = 400_000 },
        .{ .sku_id = "tasks-egress", .region = "europe-west1", .unit = "GiBy", .unit_quantity = 1, .unit_price_micros = 120_000 },
    };
    const estimate = try ziac.cost.tasksConfigurationEstimate(&prices, .{
        .resource_id = "gcp.tasks.Queue.europe-west1.invoice-worker",
        .region = "europe-west1",
        .operations_sku_id = "tasks-operations",
        .egress_sku_id = "tasks-egress",
        .billable_operations = 2_500_000,
        .egress_gib = 4,
        .observed_at_millis = 1_000,
    });
    try std.testing.expectEqual(@as(?i64, 1_480_000), estimate.amount_micros);
    try std.testing.expectEqual(ziac.cost.Origin.configuration_estimate, estimate.origin);
}

test "Eventarc estimates separate chargeable events from Pub/Sub transport" {
    const prices = [_]ziac.cost.SkuPrice{
        .{ .sku_id = "eventarc-events", .region = "global", .unit = "event", .unit_quantity = 1_000_000, .unit_price_micros = 1_000_000 },
        .{ .sku_id = "pubsub-throughput", .region = "global", .unit = "GiBy", .unit_quantity = 1, .unit_price_micros = 40_000 },
    };
    const estimate = try ziac.cost.eventarcConfigurationEstimate(&prices, .{
        .resource_id = "gcp.eventarc.Trigger.europe-west1.orders-created",
        .region = "global",
        .events_sku_id = "eventarc-events",
        .transport_sku_id = "pubsub-throughput",
        .chargeable_events = 2_000_000,
        .transport_gib = 10,
        .observed_at_millis = 1_000,
    });
    try std.testing.expectEqual(@as(?i64, 2_400_000), estimate.amount_micros);
    try std.testing.expectEqual(ziac.cost.Origin.configuration_estimate, estimate.origin);
}

test "Cloud Run Job estimates derive bounded compute usage from execution assumptions" {
    const prices = [_]ziac.cost.SkuPrice{
        .{ .sku_id = "run-job-cpu", .region = "europe-west1", .unit = "vCPU-second", .unit_quantity = 1, .unit_price_micros = 24 },
        .{ .sku_id = "run-job-memory", .region = "europe-west1", .unit = "GiB-second", .unit_quantity = 1, .unit_price_micros = 3 },
    };
    const estimate = try ziac.cost.cloudRunJobConfigurationEstimate(&prices, .{
        .resource_id = "gcp.run.Job.europe-west1.nightly-report",
        .region = "europe-west1",
        .cpu_sku_id = "run-job-cpu",
        .memory_sku_id = "run-job-memory",
        .task_count = 10,
        .executions_per_month = 30,
        .average_task_seconds = 60,
        .vcpu_per_task = 2,
        .memory_gib_per_task = 4,
        .observed_at_millis = 1_000,
    });
    try std.testing.expectEqual(@as(?i64, 1_080_000), estimate.amount_micros);
    try std.testing.expectEqual(ziac.cost.Origin.configuration_estimate, estimate.origin);
    try std.testing.expectEqual(ziac.cost.Confidence.explicit_usage, estimate.confidence);
}

test "Cloud Run Worker Pool estimates derive always-on capacity without inventing utilization" {
    const prices = [_]ziac.cost.SkuPrice{
        .{ .sku_id = "run-worker-cpu", .region = "europe-west1", .unit = "vCPU-second", .unit_quantity = 1, .unit_price_micros = 20 },
        .{ .sku_id = "run-worker-memory", .region = "europe-west1", .unit = "GiB-second", .unit_quantity = 1, .unit_price_micros = 2 },
    };
    const estimate = try ziac.cost.cloudRunWorkerPoolConfigurationEstimate(&prices, .{
        .resource_id = "gcp.run.WorkerPool.europe-west1.events",
        .region = "europe-west1",
        .cpu_sku_id = "run-worker-cpu",
        .memory_sku_id = "run-worker-memory",
        .instance_count = 3,
        .active_seconds_per_instance = 2_592_000,
        .vcpu_per_instance = 2,
        .memory_gib_per_instance = 4,
        .observed_at_millis = 1_000,
    });
    try std.testing.expectEqual(@as(?i64, 373_248_000), estimate.amount_micros);
    try std.testing.expectEqual(ziac.cost.Origin.configuration_estimate, estimate.origin);
    try std.testing.expectError(error.InvalidUsageAssumption, ziac.cost.cloudRunWorkerPoolConfigurationEstimate(&prices, .{
        .resource_id = "gcp.run.WorkerPool.europe-west1.events",
        .region = "europe-west1",
        .cpu_sku_id = "run-worker-cpu",
        .memory_sku_id = "run-worker-memory",
        .instance_count = 0,
        .active_seconds_per_instance = 2_592_000,
        .vcpu_per_instance = 2,
        .memory_gib_per_instance = 4,
        .observed_at_millis = 1_000,
    }));
}

test "Cloud Billing adapters parse catalog prices and normalized detailed export rows" {
    var catalog = try ziac.cost.parseCatalogPageAlloc(std.testing.allocator, "{\"skus\":[{\"skuId\":\"run-cpu\",\"serviceRegions\":[\"europe-west1\"],\"pricingInfo\":[{\"pricingExpression\":{\"usageUnit\":\"vCPU-second\",\"baseUnitConversionFactor\":1,\"tieredRates\":[{\"unitPrice\":{\"units\":\"0\",\"nanos\":24000}}]}}]}],\"nextPageToken\":\"next-1\"}");
    defer catalog.deinit();
    try std.testing.expectEqual(@as(usize, 1), catalog.prices.len);
    try std.testing.expectEqual(@as(i64, 24), catalog.prices[0].unit_price_micros);
    try std.testing.expectEqualStrings("next-1", catalog.next_page_token.?);

    const query = try ziac.cost.detailedBillingQueryAlloc(std.testing.allocator, "billing-project.normalized.detailed_cost", "acme-prod");
    defer std.testing.allocator.free(query);
    try std.testing.expect(std.mem.indexOf(u8, query, "resource.global_name") != null);
    try std.testing.expect(std.mem.indexOf(u8, query, "cost_micros") != null);
    try std.testing.expect(std.mem.indexOf(u8, query, "credit_micros") != null);
}

test "security foundation estimates separate priced CA usage from no-charge admission policy" {
    const prices = [_]ziac.cost.SkuPrice{
        .{ .sku_id = "private-ca-enterprise", .region = "europe-west1", .unit = "ca-month", .unit_quantity = 1, .unit_price_micros = 100_000_000 },
        .{ .sku_id = "private-ca-certificate", .region = "europe-west1", .unit = "certificate", .unit_quantity = 1, .unit_price_micros = 300_000 },
    };
    const estimate = try ziac.cost.securityFoundationConfigurationEstimate(&prices, .{
        .resource_id = "gcp.privateca.CaPool.europe-west1.application-trust",
        .region = "europe-west1",
        .private_ca_enterprise_sku_id = "private-ca-enterprise",
        .private_ca_certificate_sku_id = "private-ca-certificate",
        .active_enterprise_ca_months = 1,
        .issued_certificates = 10,
        .observed_at_millis = 1_000,
    });
    try std.testing.expectEqual(@as(?i64, 103_000_000), estimate.amount_micros);
    try std.testing.expectEqual(ziac.cost.Origin.configuration_estimate, estimate.origin);

    const admission = try ziac.cost.binaryAuthorizationConfigurationEstimate(
        "gcp.binaryauthorization.Policy.global.application-images",
        1_000,
    );
    try std.testing.expectEqual(@as(?i64, 0), admission.amount_micros);
    try std.testing.expectEqual(ziac.cost.Confidence.explicit_usage, admission.confidence);
}
