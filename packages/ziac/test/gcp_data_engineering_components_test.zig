const std = @import("std");
const ziac = @import("ziac");

const config = ziac.gcp.ProviderConfig{ .project_id = "analytics-prod", .primary_region = "europe-west1", .service_regions = &.{"europe-west1"} };

test "ScheduledDataflowPipeline composes recurring workload and least authority" {
    var platform = try ziac.gcp.ScheduledDataflowPipeline.build(std.testing.allocator, config, .{
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
    defer platform.deinit();
    try std.testing.expectEqual(@as(usize, 4), platform.graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 1), countType(&platform.graph, "gcp.datapipelines.Pipeline"));
    try std.testing.expectEqual(@as(usize, 3), countType(&platform.graph, "gcp.iam.ProjectMember"));
    try platform.graph.validateAcyclic();
}

test "DataprocWorkflowPlatform wires autoscaling cluster workflow and operators" {
    var platform = try ziac.gcp.DataprocWorkflowPlatform.build(std.testing.allocator, config, .{
        .autoscaling = .{ .name = "balanced", .region = "europe-west1", .worker = .{ .min_instances = 2, .max_instances = 10 } },
        .cluster = .{ .name = "analytics", .region = "europe-west1", .master = .{ .machine_type = "n2-standard-4", .disk_size_gb = 100 }, .worker = .{ .machine_type = "n2-standard-4", .disk_size_gb = 100, .instances = 2 } },
        .workflow = .{ .name = "daily-orders", .region = "europe-west1", .placement = .{ .cluster_selector = .{ .labels = &.{.{ .key = "env", .value = "prod" }} } }, .jobs = &.{.{ .id = "extract", .job = .{ .pyspark = .{ .main_python_file_uri = "gs://jobs/extract.py" } } }} },
        .operators = &.{"group:data@example.com"},
    });
    defer platform.deinit();
    try std.testing.expectEqual(@as(usize, 5), platform.graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 1), countType(&platform.graph, "gcp.dataproc.ClusterIamMember"));
    try std.testing.expectEqual(@as(usize, 1), countType(&platform.graph, "gcp.dataproc.WorkflowTemplateIamMember"));
    try platform.graph.validateAcyclic();
}

test "DataformReleasePipeline wires repository release workflow workspace and authority" {
    const placeholder = ziac.PublicOutput([]const u8).known("projects/analytics-prod/locations/europe-west1/repositories/placeholder");
    var platform = try ziac.gcp.DataformReleasePipeline.build(std.testing.allocator, config, .{
        .repository = .{ .name = "analytics", .location = "europe-west1", .git_remote = .{ .url = "https://github.com/acme/analytics.git", .authentication = .{ .token_secret_version = "projects/analytics-prod/secrets/git/versions/1" } } },
        .release = .{ .name = "production", .repository = placeholder, .git_commitish = "main" },
        .workflow = .{ .name = "production", .repository = placeholder, .release_config = ziac.PublicOutput([]const u8).known("projects/analytics-prod/locations/europe-west1/repositories/placeholder/releaseConfigs/placeholder") },
        .workspace_name = "development",
        .operators = &.{"group:data@example.com"},
    });
    defer platform.deinit();
    try std.testing.expectEqual(@as(usize, 5), platform.graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 1), countType(&platform.graph, "gcp.dataform.RepositoryIamMember"));
    try std.testing.expectEqual(@as(usize, 1), countType(&platform.graph, "gcp.dataform.Workspace"));
    try platform.graph.validateAcyclic();
}

fn countType(graph: *const ziac.ResourceGraph, type_name: []const u8) usize {
    var count: usize = 0;
    for (graph.resources.items) |node| if (std.mem.eql(u8, node.type_name, type_name)) {
        count += 1;
    };
    return count;
}
