const std = @import("std");
const ziac = @import("ziac");

test "Dataproc declarations type autoscaled clusters workflow DAGs and IAM" {
    const dataproc = ziac.gcp.dataproc;
    var autoscaling = try dataproc.AutoscalingPolicy.build(std.testing.allocator, config(), .{
        .name = "balanced",
        .region = "europe-west1",
        .worker = .{ .min_instances = 2, .max_instances = 20, .weight = 1 },
        .secondary_worker = .{ .min_instances = 0, .max_instances = 50, .weight = 1 },
        .algorithm = .{ .yarn = .{ .graceful_decommission_timeout_seconds = 600, .scale_up_factor = 0.5, .scale_down_factor = 0.5 } },
    });
    defer autoscaling.deinit(std.testing.allocator);

    var cluster = try dataproc.Cluster.build(std.testing.allocator, config(), .{
        .name = "analytics",
        .region = "europe-west1",
        .zone = "europe-west1-b",
        .service_account = "dataproc@analytics-prod.iam.gserviceaccount.com",
        .subnetwork = "projects/analytics-prod/regions/europe-west1/subnetworks/data",
        .master = .{ .machine_type = "n2-standard-4", .disk_size_gb = 100 },
        .worker = .{ .machine_type = "n2-standard-4", .disk_size_gb = 250, .instances = 2 },
        .secondary_worker = .{ .machine_type = "n2-standard-4", .disk_size_gb = 100, .instances = 2, .preemptibility = .spot },
        .autoscaling_policy = autoscaling.name,
        .image_version = "2.2-debian12",
        .component_gateway = true,
        .init_actions = &.{.{ .executable_file = "gs://analytics-bootstrap/dataproc/init.sh", .timeout_seconds = 600 }},
    });
    defer cluster.deinit(std.testing.allocator);

    var cluster_iam = try dataproc.ClusterIamMember.build(std.testing.allocator, config(), .{
        .name = "analysts",
        .resource = cluster.name,
        .role = "roles/dataproc.viewer",
        .member = "group:analytics@example.com",
    });
    defer cluster_iam.deinit(std.testing.allocator);

    const jobs = [_]dataproc.WorkflowJob{
        .{ .id = "extract", .job = .{ .pyspark = .{ .main_python_file_uri = "gs://analytics-jobs/extract.py" } } },
        .{ .id = "aggregate", .prerequisite_step_ids = &.{"extract"}, .job = .{ .spark = .{ .main_class = "com.example.Aggregate", .jar_file_uris = &.{"gs://analytics-jobs/aggregate.jar"} } } },
    };
    var workflow = try dataproc.WorkflowTemplate.build(std.testing.allocator, config(), .{
        .name = "daily-orders",
        .region = "europe-west1",
        .placement = .{ .cluster = cluster.name },
        .jobs = &jobs,
        .dag_timeout_seconds = 3600,
    });
    defer workflow.deinit(std.testing.allocator);

    var workflow_iam = try dataproc.WorkflowTemplateIamMember.build(std.testing.allocator, config(), .{
        .name = "scheduler",
        .resource = workflow.name,
        .role = "roles/dataproc.editor",
        .member = "serviceAccount:scheduler@analytics-prod.iam.gserviceaccount.com",
    });
    defer workflow_iam.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.dataproc.Cluster.europe-west1.analytics", cluster.node.id);
    try std.testing.expectEqualStrings("gcp.dataproc.WorkflowTemplate.europe-west1.daily-orders", workflow.node.id);
    try std.testing.expect(cluster.node.lifecycle.protect);
}

test "Dataproc rejects invalid worker bounds and cyclic workflow DAGs" {
    const dataproc = ziac.gcp.dataproc;
    try std.testing.expectError(error.InvalidScaling, dataproc.AutoscalingPolicy.build(std.testing.allocator, config(), .{
        .name = "bad",
        .region = "europe-west1",
        .worker = .{ .min_instances = 10, .max_instances = 2 },
    }));
    try std.testing.expectError(error.CyclicWorkflow, dataproc.WorkflowTemplate.build(std.testing.allocator, config(), .{
        .name = "cycle",
        .region = "europe-west1",
        .placement = .{ .cluster_selector = .{ .labels = &.{.{ .key = "env", .value = "prod" }} } },
        .jobs = &.{
            .{ .id = "a", .prerequisite_step_ids = &.{"b"}, .job = .{ .pyspark = .{ .main_python_file_uri = "gs://jobs/a.py" } } },
            .{ .id = "b", .prerequisite_step_ids = &.{"a"}, .job = .{ .pyspark = .{ .main_python_file_uri = "gs://jobs/b.py" } } },
        },
    }));
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "analytics-prod", .primary_region = "europe-west1", .service_regions = &.{"europe-west1"} };
}
