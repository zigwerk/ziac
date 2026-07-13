const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;

test "live Cloud Run Job provider resumes LROs normalizes drift and preserves etags" {
    const job_json =
        "{\"name\":\"projects/ziac-dev/locations/europe-west1/jobs/migrate\",\"uid\":\"job-uid\",\"labels\":{},\"annotations\":{},\"template\":{" ++
        "\"taskCount\":2,\"parallelism\":1,\"template\":{\"containers\":[{\"name\":\"main\",\"image\":\"example.invalid/migrate@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"resources\":{\"limits\":{\"cpu\":\"1\",\"memory\":\"512Mi\"}}}],\"maxRetries\":3,\"timeout\":\"600s\",\"serviceAccount\":\"default\",\"executionEnvironment\":\"EXECUTION_ENVIRONMENT_GEN2\"}}," ++
        "\"executionCount\":\"4\",\"latestCreatedExecution\":{\"name\":\"projects/ziac-dev/locations/europe-west1/jobs/migrate/executions/migrate-42\"},\"terminalCondition\":{\"state\":\"CONDITION_SUCCEEDED\"},\"reconciling\":false,\"etag\":\"etag-job-1\"}";
    const create_operation = "{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/create-job\",\"done\":false}";
    const create_done = "{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/create-job\",\"done\":true,\"response\":" ++ job_json ++ "}";
    const update_operation = "{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/update-job\",\"done\":false}";
    const update_done = "{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/update-job\",\"done\":true,\"response\":" ++ job_json ++ "}";
    const delete_operation = "{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/delete-job\",\"done\":false}";
    const delete_done = "{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/delete-job\",\"done\":true,\"response\":{}}";
    const responses = [_]zstd.Http.Response{
        notFound(), ok(create_operation), ok(create_done), ok(job_json), ok(update_operation), ok(update_done), ok(job_json), ok(job_json), ok(delete_operation), ok(delete_done),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var job = try buildJob(1);
    defer job.deinit(std.testing.allocator);
    var changed = try buildJob(2);
    defer changed.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var absent = try live.readWithContext(&context, job.node);
    defer absent.deinit();
    var pending = try live.createWithContext(&context, job.node);
    defer pending.deinit();
    try std.testing.expect(!pending.completed);
    context.operation_handle = pending.operation_handle;
    var completed = try live.readWithContext(&context, job.node);
    defer completed.deinit();
    context.operation_handle = null;
    try std.testing.expectEqual(@as(i64, 4), outputInteger(completed.present, "execution_count"));
    var read = try live.readWithContext(&context, job.node);
    defer read.deinit();
    var stable = try live.diffWithContext(&context, job.node, &read.present);
    defer stable.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.noop, stable.kind);
    var diff = try live.diffWithContext(&context, changed.node, &read.present);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, diff.kind);
    var update = try live.updateWithContext(&context, changed.node, &read.present);
    defer update.deinit();
    context.operation_handle = update.operation_handle;
    var update_completed = try live.readWithContext(&context, changed.node);
    defer update_completed.deinit();
    context.operation_handle = null;
    var imported = try live.importWithContext(&context, job.node, read.present.physical_id);
    defer imported.deinit();
    try live.deleteWithContext(&context, job.node, imported.physical_id);

    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].url, "jobId=migrate") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[4].url, "allowMissing=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[4].body, "\"etag\":\"etag-job-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[8].url, "etag=etag-job-1") != null);
}

test "live Cloud Run WorkerPool provider resumes LROs and uses explicit update masks" {
    const worker_json =
        "{\"name\":\"projects/ziac-dev/locations/europe-west1/workerPools/events\",\"uid\":\"worker-uid\",\"description\":\"events\",\"labels\":{},\"annotations\":{}," ++
        "\"template\":{\"containers\":[{\"name\":\"worker\",\"image\":\"example.invalid/events@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"resources\":{\"limits\":{\"cpu\":\"1\",\"memory\":\"512Mi\"}}}],\"serviceAccount\":\"default\"}," ++
        "\"scaling\":{\"manualInstanceCount\":3},\"instanceSplits\":[{\"type\":\"INSTANCE_SPLIT_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"latestReadyRevision\":\"projects/ziac-dev/locations/europe-west1/workerPools/events/revisions/events-00001\",\"latestCreatedRevision\":\"projects/ziac-dev/locations/europe-west1/workerPools/events/revisions/events-00001\",\"terminalCondition\":{\"state\":\"CONDITION_SUCCEEDED\"},\"reconciling\":false,\"etag\":\"etag-worker-1\"}";
    const create_operation = "{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/create-worker\",\"done\":false}";
    const create_done = "{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/create-worker\",\"done\":true,\"response\":" ++ worker_json ++ "}";
    const update_operation = "{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/update-worker\",\"done\":false}";
    const update_done = "{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/update-worker\",\"done\":true,\"response\":" ++ worker_json ++ "}";
    const delete_operation = "{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/delete-worker\",\"done\":false}";
    const delete_done = "{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/delete-worker\",\"done\":true,\"response\":{}}";
    const responses = [_]zstd.Http.Response{
        notFound(), ok(create_operation), ok(create_done), ok(worker_json), ok(update_operation), ok(update_done), ok(worker_json), ok(worker_json), ok(delete_operation), ok(delete_done),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var worker = try buildWorker(3);
    defer worker.deinit(std.testing.allocator);
    var changed = try buildWorker(4);
    defer changed.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var absent = try live.readWithContext(&context, worker.node);
    defer absent.deinit();
    var pending = try live.createWithContext(&context, worker.node);
    defer pending.deinit();
    context.operation_handle = pending.operation_handle;
    var completed = try live.readWithContext(&context, worker.node);
    defer completed.deinit();
    context.operation_handle = null;
    var read = try live.readWithContext(&context, worker.node);
    defer read.deinit();
    var stable = try live.diffWithContext(&context, worker.node, &read.present);
    defer stable.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.noop, stable.kind);
    var update = try live.updateWithContext(&context, changed.node, &read.present);
    defer update.deinit();
    context.operation_handle = update.operation_handle;
    var update_completed = try live.readWithContext(&context, changed.node);
    defer update_completed.deinit();
    context.operation_handle = null;
    var imported = try live.importWithContext(&context, worker.node, read.present.physical_id);
    defer imported.deinit();
    try live.deleteWithContext(&context, worker.node, imported.physical_id);

    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[4].url, "updateMask=description,labels,annotations,template,instanceSplits,scaling") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[4].url, "forceNewRevision=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[8].url, "etag=etag-worker-1") != null);
}

test "single-container Jobs normalize multiple implicit secret volume targets without drift" {
    const job_json =
        "{\"name\":\"projects/ziac-dev/locations/europe-west1/jobs/secret-reader\",\"uid\":\"job-uid\",\"labels\":{},\"annotations\":{},\"template\":{" ++
        "\"taskCount\":1,\"parallelism\":0,\"template\":{\"containers\":[{\"name\":\"main\",\"image\":\"example.invalid/reader@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"resources\":{\"limits\":{\"cpu\":\"1\",\"memory\":\"512Mi\"}},\"volumeMounts\":[{\"name\":\"signing\",\"mountPath\":\"/var/run/signing\"},{\"name\":\"trust\",\"mountPath\":\"/var/run/trust\"}] }]," ++
        "\"volumes\":[{\"name\":\"signing\",\"secret\":{\"secret\":\"signing-key\",\"items\":[{\"version\":\"latest\",\"path\":\"key.pem\"}]}},{\"name\":\"trust\",\"secret\":{\"secret\":\"trust-bundle\",\"items\":[{\"version\":\"latest\",\"path\":\"ca.pem\"}]} }]," ++
        "\"maxRetries\":3,\"timeout\":\"600s\",\"serviceAccount\":\"default\",\"executionEnvironment\":\"EXECUTION_ENVIRONMENT_UNSPECIFIED\"}},\"executionCount\":\"0\",\"reconciling\":false,\"etag\":\"etag-job-1\"}";
    const responses = [_]zstd.Http.Response{ok(job_json)};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var job = try ziac.gcp.run_workloads.Job.build(std.testing.allocator, .{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    }, .{
        .name = "secret-reader",
        .containers = &.{.{
            .name = "main",
            .image = "example.invalid/reader@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        }},
        .secret_volumes = &.{
            .{ .name = "signing", .secret = "signing-key", .path = "key.pem", .mount_path = "/var/run/signing" },
            .{ .name = "trust", .secret = "trust-bundle", .path = "ca.pem", .mount_path = "/var/run/trust" },
        },
    });
    defer job.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var read = try harness.live.provider().readWithContext(&context, job.node);
    defer read.deinit();
    var diff = try harness.live.provider().diffWithContext(&context, job.node, &read.present);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.noop, diff.kind);
}

const Harness = struct {
    source: FixedTokenSource,
    cache: auth.TokenCache,
    transport: @import("gcp_client_test.zig").RecordingTransport,
    client: gclient.Client,
    live: ziac.gcp.live_provider.LiveProvider,

    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.source = .{};
        self.cache = auth.TokenCache.init(self.source.tokenSource(), 300);
        self.transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{ .run = "https://run.example.test" });
        self.live = ziac.gcp.live_provider.LiveProvider.init(&self.client);
        self.live.operation_policy.poll_interval_millis = 0;
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

fn buildJob(parallelism: u32) !ziac.gcp.run_workloads.Job {
    return ziac.gcp.run_workloads.Job.build(std.testing.allocator, .{ .project_id = "ziac-dev", .primary_region = "europe-west1" }, .{
        .name = "migrate",
        .containers = &.{.{ .name = "main", .image = "example.invalid/migrate@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }},
        .task_count = 2,
        .parallelism = parallelism,
        .execution_environment = .gen2,
        .retain_on_delete = false,
    });
}

fn buildWorker(count: u32) !ziac.gcp.run_workloads.WorkerPool {
    return ziac.gcp.run_workloads.WorkerPool.build(std.testing.allocator, .{ .project_id = "ziac-dev", .primary_region = "europe-west1" }, .{
        .name = "events",
        .description = "events",
        .containers = &.{.{ .name = "worker", .image = "example.invalid/events@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }},
        .manual_instance_count = count,
        .retain_on_delete = false,
    });
}

fn outputInteger(result: ziac.provider.ResourceResult, name: []const u8) i64 {
    for (result.outputs) |entry| if (std.mem.eql(u8, entry.name, name)) return switch (entry.value) {
        .integer => |number| number,
        else => unreachable,
    };
    unreachable;
}

fn ok(body: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = body };
}
fn notFound() zstd.Http.Response {
    return .{ .status = 404, .body = "{\"error\":{\"code\":404,\"status\":\"NOT_FOUND\"}}" };
}
