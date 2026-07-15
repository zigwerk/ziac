const std = @import("std");
const ziac = @import("ziac");

test "local data engineering qualification proves bounded deterministic evidence" {
    var graph = try qualificationGraph();
    defer graph.deinit();
    var retained: usize = 0;
    for (graph.resources.items) |node| if (node.lifecycle.retain_on_delete) {
        retained += 1;
    };

    var receipt = try ziac.gcp.data_engineering_qualification.serializeLocalAlloc(std.testing.allocator, &graph, .{
        .created = graph.resources.items.len,
        .imported = graph.resources.items.len,
        .no_op = graph.resources.items.len,
        .retained = retained,
        .resumable_operations = 1,
        .supported_asset_identities = 7,
        .governed_action_boundaries = ziac.gcp.intelligence.dataEngineeringActionUsages().len,
        .runtime_estimates_requiring_usage = 4,
    });
    defer receipt.deinit();

    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"schema\":\"ziac.gcp.data-engineering-qualification.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"authenticated\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"resource_count\":14") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"supported_asset_identities\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"governed_action_boundaries\":9") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"runtime_estimates_requiring_usage\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "authenticated_data_engineering_mutation_not_exercised") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "billing_usage_not_observed") != null);
}

fn qualificationGraph() !ziac.ResourceGraph {
    const provider = ziac.gcp.ProviderConfig{ .project_id = "analytics-prod", .primary_region = "europe-west1", .service_regions = &.{"europe-west1"} };
    var pipeline = try ziac.gcp.ScheduledDataflowPipeline.build(std.testing.allocator, provider, .{
        .pipeline = .{
            .name = "daily-orders",
            .location = "europe-west1",
            .display_name = "Daily-orders",
            .pipeline_type = .batch,
            .workload = .{ .flex_template = .{ .container_spec_gcs_path = "gs://templates/orders.json" } },
            .schedule = .{ .cron = "0 4 * * *", .time_zone = "Europe/London" },
            .scheduler_service_account_email = "scheduler@analytics-prod.iam.gserviceaccount.com",
        },
        .scheduler_member = "serviceAccount:scheduler@analytics-prod.iam.gserviceaccount.com",
        .worker_member = "serviceAccount:worker@analytics-prod.iam.gserviceaccount.com",
    });
    defer pipeline.deinit();
    var dataproc = try ziac.gcp.DataprocWorkflowPlatform.build(std.testing.allocator, provider, .{
        .base_graph = &pipeline.graph,
        .autoscaling = .{ .name = "balanced", .region = "europe-west1", .worker = .{ .min_instances = 2, .max_instances = 10 }, .removal_policy = .delete },
        .cluster = .{ .name = "analytics", .region = "europe-west1", .master = .{ .machine_type = "n2-standard-4", .disk_size_gb = 100 }, .worker = .{ .machine_type = "n2-standard-4", .disk_size_gb = 100, .instances = 2 }, .removal_policy = .delete },
        .workflow = .{ .name = "daily-orders", .region = "europe-west1", .placement = .{ .cluster_selector = .{ .labels = &.{.{ .key = "env", .value = "prod" }} } }, .jobs = &.{.{ .id = "extract", .job = .{ .pyspark = .{ .main_python_file_uri = "gs://jobs/extract.py" } } }}, .removal_policy = .delete },
        .operators = &.{"group:data@example.com"},
    });
    defer dataproc.deinit();
    const placeholder = ziac.PublicOutput([]const u8).known("projects/analytics-prod/locations/europe-west1/repositories/placeholder");
    const dataform = try ziac.gcp.DataformReleasePipeline.build(std.testing.allocator, provider, .{
        .base_graph = &dataproc.graph,
        .repository = .{ .name = "analytics", .location = "europe-west1" },
        .release = .{ .name = "production", .repository = placeholder, .git_commitish = "main", .removal_policy = .delete },
        .workflow = .{ .name = "production", .repository = placeholder, .release_config = ziac.PublicOutput([]const u8).known("projects/analytics-prod/locations/europe-west1/repositories/placeholder/releaseConfigs/placeholder"), .removal_policy = .delete },
        .workspace_name = "development",
        .operators = &.{"group:data@example.com"},
    });
    return dataform.graph;
}
