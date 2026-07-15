const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{
    .project_id = "analytics-prod",
    .primary_region = "europe-west1",
    .service_regions = &.{"europe-west1"},
};

fn build(allocator: std.mem.Allocator) !ziac.gcp.DataformReleasePipeline {
    var pipeline = try ziac.gcp.ScheduledDataflowPipeline.build(allocator, provider, .{
        .pipeline = .{
            .name = "daily-orders",
            .location = "europe-west1",
            .display_name = "Daily-orders",
            .pipeline_type = .batch,
            .workload = .{ .flex_template = .{ .container_spec_gcs_path = "gs://analytics-templates/orders.json" } },
            .schedule = .{ .cron = "0 4 * * *", .time_zone = "Europe/London" },
            .scheduler_service_account_email = "scheduler@analytics-prod.iam.gserviceaccount.com",
        },
        .scheduler_member = "serviceAccount:scheduler@analytics-prod.iam.gserviceaccount.com",
        .worker_member = "serviceAccount:worker@analytics-prod.iam.gserviceaccount.com",
    });
    defer pipeline.deinit();

    var spark = try ziac.gcp.DataprocWorkflowPlatform.build(allocator, provider, .{
        .base_graph = &pipeline.graph,
        .autoscaling = .{
            .name = "balanced",
            .region = "europe-west1",
            .worker = .{ .min_instances = 2, .max_instances = 10 },
        },
        .cluster = .{
            .name = "analytics",
            .region = "europe-west1",
            .master = .{ .machine_type = "n2-standard-4", .disk_size_gb = 100 },
            .worker = .{ .machine_type = "n2-standard-4", .disk_size_gb = 100, .instances = 2 },
        },
        .workflow = .{
            .name = "daily-orders",
            .region = "europe-west1",
            .placement = .{ .cluster_selector = .{ .labels = &.{.{ .key = "env", .value = "prod" }} } },
            .jobs = &.{.{ .id = "extract", .job = .{ .pyspark = .{ .main_python_file_uri = "gs://analytics-jobs/extract.py" } } }},
        },
        .operators = &.{"group:data-platform@example.com"},
    });
    defer spark.deinit();

    const placeholder = ziac.PublicOutput([]const u8).known("projects/analytics-prod/locations/europe-west1/repositories/placeholder");
    return ziac.gcp.DataformReleasePipeline.build(allocator, provider, .{
        .base_graph = &spark.graph,
        .repository = .{ .name = "analytics", .location = "europe-west1" },
        .release = .{ .name = "production", .repository = placeholder, .git_commitish = "main" },
        .workflow = .{
            .name = "production",
            .repository = placeholder,
            .release_config = ziac.PublicOutput([]const u8).known("projects/analytics-prod/locations/europe-west1/repositories/placeholder/releaseConfigs/placeholder"),
        },
        .workspace_name = "development",
        .operators = &.{"group:data-platform@example.com"},
    });
}

pub fn main() !void {
    var platform = try build(std.heap.page_allocator);
    defer platform.deinit();
    var permissions = try ziac.gcp.intelligence.synthesizePermissionPlan(std.heap.page_allocator, &platform.graph);
    defer permissions.deinit(std.heap.page_allocator);
    std.debug.print("data engineering: {d} resources, {d} dependencies, {d} deployer permissions, {d} runtime permissions\n", .{
        platform.graph.resources.items.len,
        platform.graph.dependencies.items.len,
        permissions.deployer_permissions.len,
        permissions.runtime_permissions.len,
    });
}

test "data engineering example composes scheduled Dataflow Dataproc and Dataform" {
    var platform = try build(std.testing.allocator);
    defer platform.deinit();
    try platform.graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 14), platform.graph.resources.items.len);
    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &platform.graph);
    defer requirements.deinit(std.testing.allocator);
    try std.testing.expect(requirements.hasPermission("datapipelines.pipelines.create"));
    try std.testing.expect(requirements.hasPermission("dataproc.clusters.create"));
    try std.testing.expect(requirements.hasPermission("dataform.repositories.create"));
}
