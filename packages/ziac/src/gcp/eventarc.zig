const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    DuplicateFilter,
    DuplicateLabel,
    InvalidChannel,
    InvalidDestination,
    InvalidFilter,
    InvalidLabel,
    InvalidName,
    InvalidResourceName,
    InvalidRetryPolicy,
    InvalidServiceAccount,
    MissingTypeFilter,
    OutputNotKnown,
};

pub const FilterOperator = enum {
    exact,
    path_pattern,
    match_path_pattern,

    pub fn apiName(self: FilterOperator) []const u8 {
        return switch (self) {
            .exact => "",
            .path_pattern => "PATH_PATTERN",
            .match_path_pattern => "MATCH_PATH_PATTERN",
        };
    }
};

pub const EventFilter = struct {
    attribute: []const u8,
    value: []const u8,
    operator: FilterOperator = .exact,
};

pub const CloudRunDestination = struct {
    service: []const u8,
    region: []const u8,
    path: []const u8 = "",
};

pub const GkeDestination = struct {
    cluster: []const u8,
    location: []const u8,
    namespace: []const u8,
    service: []const u8,
    path: []const u8 = "",
};

pub const HttpEndpointDestination = struct {
    uri: []const u8,
    network_attachment: []const u8 = "",
};

pub const Destination = union(enum) {
    cloud_run: CloudRunDestination,
    gke: GkeDestination,
    workflow: []const u8,
    http_endpoint: HttpEndpointDestination,
};

pub const TriggerArgs = struct {
    name: []const u8,
    location: ?[]const u8 = null,
    event_filters: []const EventFilter,
    service_account: []const u8,
    destination: Destination,
    transport_topic: ?output.Output([]const u8, .public) = null,
    labels: []const config_mod.Label = &.{},
    channel: []const u8 = "",
    event_data_content_type: []const u8 = "application/json",
    retry_max_attempts: u8 = 0,
    retain_on_delete: bool = true,
};

pub const Trigger = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Uid = output.Descriptor("uid", []const u8, .public);
        pub const TransportTopic = output.Descriptor("transport_topic", []const u8, .public);
        pub const TransportSubscription = output.Descriptor("transport_subscription", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
        pub const Ready = output.Descriptor("ready", bool, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    uid: Outputs.Uid.OutputType,
    transport_topic: Outputs.TransportTopic.OutputType,
    transport_subscription: Outputs.TransportSubscription.OutputType,
    etag: Outputs.Etag.OutputType,
    ready: Outputs.Ready.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: TriggerArgs) BuildError!Trigger {
        try provider.validate();
        try validateToken(args.name, 1, 63);
        const location = args.location orelse provider.primary_region;
        try validateToken(location, 1, 63);
        if (!validServiceAccount(args.service_account, provider.project_id)) return error.InvalidServiceAccount;
        if (args.event_filters.len == 0) return error.MissingTypeFilter;
        var has_type = false;
        for (args.event_filters, 0..) |filter, index| {
            try validateFilter(filter);
            if (std.mem.eql(u8, filter.attribute, "type")) has_type = true;
            for (args.event_filters[0..index]) |previous| if (std.mem.eql(u8, previous.attribute, filter.attribute)) return error.DuplicateFilter;
        }
        if (!has_type) return error.MissingTypeFilter;
        if (args.event_data_content_type.len == 0 or std.mem.indexOfAny(u8, args.event_data_content_type, "\x00\r\n ") != null) return error.InvalidFilter;
        if (args.retry_max_attempts != 0 and args.retry_max_attempts != 1) return error.InvalidRetryPolicy;
        if (args.retry_max_attempts == 1 and args.destination != .cloud_run) return error.InvalidRetryPolicy;
        if (args.channel.len > 0 and !validChannel(args.channel, provider.project_id, location)) return error.InvalidChannel;
        try validateDestination(args.destination, provider.project_id);

        const filters = try filtersValueAlloc(allocator, args.event_filters);
        defer freeFilterValues(allocator, filters);
        const labels = try labelsValueAlloc(allocator, provider.labels, args.labels);
        defer allocator.free(labels.object);
        const transport = if (args.transport_topic) |topic| try topicValue(topic, provider.project_id) else value.Value{ .string = "" };
        const destination_fields = destinationFields(args.destination);
        const fields = [_]value.Field{
            .{ .name = "channel", .value = .{ .string = args.channel } },
            .{ .name = "destination_kind", .value = .{ .string = destination_fields.kind } },
            .{ .name = "destination_network_attachment", .value = .{ .string = destination_fields.network_attachment } },
            .{ .name = "destination_path", .value = .{ .string = destination_fields.path } },
            .{ .name = "destination_primary", .value = .{ .string = destination_fields.primary } },
            .{ .name = "destination_secondary", .value = .{ .string = destination_fields.secondary } },
            .{ .name = "destination_tertiary", .value = .{ .string = destination_fields.tertiary } },
            .{ .name = "event_data_content_type", .value = .{ .string = args.event_data_content_type } },
            .{ .name = "event_filters", .value = filters },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "retry_max_attempts", .value = .{ .integer = args.retry_max_attempts } },
            .{ .name = "service_account", .value = .{ .string = args.service_account } },
            .{ .name = "transport_topic", .value = transport },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.eventarc.Trigger.{s}.{s}", .{ location, args.name });
        defer allocator.free(id);
        const node = resource.ResourceNode.initOwned(allocator, .{
            .id = id,
            .provider = .gcp,
            .type_name = "gcp.eventarc.Trigger",
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
            .transport_topic = Outputs.TransportTopic.fromResource(node.id),
            .transport_subscription = Outputs.TransportSubscription.fromResource(node.id),
            .etag = Outputs.Etag.fromResource(node.id),
            .ready = Outputs.Ready.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Trigger, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

const DestinationFields = struct {
    kind: []const u8,
    primary: []const u8,
    secondary: []const u8 = "",
    tertiary: []const u8 = "",
    path: []const u8 = "",
    network_attachment: []const u8 = "",
};

fn destinationFields(destination: Destination) DestinationFields {
    return switch (destination) {
        .cloud_run => |target| .{ .kind = "cloud_run", .primary = target.service, .secondary = target.region, .path = target.path },
        .gke => |target| .{ .kind = "gke", .primary = target.cluster, .secondary = target.location, .tertiary = target.namespace, .path = target.path, .network_attachment = target.service },
        .workflow => |workflow| .{ .kind = "workflow", .primary = workflow },
        .http_endpoint => |target| .{ .kind = "http_endpoint", .primary = target.uri, .network_attachment = target.network_attachment },
    };
}

fn validateDestination(destination: Destination, project_id: []const u8) BuildError!void {
    switch (destination) {
        .cloud_run => |target| {
            try validateToken(target.service, 1, 63);
            try validateToken(target.region, 1, 63);
            try validatePath(target.path);
        },
        .gke => |target| {
            try validateToken(target.cluster, 1, 63);
            try validateToken(target.location, 1, 63);
            try validateToken(target.namespace, 1, 63);
            try validateToken(target.service, 1, 63);
            try validatePath(target.path);
        },
        .workflow => |workflow| if (!validWorkflow(workflow, project_id)) return error.InvalidDestination,
        .http_endpoint => |target| {
            if (!validHttpsUrl(target.uri) or !validNetworkAttachment(target.network_attachment, project_id)) return error.InvalidDestination;
        },
    }
}

fn filtersValueAlloc(allocator: std.mem.Allocator, filters: []const EventFilter) BuildError!value.Value {
    const values = try allocator.alloc(value.Value, filters.len);
    errdefer allocator.free(values);
    for (filters, 0..) |filter, index| {
        const fields = try allocator.alloc(value.Field, 3);
        fields[0] = .{ .name = "attribute", .value = .{ .string = filter.attribute } };
        fields[1] = .{ .name = "operator", .value = .{ .string = filter.operator.apiName() } };
        fields[2] = .{ .name = "value", .value = .{ .string = filter.value } };
        values[index] = .{ .object = fields };
    }
    return .{ .list = values };
}

fn freeFilterValues(allocator: std.mem.Allocator, filters: value.Value) void {
    for (filters.list) |entry| allocator.free(entry.object);
    allocator.free(filters.list);
}

fn labelsValueAlloc(allocator: std.mem.Allocator, inherited: []const config_mod.Label, labels: []const config_mod.Label) BuildError!value.Value {
    const fields = try allocator.alloc(value.Field, inherited.len + labels.len);
    errdefer allocator.free(fields);
    var index: usize = 0;
    for (inherited) |label| {
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

fn topicValue(result: output.Output([]const u8, .public), project_id: []const u8) BuildError!value.Value {
    return switch (result) {
        .value => |known| if (validTopic(known, project_id)) .{ .string = known } else error.InvalidResourceName,
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn validateFilter(filter: EventFilter) BuildError!void {
    if (filter.attribute.len == 0 or filter.value.len == 0 or std.mem.indexOfAny(u8, filter.attribute, "\x00\r\n ") != null or
        std.mem.indexOfAny(u8, filter.value, "\x00\r\n") != null) return error.InvalidFilter;
}

fn validateToken(token: []const u8, minimum: usize, maximum: usize) BuildError!void {
    if (token.len < minimum or token.len > maximum or !std.ascii.isAlphanumeric(token[0])) return error.InvalidName;
    for (token) |character| if (!std.ascii.isAlphanumeric(character) and character != '-' and character != '_') return error.InvalidName;
}

fn validatePath(path: []const u8) BuildError!void {
    if (path.len == 0) return;
    if (path[0] != '/' or std.mem.indexOfAny(u8, path, "\x00\r\n?#") != null) return error.InvalidDestination;
}

fn validateLabel(label: config_mod.Label) BuildError!void {
    if (label.key.len == 0 or label.key.len > 63 or label.value.len > 63 or !std.ascii.isLower(label.key[0])) return error.InvalidLabel;
    for (label.key) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-' and character != '_') return error.InvalidLabel;
    for (label.value) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-' and character != '_') return error.InvalidLabel;
}

fn validServiceAccount(email: []const u8, project_id: []const u8) bool {
    return std.mem.endsWith(u8, email, ".iam.gserviceaccount.com") and std.mem.indexOfScalar(u8, email, '@') != null and
        std.mem.indexOf(u8, email, project_id) != null and std.mem.indexOfAny(u8, email, "\x00\r\n /") == null;
}

fn validTopic(name: []const u8, project_id: []const u8) bool {
    if (std.mem.indexOfAny(u8, name, "\x00\r\n?#") != null) return false;
    var parts = std.mem.splitScalar(u8, name, '/');
    return std.mem.eql(u8, parts.next() orelse return false, "projects") and
        std.mem.eql(u8, parts.next() orelse return false, project_id) and
        std.mem.eql(u8, parts.next() orelse return false, "topics") and
        (parts.next() orelse return false).len > 0 and parts.next() == null;
}

fn validChannel(name: []const u8, project_id: []const u8, location: []const u8) bool {
    if (std.mem.indexOfAny(u8, name, "\x00\r\n?#") != null) return false;
    var parts = std.mem.splitScalar(u8, name, '/');
    return std.mem.eql(u8, parts.next() orelse return false, "projects") and
        std.mem.eql(u8, parts.next() orelse return false, project_id) and
        std.mem.eql(u8, parts.next() orelse return false, "locations") and
        std.mem.eql(u8, parts.next() orelse return false, location) and
        std.mem.eql(u8, parts.next() orelse return false, "channels") and
        (parts.next() orelse return false).len > 0 and parts.next() == null;
}

fn validWorkflow(name: []const u8, project_id: []const u8) bool {
    return std.mem.startsWith(u8, name, "projects/") and std.mem.indexOf(u8, name, project_id) != null and
        std.mem.indexOf(u8, name, "/locations/") != null and std.mem.indexOf(u8, name, "/workflows/") != null and
        std.mem.indexOfAny(u8, name, "\x00\r\n?#") == null;
}

fn validNetworkAttachment(name: []const u8, project_id: []const u8) bool {
    return name.len > 0 and std.mem.startsWith(u8, name, "projects/") and std.mem.indexOf(u8, name, project_id) != null and
        std.mem.indexOf(u8, name, "/regions/") != null and std.mem.indexOf(u8, name, "/networkAttachments/") != null and
        std.mem.indexOfAny(u8, name, "\x00\r\n?#") == null;
}

fn validHttpsUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://") and url.len > "https://".len and std.mem.indexOfAny(u8, url, "\x00\r\n ") == null;
}
