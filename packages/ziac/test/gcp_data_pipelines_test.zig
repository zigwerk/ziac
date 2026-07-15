const std = @import("std");
const ziac = @import("ziac");

test "Data Pipelines declarations type recurring Flex Template workloads" {
    var pipeline = try ziac.gcp.data_pipelines.Pipeline.build(std.testing.allocator, config(), .{
        .name = "daily-orders",
        .location = "europe-west1",
        .display_name = "daily_orders",
        .pipeline_type = .batch,
        .workload = .{ .flex_template = .{
            .container_spec_gcs_path = "gs://dataflow-templates/orders/spec.json",
            .parameters = &.{.{ .key = "outputTable", .value = "analytics.orders" }},
            .environment = .{
                .service_account_email = "dataflow@analytics-prod.iam.gserviceaccount.com",
                .temp_location = "gs://analytics-temp/dataflow",
                .subnetwork = "regions/europe-west1/subnetworks/data",
                .num_workers = 2,
                .max_workers = 20,
                .ip_configuration = .worker_ip_private,
            },
        } },
        .schedule = .{ .cron = "0 2 * * *", .time_zone = "Europe/London" },
        .scheduler_service_account_email = "scheduler@analytics-prod.iam.gserviceaccount.com",
    });
    defer pipeline.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.datapipelines.Pipeline.europe-west1.daily-orders", pipeline.node.id);
    try std.testing.expect(pipeline.node.lifecycle.protect);
    try std.testing.expect(pipeline.node.lifecycle.retain_on_delete);
}

test "Data Pipelines rejects invalid schedule and template boundaries" {
    try std.testing.expectError(error.InvalidSchedule, ziac.gcp.data_pipelines.Pipeline.build(std.testing.allocator, config(), .{
        .name = "stream",
        .location = "europe-west1",
        .display_name = "stream",
        .pipeline_type = .streaming,
        .workload = .{ .classic_template = .{ .gcs_path = "gs://templates/stream" } },
        .schedule = .{ .cron = "* * * * *", .time_zone = "UTC" },
    }));
    try std.testing.expectError(error.InvalidTemplate, ziac.gcp.data_pipelines.Pipeline.build(std.testing.allocator, config(), .{
        .name = "batch",
        .location = "europe-west1",
        .display_name = "batch",
        .pipeline_type = .batch,
        .workload = .{ .flex_template = .{ .container_spec_gcs_path = "https://example.com/spec.json" } },
    }));
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "analytics-prod", .primary_region = "europe-west1", .service_regions = &.{"europe-west1"} };
}
