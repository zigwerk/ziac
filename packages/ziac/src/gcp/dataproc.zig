const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    CyclicWorkflow,
    DuplicateField,
    DuplicateJob,
    DuplicateKey,
    InvalidCluster,
    InvalidDisk,
    InvalidIamMember,
    InvalidJob,
    InvalidName,
    InvalidNetwork,
    InvalidOutput,
    InvalidRegion,
    InvalidRole,
    InvalidScaling,
    InvalidServiceAccount,
    InvalidTimeout,
    MissingPrerequisite,
};

pub const KeyValue = struct { key: []const u8, value: []const u8 };
pub const RemovalPolicy = enum { retain, delete };

pub const InstanceBounds = struct {
    min_instances: u16,
    max_instances: u16,
    weight: u16 = 1,
};

pub const YarnAlgorithm = struct {
    graceful_decommission_timeout_seconds: u32 = 0,
    scale_up_factor: f64 = 0.0,
    scale_down_factor: f64 = 0.0,
    scale_up_min_worker_fraction: f64 = 0.0,
    scale_down_min_worker_fraction: f64 = 0.0,
};

pub const ScalingAlgorithm = union(enum) { yarn: YarnAlgorithm };

pub const AutoscalingPolicyArgs = struct {
    name: []const u8,
    region: []const u8,
    worker: InstanceBounds,
    secondary_worker: ?InstanceBounds = null,
    algorithm: ScalingAlgorithm = .{ .yarn = .{} },
    labels: []const KeyValue = &.{},
    protect: bool = true,
    removal_policy: RemovalPolicy = .retain,
};

pub const AutoscalingPolicy = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: AutoscalingPolicyArgs) BuildError!AutoscalingPolicy {
        try provider.validate();
        try validateCommon(provider, args.name, args.region);
        try validateBounds(args.worker, false);
        if (args.secondary_worker) |bounds| try validateBounds(bounds, true);
        var worker = try boundsValue(allocator, args.worker);
        defer worker.deinit(allocator);
        var secondary = if (args.secondary_worker) |selected| try boundsValue(allocator, selected) else try ownedValue(allocator, .{ .object = &.{} });
        defer secondary.deinit(allocator);
        var algorithm = try algorithmValue(allocator, args.algorithm);
        defer algorithm.deinit(allocator);
        var labels = try mapValue(allocator, args.labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "algorithm", .value = algorithm },
            .{ .name = "labels", .value = labels },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "region", .value = .{ .string = args.region } },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
            .{ .name = "secondary_worker", .value = secondary },
            .{ .name = "worker", .value = worker },
        };
        const node = try nodeOwned(allocator, "gcp.dataproc.AutoscalingPolicy", args.region, args.name, &fields, .{ .protect = args.protect, .retain_on_delete = args.removal_policy == .retain });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
    }

    pub fn deinit(self: *AutoscalingPolicy, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const Preemptibility = enum { non_preemptible, preemptible, spot };
pub const InstanceGroup = struct {
    machine_type: []const u8,
    disk_size_gb: u32,
    disk_type: []const u8 = "pd-balanced",
    instances: u16 = 1,
    local_ssds: u8 = 0,
    preemptibility: Preemptibility = .non_preemptible,
};
pub const InitAction = struct { executable_file: []const u8, timeout_seconds: u32 = 600 };

pub const ClusterArgs = struct {
    name: []const u8,
    region: []const u8,
    zone: []const u8 = "",
    service_account: ?[]const u8 = null,
    subnetwork: ?[]const u8 = null,
    network: ?[]const u8 = null,
    master: InstanceGroup,
    worker: InstanceGroup,
    secondary_worker: ?InstanceGroup = null,
    autoscaling_policy: ?output.Output([]const u8, .public) = null,
    image_version: []const u8 = "",
    kms_key_name: ?output.Output([]const u8, .public) = null,
    component_gateway: bool = false,
    init_actions: []const InitAction = &.{},
    properties: []const KeyValue = &.{},
    labels: []const KeyValue = &.{},
    protect: bool = true,
    removal_policy: RemovalPolicy = .retain,
};

pub const Cluster = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Uuid = output.Descriptor("uuid", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    uuid: Outputs.Uuid.OutputType,
    state: Outputs.State.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ClusterArgs) BuildError!Cluster {
        try provider.validate();
        try validateCommon(provider, args.name, args.region);
        if (args.zone.len != 0 and !std.mem.startsWith(u8, args.zone, args.region)) return error.InvalidRegion;
        if ((args.subnetwork == null) == (args.network == null) and args.subnetwork != null) return error.InvalidNetwork;
        if (args.subnetwork) |network| if (!std.mem.startsWith(u8, network, "projects/") or std.mem.indexOf(u8, network, "/subnetworks/") == null) return error.InvalidNetwork;
        if (args.network) |network| if (!std.mem.startsWith(u8, network, "projects/") or std.mem.indexOf(u8, network, "/networks/") == null) return error.InvalidNetwork;
        if (args.service_account) |email| try validateServiceAccount(email);
        try validateGroup(args.master, false);
        try validateGroup(args.worker, false);
        if (args.secondary_worker) |group| try validateGroup(group, true);
        for (args.init_actions) |action| if (!std.mem.startsWith(u8, action.executable_file, "gs://") or action.timeout_seconds == 0 or action.timeout_seconds > 3600) return error.InvalidCluster;
        var master = try groupValue(allocator, args.master);
        defer master.deinit(allocator);
        var worker = try groupValue(allocator, args.worker);
        defer worker.deinit(allocator);
        var secondary = if (args.secondary_worker) |selected| try groupValue(allocator, selected) else try ownedValue(allocator, .{ .object = &.{} });
        defer secondary.deinit(allocator);
        var actions = try initActionsValue(allocator, args.init_actions);
        defer actions.deinit(allocator);
        var properties = try mapValue(allocator, args.properties);
        defer properties.deinit(allocator);
        var labels = try mapValue(allocator, args.labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "autoscaling_policy", .value = try optionalOutputValue(args.autoscaling_policy) },
            .{ .name = "component_gateway", .value = .{ .boolean = args.component_gateway } },
            .{ .name = "image_version", .value = .{ .string = args.image_version } },
            .{ .name = "init_actions", .value = actions },
            .{ .name = "kms_key_name", .value = try optionalOutputValue(args.kms_key_name) },
            .{ .name = "labels", .value = labels },
            .{ .name = "master", .value = master },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "network", .value = .{ .string = args.network orelse "" } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "properties", .value = properties },
            .{ .name = "region", .value = .{ .string = args.region } },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
            .{ .name = "secondary_worker", .value = secondary },
            .{ .name = "service_account", .value = .{ .string = args.service_account orelse "" } },
            .{ .name = "subnetwork", .value = .{ .string = args.subnetwork orelse "" } },
            .{ .name = "worker", .value = worker },
            .{ .name = "zone", .value = .{ .string = args.zone } },
        };
        const node = try nodeOwned(allocator, "gcp.dataproc.Cluster", args.region, args.name, &fields, .{ .protect = args.protect, .retain_on_delete = args.removal_policy == .retain });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .uuid = Outputs.Uuid.fromResource(node.id), .state = Outputs.State.fromResource(node.id) };
    }

    pub fn deinit(self: *Cluster, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const ClusterSelector = struct { labels: []const KeyValue };
pub const ManagedCluster = struct {
    name: []const u8,
    zone: []const u8 = "",
    master: InstanceGroup,
    worker: InstanceGroup,
    secondary_worker: ?InstanceGroup = null,
    autoscaling_policy: ?output.Output([]const u8, .public) = null,
};
pub const WorkflowPlacement = union(enum) {
    cluster: output.Output([]const u8, .public),
    cluster_selector: ClusterSelector,
    managed_cluster: ManagedCluster,
};

pub const HadoopJob = struct { main_class: []const u8, jar_file_uris: []const []const u8 = &.{}, args: []const []const u8 = &.{} };
pub const SparkJob = struct { main_class: []const u8, jar_file_uris: []const []const u8 = &.{}, args: []const []const u8 = &.{} };
pub const PySparkJob = struct { main_python_file_uri: []const u8, python_file_uris: []const []const u8 = &.{}, jar_file_uris: []const []const u8 = &.{}, args: []const []const u8 = &.{} };
pub const PrestoJob = struct { query_file_uri: []const u8, client_tags: []const []const u8 = &.{} };
pub const WorkflowJobKind = union(enum) { hadoop: HadoopJob, spark: SparkJob, pyspark: PySparkJob, presto: PrestoJob };
pub const WorkflowJob = struct { id: []const u8, prerequisite_step_ids: []const []const u8 = &.{}, job: WorkflowJobKind };

pub const WorkflowTemplateArgs = struct {
    name: []const u8,
    region: []const u8,
    placement: WorkflowPlacement,
    jobs: []const WorkflowJob,
    dag_timeout_seconds: u32 = 0,
    labels: []const KeyValue = &.{},
    protect: bool = true,
    removal_policy: RemovalPolicy = .retain,
};

pub const WorkflowTemplate = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Version = output.Descriptor("version", u64, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    version: Outputs.Version.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: WorkflowTemplateArgs) BuildError!WorkflowTemplate {
        try provider.validate();
        try validateCommon(provider, args.name, args.region);
        if (args.jobs.len == 0 or args.jobs.len > 100) return error.InvalidJob;
        if (args.dag_timeout_seconds != 0 and (args.dag_timeout_seconds < 600 or args.dag_timeout_seconds > 86_400)) return error.InvalidTimeout;
        try validateDag(allocator, args.jobs);
        var placement = try placementValue(allocator, args.placement);
        defer placement.deinit(allocator);
        var jobs = try jobsValue(allocator, args.jobs);
        defer jobs.deinit(allocator);
        var labels = try mapValue(allocator, args.labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "dag_timeout_seconds", .value = .{ .integer = args.dag_timeout_seconds } },
            .{ .name = "jobs", .value = jobs },
            .{ .name = "labels", .value = labels },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "placement", .value = placement },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "region", .value = .{ .string = args.region } },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
        };
        const node = try nodeOwned(allocator, "gcp.dataproc.WorkflowTemplate", args.region, args.name, &fields, .{ .protect = args.protect, .retain_on_delete = args.removal_policy == .retain });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .version = Outputs.Version.fromResource(node.id) };
    }

    pub fn deinit(self: *WorkflowTemplate, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const IamCondition = struct { title: []const u8, expression: []const u8, description: []const u8 = "" };
pub const IamMemberArgs = struct { name: []const u8, resource: output.Output([]const u8, .public), role: []const u8, member: []const u8, condition: ?IamCondition = null };
pub const ClusterIamMember = iamMemberType("gcp.dataproc.ClusterIamMember", "/clusters/");
pub const AutoscalingPolicyIamMember = iamMemberType("gcp.dataproc.AutoscalingPolicyIamMember", "/autoscalingPolicies/");
pub const WorkflowTemplateIamMember = iamMemberType("gcp.dataproc.WorkflowTemplateIamMember", "/workflowTemplates/");

fn iamMemberType(comptime type_name: []const u8, comptime segment: []const u8) type {
    return struct {
        node: resource.ResourceNode,
        pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: IamMemberArgs) BuildError!@This() {
            try provider.validate();
            try validateName(args.name);
            try validateOutputContains(args.resource, segment);
            if (!std.mem.startsWith(u8, args.role, "roles/") or std.mem.indexOfScalar(u8, args.role, ' ') != null) return error.InvalidRole;
            if (!validMember(args.member)) return error.InvalidIamMember;
            var condition = if (args.condition) |selected| try conditionValue(allocator, selected) else try ownedValue(allocator, .{ .object = &.{} });
            defer condition.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "condition", .value = condition },
                .{ .name = "has_condition", .value = .{ .boolean = args.condition != null } },
                .{ .name = "member", .value = .{ .string = args.member } },
                .{ .name = "resource", .value = try outputValue(args.resource) },
                .{ .name = "role", .value = .{ .string = args.role } },
            };
            return .{ .node = try nodeOwned(allocator, type_name, "global", args.name, &fields, .{}) };
        }
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.node.deinit(allocator);
            self.* = undefined;
        }
    };
}

fn validateDag(allocator: std.mem.Allocator, jobs: []const WorkflowJob) BuildError!void {
    for (jobs, 0..) |job, index| {
        try validateName(job.id);
        for (jobs[0..index]) |prior| if (std.mem.eql(u8, prior.id, job.id)) return error.DuplicateJob;
        try validateJobKind(job.job);
        for (job.prerequisite_step_ids, 0..) |dependency, dep_index| {
            for (job.prerequisite_step_ids[0..dep_index]) |prior| if (std.mem.eql(u8, prior, dependency)) return error.DuplicateJob;
            if (findJob(jobs, dependency) == null) return error.MissingPrerequisite;
        }
    }
    const resolved = try allocator.alloc(bool, jobs.len);
    defer allocator.free(resolved);
    @memset(resolved, false);
    var count: usize = 0;
    while (count < jobs.len) {
        var progress = false;
        for (jobs, 0..) |job, index| {
            if (resolved[index]) continue;
            var ready = true;
            for (job.prerequisite_step_ids) |dependency| if (!resolved[findJob(jobs, dependency).?]) {
                ready = false;
                break;
            };
            if (ready) {
                resolved[index] = true;
                count += 1;
                progress = true;
            }
        }
        if (!progress) return error.CyclicWorkflow;
    }
}

fn findJob(jobs: []const WorkflowJob, id: []const u8) ?usize {
    for (jobs, 0..) |job, index| if (std.mem.eql(u8, job.id, id)) return index;
    return null;
}

fn validateJobKind(job: WorkflowJobKind) BuildError!void {
    switch (job) {
        .hadoop => |selected| if (selected.main_class.len == 0) return error.InvalidJob,
        .spark => |selected| if (selected.main_class.len == 0) return error.InvalidJob,
        .pyspark => |selected| if (!std.mem.startsWith(u8, selected.main_python_file_uri, "gs://")) return error.InvalidJob,
        .presto => |selected| if (!std.mem.startsWith(u8, selected.query_file_uri, "gs://")) return error.InvalidJob,
    }
}

fn jobsValue(allocator: std.mem.Allocator, jobs: []const WorkflowJob) BuildError!value.Value {
    const values = try allocator.alloc(value.Value, jobs.len);
    defer allocator.free(values);
    for (jobs, 0..) |job, index| {
        var dependencies = try stringsValue(allocator, job.prerequisite_step_ids);
        defer dependencies.deinit(allocator);
        var selected = try jobKindValue(allocator, job.job);
        defer selected.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "id", .value = .{ .string = job.id } },
            .{ .name = "job", .value = selected },
            .{ .name = "prerequisite_step_ids", .value = dependencies },
        };
        values[index] = try ownedValue(allocator, .{ .object = &fields });
    }
    defer for (values) |*selected| selected.deinit(allocator);
    return ownedValue(allocator, .{ .list = values });
}

fn jobKindValue(allocator: std.mem.Allocator, job: WorkflowJobKind) BuildError!value.Value {
    try validateJobKind(job);
    return switch (job) {
        .hadoop => |selected| classJobValue(allocator, "hadoop", selected.main_class, selected.jar_file_uris, selected.args),
        .spark => |selected| classJobValue(allocator, "spark", selected.main_class, selected.jar_file_uris, selected.args),
        .pyspark => |selected| blk: {
            var python = try stringsValue(allocator, selected.python_file_uris);
            defer python.deinit(allocator);
            var jars = try stringsValue(allocator, selected.jar_file_uris);
            defer jars.deinit(allocator);
            var args = try stringsValue(allocator, selected.args);
            defer args.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "args", .value = args },
                .{ .name = "jar_file_uris", .value = jars },
                .{ .name = "kind", .value = .{ .string = "pyspark" } },
                .{ .name = "main_python_file_uri", .value = .{ .string = selected.main_python_file_uri } },
                .{ .name = "python_file_uris", .value = python },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
        .presto => |selected| blk: {
            var tags = try stringsValue(allocator, selected.client_tags);
            defer tags.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "client_tags", .value = tags },
                .{ .name = "kind", .value = .{ .string = "presto" } },
                .{ .name = "query_file_uri", .value = .{ .string = selected.query_file_uri } },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
    };
}

fn classJobValue(allocator: std.mem.Allocator, kind: []const u8, main_class: []const u8, jars: []const []const u8, args: []const []const u8) BuildError!value.Value {
    var jar_values = try stringsValue(allocator, jars);
    defer jar_values.deinit(allocator);
    var arg_values = try stringsValue(allocator, args);
    defer arg_values.deinit(allocator);
    const fields = [_]value.Field{
        .{ .name = "args", .value = arg_values },
        .{ .name = "jar_file_uris", .value = jar_values },
        .{ .name = "kind", .value = .{ .string = kind } },
        .{ .name = "main_class", .value = .{ .string = main_class } },
    };
    return ownedValue(allocator, .{ .object = &fields });
}

fn placementValue(allocator: std.mem.Allocator, placement: WorkflowPlacement) BuildError!value.Value {
    return switch (placement) {
        .cluster => |selected| blk: {
            try validateOutputContains(selected, "/clusters/");
            const fields = [_]value.Field{ .{ .name = "cluster", .value = try outputValue(selected) }, .{ .name = "kind", .value = .{ .string = "cluster" } } };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
        .cluster_selector => |selected| blk: {
            if (selected.labels.len == 0) return error.InvalidCluster;
            var labels = try mapValue(allocator, selected.labels);
            defer labels.deinit(allocator);
            const fields = [_]value.Field{ .{ .name = "kind", .value = .{ .string = "cluster_selector" } }, .{ .name = "labels", .value = labels } };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
        .managed_cluster => |selected| blk: {
            try validateName(selected.name);
            try validateGroup(selected.master, false);
            try validateGroup(selected.worker, false);
            var master = try groupValue(allocator, selected.master);
            defer master.deinit(allocator);
            var worker = try groupValue(allocator, selected.worker);
            defer worker.deinit(allocator);
            var secondary = if (selected.secondary_worker) |group| try groupValue(allocator, group) else try ownedValue(allocator, .{ .object = &.{} });
            defer secondary.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "autoscaling_policy", .value = try optionalOutputValue(selected.autoscaling_policy) },
                .{ .name = "kind", .value = .{ .string = "managed_cluster" } },
                .{ .name = "master", .value = master },
                .{ .name = "name", .value = .{ .string = selected.name } },
                .{ .name = "secondary_worker", .value = secondary },
                .{ .name = "worker", .value = worker },
                .{ .name = "zone", .value = .{ .string = selected.zone } },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
    };
}

fn groupValue(allocator: std.mem.Allocator, group: InstanceGroup) BuildError!value.Value {
    try validateGroup(group, true);
    const fields = [_]value.Field{
        .{ .name = "disk_size_gb", .value = .{ .integer = group.disk_size_gb } },
        .{ .name = "disk_type", .value = .{ .string = group.disk_type } },
        .{ .name = "instances", .value = .{ .integer = group.instances } },
        .{ .name = "local_ssds", .value = .{ .integer = group.local_ssds } },
        .{ .name = "machine_type", .value = .{ .string = group.machine_type } },
        .{ .name = "preemptibility", .value = .{ .string = switch (group.preemptibility) {
            .non_preemptible => "NON_PREEMPTIBLE",
            .preemptible => "PREEMPTIBLE",
            .spot => "SPOT",
        } } },
    };
    return ownedValue(allocator, .{ .object = &fields });
}
fn boundsValue(allocator: std.mem.Allocator, bounds: InstanceBounds) BuildError!value.Value {
    const fields = [_]value.Field{
        .{ .name = "max_instances", .value = .{ .integer = bounds.max_instances } },
        .{ .name = "min_instances", .value = .{ .integer = bounds.min_instances } },
        .{ .name = "weight", .value = .{ .integer = bounds.weight } },
    };
    return ownedValue(allocator, .{ .object = &fields });
}
fn algorithmValue(allocator: std.mem.Allocator, algorithm: ScalingAlgorithm) BuildError!value.Value {
    return switch (algorithm) {
        .yarn => |selected| blk: {
            if (selected.graceful_decommission_timeout_seconds > 86_400 or !validFactor(selected.scale_up_factor) or !validFactor(selected.scale_down_factor) or !validFactor(selected.scale_up_min_worker_fraction) or !validFactor(selected.scale_down_min_worker_fraction)) return error.InvalidScaling;
            const scale_up = try std.fmt.allocPrint(allocator, "{d:.6}", .{selected.scale_up_factor});
            defer allocator.free(scale_up);
            const scale_down = try std.fmt.allocPrint(allocator, "{d:.6}", .{selected.scale_down_factor});
            defer allocator.free(scale_down);
            const scale_up_min = try std.fmt.allocPrint(allocator, "{d:.6}", .{selected.scale_up_min_worker_fraction});
            defer allocator.free(scale_up_min);
            const scale_down_min = try std.fmt.allocPrint(allocator, "{d:.6}", .{selected.scale_down_min_worker_fraction});
            defer allocator.free(scale_down_min);
            const fields = [_]value.Field{
                .{ .name = "graceful_decommission_timeout_seconds", .value = .{ .integer = selected.graceful_decommission_timeout_seconds } },
                .{ .name = "kind", .value = .{ .string = "yarn" } },
                .{ .name = "scale_down_factor", .value = .{ .string = scale_down } },
                .{ .name = "scale_down_min_worker_fraction", .value = .{ .string = scale_down_min } },
                .{ .name = "scale_up_factor", .value = .{ .string = scale_up } },
                .{ .name = "scale_up_min_worker_fraction", .value = .{ .string = scale_up_min } },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
    };
}

fn initActionsValue(allocator: std.mem.Allocator, actions: []const InitAction) BuildError!value.Value {
    const values = try allocator.alloc(value.Value, actions.len);
    defer allocator.free(values);
    for (actions, 0..) |action, index| {
        const fields = [_]value.Field{
            .{ .name = "executable_file", .value = .{ .string = action.executable_file } },
            .{ .name = "timeout_seconds", .value = .{ .integer = action.timeout_seconds } },
        };
        values[index] = try ownedValue(allocator, .{ .object = &fields });
    }
    defer for (values) |*selected| selected.deinit(allocator);
    return ownedValue(allocator, .{ .list = values });
}
fn conditionValue(allocator: std.mem.Allocator, condition: IamCondition) BuildError!value.Value {
    if (condition.title.len == 0 or condition.expression.len == 0) return error.InvalidIamMember;
    const fields = [_]value.Field{
        .{ .name = "description", .value = .{ .string = condition.description } },
        .{ .name = "expression", .value = .{ .string = condition.expression } },
        .{ .name = "title", .value = .{ .string = condition.title } },
    };
    return ownedValue(allocator, .{ .object = &fields });
}
fn mapValue(allocator: std.mem.Allocator, items: []const KeyValue) BuildError!value.Value {
    const fields = try allocator.alloc(value.Field, items.len);
    defer allocator.free(fields);
    for (items, 0..) |item, index| {
        if (item.key.len == 0 or item.value.len > 4096) return error.InvalidCluster;
        for (items[0..index]) |prior| if (std.mem.eql(u8, prior.key, item.key)) return error.DuplicateKey;
        fields[index] = .{ .name = item.key, .value = .{ .string = item.value } };
    }
    std.mem.sort(value.Field, fields, {}, lessField);
    return ownedValue(allocator, .{ .object = fields });
}
fn stringsValue(allocator: std.mem.Allocator, items: []const []const u8) BuildError!value.Value {
    const values = try allocator.alloc(value.Value, items.len);
    defer allocator.free(values);
    for (items, 0..) |item, index| values[index] = .{ .string = item };
    return ownedValue(allocator, .{ .list = values });
}
fn optionalOutputValue(selected: ?output.Output([]const u8, .public)) BuildError!value.Value {
    return if (selected) |known| outputValue(known) else .{ .string = "" };
}
fn outputValue(selected: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (selected) {
        .value => |text| .{ .string = text },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.InvalidOutput,
    };
}
fn validateOutputContains(selected: output.Output([]const u8, .public), segment: []const u8) BuildError!void {
    switch (selected) {
        .value => |text| if (std.mem.indexOf(u8, text, segment) == null) return error.InvalidOutput,
        .resource_ref => {},
        .unknown_reason => return error.InvalidOutput,
    }
}
fn validateBounds(bounds: InstanceBounds, allow_zero: bool) BuildError!void {
    if ((!allow_zero and bounds.min_instances == 0) or bounds.min_instances > bounds.max_instances or bounds.max_instances > 10_000 or bounds.weight == 0) return error.InvalidScaling;
}
fn validateGroup(group: InstanceGroup, allow_spot: bool) BuildError!void {
    if (group.machine_type.len == 0 or group.instances == 0 or group.instances > 10_000) return error.InvalidCluster;
    if (group.disk_size_gb < 10 or group.disk_size_gb > 65_536 or group.local_ssds > 8) return error.InvalidDisk;
    if (!allow_spot and group.preemptibility != .non_preemptible) return error.InvalidCluster;
}
fn validFactor(factor: f64) bool {
    return factor >= 0 and factor <= 1;
}
fn validateCommon(provider: config_mod.ProviderConfig, name: []const u8, region: []const u8) BuildError!void {
    try validateName(name);
    if (region.len == 0) return error.InvalidRegion;
    if (provider.service_regions.len == 0) {
        if (!std.mem.eql(u8, provider.primary_region, region)) return error.InvalidRegion;
        return;
    }
    for (provider.service_regions) |allowed| if (std.mem.eql(u8, allowed, region)) return;
    return error.InvalidRegion;
}
fn validateName(name: []const u8) BuildError!void {
    if (name.len == 0 or name.len > 63 or !std.ascii.isLower(name[0]) or !std.ascii.isAlphanumeric(name[name.len - 1])) return error.InvalidName;
    for (name) |char| if (!(std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '-' or char == '_')) return error.InvalidName;
}
fn validateServiceAccount(email: []const u8) BuildError!void {
    if (!std.mem.endsWith(u8, email, ".iam.gserviceaccount.com") or std.mem.indexOfScalar(u8, email, '@') == null) return error.InvalidServiceAccount;
}
fn validMember(member: []const u8) bool {
    inline for (.{ "user:", "group:", "serviceAccount:", "domain:" }) |prefix| if (std.mem.startsWith(u8, member, prefix) and member.len > prefix.len) return true;
    return std.mem.eql(u8, member, "allUsers") or std.mem.eql(u8, member, "allAuthenticatedUsers");
}
fn lessField(_: void, left: value.Field, right: value.Field) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}
fn ownedValue(allocator: std.mem.Allocator, selected: value.Value) BuildError!value.Value {
    return value.Value.initOwned(allocator, selected) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
    };
}
fn nodeOwned(allocator: std.mem.Allocator, type_name: []const u8, scope: []const u8, logical: []const u8, fields: []const value.Field, lifecycle: resource.Lifecycle) BuildError!resource.ResourceNode {
    const id = try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ type_name, scope, logical });
    defer allocator.free(id);
    return resource.ResourceNode.initOwned(allocator, .{ .id = id, .provider = .gcp, .type_name = type_name, .schema_version = 1, .logical_id = logical, .inputs = .{ .object = fields }, .lifecycle = lifecycle }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}
