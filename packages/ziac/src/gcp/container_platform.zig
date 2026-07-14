const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    DuplicateValue,
    InvalidAutoscaling,
    InvalidClusterLink,
    InvalidCidr,
    InvalidDigest,
    InvalidEnvironment,
    InvalidImage,
    InvalidLocation,
    InvalidName,
    InvalidParallelism,
    InvalidPrivateCluster,
    InvalidRole,
    InvalidSecret,
    InvalidSizing,
    InvalidTrigger,
    InvalidValue,
    InvalidWorkloadPool,
    OutputNotKnown,
};

pub const Label = struct { key: []const u8, value: []const u8 };
pub const EnvVar = struct { key: []const u8, value: []const u8 };
pub const AuthorizedNetwork = struct { name: []const u8, cidr: []const u8 };

pub const ClusterMode = enum {
    autopilot,
    standard,

    pub fn apiName(self: ClusterMode) []const u8 {
        return if (self == .autopilot) "AUTOPILOT" else "STANDARD";
    }
};

pub const ReleaseChannel = enum {
    rapid,
    regular,
    stable,
    extended,
    unspecified,

    pub fn apiName(self: ReleaseChannel) []const u8 {
        return switch (self) {
            .rapid => "RAPID",
            .regular => "REGULAR",
            .stable => "STABLE",
            .extended => "EXTENDED",
            .unspecified => "UNSPECIFIED",
        };
    }
};

pub const BinaryAuthorizationMode = enum {
    disabled,
    project_singleton_policy_enforce,

    pub fn apiName(self: BinaryAuthorizationMode) []const u8 {
        return if (self == .project_singleton_policy_enforce) "PROJECT_SINGLETON_POLICY_ENFORCE" else "DISABLED";
    }
};

pub const IpAllocation = struct {
    cluster_secondary_range: []const u8 = "",
    services_secondary_range: []const u8 = "",
};

pub const PrivateCluster = struct {
    private_nodes: bool = false,
    private_endpoint: bool = false,
    master_ipv4_cidr: []const u8 = "",
    authorized_networks: []const AuthorizedNetwork = &.{},
};

pub const ClusterArgs = struct {
    name: []const u8,
    location: []const u8,
    mode: ClusterMode,
    network: output.Output([]const u8, .public),
    subnetwork: output.Output([]const u8, .public),
    description: []const u8 = "",
    release_channel: ReleaseChannel = .regular,
    workload_pool: []const u8 = "",
    ip_allocation: IpAllocation = .{},
    private_cluster: PrivateCluster = .{},
    binary_authorization: BinaryAuthorizationMode = .disabled,
    logging_components: []const []const u8 = &.{"SYSTEM_COMPONENTS"},
    monitoring_components: []const []const u8 = &.{"SYSTEM_COMPONENTS"},
    labels: []const Label = &.{},
    deletion_protection: bool = true,
};

pub const Cluster = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Endpoint = output.Descriptor("endpoint", []const u8, .public);
        pub const Status = output.Descriptor("status", []const u8, .public);
        pub const WorkloadPool = output.Descriptor("workload_pool", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    endpoint: Outputs.Endpoint.OutputType,
    status: Outputs.Status.OutputType,
    workload_pool: Outputs.WorkloadPool.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ClusterArgs) BuildError!Cluster {
        try provider.validate();
        try validateName(args.name);
        try validateLocation(args.location);
        try validatePrivateCluster(args.private_cluster);
        const expected_pool = try std.fmt.allocPrint(allocator, "{s}.svc.id.goog", .{provider.project_id});
        defer allocator.free(expected_pool);
        const workload_pool = if (args.workload_pool.len == 0) expected_pool else args.workload_pool;
        if (!std.mem.eql(u8, workload_pool, expected_pool)) return error.InvalidWorkloadPool;
        if ((args.ip_allocation.cluster_secondary_range.len == 0) != (args.ip_allocation.services_secondary_range.len == 0)) return error.InvalidValue;

        var networks = try authorizedNetworksValueOwned(allocator, args.private_cluster.authorized_networks);
        defer networks.deinit(allocator);
        var logging = try stringListValueOwned(allocator, args.logging_components);
        defer logging.deinit(allocator);
        var monitoring = try stringListValueOwned(allocator, args.monitoring_components);
        defer monitoring.deinit(allocator);
        var labels = try labelsValueOwned(allocator, args.labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "authorized_networks", .value = networks },
            .{ .name = "binary_authorization", .value = .{ .string = args.binary_authorization.apiName() } },
            .{ .name = "cluster_secondary_range", .value = .{ .string = args.ip_allocation.cluster_secondary_range } },
            .{ .name = "deletion_protection", .value = .{ .boolean = args.deletion_protection } },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "logging_components", .value = logging },
            .{ .name = "master_ipv4_cidr", .value = .{ .string = args.private_cluster.master_ipv4_cidr } },
            .{ .name = "mode", .value = .{ .string = args.mode.apiName() } },
            .{ .name = "monitoring_components", .value = monitoring },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "network", .value = try publicOutputValue(args.network) },
            .{ .name = "private_endpoint", .value = .{ .boolean = args.private_cluster.private_endpoint } },
            .{ .name = "private_nodes", .value = .{ .boolean = args.private_cluster.private_nodes } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "release_channel", .value = .{ .string = args.release_channel.apiName() } },
            .{ .name = "services_secondary_range", .value = .{ .string = args.ip_allocation.services_secondary_range } },
            .{ .name = "subnetwork", .value = try publicOutputValue(args.subnetwork) },
            .{ .name = "workload_pool", .value = .{ .string = workload_pool } },
        };
        const logical_id = try locationIdAlloc(allocator, args.location, args.name);
        defer allocator.free(logical_id);
        const node = try nodeOwned(allocator, "gcp.container.Cluster", logical_id, args.name, &fields, .{ .protect = args.deletion_protection });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .endpoint = Outputs.Endpoint.fromResource(node.id),
            .status = Outputs.Status.fromResource(node.id),
            .workload_pool = Outputs.WorkloadPool.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Cluster, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const NodePoolAutoscaling = struct {
    min_nodes: u32,
    max_nodes: u32,
    total_min_nodes: u32 = 0,
    total_max_nodes: u32 = 0,
};

pub const NodePoolArgs = struct {
    name: []const u8,
    location: []const u8,
    cluster_name: []const u8,
    cluster: output.Output([]const u8, .public),
    machine_type: []const u8,
    disk_type: []const u8 = "pd-balanced",
    disk_size_gb: u32 = 100,
    image_type: []const u8 = "COS_CONTAINERD",
    service_account: output.Output([]const u8, .public),
    oauth_scopes: []const []const u8 = &.{"https://www.googleapis.com/auth/cloud-platform"},
    locations: []const []const u8 = &.{},
    node_count: u32 = 1,
    autoscaling: ?NodePoolAutoscaling = null,
    auto_repair: bool = true,
    auto_upgrade: bool = true,
    spot: bool = false,
    labels: []const Label = &.{},
    protect: bool = false,
};

pub const NodePool = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Status = output.Descriptor("status", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    status: Outputs.Status.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: NodePoolArgs) BuildError!NodePool {
        try provider.validate();
        try validateName(args.name);
        try validateName(args.cluster_name);
        try validateLocation(args.location);
        if (args.machine_type.len == 0 or args.disk_size_gb < 10 or args.node_count == 0) return error.InvalidSizing;
        const scaling = args.autoscaling orelse NodePoolAutoscaling{ .min_nodes = 0, .max_nodes = 0 };
        if (args.autoscaling != null and (scaling.min_nodes > scaling.max_nodes or scaling.max_nodes == 0 or
            ((scaling.total_min_nodes == 0) != (scaling.total_max_nodes == 0)) or scaling.total_min_nodes > scaling.total_max_nodes)) return error.InvalidAutoscaling;
        var scopes = try stringListValueOwned(allocator, args.oauth_scopes);
        defer scopes.deinit(allocator);
        var locations = try stringListValueOwned(allocator, args.locations);
        defer locations.deinit(allocator);
        var labels = try labelsValueOwned(allocator, args.labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "auto_repair", .value = .{ .boolean = args.auto_repair } },
            .{ .name = "auto_upgrade", .value = .{ .boolean = args.auto_upgrade } },
            .{ .name = "autoscaling_enabled", .value = .{ .boolean = args.autoscaling != null } },
            .{ .name = "cluster", .value = try publicOutputValue(args.cluster) },
            .{ .name = "cluster_name", .value = .{ .string = args.cluster_name } },
            .{ .name = "disk_size_gb", .value = .{ .integer = args.disk_size_gb } },
            .{ .name = "disk_type", .value = .{ .string = args.disk_type } },
            .{ .name = "image_type", .value = .{ .string = args.image_type } },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "locations", .value = locations },
            .{ .name = "machine_type", .value = .{ .string = args.machine_type } },
            .{ .name = "max_nodes", .value = .{ .integer = scaling.max_nodes } },
            .{ .name = "min_nodes", .value = .{ .integer = scaling.min_nodes } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "node_count", .value = .{ .integer = args.node_count } },
            .{ .name = "oauth_scopes", .value = scopes },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "service_account", .value = try publicOutputValue(args.service_account) },
            .{ .name = "spot", .value = .{ .boolean = args.spot } },
            .{ .name = "total_max_nodes", .value = .{ .integer = scaling.total_max_nodes } },
            .{ .name = "total_min_nodes", .value = .{ .integer = scaling.total_min_nodes } },
        };
        const logical_id = try parentIdAlloc(allocator, args.location, args.cluster_name, args.name);
        defer allocator.free(logical_id);
        const node = try nodeOwned(allocator, "gcp.container.NodePool", logical_id, args.name, &fields, .{ .protect = args.protect });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .status = Outputs.Status.fromResource(node.id) };
    }

    pub fn deinit(self: *NodePool, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const FleetArgs = struct {
    name: []const u8 = "default",
    display_name: []const u8 = "",
    labels: []const Label = &.{},
    protect: bool = false,
};

pub const Fleet = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Uid = output.Descriptor("uid", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    uid: Outputs.Uid.OutputType,
    state: Outputs.State.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: FleetArgs) BuildError!Fleet {
        try provider.validate();
        try validateName(args.name);
        var labels = try labelsValueOwned(allocator, args.labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "labels", .value = labels },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        };
        const node = try nodeOwned(allocator, "gcp.gkehub.Fleet", args.name, args.name, &fields, .{ .protect = args.protect });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .uid = Outputs.Uid.fromResource(node.id), .state = Outputs.State.fromResource(node.id) };
    }

    pub fn deinit(self: *Fleet, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const MembershipArgs = struct {
    name: []const u8,
    location: []const u8 = "global",
    cluster: output.Output([]const u8, .public),
    description: []const u8 = "",
    labels: []const Label = &.{},
    protect: bool = false,
};

pub const Membership = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
        pub const UniqueId = output.Descriptor("unique_id", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    state: Outputs.State.OutputType,
    unique_id: Outputs.UniqueId.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: MembershipArgs) BuildError!Membership {
        try provider.validate();
        try validateName(args.name);
        try validateLocation(args.location);
        switch (args.cluster) {
            .value => |link| if (!validClusterLink(link)) return error.InvalidClusterLink,
            .resource_ref => {},
            .unknown_reason => return error.OutputNotKnown,
        }
        var labels = try labelsValueOwned(allocator, args.labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "cluster", .value = try publicOutputValue(args.cluster) },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        };
        const logical_id = try locationIdAlloc(allocator, args.location, args.name);
        defer allocator.free(logical_id);
        const node = try nodeOwned(allocator, "gcp.gkehub.Membership", logical_id, args.name, &fields, .{ .protect = args.protect });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .state = Outputs.State.fromResource(node.id), .unique_id = Outputs.UniqueId.fromResource(node.id) };
    }

    pub fn deinit(self: *Membership, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const StorageSource = struct { bucket: []const u8, object: []const u8, generation: u64 = 0 };
pub const EventFilter = struct { key: []const u8, value: []const u8 };
pub const EventarcTrigger = struct {
    event_type: []const u8,
    region: []const u8,
    filters: []const EventFilter = &.{},
    pubsub_topic: output.Output([]const u8, .public) = .{ .value = "" },
    service_account: output.Output([]const u8, .public),
    retry: bool = true,
};
pub const FunctionTrigger = union(enum) { http: void, eventarc: EventarcTrigger };
pub const SecretEnvVar = struct { key: []const u8, project_id: []const u8, secret: []const u8, version: []const u8 };
pub const FunctionIngress = enum {
    all,
    internal_only,
    internal_and_gclb,

    pub fn apiName(self: FunctionIngress) []const u8 {
        return switch (self) {
            .all => "ALLOW_ALL",
            .internal_only => "ALLOW_INTERNAL_ONLY",
            .internal_and_gclb => "ALLOW_INTERNAL_AND_GCLB",
        };
    }
};

pub const FunctionV2Args = struct {
    name: []const u8,
    location: []const u8,
    runtime: []const u8,
    entry_point: []const u8,
    source: StorageSource,
    trigger: FunctionTrigger = .{ .http = {} },
    service_account: output.Output([]const u8, .public),
    build_service_account: output.Output([]const u8, .public),
    environment: []const EnvVar = &.{},
    secret_environment: []const SecretEnvVar = &.{},
    available_memory: []const u8 = "256Mi",
    available_cpu: []const u8 = "1",
    timeout_seconds: u32 = 60,
    min_instances: u32 = 0,
    max_instances: u32 = 100,
    max_concurrency: u32 = 1,
    ingress: FunctionIngress = .all,
    vpc_connector: output.Output([]const u8, .public) = .{ .value = "" },
    vpc_egress: []const u8 = "PRIVATE_RANGES_ONLY",
    kms_key: output.Output([]const u8, .public) = .{ .value = "" },
    labels: []const Label = &.{},
    protect: bool = false,
};

pub const FunctionV2 = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Url = output.Descriptor("url", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
        pub const Service = output.Descriptor("service", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    url: Outputs.Url.OutputType,
    state: Outputs.State.OutputType,
    service: Outputs.Service.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: FunctionV2Args) BuildError!FunctionV2 {
        try provider.validate();
        try validateName(args.name);
        try validateLocation(args.location);
        if (args.runtime.len == 0 or args.entry_point.len == 0 or args.source.bucket.len == 0 or args.source.object.len == 0) return error.InvalidValue;
        if (args.timeout_seconds == 0 or args.max_instances == 0 or args.min_instances > args.max_instances or args.max_concurrency == 0) return error.InvalidSizing;
        var env = try envValueOwned(allocator, args.environment);
        defer env.deinit(allocator);
        var secrets = try secretEnvValueOwned(allocator, args.secret_environment);
        defer secrets.deinit(allocator);
        var labels = try labelsValueOwned(allocator, args.labels);
        defer labels.deinit(allocator);
        var filters = try ownedValue(allocator, .{ .object = &.{} });
        defer filters.deinit(allocator);
        var trigger_kind: []const u8 = undefined;
        var event_type: []const u8 = "";
        var trigger_region: []const u8 = "";
        var trigger_service_account: value.Value = .{ .string = "" };
        var pubsub_topic: value.Value = .{ .string = "" };
        var retry = false;
        switch (args.trigger) {
            .http => trigger_kind = "HTTP",
            .eventarc => |trigger| {
                if (trigger.event_type.len == 0 or trigger.region.len == 0) return error.InvalidTrigger;
                filters.deinit(allocator);
                filters = try eventFiltersValueOwned(allocator, trigger.filters);
                trigger_kind = "EVENTARC";
                event_type = trigger.event_type;
                trigger_region = trigger.region;
                trigger_service_account = try publicOutputValue(trigger.service_account);
                pubsub_topic = try publicOutputValue(trigger.pubsub_topic);
                retry = trigger.retry;
            },
        }
        const fields = [_]value.Field{
            .{ .name = "available_cpu", .value = .{ .string = args.available_cpu } },
            .{ .name = "available_memory", .value = .{ .string = args.available_memory } },
            .{ .name = "build_service_account", .value = try publicOutputValue(args.build_service_account) },
            .{ .name = "entry_point", .value = .{ .string = args.entry_point } },
            .{ .name = "environment", .value = env },
            .{ .name = "event_filters", .value = filters },
            .{ .name = "event_type", .value = .{ .string = event_type } },
            .{ .name = "ingress", .value = .{ .string = args.ingress.apiName() } },
            .{ .name = "kms_key", .value = try publicOutputValue(args.kms_key) },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "max_concurrency", .value = .{ .integer = args.max_concurrency } },
            .{ .name = "max_instances", .value = .{ .integer = args.max_instances } },
            .{ .name = "min_instances", .value = .{ .integer = args.min_instances } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "pubsub_topic", .value = pubsub_topic },
            .{ .name = "retry", .value = .{ .boolean = retry } },
            .{ .name = "runtime", .value = .{ .string = args.runtime } },
            .{ .name = "secret_environment", .value = secrets },
            .{ .name = "service_account", .value = try publicOutputValue(args.service_account) },
            .{ .name = "source_bucket", .value = .{ .string = args.source.bucket } },
            .{ .name = "source_generation", .value = .{ .integer = @intCast(args.source.generation) } },
            .{ .name = "source_object", .value = .{ .string = args.source.object } },
            .{ .name = "timeout_seconds", .value = .{ .integer = args.timeout_seconds } },
            .{ .name = "trigger_kind", .value = .{ .string = trigger_kind } },
            .{ .name = "trigger_region", .value = .{ .string = trigger_region } },
            .{ .name = "trigger_service_account", .value = trigger_service_account },
            .{ .name = "vpc_connector", .value = try publicOutputValue(args.vpc_connector) },
            .{ .name = "vpc_egress", .value = .{ .string = args.vpc_egress } },
        };
        const logical_id = try locationIdAlloc(allocator, args.location, args.name);
        defer allocator.free(logical_id);
        const node = try nodeOwned(allocator, "gcp.functions.FunctionV2", logical_id, args.name, &fields, .{ .protect = args.protect });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .url = Outputs.Url.fromResource(node.id), .state = Outputs.State.fromResource(node.id), .service = Outputs.Service.fromResource(node.id) };
    }

    pub fn deinit(self: *FunctionV2, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const FunctionIamMemberArgs = struct {
    name: []const u8,
    location: []const u8,
    function_name: []const u8,
    function: output.Output([]const u8, .public),
    role: []const u8,
    member: []const u8,
};

pub const FunctionIamMember = struct {
    pub const Outputs = struct {
        pub const Etag = output.Descriptor("etag", []const u8, .public);
    };
    node: resource.ResourceNode,
    etag: Outputs.Etag.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: FunctionIamMemberArgs) BuildError!FunctionIamMember {
        try provider.validate();
        try validateName(args.name);
        try validateName(args.function_name);
        try validateLocation(args.location);
        if (!std.mem.eql(u8, args.role, "roles/run.invoker") and !std.mem.eql(u8, args.role, "roles/cloudfunctions.invoker")) return error.InvalidRole;
        if (!validPrincipal(args.member)) return error.InvalidValue;
        const fields = [_]value.Field{
            .{ .name = "function", .value = try publicOutputValue(args.function) },
            .{ .name = "function_name", .value = .{ .string = args.function_name } },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "member", .value = .{ .string = args.member } },
            .{ .name = "ownership_mode", .value = .{ .string = "member" } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "role", .value = .{ .string = args.role } },
        };
        const node = try nodeOwned(allocator, "gcp.functions.FunctionIamMember", args.name, args.name, &fields, .{});
        return .{ .node = node, .etag = Outputs.Etag.fromResource(node.id) };
    }

    pub fn deinit(self: *FunctionIamMember, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const BatchSecretEnvVar = struct { key: []const u8, secret_version: []const u8 };
pub const ProvisioningModel = enum {
    standard,
    spot,
    preemptible,

    pub fn apiName(self: ProvisioningModel) []const u8 {
        return switch (self) {
            .standard => "STANDARD",
            .spot => "SPOT",
            .preemptible => "PREEMPTIBLE",
        };
    }
};
pub const BatchLogs = enum {
    disabled,
    cloud_logging,

    pub fn apiName(self: BatchLogs) []const u8 {
        return if (self == .cloud_logging) "CLOUD_LOGGING" else "DESTINATION_UNSPECIFIED";
    }
};

pub const BatchJobArgs = struct {
    name: []const u8,
    location: []const u8,
    image: []const u8,
    commands: []const []const u8 = &.{},
    environment: []const EnvVar = &.{},
    secret_environment: []const BatchSecretEnvVar = &.{},
    task_count: u32 = 1,
    parallelism: u32 = 1,
    max_retry_count: u32 = 0,
    max_run_seconds: u32 = 3600,
    machine_type: []const u8 = "e2-standard-2",
    provisioning_model: ProvisioningModel = .standard,
    service_account: output.Output([]const u8, .public),
    network: output.Output([]const u8, .public) = .{ .value = "" },
    subnetwork: output.Output([]const u8, .public) = .{ .value = "" },
    logs: BatchLogs = .cloud_logging,
    priority: u8 = 0,
    labels: []const Label = &.{},
    protect: bool = false,
};

pub const BatchJob = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Uid = output.Descriptor("uid", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    uid: Outputs.Uid.OutputType,
    state: Outputs.State.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: BatchJobArgs) BuildError!BatchJob {
        try provider.validate();
        try validateName(args.name);
        try validateLocation(args.location);
        if (!validDigestImage(args.image)) return error.InvalidDigest;
        if (args.task_count == 0 or args.parallelism == 0 or args.parallelism > args.task_count) return error.InvalidParallelism;
        if (args.machine_type.len == 0 or args.max_run_seconds == 0 or args.priority > 100) return error.InvalidSizing;
        var commands = try stringListValueOwned(allocator, args.commands);
        defer commands.deinit(allocator);
        var env = try envValueOwned(allocator, args.environment);
        defer env.deinit(allocator);
        var secrets = try batchSecretEnvValueOwned(allocator, args.secret_environment);
        defer secrets.deinit(allocator);
        var labels = try labelsValueOwned(allocator, args.labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "commands", .value = commands },
            .{ .name = "environment", .value = env },
            .{ .name = "image", .value = .{ .string = args.image } },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "logs", .value = .{ .string = args.logs.apiName() } },
            .{ .name = "machine_type", .value = .{ .string = args.machine_type } },
            .{ .name = "max_retry_count", .value = .{ .integer = args.max_retry_count } },
            .{ .name = "max_run_seconds", .value = .{ .integer = args.max_run_seconds } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "network", .value = try publicOutputValue(args.network) },
            .{ .name = "parallelism", .value = .{ .integer = args.parallelism } },
            .{ .name = "priority", .value = .{ .integer = args.priority } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "provisioning_model", .value = .{ .string = args.provisioning_model.apiName() } },
            .{ .name = "secret_environment", .value = secrets },
            .{ .name = "service_account", .value = try publicOutputValue(args.service_account) },
            .{ .name = "subnetwork", .value = try publicOutputValue(args.subnetwork) },
            .{ .name = "task_count", .value = .{ .integer = args.task_count } },
        };
        const logical_id = try locationIdAlloc(allocator, args.location, args.name);
        defer allocator.free(logical_id);
        const node = try nodeOwned(allocator, "gcp.batch.Job", logical_id, args.name, &fields, .{ .protect = args.protect, .replace_before_delete = true });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .uid = Outputs.Uid.fromResource(node.id), .state = Outputs.State.fromResource(node.id) };
    }

    pub fn deinit(self: *BatchJob, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn nodeOwned(allocator: std.mem.Allocator, type_name: []const u8, logical_id: []const u8, name: []const u8, fields: []const value.Field, lifecycle: resource.Lifecycle) BuildError!resource.ResourceNode {
    const id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_name, logical_id });
    defer allocator.free(id);
    return resource.ResourceNode.initOwned(allocator, .{
        .id = id,
        .provider = .gcp,
        .type_name = type_name,
        .logical_id = name,
        .inputs = .{ .object = fields },
        .lifecycle = lifecycle,
    }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
    };
}

fn labelsValueOwned(allocator: std.mem.Allocator, labels: []const Label) BuildError!value.Value {
    const fields = try allocator.alloc(value.Field, labels.len);
    defer allocator.free(fields);
    for (labels, 0..) |label, index| {
        try validateKeyValue(label.key, label.value);
        fields[index] = .{ .name = label.key, .value = .{ .string = label.value } };
    }
    return ownedValue(allocator, .{ .object = fields }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateValue,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn envValueOwned(allocator: std.mem.Allocator, env: []const EnvVar) BuildError!value.Value {
    const fields = try allocator.alloc(value.Field, env.len);
    defer allocator.free(fields);
    for (env, 0..) |entry, index| {
        if (!validEnvKey(entry.key)) return error.InvalidEnvironment;
        fields[index] = .{ .name = entry.key, .value = .{ .string = entry.value } };
    }
    return ownedValue(allocator, .{ .object = fields }) catch |err| switch (err) {
        error.DuplicateField => error.InvalidEnvironment,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn secretEnvValueOwned(allocator: std.mem.Allocator, env: []const SecretEnvVar) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, env.len);
    defer allocator.free(items);
    for (env, 0..) |entry, index| {
        if (!validEnvKey(entry.key) or entry.project_id.len == 0 or entry.secret.len == 0 or entry.version.len == 0) return error.InvalidSecret;
        const fields = [_]value.Field{
            .{ .name = "key", .value = .{ .string = entry.key } },
            .{ .name = "project_id", .value = .{ .string = entry.project_id } },
            .{ .name = "secret", .value = .{ .string = entry.secret } },
            .{ .name = "version", .value = .{ .string = entry.version } },
        };
        items[index] = .{ .object = &fields };
    }
    return ownedValue(allocator, .{ .list = items });
}

fn batchSecretEnvValueOwned(allocator: std.mem.Allocator, env: []const BatchSecretEnvVar) BuildError!value.Value {
    const fields = try allocator.alloc(value.Field, env.len);
    defer allocator.free(fields);
    for (env, 0..) |entry, index| {
        if (!validEnvKey(entry.key) or !std.mem.startsWith(u8, entry.secret_version, "projects/") or std.mem.indexOf(u8, entry.secret_version, "/secrets/") == null or std.mem.indexOf(u8, entry.secret_version, "/versions/") == null) return error.InvalidSecret;
        fields[index] = .{ .name = entry.key, .value = .{ .string = entry.secret_version } };
    }
    return ownedValue(allocator, .{ .object = fields }) catch |err| switch (err) {
        error.DuplicateField => error.InvalidEnvironment,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn authorizedNetworksValueOwned(allocator: std.mem.Allocator, networks: []const AuthorizedNetwork) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, networks.len);
    defer allocator.free(items);
    for (networks, 0..) |network, index| {
        if (network.name.len == 0 or !validCidr(network.cidr)) return error.InvalidCidr;
        const fields = [_]value.Field{
            .{ .name = "cidr", .value = .{ .string = network.cidr } },
            .{ .name = "name", .value = .{ .string = network.name } },
        };
        items[index] = .{ .object = &fields };
    }
    return ownedValue(allocator, .{ .list = items });
}

fn eventFiltersValueOwned(allocator: std.mem.Allocator, filters: []const EventFilter) BuildError!value.Value {
    const fields = try allocator.alloc(value.Field, filters.len);
    defer allocator.free(fields);
    for (filters, 0..) |filter, index| {
        if (filter.key.len == 0 or filter.value.len == 0) return error.InvalidTrigger;
        fields[index] = .{ .name = filter.key, .value = .{ .string = filter.value } };
    }
    return ownedValue(allocator, .{ .object = fields }) catch |err| switch (err) {
        error.DuplicateField => error.InvalidTrigger,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn stringListValueOwned(allocator: std.mem.Allocator, strings: []const []const u8) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, strings.len);
    defer allocator.free(items);
    for (strings, 0..) |string, index| {
        if (string.len == 0) return error.InvalidValue;
        items[index] = .{ .string = string };
    }
    return ownedValue(allocator, .{ .list = items });
}

fn ownedValue(allocator: std.mem.Allocator, source: value.Value) (std.mem.Allocator.Error || error{DuplicateField})!value.Value {
    return value.Value.initOwned(allocator, source);
}

fn publicOutputValue(result: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (result) {
        .value => |known| .{ .string = known },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn locationIdAlloc(allocator: std.mem.Allocator, location: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ location, name });
}

fn parentIdAlloc(allocator: std.mem.Allocator, location: []const u8, parent: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ location, parent, name });
}

fn validateName(name: []const u8) BuildError!void {
    if (name.len == 0 or name.len > 63 or !std.ascii.isLower(name[0])) return error.InvalidName;
    if (!std.ascii.isLower(name[name.len - 1]) and !std.ascii.isDigit(name[name.len - 1])) return error.InvalidName;
    for (name) |byte| if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '-') return error.InvalidName;
}

fn validateLocation(location: []const u8) BuildError!void {
    if (std.mem.eql(u8, location, "global")) return;
    validateName(location) catch return error.InvalidLocation;
}

fn validatePrivateCluster(config: PrivateCluster) BuildError!void {
    if (config.private_endpoint and (!config.private_nodes or config.master_ipv4_cidr.len == 0)) return error.InvalidPrivateCluster;
    if (config.master_ipv4_cidr.len > 0 and !validCidr(config.master_ipv4_cidr)) return error.InvalidPrivateCluster;
    if (config.private_endpoint and config.authorized_networks.len > 0) return error.InvalidPrivateCluster;
}

fn validateKeyValue(key: []const u8, text: []const u8) BuildError!void {
    if (key.len == 0 or key.len > 63 or text.len > 63) return error.InvalidValue;
    for (key) |byte| if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '_' and byte != '-') return error.InvalidValue;
}

fn validEnvKey(key: []const u8) bool {
    if (key.len == 0 or (!std.ascii.isAlphabetic(key[0]) and key[0] != '_')) return false;
    for (key) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}

fn validCidr(cidr: []const u8) bool {
    const slash = std.mem.lastIndexOfScalar(u8, cidr, '/') orelse return false;
    if (slash == 0 or slash + 1 == cidr.len) return false;
    if (!validIpv4(cidr[0..slash])) return false;
    const prefix = std.fmt.parseInt(u8, cidr[slash + 1 ..], 10) catch return false;
    return prefix <= 32;
}

fn validIpv4(address: []const u8) bool {
    var parts = std.mem.splitScalar(u8, address, '.');
    var count: usize = 0;
    while (parts.next()) |part| : (count += 1) {
        if (part.len == 0) return false;
        _ = std.fmt.parseInt(u8, part, 10) catch return false;
    }
    return count == 4;
}

fn validClusterLink(link: []const u8) bool {
    return std.mem.startsWith(u8, link, "//container.googleapis.com/projects/") and
        std.mem.indexOf(u8, link, "/locations/") != null and std.mem.indexOf(u8, link, "/clusters/") != null;
}

fn validDigestImage(image: []const u8) bool {
    const marker = "@sha256:";
    const start = std.mem.indexOf(u8, image, marker) orelse return false;
    const digest = image[start + marker.len ..];
    if (digest.len != 64) return false;
    for (digest) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    return true;
}

fn validPrincipal(principal: []const u8) bool {
    if (std.mem.eql(u8, principal, "allUsers") or std.mem.eql(u8, principal, "allAuthenticatedUsers")) return true;
    inline for (&.{ "user:", "group:", "serviceAccount:", "domain:", "principal://iam.googleapis.com/", "principalSet://iam.googleapis.com/" }) |prefix| {
        if (std.mem.startsWith(u8, principal, prefix) and principal.len > prefix.len) return true;
    }
    return false;
}
