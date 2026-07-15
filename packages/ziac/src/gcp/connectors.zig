const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    DuplicateKey,
    InvalidConnectorVersion,
    InvalidDestination,
    InvalidDns,
    InvalidIamMember,
    InvalidName,
    InvalidNetwork,
    InvalidNodeConfig,
    InvalidOutput,
    InvalidRegion,
    InvalidRole,
    InvalidSecretReference,
    InvalidServiceAccount,
    InvalidSubscription,
    InvalidValue,
};

pub const RemovalPolicy = enum { retain, delete };
pub const LogLevel = enum { off, error_level, info, debug };
pub const EgressMode = enum { public_ip, private_ip };
pub const KeyValue = struct { key: []const u8, value: []const u8 };

pub const ConfigValue = union(enum) {
    string: []const u8,
    integer: i64,
    boolean: bool,
    secret_version: output.Output([]const u8, .public),
};
pub const ConfigVariable = struct { key: []const u8, value: ConfigValue };
pub const UserPassword = struct { username: []const u8, password_secret_version: output.Output([]const u8, .public) };
pub const OAuthClientCredentials = struct { client_id: []const u8, client_secret_version: output.Output([]const u8, .public) };
pub const SshAuthentication = struct { username: []const u8, private_key_secret_version: output.Output([]const u8, .public) };
pub const Authentication = union(enum) { none, user_password: UserPassword, oauth_client_credentials: OAuthClientCredentials, ssh: SshAuthentication };
pub const NodeConfig = struct { min_nodes: u16 = 1, max_nodes: u16 = 2 };
pub const DestinationConfig = struct { key: []const u8, destinations: []const []const u8 };
pub const ConnectionArgs = struct {
    name: []const u8,
    location: []const u8,
    connector_version: []const u8,
    description: []const u8 = "",
    service_account_email: ?[]const u8 = null,
    authentication: Authentication = .none,
    config_variables: []const ConfigVariable = &.{},
    destinations: []const DestinationConfig = &.{},
    node_config: NodeConfig = .{},
    suspended: bool = false,
    log_level: LogLevel = .info,
    labels: []const KeyValue = &.{},
    protect: bool = true,
    removal_policy: RemovalPolicy = .retain,
};

pub const Connection = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Status = output.Descriptor("status", []const u8, .public);
        pub const ServiceDirectory = output.Descriptor("service_directory", []const u8, .public);
        pub const EgressHost = output.Descriptor("host", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    status: Outputs.Status.OutputType,
    service_directory: Outputs.ServiceDirectory.OutputType,
    host: Outputs.EgressHost.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ConnectionArgs) BuildError!Connection {
        try provider.validate();
        try validateCommon(provider, args.name, args.location);
        try validateConnectorVersion(args.connector_version);
        if (args.description.len > 1024 or std.mem.indexOfAny(u8, args.description, "\r\n") != null) return error.InvalidValue;
        if (args.service_account_email) |email| try validateServiceAccount(email);
        try validateNodes(args.node_config);
        var authentication = try authenticationValue(allocator, args.authentication);
        defer authentication.deinit(allocator);
        var config_variables = try configVariablesValue(allocator, args.config_variables);
        defer config_variables.deinit(allocator);
        var destinations = try destinationsValue(allocator, args.destinations);
        defer destinations.deinit(allocator);
        var labels = try mapValue(allocator, args.labels);
        defer labels.deinit(allocator);
        var nodes = try nodeConfigValue(allocator, args.node_config);
        defer nodes.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "authentication", .value = authentication },
            .{ .name = "config_variables", .value = config_variables },
            .{ .name = "connector_version", .value = .{ .string = args.connector_version } },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "destinations", .value = destinations },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "log_level", .value = .{ .string = logLevelName(args.log_level) } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "node_config", .value = nodes },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
            .{ .name = "service_account_email", .value = .{ .string = args.service_account_email orelse "" } },
            .{ .name = "suspended", .value = .{ .boolean = args.suspended } },
        };
        const node = try nodeOwned(allocator, "gcp.connectors.Connection", args.location, args.name, null, &fields, lifecycle(args.protect, args.removal_policy));
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .status = Outputs.Status.fromResource(node.id),
            .service_directory = Outputs.ServiceDirectory.fromResource(node.id),
            .host = Outputs.EgressHost.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Connection, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const EndpointAttachmentArgs = struct {
    name: []const u8,
    location: []const u8,
    service_attachment: output.Output([]const u8, .public),
    description: []const u8 = "",
    endpoint_global_access: bool = false,
    labels: []const KeyValue = &.{},
    protect: bool = true,
    removal_policy: RemovalPolicy = .retain,
};

pub const EndpointAttachment = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const EndpointIp = output.Descriptor("endpoint_ip", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    endpoint_ip: Outputs.EndpointIp.OutputType,
    state: Outputs.State.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: EndpointAttachmentArgs) BuildError!EndpointAttachment {
        try provider.validate();
        try validateCommon(provider, args.name, args.location);
        try validateOutputContains(args.service_attachment, "/serviceAttachments/");
        try validateOutputRegion(args.service_attachment, args.location, "/regions/");
        if (args.description.len > 1024) return error.InvalidValue;
        var labels = try mapValue(allocator, args.labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "endpoint_global_access", .value = .{ .boolean = args.endpoint_global_access } },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
            .{ .name = "service_attachment", .value = try outputValue(args.service_attachment) },
        };
        const node = try nodeOwned(allocator, "gcp.connectors.EndpointAttachment", args.location, args.name, null, &fields, lifecycle(args.protect, args.removal_policy));
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .endpoint_ip = Outputs.EndpointIp.fromResource(node.id), .state = Outputs.State.fromResource(node.id) };
    }

    pub fn deinit(self: *EndpointAttachment, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const HttpsEventDestination = struct { uri: []const u8, service_account_email: ?[]const u8 = null };
pub const PubSubEventDestination = struct { project_id: []const u8, topic_id: []const u8 };
pub const EventDestination = union(enum) { https: HttpsEventDestination, pubsub: PubSubEventDestination };
pub const EventSubscriptionArgs = struct {
    name: []const u8,
    location: []const u8,
    connection: output.Output([]const u8, .public),
    event_type_id: []const u8,
    destination: EventDestination,
    filter: []const u8 = "",
    trigger_config_variables: []const ConfigVariable = &.{},
    protect: bool = true,
    removal_policy: RemovalPolicy = .retain,
};

pub const EventSubscription = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Status = output.Descriptor("status", []const u8, .public);
        pub const SubscriberLink = output.Descriptor("subscriber_link", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    status: Outputs.Status.OutputType,
    subscriber_link: Outputs.SubscriberLink.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: EventSubscriptionArgs) BuildError!EventSubscription {
        try provider.validate();
        try validateCommon(provider, args.name, args.location);
        try validateOutputContains(args.connection, "/connections/");
        const identity = try connectionIdentityAlloc(allocator, args.connection);
        defer allocator.free(identity.location);
        defer allocator.free(identity.connection);
        if (!std.mem.eql(u8, identity.location, args.location)) return error.InvalidRegion;
        if (args.event_type_id.len == 0 or args.event_type_id.len > 256) return error.InvalidSubscription;
        if (args.filter.len > 2048 or std.mem.indexOfAny(u8, args.filter, "\r\n") != null) return error.InvalidSubscription;
        var destination = try eventDestinationValue(allocator, args.destination);
        defer destination.deinit(allocator);
        var trigger_config = try configVariablesValue(allocator, args.trigger_config_variables);
        defer trigger_config.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "connection", .value = try outputValue(args.connection) },
            .{ .name = "connection_name", .value = .{ .string = identity.connection } },
            .{ .name = "destination", .value = destination },
            .{ .name = "event_type_id", .value = .{ .string = args.event_type_id } },
            .{ .name = "filter", .value = .{ .string = args.filter } },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
            .{ .name = "trigger_config_variables", .value = trigger_config },
        };
        const node = try nodeOwned(allocator, "gcp.connectors.EventSubscription", args.location, args.name, identity.connection, &fields, lifecycle(args.protect, args.removal_policy));
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .status = Outputs.Status.fromResource(node.id), .subscriber_link = Outputs.SubscriberLink.fromResource(node.id) };
    }

    pub fn deinit(self: *EventSubscription, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const ManagedZoneArgs = struct {
    name: []const u8,
    target_project: []const u8,
    target_vpc: []const u8,
    dns: []const u8,
    description: []const u8 = "",
    labels: []const KeyValue = &.{},
    protect: bool = true,
    removal_policy: RemovalPolicy = .retain,
};

pub const ManagedZone = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ManagedZoneArgs) BuildError!ManagedZone {
        try provider.validate();
        try validateName(args.name);
        if (args.target_project.len == 0 or args.target_vpc.len == 0 or std.mem.indexOfAny(u8, args.target_project, "/\r\n") != null or std.mem.indexOfAny(u8, args.target_vpc, "/\r\n") != null) return error.InvalidNetwork;
        if (args.dns.len < 2 or args.dns.len > 253 or args.dns[args.dns.len - 1] != '.' or std.mem.indexOfAny(u8, args.dns, " /\r\n") != null) return error.InvalidDns;
        if (args.description.len > 1024) return error.InvalidValue;
        var labels = try mapValue(allocator, args.labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "dns", .value = .{ .string = args.dns } },
            .{ .name = "labels", .value = labels },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
            .{ .name = "target_project", .value = .{ .string = args.target_project } },
            .{ .name = "target_vpc", .value = .{ .string = args.target_vpc } },
        };
        const node = try nodeOwned(allocator, "gcp.connectors.ManagedZone", "global", args.name, null, &fields, lifecycle(args.protect, args.removal_policy));
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
    }

    pub fn deinit(self: *ManagedZone, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const RegionalSettingsArgs = struct {
    location: []const u8,
    egress_mode: EgressMode = .public_ip,
    kms_key_name: ?output.Output([]const u8, .public) = null,
    client: []const u8 = "ZIAC",
};

pub const RegionalSettings = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Provisioned = output.Descriptor("provisioned", bool, .public);
        pub const EgressIps = output.Descriptor("egress_ips", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    provisioned: Outputs.Provisioned.OutputType,
    egress_ips: Outputs.EgressIps.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: RegionalSettingsArgs) BuildError!RegionalSettings {
        try provider.validate();
        try validateRegion(provider, args.location);
        if (args.client.len == 0 or args.client.len > 64) return error.InvalidValue;
        const fields = [_]value.Field{
            .{ .name = "client", .value = .{ .string = args.client } },
            .{ .name = "egress_mode", .value = .{ .string = if (args.egress_mode == .private_ip) "PRIVATE_IP" else "PUBLIC_IP" } },
            .{ .name = "kms_key_name", .value = try optionalOutputValue(args.kms_key_name) },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        };
        const node = try singletonNodeOwned(allocator, "gcp.connectors.RegionalSettings", args.location, "regional-settings", &fields);
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .provisioned = Outputs.Provisioned.fromResource(node.id), .egress_ips = Outputs.EgressIps.fromResource(node.id) };
    }

    pub fn deinit(self: *RegionalSettings, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const IamCondition = struct { title: []const u8, expression: []const u8, description: []const u8 = "" };
pub const ConnectionIamMemberArgs = struct {
    location: []const u8,
    connection: output.Output([]const u8, .public),
    role: []const u8,
    member: []const u8,
    condition: ?IamCondition = null,
    protect: bool = true,
};
pub const ConnectionIamMember = struct {
    node: resource.ResourceNode,
    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ConnectionIamMemberArgs) BuildError!ConnectionIamMember {
        try provider.validate();
        try validateRegion(provider, args.location);
        try validateOutputContains(args.connection, "/connections/");
        try validateOutputLocation(args.connection, args.location);
        if (!std.mem.startsWith(u8, args.role, "roles/") or std.mem.indexOfScalar(u8, args.role, ' ') != null) return error.InvalidRole;
        if (!validMember(args.member)) return error.InvalidIamMember;
        var condition = if (args.condition) |selected| try conditionValue(allocator, selected) else try ownedValue(allocator, .{ .object = &.{} });
        defer condition.deinit(allocator);
        const target_name = targetBasename(args.connection);
        const identity = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ args.role, args.member });
        defer allocator.free(identity);
        const logical = try slugAlloc(allocator, identity);
        defer allocator.free(logical);
        const fields = [_]value.Field{
            .{ .name = "condition", .value = condition },
            .{ .name = "has_condition", .value = .{ .boolean = args.condition != null } },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "member", .value = .{ .string = args.member } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "resource", .value = try outputValue(args.connection) },
            .{ .name = "role", .value = .{ .string = args.role } },
        };
        return .{ .node = try nodeOwned(allocator, "gcp.connectors.ConnectionIamMember", args.location, logical, target_name, &fields, .{ .protect = args.protect }) };
    }
    pub fn deinit(self: *ConnectionIamMember, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn authenticationValue(allocator: std.mem.Allocator, authentication: Authentication) BuildError!value.Value {
    return switch (authentication) {
        .none => ownedValue(allocator, .{ .object = &.{.{ .name = "kind", .value = .{ .string = "none" } }} }),
        .user_password => |selected| blk: {
            if (selected.username.len == 0 or selected.username.len > 256) return error.InvalidValue;
            try validateSecretOutput(selected.password_secret_version);
            const fields = [_]value.Field{
                .{ .name = "kind", .value = .{ .string = "user_password" } },
                .{ .name = "password_secret_version", .value = try secretOutputValue(selected.password_secret_version) },
                .{ .name = "username", .value = .{ .string = selected.username } },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
        .oauth_client_credentials => |selected| blk: {
            if (selected.client_id.len == 0 or selected.client_id.len > 512) return error.InvalidValue;
            try validateSecretOutput(selected.client_secret_version);
            const fields = [_]value.Field{
                .{ .name = "client_id", .value = .{ .string = selected.client_id } },
                .{ .name = "client_secret_version", .value = try secretOutputValue(selected.client_secret_version) },
                .{ .name = "kind", .value = .{ .string = "oauth_client_credentials" } },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
        .ssh => |selected| blk: {
            if (selected.username.len == 0 or selected.username.len > 256) return error.InvalidValue;
            try validateSecretOutput(selected.private_key_secret_version);
            const fields = [_]value.Field{
                .{ .name = "kind", .value = .{ .string = "ssh" } },
                .{ .name = "private_key_secret_version", .value = try secretOutputValue(selected.private_key_secret_version) },
                .{ .name = "username", .value = .{ .string = selected.username } },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
    };
}

fn configVariablesValue(allocator: std.mem.Allocator, variables: []const ConfigVariable) BuildError!value.Value {
    const values = try allocator.alloc(value.Value, variables.len);
    defer allocator.free(values);
    var initialized: usize = 0;
    defer for (values[0..initialized]) |*item| item.deinit(allocator);
    for (variables, 0..) |variable, index| {
        if (variable.key.len == 0 or variable.key.len > 128) return error.InvalidValue;
        for (variables[0..index]) |prior| if (std.mem.eql(u8, prior.key, variable.key)) return error.DuplicateKey;
        var selected = try configValue(allocator, variable.key, variable.value);
        defer selected.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "key", .value = .{ .string = variable.key } },
            .{ .name = "value", .value = selected },
        };
        values[index] = try ownedValue(allocator, .{ .object = &fields });
        initialized += 1;
    }
    return ownedValue(allocator, .{ .list = values });
}

fn configValue(allocator: std.mem.Allocator, key: []const u8, selected: ConfigValue) BuildError!value.Value {
    const kind: []const u8, const inner: value.Value = switch (selected) {
        .string => |text| blk: {
            if (text.len > 4096 or (isSensitiveKey(key) and text.len != 0)) return error.InvalidSecretReference;
            break :blk .{ "string", .{ .string = text } };
        },
        .integer => |number| .{ "integer", .{ .integer = number } },
        .boolean => |flag| .{ "boolean", .{ .boolean = flag } },
        .secret_version => |secret| blk: {
            try validateSecretOutput(secret);
            break :blk .{ "secret_version", try secretOutputValue(secret) };
        },
    };
    const fields = [_]value.Field{
        .{ .name = "kind", .value = .{ .string = kind } },
        .{ .name = "value", .value = inner },
    };
    return ownedValue(allocator, .{ .object = &fields });
}

fn destinationsValue(allocator: std.mem.Allocator, destinations: []const DestinationConfig) BuildError!value.Value {
    const values = try allocator.alloc(value.Value, destinations.len);
    defer allocator.free(values);
    var initialized: usize = 0;
    defer for (values[0..initialized]) |*item| item.deinit(allocator);
    for (destinations, 0..) |destination, index| {
        if (destination.key.len == 0 or destination.destinations.len == 0) return error.InvalidDestination;
        for (destinations[0..index]) |prior| if (std.mem.eql(u8, prior.key, destination.key)) return error.DuplicateKey;
        var urls = try stringsValue(allocator, destination.destinations);
        defer urls.deinit(allocator);
        for (destination.destinations) |url| if (!(std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "tcp://"))) return error.InvalidDestination;
        const fields = [_]value.Field{
            .{ .name = "destinations", .value = urls },
            .{ .name = "key", .value = .{ .string = destination.key } },
        };
        values[index] = try ownedValue(allocator, .{ .object = &fields });
        initialized += 1;
    }
    return ownedValue(allocator, .{ .list = values });
}

fn nodeConfigValue(allocator: std.mem.Allocator, nodes: NodeConfig) BuildError!value.Value {
    try validateNodes(nodes);
    const fields = [_]value.Field{
        .{ .name = "max_nodes", .value = .{ .integer = nodes.max_nodes } },
        .{ .name = "min_nodes", .value = .{ .integer = nodes.min_nodes } },
    };
    return ownedValue(allocator, .{ .object = &fields });
}

fn eventDestinationValue(allocator: std.mem.Allocator, destination: EventDestination) BuildError!value.Value {
    return switch (destination) {
        .https => |selected| blk: {
            if (!std.mem.startsWith(u8, selected.uri, "https://") or selected.uri.len > 2048) return error.InvalidDestination;
            if (selected.service_account_email) |email| try validateServiceAccount(email);
            const fields = [_]value.Field{
                .{ .name = "kind", .value = .{ .string = "https" } },
                .{ .name = "service_account_email", .value = .{ .string = selected.service_account_email orelse "" } },
                .{ .name = "uri", .value = .{ .string = selected.uri } },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
        .pubsub => |selected| blk: {
            if (selected.project_id.len == 0 or selected.topic_id.len == 0 or std.mem.indexOfAny(u8, selected.project_id, "/\r\n") != null or std.mem.indexOfAny(u8, selected.topic_id, "/\r\n") != null) return error.InvalidDestination;
            const fields = [_]value.Field{
                .{ .name = "kind", .value = .{ .string = "pubsub" } },
                .{ .name = "project_id", .value = .{ .string = selected.project_id } },
                .{ .name = "topic_id", .value = .{ .string = selected.topic_id } },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
    };
}

fn mapValue(allocator: std.mem.Allocator, items: []const KeyValue) BuildError!value.Value {
    const fields = try allocator.alloc(value.Field, items.len);
    defer allocator.free(fields);
    for (items, 0..) |item, index| {
        if (item.key.len == 0 or item.key.len > 63 or item.value.len > 63) return error.InvalidValue;
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
fn conditionValue(allocator: std.mem.Allocator, condition: IamCondition) BuildError!value.Value {
    if (condition.title.len == 0 or condition.expression.len == 0) return error.InvalidIamMember;
    const fields = [_]value.Field{
        .{ .name = "description", .value = .{ .string = condition.description } },
        .{ .name = "expression", .value = .{ .string = condition.expression } },
        .{ .name = "title", .value = .{ .string = condition.title } },
    };
    return ownedValue(allocator, .{ .object = &fields });
}

const ConnectionIdentity = struct { location: []u8, connection: []u8 };
fn connectionIdentityAlloc(allocator: std.mem.Allocator, selected: output.Output([]const u8, .public)) BuildError!ConnectionIdentity {
    const source = switch (selected) {
        .value => |text| text,
        .resource_ref => |reference| reference.resource_id,
        .unknown_reason => return error.InvalidOutput,
    };
    if (std.mem.startsWith(u8, source, "projects/")) {
        const location_marker = "/locations/";
        const connection_marker = "/connections/";
        const location_start = (std.mem.indexOf(u8, source, location_marker) orelse return error.InvalidOutput) + location_marker.len;
        const connection_start = (std.mem.indexOfPos(u8, source, location_start, connection_marker) orelse return error.InvalidOutput) + connection_marker.len;
        return .{ .location = try allocator.dupe(u8, source[location_start .. connection_start - connection_marker.len]), .connection = try allocator.dupe(u8, source[connection_start..]) };
    }
    const prefix = "gcp.connectors.Connection.";
    if (!std.mem.startsWith(u8, source, prefix)) return error.InvalidOutput;
    const rest = source[prefix.len..];
    const separator = std.mem.indexOfScalar(u8, rest, '.') orelse return error.InvalidOutput;
    return .{ .location = try allocator.dupe(u8, rest[0..separator]), .connection = try allocator.dupe(u8, rest[separator + 1 ..]) };
}

fn outputValue(selected: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (selected) {
        .value => |text| .{ .string = text },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.InvalidOutput,
    };
}
fn optionalOutputValue(selected: ?output.Output([]const u8, .public)) BuildError!value.Value {
    return if (selected) |known| outputValue(known) else .{ .string = "" };
}
fn secretOutputValue(selected: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (selected) {
        .value => |text| .{ .secret_ref = .{ .provider = "gcp-secret-manager", .resource = text } },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.InvalidSecretReference,
    };
}
fn validateSecretOutput(selected: output.Output([]const u8, .public)) BuildError!void {
    switch (selected) {
        .value => |text| try validateSecretVersion(text),
        .resource_ref => {},
        .unknown_reason => return error.InvalidSecretReference,
    }
}
fn validateSecretVersion(secret: []const u8) BuildError!void {
    const marker = "/secrets/";
    const version = "/versions/";
    const marker_pos = std.mem.indexOf(u8, secret, marker) orelse return error.InvalidSecretReference;
    const version_pos = std.mem.indexOfPos(u8, secret, marker_pos + marker.len, version) orelse return error.InvalidSecretReference;
    if (!std.mem.startsWith(u8, secret, "projects/") or version_pos + version.len >= secret.len or std.mem.eql(u8, secret[version_pos + version.len ..], "latest")) return error.InvalidSecretReference;
}
fn validateOutputContains(selected: output.Output([]const u8, .public), segment: []const u8) BuildError!void {
    switch (selected) {
        .value => |text| if (std.mem.indexOf(u8, text, segment) == null) return error.InvalidOutput,
        .resource_ref => {},
        .unknown_reason => return error.InvalidOutput,
    }
}
fn validateOutputRegion(selected: output.Output([]const u8, .public), location: []const u8, marker: []const u8) BuildError!void {
    switch (selected) {
        .value => |text| {
            const start = (std.mem.indexOf(u8, text, marker) orelse return error.InvalidRegion) + marker.len;
            const end = std.mem.indexOfScalarPos(u8, text, start, '/') orelse return error.InvalidRegion;
            if (!std.mem.eql(u8, text[start..end], location)) return error.InvalidRegion;
        },
        .resource_ref => {},
        .unknown_reason => return error.InvalidOutput,
    }
}
fn validateOutputLocation(selected: output.Output([]const u8, .public), location: []const u8) BuildError!void {
    switch (selected) {
        .value => |text| {
            const marker = "/locations/";
            const start = (std.mem.indexOf(u8, text, marker) orelse return error.InvalidRegion) + marker.len;
            const end = std.mem.indexOfScalarPos(u8, text, start, '/') orelse return error.InvalidRegion;
            if (!std.mem.eql(u8, text[start..end], location)) return error.InvalidRegion;
        },
        .resource_ref => {},
        .unknown_reason => return error.InvalidOutput,
    }
}
fn validateConnectorVersion(version: []const u8) BuildError!void {
    if (!std.mem.startsWith(u8, version, "projects/") or std.mem.indexOf(u8, version, "/locations/global/providers/") == null or std.mem.indexOf(u8, version, "/connectors/") == null or std.mem.indexOf(u8, version, "/versions/") == null or std.mem.endsWith(u8, version, "/versions/latest")) return error.InvalidConnectorVersion;
}
fn validateNodes(nodes: NodeConfig) BuildError!void {
    if (nodes.min_nodes == 0 or nodes.max_nodes == 0 or nodes.min_nodes > nodes.max_nodes or nodes.max_nodes > 100) return error.InvalidNodeConfig;
}
fn validateCommon(provider: config_mod.ProviderConfig, name: []const u8, location: []const u8) BuildError!void {
    try validateName(name);
    try validateRegion(provider, location);
}
fn validateRegion(provider: config_mod.ProviderConfig, location: []const u8) BuildError!void {
    if (location.len == 0) return error.InvalidRegion;
    if (provider.service_regions.len == 0) {
        if (!std.mem.eql(u8, provider.primary_region, location)) return error.InvalidRegion;
        return;
    }
    for (provider.service_regions) |allowed| if (std.mem.eql(u8, allowed, location)) return;
    return error.InvalidRegion;
}
fn validateName(name: []const u8) BuildError!void {
    if (name.len == 0 or name.len > 63 or !std.ascii.isLower(name[0]) or !std.ascii.isAlphanumeric(name[name.len - 1])) return error.InvalidName;
    for (name) |char| if (!(std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '-')) return error.InvalidName;
}
fn validateServiceAccount(email: []const u8) BuildError!void {
    if (!std.mem.endsWith(u8, email, ".iam.gserviceaccount.com") or std.mem.indexOfScalar(u8, email, '@') == null) return error.InvalidServiceAccount;
}
fn validMember(member: []const u8) bool {
    inline for (.{ "user:", "group:", "serviceAccount:", "domain:" }) |prefix| if (std.mem.startsWith(u8, member, prefix) and member.len > prefix.len) return true;
    return std.mem.eql(u8, member, "allUsers") or std.mem.eql(u8, member, "allAuthenticatedUsers");
}
fn isSensitiveKey(key: []const u8) bool {
    const lowered_sensitive = [_][]const u8{ "password", "secret", "token", "private_key", "client_secret" };
    for (lowered_sensitive) |needle| if (std.ascii.indexOfIgnoreCase(key, needle) != null) return true;
    return false;
}
fn targetBasename(target: output.Output([]const u8, .public)) []const u8 {
    const source = switch (target) {
        .value => |text| text,
        .resource_ref => |reference| reference.resource_id,
        .unknown_reason => return "unknown",
    };
    const slash = std.mem.lastIndexOfScalar(u8, source, '/');
    const dot = std.mem.lastIndexOfScalar(u8, source, '.');
    const index = @max(if (slash) |position| position + 1 else 0, if (dot) |position| position + 1 else 0);
    return source[index..];
}
fn slugAlloc(allocator: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    var separator = false;
    for (source) |char| {
        if (std.ascii.isAlphanumeric(char)) {
            if (separator and result.items.len != 0) try result.append(allocator, '-');
            try result.append(allocator, std.ascii.toLower(char));
            separator = false;
        } else separator = true;
    }
    return result.toOwnedSlice(allocator);
}
fn logLevelName(level: LogLevel) []const u8 {
    return switch (level) {
        .off => "OFF",
        .error_level => "ERROR",
        .info => "INFO",
        .debug => "DEBUG",
    };
}
fn lifecycle(protect: bool, removal_policy: RemovalPolicy) resource.Lifecycle {
    return .{ .protect = protect, .retain_on_delete = removal_policy == .retain };
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
fn nodeOwned(allocator: std.mem.Allocator, type_name: []const u8, scope: []const u8, logical: []const u8, parent: ?[]const u8, fields: []const value.Field, resource_lifecycle: resource.Lifecycle) BuildError!resource.ResourceNode {
    const id = if (parent) |selected|
        try std.fmt.allocPrint(allocator, "{s}.{s}.{s}.{s}", .{ type_name, scope, selected, logical })
    else
        try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ type_name, scope, logical });
    defer allocator.free(id);
    return resource.ResourceNode.initOwned(allocator, .{ .id = id, .provider = .gcp, .type_name = type_name, .schema_version = 1, .logical_id = logical, .inputs = .{ .object = fields }, .lifecycle = resource_lifecycle }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}
fn singletonNodeOwned(allocator: std.mem.Allocator, type_name: []const u8, scope: []const u8, logical: []const u8, fields: []const value.Field) BuildError!resource.ResourceNode {
    const id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_name, scope });
    defer allocator.free(id);
    return resource.ResourceNode.initOwned(allocator, .{ .id = id, .provider = .gcp, .type_name = type_name, .schema_version = 1, .logical_id = logical, .inputs = .{ .object = fields }, .lifecycle = .{ .protect = true, .retain_on_delete = true } }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}
