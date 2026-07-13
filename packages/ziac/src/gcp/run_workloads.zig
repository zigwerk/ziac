const std = @import("std");
const cloud_run = @import("cloud_run.zig");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    ConflictingOutput,
    DuplicateContainer,
    DuplicateEnvVar,
    DuplicateField,
    DuplicateLabel,
    InvalidContainer,
    InvalidEncryptionKey,
    InvalidGpu,
    InvalidIamCondition,
    InvalidInstanceSplits,
    InvalidMember,
    InvalidName,
    InvalidParallelism,
    InvalidResources,
    InvalidResourceName,
    InvalidRole,
    InvalidRetries,
    InvalidScaling,
    InvalidSecretVolume,
    InvalidServiceAccount,
    InvalidTimeout,
    InvalidVpcAccess,
    MissingContainer,
    MissingImage,
    OutputNotKnown,
};

pub const ExecutionEnvironment = enum {
    default,
    gen1,
    gen2,

    pub fn apiName(self: ExecutionEnvironment) []const u8 {
        return switch (self) {
            .default => "EXECUTION_ENVIRONMENT_UNSPECIFIED",
            .gen1 => "EXECUTION_ENVIRONMENT_GEN1",
            .gen2 => "EXECUTION_ENVIRONMENT_GEN2",
        };
    }
};

pub const Container = struct {
    name: []const u8,
    image: []const u8 = "",
    image_output: ?output.Output([]const u8, .public) = null,
    command: []const []const u8 = &.{},
    args: []const []const u8 = &.{},
    cpu: []const u8 = "1",
    memory: []const u8 = "512Mi",
    env: []const cloud_run.EnvVar = &.{},
};

pub const SecretVolume = struct {
    name: []const u8,
    secret: []const u8,
    version: []const u8 = "latest",
    path: []const u8,
    mount_path: []const u8,
    container: []const u8 = "",
};

pub const JobArgs = struct {
    name: []const u8,
    region: ?[]const u8 = null,
    containers: []const Container,
    task_count: u32 = 1,
    parallelism: u32 = 0,
    max_retries: i32 = 3,
    timeout_seconds: u32 = 600,
    service_account: ?[]const u8 = null,
    execution_environment: ExecutionEnvironment = .default,
    secret_volumes: []const SecretVolume = &.{},
    direct_vpc: ?cloud_run.DirectVpc = null,
    encryption_key: []const u8 = "",
    gpu_accelerator: []const u8 = "",
    gpu_zonal_redundancy_disabled: bool = false,
    labels: []const config_mod.Label = &.{},
    annotations: []const config_mod.Label = &.{},
    retain_on_delete: bool = true,
};

pub const Job = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Uid = output.Descriptor("uid", []const u8, .public);
        pub const ExecutionCount = output.Descriptor("execution_count", i64, .public);
        pub const LatestExecution = output.Descriptor("latest_execution", []const u8, .public);
        pub const Ready = output.Descriptor("ready", bool, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    uid: Outputs.Uid.OutputType,
    execution_count: Outputs.ExecutionCount.OutputType,
    latest_execution: Outputs.LatestExecution.OutputType,
    ready: Outputs.Ready.OutputType,
    etag: Outputs.Etag.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: JobArgs) BuildError!Job {
        try provider.validate();
        try validateResourceName(args.name, 63);
        const region = args.region orelse provider.primary_region;
        try validateRegion(region);
        try validateContainers(args.containers);
        if (args.task_count == 0) return error.InvalidParallelism;
        if (args.parallelism > args.task_count) return error.InvalidParallelism;
        if (args.max_retries < 0) return error.InvalidRetries;
        if (args.timeout_seconds == 0 or args.timeout_seconds > 24 * 60 * 60) return error.InvalidTimeout;
        const service_account = args.service_account orelse provider.service_account orelse "default";
        if (!std.mem.eql(u8, service_account, "default") and !validServiceAccount(service_account, provider.project_id)) return error.InvalidServiceAccount;
        try validateWorkloadControls(provider.project_id, args.containers, args.secret_volumes, args.direct_vpc, args.encryption_key, args.gpu_accelerator, args.gpu_zonal_redundancy_disabled);

        const containers = try containerValuesAlloc(allocator, args.containers);
        defer deinitValues(allocator, containers);
        const volumes = try volumeValuesAlloc(allocator, args.secret_volumes);
        defer deinitValues(allocator, volumes);
        var vpc = try vpcValueOwned(allocator, args.direct_vpc);
        defer vpc.deinit(allocator);
        var labels = try metadataValueOwned(allocator, provider.labels, args.labels);
        defer labels.deinit(allocator);
        var annotations = try metadataValueOwned(allocator, &.{}, args.annotations);
        defer annotations.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "annotations", .value = annotations },
            .{ .name = "containers", .value = .{ .list = containers } },
            .{ .name = "encryption_key", .value = .{ .string = args.encryption_key } },
            .{ .name = "execution_environment", .value = .{ .string = args.execution_environment.apiName() } },
            .{ .name = "gpu_accelerator", .value = .{ .string = args.gpu_accelerator } },
            .{ .name = "gpu_zonal_redundancy_disabled", .value = .{ .boolean = args.gpu_zonal_redundancy_disabled } },
            .{ .name = "labels", .value = labels },
            .{ .name = "max_retries", .value = .{ .integer = args.max_retries } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "parallelism", .value = .{ .integer = args.parallelism } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "region", .value = .{ .string = region } },
            .{ .name = "secret_volumes", .value = .{ .list = volumes } },
            .{ .name = "service_account", .value = .{ .string = service_account } },
            .{ .name = "task_count", .value = .{ .integer = args.task_count } },
            .{ .name = "timeout_seconds", .value = .{ .integer = args.timeout_seconds } },
            .{ .name = "vpc_access", .value = vpc },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.run.Job.{s}.{s}", .{ region, args.name });
        defer allocator.free(id);
        const node = resource.ResourceNode.initOwned(allocator, .{
            .id = id,
            .provider = .gcp,
            .type_name = "gcp.run.Job",
            .schema_version = 1,
            .logical_id = args.name,
            .inputs = .{ .object = &fields },
            .lifecycle = .{ .retain_on_delete = args.retain_on_delete, .operation_timeout_millis = 30 * 60 * 1000 },
        }) catch |err| switch (err) {
            error.DuplicateField => return error.DuplicateField,
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
        };
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .uid = Outputs.Uid.fromResource(node.id),
            .execution_count = Outputs.ExecutionCount.fromResource(node.id),
            .latest_execution = Outputs.LatestExecution.fromResource(node.id),
            .ready = Outputs.Ready.fromResource(node.id),
            .etag = Outputs.Etag.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Job, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const JobIamMemberArgs = struct {
    name: []const u8,
    job: output.Output([]const u8, .public),
    role: []const u8,
    member: []const u8,
    condition: ?cloud_run.IamCondition = null,
};

pub const JobIamMember = struct {
    pub const Outputs = struct {
        pub const BindingId = output.Descriptor("binding_id", []const u8, .public);
    };

    node: resource.ResourceNode,
    binding_id: Outputs.BindingId.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: JobIamMemberArgs) BuildError!JobIamMember {
        try provider.validate();
        try validateResourceName(args.name, 255);
        if (!std.mem.startsWith(u8, args.role, "roles/run.") or args.role.len <= "roles/run.".len or !validIamText(args.role)) return error.InvalidRole;
        if (!validIamMember(args.member)) return error.InvalidMember;
        if (args.condition) |condition| try validateIamCondition(args.member, condition);
        const fields = [_]value.Field{
            .{ .name = "condition_description", .value = .{ .string = if (args.condition) |condition| condition.description else "" } },
            .{ .name = "condition_expression", .value = .{ .string = if (args.condition) |condition| condition.expression else "" } },
            .{ .name = "condition_title", .value = .{ .string = if (args.condition) |condition| condition.title else "" } },
            .{ .name = "member", .value = .{ .string = args.member } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "resource", .value = try jobResourceValue(args.job, provider.project_id) },
            .{ .name = "role", .value = .{ .string = args.role } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.run.JobIamMember.{s}", .{args.name});
        defer allocator.free(id);
        const node = resource.ResourceNode.initOwned(allocator, .{
            .id = id,
            .provider = .gcp,
            .type_name = "gcp.run.JobIamMember",
            .schema_version = 1,
            .logical_id = args.name,
            .inputs = .{ .object = &fields },
            .lifecycle = .{ .operation_timeout_millis = 15 * 60 * 1000 },
        }) catch |err| switch (err) {
            error.DuplicateField => return error.DuplicateField,
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
        };
        return .{ .node = node, .binding_id = Outputs.BindingId.fromResource(node.id) };
    }

    pub fn deinit(self: *JobIamMember, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const SplitAllocation = enum {
    latest,
    revision,

    pub fn apiName(self: SplitAllocation) []const u8 {
        return switch (self) {
            .latest => "INSTANCE_SPLIT_ALLOCATION_TYPE_LATEST",
            .revision => "INSTANCE_SPLIT_ALLOCATION_TYPE_REVISION",
        };
    }
};

pub const InstanceSplit = struct {
    allocation: SplitAllocation,
    revision: []const u8 = "",
    percent: u8,
};

pub const WorkerPoolArgs = struct {
    name: []const u8,
    region: ?[]const u8 = null,
    description: []const u8 = "",
    containers: []const Container,
    manual_instance_count: u32 = 1,
    revision: []const u8 = "",
    instance_splits: []const InstanceSplit = &.{.{ .allocation = .latest, .percent = 100 }},
    service_account: ?[]const u8 = null,
    secret_volumes: []const SecretVolume = &.{},
    direct_vpc: ?cloud_run.DirectVpc = null,
    encryption_key: []const u8 = "",
    gpu_accelerator: []const u8 = "",
    gpu_zonal_redundancy_disabled: bool = false,
    labels: []const config_mod.Label = &.{},
    annotations: []const config_mod.Label = &.{},
    retain_on_delete: bool = true,
};

pub const WorkerPool = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Uid = output.Descriptor("uid", []const u8, .public);
        pub const LatestReadyRevision = output.Descriptor("latest_ready_revision", []const u8, .public);
        pub const LatestCreatedRevision = output.Descriptor("latest_created_revision", []const u8, .public);
        pub const Ready = output.Descriptor("ready", bool, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    uid: Outputs.Uid.OutputType,
    latest_ready_revision: Outputs.LatestReadyRevision.OutputType,
    latest_created_revision: Outputs.LatestCreatedRevision.OutputType,
    ready: Outputs.Ready.OutputType,
    etag: Outputs.Etag.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: WorkerPoolArgs) BuildError!WorkerPool {
        try provider.validate();
        try validateResourceName(args.name, 49);
        const region = args.region orelse provider.primary_region;
        try validateRegion(region);
        if (args.description.len > 512 or std.mem.indexOfScalar(u8, args.description, 0) != null) return error.InvalidName;
        try validateContainers(args.containers);
        if (args.manual_instance_count == 0) return error.InvalidScaling;
        if (args.revision.len > 0) try validateResourceName(args.revision, 63);
        try validateInstanceSplits(args.instance_splits);
        const service_account = args.service_account orelse provider.service_account orelse "default";
        if (!std.mem.eql(u8, service_account, "default") and !validServiceAccount(service_account, provider.project_id)) return error.InvalidServiceAccount;
        try validateWorkloadControls(provider.project_id, args.containers, args.secret_volumes, args.direct_vpc, args.encryption_key, args.gpu_accelerator, args.gpu_zonal_redundancy_disabled);

        const containers = try containerValuesAlloc(allocator, args.containers);
        defer deinitValues(allocator, containers);
        const volumes = try volumeValuesAlloc(allocator, args.secret_volumes);
        defer deinitValues(allocator, volumes);
        const splits = try splitValuesAlloc(allocator, args.instance_splits);
        defer deinitValues(allocator, splits);
        var vpc = try vpcValueOwned(allocator, args.direct_vpc);
        defer vpc.deinit(allocator);
        var labels = try metadataValueOwned(allocator, provider.labels, args.labels);
        defer labels.deinit(allocator);
        var annotations = try metadataValueOwned(allocator, &.{}, args.annotations);
        defer annotations.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "annotations", .value = annotations },
            .{ .name = "containers", .value = .{ .list = containers } },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "encryption_key", .value = .{ .string = args.encryption_key } },
            .{ .name = "gpu_accelerator", .value = .{ .string = args.gpu_accelerator } },
            .{ .name = "gpu_zonal_redundancy_disabled", .value = .{ .boolean = args.gpu_zonal_redundancy_disabled } },
            .{ .name = "instance_splits", .value = .{ .list = splits } },
            .{ .name = "labels", .value = labels },
            .{ .name = "manual_instance_count", .value = .{ .integer = args.manual_instance_count } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "region", .value = .{ .string = region } },
            .{ .name = "revision", .value = .{ .string = args.revision } },
            .{ .name = "secret_volumes", .value = .{ .list = volumes } },
            .{ .name = "service_account", .value = .{ .string = service_account } },
            .{ .name = "vpc_access", .value = vpc },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.run.WorkerPool.{s}.{s}", .{ region, args.name });
        defer allocator.free(id);
        const node = resource.ResourceNode.initOwned(allocator, .{
            .id = id,
            .provider = .gcp,
            .type_name = "gcp.run.WorkerPool",
            .schema_version = 1,
            .logical_id = args.name,
            .inputs = .{ .object = &fields },
            .lifecycle = .{ .retain_on_delete = args.retain_on_delete, .operation_timeout_millis = 30 * 60 * 1000 },
        }) catch |err| switch (err) {
            error.DuplicateField => return error.DuplicateField,
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
        };
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .uid = Outputs.Uid.fromResource(node.id),
            .latest_ready_revision = Outputs.LatestReadyRevision.fromResource(node.id),
            .latest_created_revision = Outputs.LatestCreatedRevision.fromResource(node.id),
            .ready = Outputs.Ready.fromResource(node.id),
            .etag = Outputs.Etag.fromResource(node.id),
        };
    }

    pub fn deinit(self: *WorkerPool, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn validateContainers(containers: []const Container) BuildError!void {
    if (containers.len == 0) return error.MissingContainer;
    for (containers, 0..) |container, index| {
        try validateResourceName(container.name, 63);
        if ((container.image.len == 0) == (container.image_output == null)) return if (container.image.len == 0) error.MissingImage else error.ConflictingOutput;
        if (container.cpu.len == 0 or container.memory.len == 0) return error.InvalidResources;
        for (containers[index + 1 ..]) |other| if (std.mem.eql(u8, container.name, other.name)) return error.DuplicateContainer;
        for (container.env, 0..) |entry, env_index| {
            try validateEnvName(entry.name);
            if (entry.secret and entry.secret_version.len == 0) return error.InvalidSecretVolume;
            if ((!entry.secret and entry.secret_output != null) or (entry.secret and entry.value_output != null) or
                (entry.secret_output != null and entry.secret_name != null) or (entry.value_output != null and entry.value.len != 0)) return error.ConflictingOutput;
            for (container.env[env_index + 1 ..]) |other| if (std.mem.eql(u8, entry.name, other.name)) return error.DuplicateEnvVar;
        }
    }
}

fn validateWorkloadControls(
    project_id: []const u8,
    containers: []const Container,
    volumes: []const SecretVolume,
    maybe_vpc: ?cloud_run.DirectVpc,
    encryption_key: []const u8,
    gpu_accelerator: []const u8,
    gpu_zonal_redundancy_disabled: bool,
) BuildError!void {
    for (volumes, 0..) |volume, index| {
        if (volume.name.len == 0 or volume.secret.len == 0 or volume.version.len == 0 or volume.path.len == 0 or !std.mem.startsWith(u8, volume.mount_path, "/")) return error.InvalidSecretVolume;
        const target = if (volume.container.len > 0) volume.container else if (containers.len == 1) containers[0].name else return error.InvalidSecretVolume;
        var target_exists = false;
        for (containers) |container| if (std.mem.eql(u8, container.name, target)) {
            target_exists = true;
            break;
        };
        if (!target_exists) return error.InvalidSecretVolume;
        for (volumes[index + 1 ..]) |other| if (std.mem.eql(u8, volume.name, other.name) or std.mem.eql(u8, volume.mount_path, other.mount_path)) return error.InvalidSecretVolume;
    }
    if (maybe_vpc) |vpc| {
        if ((vpc.network.len == 0) == (vpc.network_output == null) or (vpc.subnetwork.len == 0) == (vpc.subnetwork_output == null)) return error.InvalidVpcAccess;
    }
    if (encryption_key.len > 0 and (!std.mem.startsWith(u8, encryption_key, "projects/") or std.mem.indexOf(u8, encryption_key, project_id) == null or std.mem.indexOf(u8, encryption_key, "/cryptoKeys/") == null)) return error.InvalidEncryptionKey;
    if (gpu_zonal_redundancy_disabled and gpu_accelerator.len == 0) return error.InvalidGpu;
    if (std.mem.indexOfAny(u8, gpu_accelerator, "\x00\r\n ") != null) return error.InvalidGpu;
}

fn validateInstanceSplits(splits: []const InstanceSplit) BuildError!void {
    if (splits.len == 0) return error.InvalidInstanceSplits;
    var total: u16 = 0;
    var latest_count: usize = 0;
    for (splits, 0..) |split, index| {
        if (split.percent == 0) return error.InvalidInstanceSplits;
        total += split.percent;
        switch (split.allocation) {
            .latest => {
                latest_count += 1;
                if (split.revision.len != 0) return error.InvalidInstanceSplits;
            },
            .revision => {
                if (split.revision.len == 0) return error.InvalidInstanceSplits;
                try validateResourceName(split.revision, 63);
            },
        }
        for (splits[index + 1 ..]) |other| {
            if (split.allocation == .latest and other.allocation == .latest) return error.InvalidInstanceSplits;
            if (split.allocation == .revision and other.allocation == .revision and std.mem.eql(u8, split.revision, other.revision)) return error.InvalidInstanceSplits;
        }
    }
    if (latest_count > 1 or total != 100) return error.InvalidInstanceSplits;
}

fn containerValuesAlloc(allocator: std.mem.Allocator, containers: []const Container) BuildError![]value.Value {
    const values = try allocator.alloc(value.Value, containers.len);
    errdefer allocator.free(values);
    var initialized: usize = 0;
    errdefer for (values[0..initialized]) |*item| item.deinit(allocator);
    for (containers, 0..) |container, index| {
        const command = try stringValuesAlloc(allocator, container.command);
        defer allocator.free(command);
        const args = try stringValuesAlloc(allocator, container.args);
        defer allocator.free(args);
        const env = try envValuesAlloc(allocator, container.env);
        defer deinitValues(allocator, env);
        const fields = [_]value.Field{
            .{ .name = "args", .value = .{ .list = args } },
            .{ .name = "command", .value = .{ .list = command } },
            .{ .name = "cpu", .value = .{ .string = container.cpu } },
            .{ .name = "env", .value = .{ .list = env } },
            .{ .name = "image", .value = try publicOutputValue(container.image, container.image_output) },
            .{ .name = "memory", .value = .{ .string = container.memory } },
            .{ .name = "name", .value = .{ .string = container.name } },
        };
        values[index] = try ownedValue(allocator, .{ .object = &fields });
        initialized += 1;
    }
    return values;
}

fn envValuesAlloc(allocator: std.mem.Allocator, env: []const cloud_run.EnvVar) BuildError![]value.Value {
    const values = try allocator.alloc(value.Value, env.len);
    errdefer allocator.free(values);
    var initialized: usize = 0;
    errdefer for (values[0..initialized]) |*item| item.deinit(allocator);
    for (env, 0..) |entry, index| {
        const selected: value.Value = if (entry.secret)
            try secretOutputValue(entry)
        else
            try publicOutputValueAllowEmpty(entry.value, entry.value_output);
        const fields = [_]value.Field{
            .{ .name = "name", .value = .{ .string = entry.name } },
            .{ .name = "secret", .value = .{ .boolean = entry.secret } },
            .{ .name = "value", .value = selected },
        };
        values[index] = try ownedValue(allocator, .{ .object = &fields });
        initialized += 1;
    }
    return values;
}

fn volumeValuesAlloc(allocator: std.mem.Allocator, volumes: []const SecretVolume) BuildError![]value.Value {
    const values = try allocator.alloc(value.Value, volumes.len);
    errdefer allocator.free(values);
    var initialized: usize = 0;
    errdefer for (values[0..initialized]) |*item| item.deinit(allocator);
    for (volumes, 0..) |volume, index| {
        const fields = [_]value.Field{
            .{ .name = "container", .value = .{ .string = volume.container } },
            .{ .name = "mount_path", .value = .{ .string = volume.mount_path } },
            .{ .name = "name", .value = .{ .string = volume.name } },
            .{ .name = "path", .value = .{ .string = volume.path } },
            .{ .name = "secret", .value = .{ .secret_ref = .{ .provider = "gcp-secret-manager", .resource = volume.secret, .version = volume.version } } },
        };
        values[index] = try ownedValue(allocator, .{ .object = &fields });
        initialized += 1;
    }
    return values;
}

fn splitValuesAlloc(allocator: std.mem.Allocator, splits: []const InstanceSplit) BuildError![]value.Value {
    const values = try allocator.alloc(value.Value, splits.len);
    errdefer allocator.free(values);
    var initialized: usize = 0;
    errdefer for (values[0..initialized]) |*item| item.deinit(allocator);
    for (splits, 0..) |split, index| {
        const fields = [_]value.Field{
            .{ .name = "allocation", .value = .{ .string = split.allocation.apiName() } },
            .{ .name = "percent", .value = .{ .integer = split.percent } },
            .{ .name = "revision", .value = .{ .string = split.revision } },
        };
        values[index] = try ownedValue(allocator, .{ .object = &fields });
        initialized += 1;
    }
    return values;
}

fn metadataValueOwned(allocator: std.mem.Allocator, inherited: []const config_mod.Label, supplied: []const config_mod.Label) BuildError!value.Value {
    const fields = try allocator.alloc(value.Field, inherited.len + supplied.len);
    defer allocator.free(fields);
    var index: usize = 0;
    for (inherited) |label| {
        try validateMetadata(label);
        fields[index] = .{ .name = label.key, .value = .{ .string = label.value } };
        index += 1;
    }
    for (supplied) |label| {
        try validateMetadata(label);
        for (fields[0..index]) |existing| if (std.mem.eql(u8, existing.name, label.key)) return error.DuplicateLabel;
        fields[index] = .{ .name = label.key, .value = .{ .string = label.value } };
        index += 1;
    }
    return ownedValue(allocator, .{ .object = fields });
}

fn vpcValueOwned(allocator: std.mem.Allocator, maybe_vpc: ?cloud_run.DirectVpc) BuildError!value.Value {
    const vpc = maybe_vpc orelse return ownedValue(allocator, .{ .object = &.{} });
    const tags = try stringValuesAlloc(allocator, vpc.tags);
    defer allocator.free(tags);
    const fields = [_]value.Field{
        .{ .name = "egress", .value = .{ .string = vpc.egress.apiName() } },
        .{ .name = "network", .value = try optionalOutputValue(vpc.network, vpc.network_output) },
        .{ .name = "subnetwork", .value = try optionalOutputValue(vpc.subnetwork, vpc.subnetwork_output) },
        .{ .name = "tags", .value = .{ .list = tags } },
    };
    return ownedValue(allocator, .{ .object = &fields });
}

fn publicOutputValue(literal: []const u8, selected: ?output.Output([]const u8, .public)) BuildError!value.Value {
    if (selected) |present| return outputValue(present);
    if (literal.len == 0) return error.MissingImage;
    return .{ .string = literal };
}

fn publicOutputValueAllowEmpty(literal: []const u8, selected: ?output.Output([]const u8, .public)) BuildError!value.Value {
    if (selected) |present| return outputValue(present);
    return .{ .string = literal };
}

fn optionalOutputValue(literal: []const u8, selected: ?output.Output([]const u8, .public)) BuildError!value.Value {
    if (selected) |present| return outputValue(present);
    return .{ .string = literal };
}

fn outputValue(selected: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (selected) {
        .value => |known| .{ .string = known },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn secretOutputValue(entry: cloud_run.EnvVar) BuildError!value.Value {
    const selected = entry.secret_output orelse return .{ .secret_ref = .{
        .provider = "gcp-secret-manager",
        .resource = entry.secret_name orelse entry.name,
        .version = entry.secret_version,
    } };
    return switch (selected) {
        .value => |known| .{ .secret_ref = known },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn stringValuesAlloc(allocator: std.mem.Allocator, strings: []const []const u8) BuildError![]value.Value {
    const values = try allocator.alloc(value.Value, strings.len);
    errdefer allocator.free(values);
    for (strings, 0..) |text, index| {
        if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidContainer;
        values[index] = .{ .string = text };
    }
    return values;
}

fn validateResourceName(name: []const u8, maximum: usize) BuildError!void {
    if (name.len == 0 or name.len > maximum or !std.ascii.isLower(name[0]) or name[name.len - 1] == '-') return error.InvalidName;
    for (name) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return error.InvalidName;
}

fn validateRegion(region: []const u8) BuildError!void {
    try validateResourceName(region, 63);
}

fn validateEnvName(name: []const u8) BuildError!void {
    if (name.len == 0 or name.len > 32_768 or (!std.ascii.isAlphabetic(name[0]) and name[0] != '_')) return error.InvalidName;
    for (name) |character| if (!std.ascii.isAlphanumeric(character) and character != '_') return error.InvalidName;
}

fn validateMetadata(label: config_mod.Label) BuildError!void {
    if (label.key.len == 0 or label.key.len > 63 or label.value.len > 63 or std.mem.indexOfAny(u8, label.key, "\x00\r\n ") != null or std.mem.indexOfAny(u8, label.value, "\x00\r\n") != null) return error.InvalidName;
    for ([_][]const u8{ "run.googleapis.com/", "cloud.googleapis.com/", "serving.knative.dev/", "autoscaling.knative.dev/" }) |prefix| {
        if (std.mem.startsWith(u8, label.key, prefix)) return error.InvalidName;
    }
}

fn validServiceAccount(email: []const u8, project_id: []const u8) bool {
    return std.mem.endsWith(u8, email, ".iam.gserviceaccount.com") and std.mem.indexOfScalar(u8, email, '@') != null and
        std.mem.indexOf(u8, email, project_id) != null and std.mem.indexOfAny(u8, email, "\x00\r\n /") == null;
}

fn jobResourceValue(job: output.Output([]const u8, .public), project_id: []const u8) BuildError!value.Value {
    return switch (job) {
        .value => |known| if (validJobResourceName(known, project_id)) .{ .string = known } else error.InvalidResourceName,
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn validJobResourceName(name: []const u8, project_id: []const u8) bool {
    var parts = std.mem.splitScalar(u8, name, '/');
    return std.mem.eql(u8, parts.next() orelse return false, "projects") and
        std.mem.eql(u8, parts.next() orelse return false, project_id) and
        std.mem.eql(u8, parts.next() orelse return false, "locations") and
        validIamResourceId(parts.next() orelse return false) and
        std.mem.eql(u8, parts.next() orelse return false, "jobs") and
        validIamResourceId(parts.next() orelse return false) and
        parts.next() == null;
}

fn validIamResourceId(name: []const u8) bool {
    return name.len > 0 and name.len <= 255 and std.mem.indexOfAny(u8, name, "\x00\r\n /?#") == null;
}

fn validIamMember(member: []const u8) bool {
    return (std.mem.eql(u8, member, "allUsers") or std.mem.eql(u8, member, "allAuthenticatedUsers") or std.mem.indexOfScalar(u8, member, ':') != null) and
        std.mem.indexOfAny(u8, member, "\x00\r\n ") == null;
}

fn validateIamCondition(member: []const u8, condition: cloud_run.IamCondition) BuildError!void {
    if (std.mem.eql(u8, member, "allUsers") or std.mem.eql(u8, member, "allAuthenticatedUsers")) return error.InvalidIamCondition;
    if (!validIamText(condition.title) or condition.title.len > 100 or !validIamText(condition.expression)) return error.InvalidIamCondition;
    if (condition.description.len > 0 and !validIamText(condition.description)) return error.InvalidIamCondition;
}

fn validIamText(text: []const u8) bool {
    return text.len > 0 and std.mem.indexOfScalar(u8, text, 0) == null;
}

fn ownedValue(allocator: std.mem.Allocator, source: value.Value) BuildError!value.Value {
    return value.Value.initOwned(allocator, source) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn deinitValues(allocator: std.mem.Allocator, values: []value.Value) void {
    for (values) |*item| item.deinit(allocator);
    allocator.free(values);
}
