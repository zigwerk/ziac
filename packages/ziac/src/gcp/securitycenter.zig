const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    DuplicateItem,
    InvalidDataset,
    InvalidExpiry,
    InvalidFilter,
    InvalidLocation,
    InvalidName,
    InvalidParent,
    InvalidResourceType,
    InvalidTagValue,
    InvalidTopic,
    OutputNotKnown,
};

pub const RemovalPolicy = enum { retain, delete };

pub const SourceArgs = struct {
    name: []const u8,
    organization: output.Output([]const u8, .public),
    display_name: []const u8,
    description: []const u8 = "",
};

pub const Source = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const CanonicalName = output.Descriptor("canonical_name", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    canonical_name: Outputs.CanonicalName.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: SourceArgs) BuildError!Source {
        try provider.validate();
        try validateLogicalName(args.name);
        try validateOrganization(args.organization);
        if (args.display_name.len == 0 or args.display_name.len > 32 or args.description.len > 1024) return error.InvalidName;
        const fields = [_]value.Field{
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "organization", .value = try outputValue(args.organization) },
        };
        const node = try initNode(allocator, "gcp.securitycenter.Source", args.name, &fields, .{ .retain_on_delete = true });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .canonical_name = Outputs.CanonicalName.fromResource(node.id) };
    }

    pub fn deinit(self: *Source, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const NotificationConfigArgs = struct {
    name: []const u8,
    parent: output.Output([]const u8, .public),
    location: []const u8 = "global",
    description: []const u8 = "",
    pubsub_topic: output.Output([]const u8, .public),
    filter: []const u8,
    removal_policy: RemovalPolicy = .retain,
};

pub const NotificationConfig = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const ServiceAccount = output.Descriptor("service_account", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    service_account: Outputs.ServiceAccount.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: NotificationConfigArgs) BuildError!NotificationConfig {
        try provider.validate();
        try validateLogicalName(args.name);
        try validateHierarchy(args.parent);
        try validateLocation(args.location);
        try validateFilter(args.filter);
        try validateOutputPrefix(args.pubsub_topic, "projects/", "/topics/", error.InvalidTopic);
        if (args.description.len > 1024) return error.InvalidName;
        const fields = [_]value.Field{
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "filter", .value = .{ .string = args.filter } },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "parent", .value = try outputValue(args.parent) },
            .{ .name = "pubsub_topic", .value = try outputValue(args.pubsub_topic) },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
        };
        const node = try initNode(allocator, "gcp.securitycenter.NotificationConfig", args.name, &fields, .{ .retain_on_delete = args.removal_policy == .retain });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .service_account = Outputs.ServiceAccount.fromResource(node.id) };
    }

    pub fn deinit(self: *NotificationConfig, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const MuteConfigType = enum { static, dynamic };
pub const MuteConfigArgs = struct {
    name: []const u8,
    parent: output.Output([]const u8, .public),
    location: []const u8 = "global",
    description: []const u8 = "",
    config_type: MuteConfigType,
    filter: []const u8,
    expiry_time: []const u8 = "",
    removal_policy: RemovalPolicy = .retain,
};

pub const MuteConfig = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: MuteConfigArgs) BuildError!MuteConfig {
        try provider.validate();
        try validateLogicalName(args.name);
        try validateHierarchy(args.parent);
        try validateLocation(args.location);
        try validateFilter(args.filter);
        if (args.description.len > 1024 or (args.config_type == .static and args.expiry_time.len != 0) or
            (args.expiry_time.len != 0 and !validTimestamp(args.expiry_time))) return error.InvalidExpiry;
        const fields = [_]value.Field{
            .{ .name = "config_type", .value = .{ .string = if (args.config_type == .static) "STATIC" else "DYNAMIC" } },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "expiry_time", .value = .{ .string = args.expiry_time } },
            .{ .name = "filter", .value = .{ .string = args.filter } },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "parent", .value = try outputValue(args.parent) },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
        };
        const node = try initNode(allocator, "gcp.securitycenter.MuteConfig", args.name, &fields, .{ .retain_on_delete = args.removal_policy == .retain });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
    }

    pub fn deinit(self: *MuteConfig, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const BigQueryExportArgs = struct {
    name: []const u8,
    parent: output.Output([]const u8, .public),
    location: []const u8 = "global",
    description: []const u8 = "",
    dataset: output.Output([]const u8, .public),
    filter: []const u8,
    removal_policy: RemovalPolicy = .retain,
};

pub const BigQueryExport = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Principal = output.Descriptor("principal", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    principal: Outputs.Principal.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: BigQueryExportArgs) BuildError!BigQueryExport {
        try provider.validate();
        try validateLogicalName(args.name);
        try validateHierarchy(args.parent);
        try validateLocation(args.location);
        try validateFilter(args.filter);
        try validateOutputPrefix(args.dataset, "projects/", "/datasets/", error.InvalidDataset);
        if (args.description.len > 1024) return error.InvalidName;
        const fields = [_]value.Field{
            .{ .name = "dataset", .value = try outputValue(args.dataset) },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "filter", .value = .{ .string = args.filter } },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "parent", .value = try outputValue(args.parent) },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
        };
        const node = try initNode(allocator, "gcp.securitycenter.BigQueryExport", args.name, &fields, .{ .retain_on_delete = args.removal_policy == .retain });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .principal = Outputs.Principal.fromResource(node.id) };
    }

    pub fn deinit(self: *BigQueryExport, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const ResourceValue = enum { high, medium, low, none };
pub const CloudProvider = enum { google_cloud, aws, azure };
pub const ResourceValueConfigArgs = struct {
    name: []const u8,
    organization: output.Output([]const u8, .public),
    location: []const u8 = "global",
    description: []const u8 = "",
    resource_value: ResourceValue,
    cloud_provider: CloudProvider = .google_cloud,
    resource_type: []const u8 = "",
    scope: []const u8 = "",
    labels: []const config_mod.Label = &.{},
    tag_values: []const []const u8 = &.{},
    removal_policy: RemovalPolicy = .retain,
};

pub const ResourceValueConfig = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ResourceValueConfigArgs) BuildError!ResourceValueConfig {
        try provider.validate();
        try validateLogicalName(args.name);
        try validateOrganization(args.organization);
        try validateLocation(args.location);
        if (args.description.len > 1024 or (args.resource_type.len != 0 and std.mem.indexOfScalar(u8, args.resource_type, '/') == null)) return error.InvalidResourceType;
        try validateUnique(args.tag_values);
        for (args.tag_values) |tag| if (!canonicalNumeric(tag, "tagValues/")) return error.InvalidTagValue;
        var labels = try labelsValue(allocator, args.labels);
        defer labels.deinit(allocator);
        var tags = try stringsValue(allocator, args.tag_values);
        defer tags.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "cloud_provider", .value = .{ .string = switch (args.cloud_provider) {
                .google_cloud => "GOOGLE_CLOUD_PLATFORM",
                .aws => "AMAZON_WEB_SERVICES",
                .azure => "MICROSOFT_AZURE",
            } } },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "organization", .value = try outputValue(args.organization) },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
            .{ .name = "resource_type", .value = .{ .string = args.resource_type } },
            .{ .name = "resource_value", .value = .{ .string = switch (args.resource_value) {
                .high => "HIGH",
                .medium => "MEDIUM",
                .low => "LOW",
                .none => "NONE",
            } } },
            .{ .name = "scope", .value = .{ .string = args.scope } },
            .{ .name = "tag_values", .value = tags },
        };
        const node = try initNode(allocator, "gcp.securitycenter.ResourceValueConfig", args.name, &fields, .{ .retain_on_delete = args.removal_policy == .retain });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
    }

    pub fn deinit(self: *ResourceValueConfig, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn initNode(allocator: std.mem.Allocator, type_name: []const u8, logical_name: []const u8, fields: []const value.Field, lifecycle: resource.Lifecycle) BuildError!resource.ResourceNode {
    const id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_name, logical_name });
    defer allocator.free(id);
    return resource.ResourceNode.initOwned(allocator, .{ .id = id, .provider = .gcp, .type_name = type_name, .schema_version = 1, .logical_id = logical_name, .inputs = .{ .object = fields }, .lifecycle = lifecycle }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}

fn validateLogicalName(name: []const u8) BuildError!void {
    if (name.len == 0 or name.len > 63 or !std.ascii.isLower(name[0]) or !std.ascii.isAlphanumeric(name[name.len - 1])) return error.InvalidName;
    for (name) |char| if (!(std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '-')) return error.InvalidName;
}

fn validateHierarchy(selected: output.Output([]const u8, .public)) BuildError!void {
    switch (selected) {
        .value => |known| if (!(canonicalNumeric(known, "organizations/") or canonicalNumeric(known, "folders/") or validProject(known))) return error.InvalidParent,
        .resource_ref => {},
        .unknown_reason => return error.OutputNotKnown,
    }
}

fn validateOrganization(selected: output.Output([]const u8, .public)) BuildError!void {
    switch (selected) {
        .value => |known| if (!canonicalNumeric(known, "organizations/")) return error.InvalidParent,
        .resource_ref => {},
        .unknown_reason => return error.OutputNotKnown,
    }
}

fn validateLocation(location: []const u8) BuildError!void {
    if (location.len == 0 or location.len > 63) return error.InvalidLocation;
    for (location) |char| if (!(std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '-')) return error.InvalidLocation;
}

fn validateFilter(filter: []const u8) BuildError!void {
    if (filter.len == 0 or filter.len > 4096 or std.mem.indexOfScalar(u8, filter, '\n') != null) return error.InvalidFilter;
}

fn validateOutputPrefix(selected: output.Output([]const u8, .public), prefix: []const u8, middle: []const u8, failure: error{ InvalidTopic, InvalidDataset }) BuildError!void {
    switch (selected) {
        .value => |known| if (!std.mem.startsWith(u8, known, prefix) or std.mem.indexOf(u8, known, middle) == null) return failure,
        .resource_ref => {},
        .unknown_reason => return error.OutputNotKnown,
    }
}

fn outputValue(selected: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (selected) {
        .value => |known| .{ .string = known },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn labelsValue(allocator: std.mem.Allocator, labels: []const config_mod.Label) BuildError!value.Value {
    const fields = try allocator.alloc(value.Field, labels.len);
    defer allocator.free(fields);
    for (labels, 0..) |label, index| {
        for (labels[index + 1 ..]) |other| if (std.mem.eql(u8, label.key, other.key)) return error.DuplicateItem;
        fields[index] = .{ .name = label.key, .value = .{ .string = label.value } };
    }
    return ownedValue(allocator, .{ .object = fields });
}

fn stringsValue(allocator: std.mem.Allocator, strings: []const []const u8) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, strings.len);
    defer allocator.free(items);
    for (strings, 0..) |item, index| items[index] = .{ .string = item };
    return ownedValue(allocator, .{ .list = items });
}

fn ownedValue(allocator: std.mem.Allocator, source: value.Value) BuildError!value.Value {
    const holder = resource.ResourceNode.initOwned(allocator, .{ .id = "temporary", .provider = .local, .type_name = "local.Value", .schema_version = 1, .logical_id = "temporary", .inputs = source }) catch |err| switch (err) {
        error.DuplicateField => return error.DuplicateField,
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    var mutable = holder;
    const result = mutable.inputs;
    mutable.inputs = .{ .object = &.{} };
    mutable.deinit(allocator);
    return result;
}

fn validateUnique(items: []const []const u8) BuildError!void {
    for (items, 0..) |item, index| for (items[index + 1 ..]) |other| if (std.mem.eql(u8, item, other)) return error.DuplicateItem;
}

fn validProject(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "projects/") or name.len == "projects/".len) return false;
    for (name["projects/".len..]) |char| if (!(std.ascii.isAlphanumeric(char) or char == '-')) return false;
    return true;
}

fn canonicalNumeric(candidate: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, candidate, prefix) or candidate.len == prefix.len) return false;
    for (candidate[prefix.len..]) |char| if (!std.ascii.isDigit(char)) return false;
    return true;
}

fn validTimestamp(candidate: []const u8) bool {
    return candidate.len >= 20 and candidate[4] == '-' and candidate[7] == '-' and candidate[10] == 'T' and candidate[candidate.len - 1] == 'Z';
}
