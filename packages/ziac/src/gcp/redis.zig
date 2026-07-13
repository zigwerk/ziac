const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || resource.ResourceGraphError || std.mem.Allocator.Error || error{
    DuplicateConfig,
    DuplicateRule,
    InvalidAclPolicy,
    InvalidCluster,
    InvalidConfig,
    InvalidInstance,
    InvalidKmsKey,
    InvalidLocation,
    InvalidMaintenanceWindow,
    InvalidNetwork,
    InvalidReplicaCount,
    MissingAuthSecret,
    MissingPrivateConnectivityDependency,
    OutputNotKnown,
};

pub const Config = struct { key: []const u8, value: []const u8 };

pub const Tier = enum {
    basic,
    standard_ha,

    pub fn apiName(self: Tier) []const u8 {
        return switch (self) {
            .basic => "BASIC",
            .standard_ha => "STANDARD_HA",
        };
    }
};

pub const RedisVersion = enum {
    redis_4_0,
    redis_5_0,
    redis_6_x,
    redis_7_0,
    redis_7_2,

    pub fn apiName(self: RedisVersion) []const u8 {
        return switch (self) {
            .redis_4_0 => "REDIS_4_0",
            .redis_5_0 => "REDIS_5_0",
            .redis_6_x => "REDIS_6_X",
            .redis_7_0 => "REDIS_7_0",
            .redis_7_2 => "REDIS_7_2",
        };
    }
};

pub const ConnectMode = enum {
    direct_peering,
    private_service_access,

    pub fn apiName(self: ConnectMode) []const u8 {
        return switch (self) {
            .direct_peering => "DIRECT_PEERING",
            .private_service_access => "PRIVATE_SERVICE_ACCESS",
        };
    }
};

pub const TransitEncryption = enum {
    disabled,
    server_authentication,

    pub fn classicApiName(self: TransitEncryption) []const u8 {
        return switch (self) {
            .disabled => "DISABLED",
            .server_authentication => "SERVER_AUTHENTICATION",
        };
    }

    pub fn clusterApiName(self: TransitEncryption) []const u8 {
        return switch (self) {
            .disabled => "TRANSIT_ENCRYPTION_MODE_DISABLED",
            .server_authentication => "TRANSIT_ENCRYPTION_MODE_SERVER_AUTHENTICATION",
        };
    }
};

pub const SnapshotPeriod = enum {
    one_hour,
    six_hours,
    twelve_hours,
    twenty_four_hours,

    pub fn apiName(self: SnapshotPeriod) []const u8 {
        return switch (self) {
            .one_hour => "ONE_HOUR",
            .six_hours => "SIX_HOURS",
            .twelve_hours => "TWELVE_HOURS",
            .twenty_four_hours => "TWENTY_FOUR_HOURS",
        };
    }
};

pub const Persistence = union(enum) {
    disabled,
    rdb: SnapshotPeriod,
};

pub const InstanceArgs = struct {
    instance_id: []const u8,
    location: []const u8,
    display_name: []const u8 = "",
    tier: Tier,
    memory_size_gb: u16,
    redis_version: RedisVersion = .redis_7_2,
    network: []const u8,
    connect_mode: ConnectMode = .direct_peering,
    connectivity_dependency: ?output.Output([]const u8, .public) = null,
    reserved_ip_range: []const u8 = "",
    auth_enabled: bool = true,
    auth_secret: ?output.Output([]const u8, .public) = null,
    transit_encryption: TransitEncryption = .server_authentication,
    read_replicas: u8 = 0,
    persistence: Persistence = .disabled,
    kms_key_name: []const u8 = "",
    maintenance_day: []const u8 = "",
    maintenance_hour_utc: u8 = 0,
    configs: []const Config = &.{},
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const Instance = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Host = output.Descriptor("host", []const u8, .public);
        pub const Port = output.Descriptor("port", i64, .public);
        pub const ReadEndpoint = output.Descriptor("read_endpoint", []const u8, .public);
        pub const AuthSecretVersion = output.Descriptor("auth_secret_version", value.SecretReference, .secret);
        pub const State = output.Descriptor("state", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    host: Outputs.Host.OutputType,
    port: Outputs.Port.OutputType,
    read_endpoint: Outputs.ReadEndpoint.OutputType,
    auth_secret_version: Outputs.AuthSecretVersion.OutputType,
    state: Outputs.State.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: InstanceArgs) BuildError!Instance {
        try provider.validate();
        try validateName(args.instance_id, error.InvalidInstance);
        try validateLocation(args.location);
        try validateNetwork(args.network);
        if (args.memory_size_gb == 0 or args.memory_size_gb > 300) return error.InvalidInstance;
        if (args.connect_mode == .private_service_access and args.connectivity_dependency == null) return error.MissingPrivateConnectivityDependency;
        if (args.auth_enabled and args.auth_secret == null) return error.MissingAuthSecret;
        if (args.tier == .basic and args.read_replicas != 0) return error.InvalidReplicaCount;
        if (args.tier == .standard_ha and args.read_replicas > 5) return error.InvalidReplicaCount;
        if (args.reserved_ip_range.len > 0 and std.mem.indexOfAny(u8, args.reserved_ip_range, "\x00\r\n ?/") != null) return error.InvalidInstance;
        if (!validMaintenanceWindow(args.maintenance_day, args.maintenance_hour_utc)) return error.InvalidMaintenanceWindow;
        try validateKms(args.kms_key_name);
        const configs = try configsAlloc(allocator, args.configs);
        defer allocator.free(configs);
        const persistence_mode, const snapshot_period = switch (args.persistence) {
            .disabled => .{ "DISABLED", "" },
            .rdb => |period| .{ "RDB", period.apiName() },
        };
        const dependency = if (args.connectivity_dependency) |present| try publicOutputValue(present) else value.Value{ .string = "" };
        const auth_secret = if (args.auth_secret) |present| try publicOutputValue(present) else value.Value{ .string = "" };
        const fields = [_]value.Field{
            .{ .name = "auth_enabled", .value = .{ .boolean = args.auth_enabled } },
            .{ .name = "auth_secret", .value = auth_secret },
            .{ .name = "configs", .value = .{ .string = configs } },
            .{ .name = "connect_mode", .value = .{ .string = args.connect_mode.apiName() } },
            .{ .name = "connectivity_dependency", .value = dependency },
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "instance_id", .value = .{ .string = args.instance_id } },
            .{ .name = "kms_key_name", .value = .{ .string = args.kms_key_name } },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "maintenance_day", .value = .{ .string = args.maintenance_day } },
            .{ .name = "maintenance_hour_utc", .value = .{ .integer = args.maintenance_hour_utc } },
            .{ .name = "memory_size_gb", .value = .{ .integer = args.memory_size_gb } },
            .{ .name = "network", .value = .{ .string = args.network } },
            .{ .name = "persistence_mode", .value = .{ .string = persistence_mode } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "read_replicas", .value = .{ .integer = args.read_replicas } },
            .{ .name = "redis_version", .value = .{ .string = args.redis_version.apiName() } },
            .{ .name = "reserved_ip_range", .value = .{ .string = args.reserved_ip_range } },
            .{ .name = "snapshot_period", .value = .{ .string = snapshot_period } },
            .{ .name = "tier", .value = .{ .string = args.tier.apiName() } },
            .{ .name = "transit_encryption", .value = .{ .string = args.transit_encryption.classicApiName() } },
        };
        const logical = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ args.location, args.instance_id });
        defer allocator.free(logical);
        const id = try std.fmt.allocPrint(allocator, "gcp.redis.Instance.{s}", .{logical});
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.redis.Instance", logical, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
            .operation_timeout_millis = 60 * 60 * 1000,
        });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .host = Outputs.Host.fromResource(node.id),
            .port = Outputs.Port.fromResource(node.id),
            .read_endpoint = Outputs.ReadEndpoint.fromResource(node.id),
            .auth_secret_version = Outputs.AuthSecretVersion.fromResource(node.id),
            .state = Outputs.State.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Instance, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn validMaintenanceWindow(day: []const u8, hour: u8) bool {
    if (day.len == 0) return hour == 0;
    if (hour > 23) return false;
    inline for (.{ "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY" }) |valid_day| {
        if (std.mem.eql(u8, day, valid_day)) return true;
    }
    return false;
}

pub const NodeType = enum {
    shared_core_nano,
    highmem_medium,
    highmem_xlarge,
    standard_small,
    highcpu_medium,
    standard_large,
    highmem_2xlarge,

    pub fn apiName(self: NodeType) []const u8 {
        return switch (self) {
            .shared_core_nano => "REDIS_SHARED_CORE_NANO",
            .highmem_medium => "REDIS_HIGHMEM_MEDIUM",
            .highmem_xlarge => "REDIS_HIGHMEM_XLARGE",
            .standard_small => "REDIS_STANDARD_SMALL",
            .highcpu_medium => "REDIS_HIGHCPU_MEDIUM",
            .standard_large => "REDIS_STANDARD_LARGE",
            .highmem_2xlarge => "REDIS_HIGHMEM_2XLARGE",
        };
    }
};

pub const Authorization = enum {
    disabled,
    iam_auth,
    token_auth,

    pub fn apiName(self: Authorization) []const u8 {
        return switch (self) {
            .disabled => "AUTH_MODE_DISABLED",
            .iam_auth => "AUTH_MODE_IAM_AUTH",
            .token_auth => "AUTH_MODE_TOKEN_AUTH",
        };
    }
};

pub const ClusterPersistence = enum { disabled, rdb, aof };

pub const ClusterArgs = struct {
    cluster_id: []const u8,
    location: []const u8,
    shard_count: u16,
    replica_count: u8 = 1,
    node_type: NodeType = .standard_small,
    network: []const u8,
    authorization: Authorization = .iam_auth,
    transit_encryption: TransitEncryption = .server_authentication,
    persistence: ClusterPersistence = .disabled,
    kms_key_name: []const u8 = "",
    acl_policy: ?output.Output([]const u8, .public) = null,
    deletion_protection: bool = true,
    configs: []const Config = &.{},
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const Cluster = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const DiscoveryEndpoint = output.Descriptor("discovery_endpoint", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
        pub const Uid = output.Descriptor("uid", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    discovery_endpoint: Outputs.DiscoveryEndpoint.OutputType,
    state: Outputs.State.OutputType,
    uid: Outputs.Uid.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ClusterArgs) BuildError!Cluster {
        try provider.validate();
        try validateName(args.cluster_id, error.InvalidCluster);
        try validateLocation(args.location);
        try validateNetwork(args.network);
        if (args.shard_count == 0 or args.shard_count > 250 or args.replica_count > 5) return error.InvalidCluster;
        try validateKms(args.kms_key_name);
        const configs = try configsAlloc(allocator, args.configs);
        defer allocator.free(configs);
        const acl_policy = if (args.acl_policy) |present| try publicOutputValue(present) else value.Value{ .string = "" };
        const fields = [_]value.Field{
            .{ .name = "acl_policy", .value = acl_policy },
            .{ .name = "authorization", .value = .{ .string = args.authorization.apiName() } },
            .{ .name = "cluster_id", .value = .{ .string = args.cluster_id } },
            .{ .name = "configs", .value = .{ .string = configs } },
            .{ .name = "deletion_protection", .value = .{ .boolean = args.deletion_protection } },
            .{ .name = "kms_key_name", .value = .{ .string = args.kms_key_name } },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "network", .value = .{ .string = args.network } },
            .{ .name = "node_type", .value = .{ .string = args.node_type.apiName() } },
            .{ .name = "persistence", .value = .{ .string = switch (args.persistence) {
                .disabled => "DISABLED",
                .rdb => "RDB",
                .aof => "AOF",
            } } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "replica_count", .value = .{ .integer = args.replica_count } },
            .{ .name = "shard_count", .value = .{ .integer = args.shard_count } },
            .{ .name = "transit_encryption", .value = .{ .string = args.transit_encryption.clusterApiName() } },
        };
        const logical = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ args.location, args.cluster_id });
        defer allocator.free(logical);
        const id = try std.fmt.allocPrint(allocator, "gcp.redis.Cluster.{s}", .{logical});
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.redis.Cluster", logical, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
            .operation_timeout_millis = 60 * 60 * 1000,
        });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .discovery_endpoint = Outputs.DiscoveryEndpoint.fromResource(node.id),
            .state = Outputs.State.fromResource(node.id),
            .uid = Outputs.Uid.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Cluster, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const AclRule = struct {
    username: []const u8,
    rule: output.Output(value.SecretReference, .secret),
};

pub const AclPolicyArgs = struct {
    policy_id: []const u8,
    location: []const u8,
    rules: []const AclRule,
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const AclPolicy = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    state: Outputs.State.OutputType,
    etag: Outputs.Etag.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: AclPolicyArgs) BuildError!AclPolicy {
        try provider.validate();
        try validateName(args.policy_id, error.InvalidAclPolicy);
        try validateLocation(args.location);
        if (args.rules.len == 0 or args.rules.len > 100) return error.InvalidAclPolicy;
        const sorted = try allocator.dupe(AclRule, args.rules);
        defer allocator.free(sorted);
        std.mem.sort(AclRule, sorted, {}, struct {
            fn lessThan(_: void, left: AclRule, right: AclRule) bool {
                return std.mem.order(u8, left.username, right.username) == .lt;
            }
        }.lessThan);
        const rules = try allocator.alloc(value.Value, sorted.len);
        defer allocator.free(rules);
        const rule_fields = try allocator.alloc([2]value.Field, sorted.len);
        defer allocator.free(rule_fields);
        for (sorted, 0..) |rule, index| {
            if (!validUsername(rule.username)) return error.InvalidAclPolicy;
            if (index > 0 and std.mem.eql(u8, sorted[index - 1].username, rule.username)) return error.DuplicateRule;
            rule_fields[index] = .{
                .{ .name = "rule", .value = try secretReferenceValue(rule.rule) },
                .{ .name = "username", .value = .{ .string = rule.username } },
            };
            rules[index] = .{ .object = &rule_fields[index] };
        }
        const fields = [_]value.Field{
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "policy_id", .value = .{ .string = args.policy_id } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "rules", .value = .{ .list = rules } },
        };
        const logical = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ args.location, args.policy_id });
        defer allocator.free(logical);
        const id = try std.fmt.allocPrint(allocator, "gcp.redis.AclPolicy.{s}", .{logical});
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.redis.AclPolicy", logical, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
            .operation_timeout_millis = 30 * 60 * 1000,
        });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .state = Outputs.State.fromResource(node.id),
            .etag = Outputs.Etag.fromResource(node.id),
        };
    }

    pub fn deinit(self: *AclPolicy, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn configsAlloc(allocator: std.mem.Allocator, configs: []const Config) BuildError![]const u8 {
    const sorted = try allocator.dupe(Config, configs);
    defer allocator.free(sorted);
    std.mem.sort(Config, sorted, {}, struct {
        fn lessThan(_: void, left: Config, right: Config) bool {
            return std.mem.order(u8, left.key, right.key) == .lt;
        }
    }.lessThan);
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    for (sorted, 0..) |config, index| {
        if (!validConfig(config)) return error.InvalidConfig;
        if (index > 0 and std.mem.eql(u8, sorted[index - 1].key, config.key)) return error.DuplicateConfig;
        if (index > 0) try result.append(allocator, '\n');
        try result.appendSlice(allocator, config.key);
        try result.append(allocator, '=');
        try result.appendSlice(allocator, config.value);
    }
    return result.toOwnedSlice(allocator);
}

fn validateName(name: []const u8, err: BuildError) BuildError!void {
    if (name.len == 0 or name.len > 63 or !std.ascii.isLower(name[0]) or !std.ascii.isAlphanumeric(name[name.len - 1])) return err;
    for (name) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return err;
}

fn validateLocation(location: []const u8) BuildError!void {
    if (location.len == 0 or location.len > 63 or !std.ascii.isLower(location[0]) or std.mem.indexOfAny(u8, location, "\x00\r\n /?") != null) return error.InvalidLocation;
}

fn validateNetwork(network: []const u8) BuildError!void {
    if (!std.mem.startsWith(u8, network, "projects/") or std.mem.indexOf(u8, network, "/global/networks/") == null or std.mem.indexOfAny(u8, network, "\x00\r\n ?") != null) return error.InvalidNetwork;
}

fn validateKms(name: []const u8) BuildError!void {
    if (name.len == 0) return;
    if (!std.mem.startsWith(u8, name, "projects/") or std.mem.indexOf(u8, name, "/locations/") == null or std.mem.indexOf(u8, name, "/keyRings/") == null or std.mem.indexOf(u8, name, "/cryptoKeys/") == null or std.mem.indexOfAny(u8, name, "\x00\r\n ?") != null) return error.InvalidKmsKey;
}

fn validConfig(config: Config) bool {
    if (config.key.len == 0 or config.key.len > 128 or config.value.len > 1024) return false;
    for (config.key) |character| if (!std.ascii.isAlphanumeric(character) and character != '-' and character != '_') return false;
    return std.mem.indexOfAny(u8, config.value, "\x00\r\n") == null;
}

fn validUsername(username: []const u8) bool {
    if (username.len == 0 or username.len > 128 or std.mem.indexOfAny(u8, username, "\x00\r\n ") != null) return false;
    return true;
}

fn publicOutputValue(candidate: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (candidate) {
        .value => |text| .{ .string = text },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn secretReferenceValue(candidate: output.Output(value.SecretReference, .secret)) BuildError!value.Value {
    return switch (candidate) {
        .value => |reference| .{ .secret_ref = reference },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn nodeOwned(allocator: std.mem.Allocator, id: []const u8, type_name: []const u8, logical_id: []const u8, fields: []const value.Field, lifecycle: resource.Lifecycle) BuildError!resource.ResourceNode {
    return resource.ResourceNode.initOwned(allocator, .{
        .id = id,
        .provider = .gcp,
        .type_name = type_name,
        .schema_version = 1,
        .logical_id = logical_id,
        .inputs = .{ .object = fields },
        .lifecycle = lifecycle,
    });
}
