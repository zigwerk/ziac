const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || resource.ResourceGraphError || std.mem.Allocator.Error || error{
    DuplicateLabel,
    InvalidDigest,
    InvalidKmsKey,
    InvalidLabel,
    InvalidLocation,
    InvalidResourceId,
    InvalidResourceName,
    OutputNotKnown,
};

pub const Format = enum {
    unspecified,
    unformatted,
    yaml,
    json,

    pub fn apiName(self: Format) []const u8 {
        return switch (self) {
            .unspecified => "PARAMETER_FORMAT_UNSPECIFIED",
            .unformatted => "UNFORMATTED",
            .yaml => "YAML",
            .json => "JSON",
        };
    }
};

pub const ParameterArgs = struct {
    parameter_id: []const u8,
    location: []const u8 = "global",
    format: Format = .unformatted,
    kms_key: ?output.Output([]const u8, .public) = null,
    labels: []const config_mod.Label = &.{},
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const Parameter = ResourceType("gcp.parametermanager.Parameter", ParameterArgs, .parameter);

pub const TemplateArgs = struct {
    template_id: []const u8,
    location: []const u8 = "global",
    format: Format = .unformatted,
    labels: []const config_mod.Label = &.{},
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const Template = ResourceType("gcp.parametermanager.Template", TemplateArgs, .template);

const ResourceKind = enum { parameter, template };

fn ResourceType(comptime type_name: []const u8, comptime Args: type, comptime kind: ResourceKind) type {
    return struct {
        pub const Outputs = struct {
            pub const Name = output.Descriptor("name", []const u8, .public);
            pub const Etag = output.Descriptor("etag", []const u8, .public);
        };
        node: resource.ResourceNode,
        name: Outputs.Name.OutputType,
        etag: Outputs.Etag.OutputType,

        pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: Args) BuildError!@This() {
            try provider.validate();
            const resource_id = if (comptime kind == .parameter) args.parameter_id else args.template_id;
            try validateId(resource_id);
            try validateLocation(args.location);
            const labels = try labelsTextAlloc(allocator, args.labels);
            defer allocator.free(labels);
            const kms_key = if (comptime kind == .parameter)
                if (args.kms_key) |candidate| try publicOutputValue(candidate) else value.Value{ .string = "" }
            else
                value.Value{ .string = "" };
            if (kms_key == .string and kms_key.string.len > 0 and !validKms(kms_key.string, provider.project_id)) return error.InvalidKmsKey;
            const fields = [_]value.Field{
                .{ .name = "format", .value = .{ .string = args.format.apiName() } },
                .{ .name = "kms_key", .value = kms_key },
                .{ .name = "labels", .value = .{ .string = labels } },
                .{ .name = "location", .value = .{ .string = args.location } },
                .{ .name = "project_id", .value = .{ .string = provider.project_id } },
                .{ .name = "resource_id", .value = .{ .string = resource_id } },
            };
            const id = try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ type_name, args.location, resource_id });
            defer allocator.free(id);
            const node = try nodeOwned(allocator, id, type_name, resource_id, &fields, .{ .protect = args.protect, .retain_on_delete = args.retain_on_delete });
            return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .etag = Outputs.Etag.fromResource(node.id) };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.node.deinit(allocator);
            self.* = undefined;
        }
    };
}

pub const ParameterVersionArgs = struct {
    parameter: output.Output([]const u8, .public),
    parameter_id: []const u8,
    version_id: []const u8,
    location: []const u8 = "global",
    payload: output.Output(value.SecretReference, .secret),
    payload_sha256: []const u8,
    disabled: bool = false,
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const ParameterVersion = VersionType("gcp.parametermanager.ParameterVersion", ParameterVersionArgs, .parameter);

pub const TemplateVersionArgs = struct {
    template: output.Output([]const u8, .public),
    template_id: []const u8,
    version_id: []const u8,
    location: []const u8 = "global",
    payload: output.Output(value.SecretReference, .secret),
    payload_sha256: []const u8,
    disabled: bool = false,
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const TemplateVersion = VersionType("gcp.parametermanager.TemplateVersion", TemplateVersionArgs, .template);

fn VersionType(comptime type_name: []const u8, comptime Args: type, comptime kind: ResourceKind) type {
    return struct {
        pub const Outputs = struct {
            pub const Name = output.Descriptor("name", []const u8, .public);
            pub const Etag = output.Descriptor("etag", []const u8, .public);
            pub const State = output.Descriptor("state", []const u8, .public);
        };
        node: resource.ResourceNode,
        name: Outputs.Name.OutputType,
        etag: Outputs.Etag.OutputType,
        state: Outputs.State.OutputType,

        pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: Args) BuildError!@This() {
            try provider.validate();
            const parent_id = if (comptime kind == .parameter) args.parameter_id else args.template_id;
            const parent = if (comptime kind == .parameter) args.parameter else args.template;
            try validateId(parent_id);
            try validateId(args.version_id);
            try validateLocation(args.location);
            if (!validDigest(args.payload_sha256)) return error.InvalidDigest;
            const fields = [_]value.Field{
                .{ .name = "disabled", .value = .{ .boolean = args.disabled } },
                .{ .name = "location", .value = .{ .string = args.location } },
                .{ .name = "parent", .value = try publicOutputValue(parent) },
                .{ .name = "parent_id", .value = .{ .string = parent_id } },
                .{ .name = "payload", .value = try secretOutputValue(args.payload) },
                .{ .name = "payload_sha256", .value = .{ .string = args.payload_sha256 } },
                .{ .name = "project_id", .value = .{ .string = provider.project_id } },
                .{ .name = "version_id", .value = .{ .string = args.version_id } },
            };
            const id = try std.fmt.allocPrint(allocator, "{s}.{s}.{s}.{s}", .{ type_name, args.location, parent_id, args.version_id });
            defer allocator.free(id);
            const node = try nodeOwned(allocator, id, type_name, args.version_id, &fields, .{ .protect = args.protect, .retain_on_delete = args.retain_on_delete });
            return .{
                .node = node,
                .name = Outputs.Name.fromResource(node.id),
                .etag = Outputs.Etag.fromResource(node.id),
                .state = Outputs.State.fromResource(node.id),
            };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.node.deinit(allocator);
            self.* = undefined;
        }
    };
}

fn validateId(text: []const u8) BuildError!void {
    if (text.len == 0 or text.len > 63 or !std.ascii.isLower(text[0]) or !std.ascii.isAlphanumeric(text[text.len - 1])) return error.InvalidResourceId;
    for (text) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-' and character != '_') return error.InvalidResourceId;
}

fn validateLocation(text: []const u8) BuildError!void {
    if (text.len == 0 or text.len > 63 or std.mem.indexOfAny(u8, text, "\x00\r\n /?") != null) return error.InvalidLocation;
}

fn validDigest(text: []const u8) bool {
    if (text.len != 64) return false;
    for (text) |character| if (!std.ascii.isHex(character)) return false;
    return true;
}

fn validKms(text: []const u8, project_id: []const u8) bool {
    return std.mem.startsWith(u8, text, "projects/") and std.mem.indexOf(u8, text, project_id) != null and std.mem.indexOf(u8, text, "/locations/") != null and std.mem.indexOf(u8, text, "/keyRings/") != null and std.mem.indexOf(u8, text, "/cryptoKeys/") != null and std.mem.indexOfAny(u8, text, "\x00\r\n ?") == null;
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
        if (!validLabel(label.key) or !validLabelValue(label.value)) return error.InvalidLabel;
        if (index > 0 and std.mem.eql(u8, sorted[index - 1].key, label.key)) return error.DuplicateLabel;
        if (index > 0) try result.append(allocator, '\n');
        try result.appendSlice(allocator, label.key);
        try result.append(allocator, '=');
        try result.appendSlice(allocator, label.value);
    }
    return result.toOwnedSlice(allocator);
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
