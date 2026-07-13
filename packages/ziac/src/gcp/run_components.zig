const std = @import("std");
const config_mod = @import("config.zig");
const iam = @import("iam.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const scheduler = @import("scheduler.zig");
const workloads = @import("run_workloads.zig");

pub const BuildError = workloads.BuildError || iam.BuildError || resource.ResourceGraphError || std.mem.Allocator.Error || error{
    InvalidScheduler,
    ManagedIdentityConflict,
};

pub const ZigJobArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    workload: workloads.JobArgs,
    service_account_id: []const u8 = "",
};

pub const ZigJob = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    job: workloads.Job.Outputs.Name.OutputType,
    service_account: iam.ServiceAccount.Outputs.Email.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ZigJobArgs) BuildError!ZigJob {
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);
        const parts = try appendJob(allocator, &graph, provider, args.workload, args.service_account_id);
        try graph.validateAcyclic();
        return .{
            .allocator = allocator,
            .graph = graph,
            .job = workloads.Job.Outputs.Name.fromResource(parts.workload_id),
            .service_account = iam.ServiceAccount.Outputs.Email.fromResource(parts.account_id),
        };
    }

    pub fn deinit(self: *ZigJob) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

pub const ScheduledZigJobArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    workload: workloads.JobArgs,
    service_account_id: []const u8 = "",
    scheduler_account_id: []const u8 = "",
    schedule: []const u8,
    time_zone: []const u8 = "Etc/UTC",
    attempt_deadline_seconds: u16 = 900,
};

pub const ScheduledZigJob = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    job: workloads.Job.Outputs.Name.OutputType,
    schedule: scheduler.Job.Outputs.Name.OutputType,
    runtime_service_account: iam.ServiceAccount.Outputs.Email.OutputType,
    scheduler_service_account: iam.ServiceAccount.Outputs.Email.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ScheduledZigJobArgs) BuildError!ScheduledZigJob {
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);
        const job_parts = try appendJob(allocator, &graph, provider, args.workload, args.service_account_id);

        const scheduler_account_id = if (args.scheduler_account_id.len > 0)
            try allocator.dupe(u8, args.scheduler_account_id)
        else
            try accountIdAlloc(allocator, args.workload.name, "schedule");
        defer allocator.free(scheduler_account_id);
        const scheduler_email = try std.fmt.allocPrint(allocator, "{s}@{s}.iam.gserviceaccount.com", .{ scheduler_account_id, provider.project_id });
        defer allocator.free(scheduler_email);
        const scheduler_member = try std.fmt.allocPrint(allocator, "serviceAccount:{s}", .{scheduler_email});
        defer allocator.free(scheduler_member);

        const scheduler_account_index = graph.resources.items.len;
        var scheduler_account = try iam.ServiceAccount.build(allocator, provider, .{
            .account_id = scheduler_account_id,
            .display_name = "Ziac Cloud Run Job scheduler",
            .description = "Invokes one Cloud Run Job through the Google Run API",
        });
        defer scheduler_account.deinit(allocator);
        try graph.addResource(scheduler_account.node);
        const scheduler_account_resource_id = graph.resources.items[scheduler_account_index].id;

        const binding_name = try std.fmt.allocPrint(allocator, "{s}-scheduler-invoker", .{args.workload.name});
        defer allocator.free(binding_name);
        const binding_index = graph.resources.items.len;
        var binding = try workloads.JobIamMember.build(allocator, provider, .{
            .name = binding_name,
            .job = workloads.Job.Outputs.Name.fromResource(job_parts.workload_id),
            .role = "roles/run.invoker",
            .member = scheduler_member,
        });
        defer binding.deinit(allocator);
        try graph.addResource(binding.node);
        const binding_resource_id = graph.resources.items[binding_index].id;
        try graph.addDependency(binding_resource_id, scheduler_account_resource_id);

        const region = args.workload.region orelse provider.primary_region;
        const path = try std.fmt.allocPrint(allocator, "/v2/projects/{s}/locations/{s}/jobs/{s}:run", .{ provider.project_id, region, args.workload.name });
        defer allocator.free(path);
        const schedule_index = graph.resources.items.len;
        var schedule = scheduler.Job.build(allocator, provider, .{
            .name = args.workload.name,
            .location = region,
            .description = "Run a Ziac-managed Cloud Run Job",
            .schedule = args.schedule,
            .time_zone = args.time_zone,
            .service_url = output.Output([]const u8, .public).known("https://run.googleapis.com"),
            .path = path,
            .service_account = scheduler_email,
            .auth_kind = .oauth,
            .oauth_scope = "https://www.googleapis.com/auth/cloud-platform",
            .body_json = "{}",
            .attempt_deadline_seconds = args.attempt_deadline_seconds,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidScheduler,
        };
        defer schedule.deinit(allocator);
        try graph.addResource(schedule.node);
        const schedule_resource_id = graph.resources.items[schedule_index].id;
        try graph.addDependency(schedule_resource_id, scheduler_account_resource_id);
        try graph.addDependency(schedule_resource_id, binding_resource_id);
        try graph.addDependency(schedule_resource_id, job_parts.workload_id);
        try graph.validateAcyclic();
        return .{
            .allocator = allocator,
            .graph = graph,
            .job = workloads.Job.Outputs.Name.fromResource(job_parts.workload_id),
            .schedule = scheduler.Job.Outputs.Name.fromResource(schedule_resource_id),
            .runtime_service_account = iam.ServiceAccount.Outputs.Email.fromResource(job_parts.account_id),
            .scheduler_service_account = iam.ServiceAccount.Outputs.Email.fromResource(scheduler_account_resource_id),
        };
    }

    pub fn deinit(self: *ScheduledZigJob) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

pub const ZigWorkerPoolArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    workload: workloads.WorkerPoolArgs,
    service_account_id: []const u8 = "",
};

pub const ZigWorkerPool = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    worker_pool: workloads.WorkerPool.Outputs.Name.OutputType,
    service_account: iam.ServiceAccount.Outputs.Email.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ZigWorkerPoolArgs) BuildError!ZigWorkerPool {
        if (args.workload.service_account != null) return error.ManagedIdentityConflict;
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);
        const account_id = if (args.service_account_id.len > 0)
            try allocator.dupe(u8, args.service_account_id)
        else
            try accountIdAlloc(allocator, args.workload.name, "worker");
        defer allocator.free(account_id);
        const account_email = try std.fmt.allocPrint(allocator, "{s}@{s}.iam.gserviceaccount.com", .{ account_id, provider.project_id });
        defer allocator.free(account_email);
        const account_index = graph.resources.items.len;
        var account = try iam.ServiceAccount.build(allocator, provider, .{
            .account_id = account_id,
            .display_name = "Ziac Cloud Run Worker Pool runtime",
            .description = "Dedicated identity for one Cloud Run Worker Pool",
        });
        defer account.deinit(allocator);
        try graph.addResource(account.node);
        const account_resource_id = graph.resources.items[account_index].id;
        var workload_args = args.workload;
        workload_args.service_account = account_email;
        const workload_index = graph.resources.items.len;
        var workload = try workloads.WorkerPool.build(allocator, provider, workload_args);
        defer workload.deinit(allocator);
        try graph.addResource(workload.node);
        const workload_resource_id = graph.resources.items[workload_index].id;
        try graph.addDependency(workload_resource_id, account_resource_id);
        try graph.validateAcyclic();
        return .{
            .allocator = allocator,
            .graph = graph,
            .worker_pool = workloads.WorkerPool.Outputs.Name.fromResource(workload_resource_id),
            .service_account = iam.ServiceAccount.Outputs.Email.fromResource(account_resource_id),
        };
    }

    pub fn deinit(self: *ZigWorkerPool) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

const JobParts = struct {
    account_id: []const u8,
    workload_id: []const u8,
};

fn appendJob(allocator: std.mem.Allocator, graph: *resource.ResourceGraph, provider: config_mod.ProviderConfig, args: workloads.JobArgs, configured_account_id: []const u8) BuildError!JobParts {
    if (args.service_account != null) return error.ManagedIdentityConflict;
    const account_id = if (configured_account_id.len > 0)
        try allocator.dupe(u8, configured_account_id)
    else
        try accountIdAlloc(allocator, args.name, "job");
    defer allocator.free(account_id);
    const account_email = try std.fmt.allocPrint(allocator, "{s}@{s}.iam.gserviceaccount.com", .{ account_id, provider.project_id });
    defer allocator.free(account_email);
    const account_index = graph.resources.items.len;
    var account = try iam.ServiceAccount.build(allocator, provider, .{
        .account_id = account_id,
        .display_name = "Ziac Cloud Run Job runtime",
        .description = "Dedicated identity for one Cloud Run Job",
    });
    defer account.deinit(allocator);
    try graph.addResource(account.node);
    const account_resource_id = graph.resources.items[account_index].id;
    var workload_args = args;
    workload_args.service_account = account_email;
    const workload_index = graph.resources.items.len;
    var workload = try workloads.Job.build(allocator, provider, workload_args);
    defer workload.deinit(allocator);
    try graph.addResource(workload.node);
    const workload_resource_id = graph.resources.items[workload_index].id;
    try graph.addDependency(workload_resource_id, account_resource_id);
    return .{ .account_id = account_resource_id, .workload_id = workload_resource_id };
}

fn accountIdAlloc(allocator: std.mem.Allocator, name: []const u8, suffix: []const u8) std.mem.Allocator.Error![]const u8 {
    var slug: std.ArrayList(u8) = .empty;
    defer slug.deinit(allocator);
    if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) try slug.append(allocator, 'z');
    const max_base = 29 - suffix.len;
    for (name) |character| {
        if (slug.items.len == max_base) break;
        const normalized = if (std.ascii.isAlphabetic(character)) std.ascii.toLower(character) else if (std.ascii.isDigit(character) or character == '-') character else '-';
        try slug.append(allocator, normalized);
    }
    while (slug.items.len > 0 and slug.items[slug.items.len - 1] == '-') _ = slug.pop();
    while (slug.items.len < 1) try slug.append(allocator, 'z');
    while (slug.items.len + 1 + suffix.len < 6) try slug.append(allocator, 'z');
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ slug.items, suffix });
}
