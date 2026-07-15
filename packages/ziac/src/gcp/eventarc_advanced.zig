const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    DuplicateKey,
    DuplicateValue,
    InvalidDestination,
    InvalidExpression,
    InvalidIamMember,
    InvalidLogging,
    InvalidName,
    InvalidOutput,
    InvalidRegion,
    InvalidRetryPolicy,
    InvalidRole,
    InvalidServiceAccount,
    InvalidSubscription,
};

pub const KeyValue = struct { key: []const u8, value: []const u8 };
pub const RemovalPolicy = enum { retain, delete };
pub const LoggingSeverity = enum { default, debug, info, notice, warning, error_level, critical, alert, emergency };
pub const PayloadFormat = enum { cloud_event_json, json, protobuf, avro };

pub const MessageBusArgs = struct {
    name: []const u8,
    location: []const u8,
    display_name: []const u8 = "",
    crypto_key_name: ?output.Output([]const u8, .public) = null,
    logging_severity: LoggingSeverity = .default,
    labels: []const KeyValue = &.{},
    annotations: []const KeyValue = &.{},
    protect: bool = true,
    removal_policy: RemovalPolicy = .retain,
};

pub const MessageBus = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Uid = output.Descriptor("uid", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    uid: Outputs.Uid.OutputType,
    etag: Outputs.Etag.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: MessageBusArgs) BuildError!MessageBus {
        try provider.validate();
        try validateCommon(provider, args.name, args.location);
        try validateDisplayName(args.display_name);
        var labels = try mapValue(allocator, args.labels, 63, 63);
        defer labels.deinit(allocator);
        var annotations = try mapValue(allocator, args.annotations, 63, 256);
        defer annotations.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "annotations", .value = annotations },
            .{ .name = "crypto_key_name", .value = try optionalOutputValue(args.crypto_key_name) },
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "logging_severity", .value = .{ .string = loggingName(args.logging_severity) } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
        };
        const node = try nodeOwned(allocator, "gcp.eventarc.MessageBus", args.location, args.name, null, &fields, lifecycle(args.protect, args.removal_policy));
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .uid = Outputs.Uid.fromResource(node.id), .etag = Outputs.Etag.fromResource(node.id) };
    }

    pub fn deinit(self: *MessageBus, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const OidcAuthentication = struct { service_account_email: []const u8, audience: []const u8 = "" };
pub const OAuthAuthentication = struct { service_account_email: []const u8, scope: []const u8 = "https://www.googleapis.com/auth/cloud-platform" };
pub const Authentication = union(enum) { oidc: OidcAuthentication, oauth: OAuthAuthentication };
pub const HttpsDestination = struct {
    uri: []const u8,
    authentication: ?Authentication = null,
    network_attachment: ?[]const u8 = null,
    message_binding_template: []const u8 = "",
};
pub const Destination = union(enum) {
    https: HttpsDestination,
    workflow: output.Output([]const u8, .public),
    pubsub_topic: output.Output([]const u8, .public),
    message_bus: output.Output([]const u8, .public),
};
pub const RetryPolicy = struct { max_attempts: u8 = 5, min_delay_seconds: u16 = 5, max_delay_seconds: u16 = 60 };
pub const PipelineArgs = struct {
    name: []const u8,
    location: []const u8,
    display_name: []const u8 = "",
    destination: Destination,
    retry: RetryPolicy = .{},
    input_payload_format: PayloadFormat = .cloud_event_json,
    output_payload_format: PayloadFormat = .cloud_event_json,
    transformation_cel: []const u8 = "",
    crypto_key_name: ?output.Output([]const u8, .public) = null,
    logging_severity: LoggingSeverity = .default,
    labels: []const KeyValue = &.{},
    annotations: []const KeyValue = &.{},
    protect: bool = true,
    removal_policy: RemovalPolicy = .retain,
};

pub const Pipeline = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Uid = output.Descriptor("uid", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    uid: Outputs.Uid.OutputType,
    etag: Outputs.Etag.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: PipelineArgs) BuildError!Pipeline {
        try provider.validate();
        try validateCommon(provider, args.name, args.location);
        try validateDisplayName(args.display_name);
        try validateRetry(args.retry);
        if (args.transformation_cel.len > 4096 or std.mem.indexOfAny(u8, args.transformation_cel, "\r\n") != null) return error.InvalidExpression;
        var destination = try destinationValue(allocator, args.location, args.destination);
        defer destination.deinit(allocator);
        var retry = try retryValue(allocator, args.retry);
        defer retry.deinit(allocator);
        var labels = try mapValue(allocator, args.labels, 63, 63);
        defer labels.deinit(allocator);
        var annotations = try mapValue(allocator, args.annotations, 63, 256);
        defer annotations.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "annotations", .value = annotations },
            .{ .name = "crypto_key_name", .value = try optionalOutputValue(args.crypto_key_name) },
            .{ .name = "destination", .value = destination },
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "input_payload_format", .value = .{ .string = @tagName(args.input_payload_format) } },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "logging_severity", .value = .{ .string = loggingName(args.logging_severity) } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "output_payload_format", .value = .{ .string = @tagName(args.output_payload_format) } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
            .{ .name = "retry", .value = retry },
            .{ .name = "transformation_cel", .value = .{ .string = args.transformation_cel } },
        };
        const node = try nodeOwned(allocator, "gcp.eventarc.Pipeline", args.location, args.name, null, &fields, lifecycle(args.protect, args.removal_policy));
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .uid = Outputs.Uid.fromResource(node.id), .etag = Outputs.Etag.fromResource(node.id) };
    }

    pub fn deinit(self: *Pipeline, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const EnrollmentArgs = struct {
    name: []const u8,
    location: []const u8,
    message_bus: output.Output([]const u8, .public),
    destination_pipeline: output.Output([]const u8, .public),
    cel_match: []const u8,
    display_name: []const u8 = "",
    labels: []const KeyValue = &.{},
    annotations: []const KeyValue = &.{},
    protect: bool = true,
    removal_policy: RemovalPolicy = .retain,
};

pub const Enrollment = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Uid = output.Descriptor("uid", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    uid: Outputs.Uid.OutputType,
    etag: Outputs.Etag.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: EnrollmentArgs) BuildError!Enrollment {
        try provider.validate();
        try validateCommon(provider, args.name, args.location);
        try validateDisplayName(args.display_name);
        try validateCel(args.cel_match);
        try validateRegionalOutput(args.message_bus, args.location, "/messageBuses/");
        try validateRegionalOutput(args.destination_pipeline, args.location, "/pipelines/");
        var labels = try mapValue(allocator, args.labels, 63, 63);
        defer labels.deinit(allocator);
        var annotations = try mapValue(allocator, args.annotations, 63, 256);
        defer annotations.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "annotations", .value = annotations },
            .{ .name = "cel_match", .value = .{ .string = args.cel_match } },
            .{ .name = "destination_pipeline", .value = try outputValue(args.destination_pipeline) },
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "message_bus", .value = try outputValue(args.message_bus) },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
        };
        const node = try nodeOwned(allocator, "gcp.eventarc.Enrollment", args.location, args.name, null, &fields, lifecycle(args.protect, args.removal_policy));
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .uid = Outputs.Uid.fromResource(node.id), .etag = Outputs.Etag.fromResource(node.id) };
    }

    pub fn deinit(self: *Enrollment, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const SourceSubscriptions = union(enum) { projects: []const []const u8, organization: []const u8 };
pub const GoogleApiSourceArgs = struct {
    name: []const u8,
    location: []const u8,
    destination_message_bus: output.Output([]const u8, .public),
    subscriptions: SourceSubscriptions,
    display_name: []const u8 = "",
    crypto_key_name: ?output.Output([]const u8, .public) = null,
    logging_severity: LoggingSeverity = .default,
    labels: []const KeyValue = &.{},
    annotations: []const KeyValue = &.{},
    protect: bool = true,
    removal_policy: RemovalPolicy = .retain,
};

pub const GoogleApiSource = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Uid = output.Descriptor("uid", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    uid: Outputs.Uid.OutputType,
    etag: Outputs.Etag.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: GoogleApiSourceArgs) BuildError!GoogleApiSource {
        try provider.validate();
        try validateCommon(provider, args.name, args.location);
        try validateDisplayName(args.display_name);
        try validateRegionalOutput(args.destination_message_bus, args.location, "/messageBuses/");
        var subscriptions = try subscriptionsValue(allocator, args.subscriptions);
        defer subscriptions.deinit(allocator);
        var labels = try mapValue(allocator, args.labels, 63, 63);
        defer labels.deinit(allocator);
        var annotations = try mapValue(allocator, args.annotations, 63, 256);
        defer annotations.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "annotations", .value = annotations },
            .{ .name = "crypto_key_name", .value = try optionalOutputValue(args.crypto_key_name) },
            .{ .name = "destination_message_bus", .value = try outputValue(args.destination_message_bus) },
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "logging_severity", .value = .{ .string = loggingName(args.logging_severity) } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
            .{ .name = "subscriptions", .value = subscriptions },
        };
        const node = try nodeOwned(allocator, "gcp.eventarc.GoogleApiSource", args.location, args.name, null, &fields, lifecycle(args.protect, args.removal_policy));
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .uid = Outputs.Uid.fromResource(node.id), .etag = Outputs.Etag.fromResource(node.id) };
    }

    pub fn deinit(self: *GoogleApiSource, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const IamCondition = struct { title: []const u8, expression: []const u8, description: []const u8 = "" };
pub const MessageBusIamMemberArgs = struct { location: []const u8, message_bus: output.Output([]const u8, .public), role: []const u8, member: []const u8, condition: ?IamCondition = null, protect: bool = true };
pub const PipelineIamMemberArgs = struct { location: []const u8, pipeline: output.Output([]const u8, .public), role: []const u8, member: []const u8, condition: ?IamCondition = null, protect: bool = true };
pub const EnrollmentIamMemberArgs = struct { location: []const u8, enrollment: output.Output([]const u8, .public), role: []const u8, member: []const u8, condition: ?IamCondition = null, protect: bool = true };
pub const GoogleApiSourceIamMemberArgs = struct { location: []const u8, google_api_source: output.Output([]const u8, .public), role: []const u8, member: []const u8, condition: ?IamCondition = null, protect: bool = true };

pub const MessageBusIamMember = iamWrapper("gcp.eventarc.MessageBusIamMember", MessageBusIamMemberArgs, "message_bus", "/messageBuses/");
pub const PipelineIamMember = iamWrapper("gcp.eventarc.PipelineIamMember", PipelineIamMemberArgs, "pipeline", "/pipelines/");
pub const EnrollmentIamMember = iamWrapper("gcp.eventarc.EnrollmentIamMember", EnrollmentIamMemberArgs, "enrollment", "/enrollments/");
pub const GoogleApiSourceIamMember = iamWrapper("gcp.eventarc.GoogleApiSourceIamMember", GoogleApiSourceIamMemberArgs, "google_api_source", "/googleApiSources/");

fn iamWrapper(comptime type_name: []const u8, comptime Args: type, comptime target_field: []const u8, comptime segment: []const u8) type {
    return struct {
        node: resource.ResourceNode,
        pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: Args) BuildError!@This() {
            const target = @field(args, target_field);
            return .{ .node = try iamNode(allocator, provider, type_name, args.location, target, segment, args.role, args.member, args.condition, args.protect) };
        }
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.node.deinit(allocator);
            self.* = undefined;
        }
    };
}

fn iamNode(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, type_name: []const u8, location: []const u8, target: output.Output([]const u8, .public), segment: []const u8, role: []const u8, member: []const u8, condition: ?IamCondition, protect: bool) BuildError!resource.ResourceNode {
    try provider.validate();
    try validateRegion(provider, location);
    try validateRegionalOutput(target, location, segment);
    if (!std.mem.startsWith(u8, role, "roles/") or std.mem.indexOfScalar(u8, role, ' ') != null) return error.InvalidRole;
    if (!validMember(member)) return error.InvalidIamMember;
    var condition_value = if (condition) |selected| try conditionValue(allocator, selected) else try ownedValue(allocator, .{ .object = &.{} });
    defer condition_value.deinit(allocator);
    const target_name = targetBasename(target);
    const identity = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ role, member });
    defer allocator.free(identity);
    const logical = try slugAlloc(allocator, identity);
    defer allocator.free(logical);
    const fields = [_]value.Field{
        .{ .name = "condition", .value = condition_value },
        .{ .name = "has_condition", .value = .{ .boolean = condition != null } },
        .{ .name = "location", .value = .{ .string = location } },
        .{ .name = "member", .value = .{ .string = member } },
        .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        .{ .name = "resource", .value = try outputValue(target) },
        .{ .name = "role", .value = .{ .string = role } },
    };
    return nodeOwned(allocator, type_name, location, logical, target_name, &fields, .{ .protect = protect });
}

fn destinationValue(allocator: std.mem.Allocator, location: []const u8, destination: Destination) BuildError!value.Value {
    return switch (destination) {
        .https => |selected| blk: {
            if (!std.mem.startsWith(u8, selected.uri, "https://") or selected.uri.len > 2048 or std.mem.indexOfAny(u8, selected.uri, "\r\n") != null) return error.InvalidDestination;
            if (selected.network_attachment) |attachment| {
                if (std.mem.indexOf(u8, attachment, "/networkAttachments/") == null or std.mem.indexOf(u8, attachment, location) == null) return error.InvalidDestination;
            }
            if (selected.message_binding_template.len > 4096) return error.InvalidExpression;
            var authentication = if (selected.authentication) |auth| try authenticationValue(allocator, auth) else try ownedValue(allocator, .{ .object = &.{} });
            defer authentication.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "authentication", .value = authentication },
                .{ .name = "kind", .value = .{ .string = "https" } },
                .{ .name = "message_binding_template", .value = .{ .string = selected.message_binding_template } },
                .{ .name = "network_attachment", .value = .{ .string = selected.network_attachment orelse "" } },
                .{ .name = "uri", .value = .{ .string = selected.uri } },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
        .workflow => |selected| try referenceDestinationValue(allocator, "workflow", selected, "/workflows/"),
        .pubsub_topic => |selected| try referenceDestinationValue(allocator, "pubsub_topic", selected, "/topics/"),
        .message_bus => |selected| try referenceDestinationValue(allocator, "message_bus", selected, "/messageBuses/"),
    };
}

fn referenceDestinationValue(allocator: std.mem.Allocator, kind: []const u8, selected: output.Output([]const u8, .public), segment: []const u8) BuildError!value.Value {
    try validateOutputContains(selected, segment);
    const fields = [_]value.Field{
        .{ .name = "kind", .value = .{ .string = kind } },
        .{ .name = "resource", .value = try outputValue(selected) },
    };
    return ownedValue(allocator, .{ .object = &fields });
}

fn authenticationValue(allocator: std.mem.Allocator, authentication: Authentication) BuildError!value.Value {
    const kind: []const u8, const service_account: []const u8, const claim: []const u8 = switch (authentication) {
        .oidc => |selected| .{ "oidc", selected.service_account_email, selected.audience },
        .oauth => |selected| .{ "oauth", selected.service_account_email, selected.scope },
    };
    try validateServiceAccount(service_account);
    if (claim.len > 2048 or std.mem.indexOfAny(u8, claim, "\r\n") != null) return error.InvalidDestination;
    const fields = [_]value.Field{
        .{ .name = "claim", .value = .{ .string = claim } },
        .{ .name = "kind", .value = .{ .string = kind } },
        .{ .name = "service_account_email", .value = .{ .string = service_account } },
    };
    return ownedValue(allocator, .{ .object = &fields });
}

fn retryValue(allocator: std.mem.Allocator, retry: RetryPolicy) BuildError!value.Value {
    try validateRetry(retry);
    const fields = [_]value.Field{
        .{ .name = "max_attempts", .value = .{ .integer = retry.max_attempts } },
        .{ .name = "max_delay_seconds", .value = .{ .integer = retry.max_delay_seconds } },
        .{ .name = "min_delay_seconds", .value = .{ .integer = retry.min_delay_seconds } },
    };
    return ownedValue(allocator, .{ .object = &fields });
}

fn subscriptionsValue(allocator: std.mem.Allocator, subscriptions: SourceSubscriptions) BuildError!value.Value {
    return switch (subscriptions) {
        .projects => |projects| blk: {
            if (projects.len == 0 or projects.len > 100) return error.InvalidSubscription;
            try validateUnique(projects);
            for (projects) |project| if (!isNumeric(project)) return error.InvalidSubscription;
            var project_values = try stringsValue(allocator, projects);
            defer project_values.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "kind", .value = .{ .string = "projects" } },
                .{ .name = "projects", .value = project_values },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
        .organization => |organization| blk: {
            if (!isNumeric(organization)) return error.InvalidSubscription;
            const fields = [_]value.Field{
                .{ .name = "kind", .value = .{ .string = "organization" } },
                .{ .name = "organization", .value = .{ .string = organization } },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
    };
}

fn mapValue(allocator: std.mem.Allocator, items: []const KeyValue, max_key: usize, max_value: usize) BuildError!value.Value {
    const fields = try allocator.alloc(value.Field, items.len);
    defer allocator.free(fields);
    for (items, 0..) |item, index| {
        if (item.key.len == 0 or item.key.len > max_key or item.value.len > max_value) return error.InvalidName;
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
fn validateOutputContains(selected: output.Output([]const u8, .public), segment: []const u8) BuildError!void {
    switch (selected) {
        .value => |text| if (std.mem.indexOf(u8, text, segment) == null) return error.InvalidOutput,
        .resource_ref => {},
        .unknown_reason => return error.InvalidOutput,
    }
}
fn validateRegionalOutput(selected: output.Output([]const u8, .public), location: []const u8, segment: []const u8) BuildError!void {
    try validateOutputContains(selected, segment);
    switch (selected) {
        .value => |text| {
            const marker = try std.fmt.allocPrint(std.heap.page_allocator, "/locations/{s}/", .{location});
            defer std.heap.page_allocator.free(marker);
            if (std.mem.indexOf(u8, text, marker) == null) return error.InvalidRegion;
        },
        .resource_ref, .unknown_reason => {},
    }
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
fn validateDisplayName(name: []const u8) BuildError!void {
    if (name.len > 63 or std.mem.indexOfAny(u8, name, "\r\n") != null) return error.InvalidName;
}
fn validateCel(expression: []const u8) BuildError!void {
    if (expression.len == 0 or expression.len > 4096 or std.mem.indexOfAny(u8, expression, "\r\n") != null) return error.InvalidExpression;
}
fn validateRetry(retry: RetryPolicy) BuildError!void {
    if (retry.max_attempts == 0 or retry.max_attempts > 100 or retry.min_delay_seconds == 0 or retry.min_delay_seconds > 600 or retry.max_delay_seconds == 0 or retry.max_delay_seconds > 600 or retry.min_delay_seconds > retry.max_delay_seconds) return error.InvalidRetryPolicy;
}
fn validateServiceAccount(email: []const u8) BuildError!void {
    if (!std.mem.endsWith(u8, email, ".iam.gserviceaccount.com") or std.mem.indexOfScalar(u8, email, '@') == null) return error.InvalidServiceAccount;
}
fn validateUnique(items: []const []const u8) BuildError!void {
    for (items, 0..) |item, index| for (items[0..index]) |prior| if (std.mem.eql(u8, prior, item)) return error.DuplicateValue;
}
fn isNumeric(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |char| if (!std.ascii.isDigit(char)) return false;
    return true;
}
fn validMember(member: []const u8) bool {
    inline for (.{ "user:", "group:", "serviceAccount:", "domain:" }) |prefix| if (std.mem.startsWith(u8, member, prefix) and member.len > prefix.len) return true;
    return std.mem.eql(u8, member, "allUsers") or std.mem.eql(u8, member, "allAuthenticatedUsers");
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
fn loggingName(severity: LoggingSeverity) []const u8 {
    return switch (severity) {
        .default => "LOG_SEVERITY_UNSPECIFIED",
        .debug => "DEBUG",
        .info => "INFO",
        .notice => "NOTICE",
        .warning => "WARNING",
        .error_level => "ERROR",
        .critical => "CRITICAL",
        .alert => "ALERT",
        .emergency => "EMERGENCY",
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
