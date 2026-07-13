const std = @import("std");
const async_components = @import("async_components.zig");
const cloud_run = @import("cloud_run.zig");
const config_mod = @import("config.zig");
const eventarc = @import("eventarc.zig");
const iam = @import("iam.zig");
const pubsub = @import("pubsub.zig");
const pubsub_components = @import("pubsub_components.zig");
const resource = @import("../resource.zig");
const run_components = @import("run_components.zig");
const run_workloads = @import("run_workloads.zig");
const scheduler = @import("scheduler.zig");
const storage = @import("storage.zig");
const storage_components = @import("storage_components.zig");
const tasks = @import("tasks.zig");

pub const BuildError = cloud_run.BuildError || iam.BuildError || storage_components.BuildError ||
    pubsub_components.BuildError || async_components.BuildError || run_components.BuildError ||
    resource.ResourceGraphError || error{InvalidServiceOrigin};

pub const ApplicationPlatformArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    project_number: []const u8,
    image: []const u8,
    service_origin: []const u8,
    bucket_name: []const u8,
    location: []const u8,
    allowed_persistence_regions: []const []const u8 = &.{},
    cors_origins: []const []const u8 = &.{},
    service_command: []const []const u8 = &.{},
    service_args: []const []const u8 = &.{},
    job_command: []const []const u8 = &.{},
    job_args: []const []const u8 = &.{},
    worker_command: []const []const u8 = &.{},
    worker_args: []const []const u8 = &.{},
    schedule: []const u8 = "0 2 * * *",
    time_zone: []const u8 = "Etc/UTC",
    retain_data: bool = true,
};

pub const ApplicationPlatform = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    service: cloud_run.Service.Outputs.Name.OutputType,
    service_url: cloud_run.Service.Outputs.ServiceUrl.OutputType,
    bucket: storage.Bucket.Outputs.Name.OutputType,
    topic: pubsub.Topic.Outputs.Name.OutputType,
    subscription: pubsub.Subscription.Outputs.Name.OutputType,
    queue: tasks.Queue.Outputs.Name.OutputType,
    trigger: eventarc.Trigger.Outputs.Name.OutputType,
    job: run_workloads.Job.Outputs.Name.OutputType,
    schedule: scheduler.Job.Outputs.Name.OutputType,
    worker_pool: run_workloads.WorkerPool.Outputs.Name.OutputType,
    runtime_service_account: iam.ServiceAccount.Outputs.Email.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: ApplicationPlatformArgs,
    ) BuildError!ApplicationPlatform {
        try validateServiceOrigin(args.service_origin);

        const service_name = try boundedNameAlloc(allocator, args.name, "api", 63);
        defer allocator.free(service_name);
        const runtime_account_id = try boundedNameAlloc(allocator, args.name, "runtime", 30);
        defer allocator.free(runtime_account_id);
        const subscriber_name = try boundedNameAlloc(allocator, args.name, "events", 63);
        defer allocator.free(subscriber_name);
        const tasks_name = try boundedNameAlloc(allocator, args.name, "tasks", 63);
        defer allocator.free(tasks_name);
        const trigger_name = try boundedNameAlloc(allocator, args.name, "trigger", 63);
        defer allocator.free(trigger_name);
        const job_name = try boundedNameAlloc(allocator, args.name, "job", 63);
        defer allocator.free(job_name);
        const worker_name = try boundedNameAlloc(allocator, args.name, "worker", 49);
        defer allocator.free(worker_name);
        const runtime_email = try std.fmt.allocPrint(
            allocator,
            "{s}@{s}.iam.gserviceaccount.com",
            .{ runtime_account_id, provider.project_id },
        );
        defer allocator.free(runtime_email);
        const runtime_member = try std.fmt.allocPrint(allocator, "serviceAccount:{s}", .{runtime_email});
        defer allocator.free(runtime_member);
        const push_endpoint = try std.fmt.allocPrint(allocator, "{s}/events/pubsub", .{args.service_origin});
        defer allocator.free(push_endpoint);
        const task_endpoint = try std.fmt.allocPrint(allocator, "{s}/tasks", .{args.service_origin});
        defer allocator.free(task_endpoint);

        var base = resource.ResourceGraph.init(allocator);
        defer base.deinit();
        if (args.base_graph) |parent| try base.appendGraph(parent);

        const account_index = base.resources.items.len;
        var runtime_account = try iam.ServiceAccount.build(allocator, provider, .{
            .account_id = runtime_account_id,
            .display_name = "Ziac application runtime",
            .description = "Dedicated identity for one Ziac application platform",
        });
        defer runtime_account.deinit(allocator);
        try base.addResource(runtime_account.node);
        const runtime_account_resource_id = base.resources.items[account_index].id;

        const service_index = base.resources.items.len;
        var service = try cloud_run.Service.build(allocator, provider, .{
            .name = service_name,
            .image = args.image,
            .command = args.service_command,
            .args = args.service_args,
            .service_account = runtime_email,
            .ingress = .internal_and_cloud_load_balancing,
            .allow_unauthenticated = false,
        });
        defer service.deinit(allocator);
        try base.addResource(service.node);
        const service_resource_id = base.resources.items[service_index].id;
        try base.addDependency(service_resource_id, runtime_account_resource_id);
        try base.validateAcyclic();

        var uploads = try storage_components.UploadBucket.build(allocator, provider, .{
            .base_graph = &base,
            .name = args.bucket_name,
            .location = args.location,
            .writers = &.{runtime_member},
            .cors_origins = args.cors_origins,
            .retain_on_delete = args.retain_data,
        });
        defer uploads.deinit();

        var subscriber = try pubsub_components.ZigSubscriber.build(allocator, provider, .{
            .base_graph = &uploads.graph,
            .name = subscriber_name,
            .project_number = args.project_number,
            .service = cloud_run.Service.Outputs.Name.fromResource(service_resource_id),
            .push_endpoint = push_endpoint,
            .oidc_audience = args.service_origin,
            .publishers = &.{runtime_member},
            .allowed_persistence_regions = args.allowed_persistence_regions,
            .retain_on_delete = args.retain_data,
        });
        defer subscriber.deinit();

        var task_worker = try async_components.ZigTaskWorker.build(allocator, provider, .{
            .base_graph = &subscriber.graph,
            .name = tasks_name,
            .service = cloud_run.Service.Outputs.Name.fromResource(service_resource_id),
            .endpoint = task_endpoint,
            .enqueuers = &.{runtime_member},
            .retain_on_delete = args.retain_data,
        });
        defer task_worker.deinit();

        var event_pipeline = try async_components.EventPipeline.build(allocator, provider, .{
            .base_graph = &task_worker.graph,
            .name = trigger_name,
            .service = cloud_run.Service.Outputs.Name.fromResource(service_resource_id),
            .service_name = service_name,
            .event_filters = &.{.{
                .attribute = "type",
                .value = "google.cloud.pubsub.topic.v1.messagePublished",
            }},
            .create_transport_topic = true,
            .publishers = &.{runtime_member},
            .retain_on_delete = args.retain_data,
        });
        defer event_pipeline.deinit();

        var scheduled_job = try run_components.ScheduledZigJob.build(allocator, provider, .{
            .base_graph = &event_pipeline.graph,
            .workload = .{
                .name = job_name,
                .containers = &.{.{
                    .name = "main",
                    .image = args.image,
                    .command = args.job_command,
                    .args = args.job_args,
                }},
                .retain_on_delete = false,
            },
            .schedule = args.schedule,
            .time_zone = args.time_zone,
        });
        defer scheduled_job.deinit();

        var worker = try run_components.ZigWorkerPool.build(allocator, provider, .{
            .base_graph = &scheduled_job.graph,
            .workload = .{
                .name = worker_name,
                .containers = &.{.{
                    .name = "worker",
                    .image = args.image,
                    .command = args.worker_command,
                    .args = args.worker_args,
                }},
                .retain_on_delete = false,
            },
        });
        errdefer worker.deinit();
        try worker.graph.validateAcyclic();

        var final_graph = worker.graph;
        errdefer final_graph.deinit();
        worker.graph = resource.ResourceGraph.init(allocator);
        worker.deinit();

        const service_final_id = findResourceId(&final_graph, "gcp.run.Service", service_name) orelse unreachable;
        const runtime_account_final_id = findResourceId(&final_graph, "gcp.iam.ServiceAccount", runtime_account_id) orelse unreachable;
        const bucket_resource_id = findResourceId(&final_graph, "gcp.storage.Bucket", args.bucket_name) orelse unreachable;
        const topic_resource_id = findResourceId(&final_graph, "gcp.pubsub.Topic", subscriber_name) orelse unreachable;
        const subscription_resource_id = findResourceByPrefix(&final_graph, "gcp.pubsub.Subscription.", subscriber_name) orelse unreachable;
        const queue_resource_id = findResourceId(&final_graph, "gcp.tasks.Queue", tasks_name) orelse unreachable;
        const trigger_resource_id = findResourceId(&final_graph, "gcp.eventarc.Trigger", trigger_name) orelse unreachable;
        const job_resource_id = findResourceId(&final_graph, "gcp.run.Job", job_name) orelse unreachable;
        const schedule_resource_id = findResourceId(&final_graph, "gcp.scheduler.Job", job_name) orelse unreachable;
        const worker_resource_id = findResourceId(&final_graph, "gcp.run.WorkerPool", worker_name) orelse unreachable;

        return .{
            .allocator = allocator,
            .graph = final_graph,
            .service = cloud_run.Service.Outputs.Name.fromResource(service_final_id),
            .service_url = cloud_run.Service.Outputs.ServiceUrl.fromResource(service_final_id),
            .bucket = storage.Bucket.Outputs.Name.fromResource(bucket_resource_id),
            .topic = pubsub.Topic.Outputs.Name.fromResource(topic_resource_id),
            .subscription = pubsub.Subscription.Outputs.Name.fromResource(subscription_resource_id),
            .queue = tasks.Queue.Outputs.Name.fromResource(queue_resource_id),
            .trigger = eventarc.Trigger.Outputs.Name.fromResource(trigger_resource_id),
            .job = run_workloads.Job.Outputs.Name.fromResource(job_resource_id),
            .schedule = scheduler.Job.Outputs.Name.fromResource(schedule_resource_id),
            .worker_pool = run_workloads.WorkerPool.Outputs.Name.fromResource(worker_resource_id),
            .runtime_service_account = iam.ServiceAccount.Outputs.Email.fromResource(runtime_account_final_id),
        };
    }

    pub fn deinit(self: *ApplicationPlatform) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

fn validateServiceOrigin(origin: []const u8) BuildError!void {
    if (!std.mem.startsWith(u8, origin, "https://") or origin.len == "https://".len or
        std.mem.indexOfAny(u8, origin, "\x00\r\n ?#") != null or
        std.mem.indexOfScalarPos(u8, origin, "https://".len, '/') != null or
        origin[origin.len - 1] == '.') return error.InvalidServiceOrigin;
}

fn boundedNameAlloc(
    allocator: std.mem.Allocator,
    base: []const u8,
    suffix: []const u8,
    maximum: usize,
) std.mem.Allocator.Error![]const u8 {
    const candidate = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ base, suffix });
    if (candidate.len <= maximum) return candidate;
    defer allocator.free(candidate);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(candidate, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const prefix_len = maximum - 15;
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ base[0..@min(prefix_len, base.len)], hex[0..14] });
}

fn findResourceId(graph: *const resource.ResourceGraph, type_name: []const u8, logical_id: []const u8) ?[]const u8 {
    for (graph.resources.items) |node| {
        if (std.mem.eql(u8, node.type_name, type_name) and std.mem.eql(u8, node.logical_id, logical_id)) return node.id;
    }
    return null;
}

fn findResourceByPrefix(graph: *const resource.ResourceGraph, prefix: []const u8, contains_name: []const u8) ?[]const u8 {
    for (graph.resources.items) |node| {
        if (std.mem.startsWith(u8, node.id, prefix) and std.mem.indexOf(u8, node.id, contains_name) != null) return node.id;
    }
    return null;
}
