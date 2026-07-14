const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;
const platform = ziac.gcp.container_platform;

test "GKE create checkpoints and resumes native Container operations" {
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"operation-create-cluster\",\"status\":\"RUNNING\"}"),
        ok("{\"name\":\"operation-create-cluster\",\"status\":\"DONE\"}"),
        ok(clusterJson()),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.container_platform_provider.Handler{ .client = &harness.client, .operation_policy = .{ .poll_interval_millis = 0 } };
    var cluster = try buildCluster(.autopilot, "prod");
    defer cluster.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.create(&context, cluster.node);
    defer pending.deinit();
    try std.testing.expect(!pending.completed);
    try std.testing.expectEqualStrings("operation-create-cluster", pending.operation_handle.?);
    context.operation_handle = pending.operation_handle;
    var read = try handler.read(&context, cluster.node, null);
    defer read.deinit();

    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].url, "/v1/projects/ziac-dev/locations/europe-west1/clusters") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "\"autopilot\":{\"enabled\":true}") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].url, "/operations/operation-create-cluster") != null);
    try std.testing.expectEqualStrings("RUNNING", outputValue(read.present, "status").string);
    try std.testing.expectEqualStrings("ziac-dev.svc.id.goog", outputValue(read.present, "workload_pool").string);
}

test "Standard GKE creation removes the implicit default node pool" {
    const responses = [_]zstd.Http.Response{ok("{\"name\":\"operation-create-standard\",\"status\":\"RUNNING\"}")};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.container_platform_provider.Handler{ .client = &harness.client };
    var cluster = try buildCluster(.standard, "prod");
    defer cluster.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.create(&context, cluster.node);
    defer pending.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "\"removeDefaultNodePool\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "\"initialNodeCount\":1") != null);
}

test "GKE node pool updates select native size autoscaling and configuration methods" {
    var old_pool = try buildPool(2, 1, 4, "e2-standard-4");
    defer old_pool.deinit(std.testing.allocator);

    {
        var desired = try buildPool(3, 1, 4, "e2-standard-4");
        defer desired.deinit(std.testing.allocator);
        const responses = [_]zstd.Http.Response{ok("{\"name\":\"resize\",\"status\":\"RUNNING\"}")};
        var harness: Harness = undefined;
        harness.init(&responses);
        defer harness.deinit();
        const handler = ziac.gcp.container_platform_provider.Handler{ .client = &harness.client };
        var context = ziac.provider.OperationContext.init(std.testing.allocator);
        var observed = try resultFor(old_pool.node, &.{});
        defer observed.deinit();
        var pending = try handler.update(&context, desired.node, &observed);
        defer pending.deinit();
        try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[0].url, "/nodePools/general:setSize"));
        try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "\"nodeCount\":3") != null);
    }
    {
        var desired = try buildPool(2, 1, 8, "e2-standard-4");
        defer desired.deinit(std.testing.allocator);
        const responses = [_]zstd.Http.Response{ok("{\"name\":\"autoscale\",\"status\":\"RUNNING\"}")};
        var harness: Harness = undefined;
        harness.init(&responses);
        defer harness.deinit();
        const handler = ziac.gcp.container_platform_provider.Handler{ .client = &harness.client };
        var context = ziac.provider.OperationContext.init(std.testing.allocator);
        var observed = try resultFor(old_pool.node, &.{});
        defer observed.deinit();
        var pending = try handler.update(&context, desired.node, &observed);
        defer pending.deinit();
        try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[0].url, "/nodePools/general:setAutoscaling"));
        try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "\"maxNodeCount\":8") != null);
    }
    {
        var desired = try buildPool(2, 1, 4, "c4-standard-4");
        defer desired.deinit(std.testing.allocator);
        const responses = [_]zstd.Http.Response{ok("{\"name\":\"reconfigure\",\"status\":\"RUNNING\"}")};
        var harness: Harness = undefined;
        harness.init(&responses);
        defer harness.deinit();
        const handler = ziac.gcp.container_platform_provider.Handler{ .client = &harness.client };
        var context = ziac.provider.OperationContext.init(std.testing.allocator);
        var observed = try resultFor(old_pool.node, &.{});
        defer observed.deinit();
        var pending = try handler.update(&context, desired.node, &observed);
        defer pending.deinit();
        try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[0].url, "/nodePools/general"));
        try std.testing.expectEqualStrings("PUT", harness.transport.requests.items[0].method);
        try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "\"machineType\":\"c4-standard-4\"") != null);
    }
}

test "Fleet and memberships use generic LROs field masks and etags" {
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"projects/ziac-dev/locations/global/operations/create-fleet\",\"done\":false}"),
        ok("{\"name\":\"projects/ziac-dev/locations/global/operations/patch-membership\",\"done\":false}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.container_platform_provider.Handler{ .client = &harness.client };
    var fleet = try platform.Fleet.build(std.testing.allocator, config(), .{ .name = "default", .display_name = "Production" });
    defer fleet.deinit(std.testing.allocator);
    var membership = try buildMembership("new description");
    defer membership.deinit(std.testing.allocator);
    var old_membership = try buildMembership("old description");
    defer old_membership.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var fleet_pending = try handler.create(&context, fleet.node);
    defer fleet_pending.deinit();
    var observed = try resultFor(old_membership.node, &.{});
    defer observed.deinit();
    var membership_pending = try handler.update(&context, membership.node, &observed);
    defer membership_pending.deinit();

    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].url, "/v1/projects/ziac-dev/locations/global/fleets?fleetId=default") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].url, "updateMask=description%2Clabels%2Cendpoint") != null);
}

test "Functions v2 resume operations and IAM preserves unrelated bindings" {
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/create-function\",\"done\":false}"),
        ok("{\"version\":1,\"etag\":\"etag-policy\",\"bindings\":[{\"role\":\"roles/logging.logWriter\",\"members\":[\"serviceAccount:other@ziac-dev.iam.gserviceaccount.com\"]}]}"),
        ok("{\"version\":1,\"etag\":\"etag-next\",\"bindings\":[{\"role\":\"roles/logging.logWriter\",\"members\":[\"serviceAccount:other@ziac-dev.iam.gserviceaccount.com\"]},{\"role\":\"roles/run.invoker\",\"members\":[\"allUsers\"]}]}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.container_platform_provider.Handler{ .client = &harness.client };
    var function = try buildFunction();
    defer function.deinit(std.testing.allocator);
    var member = try platform.FunctionIamMember.build(std.testing.allocator, config(), .{
        .name = "thumbnail-public",
        .location = "europe-west1",
        .function_name = "thumbnail",
        .function = function.name,
        .role = "roles/run.invoker",
        .member = "allUsers",
    });
    defer member.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.create(&context, function.node);
    defer pending.deinit();
    var iam_result = try handler.create(&context, member.node);
    defer iam_result.deinit();

    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].url, "/v2/projects/ziac-dev/locations/europe-west1/functions?functionId=thumbnail") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "\"secretEnvironmentVariables\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[1].url, "/functions/thumbnail:getIamPolicy"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[2].body, "roles/logging.logWriter") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[2].body, "roles/run.invoker") != null);
    try std.testing.expectEqualStrings("etag-next", outputValue(iam_result, "etag").string);
}

test "Batch create is synchronous changes replace and cancel waits for its LRO" {
    const responses = [_]zstd.Http.Response{
        ok(batchJson("RUNNING")),
        ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/cancel-job\",\"done\":false}"),
        ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/cancel-job\",\"done\":true}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.container_platform_provider.Handler{ .client = &harness.client, .operation_policy = .{ .poll_interval_millis = 0 } };
    var job = try buildBatch(10);
    defer job.deinit(std.testing.allocator);
    var changed = try buildBatch(20);
    defer changed.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try handler.create(&context, job.node);
    defer created.deinit();
    try std.testing.expect(created.completed);
    try std.testing.expectEqualStrings("RUNNING", outputValue(created, "state").string);
    var diff = try ziac.gcp.container_platform_provider.Handler.diff(&context, changed.node, &created);
    defer diff.deinit();
    try std.testing.expect(diff.kind == .replace);
    try handler.cancelBatchJob(&context, job.node);

    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].url, "/v1/projects/ziac-dev/locations/europe-west1/jobs?jobId=daily-rollup") != null);
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[1].url, "/jobs/daily-rollup:cancel"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[2].url, "/operations/cancel-job") != null);
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
}

fn buildCluster(mode: platform.ClusterMode, environment: []const u8) !platform.Cluster {
    return platform.Cluster.build(std.testing.allocator, config(), .{
        .name = "platform",
        .location = "europe-west1",
        .mode = mode,
        .network = known("projects/ziac-dev/global/networks/platform"),
        .subnetwork = known("projects/ziac-dev/regions/europe-west1/subnetworks/gke"),
        .ip_allocation = .{ .cluster_secondary_range = "pods", .services_secondary_range = "services" },
        .private_cluster = .{ .private_nodes = true, .master_ipv4_cidr = "172.16.0.0/28" },
        .labels = &.{.{ .key = "environment", .value = environment }},
    });
}

fn buildPool(count: u32, min_nodes: u32, max_nodes: u32, machine: []const u8) !platform.NodePool {
    return platform.NodePool.build(std.testing.allocator, config(), .{
        .name = "general",
        .location = "europe-west1",
        .cluster_name = "platform",
        .cluster = known("projects/ziac-dev/locations/europe-west1/clusters/platform"),
        .machine_type = machine,
        .service_account = known("nodes@ziac-dev.iam.gserviceaccount.com"),
        .node_count = count,
        .autoscaling = .{ .min_nodes = min_nodes, .max_nodes = max_nodes },
    });
}

fn buildMembership(description: []const u8) !platform.Membership {
    return platform.Membership.build(std.testing.allocator, config(), .{
        .name = "platform-eu",
        .cluster = known("//container.googleapis.com/projects/ziac-dev/locations/europe-west1/clusters/platform"),
        .description = description,
    });
}

fn buildFunction() !platform.FunctionV2 {
    return platform.FunctionV2.build(std.testing.allocator, config(), .{
        .name = "thumbnail",
        .location = "europe-west1",
        .runtime = "nodejs24",
        .entry_point = "thumbnail",
        .source = .{ .bucket = "source", .object = "thumbnail.zip", .generation = 1 },
        .trigger = .{ .http = {} },
        .service_account = known("thumbnail@ziac-dev.iam.gserviceaccount.com"),
        .build_service_account = known("projects/ziac-dev/serviceAccounts/build@ziac-dev.iam.gserviceaccount.com"),
        .secret_environment = &.{.{ .key = "DATABASE_URL", .project_id = "ziac-dev", .secret = "database-url", .version = "1" }},
    });
}

fn buildBatch(task_count: u32) !platform.BatchJob {
    return platform.BatchJob.build(std.testing.allocator, config(), .{
        .name = "daily-rollup",
        .location = "europe-west1",
        .image = "example/image@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .task_count = task_count,
        .parallelism = 2,
        .service_account = known("batch@ziac-dev.iam.gserviceaccount.com"),
    });
}

fn resultFor(node: ziac.ResourceNode, outputs: []const ziac.state.StateOutput) !ziac.provider.ResourceResult {
    return ziac.provider.ResourceResult.init(std.testing.allocator, "physical", node.inputs, outputs, null);
}

fn clusterJson() []const u8 {
    return "{\"name\":\"platform\",\"selfLink\":\"https://container.googleapis.com/v1/projects/ziac-dev/locations/europe-west1/clusters/platform\",\"location\":\"europe-west1\",\"status\":\"RUNNING\",\"endpoint\":\"10.0.0.2\",\"network\":\"projects/ziac-dev/global/networks/platform\",\"subnetwork\":\"projects/ziac-dev/regions/europe-west1/subnetworks/gke\",\"autopilot\":{\"enabled\":true},\"releaseChannel\":{\"channel\":\"REGULAR\"},\"workloadIdentityConfig\":{\"workloadPool\":\"ziac-dev.svc.id.goog\"},\"ipAllocationPolicy\":{\"clusterSecondaryRangeName\":\"pods\",\"servicesSecondaryRangeName\":\"services\"},\"privateClusterConfig\":{\"enablePrivateNodes\":true,\"enablePrivateEndpoint\":false,\"masterIpv4CidrBlock\":\"172.16.0.0/28\"},\"binaryAuthorization\":{\"evaluationMode\":\"DISABLED\"},\"loggingConfig\":{\"componentConfig\":{\"enableComponents\":[\"SYSTEM_COMPONENTS\"]}},\"monitoringConfig\":{\"componentConfig\":{\"enableComponents\":[\"SYSTEM_COMPONENTS\"]}},\"resourceLabels\":{\"environment\":\"prod\"},\"labelFingerprint\":\"labels-a\",\"deletionProtection\":true}";
}

fn batchJson(state: []const u8) []const u8 {
    if (std.mem.eql(u8, state, "RUNNING")) return "{\"name\":\"projects/ziac-dev/locations/europe-west1/jobs/daily-rollup\",\"uid\":\"job-uid\",\"status\":{\"state\":\"RUNNING\"}}";
    unreachable;
}

fn known(text: []const u8) ziac.PublicOutput([]const u8) {
    return .known(text);
}

const Harness = struct {
    source: FixedTokenSource,
    cache: auth.TokenCache,
    transport: @import("gcp_client_test.zig").RecordingTransport,
    client: gclient.Client,

    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.source = .{};
        self.cache = auth.TokenCache.init(self.source.tokenSource(), 300);
        self.transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{
            .container = "https://container.example.test",
            .gke_hub = "https://gkehub.example.test",
            .cloud_functions = "https://cloudfunctions.example.test",
            .batch = "https://batch.example.test",
        });
    }

    fn deinit(self: *Harness) void {
        self.transport.deinit();
        self.cache.deinit(std.testing.allocator);
    }
};

const FixedTokenSource = struct {
    fn tokenSource(self: *FixedTokenSource) auth.TokenSource {
        return .{ .ptr = self, .fetchFn = fetch };
    }
    fn fetch(_: *anyopaque, allocator: std.mem.Allocator, now: u64) auth.AuthError!auth.AccessToken {
        return auth.AccessToken.initOwned(allocator, .{ .access_token = "token", .token_type = "Bearer", .expires_at_seconds = now + 3600 });
    }
};

fn outputValue(result: ziac.provider.ResourceResult, name: []const u8) ziac.value.Value {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name)) return item.value;
    unreachable;
}

fn ok(body: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = @constCast(body) };
}
