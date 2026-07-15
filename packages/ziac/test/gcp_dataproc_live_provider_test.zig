const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

test "Dataproc cluster creation checkpoints and resumes the regional operation" {
    const operation_name = "projects/analytics-prod/regions/europe-west1/operations/create-cluster";
    const cluster_json = "{\"projectId\":\"analytics-prod\",\"clusterName\":\"analytics\",\"clusterUuid\":\"uuid-1\",\"config\":{\"gceClusterConfig\":{},\"masterConfig\":{\"numInstances\":1},\"workerConfig\":{\"numInstances\":2}},\"status\":{\"state\":\"RUNNING\"}}";
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"" ++ operation_name ++ "\"}"),
        ok("{\"name\":\"" ++ operation_name ++ "\",\"done\":true,\"response\":" ++ cluster_json ++ "}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.dataproc_provider.Handler{ .client = &harness.client, .operation_policy = .{ .poll_interval_millis = 0 } };
    var cluster = try buildCluster();
    defer cluster.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.create(&context, cluster.node);
    defer pending.deinit();
    try std.testing.expect(!pending.completed);
    try std.testing.expectEqualStrings(operation_name, pending.operation_handle.?);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].url, "/v1/projects/analytics-prod/regions/europe-west1/clusters?requestId=") != null);
    context.operation_handle = pending.operation_handle;
    var observed = try handler.read(&context, cluster.node, pending.physical_id);
    defer observed.deinit();
    try std.testing.expectEqualStrings("projects/analytics-prod/regions/europe-west1/clusters/analytics", observed.present.physical_id);
}

test "Dataproc workflow update carries the observed version token" {
    const current = "{\"id\":\"daily-orders\",\"name\":\"projects/analytics-prod/regions/europe-west1/workflowTemplates/daily-orders\",\"version\":7,\"placement\":{\"clusterSelector\":{\"clusterLabels\":{\"env\":\"old\"}}},\"jobs\":[{\"stepId\":\"extract\",\"pysparkJob\":{\"mainPythonFileUri\":\"gs://jobs/extract.py\"}}]}";
    const updated_json = "{\"id\":\"daily-orders\",\"name\":\"projects/analytics-prod/regions/europe-west1/workflowTemplates/daily-orders\",\"version\":8,\"placement\":{\"clusterSelector\":{\"clusterLabels\":{\"env\":\"prod\"}}},\"jobs\":[{\"stepId\":\"extract\",\"pysparkJob\":{\"mainPythonFileUri\":\"gs://jobs/extract.py\"}}]}";
    const responses = [_]zstd.Http.Response{ ok(current), ok(updated_json) };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.dataproc_provider.Handler{ .client = &harness.client };
    var workflow = try buildWorkflow();
    defer workflow.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var observed = try handler.read(&context, workflow.node, null);
    defer observed.deinit();
    var updated = try handler.update(&context, workflow.node, &observed.present);
    defer updated.deinit();
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[1].url, "/v1/projects/analytics-prod/regions/europe-west1/workflowTemplates/daily-orders"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"version\":7") != null);
}

fn buildCluster() !ziac.gcp.dataproc.Cluster {
    return ziac.gcp.dataproc.Cluster.build(std.testing.allocator, config(), .{
        .name = "analytics",
        .region = "europe-west1",
        .master = .{ .machine_type = "n2-standard-4", .disk_size_gb = 100 },
        .worker = .{ .machine_type = "n2-standard-4", .disk_size_gb = 100, .instances = 2 },
    });
}
fn buildWorkflow() !ziac.gcp.dataproc.WorkflowTemplate {
    return ziac.gcp.dataproc.WorkflowTemplate.build(std.testing.allocator, config(), .{
        .name = "daily-orders",
        .region = "europe-west1",
        .placement = .{ .cluster_selector = .{ .labels = &.{.{ .key = "env", .value = "prod" }} } },
        .jobs = &.{.{ .id = "extract", .job = .{ .pyspark = .{ .main_python_file_uri = "gs://jobs/extract.py" } } }},
    });
}
fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "analytics-prod", .primary_region = "europe-west1" };
}
const Harness = struct {
    source: FixedTokenSource,
    cache: ziac.gcp.auth.TokenCache,
    transport: @import("gcp_client_test.zig").RecordingTransport,
    client: ziac.gcp.client.Client,
    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.source = .{};
        self.cache = ziac.gcp.auth.TokenCache.init(self.source.tokenSource(), 300);
        self.transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = ziac.gcp.client.Client.init(self.transport.client(), &self.cache, .{ .dataproc = "https://dataproc.example.test" });
    }
    fn deinit(self: *Harness) void {
        self.transport.deinit();
        self.cache.deinit(std.testing.allocator);
    }
};
const FixedTokenSource = struct {
    fn tokenSource(self: *FixedTokenSource) ziac.gcp.auth.TokenSource {
        return .{ .ptr = self, .fetchFn = fetch };
    }
    fn fetch(_: *anyopaque, allocator: std.mem.Allocator, now: u64) ziac.gcp.auth.AuthError!ziac.gcp.auth.AccessToken {
        return ziac.gcp.auth.AccessToken.initOwned(allocator, .{ .access_token = "token", .token_type = "Bearer", .expires_at_seconds = now + 3600 });
    }
};
fn ok(body: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = body };
}
