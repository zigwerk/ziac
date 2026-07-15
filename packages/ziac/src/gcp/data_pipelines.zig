const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    DuplicateKey,
    InvalidDisplayName,
    InvalidName,
    InvalidRegion,
    InvalidRuntime,
    InvalidSchedule,
    InvalidServiceAccount,
    InvalidTemplate,
};

pub const KeyValue = struct { key: []const u8, value: []const u8 };
pub const PipelineType = enum { batch, streaming };
pub const IpConfiguration = enum { worker_ip_public, worker_ip_private };
pub const RemovalPolicy = enum { retain, delete };

pub const RuntimeEnvironment = struct {
    service_account_email: ?[]const u8 = null,
    temp_location: ?[]const u8 = null,
    staging_location: ?[]const u8 = null,
    subnetwork: ?[]const u8 = null,
    machine_type: ?[]const u8 = null,
    num_workers: u16 = 0,
    max_workers: u16 = 0,
    ip_configuration: IpConfiguration = .worker_ip_public,
    kms_key_name: ?output.Output([]const u8, .public) = null,
    additional_experiments: []const []const u8 = &.{},
};

pub const ClassicTemplate = struct {
    gcs_path: []const u8,
    parameters: []const KeyValue = &.{},
    environment: RuntimeEnvironment = .{},
};

pub const FlexTemplate = struct {
    container_spec_gcs_path: []const u8,
    parameters: []const KeyValue = &.{},
    launch_options: []const KeyValue = &.{},
    environment: RuntimeEnvironment = .{},
};

pub const Workload = union(enum) {
    classic_template: ClassicTemplate,
    flex_template: FlexTemplate,
};

pub const Schedule = struct {
    cron: []const u8,
    time_zone: []const u8,
};

pub const PipelineArgs = struct {
    name: []const u8,
    location: []const u8,
    display_name: []const u8,
    pipeline_type: PipelineType,
    workload: Workload,
    schedule: ?Schedule = null,
    scheduler_service_account_email: ?[]const u8 = null,
    protect: bool = true,
    removal_policy: RemovalPolicy = .retain,
};

pub const Pipeline = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
        pub const JobCount = output.Descriptor("job_count", u64, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    state: Outputs.State.OutputType,
    job_count: Outputs.JobCount.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: PipelineArgs) BuildError!Pipeline {
        try provider.validate();
        try validateName(args.name);
        try validateRegion(provider, args.location);
        try validateDisplayName(args.display_name);
        if (args.pipeline_type == .streaming and args.schedule != null) return error.InvalidSchedule;
        if (args.schedule) |schedule| try validateSchedule(schedule);
        if (args.scheduler_service_account_email) |email| try validateServiceAccount(email);
        var workload = try workloadValue(allocator, args.workload);
        defer workload.deinit(allocator);
        var schedule = if (args.schedule) |selected| try scheduleValue(allocator, selected) else try ownedValue(allocator, .{ .object = &.{} });
        defer schedule.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "pipeline_type", .value = .{ .string = if (args.pipeline_type == .batch) "PIPELINE_TYPE_BATCH" else "PIPELINE_TYPE_STREAMING" } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
            .{ .name = "schedule", .value = schedule },
            .{ .name = "scheduler_service_account_email", .value = .{ .string = args.scheduler_service_account_email orelse "" } },
            .{ .name = "workload", .value = workload },
        };
        const node = try nodeOwned(allocator, "gcp.datapipelines.Pipeline", args.location, args.name, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.removal_policy == .retain,
        });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .state = Outputs.State.fromResource(node.id),
            .job_count = Outputs.JobCount.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Pipeline, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn workloadValue(allocator: std.mem.Allocator, workload: Workload) BuildError!value.Value {
    return switch (workload) {
        .classic_template => |selected| blk: {
            try validateGcs(selected.gcs_path);
            var parameters = try mapValue(allocator, selected.parameters);
            defer parameters.deinit(allocator);
            var environment = try environmentValue(allocator, selected.environment);
            defer environment.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "environment", .value = environment },
                .{ .name = "gcs_path", .value = .{ .string = selected.gcs_path } },
                .{ .name = "kind", .value = .{ .string = "classic_template" } },
                .{ .name = "parameters", .value = parameters },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
        .flex_template => |selected| blk: {
            try validateGcs(selected.container_spec_gcs_path);
            var parameters = try mapValue(allocator, selected.parameters);
            defer parameters.deinit(allocator);
            var launch_options = try mapValue(allocator, selected.launch_options);
            defer launch_options.deinit(allocator);
            var environment = try environmentValue(allocator, selected.environment);
            defer environment.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "container_spec_gcs_path", .value = .{ .string = selected.container_spec_gcs_path } },
                .{ .name = "environment", .value = environment },
                .{ .name = "kind", .value = .{ .string = "flex_template" } },
                .{ .name = "launch_options", .value = launch_options },
                .{ .name = "parameters", .value = parameters },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
    };
}

fn environmentValue(allocator: std.mem.Allocator, environment: RuntimeEnvironment) BuildError!value.Value {
    if (environment.service_account_email) |email| try validateServiceAccount(email);
    if (environment.temp_location) |location| try validateGcs(location);
    if (environment.staging_location) |location| try validateGcs(location);
    if (environment.num_workers > 1000 or environment.max_workers > 1000 or
        (environment.max_workers != 0 and environment.num_workers > environment.max_workers)) return error.InvalidRuntime;
    var experiments = try stringsValue(allocator, environment.additional_experiments);
    defer experiments.deinit(allocator);
    const fields = [_]value.Field{
        .{ .name = "additional_experiments", .value = experiments },
        .{ .name = "ip_configuration", .value = .{ .string = if (environment.ip_configuration == .worker_ip_private) "WORKER_IP_PRIVATE" else "WORKER_IP_PUBLIC" } },
        .{ .name = "kms_key_name", .value = try optionalOutputValue(environment.kms_key_name) },
        .{ .name = "machine_type", .value = .{ .string = environment.machine_type orelse "" } },
        .{ .name = "max_workers", .value = .{ .integer = environment.max_workers } },
        .{ .name = "num_workers", .value = .{ .integer = environment.num_workers } },
        .{ .name = "service_account_email", .value = .{ .string = environment.service_account_email orelse "" } },
        .{ .name = "staging_location", .value = .{ .string = environment.staging_location orelse "" } },
        .{ .name = "subnetwork", .value = .{ .string = environment.subnetwork orelse "" } },
        .{ .name = "temp_location", .value = .{ .string = environment.temp_location orelse "" } },
    };
    return ownedValue(allocator, .{ .object = &fields });
}

fn scheduleValue(allocator: std.mem.Allocator, schedule: Schedule) BuildError!value.Value {
    try validateSchedule(schedule);
    const fields = [_]value.Field{
        .{ .name = "cron", .value = .{ .string = schedule.cron } },
        .{ .name = "time_zone", .value = .{ .string = schedule.time_zone } },
    };
    return ownedValue(allocator, .{ .object = &fields });
}

fn mapValue(allocator: std.mem.Allocator, items: []const KeyValue) BuildError!value.Value {
    const fields = try allocator.alloc(value.Field, items.len);
    defer allocator.free(fields);
    for (items, 0..) |item, index| {
        if (item.key.len == 0 or item.value.len > 4096) return error.InvalidTemplate;
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
    const known = selected orelse return .{ .string = "" };
    return switch (known) {
        .value => |text| .{ .string = text },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.InvalidRuntime,
    };
}

fn validateName(name: []const u8) BuildError!void {
    if (name.len == 0 or name.len > 63 or !std.ascii.isLower(name[0]) or !std.ascii.isAlphanumeric(name[name.len - 1])) return error.InvalidName;
    for (name) |char| if (!(std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '-')) return error.InvalidName;
}
fn validateDisplayName(name: []const u8) BuildError!void {
    if (name.len == 0 or name.len > 63) return error.InvalidDisplayName;
    for (name) |char| if (!(std.ascii.isAlphanumeric(char) or char == '-' or char == '_')) return error.InvalidDisplayName;
}
fn validateRegion(provider: config_mod.ProviderConfig, region: []const u8) BuildError!void {
    if (region.len == 0) return error.InvalidRegion;
    if (provider.service_regions.len == 0) {
        if (!std.mem.eql(u8, region, provider.primary_region)) return error.InvalidRegion;
        return;
    }
    for (provider.service_regions) |allowed| if (std.mem.eql(u8, allowed, region)) return;
    return error.InvalidRegion;
}
fn validateGcs(path: []const u8) BuildError!void {
    if (!std.mem.startsWith(u8, path, "gs://") or path.len <= 5 or std.mem.indexOfAny(u8, path, "?#\r\n") != null) return error.InvalidTemplate;
}
fn validateServiceAccount(email: []const u8) BuildError!void {
    if (std.mem.indexOf(u8, email, "@") == null or !std.mem.endsWith(u8, email, ".iam.gserviceaccount.com")) return error.InvalidServiceAccount;
}
fn validateSchedule(schedule: Schedule) BuildError!void {
    if (schedule.cron.len == 0 or schedule.time_zone.len == 0 or std.mem.count(u8, schedule.cron, " ") < 4 or std.mem.indexOfAny(u8, schedule.cron, "\r\n") != null) return error.InvalidSchedule;
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
