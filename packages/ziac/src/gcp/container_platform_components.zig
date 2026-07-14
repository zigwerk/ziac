const std = @import("std");
const config_mod = @import("config.zig");
const container = @import("container_platform.zig");
const iam = @import("iam.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");

pub const BuildError = container.BuildError || iam.BuildError || resource.ResourceGraphError || std.mem.Allocator.Error || error{
    InvalidClusterMode,
    InvalidWorkloadIdentity,
};

pub const GkeNodePool = struct {
    name: []const u8,
    machine_type: []const u8,
    disk_type: []const u8 = "pd-balanced",
    disk_size_gb: u32 = 100,
    image_type: []const u8 = "COS_CONTAINERD",
    oauth_scopes: []const []const u8 = &.{"https://www.googleapis.com/auth/cloud-platform"},
    locations: []const []const u8 = &.{},
    node_count: u32 = 1,
    autoscaling: ?container.NodePoolAutoscaling = null,
    auto_repair: bool = true,
    auto_upgrade: bool = true,
    spot: bool = false,
    labels: []const container.Label = &.{},
    protect: bool = false,
};

pub const GkeFleet = struct {
    name: []const u8 = "default",
    membership_name: []const u8 = "",
    membership_location: []const u8 = "global",
    display_name: []const u8 = "",
    description: []const u8 = "",
    labels: []const container.Label = &.{},
    protect: bool = false,
};

pub const GkeWorkloadIdentity = struct {
    namespace: []const u8,
    kubernetes_service_account: []const u8,
};

pub const GkePlatformArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    cluster: container.ClusterArgs,
    identity_account_id: []const u8 = "",
    node_pools: []const GkeNodePool = &.{},
    fleet: ?GkeFleet = null,
    workload_identities: []const GkeWorkloadIdentity = &.{},
    protect_identity: bool = true,
};

pub const GkePlatform = struct {
    graph: resource.ResourceGraph,
    service_account: output.Output([]const u8, .public),
    cluster: output.Output([]const u8, .public),
    endpoint: output.Output([]const u8, .public),
    fleet: ?output.Output([]const u8, .public),
    membership: ?output.Output([]const u8, .public),

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: GkePlatformArgs) BuildError!GkePlatform {
        if (args.cluster.mode == .autopilot and args.node_pools.len != 0) return error.InvalidClusterMode;
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);

        const account_id = try identityIdAlloc(allocator, args.identity_account_id, args.cluster.name, "gke");
        defer allocator.free(account_id);
        const account_index = graph.resources.items.len;
        var account = try iam.ServiceAccount.build(allocator, provider, .{
            .account_id = account_id,
            .display_name = "Ziac GKE workload identity",
            .description = "Runtime identity managed by Ziac for a GKE platform",
        });
        defer account.deinit(allocator);
        account.node.lifecycle.protect = args.protect_identity;
        try graph.addResource(account.node);
        const account_resource_id = graph.resources.items[account_index].id;
        const account_output = iam.ServiceAccount.Outputs.Email.fromResource(account_resource_id);
        const account_email = try std.fmt.allocPrint(allocator, "{s}@{s}.iam.gserviceaccount.com", .{ account_id, provider.project_id });
        defer allocator.free(account_email);

        const cluster_index = graph.resources.items.len;
        var cluster_resource = try container.Cluster.build(allocator, provider, args.cluster);
        defer cluster_resource.deinit(allocator);
        try graph.addResource(cluster_resource.node);
        const cluster_resource_id = graph.resources.items[cluster_index].id;
        const cluster_output = container.Cluster.Outputs.Name.fromResource(cluster_resource_id);
        const endpoint_output = container.Cluster.Outputs.Endpoint.fromResource(cluster_resource_id);

        for (args.node_pools) |pool| {
            var node_pool = try container.NodePool.build(allocator, provider, .{
                .name = pool.name,
                .location = args.cluster.location,
                .cluster_name = args.cluster.name,
                .cluster = cluster_output,
                .machine_type = pool.machine_type,
                .disk_type = pool.disk_type,
                .disk_size_gb = pool.disk_size_gb,
                .image_type = pool.image_type,
                .service_account = account_output,
                .oauth_scopes = pool.oauth_scopes,
                .locations = pool.locations,
                .node_count = pool.node_count,
                .autoscaling = pool.autoscaling,
                .auto_repair = pool.auto_repair,
                .auto_upgrade = pool.auto_upgrade,
                .spot = pool.spot,
                .labels = pool.labels,
                .protect = pool.protect,
            });
            defer node_pool.deinit(allocator);
            try graph.addResource(node_pool.node);
        }

        var fleet_output: ?output.Output([]const u8, .public) = null;
        var membership_output: ?output.Output([]const u8, .public) = null;
        if (args.fleet) |fleet_args| {
            const fleet_index = graph.resources.items.len;
            var fleet_resource = try container.Fleet.build(allocator, provider, .{
                .name = fleet_args.name,
                .display_name = fleet_args.display_name,
                .labels = fleet_args.labels,
                .protect = fleet_args.protect,
            });
            defer fleet_resource.deinit(allocator);
            try graph.addResource(fleet_resource.node);
            const fleet_resource_id = graph.resources.items[fleet_index].id;
            fleet_output = container.Fleet.Outputs.Name.fromResource(fleet_resource_id);

            const membership_name = if (fleet_args.membership_name.len == 0) args.cluster.name else fleet_args.membership_name;
            const membership_index = graph.resources.items.len;
            var membership_resource = try container.Membership.build(allocator, provider, .{
                .name = membership_name,
                .location = fleet_args.membership_location,
                .cluster = cluster_output,
                .description = fleet_args.description,
                .labels = fleet_args.labels,
                .protect = fleet_args.protect,
            });
            defer membership_resource.deinit(allocator);
            try graph.addResource(membership_resource.node);
            const membership_resource_id = graph.resources.items[membership_index].id;
            try graph.addDependency(membership_resource_id, fleet_resource_id);
            membership_output = container.Membership.Outputs.Name.fromResource(membership_resource_id);
        }

        for (args.workload_identities, 0..) |binding, index| {
            if (!validKubernetesName(binding.namespace) or !validKubernetesName(binding.kubernetes_service_account)) return error.InvalidWorkloadIdentity;
            const binding_name = try std.fmt.allocPrint(allocator, "{s}-wi-{d}", .{ args.cluster.name, index });
            defer allocator.free(binding_name);
            const member = try std.fmt.allocPrint(
                allocator,
                "serviceAccount:{s}.svc.id.goog[{s}/{s}]",
                .{ provider.project_id, binding.namespace, binding.kubernetes_service_account },
            );
            defer allocator.free(member);
            const binding_index = graph.resources.items.len;
            var iam_member = try iam.ServiceAccountIamMember.build(allocator, provider, .{
                .name = binding_name,
                .service_account_email = account_email,
                .role = "roles/iam.workloadIdentityUser",
                .member = member,
            });
            defer iam_member.deinit(allocator);
            try graph.addResource(iam_member.node);
            try graph.addDependency(graph.resources.items[binding_index].id, account_resource_id);
        }

        try graph.validateAcyclic();
        return .{
            .graph = graph,
            .service_account = account_output,
            .cluster = cluster_output,
            .endpoint = endpoint_output,
            .fleet = fleet_output,
            .membership = membership_output,
        };
    }

    pub fn deinit(self: *GkePlatform) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

pub const ZigFunctionArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    location: []const u8,
    runtime: []const u8,
    entry_point: []const u8,
    source: container.StorageSource,
    identity_account_id: []const u8 = "",
    trigger: container.FunctionTrigger = .{ .http = {} },
    environment: []const container.EnvVar = &.{},
    secret_environment: []const container.SecretEnvVar = &.{},
    available_memory: []const u8 = "256Mi",
    available_cpu: []const u8 = "1",
    timeout_seconds: u32 = 60,
    min_instances: u32 = 0,
    max_instances: u32 = 100,
    max_concurrency: u32 = 1,
    ingress: container.FunctionIngress = .all,
    vpc_connector: output.Output([]const u8, .public) = .{ .value = "" },
    vpc_egress: []const u8 = "PRIVATE_RANGES_ONLY",
    kms_key: output.Output([]const u8, .public) = .{ .value = "" },
    labels: []const container.Label = &.{},
    invokers: []const []const u8 = &.{},
    protect: bool = false,
    protect_identity: bool = true,
};

pub const ZigFunction = struct {
    graph: resource.ResourceGraph,
    service_account: output.Output([]const u8, .public),
    name: output.Output([]const u8, .public),
    url: output.Output([]const u8, .public),
    state: output.Output([]const u8, .public),

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ZigFunctionArgs) BuildError!ZigFunction {
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);

        const account_id = try identityIdAlloc(allocator, args.identity_account_id, args.name, "fn");
        defer allocator.free(account_id);
        const account_index = graph.resources.items.len;
        var account = try iam.ServiceAccount.build(allocator, provider, .{
            .account_id = account_id,
            .display_name = "Ziac Function identity",
            .description = "Runtime and build identity managed by Ziac for a Cloud Function",
        });
        defer account.deinit(allocator);
        account.node.lifecycle.protect = args.protect_identity;
        try graph.addResource(account.node);
        const account_resource_id = graph.resources.items[account_index].id;
        const account_output = iam.ServiceAccount.Outputs.Email.fromResource(account_resource_id);

        const function_index = graph.resources.items.len;
        var function = try container.FunctionV2.build(allocator, provider, .{
            .name = args.name,
            .location = args.location,
            .runtime = args.runtime,
            .entry_point = args.entry_point,
            .source = args.source,
            .trigger = args.trigger,
            .service_account = account_output,
            .build_service_account = account_output,
            .environment = args.environment,
            .secret_environment = args.secret_environment,
            .available_memory = args.available_memory,
            .available_cpu = args.available_cpu,
            .timeout_seconds = args.timeout_seconds,
            .min_instances = args.min_instances,
            .max_instances = args.max_instances,
            .max_concurrency = args.max_concurrency,
            .ingress = args.ingress,
            .vpc_connector = args.vpc_connector,
            .vpc_egress = args.vpc_egress,
            .kms_key = args.kms_key,
            .labels = args.labels,
            .protect = args.protect,
        });
        defer function.deinit(allocator);
        try graph.addResource(function.node);
        const function_resource_id = graph.resources.items[function_index].id;
        const function_output = container.FunctionV2.Outputs.Name.fromResource(function_resource_id);

        for (args.invokers, 0..) |member, index| {
            const binding_name = try std.fmt.allocPrint(allocator, "{s}-invoker-{d}", .{ args.name, index });
            defer allocator.free(binding_name);
            var invoker = try container.FunctionIamMember.build(allocator, provider, .{
                .name = binding_name,
                .location = args.location,
                .function_name = args.name,
                .function = function_output,
                .role = "roles/run.invoker",
                .member = member,
            });
            defer invoker.deinit(allocator);
            try graph.addResource(invoker.node);
        }

        try graph.validateAcyclic();
        return .{
            .graph = graph,
            .service_account = account_output,
            .name = function_output,
            .url = container.FunctionV2.Outputs.Url.fromResource(function_resource_id),
            .state = container.FunctionV2.Outputs.State.fromResource(function_resource_id),
        };
    }

    pub fn deinit(self: *ZigFunction) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

pub const ZigBatchJobArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    location: []const u8,
    image: []const u8,
    identity_account_id: []const u8 = "",
    commands: []const []const u8 = &.{},
    environment: []const container.EnvVar = &.{},
    secret_environment: []const container.BatchSecretEnvVar = &.{},
    task_count: u32 = 1,
    parallelism: u32 = 1,
    max_retry_count: u32 = 0,
    max_run_seconds: u32 = 3600,
    machine_type: []const u8 = "e2-standard-2",
    provisioning_model: container.ProvisioningModel = .standard,
    network: output.Output([]const u8, .public) = .{ .value = "" },
    subnetwork: output.Output([]const u8, .public) = .{ .value = "" },
    logs: container.BatchLogs = .cloud_logging,
    priority: u8 = 0,
    labels: []const container.Label = &.{},
    protect: bool = false,
    protect_identity: bool = true,
};

pub const ZigBatchJob = struct {
    graph: resource.ResourceGraph,
    service_account: output.Output([]const u8, .public),
    name: output.Output([]const u8, .public),
    state: output.Output([]const u8, .public),

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ZigBatchJobArgs) BuildError!ZigBatchJob {
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);

        const account_id = try identityIdAlloc(allocator, args.identity_account_id, args.name, "batch");
        defer allocator.free(account_id);
        const account_index = graph.resources.items.len;
        var account = try iam.ServiceAccount.build(allocator, provider, .{
            .account_id = account_id,
            .display_name = "Ziac Batch identity",
            .description = "Runtime identity managed by Ziac for a Batch job",
        });
        defer account.deinit(allocator);
        account.node.lifecycle.protect = args.protect_identity;
        try graph.addResource(account.node);
        const account_resource_id = graph.resources.items[account_index].id;
        const account_output = iam.ServiceAccount.Outputs.Email.fromResource(account_resource_id);

        const job_index = graph.resources.items.len;
        var job = try container.BatchJob.build(allocator, provider, .{
            .name = args.name,
            .location = args.location,
            .image = args.image,
            .commands = args.commands,
            .environment = args.environment,
            .secret_environment = args.secret_environment,
            .task_count = args.task_count,
            .parallelism = args.parallelism,
            .max_retry_count = args.max_retry_count,
            .max_run_seconds = args.max_run_seconds,
            .machine_type = args.machine_type,
            .provisioning_model = args.provisioning_model,
            .service_account = account_output,
            .network = args.network,
            .subnetwork = args.subnetwork,
            .logs = args.logs,
            .priority = args.priority,
            .labels = args.labels,
            .protect = args.protect,
        });
        defer job.deinit(allocator);
        try graph.addResource(job.node);
        const job_resource_id = graph.resources.items[job_index].id;

        try graph.validateAcyclic();
        return .{
            .graph = graph,
            .service_account = account_output,
            .name = container.BatchJob.Outputs.Name.fromResource(job_resource_id),
            .state = container.BatchJob.Outputs.State.fromResource(job_resource_id),
        };
    }

    pub fn deinit(self: *ZigBatchJob) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

fn identityIdAlloc(allocator: std.mem.Allocator, explicit: []const u8, name: []const u8, suffix: []const u8) std.mem.Allocator.Error![]const u8 {
    if (explicit.len != 0) return allocator.dupe(u8, explicit);
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ name, suffix });
}

fn validKubernetesName(name: []const u8) bool {
    if (name.len == 0 or name.len > 63 or name[0] == '-' or name[name.len - 1] == '-') return false;
    for (name) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return false;
    return true;
}
