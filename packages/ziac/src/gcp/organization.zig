const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    DuplicateLabel,
    DuplicateRestriction,
    InvalidBillingAccount,
    InvalidName,
    InvalidOrigin,
    InvalidParent,
    InvalidProjectId,
    InvalidReason,
    InvalidRestriction,
    InvalidService,
    OutputNotKnown,
};

pub const RemovalPolicy = enum { retain, delete };
pub const BillingRemovalPolicy = enum { retain, detach };

pub const FolderArgs = struct {
    name: []const u8,
    parent: output.Output([]const u8, .public),
    display_name: []const u8,
    request_delete: bool = false,
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const Folder = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const FolderId = output.Descriptor("folder_id", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    folder_id: Outputs.FolderId.OutputType,
    state: Outputs.State.OutputType,
    etag: Outputs.Etag.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: FolderArgs) BuildError!Folder {
        try provider.validate();
        try validateLogicalName(args.name);
        if (!validFolderDisplayName(args.display_name)) return error.InvalidName;
        try validateParentOutput(args.parent, .folder);
        const fields = [_]value.Field{
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "parent", .value = try outputValue(args.parent) },
            .{ .name = "request_delete", .value = .{ .boolean = args.request_delete } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.resourcemanager.Folder.{s}", .{args.name});
        defer allocator.free(id);
        const node = try initNode(allocator, id, "gcp.resourcemanager.Folder", args.name, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
            .operation_timeout_millis = 30 * 60 * 1000,
        });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .folder_id = Outputs.FolderId.fromResource(node.id),
            .state = Outputs.State.fromResource(node.id),
            .etag = Outputs.Etag.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Folder, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const ProjectArgs = struct {
    project_id: []const u8,
    parent: output.Output([]const u8, .public),
    display_name: []const u8 = "",
    labels: []const config_mod.Label = &.{},
    request_delete: bool = false,
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const Project = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const ProjectId = output.Descriptor("project_id", []const u8, .public);
        pub const ProjectNumber = output.Descriptor("project_number", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    project_id: Outputs.ProjectId.OutputType,
    project_number: Outputs.ProjectNumber.OutputType,
    state: Outputs.State.OutputType,
    etag: Outputs.Etag.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ProjectArgs) BuildError!Project {
        try provider.validate();
        if (!validProjectId(args.project_id)) return error.InvalidProjectId;
        if (!validProjectDisplayName(args.display_name)) return error.InvalidName;
        try validateParentOutput(args.parent, .project);
        var labels = try labelsValueOwned(allocator, args.labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "labels", .value = labels },
            .{ .name = "parent", .value = try outputValue(args.parent) },
            .{ .name = "project_id", .value = .{ .string = args.project_id } },
            .{ .name = "request_delete", .value = .{ .boolean = args.request_delete } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.resourcemanager.Project.{s}", .{args.project_id});
        defer allocator.free(id);
        const node = try initNode(allocator, id, "gcp.resourcemanager.Project", args.project_id, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
            .operation_timeout_millis = 30 * 60 * 1000,
        });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .project_id = Outputs.ProjectId.fromResource(node.id),
            .project_number = Outputs.ProjectNumber.fromResource(node.id),
            .state = Outputs.State.fromResource(node.id),
            .etag = Outputs.Etag.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Project, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const LienArgs = struct {
    name: []const u8,
    parent: output.Output([]const u8, .public),
    reason: []const u8,
    origin: []const u8,
    restrictions: []const []const u8,
    removal_policy: RemovalPolicy = .retain,
    protect: bool = true,
};

pub const Lien = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const CreateTime = output.Descriptor("create_time", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    create_time: Outputs.CreateTime.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: LienArgs) BuildError!Lien {
        try provider.validate();
        try validateLogicalName(args.name);
        try validateProjectOutput(args.parent);
        if (args.reason.len == 0 or args.reason.len > 200) return error.InvalidReason;
        if (args.origin.len == 0 or args.origin.len > 200) return error.InvalidOrigin;
        if (args.restrictions.len == 0) return error.InvalidRestriction;
        for (args.restrictions, 0..) |restriction, index| {
            if (restriction.len == 0 or std.mem.indexOfScalar(u8, restriction, ' ') != null) return error.InvalidRestriction;
            for (args.restrictions[index + 1 ..]) |other| if (std.mem.eql(u8, restriction, other)) return error.DuplicateRestriction;
        }
        const restriction_values = try stringValuesOwned(allocator, args.restrictions);
        defer deinitValues(allocator, restriction_values);
        const fields = [_]value.Field{
            .{ .name = "origin", .value = .{ .string = args.origin } },
            .{ .name = "parent", .value = try outputValue(args.parent) },
            .{ .name = "reason", .value = .{ .string = args.reason } },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
            .{ .name = "restrictions", .value = .{ .list = restriction_values } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.resourcemanager.Lien.{s}", .{args.name});
        defer allocator.free(id);
        const node = try initNode(allocator, id, "gcp.resourcemanager.Lien", args.name, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.removal_policy == .retain,
        });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .create_time = Outputs.CreateTime.fromResource(node.id) };
    }

    pub fn deinit(self: *Lien, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const ProjectBillingAssociationArgs = struct {
    name: []const u8 = "project",
    project: output.Output([]const u8, .public),
    billing_account: []const u8,
    removal_policy: BillingRemovalPolicy = .retain,
};

pub const ProjectBillingAssociation = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const BillingAccount = output.Descriptor("billing_account", []const u8, .public);
        pub const BillingEnabled = output.Descriptor("billing_enabled", bool, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    billing_account: Outputs.BillingAccount.OutputType,
    billing_enabled: Outputs.BillingEnabled.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ProjectBillingAssociationArgs) BuildError!ProjectBillingAssociation {
        try provider.validate();
        try validateLogicalName(args.name);
        try validateProjectOutput(args.project);
        if (!validBillingAccount(args.billing_account)) return error.InvalidBillingAccount;
        const fields = [_]value.Field{
            .{ .name = "billing_account", .value = .{ .string = args.billing_account } },
            .{ .name = "project", .value = try outputValue(args.project) },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.billing.ProjectBillingAssociation.{s}", .{args.name});
        defer allocator.free(id);
        const node = try initNode(allocator, id, "gcp.billing.ProjectBillingAssociation", args.name, &fields, .{ .retain_on_delete = args.removal_policy == .retain });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .billing_account = Outputs.BillingAccount.fromResource(node.id),
            .billing_enabled = Outputs.BillingEnabled.fromResource(node.id),
        };
    }

    pub fn deinit(self: *ProjectBillingAssociation, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const ServiceIdentityArgs = struct {
    name: ?[]const u8 = null,
    project_number: output.Output([]const u8, .public),
    service: []const u8,
};

pub const ServiceIdentity = struct {
    pub const Outputs = struct {
        pub const Email = output.Descriptor("email", []const u8, .public);
        pub const UniqueId = output.Descriptor("unique_id", []const u8, .public);
    };

    node: resource.ResourceNode,
    email: Outputs.Email.OutputType,
    unique_id: Outputs.UniqueId.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ServiceIdentityArgs) BuildError!ServiceIdentity {
        try provider.validate();
        try validateProjectNumberOutput(args.project_number);
        if (!validService(args.service)) return error.InvalidService;
        const logical_name = args.name orelse args.service;
        if (logical_name.len == 0) return error.InvalidName;
        const fields = [_]value.Field{
            .{ .name = "project_number", .value = try outputValue(args.project_number) },
            .{ .name = "service", .value = .{ .string = args.service } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.serviceusage.ServiceIdentity.{s}", .{logical_name});
        defer allocator.free(id);
        const node = try initNode(allocator, id, "gcp.serviceusage.ServiceIdentity", logical_name, &fields, .{ .retain_on_delete = true });
        return .{ .node = node, .email = Outputs.Email.fromResource(node.id), .unique_id = Outputs.UniqueId.fromResource(node.id) };
    }

    pub fn deinit(self: *ServiceIdentity, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

const ParentKind = enum { folder, project };

fn initNode(allocator: std.mem.Allocator, id: []const u8, type_name: []const u8, logical_id: []const u8, fields: []const value.Field, lifecycle: resource.Lifecycle) BuildError!resource.ResourceNode {
    return resource.ResourceNode.initOwned(allocator, .{
        .id = id,
        .provider = .gcp,
        .type_name = type_name,
        .schema_version = 1,
        .logical_id = logical_id,
        .inputs = .{ .object = fields },
        .lifecycle = lifecycle,
    }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
    };
}

fn outputValue(selected: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (selected) {
        .value => |known| .{ .string = known },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn validateParentOutput(parent: output.Output([]const u8, .public), kind: ParentKind) BuildError!void {
    switch (parent) {
        .value => |known| {
            const valid = switch (kind) {
                .folder => canonicalNumericName(known, "organizations/") or canonicalNumericName(known, "folders/"),
                .project => canonicalNumericName(known, "organizations/") or canonicalNumericName(known, "folders/"),
            };
            if (!valid) return error.InvalidParent;
        },
        .resource_ref => {},
        .unknown_reason => return error.OutputNotKnown,
    }
}

fn validateProjectOutput(project: output.Output([]const u8, .public)) BuildError!void {
    switch (project) {
        .value => |known| if (!canonicalProjectName(known)) return error.InvalidParent,
        .resource_ref => {},
        .unknown_reason => return error.OutputNotKnown,
    }
}

fn validateProjectNumberOutput(project: output.Output([]const u8, .public)) BuildError!void {
    switch (project) {
        .value => |known| if (!allDigits(known) and !canonicalNumericName(known, "projects/")) return error.InvalidParent,
        .resource_ref => {},
        .unknown_reason => return error.OutputNotKnown,
    }
}

fn validateLogicalName(name: []const u8) BuildError!void {
    if (name.len == 0 or name.len > 63) return error.InvalidName;
    for (name) |char| if (!std.ascii.isAlphanumeric(char) and char != '-' and char != '_') return error.InvalidName;
}

fn validProjectId(candidate: []const u8) bool {
    if (candidate.len < 6 or candidate.len > 30 or !std.ascii.isLower(candidate[0]) or !std.ascii.isAlphanumeric(candidate[candidate.len - 1])) return false;
    for (candidate) |char| if (!std.ascii.isLower(char) and !std.ascii.isDigit(char) and char != '-') return false;
    return !std.mem.startsWith(u8, candidate, "goog");
}

fn validFolderDisplayName(candidate: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(candidate)) return false;
    var codepoints: usize = 0;
    var last_start: usize = 0;
    for (candidate, 0..) |char, index| {
        if ((char & 0xc0) == 0x80) continue;
        codepoints += 1;
        last_start = index;
        if (char < 0x80 and !std.ascii.isAlphanumeric(char) and char != ' ' and char != '-' and char != '_') return false;
    }
    if (codepoints < 3 or codepoints > 30) return false;
    return (candidate[0] >= 0x80 or std.ascii.isAlphanumeric(candidate[0])) and
        (candidate[last_start] >= 0x80 or std.ascii.isAlphanumeric(candidate[last_start]));
}

fn validProjectDisplayName(candidate: []const u8) bool {
    if (candidate.len == 0) return true;
    if (candidate.len < 4 or candidate.len > 30) return false;
    for (candidate) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '-' and char != '\'' and char != '"' and char != ' ' and char != '!') return false;
    }
    return true;
}

fn validBillingAccount(candidate: []const u8) bool {
    if (!std.mem.startsWith(u8, candidate, "billingAccounts/")) return false;
    const suffix = candidate["billingAccounts/".len..];
    if (suffix.len != 20 or suffix[6] != '-' or suffix[13] != '-') return false;
    for (suffix, 0..) |char, index| if (index != 6 and index != 13 and !std.ascii.isAlphanumeric(char)) return false;
    return true;
}

fn validService(candidate: []const u8) bool {
    if (!std.mem.endsWith(u8, candidate, ".googleapis.com") or candidate.len <= ".googleapis.com".len) return false;
    for (candidate) |char| if (!std.ascii.isLower(char) and !std.ascii.isDigit(char) and char != '.' and char != '-') return false;
    return true;
}

fn canonicalProjectName(candidate: []const u8) bool {
    if (!std.mem.startsWith(u8, candidate, "projects/")) return false;
    const suffix = candidate["projects/".len..];
    return allDigits(suffix) or validProjectId(suffix);
}

fn canonicalNumericName(candidate: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, candidate, prefix) and allDigits(candidate[prefix.len..]);
}

fn allDigits(candidate: []const u8) bool {
    if (candidate.len == 0) return false;
    for (candidate) |char| if (!std.ascii.isDigit(char)) return false;
    return true;
}

fn labelsValueOwned(allocator: std.mem.Allocator, labels: []const config_mod.Label) BuildError!value.Value {
    if (labels.len > 64) return error.InvalidName;
    const sorted = try allocator.dupe(config_mod.Label, labels);
    defer allocator.free(sorted);
    std.mem.sort(config_mod.Label, sorted, {}, struct {
        fn lessThan(_: void, left: config_mod.Label, right: config_mod.Label) bool {
            return std.mem.lessThan(u8, left.key, right.key);
        }
    }.lessThan);
    const fields = try allocator.alloc(value.Field, sorted.len);
    defer allocator.free(fields);
    for (sorted, 0..) |label, index| {
        if (!validProjectLabelPart(label.key, false) or !validProjectLabelPart(label.value, true)) return error.InvalidName;
        if (index != 0 and std.mem.eql(u8, sorted[index - 1].key, label.key)) return error.DuplicateLabel;
        fields[index] = .{ .name = label.key, .value = .{ .string = label.value } };
    }
    return value.Value.initOwned(allocator, .{ .object = fields }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateLabel,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn validProjectLabelPart(candidate: []const u8, allow_empty: bool) bool {
    if (candidate.len == 0) return allow_empty;
    if (candidate.len > 63 or !std.ascii.isLower(candidate[0]) or !std.ascii.isAlphanumeric(candidate[candidate.len - 1])) return false;
    for (candidate) |char| if (!std.ascii.isLower(char) and !std.ascii.isDigit(char) and char != '-') return false;
    return true;
}

fn stringValuesOwned(allocator: std.mem.Allocator, items: []const []const u8) BuildError![]value.Value {
    const values = try allocator.alloc(value.Value, items.len);
    errdefer allocator.free(values);
    for (items, 0..) |item, index| values[index] = try value.Value.initOwned(allocator, .{ .string = item });
    return values;
}

fn deinitValues(allocator: std.mem.Allocator, values: []value.Value) void {
    for (values) |*item| item.deinit(allocator);
    allocator.free(values);
}
