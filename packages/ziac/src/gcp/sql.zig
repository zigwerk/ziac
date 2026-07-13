const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    DuplicateFlag,
    InvalidAuthorizedNetwork,
    InvalidDatabase,
    InvalidDatabaseFlag,
    InvalidDisk,
    InvalidInstance,
    InvalidNetworkConfiguration,
    InvalidRegion,
    InvalidSecretReference,
    InvalidTier,
    InvalidUser,
    OutputNotKnown,
    PasswordForbidden,
    PasswordRequired,
};

pub const PostgresVersion = enum {
    postgres_13,
    postgres_14,
    postgres_15,
    postgres_16,
    postgres_17,
    postgres_18,
    postgres_19,
    postgres_20,

    pub fn apiName(self: PostgresVersion) []const u8 {
        return switch (self) {
            .postgres_13 => "POSTGRES_13",
            .postgres_14 => "POSTGRES_14",
            .postgres_15 => "POSTGRES_15",
            .postgres_16 => "POSTGRES_16",
            .postgres_17 => "POSTGRES_17",
            .postgres_18 => "POSTGRES_18",
            .postgres_19 => "POSTGRES_19",
            .postgres_20 => "POSTGRES_20",
        };
    }
};

pub const Edition = enum {
    enterprise,
    enterprise_plus,
    developer,

    pub fn apiName(self: Edition) []const u8 {
        return switch (self) {
            .enterprise => "ENTERPRISE",
            .enterprise_plus => "ENTERPRISE_PLUS",
            .developer => "DEVELOPER",
        };
    }
};

pub const Availability = enum {
    zonal,
    regional,

    pub fn apiName(self: Availability) []const u8 {
        return switch (self) {
            .zonal => "ZONAL",
            .regional => "REGIONAL",
        };
    }
};

pub const DiskType = enum {
    pd_ssd,
    pd_hdd,
    hyperdisk_balanced,

    pub fn apiName(self: DiskType) []const u8 {
        return switch (self) {
            .pd_ssd => "PD_SSD",
            .pd_hdd => "PD_HDD",
            .hyperdisk_balanced => "HYPERDISK_BALANCED",
        };
    }
};

pub const SslMode = enum {
    allow_unencrypted_and_encrypted,
    encrypted_only,
    trusted_client_certificate_required,

    pub fn apiName(self: SslMode) []const u8 {
        return switch (self) {
            .allow_unencrypted_and_encrypted => "ALLOW_UNENCRYPTED_AND_ENCRYPTED",
            .encrypted_only => "ENCRYPTED_ONLY",
            .trusted_client_certificate_required => "TRUSTED_CLIENT_CERTIFICATE_REQUIRED",
        };
    }
};

pub const ConnectorEnforcement = enum {
    not_required,
    required,

    pub fn apiName(self: ConnectorEnforcement) []const u8 {
        return switch (self) {
            .not_required => "NOT_REQUIRED",
            .required => "REQUIRED",
        };
    }
};

pub const DatabaseFlag = struct {
    name: []const u8,
    value: []const u8,
};

pub const AuthorizedNetwork = struct {
    name: []const u8,
    cidr: []const u8,
    expiration_time: []const u8 = "",
};

pub const BackupConfiguration = struct {
    enabled: bool = true,
    start_time: []const u8 = "03:00",
    point_in_time_recovery: bool = false,
    retained_backups: u8 = 7,
    transaction_log_retention_days: u8 = 7,
};

pub const MaintenanceUpdateTrack = enum {
    canary,
    stable,
    week5,

    pub fn apiName(self: MaintenanceUpdateTrack) []const u8 {
        return switch (self) {
            .canary => "canary",
            .stable => "stable",
            .week5 => "week5",
        };
    }
};

pub const MaintenanceWindow = struct {
    day: u8 = 7,
    hour: u8 = 4,
    update_track: MaintenanceUpdateTrack = .stable,
};

pub const InstanceArgs = struct {
    instance_id: []const u8,
    database_version: PostgresVersion,
    region: []const u8,
    tier: []const u8,
    edition: Edition = .enterprise,
    availability: Availability = .zonal,
    disk_type: DiskType = .pd_ssd,
    disk_size_gb: u64 = 20,
    disk_autoresize: bool = true,
    backup: BackupConfiguration = .{},
    maintenance: MaintenanceWindow = .{},
    point_in_time_recovery: bool = false,
    deletion_protection: bool = true,
    database_flags: []const DatabaseFlag = &.{},
    private_network: []const u8 = "",
    allocated_ip_range: []const u8 = "",
    ipv4_enabled: bool = false,
    authorized_networks: []const AuthorizedNetwork = &.{},
    enable_private_path: bool = false,
    ssl_mode: SslMode = .encrypted_only,
    connector_enforcement: ConnectorEnforcement = .not_required,
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const Instance = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const InstanceId = output.Descriptor("instance_id", []const u8, .public);
        pub const ConnectionName = output.Descriptor("connection_name", []const u8, .public);
        pub const PrivateIp = output.Descriptor("private_ip", []const u8, .public);
        pub const PublicIp = output.Descriptor("public_ip", []const u8, .public);
        pub const ServerCaCert = output.Descriptor("server_ca_cert", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
        pub const SettingsVersion = output.Descriptor("settings_version", i64, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    instance_id: Outputs.InstanceId.OutputType,
    connection_name: Outputs.ConnectionName.OutputType,
    private_ip: Outputs.PrivateIp.OutputType,
    public_ip: Outputs.PublicIp.OutputType,
    server_ca_cert: Outputs.ServerCaCert.OutputType,
    state: Outputs.State.OutputType,
    settings_version: Outputs.SettingsVersion.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: InstanceArgs) BuildError!Instance {
        const node = try instanceNodeOwned(allocator, provider, "gcp.sql.Instance", args, null);
        return instanceFromNode(node);
    }

    pub fn deinit(self: *Instance, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const ReadReplicaArgs = struct {
    instance_id: []const u8,
    primary_instance_id: output.Output([]const u8, .public),
    database_version: PostgresVersion,
    region: []const u8,
    tier: []const u8,
    edition: Edition = .enterprise,
    disk_type: DiskType = .pd_ssd,
    disk_size_gb: u64 = 20,
    disk_autoresize: bool = true,
    private_network: []const u8 = "",
    ipv4_enabled: bool = false,
    ssl_mode: SslMode = .encrypted_only,
    connector_enforcement: ConnectorEnforcement = .not_required,
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const ReadReplica = struct {
    node: resource.ResourceNode,
    name: Instance.Outputs.Name.OutputType,
    instance_id: Instance.Outputs.InstanceId.OutputType,
    connection_name: Instance.Outputs.ConnectionName.OutputType,
    private_ip: Instance.Outputs.PrivateIp.OutputType,
    public_ip: Instance.Outputs.PublicIp.OutputType,
    server_ca_cert: Instance.Outputs.ServerCaCert.OutputType,
    state: Instance.Outputs.State.OutputType,
    settings_version: Instance.Outputs.SettingsVersion.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ReadReplicaArgs) BuildError!ReadReplica {
        const primary = try publicOutputValue(args.primary_instance_id);
        const node = try instanceNodeOwned(allocator, provider, "gcp.sql.ReadReplica", .{
            .instance_id = args.instance_id,
            .database_version = args.database_version,
            .region = args.region,
            .tier = args.tier,
            .edition = args.edition,
            .availability = .zonal,
            .disk_type = args.disk_type,
            .disk_size_gb = args.disk_size_gb,
            .disk_autoresize = args.disk_autoresize,
            .backup = .{ .enabled = false },
            .deletion_protection = true,
            .private_network = args.private_network,
            .ipv4_enabled = args.ipv4_enabled,
            .ssl_mode = args.ssl_mode,
            .connector_enforcement = args.connector_enforcement,
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
        }, primary);
        const instance = instanceFromNode(node);
        return .{
            .node = instance.node,
            .name = instance.name,
            .instance_id = instance.instance_id,
            .connection_name = instance.connection_name,
            .private_ip = instance.private_ip,
            .public_ip = instance.public_ip,
            .server_ca_cert = instance.server_ca_cert,
            .state = instance.state,
            .settings_version = instance.settings_version,
        };
    }

    pub fn deinit(self: *ReadReplica, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const DatabaseArgs = struct {
    instance_id: []const u8,
    name: []const u8,
    charset: []const u8 = "UTF8",
    collation: []const u8 = "en_US.UTF8",
    retain_on_delete: bool = true,
};

pub const Database = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    self_link: Outputs.SelfLink.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: DatabaseArgs) BuildError!Database {
        try provider.validate();
        try validateInstanceId(args.instance_id);
        try validateDatabaseName(args.name);
        if (!validSimpleValue(args.charset) or !validSimpleValue(args.collation)) return error.InvalidDatabase;
        const fields = [_]value.Field{
            .{ .name = "charset", .value = .{ .string = args.charset } },
            .{ .name = "collation", .value = .{ .string = args.collation } },
            .{ .name = "instance_id", .value = .{ .string = args.instance_id } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.sql.Database.{s}.{s}", .{ args.instance_id, args.name });
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.sql.Database", args.name, &fields, .{ .retain_on_delete = args.retain_on_delete });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .self_link = Outputs.SelfLink.fromResource(node.id) };
    }

    pub fn deinit(self: *Database, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const UserType = enum {
    built_in,
    cloud_iam_user,
    cloud_iam_service_account,
    cloud_iam_group,

    pub fn apiName(self: UserType) []const u8 {
        return switch (self) {
            .built_in => "BUILT_IN",
            .cloud_iam_user => "CLOUD_IAM_USER",
            .cloud_iam_service_account => "CLOUD_IAM_SERVICE_ACCOUNT",
            .cloud_iam_group => "CLOUD_IAM_GROUP",
        };
    }
};

pub const UserArgs = struct {
    instance_id: []const u8,
    name: []const u8,
    user_type: UserType = .built_in,
    host: []const u8 = "",
    password: ?output.Output(value.SecretReference, .secret) = null,
};

pub const User = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const UserType = output.Descriptor("user_type", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    user_type: Outputs.UserType.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: UserArgs) BuildError!User {
        try provider.validate();
        try validateInstanceId(args.instance_id);
        try validateUser(args.name, args.user_type);
        if (args.host.len > 255 or std.mem.indexOfScalar(u8, args.host, '\n') != null) return error.InvalidUser;
        const password = if (args.password) |secret| try secretOutputValue(secret) else null;
        if (args.user_type == .built_in and password == null) return error.PasswordRequired;
        if (args.user_type != .built_in and password != null) return error.PasswordForbidden;
        const fields = [_]value.Field{
            .{ .name = "host", .value = .{ .string = args.host } },
            .{ .name = "instance_id", .value = .{ .string = args.instance_id } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "password", .value = password orelse .{ .string = "" } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "user_type", .value = .{ .string = args.user_type.apiName() } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.sql.User.{s}.{s}.{s}", .{ args.instance_id, @tagName(args.user_type), args.name });
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.sql.User", args.name, &fields, .{});
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .user_type = Outputs.UserType.fromResource(node.id) };
    }

    pub fn deinit(self: *User, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const ClientCertificateArgs = struct {
    instance_id: []const u8,
    common_name: []const u8,
    private_key_secret: output.Output([]const u8, .public),
    imported_private_key_version: []const u8 = "",
};

pub const ClientCertificate = struct {
    pub const Outputs = struct {
        pub const Fingerprint = output.Descriptor("sha1_fingerprint", []const u8, .public);
        pub const Certificate = output.Descriptor("certificate", []const u8, .public);
        pub const ExpirationTime = output.Descriptor("expiration_time", []const u8, .public);
        pub const PrivateKeyVersion = output.Descriptor("private_key_version", value.SecretReference, .secret);
    };

    node: resource.ResourceNode,
    sha1_fingerprint: Outputs.Fingerprint.OutputType,
    certificate: Outputs.Certificate.OutputType,
    expiration_time: Outputs.ExpirationTime.OutputType,
    private_key_version: Outputs.PrivateKeyVersion.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ClientCertificateArgs) BuildError!ClientCertificate {
        try provider.validate();
        try validateInstanceId(args.instance_id);
        if (!validCommonName(args.common_name)) return error.InvalidInstance;
        const secret = try publicOutputValue(args.private_key_secret);
        const fields = [_]value.Field{
            .{ .name = "common_name", .value = .{ .string = args.common_name } },
            .{ .name = "instance_id", .value = .{ .string = args.instance_id } },
            .{ .name = "imported_private_key_version", .value = .{ .string = args.imported_private_key_version } },
            .{ .name = "private_key_secret", .value = secret },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.sql.ClientCertificate.{s}.{s}", .{ args.instance_id, args.common_name });
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.sql.ClientCertificate", args.common_name, &fields, .{});
        return .{
            .node = node,
            .sha1_fingerprint = Outputs.Fingerprint.fromResource(node.id),
            .certificate = Outputs.Certificate.fromResource(node.id),
            .expiration_time = Outputs.ExpirationTime.fromResource(node.id),
            .private_key_version = Outputs.PrivateKeyVersion.fromResource(node.id),
        };
    }

    pub fn deinit(self: *ClientCertificate, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn instanceNodeOwned(
    allocator: std.mem.Allocator,
    provider: config_mod.ProviderConfig,
    type_name: []const u8,
    args: InstanceArgs,
    primary: ?value.Value,
) BuildError!resource.ResourceNode {
    try provider.validate();
    try validateInstanceArgs(args, primary != null);
    const flags = try databaseFlagsValueAlloc(allocator, args.database_flags);
    defer freeTemporaryList(allocator, flags);
    const networks = try authorizedNetworksValueAlloc(allocator, args.authorized_networks);
    defer freeTemporaryList(allocator, networks);
    const fields = [_]value.Field{
        .{ .name = "allocated_ip_range", .value = .{ .string = args.allocated_ip_range } },
        .{ .name = "authorized_networks", .value = networks },
        .{ .name = "availability", .value = .{ .string = args.availability.apiName() } },
        .{ .name = "backup_enabled", .value = .{ .boolean = args.backup.enabled } },
        .{ .name = "backup_start_time", .value = .{ .string = args.backup.start_time } },
        .{ .name = "connector_enforcement", .value = .{ .string = args.connector_enforcement.apiName() } },
        .{ .name = "database_flags", .value = flags },
        .{ .name = "database_version", .value = .{ .string = args.database_version.apiName() } },
        .{ .name = "deletion_protection", .value = .{ .boolean = args.deletion_protection } },
        .{ .name = "disk_autoresize", .value = .{ .boolean = args.disk_autoresize } },
        .{ .name = "disk_size_gb", .value = .{ .integer = @intCast(args.disk_size_gb) } },
        .{ .name = "disk_type", .value = .{ .string = args.disk_type.apiName() } },
        .{ .name = "edition", .value = .{ .string = args.edition.apiName() } },
        .{ .name = "enable_private_path", .value = .{ .boolean = args.enable_private_path } },
        .{ .name = "instance_id", .value = .{ .string = args.instance_id } },
        .{ .name = "ipv4_enabled", .value = .{ .boolean = args.ipv4_enabled } },
        .{ .name = "maintenance_day", .value = .{ .integer = args.maintenance.day } },
        .{ .name = "maintenance_hour", .value = .{ .integer = args.maintenance.hour } },
        .{ .name = "maintenance_update_track", .value = .{ .string = args.maintenance.update_track.apiName() } },
        .{ .name = "point_in_time_recovery", .value = .{ .boolean = args.point_in_time_recovery or args.backup.point_in_time_recovery } },
        .{ .name = "primary_instance_id", .value = primary orelse .{ .string = "" } },
        .{ .name = "private_network", .value = .{ .string = args.private_network } },
        .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        .{ .name = "region", .value = .{ .string = args.region } },
        .{ .name = "retained_backups", .value = .{ .integer = args.backup.retained_backups } },
        .{ .name = "ssl_mode", .value = .{ .string = args.ssl_mode.apiName() } },
        .{ .name = "tier", .value = .{ .string = args.tier } },
        .{ .name = "transaction_log_retention_days", .value = .{ .integer = args.backup.transaction_log_retention_days } },
    };
    const id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_name, args.instance_id });
    defer allocator.free(id);
    return nodeOwned(allocator, id, type_name, args.instance_id, &fields, .{
        .protect = args.protect,
        .retain_on_delete = args.retain_on_delete,
        .operation_timeout_millis = 60 * 60 * 1000,
    });
}

fn instanceFromNode(node: resource.ResourceNode) Instance {
    return .{
        .node = node,
        .name = Instance.Outputs.Name.fromResource(node.id),
        .instance_id = Instance.Outputs.InstanceId.fromResource(node.id),
        .connection_name = Instance.Outputs.ConnectionName.fromResource(node.id),
        .private_ip = Instance.Outputs.PrivateIp.fromResource(node.id),
        .public_ip = Instance.Outputs.PublicIp.fromResource(node.id),
        .server_ca_cert = Instance.Outputs.ServerCaCert.fromResource(node.id),
        .state = Instance.Outputs.State.fromResource(node.id),
        .settings_version = Instance.Outputs.SettingsVersion.fromResource(node.id),
    };
}

fn validateInstanceArgs(args: InstanceArgs, replica: bool) BuildError!void {
    try validateInstanceId(args.instance_id);
    try validateRegion(args.region);
    if (!validTier(args.tier)) return error.InvalidTier;
    if (args.disk_size_gb < 10 or args.disk_size_gb > 65_536 or args.disk_size_gb > std.math.maxInt(i64)) return error.InvalidDisk;
    if (args.point_in_time_recovery and !args.backup.enabled) return error.InvalidInstance;
    if (!validTime(args.backup.start_time) or args.backup.retained_backups == 0 or args.backup.retained_backups > 365 or
        args.backup.transaction_log_retention_days < 1 or args.backup.transaction_log_retention_days > 7) return error.InvalidInstance;
    if (args.maintenance.day < 1 or args.maintenance.day > 7 or args.maintenance.hour > 23) return error.InvalidInstance;
    if (args.private_network.len > 0 and !validNetworkName(args.private_network)) return error.InvalidNetworkConfiguration;
    if (args.allocated_ip_range.len > 0 and (args.private_network.len == 0 or replica or !validRfc1035(args.allocated_ip_range))) return error.InvalidNetworkConfiguration;
    if (args.enable_private_path and (args.private_network.len == 0 or args.ipv4_enabled)) return error.InvalidNetworkConfiguration;
    if (args.authorized_networks.len > 0 and (!args.ipv4_enabled or args.connector_enforcement == .required)) return error.InvalidNetworkConfiguration;
    for (args.authorized_networks, 0..) |network, index| {
        if (!validNetworkEntry(network)) return error.InvalidAuthorizedNetwork;
        for (args.authorized_networks[index + 1 ..]) |other| if (std.mem.eql(u8, network.cidr, other.cidr)) return error.InvalidAuthorizedNetwork;
    }
    for (args.database_flags, 0..) |flag, index| {
        if (!validFlag(flag)) return error.InvalidDatabaseFlag;
        for (args.database_flags[index + 1 ..]) |other| if (std.mem.eql(u8, flag.name, other.name)) return error.DuplicateFlag;
    }
}

fn databaseFlagsValueAlloc(allocator: std.mem.Allocator, flags: []const DatabaseFlag) !value.Value {
    const items = try allocator.alloc(value.Value, flags.len);
    errdefer allocator.free(items);
    for (flags, 0..) |flag, index| {
        const fields = try allocator.alloc(value.Field, 2);
        fields[0] = .{ .name = "name", .value = .{ .string = flag.name } };
        fields[1] = .{ .name = "value", .value = .{ .string = flag.value } };
        items[index] = .{ .object = fields };
    }
    std.mem.sort(value.Value, items, {}, lessThanFlagValue);
    return .{ .list = items };
}

fn authorizedNetworksValueAlloc(allocator: std.mem.Allocator, networks: []const AuthorizedNetwork) !value.Value {
    const items = try allocator.alloc(value.Value, networks.len);
    errdefer allocator.free(items);
    for (networks, 0..) |network, index| {
        const fields = try allocator.alloc(value.Field, 3);
        fields[0] = .{ .name = "expiration_time", .value = .{ .string = network.expiration_time } };
        fields[1] = .{ .name = "name", .value = .{ .string = network.name } };
        fields[2] = .{ .name = "value", .value = .{ .string = network.cidr } };
        items[index] = .{ .object = fields };
    }
    std.mem.sort(value.Value, items, {}, lessThanNetworkValue);
    return .{ .list = items };
}

fn lessThanFlagValue(_: void, left: value.Value, right: value.Value) bool {
    return std.mem.order(u8, valueObjectString(left, "name"), valueObjectString(right, "name")) == .lt;
}

fn lessThanNetworkValue(_: void, left: value.Value, right: value.Value) bool {
    const value_order = std.mem.order(u8, valueObjectString(left, "value"), valueObjectString(right, "value"));
    if (value_order != .eq) return value_order == .lt;
    return std.mem.order(u8, valueObjectString(left, "name"), valueObjectString(right, "name")) == .lt;
}

fn valueObjectString(candidate: value.Value, name: []const u8) []const u8 {
    const fields = switch (candidate) {
        .object => |present| present,
        else => return "",
    };
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return switch (field.value) {
        .string => |text| text,
        else => "",
    };
    return "";
}

fn freeTemporaryList(allocator: std.mem.Allocator, temporary: value.Value) void {
    const items = switch (temporary) {
        .list => |items| items,
        else => return,
    };
    for (items) |item| if (item == .object) allocator.free(item.object);
    allocator.free(items);
}

fn publicOutputValue(candidate: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (candidate) {
        .value => |text| .{ .string = text },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn secretOutputValue(candidate: output.Output(value.SecretReference, .secret)) BuildError!value.Value {
    return switch (candidate) {
        .value => |reference| .{ .secret_ref = reference },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn nodeOwned(
    allocator: std.mem.Allocator,
    id: []const u8,
    type_name: []const u8,
    logical_id: []const u8,
    fields: []const value.Field,
    lifecycle: resource.Lifecycle,
) BuildError!resource.ResourceNode {
    return resource.ResourceNode.initOwned(allocator, .{
        .id = id,
        .provider = .gcp,
        .type_name = type_name,
        .logical_id = logical_id,
        .inputs = .{ .object = fields },
        .lifecycle = lifecycle,
    }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
    };
}

fn validateInstanceId(id: []const u8) BuildError!void {
    if (id.len == 0 or id.len > 98 or !std.ascii.isLower(id[0]) or !std.ascii.isAlphanumeric(id[id.len - 1])) return error.InvalidInstance;
    for (id) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return error.InvalidInstance;
}

fn validateRegion(region: []const u8) BuildError!void {
    if (region.len < 3 or region.len > 63 or !std.ascii.isLower(region[0])) return error.InvalidRegion;
    for (region) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return error.InvalidRegion;
}

fn validateDatabaseName(name: []const u8) BuildError!void {
    if (name.len == 0 or name.len > 63 or std.mem.indexOfAny(u8, name, "/\n\r\x00") != null) return error.InvalidDatabase;
}

fn validateUser(name: []const u8, user_type: UserType) BuildError!void {
    if (name.len == 0 or name.len > 128 or std.mem.indexOfAny(u8, name, "/\n\r\x00") != null) return error.InvalidUser;
    if (user_type != .built_in) for (name) |character| if (std.ascii.isUpper(character)) return error.InvalidUser;
}

fn validTier(tier: []const u8) bool {
    if (tier.len < 3 or tier.len > 100) return false;
    for (tier) |character| if (!std.ascii.isAlphanumeric(character) and character != '-' and character != '_') return false;
    return true;
}

fn validSimpleValue(text: []const u8) bool {
    if (text.len == 0 or text.len > 128) return false;
    return std.mem.indexOfAny(u8, text, "\n\r\x00") == null;
}

fn validFlag(flag: DatabaseFlag) bool {
    if (flag.name.len == 0 or flag.name.len > 128 or flag.value.len > 1024) return false;
    for (flag.name) |character| if (!std.ascii.isAlphanumeric(character) and character != '_' and character != '.' and character != '-') return false;
    return std.mem.indexOfAny(u8, flag.value, "\n\r\x00") == null;
}

fn validNetworkName(name: []const u8) bool {
    const prefix = "projects/";
    if (!std.mem.startsWith(u8, name, prefix)) return false;
    return std.mem.indexOf(u8, name[prefix.len..], "/global/networks/") != null and std.mem.indexOfAny(u8, name, "\n\r\x00") == null;
}

fn validRfc1035(name: []const u8) bool {
    if (name.len == 0 or name.len > 63 or !std.ascii.isLower(name[0]) or !std.ascii.isAlphanumeric(name[name.len - 1])) return false;
    for (name) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return false;
    return true;
}

fn validNetworkEntry(network: AuthorizedNetwork) bool {
    if (network.name.len == 0 or network.name.len > 128 or network.cidr.len == 0 or network.cidr.len > 43) return false;
    if (std.mem.indexOfScalar(u8, network.cidr, '/') == null or std.mem.indexOfAny(u8, network.cidr, "\n\r\x00") != null) return false;
    return network.expiration_time.len <= 64 and std.mem.indexOfAny(u8, network.expiration_time, "\n\r\x00") == null;
}

fn validTime(time: []const u8) bool {
    if (time.len != 5 or time[2] != ':' or !std.ascii.isDigit(time[0]) or !std.ascii.isDigit(time[1]) or !std.ascii.isDigit(time[3]) or !std.ascii.isDigit(time[4])) return false;
    const hour = (time[0] - '0') * 10 + time[1] - '0';
    const minute = (time[3] - '0') * 10 + time[4] - '0';
    return hour < 24 and minute < 60;
}

fn validCommonName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |character| if (!std.ascii.isAlphanumeric(character) and character != '-' and character != '_' and character != '.') return false;
    return true;
}
