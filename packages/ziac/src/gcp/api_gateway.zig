const std = @import("std");
const config_mod = @import("config.zig");
const iam = @import("iam.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || resource.ResourceGraphError || std.mem.Allocator.Error || error{
    DuplicateDocument,
    InvalidCondition,
    InvalidDigest,
    InvalidDisplayName,
    InvalidDocument,
    InvalidLocation,
    InvalidMember,
    InvalidResourceId,
    InvalidRole,
    OutputNotKnown,
};

pub const ApiArgs = struct {
    api_id: []const u8,
    display_name: []const u8 = "",
    labels: []const config_mod.Label = &.{},
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const Api = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    state: Outputs.State.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ApiArgs) BuildError!Api {
        try provider.validate();
        try validateId(args.api_id);
        try validateDisplayName(args.display_name);
        const labels = try labelsTextAlloc(allocator, args.labels);
        defer allocator.free(labels);
        const fields = [_]value.Field{
            .{ .name = "api_id", .value = .{ .string = args.api_id } },
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "labels", .value = .{ .string = labels } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.apigateway.Api.{s}", .{args.api_id});
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.apigateway.Api", args.api_id, &fields, .{ .protect = args.protect, .retain_on_delete = args.retain_on_delete, .operation_timeout_millis = 30 * 60 * 1000 });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .state = Outputs.State.fromResource(node.id) };
    }

    pub fn deinit(self: *Api, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const Document = struct {
    path: []const u8,
    contents: output.Output(value.SecretReference, .secret),
    sha256: []const u8,
};

pub const ApiConfigArgs = struct {
    api: output.Output([]const u8, .public),
    api_id: []const u8,
    config_id: []const u8,
    display_name: []const u8 = "",
    documents: []const Document,
    labels: []const config_mod.Label = &.{},
    gateway_service_account: []const u8 = "",
    retain_on_delete: bool = true,
};

pub const ApiConfig = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
        pub const ServiceAccount = output.Descriptor("service_account", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    state: Outputs.State.OutputType,
    service_account: Outputs.ServiceAccount.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ApiConfigArgs) BuildError!ApiConfig {
        try provider.validate();
        try validateId(args.api_id);
        try validateId(args.config_id);
        try validateDisplayName(args.display_name);
        if (args.documents.len == 0 or args.documents.len > 32) return error.InvalidDocument;
        var docs = try documentsValueAlloc(allocator, args.documents);
        defer docs.deinit(allocator);
        const labels = try labelsTextAlloc(allocator, args.labels);
        defer allocator.free(labels);
        const fields = [_]value.Field{
            .{ .name = "api", .value = try publicOutputValue(args.api) },
            .{ .name = "api_id", .value = .{ .string = args.api_id } },
            .{ .name = "config_id", .value = .{ .string = args.config_id } },
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "documents", .value = docs },
            .{ .name = "gateway_service_account", .value = .{ .string = args.gateway_service_account } },
            .{ .name = "labels", .value = .{ .string = labels } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.apigateway.ApiConfig.{s}.{s}", .{ args.api_id, args.config_id });
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.apigateway.ApiConfig", args.config_id, &fields, .{ .retain_on_delete = args.retain_on_delete, .operation_timeout_millis = 60 * 60 * 1000 });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .state = Outputs.State.fromResource(node.id),
            .service_account = Outputs.ServiceAccount.fromResource(node.id),
        };
    }

    pub fn deinit(self: *ApiConfig, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const GatewayArgs = struct {
    gateway_id: []const u8,
    location: ?[]const u8 = null,
    api_config: output.Output([]const u8, .public),
    api_id: []const u8,
    config_id: []const u8,
    display_name: []const u8 = "",
    labels: []const config_mod.Label = &.{},
    deletion_protection: bool = true,
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const Gateway = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const DefaultHostname = output.Descriptor("default_hostname", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    default_hostname: Outputs.DefaultHostname.OutputType,
    state: Outputs.State.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: GatewayArgs) BuildError!Gateway {
        try provider.validate();
        try validateId(args.gateway_id);
        try validateId(args.api_id);
        try validateId(args.config_id);
        try validateDisplayName(args.display_name);
        const location = args.location orelse provider.primary_region;
        try validateId(location);
        const labels = try labelsTextAlloc(allocator, args.labels);
        defer allocator.free(labels);
        const fields = [_]value.Field{
            .{ .name = "api_config", .value = try publicOutputValue(args.api_config) },
            .{ .name = "api_id", .value = .{ .string = args.api_id } },
            .{ .name = "config_id", .value = .{ .string = args.config_id } },
            .{ .name = "deletion_protection", .value = .{ .boolean = args.deletion_protection } },
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "gateway_id", .value = .{ .string = args.gateway_id } },
            .{ .name = "labels", .value = .{ .string = labels } },
            .{ .name = "location", .value = .{ .string = location } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.apigateway.Gateway.{s}.{s}", .{ location, args.gateway_id });
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.apigateway.Gateway", args.gateway_id, &fields, .{ .protect = args.protect, .retain_on_delete = args.retain_on_delete, .operation_timeout_millis = 30 * 60 * 1000 });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .default_hostname = Outputs.DefaultHostname.fromResource(node.id),
            .state = Outputs.State.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Gateway, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const IamMemberArgs = struct {
    name: []const u8,
    resource_name: output.Output([]const u8, .public),
    api_id: []const u8 = "",
    config_id: []const u8 = "",
    location: []const u8 = "global",
    gateway_id: []const u8 = "",
    role: []const u8,
    member: []const u8,
    condition: ?iam.Condition = null,
};

pub const ApiIamMember = IamMemberResource("gcp.apigateway.ApiIamMember", .api);
pub const ApiConfigIamMember = IamMemberResource("gcp.apigateway.ApiConfigIamMember", .api_config);
pub const GatewayIamMember = IamMemberResource("gcp.apigateway.GatewayIamMember", .gateway);

const IamKind = enum { api, api_config, gateway };

fn IamMemberResource(comptime type_name: []const u8, comptime kind: IamKind) type {
    return struct {
        pub const Outputs = struct {
            pub const BindingId = output.Descriptor("binding_id", []const u8, .public);
        };
        node: resource.ResourceNode,
        binding_id: Outputs.BindingId.OutputType,

        pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: IamMemberArgs) BuildError!@This() {
            try provider.validate();
            try validateId(args.name);
            if (comptime kind != .gateway) try validateId(args.api_id);
            if (comptime kind == .api_config) try validateId(args.config_id);
            if (comptime kind == .gateway) {
                try validateId(args.location);
                try validateId(args.gateway_id);
            }
            try validateRole(args.role);
            try validateMember(args.member);
            try validateCondition(args.condition);
            const condition_title = if (args.condition) |condition| condition.title else "";
            const condition_description = if (args.condition) |condition| condition.description else "";
            const condition_expression = if (args.condition) |condition| condition.expression else "";
            const fields = [_]value.Field{
                .{ .name = "api_id", .value = .{ .string = args.api_id } },
                .{ .name = "condition_description", .value = .{ .string = condition_description } },
                .{ .name = "condition_expression", .value = .{ .string = condition_expression } },
                .{ .name = "condition_title", .value = .{ .string = condition_title } },
                .{ .name = "config_id", .value = .{ .string = args.config_id } },
                .{ .name = "gateway_id", .value = .{ .string = args.gateway_id } },
                .{ .name = "location", .value = .{ .string = args.location } },
                .{ .name = "member", .value = .{ .string = args.member } },
                .{ .name = "name", .value = .{ .string = args.name } },
                .{ .name = "ownership_mode", .value = .{ .string = "member" } },
                .{ .name = "project_id", .value = .{ .string = provider.project_id } },
                .{ .name = "resource_name", .value = try publicOutputValue(args.resource_name) },
                .{ .name = "role", .value = .{ .string = args.role } },
            };
            const id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_name, args.name });
            defer allocator.free(id);
            const node = try nodeOwned(allocator, id, type_name, args.name, &fields, .{});
            return .{ .node = node, .binding_id = Outputs.BindingId.fromResource(node.id) };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.node.deinit(allocator);
            self.* = undefined;
        }
    };
}

fn documentsValueAlloc(allocator: std.mem.Allocator, documents: []const Document) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, documents.len);
    defer allocator.free(items);
    var built: usize = 0;
    defer for (items[0..built]) |item| allocator.free(item.object);
    for (documents, 0..) |document, index| {
        if (!validDocumentPath(document.path) or !validDigest(document.sha256)) return if (!validDigest(document.sha256)) error.InvalidDigest else error.InvalidDocument;
        for (documents[0..index]) |previous| if (std.mem.eql(u8, previous.path, document.path)) return error.DuplicateDocument;
        const fields = try allocator.alloc(value.Field, 3);
        fields[0] = .{ .name = "contents", .value = try secretOutputValue(document.contents) };
        fields[1] = .{ .name = "path", .value = .{ .string = document.path } };
        fields[2] = .{ .name = "sha256", .value = .{ .string = document.sha256 } };
        items[index] = .{ .object = fields };
        built += 1;
    }
    return value.Value.initOwned(allocator, .{ .list = items });
}

fn labelsTextAlloc(allocator: std.mem.Allocator, labels: []const config_mod.Label) BuildError![]const u8 {
    const sorted = try allocator.dupe(config_mod.Label, labels);
    defer allocator.free(sorted);
    std.mem.sort(config_mod.Label, sorted, {}, struct {
        fn lessThan(_: void, left: config_mod.Label, right: config_mod.Label) bool {
            return std.mem.order(u8, left.key, right.key) == .lt;
        }
    }.lessThan);
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    for (sorted, 0..) |label, index| {
        if (!validLabel(label.key) or !validLabelValue(label.value)) return error.InvalidResourceId;
        if (index > 0 and std.mem.eql(u8, sorted[index - 1].key, label.key)) return error.DuplicateDocument;
        if (index > 0) try result.append(allocator, '\n');
        try result.appendSlice(allocator, label.key);
        try result.append(allocator, '=');
        try result.appendSlice(allocator, label.value);
    }
    return result.toOwnedSlice(allocator);
}

fn validateId(text: []const u8) BuildError!void {
    if (text.len == 0 or text.len > 63 or !std.ascii.isLower(text[0]) or !std.ascii.isAlphanumeric(text[text.len - 1])) return error.InvalidResourceId;
    for (text) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return error.InvalidResourceId;
}

fn validateDisplayName(text: []const u8) BuildError!void {
    if (text.len > 256 or std.mem.indexOfAny(u8, text, "\x00\r\n") != null) return error.InvalidDisplayName;
}

fn validDocumentPath(text: []const u8) bool {
    return text.len > 0 and text.len <= 256 and text[0] != '/' and std.mem.indexOfAny(u8, text, "\x00\r\n\\") == null and std.mem.indexOf(u8, text, "..") == null;
}

fn validDigest(text: []const u8) bool {
    if (text.len != 64) return false;
    for (text) |character| if (!std.ascii.isHex(character)) return false;
    return true;
}

fn validLabel(text: []const u8) bool {
    if (text.len == 0 or text.len > 63 or !std.ascii.isLower(text[0])) return false;
    for (text) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '_' and character != '-') return false;
    return true;
}

fn validLabelValue(text: []const u8) bool {
    if (text.len > 63) return false;
    for (text) |character| if (!std.ascii.isAlphanumeric(character) and character != '_' and character != '-') return false;
    return true;
}

fn validateRole(role: []const u8) BuildError!void {
    if ((!std.mem.startsWith(u8, role, "roles/") and std.mem.indexOf(u8, role, "/roles/") == null) or std.mem.indexOfAny(u8, role, "\x00\r\n ") != null) return error.InvalidRole;
}

fn validateMember(member: []const u8) BuildError!void {
    if (std.mem.eql(u8, member, "allUsers") or std.mem.eql(u8, member, "allAuthenticatedUsers")) return;
    for ([_][]const u8{ "user:", "serviceAccount:", "group:", "domain:", "principal:", "principalSet:" }) |prefix| if (std.mem.startsWith(u8, member, prefix) and member.len > prefix.len) return;
    return error.InvalidMember;
}

fn validateCondition(condition: ?iam.Condition) BuildError!void {
    const present = condition orelse return;
    if (present.title.len == 0 or present.expression.len == 0 or std.mem.indexOfAny(u8, present.title, "\x00\r\n") != null or std.mem.indexOfAny(u8, present.expression, "\x00\r\n") != null) return error.InvalidCondition;
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

fn nodeOwned(allocator: std.mem.Allocator, id: []const u8, type_name: []const u8, logical_id: []const u8, fields: []const value.Field, lifecycle: resource.Lifecycle) BuildError!resource.ResourceNode {
    return resource.ResourceNode.initOwned(allocator, .{ .id = id, .provider = .gcp, .type_name = type_name, .logical_id = logical_id, .inputs = .{ .object = fields }, .lifecycle = lifecycle });
}
