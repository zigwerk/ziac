const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const artifact = @import("artifact_registry.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    DuplicateKey,
    InvalidConnection,
    InvalidDiskSize,
    InvalidName,
    InvalidNetwork,
    InvalidPattern,
    InvalidPath,
    InvalidRedirection,
    InvalidRegion,
    InvalidRemoteUri,
    InvalidSecretReference,
    InvalidServiceAccount,
    InvalidValue,
    OutputNotKnown,
};

pub const Annotation = struct { key: []const u8, value: []const u8 };

pub const GitHubConfig = struct {
    oauth_token_secret_version: ?[]const u8 = null,
    app_installation_id: ?[]const u8 = null,
};

pub const GitHubEnterpriseConfig = struct {
    host_uri: []const u8,
    api_key: output.Output(value.SecretReference, .secret),
    app_id: ?[]const u8 = null,
    app_slug: ?[]const u8 = null,
    private_key_secret_version: []const u8,
    webhook_secret_version: []const u8,
    app_installation_id: ?[]const u8 = null,
    service_directory_service: ?[]const u8 = null,
    ssl_ca: ?[]const u8 = null,
};

pub const GitLabConfig = struct {
    host_uri: []const u8 = "https://gitlab.com",
    authorizer_secret_version: []const u8,
    read_authorizer_secret_version: []const u8,
    webhook_secret_version: []const u8,
    service_directory_service: ?[]const u8 = null,
    ssl_ca: ?[]const u8 = null,
};

pub const BitbucketDataCenterConfig = struct {
    host_uri: []const u8,
    authorizer_secret_version: []const u8,
    read_authorizer_secret_version: []const u8,
    webhook_secret_version: []const u8,
    service_directory_service: ?[]const u8 = null,
    ssl_ca: ?[]const u8 = null,
};

pub const BitbucketCloudConfig = struct {
    workspace: []const u8,
    authorizer_secret_version: []const u8,
    read_authorizer_secret_version: []const u8,
    webhook_secret_version: []const u8,
};

pub const ConnectionConfig = union(enum) {
    github: GitHubConfig,
    github_enterprise: GitHubEnterpriseConfig,
    gitlab: GitLabConfig,
    bitbucket_data_center: BitbucketDataCenterConfig,
    bitbucket_cloud: BitbucketCloudConfig,
};

pub const ConnectionArgs = struct {
    name: []const u8,
    location: []const u8,
    config: ConnectionConfig,
    disabled: bool = false,
    annotations: []const Annotation = &.{},
    protect: bool = true,
};

pub const Connection = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const InstallationState = output.Descriptor("installation_state", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    installation_state: Outputs.InstallationState.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ConnectionArgs) BuildError!Connection {
        try provider.validate();
        try validateName(args.name);
        if (!configuredLocation(provider, args.location, true)) return error.InvalidRegion;
        var config_value = try connectionConfigValue(allocator, args.config);
        defer config_value.deinit(allocator);
        var annotations = try mapValue(allocator, args.annotations);
        defer annotations.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "annotations", .value = annotations },
            .{ .name = "config", .value = config_value },
            .{ .name = "disabled", .value = .{ .boolean = args.disabled } },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        };
        const node = try nodeOwned(allocator, "gcp.cloudbuild.Connection", args.location, args.name, &fields, .{ .protect = args.protect });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .installation_state = Outputs.InstallationState.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Connection, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const RepositoryArgs = struct {
    name: []const u8,
    location: []const u8,
    connection_name: []const u8,
    connection: output.Output([]const u8, .public),
    remote_uri: []const u8,
    annotations: []const Annotation = &.{},
    protect: bool = true,
};

pub const Repository = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const WebhookId = output.Descriptor("webhook_id", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    webhook_id: Outputs.WebhookId.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: RepositoryArgs) BuildError!Repository {
        try provider.validate();
        try validateName(args.name);
        try validateName(args.connection_name);
        if (!configuredLocation(provider, args.location, true)) return error.InvalidRegion;
        try validateHttpsUri(args.remote_uri);
        var annotations = try mapValue(allocator, args.annotations);
        defer annotations.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "annotations", .value = annotations },
            .{ .name = "connection", .value = try publicOutputValue(args.connection) },
            .{ .name = "connection_name", .value = .{ .string = args.connection_name } },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "remote_uri", .value = .{ .string = args.remote_uri } },
        };
        const node = try nodeOwned(allocator, "gcp.cloudbuild.Repository", args.location, args.name, &fields, .{ .protect = args.protect });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .webhook_id = Outputs.WebhookId.fromResource(node.id) };
    }

    pub fn deinit(self: *Repository, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const Egress = enum {
    public,
    no_public,

    pub fn apiName(self: Egress) []const u8 {
        return if (self == .no_public) "NO_PUBLIC_EGRESS" else "PUBLIC_EGRESS";
    }
};

pub const PeeredNetwork = struct {
    network: []const u8,
    ip_range: []const u8 = "/24",
    egress: Egress = .public,
};

pub const PscNetwork = struct {
    network_attachment: []const u8,
    public_ip_disabled: bool = true,
    route_all_traffic: bool = false,
};

pub const WorkerNetwork = union(enum) {
    peered: PeeredNetwork,
    psc: PscNetwork,
};

pub const WorkerPoolArgs = struct {
    name: []const u8,
    location: []const u8,
    display_name: []const u8 = "",
    machine_type: []const u8 = "e2-medium",
    disk_size_gb: u16 = 100,
    nested_virtualization: bool = false,
    network: ?WorkerNetwork = null,
    annotations: []const Annotation = &.{},
    protect: bool = true,
};

pub const WorkerPool = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    state: Outputs.State.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: WorkerPoolArgs) BuildError!WorkerPool {
        try provider.validate();
        try validateName(args.name);
        if (!configuredLocation(provider, args.location, false)) return error.InvalidRegion;
        if (args.display_name.len > 63 or args.machine_type.len == 0) return error.InvalidValue;
        if (args.disk_size_gb < 100 or args.disk_size_gb > 4000) return error.InvalidDiskSize;
        var network = try networkValue(allocator, args.location, args.network);
        defer network.deinit(allocator);
        var annotations = try mapValue(allocator, args.annotations);
        defer annotations.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "annotations", .value = annotations },
            .{ .name = "disk_size_gb", .value = .{ .integer = args.disk_size_gb } },
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "machine_type", .value = .{ .string = args.machine_type } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "nested_virtualization", .value = .{ .boolean = args.nested_virtualization } },
            .{ .name = "network", .value = network },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        };
        const node = try nodeOwned(allocator, "gcp.cloudbuild.WorkerPool", args.location, args.name, &fields, .{ .protect = args.protect });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .state = Outputs.State.fromResource(node.id) };
    }

    pub fn deinit(self: *WorkerPool, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const PushFilter = union(enum) { branch: []const u8, tag: []const u8 };
pub const PullRequestFilter = struct {
    branch: []const u8,
    require_comment: bool = true,
};
pub const TriggerEvent = union(enum) { push: PushFilter, pull_request: PullRequestFilter };
pub const Substitution = struct { key: []const u8, value: []const u8 };

pub const TriggerArgs = struct {
    name: []const u8,
    location: []const u8,
    repository: output.Output([]const u8, .public),
    event: TriggerEvent,
    filename: []const u8,
    description: []const u8 = "",
    service_account: ?[]const u8 = null,
    require_approval: bool = false,
    disabled: bool = false,
    worker_pool: ?output.Output([]const u8, .public) = null,
    substitutions: []const Substitution = &.{},
    included_files: []const []const u8 = &.{},
    ignored_files: []const []const u8 = &.{},
    protect: bool = false,
};

pub const Trigger = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: TriggerArgs) BuildError!Trigger {
        try provider.validate();
        try validateName(args.name);
        if (!configuredLocation(provider, args.location, true)) return error.InvalidRegion;
        try validatePath(args.filename);
        if (args.description.len > 1024) return error.InvalidValue;
        if (args.service_account) |account| try validateServiceAccount(account, provider.project_id);
        var event = try eventValue(allocator, args.event);
        defer event.deinit(allocator);
        var substitutions = try substitutionsValue(allocator, args.substitutions);
        defer substitutions.deinit(allocator);
        var included = try stringListValue(allocator, args.included_files);
        defer included.deinit(allocator);
        var ignored = try stringListValue(allocator, args.ignored_files);
        defer ignored.deinit(allocator);
        const worker_pool = if (args.worker_pool) |candidate| try publicOutputValue(candidate) else value.Value{ .string = "" };
        const fields = [_]value.Field{
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "disabled", .value = .{ .boolean = args.disabled } },
            .{ .name = "event", .value = event },
            .{ .name = "filename", .value = .{ .string = args.filename } },
            .{ .name = "ignored_files", .value = ignored },
            .{ .name = "included_files", .value = included },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "repository", .value = try publicOutputValue(args.repository) },
            .{ .name = "require_approval", .value = .{ .boolean = args.require_approval } },
            .{ .name = "service_account", .value = .{ .string = args.service_account orelse "" } },
            .{ .name = "substitutions", .value = substitutions },
            .{ .name = "worker_pool", .value = worker_pool },
        };
        const node = try nodeOwned(allocator, "gcp.cloudbuild.Trigger", args.location, args.name, &fields, .{ .protect = args.protect });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
    }

    pub fn deinit(self: *Trigger, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const Redirection = enum {
    disabled,
    enabled,
    enabled_and_copying,
    partial_and_copying,

    pub fn apiName(self: Redirection) []const u8 {
        return switch (self) {
            .disabled => "REDIRECTION_FROM_GCR_IO_DISABLED",
            .enabled => "REDIRECTION_FROM_GCR_IO_ENABLED",
            .enabled_and_copying => "REDIRECTION_FROM_GCR_IO_ENABLED_AND_COPYING",
            .partial_and_copying => "REDIRECTION_FROM_GCR_IO_PARTIAL_AND_COPYING",
        };
    }
};

pub const ArtifactProjectSettingsArgs = struct {
    redirection: Redirection,
    pull_percent: u8 = 0,
};

pub const ArtifactProjectSettings = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ArtifactProjectSettingsArgs) BuildError!ArtifactProjectSettings {
        try provider.validate();
        if ((args.redirection == .partial_and_copying and (args.pull_percent == 0 or args.pull_percent >= 100)) or
            (args.redirection != .partial_and_copying and args.pull_percent != 0)) return error.InvalidRedirection;
        const fields = [_]value.Field{
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "pull_percent", .value = .{ .integer = args.pull_percent } },
            .{ .name = "redirection", .value = .{ .string = args.redirection.apiName() } },
        };
        const node = try singletonNodeOwned(allocator, "gcp.artifact.ProjectSettings", provider.project_id, &fields);
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
    }

    pub fn deinit(self: *ArtifactProjectSettings, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const VpcscPolicy = enum {
    deny,
    allow,

    pub fn apiName(self: VpcscPolicy) []const u8 {
        return if (self == .allow) "ALLOW" else "DENY";
    }
};
pub const ArtifactVpcscConfigArgs = struct { location: []const u8, policy: VpcscPolicy };

pub const ArtifactVpcscConfig = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ArtifactVpcscConfigArgs) BuildError!ArtifactVpcscConfig {
        try provider.validate();
        if (!configuredLocation(provider, args.location, false)) return error.InvalidRegion;
        const fields = [_]value.Field{
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "policy", .value = .{ .string = args.policy.apiName() } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        };
        const node = try singletonNodeOwned(allocator, "gcp.artifact.VpcscConfig", args.location, &fields);
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
    }

    pub fn deinit(self: *ArtifactVpcscConfig, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn connectionConfigValue(allocator: std.mem.Allocator, config: ConnectionConfig) BuildError!value.Value {
    return switch (config) {
        .github => |item| blk: {
            if (item.oauth_token_secret_version) |secret| try validateSecretVersion(secret);
            const fields = [_]value.Field{
                .{ .name = "app_installation_id", .value = .{ .string = item.app_installation_id orelse "" } },
                .{ .name = "kind", .value = .{ .string = "github" } },
                .{ .name = "oauth_token_secret_version", .value = .{ .string = item.oauth_token_secret_version orelse "" } },
            };
            break :blk try value.Value.initOwned(allocator, .{ .object = &fields });
        },
        .github_enterprise => |item| blk: {
            try validateHttpsUri(item.host_uri);
            try validateSecretVersion(item.private_key_secret_version);
            try validateSecretVersion(item.webhook_secret_version);
            const fields = [_]value.Field{
                .{ .name = "api_key", .value = try secretOutputValue(item.api_key) },
                .{ .name = "app_id", .value = .{ .string = item.app_id orelse "" } },
                .{ .name = "app_installation_id", .value = .{ .string = item.app_installation_id orelse "" } },
                .{ .name = "app_slug", .value = .{ .string = item.app_slug orelse "" } },
                .{ .name = "host_uri", .value = .{ .string = item.host_uri } },
                .{ .name = "kind", .value = .{ .string = "github_enterprise" } },
                .{ .name = "private_key_secret_version", .value = .{ .string = item.private_key_secret_version } },
                .{ .name = "service_directory_service", .value = .{ .string = item.service_directory_service orelse "" } },
                .{ .name = "ssl_ca", .value = .{ .string = item.ssl_ca orelse "" } },
                .{ .name = "webhook_secret_version", .value = .{ .string = item.webhook_secret_version } },
            };
            break :blk try value.Value.initOwned(allocator, .{ .object = &fields });
        },
        .gitlab => |item| try tokenConnectionValue(allocator, "gitlab", item.host_uri, item.authorizer_secret_version, item.read_authorizer_secret_version, item.webhook_secret_version, item.service_directory_service, item.ssl_ca, null),
        .bitbucket_data_center => |item| try tokenConnectionValue(allocator, "bitbucket_data_center", item.host_uri, item.authorizer_secret_version, item.read_authorizer_secret_version, item.webhook_secret_version, item.service_directory_service, item.ssl_ca, null),
        .bitbucket_cloud => |item| try tokenConnectionValue(allocator, "bitbucket_cloud", "", item.authorizer_secret_version, item.read_authorizer_secret_version, item.webhook_secret_version, null, null, item.workspace),
    };
}

fn tokenConnectionValue(allocator: std.mem.Allocator, kind: []const u8, host: []const u8, authorizer: []const u8, reader: []const u8, webhook: []const u8, service: ?[]const u8, ssl_ca: ?[]const u8, workspace: ?[]const u8) BuildError!value.Value {
    if (host.len != 0) try validateHttpsUri(host);
    try validateSecretVersion(authorizer);
    try validateSecretVersion(reader);
    try validateSecretVersion(webhook);
    const fields = [_]value.Field{
        .{ .name = "authorizer_secret_version", .value = .{ .string = authorizer } },
        .{ .name = "host_uri", .value = .{ .string = host } },
        .{ .name = "kind", .value = .{ .string = kind } },
        .{ .name = "read_authorizer_secret_version", .value = .{ .string = reader } },
        .{ .name = "service_directory_service", .value = .{ .string = service orelse "" } },
        .{ .name = "ssl_ca", .value = .{ .string = ssl_ca orelse "" } },
        .{ .name = "webhook_secret_version", .value = .{ .string = webhook } },
        .{ .name = "workspace", .value = .{ .string = workspace orelse "" } },
    };
    return value.Value.initOwned(allocator, .{ .object = &fields });
}

fn networkValue(allocator: std.mem.Allocator, location: []const u8, network: ?WorkerNetwork) BuildError!value.Value {
    if (network == null) return value.Value.initOwned(allocator, .{ .object = &.{} });
    return switch (network.?) {
        .peered => |item| blk: {
            if (!std.mem.startsWith(u8, item.network, "projects/") or std.mem.indexOf(u8, item.network, "/global/networks/") == null or item.ip_range.len == 0) return error.InvalidNetwork;
            const fields = [_]value.Field{
                .{ .name = "egress", .value = .{ .string = item.egress.apiName() } },
                .{ .name = "ip_range", .value = .{ .string = item.ip_range } },
                .{ .name = "kind", .value = .{ .string = "peered" } },
                .{ .name = "network", .value = .{ .string = item.network } },
            };
            break :blk try value.Value.initOwned(allocator, .{ .object = &fields });
        },
        .psc => |item| blk: {
            const marker = try std.fmt.allocPrint(allocator, "/regions/{s}/networkAttachments/", .{location});
            defer allocator.free(marker);
            if (!std.mem.startsWith(u8, item.network_attachment, "projects/") or std.mem.indexOf(u8, item.network_attachment, marker) == null) return error.InvalidNetwork;
            const fields = [_]value.Field{
                .{ .name = "kind", .value = .{ .string = "psc" } },
                .{ .name = "network_attachment", .value = .{ .string = item.network_attachment } },
                .{ .name = "public_ip_disabled", .value = .{ .boolean = item.public_ip_disabled } },
                .{ .name = "route_all_traffic", .value = .{ .boolean = item.route_all_traffic } },
            };
            break :blk try value.Value.initOwned(allocator, .{ .object = &fields });
        },
    };
}

fn eventValue(allocator: std.mem.Allocator, event: TriggerEvent) BuildError!value.Value {
    return switch (event) {
        .push => |filter| blk: {
            const kind = @tagName(filter);
            const pattern = switch (filter) {
                .branch => |text| text,
                .tag => |text| text,
            };
            try validatePattern(pattern);
            const fields = [_]value.Field{
                .{ .name = "kind", .value = .{ .string = "push" } },
                .{ .name = "ref_kind", .value = .{ .string = kind } },
                .{ .name = "pattern", .value = .{ .string = pattern } },
            };
            break :blk try value.Value.initOwned(allocator, .{ .object = &fields });
        },
        .pull_request => |filter| blk: {
            try validatePattern(filter.branch);
            const fields = [_]value.Field{
                .{ .name = "kind", .value = .{ .string = "pull_request" } },
                .{ .name = "pattern", .value = .{ .string = filter.branch } },
                .{ .name = "require_comment", .value = .{ .boolean = filter.require_comment } },
            };
            break :blk try value.Value.initOwned(allocator, .{ .object = &fields });
        },
    };
}

fn substitutionsValue(allocator: std.mem.Allocator, items: []const Substitution) BuildError!value.Value {
    const fields = try allocator.alloc(value.Field, items.len);
    defer allocator.free(fields);
    for (items, 0..) |item, index| {
        if (item.key.len < 2 or item.key[0] != '_' or item.value.len > 4000) return error.InvalidValue;
        for (item.key[1..]) |character| if (!std.ascii.isUpper(character) and !std.ascii.isDigit(character) and character != '_') return error.InvalidValue;
        fields[index] = .{ .name = item.key, .value = .{ .string = item.value } };
    }
    return value.Value.initOwned(allocator, .{ .object = fields });
}

fn mapValue(allocator: std.mem.Allocator, items: []const Annotation) BuildError!value.Value {
    const fields = try allocator.alloc(value.Field, items.len);
    defer allocator.free(fields);
    for (items, 0..) |item, index| {
        if (item.key.len == 0 or item.key.len > 63 or item.value.len > 1024) return error.InvalidValue;
        fields[index] = .{ .name = item.key, .value = .{ .string = item.value } };
    }
    return value.Value.initOwned(allocator, .{ .object = fields }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateKey,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn stringListValue(allocator: std.mem.Allocator, items: []const []const u8) BuildError!value.Value {
    const values = try allocator.alloc(value.Value, items.len);
    defer allocator.free(values);
    for (items, 0..) |item, index| {
        if (item.len == 0 or std.mem.indexOfAny(u8, item, "\x00\r\n") != null) return error.InvalidValue;
        values[index] = .{ .string = item };
    }
    return value.Value.initOwned(allocator, .{ .list = values });
}

fn nodeOwned(allocator: std.mem.Allocator, type_name: []const u8, scope: []const u8, name: []const u8, fields: []const value.Field, lifecycle: resource.Lifecycle) BuildError!resource.ResourceNode {
    const id = try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ type_name, scope, name });
    defer allocator.free(id);
    return resource.ResourceNode.initOwned(allocator, .{ .id = id, .provider = .gcp, .type_name = type_name, .logical_id = name, .inputs = .{ .object = fields }, .lifecycle = lifecycle }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
    };
}

fn singletonNodeOwned(allocator: std.mem.Allocator, type_name: []const u8, logical_id: []const u8, fields: []const value.Field) BuildError!resource.ResourceNode {
    const id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_name, logical_id });
    defer allocator.free(id);
    return resource.ResourceNode.initOwned(allocator, .{ .id = id, .provider = .gcp, .type_name = type_name, .logical_id = logical_id, .inputs = .{ .object = fields }, .lifecycle = .{ .retain_on_delete = true } }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
    };
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

fn validateName(name: []const u8) BuildError!void {
    if (name.len == 0 or name.len > 63 or !std.ascii.isLower(name[0])) return error.InvalidName;
    if (!std.ascii.isLower(name[name.len - 1]) and !std.ascii.isDigit(name[name.len - 1])) return error.InvalidName;
    for (name) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return error.InvalidName;
}

fn configuredLocation(provider: config_mod.ProviderConfig, location: []const u8, allow_global: bool) bool {
    if (allow_global and std.mem.eql(u8, location, "global")) return true;
    if (std.mem.eql(u8, provider.primary_region, location)) return true;
    for (provider.service_regions) |candidate| if (std.mem.eql(u8, candidate, location)) return true;
    return false;
}

fn validateHttpsUri(uri: []const u8) BuildError!void {
    if (!std.mem.startsWith(u8, uri, "https://") or uri.len <= "https://".len or std.mem.indexOfAny(u8, uri, "\x00\r\n ") != null) return error.InvalidRemoteUri;
}

fn validateSecretVersion(name: []const u8) BuildError!void {
    if (!std.mem.startsWith(u8, name, "projects/") or std.mem.indexOf(u8, name, "/secrets/") == null or std.mem.indexOf(u8, name, "/versions/") == null or std.mem.indexOfAny(u8, name, "?# \t\r\n") != null) return error.InvalidSecretReference;
}

fn validatePattern(pattern: []const u8) BuildError!void {
    if (pattern.len == 0 or pattern.len > 1000 or std.mem.indexOfAny(u8, pattern, "\x00\r\n") != null) return error.InvalidPattern;
}

fn validatePath(path: []const u8) BuildError!void {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOf(u8, path, "..") != null or std.mem.indexOfAny(u8, path, "\x00\r\n") != null) return error.InvalidPath;
}

fn validateServiceAccount(name: []const u8, project_id: []const u8) BuildError!void {
    const prefix = try std.fmt.allocPrint(std.heap.page_allocator, "projects/{s}/serviceAccounts/", .{project_id});
    defer std.heap.page_allocator.free(prefix);
    if (!std.mem.startsWith(u8, name, prefix) or !std.mem.endsWith(u8, name, ".iam.gserviceaccount.com")) return error.InvalidServiceAccount;
}
