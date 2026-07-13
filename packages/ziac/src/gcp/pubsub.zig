const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    DuplicateLabel,
    InvalidAckDeadline,
    InvalidDeliveryAttempts,
    InvalidExpiration,
    InvalidFilter,
    InvalidIamCondition,
    InvalidKmsKey,
    InvalidMember,
    InvalidName,
    InvalidPushEndpoint,
    InvalidRegion,
    InvalidResourceName,
    InvalidRetention,
    InvalidRetryPolicy,
    InvalidRole,
    InvalidSchema,
    InvalidServiceAccount,
    OutputNotKnown,
};

pub const SchemaType = enum {
    protocol_buffer,
    avro,

    pub fn apiName(self: SchemaType) []const u8 {
        return switch (self) {
            .protocol_buffer => "PROTOCOL_BUFFER",
            .avro => "AVRO",
        };
    }
};

pub const SchemaEncoding = enum {
    json,
    binary,

    pub fn apiName(self: SchemaEncoding) []const u8 {
        return switch (self) {
            .json => "JSON",
            .binary => "BINARY",
        };
    }
};

pub const SchemaArgs = struct {
    name: []const u8,
    schema_type: SchemaType,
    definition: []const u8,
    retain_on_delete: bool = true,
};

pub const Schema = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const RevisionId = output.Descriptor("revision_id", []const u8, .public);
        pub const RevisionCreateTime = output.Descriptor("revision_create_time", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    revision_id: Outputs.RevisionId.OutputType,
    revision_create_time: Outputs.RevisionCreateTime.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: SchemaArgs) BuildError!Schema {
        try provider.validate();
        try validateResourceId(args.name);
        if (!validText(args.definition) or args.definition.len > 300_000) return error.InvalidSchema;
        const fields = [_]value.Field{
            .{ .name = "definition", .value = .{ .string = args.definition } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "schema_type", .value = .{ .string = args.schema_type.apiName() } },
        };
        const node = try buildNode(allocator, "gcp.pubsub.Schema", args.name, &fields, args.retain_on_delete);
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .revision_id = Outputs.RevisionId.fromResource(node.id),
            .revision_create_time = Outputs.RevisionCreateTime.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Schema, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const TopicArgs = struct {
    name: []const u8,
    labels: []const config_mod.Label = &.{},
    kms_key_name: ?[]const u8 = null,
    message_retention_seconds: u32 = 0,
    allowed_persistence_regions: []const []const u8 = &.{},
    enforce_in_transit: bool = false,
    schema_name: ?output.Output([]const u8, .public) = null,
    schema_encoding: SchemaEncoding = .json,
    retain_on_delete: bool = true,
};

pub const Topic = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const KmsKeyName = output.Descriptor("kms_key_name", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    kms_key_name: Outputs.KmsKeyName.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: TopicArgs) BuildError!Topic {
        try provider.validate();
        try validateResourceId(args.name);
        try validateRetention(args.message_retention_seconds, true);
        if (args.kms_key_name) |key| if (!isKmsKeyName(key)) return error.InvalidKmsKey;
        if (args.enforce_in_transit and args.allowed_persistence_regions.len == 0) return error.InvalidRegion;
        for (args.allowed_persistence_regions) |region| if (!validRegion(region)) return error.InvalidRegion;
        const labels = try labelsValueAlloc(allocator, provider.labels, args.labels);
        defer allocator.free(labels.object);
        const regions = try stringListValueAlloc(allocator, args.allowed_persistence_regions);
        defer allocator.free(regions.list);
        const schema = if (args.schema_name) |name| try resourceValue(name, provider.project_id, "schemas") else value.Value{ .string = "" };
        const fields = [_]value.Field{
            .{ .name = "allowed_persistence_regions", .value = regions },
            .{ .name = "enforce_in_transit", .value = .{ .boolean = args.enforce_in_transit } },
            .{ .name = "kms_key_name", .value = .{ .string = args.kms_key_name orelse "" } },
            .{ .name = "labels", .value = labels },
            .{ .name = "message_retention_seconds", .value = .{ .integer = args.message_retention_seconds } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "schema_encoding", .value = .{ .string = if (args.schema_name != null) args.schema_encoding.apiName() else "" } },
            .{ .name = "schema_name", .value = schema },
        };
        const node = try buildNode(allocator, "gcp.pubsub.Topic", args.name, &fields, args.retain_on_delete);
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .kms_key_name = Outputs.KmsKeyName.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Topic, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const PushConfig = struct {
    endpoint: []const u8,
    oidc_service_account_email: ?[]const u8 = null,
    oidc_audience: ?[]const u8 = null,
};

pub const Delivery = union(enum) {
    pull,
    push: PushConfig,
};

pub const Expiration = union(enum) {
    default,
    never,
    ttl_seconds: u32,
};

pub const RetryPolicy = struct {
    minimum_backoff_seconds: u16 = 10,
    maximum_backoff_seconds: u16 = 600,
};

pub const SubscriptionArgs = struct {
    name: []const u8,
    topic: output.Output([]const u8, .public),
    delivery: Delivery = .pull,
    labels: []const config_mod.Label = &.{},
    ack_deadline_seconds: u16 = 10,
    retain_acked_messages: bool = false,
    message_retention_seconds: u32 = 7 * 24 * 60 * 60,
    expiration: Expiration = .default,
    enable_message_ordering: bool = false,
    enable_exactly_once_delivery: bool = false,
    filter: []const u8 = "",
    dead_letter_topic: ?output.Output([]const u8, .public) = null,
    max_delivery_attempts: u8 = 0,
    retry_policy: ?RetryPolicy = null,
    retain_on_delete: bool = true,
};

pub const Subscription = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Topic = output.Descriptor("topic", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    topic: Outputs.Topic.OutputType,
    state: Outputs.State.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: SubscriptionArgs) BuildError!Subscription {
        try provider.validate();
        try validateResourceId(args.name);
        if (args.ack_deadline_seconds < 10 or args.ack_deadline_seconds > 600) return error.InvalidAckDeadline;
        try validateRetention(args.message_retention_seconds, false);
        if (args.filter.len > 256 or (args.filter.len > 0 and !validText(args.filter))) return error.InvalidFilter;
        const expiration_seconds: i64 = switch (args.expiration) {
            .default => 31 * 24 * 60 * 60,
            .never => 0,
            .ttl_seconds => |seconds| if (seconds < 24 * 60 * 60 or seconds > std.math.maxInt(i32)) return error.InvalidExpiration else seconds,
        };
        if (args.dead_letter_topic == null and args.max_delivery_attempts != 0) return error.InvalidDeliveryAttempts;
        if (args.dead_letter_topic != null and (args.max_delivery_attempts < 5 or args.max_delivery_attempts > 100)) return error.InvalidDeliveryAttempts;
        if (args.retry_policy) |policy| {
            if (policy.minimum_backoff_seconds > 600 or policy.maximum_backoff_seconds > 600 or
                policy.minimum_backoff_seconds > policy.maximum_backoff_seconds) return error.InvalidRetryPolicy;
        }
        var push_endpoint: []const u8 = "";
        var push_service_account: []const u8 = "";
        var push_audience: []const u8 = "";
        const delivery_kind = switch (args.delivery) {
            .pull => "pull",
            .push => |push| block: {
                if (!validHttpsUrl(push.endpoint)) return error.InvalidPushEndpoint;
                if (push.oidc_service_account_email) |email| {
                    if (!validServiceAccount(email, provider.project_id)) return error.InvalidServiceAccount;
                    push_service_account = email;
                } else if (push.oidc_audience != null) return error.InvalidServiceAccount;
                if (push.oidc_audience) |audience| {
                    if (!validHttpsUrl(audience)) return error.InvalidPushEndpoint;
                    push_audience = audience;
                }
                push_endpoint = push.endpoint;
                break :block "push";
            },
        };
        const labels = try labelsValueAlloc(allocator, provider.labels, args.labels);
        defer allocator.free(labels.object);
        const topic = try resourceValue(args.topic, provider.project_id, "topics");
        const dead_letter = if (args.dead_letter_topic) |name| try resourceValue(name, provider.project_id, "topics") else value.Value{ .string = "" };
        const retry = args.retry_policy orelse RetryPolicy{ .minimum_backoff_seconds = 0, .maximum_backoff_seconds = 0 };
        const fields = [_]value.Field{
            .{ .name = "ack_deadline_seconds", .value = .{ .integer = args.ack_deadline_seconds } },
            .{ .name = "dead_letter_topic", .value = dead_letter },
            .{ .name = "delivery_kind", .value = .{ .string = delivery_kind } },
            .{ .name = "enable_exactly_once_delivery", .value = .{ .boolean = args.enable_exactly_once_delivery } },
            .{ .name = "enable_message_ordering", .value = .{ .boolean = args.enable_message_ordering } },
            .{ .name = "expiration_ttl_seconds", .value = .{ .integer = expiration_seconds } },
            .{ .name = "filter", .value = .{ .string = args.filter } },
            .{ .name = "labels", .value = labels },
            .{ .name = "max_delivery_attempts", .value = .{ .integer = args.max_delivery_attempts } },
            .{ .name = "message_retention_seconds", .value = .{ .integer = args.message_retention_seconds } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "push_audience", .value = .{ .string = push_audience } },
            .{ .name = "push_endpoint", .value = .{ .string = push_endpoint } },
            .{ .name = "push_service_account", .value = .{ .string = push_service_account } },
            .{ .name = "retain_acked_messages", .value = .{ .boolean = args.retain_acked_messages } },
            .{ .name = "retry_maximum_backoff_seconds", .value = .{ .integer = retry.maximum_backoff_seconds } },
            .{ .name = "retry_minimum_backoff_seconds", .value = .{ .integer = retry.minimum_backoff_seconds } },
            .{ .name = "topic", .value = topic },
        };
        const node = try buildNode(allocator, "gcp.pubsub.Subscription", args.name, &fields, args.retain_on_delete);
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .topic = Outputs.Topic.fromResource(node.id),
            .state = Outputs.State.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Subscription, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const SnapshotArgs = struct {
    name: []const u8,
    subscription: output.Output([]const u8, .public),
    labels: []const config_mod.Label = &.{},
    retain_on_delete: bool = true,
};

pub const Snapshot = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Topic = output.Descriptor("topic", []const u8, .public);
        pub const ExpireTime = output.Descriptor("expire_time", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    topic: Outputs.Topic.OutputType,
    expire_time: Outputs.ExpireTime.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: SnapshotArgs) BuildError!Snapshot {
        try provider.validate();
        try validateResourceId(args.name);
        const labels = try labelsValueAlloc(allocator, provider.labels, args.labels);
        defer allocator.free(labels.object);
        const fields = [_]value.Field{
            .{ .name = "labels", .value = labels },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "subscription", .value = try resourceValue(args.subscription, provider.project_id, "subscriptions") },
        };
        const node = try buildNode(allocator, "gcp.pubsub.Snapshot", args.name, &fields, args.retain_on_delete);
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .topic = Outputs.Topic.fromResource(node.id),
            .expire_time = Outputs.ExpireTime.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const IamCondition = struct {
    title: []const u8,
    description: []const u8 = "",
    expression: []const u8,
};

pub const TopicIamMemberArgs = struct {
    name: []const u8,
    topic: output.Output([]const u8, .public),
    role: []const u8,
    member: []const u8,
    condition: ?IamCondition = null,
};

pub const TopicIamMember = struct {
    pub const Outputs = struct {
        pub const BindingId = output.Descriptor("binding_id", []const u8, .public);
    };

    node: resource.ResourceNode,
    binding_id: Outputs.BindingId.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: TopicIamMemberArgs) BuildError!TopicIamMember {
        const node = try buildIamMember(allocator, provider, "TopicIamMember", args.name, args.topic, "topics", args.role, args.member, args.condition);
        return .{ .node = node, .binding_id = Outputs.BindingId.fromResource(node.id) };
    }

    pub fn deinit(self: *TopicIamMember, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const SubscriptionIamMemberArgs = struct {
    name: []const u8,
    subscription: output.Output([]const u8, .public),
    role: []const u8,
    member: []const u8,
    condition: ?IamCondition = null,
};

pub const SubscriptionIamMember = struct {
    pub const Outputs = struct {
        pub const BindingId = output.Descriptor("binding_id", []const u8, .public);
    };

    node: resource.ResourceNode,
    binding_id: Outputs.BindingId.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: SubscriptionIamMemberArgs) BuildError!SubscriptionIamMember {
        const node = try buildIamMember(allocator, provider, "SubscriptionIamMember", args.name, args.subscription, "subscriptions", args.role, args.member, args.condition);
        return .{ .node = node, .binding_id = Outputs.BindingId.fromResource(node.id) };
    }

    pub fn deinit(self: *SubscriptionIamMember, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn buildIamMember(
    allocator: std.mem.Allocator,
    provider: config_mod.ProviderConfig,
    comptime suffix: []const u8,
    name: []const u8,
    target: output.Output([]const u8, .public),
    collection: []const u8,
    role: []const u8,
    member: []const u8,
    condition: ?IamCondition,
) BuildError!resource.ResourceNode {
    try provider.validate();
    try validateResourceId(name);
    if (!std.mem.startsWith(u8, role, "roles/pubsub.") or role.len <= "roles/pubsub.".len or !validText(role)) return error.InvalidRole;
    if (!validIamMember(member)) return error.InvalidMember;
    if (condition) |entry| try validateIamCondition(member, entry);
    const fields = [_]value.Field{
        .{ .name = "condition_description", .value = .{ .string = if (condition) |entry| entry.description else "" } },
        .{ .name = "condition_expression", .value = .{ .string = if (condition) |entry| entry.expression else "" } },
        .{ .name = "condition_title", .value = .{ .string = if (condition) |entry| entry.title else "" } },
        .{ .name = "member", .value = .{ .string = member } },
        .{ .name = "name", .value = .{ .string = name } },
        .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        .{ .name = "resource", .value = try resourceValue(target, provider.project_id, collection) },
        .{ .name = "role", .value = .{ .string = role } },
    };
    return buildNode(allocator, "gcp.pubsub." ++ suffix, name, &fields, false);
}

fn buildNode(
    allocator: std.mem.Allocator,
    type_name: []const u8,
    name: []const u8,
    fields: []const value.Field,
    retain_on_delete: bool,
) BuildError!resource.ResourceNode {
    const id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_name, name });
    defer allocator.free(id);
    return resource.ResourceNode.initOwned(allocator, .{
        .id = id,
        .provider = .gcp,
        .type_name = type_name,
        .logical_id = name,
        .inputs = .{ .object = fields },
        .lifecycle = .{
            .retain_on_delete = retain_on_delete,
            .operation_timeout_millis = 15 * 60 * 1000,
        },
    }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
    };
}

fn resourceValue(result: output.Output([]const u8, .public), project_id: []const u8, collection: []const u8) BuildError!value.Value {
    return switch (result) {
        .value => |known| if (validResourceName(known, project_id, collection)) .{ .string = known } else error.InvalidResourceName,
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn labelsValueAlloc(allocator: std.mem.Allocator, provider_labels: []const config_mod.Label, labels: []const config_mod.Label) BuildError!value.Value {
    const fields = try allocator.alloc(value.Field, provider_labels.len + labels.len);
    errdefer allocator.free(fields);
    var index: usize = 0;
    for (provider_labels) |label| {
        try validateLabel(label);
        fields[index] = .{ .name = label.key, .value = .{ .string = label.value } };
        index += 1;
    }
    for (labels) |label| {
        try validateLabel(label);
        for (fields[0..index]) |existing| if (std.mem.eql(u8, existing.name, label.key)) return error.DuplicateLabel;
        fields[index] = .{ .name = label.key, .value = .{ .string = label.value } };
        index += 1;
    }
    return .{ .object = fields };
}

fn stringListValueAlloc(allocator: std.mem.Allocator, strings: []const []const u8) std.mem.Allocator.Error!value.Value {
    const values = try allocator.alloc(value.Value, strings.len);
    for (strings, 0..) |string, index| values[index] = .{ .string = string };
    return .{ .list = values };
}

fn validateResourceId(name: []const u8) BuildError!void {
    if (name.len < 3 or name.len > 255 or !std.ascii.isAlphabetic(name[0]) or std.ascii.startsWithIgnoreCase(name, "goog")) return error.InvalidName;
    for (name) |character| {
        if (!std.ascii.isAlphanumeric(character) and std.mem.indexOfScalar(u8, "-_.~+%", character) == null) return error.InvalidName;
    }
}

fn validateRetention(seconds: u32, allow_unset: bool) BuildError!void {
    if (allow_unset and seconds == 0) return;
    if (seconds < 10 * 60 or seconds > 31 * 24 * 60 * 60) return error.InvalidRetention;
}

fn validResourceName(name: []const u8, project_id: []const u8, collection: []const u8) bool {
    var parts = std.mem.splitScalar(u8, name, '/');
    return std.mem.eql(u8, parts.next() orelse return false, "projects") and
        std.mem.eql(u8, parts.next() orelse return false, project_id) and
        std.mem.eql(u8, parts.next() orelse return false, collection) and
        isResourceId(parts.next() orelse return false) and
        parts.next() == null;
}

fn isResourceId(name: []const u8) bool {
    validateResourceId(name) catch return false;
    return true;
}

fn validRegion(region: []const u8) bool {
    if (region.len < 3 or region.len > 63 or !std.ascii.isLower(region[0])) return false;
    for (region) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return false;
    return true;
}

fn isKmsKeyName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "projects/")) return false;
    const markers = [_][]const u8{ "/locations/", "/keyRings/", "/cryptoKeys/" };
    var offset: usize = "projects/".len;
    for (markers) |marker| {
        const found = std.mem.indexOfPos(u8, name, offset, marker) orelse return false;
        if (found == offset) return false;
        offset = found + marker.len;
    }
    return offset < name.len and std.mem.indexOfAny(u8, name, "\x00\r\n?#") == null;
}

fn validText(text: []const u8) bool {
    return text.len > 0 and std.mem.indexOfAny(u8, text, "\x00") == null;
}

fn validHttpsUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://") and url.len > "https://".len and std.mem.indexOfAny(u8, url, "\x00\r\n ") == null;
}

fn validServiceAccount(email: []const u8, project_id: []const u8) bool {
    return std.mem.endsWith(u8, email, ".iam.gserviceaccount.com") and
        std.mem.indexOfScalar(u8, email, '@') != null and
        std.mem.indexOf(u8, email, project_id) != null and
        std.mem.indexOfAny(u8, email, "\x00\r\n /") == null;
}

fn validateLabel(label: config_mod.Label) BuildError!void {
    if (label.key.len == 0 or label.key.len > 63 or label.value.len > 63 or !std.ascii.isLower(label.key[0])) return error.InvalidName;
    for (label.key) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-' and character != '_') return error.InvalidName;
    for (label.value) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-' and character != '_') return error.InvalidName;
}

fn validIamMember(member: []const u8) bool {
    return (std.mem.eql(u8, member, "allUsers") or
        std.mem.eql(u8, member, "allAuthenticatedUsers") or
        std.mem.indexOfScalar(u8, member, ':') != null) and
        std.mem.indexOfAny(u8, member, "\x00\r\n ") == null;
}

fn validateIamCondition(member: []const u8, condition: IamCondition) BuildError!void {
    if (std.mem.eql(u8, member, "allUsers") or std.mem.eql(u8, member, "allAuthenticatedUsers")) return error.InvalidIamCondition;
    if (!validText(condition.title) or condition.title.len > 100 or !validText(condition.expression)) return error.InvalidIamCondition;
    if (condition.description.len > 0 and !validText(condition.description)) return error.InvalidIamCondition;
}
