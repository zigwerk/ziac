const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
const image = "example.invalid/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

test "ZigJob synthesizes a dedicated runtime identity and typed Job" {
    var job = try ziac.gcp.ZigJob.build(std.testing.allocator, provider, .{
        .workload = .{
            .name = "nightly-report",
            .containers = &.{.{ .name = "main", .image = image }},
            .task_count = 8,
            .parallelism = 2,
            .retain_on_delete = false,
        },
    });
    defer job.deinit();

    try std.testing.expectEqual(@as(usize, 2), job.graph.resources.items.len);
    try std.testing.expect(hasResource(&job.graph, "gcp.iam.ServiceAccount.nightly-report-job"));
    const node = findResource(&job.graph, "gcp.run.Job.europe-west1.nightly-report");
    try std.testing.expectEqualStrings("nightly-report-job@ziac-dev.iam.gserviceaccount.com", stringField(node.inputs, "service_account"));
    try std.testing.expect(hasDependency(&job.graph, node.id, "gcp.iam.ServiceAccount.nightly-report-job"));
    try job.graph.validateAcyclic();
}

test "ScheduledZigJob composes OAuth invocation and exact Job IAM" {
    var scheduled = try ziac.gcp.ScheduledZigJob.build(std.testing.allocator, provider, .{
        .workload = .{
            .name = "nightly-report",
            .containers = &.{.{ .name = "main", .image = image }},
        },
        .schedule = "0 2 * * *",
    });
    defer scheduled.deinit();

    try std.testing.expectEqual(@as(usize, 5), scheduled.graph.resources.items.len);
    const scheduler_node = findResource(&scheduled.graph, "gcp.scheduler.Job.europe-west1.nightly-report");
    try std.testing.expectEqualStrings("oauth", stringField(scheduler_node.inputs, "auth_kind"));
    try std.testing.expectEqualStrings("https://run.googleapis.com", stringField(scheduler_node.inputs, "service_url"));
    try std.testing.expectEqualStrings("/v2/projects/ziac-dev/locations/europe-west1/jobs/nightly-report:run", stringField(scheduler_node.inputs, "path"));
    const iam_node = findResource(&scheduled.graph, "gcp.run.JobIamMember.nightly-report-scheduler-invoker");
    try std.testing.expectEqualStrings("roles/run.invoker", stringField(iam_node.inputs, "role"));
    try std.testing.expectEqualStrings("serviceAccount:nightly-report-schedule@ziac-dev.iam.gserviceaccount.com", stringField(iam_node.inputs, "member"));
    try std.testing.expect(hasDependency(&scheduled.graph, scheduler_node.id, iam_node.id));
    try scheduled.graph.validateAcyclic();
}

test "ZigWorkerPool synthesizes a dedicated worker identity" {
    var worker = try ziac.gcp.ZigWorkerPool.build(std.testing.allocator, provider, .{
        .workload = .{
            .name = "events",
            .containers = &.{.{ .name = "worker", .image = image }},
            .manual_instance_count = 4,
            .retain_on_delete = false,
        },
    });
    defer worker.deinit();

    try std.testing.expectEqual(@as(usize, 2), worker.graph.resources.items.len);
    const node = findResource(&worker.graph, "gcp.run.WorkerPool.europe-west1.events");
    try std.testing.expectEqualStrings("events-worker@ziac-dev.iam.gserviceaccount.com", stringField(node.inputs, "service_account"));
    try std.testing.expect(hasDependency(&worker.graph, node.id, "gcp.iam.ServiceAccount.events-worker"));
}

test "ZigJob generates a valid service account id for a short workload name" {
    var job = try ziac.gcp.ZigJob.build(std.testing.allocator, provider, .{
        .workload = .{
            .name = "x",
            .containers = &.{.{ .name = "main", .image = image }},
        },
    });
    defer job.deinit();

    try std.testing.expect(hasResource(&job.graph, "gcp.iam.ServiceAccount.xz-job"));
    const node = findResource(&job.graph, "gcp.run.Job.europe-west1.x");
    try std.testing.expectEqualStrings("xz-job@ziac-dev.iam.gserviceaccount.com", stringField(node.inputs, "service_account"));
}

fn findResource(graph: *const ziac.resource.ResourceGraph, id: []const u8) ziac.ResourceNode {
    for (graph.resources.items) |node| if (std.mem.eql(u8, node.id, id)) return node;
    unreachable;
}

fn hasResource(graph: *const ziac.resource.ResourceGraph, id: []const u8) bool {
    for (graph.resources.items) |node| if (std.mem.eql(u8, node.id, id)) return true;
    return false;
}

fn hasDependency(graph: *const ziac.resource.ResourceGraph, from: []const u8, to: []const u8) bool {
    for (graph.dependencies.items) |edge| if (std.mem.eql(u8, edge.from, from) and std.mem.eql(u8, edge.to, to)) return true;
    return false;
}

fn stringField(input: ziac.value.Value, name: []const u8) []const u8 {
    for (input.object) |field| if (std.mem.eql(u8, field.name, name)) return switch (field.value) {
        .string => |text| text,
        else => unreachable,
    };
    unreachable;
}
