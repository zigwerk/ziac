const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");
const validation = @import("validation.zig");

pub const BuildError = validation.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    InvalidScaling,
    InvalidResources,
    InvalidConcurrency,
    InvalidTimeout,
    InvalidProbe,
    InvalidVpcAccess,
    InvalidSecretVolume,
};

pub const Ingress = enum {
    all,
    internal,
    internal_and_cloud_load_balancing,

    pub fn apiName(self: Ingress) []const u8 {
        return switch (self) {
            .all => "INGRESS_TRAFFIC_ALL",
            .internal => "INGRESS_TRAFFIC_INTERNAL_ONLY",
            .internal_and_cloud_load_balancing => "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER",
        };
    }
};

pub const VpcEgress = enum {
    private_ranges_only,
    all_traffic,

    pub fn apiName(self: VpcEgress) []const u8 {
        return switch (self) {
            .private_ranges_only => "PRIVATE_RANGES_ONLY",
            .all_traffic => "ALL_TRAFFIC",
        };
    }
};

pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
    secret: bool = false,
    secret_name: ?[]const u8 = null,
    secret_version: []const u8 = "latest",
};

pub const HttpProbe = struct {
    path: []const u8,
    initial_delay_seconds: u32 = 0,
    timeout_seconds: u32 = 1,
    period_seconds: u32 = 10,
    failure_threshold: u32 = 3,
};

pub const SecretVolume = struct {
    name: []const u8,
    secret: []const u8,
    version: []const u8 = "latest",
    path: []const u8,
    mount_path: []const u8,
};

pub const DirectVpc = struct {
    network: []const u8 = "",
    subnetwork: []const u8 = "",
    network_output: ?output.Output([]const u8, .public) = null,
    subnetwork_output: ?output.Output([]const u8, .public) = null,
    tags: []const []const u8 = &.{},
    egress: VpcEgress = .private_ranges_only,
};

pub const ServiceArgs = struct {
    name: []const u8,
    image: []const u8,
    region: ?[]const u8 = null,
    port: u16 = 8080,
    command: []const []const u8 = &.{},
    args: []const []const u8 = &.{},
    cpu: []const u8 = "1",
    memory: []const u8 = "512Mi",
    concurrency: u16 = 80,
    timeout_seconds: u32 = 300,
    min_instances: u32 = 0,
    max_instances: u32 = 100,
    startup_probe: ?HttpProbe = null,
    liveness_probe: ?HttpProbe = null,
    readiness_probe: ?HttpProbe = null,
    ingress: Ingress = .internal_and_cloud_load_balancing,
    allow_unauthenticated: bool = false,
    service_account: ?[]const u8 = null,
    env: []const EnvVar = &.{},
    secret_volumes: []const SecretVolume = &.{},
    direct_vpc: ?DirectVpc = null,
};

pub const Service = struct {
    pub const Outputs = struct {
        pub const ServiceUrl = output.Descriptor("service_url", []const u8, .public);
        pub const ServiceAccount = output.Descriptor("service_account", []const u8, .public);
        pub const LatestRevision = output.Descriptor("latest_revision", []const u8, .public);

        pub fn field(comptime name: []const u8) type {
            if (std.mem.eql(u8, name, "service_url")) return ServiceUrl;
            if (std.mem.eql(u8, name, "service_account")) return ServiceAccount;
            if (std.mem.eql(u8, name, "latest_revision")) return LatestRevision;
            @compileError("ZIAC120 unknown gcp.run.Service output field: " ++ name);
        }
    };

    node: resource.ResourceNode,
    service_url: Outputs.ServiceUrl.OutputType,
    service_account: Outputs.ServiceAccount.OutputType,
    latest_revision: Outputs.LatestRevision.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: ServiceArgs,
    ) BuildError!Service {
        try validate(provider, args);
        const region = args.region orelse provider.primary_region;
        const selected_service_account = args.service_account orelse provider.service_account orelse "default";
        const id = try std.fmt.allocPrint(allocator, "gcp.run.Service.{s}.{s}", .{ region, args.name });
        defer allocator.free(id);

        const label_fields = try allocator.alloc(value.Field, provider.labels.len);
        defer allocator.free(label_fields);
        for (provider.labels, 0..) |label, index| {
            label_fields[index] = .{ .name = label.key, .value = .{ .string = label.value } };
        }

        const command = try stringValuesAlloc(allocator, args.command);
        defer allocator.free(command);
        const command_args = try stringValuesAlloc(allocator, args.args);
        defer allocator.free(command_args);
        const env = try envValuesAlloc(allocator, args.env);
        defer deinitOwnedValues(allocator, env);
        const volumes = try volumeValuesAlloc(allocator, args.secret_volumes);
        defer deinitOwnedValues(allocator, volumes);
        var startup_probe = try probeValueOwned(allocator, args.startup_probe);
        defer startup_probe.deinit(allocator);
        var liveness_probe = try probeValueOwned(allocator, args.liveness_probe);
        defer liveness_probe.deinit(allocator);
        var readiness_probe = try probeValueOwned(allocator, args.readiness_probe);
        defer readiness_probe.deinit(allocator);
        var vpc_access = try vpcValueOwned(allocator, args.direct_vpc);
        defer vpc_access.deinit(allocator);

        const input_fields = [_]value.Field{
            .{ .name = "allow_unauthenticated", .value = .{ .boolean = args.allow_unauthenticated } },
            .{ .name = "args", .value = .{ .list = command_args } },
            .{ .name = "command", .value = .{ .list = command } },
            .{ .name = "concurrency", .value = .{ .integer = args.concurrency } },
            .{ .name = "cpu", .value = .{ .string = args.cpu } },
            .{ .name = "env", .value = .{ .list = env } },
            .{ .name = "image", .value = .{ .string = args.image } },
            .{ .name = "ingress", .value = .{ .string = args.ingress.apiName() } },
            .{ .name = "labels", .value = .{ .object = label_fields } },
            .{ .name = "liveness_probe", .value = liveness_probe },
            .{ .name = "max_instances", .value = .{ .integer = args.max_instances } },
            .{ .name = "memory", .value = .{ .string = args.memory } },
            .{ .name = "min_instances", .value = .{ .integer = args.min_instances } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "port", .value = .{ .integer = args.port } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "readiness_probe", .value = readiness_probe },
            .{ .name = "region", .value = .{ .string = region } },
            .{ .name = "secret_volumes", .value = .{ .list = volumes } },
            .{ .name = "service_account", .value = .{ .string = selected_service_account } },
            .{ .name = "startup_probe", .value = startup_probe },
            .{ .name = "timeout_seconds", .value = .{ .integer = args.timeout_seconds } },
            .{ .name = "vpc_access", .value = vpc_access },
        };
        const node = resource.ResourceNode.initOwned(allocator, .{
            .id = id,
            .provider = .gcp,
            .type_name = "gcp.run.Service",
            .schema_version = 2,
            .logical_id = args.name,
            .inputs = .{ .object = &input_fields },
        }) catch |err| switch (err) {
            error.DuplicateField => return error.DuplicateField,
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
        };

        return .{
            .node = node,
            .service_url = Outputs.ServiceUrl.fromResource(node.id),
            .service_account = Outputs.ServiceAccount.fromResource(node.id),
            .latest_revision = Outputs.LatestRevision.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Service, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn validate(provider: config_mod.ProviderConfig, args: ServiceArgs) BuildError!void {
    try provider.validate();
    if (args.name.len == 0) return error.MissingName;
    if (args.image.len == 0) return error.MissingImage;
    if (args.port == 0) return error.InvalidPort;
    if ((args.region orelse provider.primary_region).len == 0) return error.MissingRegion;
    if (args.cpu.len == 0 or args.memory.len == 0) return error.InvalidResources;
    if (args.concurrency == 0) return error.InvalidConcurrency;
    if (args.timeout_seconds == 0) return error.InvalidTimeout;
    if (args.max_instances == 0 or args.min_instances > args.max_instances) return error.InvalidScaling;
    try validateEnv(args.env);
    try validateProbe(args.startup_probe);
    try validateProbe(args.liveness_probe);
    try validateProbe(args.readiness_probe);
    if (args.direct_vpc) |vpc| {
        if ((vpc.network.len == 0) == (vpc.network_output == null) or
            (vpc.subnetwork.len == 0) == (vpc.subnetwork_output == null)) return error.InvalidVpcAccess;
    }
    for (args.secret_volumes, 0..) |volume, index| {
        if (volume.name.len == 0 or volume.secret.len == 0 or volume.version.len == 0 or
            volume.path.len == 0 or !std.mem.startsWith(u8, volume.mount_path, "/")) return error.InvalidSecretVolume;
        for (args.secret_volumes[index + 1 ..]) |other| {
            if (std.mem.eql(u8, volume.name, other.name) or std.mem.eql(u8, volume.mount_path, other.mount_path)) {
                return error.InvalidSecretVolume;
            }
        }
    }
}

fn validateEnv(env: []const EnvVar) BuildError!void {
    for (env, 0..) |left, left_index| {
        if (left.name.len == 0) return error.MissingName;
        if (left.secret and left.secret_version.len == 0) return error.InvalidSecretVolume;
        for (env[left_index + 1 ..]) |right| {
            if (std.mem.eql(u8, left.name, right.name)) return error.DuplicateEnvVar;
        }
    }
}

fn validateProbe(probe: ?HttpProbe) BuildError!void {
    if (probe) |present| {
        if (!std.mem.startsWith(u8, present.path, "/") or present.timeout_seconds == 0 or
            present.period_seconds == 0 or present.failure_threshold == 0) return error.InvalidProbe;
    }
}

fn stringValuesAlloc(allocator: std.mem.Allocator, strings: []const []const u8) BuildError![]value.Value {
    const values = try allocator.alloc(value.Value, strings.len);
    for (strings, 0..) |string, index| values[index] = .{ .string = string };
    return values;
}

fn envValuesAlloc(allocator: std.mem.Allocator, env: []const EnvVar) BuildError![]value.Value {
    const values = try allocator.alloc(value.Value, env.len);
    errdefer allocator.free(values);
    var initialized: usize = 0;
    errdefer for (values[0..initialized]) |*item| item.deinit(allocator);
    for (env, 0..) |entry, index| {
        const env_value: value.Value = if (entry.secret)
            .{ .secret_ref = .{
                .provider = "gcp-secret-manager",
                .resource = entry.secret_name orelse entry.name,
                .version = entry.secret_version,
            } }
        else
            .{ .string = entry.value };
        const fields = [_]value.Field{
            .{ .name = "name", .value = .{ .string = entry.name } },
            .{ .name = "secret", .value = .{ .boolean = entry.secret } },
            .{ .name = "value", .value = env_value },
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
            .{ .name = "mount_path", .value = .{ .string = volume.mount_path } },
            .{ .name = "name", .value = .{ .string = volume.name } },
            .{ .name = "path", .value = .{ .string = volume.path } },
            .{ .name = "secret", .value = .{ .secret_ref = .{
                .provider = "gcp-secret-manager",
                .resource = volume.secret,
                .version = volume.version,
            } } },
        };
        values[index] = try ownedValue(allocator, .{ .object = &fields });
        initialized += 1;
    }
    return values;
}

fn probeValueOwned(allocator: std.mem.Allocator, probe: ?HttpProbe) BuildError!value.Value {
    const present = probe orelse return ownedValue(allocator, .{ .object = &.{} });
    const fields = [_]value.Field{
        .{ .name = "failure_threshold", .value = .{ .integer = present.failure_threshold } },
        .{ .name = "initial_delay_seconds", .value = .{ .integer = present.initial_delay_seconds } },
        .{ .name = "path", .value = .{ .string = present.path } },
        .{ .name = "period_seconds", .value = .{ .integer = present.period_seconds } },
        .{ .name = "timeout_seconds", .value = .{ .integer = present.timeout_seconds } },
    };
    return ownedValue(allocator, .{ .object = &fields });
}

fn vpcValueOwned(allocator: std.mem.Allocator, maybe_vpc: ?DirectVpc) BuildError!value.Value {
    const vpc = maybe_vpc orelse return ownedValue(allocator, .{ .object = &.{} });
    const tags = try stringValuesAlloc(allocator, vpc.tags);
    defer allocator.free(tags);
    const network = try directVpcInputValue(vpc.network, vpc.network_output);
    const subnetwork = try directVpcInputValue(vpc.subnetwork, vpc.subnetwork_output);
    const fields = [_]value.Field{
        .{ .name = "egress", .value = .{ .string = vpc.egress.apiName() } },
        .{ .name = "network", .value = network },
        .{ .name = "subnetwork", .value = subnetwork },
        .{ .name = "tags", .value = .{ .list = tags } },
    };
    return ownedValue(allocator, .{ .object = &fields });
}

fn directVpcInputValue(
    literal: []const u8,
    maybe_output: ?output.Output([]const u8, .public),
) BuildError!value.Value {
    if (maybe_output) |typed_output| return switch (typed_output) {
        .value => |known| .{ .string = known },
        .resource_ref => |reference| .{ .output_ref = .{
            .resource_id = reference.resource_id,
            .field = reference.field,
        } },
        .unknown_reason => error.InvalidVpcAccess,
    };
    return .{ .string = literal };
}

fn ownedValue(allocator: std.mem.Allocator, source: value.Value) BuildError!value.Value {
    return value.Value.initOwned(allocator, source) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn deinitOwnedValues(allocator: std.mem.Allocator, values: []value.Value) void {
    for (values) |*item| item.deinit(allocator);
    allocator.free(values);
}
