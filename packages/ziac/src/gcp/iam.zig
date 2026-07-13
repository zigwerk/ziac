const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const validation = @import("validation.zig");
const value = @import("../value.zig");

pub const BuildError = validation.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    DuplicateBinding,
    DuplicateMember,
    DuplicatePermission,
    InvalidAccountId,
    InvalidAttributeMapping,
    InvalidCustomRole,
    InvalidIamCondition,
    InvalidIssuer,
    InvalidRole,
    InvalidMember,
    InvalidPoolId,
    InvalidProviderId,
    InvalidResourceName,
    MissingSubjectMapping,
    OutputNotKnown,
};

pub const Condition = struct {
    title: []const u8,
    description: []const u8 = "",
    expression: []const u8,
};

pub const Binding = struct {
    role: []const u8,
    members: []const []const u8,
    condition: ?Condition = null,
};

const OwnershipMode = enum {
    member,
    binding,
    policy,

    fn apiName(self: OwnershipMode) []const u8 {
        return @tagName(self);
    }
};

const PolicyScope = enum {
    project,
    folder,
    organization,
    service_account,
};

pub const ServiceAccountArgs = struct {
    account_id: []const u8,
    display_name: []const u8 = "",
    description: []const u8 = "",
};

pub const ServiceAccount = struct {
    pub const Outputs = struct {
        pub const Email = output.Descriptor("email", []const u8, .public);
        pub const UniqueId = output.Descriptor("unique_id", []const u8, .public);

        pub fn field(comptime name: []const u8) type {
            if (std.mem.eql(u8, name, "email")) return Email;
            if (std.mem.eql(u8, name, "unique_id")) return UniqueId;
            @compileError("ZIAC120 unknown gcp.iam.ServiceAccount output field: " ++ name);
        }
    };

    node: resource.ResourceNode,
    email: Outputs.Email.OutputType,
    unique_id: Outputs.UniqueId.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: ServiceAccountArgs,
    ) BuildError!ServiceAccount {
        try provider.validate();
        if (!validAccountId(args.account_id)) return error.InvalidAccountId;
        const id = try std.fmt.allocPrint(allocator, "gcp.iam.ServiceAccount.{s}", .{args.account_id});
        defer allocator.free(id);
        const fields = [_]value.Field{
            .{ .name = "account_id", .value = .{ .string = args.account_id } },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        };
        const node = resource.ResourceNode.initOwned(allocator, .{
            .id = id,
            .provider = .gcp,
            .type_name = "gcp.iam.ServiceAccount",
            .schema_version = 1,
            .logical_id = args.account_id,
            .inputs = .{ .object = &fields },
        }) catch |err| switch (err) {
            error.DuplicateField => return error.DuplicateField,
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
        };
        return .{
            .node = node,
            .email = Outputs.Email.fromResource(node.id),
            .unique_id = Outputs.UniqueId.fromResource(node.id),
        };
    }

    pub fn deinit(self: *ServiceAccount, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const ProjectMemberArgs = struct {
    name: []const u8,
    role: []const u8,
    member: []const u8,
    condition: ?Condition = null,
};

pub const ProjectBindingArgs = struct {
    name: []const u8,
    role: []const u8,
    members: []const []const u8,
    condition: ?Condition = null,
};

pub const ProjectPolicyArgs = struct {
    name: []const u8,
    bindings: []const Binding,
};

pub const FolderMemberArgs = struct {
    name: []const u8,
    folder_id: []const u8,
    role: []const u8,
    member: []const u8,
    condition: ?Condition = null,
};

pub const FolderBindingArgs = struct {
    name: []const u8,
    folder_id: []const u8,
    role: []const u8,
    members: []const []const u8,
    condition: ?Condition = null,
};

pub const FolderPolicyArgs = struct {
    name: []const u8,
    folder_id: []const u8,
    bindings: []const Binding,
};

pub const OrganizationMemberArgs = struct {
    name: []const u8,
    organization_id: []const u8,
    role: []const u8,
    member: []const u8,
    condition: ?Condition = null,
};

pub const OrganizationBindingArgs = struct {
    name: []const u8,
    organization_id: []const u8,
    role: []const u8,
    members: []const []const u8,
    condition: ?Condition = null,
};

pub const OrganizationPolicyArgs = struct {
    name: []const u8,
    organization_id: []const u8,
    bindings: []const Binding,
};

pub const ServiceAccountIamMemberArgs = struct {
    name: []const u8,
    service_account_email: []const u8,
    role: []const u8,
    member: []const u8,
    condition: ?Condition = null,
};

pub const ServiceAccountIamBindingArgs = struct {
    name: []const u8,
    service_account_email: []const u8,
    role: []const u8,
    members: []const []const u8,
    condition: ?Condition = null,
};

pub const ProjectMember = MemberResource("gcp.iam.ProjectMember", ProjectMemberArgs, .project);
pub const ProjectBinding = BindingResource("gcp.iam.ProjectBinding", ProjectBindingArgs, .project);
pub const ProjectPolicy = PolicyResource("gcp.iam.ProjectPolicy", ProjectPolicyArgs, .project);
pub const FolderMember = MemberResource("gcp.iam.FolderMember", FolderMemberArgs, .folder);
pub const FolderBinding = BindingResource("gcp.iam.FolderBinding", FolderBindingArgs, .folder);
pub const FolderPolicy = PolicyResource("gcp.iam.FolderPolicy", FolderPolicyArgs, .folder);
pub const OrganizationMember = MemberResource("gcp.iam.OrganizationMember", OrganizationMemberArgs, .organization);
pub const OrganizationBinding = BindingResource("gcp.iam.OrganizationBinding", OrganizationBindingArgs, .organization);
pub const OrganizationPolicy = PolicyResource("gcp.iam.OrganizationPolicy", OrganizationPolicyArgs, .organization);
pub const ServiceAccountIamMember = MemberResource("gcp.iam.ServiceAccountIamMember", ServiceAccountIamMemberArgs, .service_account);
pub const ServiceAccountIamBinding = BindingResource("gcp.iam.ServiceAccountIamBinding", ServiceAccountIamBindingArgs, .service_account);

pub const OwnershipError = error{IamOwnershipConflict};

pub fn validateGraphOwnership(graph: *const resource.ResourceGraph) OwnershipError!void {
    for (graph.resources.items, 0..) |left, left_index| {
        const left_mode = iamInputString(left.inputs, "ownership_mode") orelse continue;
        const left_target = iamInputString(left.inputs, "resource_name") orelse continue;
        for (graph.resources.items[left_index + 1 ..]) |right| {
            const right_mode = iamInputString(right.inputs, "ownership_mode") orelse continue;
            const right_target = iamInputString(right.inputs, "resource_name") orelse continue;
            if (!std.mem.eql(u8, left_target, right_target)) continue;
            if (std.mem.eql(u8, left_mode, "policy") or std.mem.eql(u8, right_mode, "policy")) {
                return error.IamOwnershipConflict;
            }
            if (!sameIamBindingIdentity(left.inputs, right.inputs)) continue;
            if (std.mem.eql(u8, left_mode, "binding") or std.mem.eql(u8, right_mode, "binding")) {
                return error.IamOwnershipConflict;
            }
            const left_member = iamInputString(left.inputs, "member") orelse continue;
            const right_member = iamInputString(right.inputs, "member") orelse continue;
            if (std.mem.eql(u8, left_member, right_member)) return error.IamOwnershipConflict;
        }
    }
}

fn sameIamBindingIdentity(left: value.Value, right: value.Value) bool {
    const fields = [_][]const u8{ "role", "condition_title", "condition_description", "condition_expression" };
    for (fields) |field| {
        const left_value = iamInputString(left, field) orelse "";
        const right_value = iamInputString(right, field) orelse "";
        if (!std.mem.eql(u8, left_value, right_value)) return false;
    }
    return true;
}

fn iamInputString(input: value.Value, name: []const u8) ?[]const u8 {
    const fields = switch (input) {
        .object => |items| items,
        else => return null,
    };
    for (fields) |field| {
        if (!std.mem.eql(u8, field.name, name)) continue;
        return switch (field.value) {
            .string => |text| text,
            else => null,
        };
    }
    return null;
}

pub const RoleStage = enum {
    alpha,
    beta,
    ga,
    deprecated,
    disabled,
    eap,

    pub fn apiName(self: RoleStage) []const u8 {
        return switch (self) {
            .alpha => "ALPHA",
            .beta => "BETA",
            .ga => "GA",
            .deprecated => "DEPRECATED",
            .disabled => "DISABLED",
            .eap => "EAP",
        };
    }
};

pub const ProjectCustomRoleArgs = struct {
    role_id: []const u8,
    title: []const u8,
    description: []const u8 = "",
    included_permissions: []const []const u8,
    stage: RoleStage = .ga,
    retain_on_delete: bool = false,
};

pub const OrganizationCustomRoleArgs = struct {
    role_id: []const u8,
    organization_id: []const u8,
    title: []const u8,
    description: []const u8 = "",
    included_permissions: []const []const u8,
    stage: RoleStage = .ga,
    retain_on_delete: bool = false,
};

pub const ProjectCustomRole = CustomRoleResource("gcp.iam.ProjectCustomRole", ProjectCustomRoleArgs, .project);
pub const OrganizationCustomRole = CustomRoleResource("gcp.iam.OrganizationCustomRole", OrganizationCustomRoleArgs, .organization);

pub const WorkloadIdentityPoolArgs = struct {
    project_number: []const u8,
    pool_id: []const u8,
    display_name: []const u8,
    description: []const u8 = "",
    disabled: bool = false,
    retain_on_delete: bool = false,
};

pub const WorkloadIdentityPool = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    state: Outputs.State.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: WorkloadIdentityPoolArgs,
    ) BuildError!WorkloadIdentityPool {
        try provider.validate();
        if (!validNumericId(args.project_number)) return error.InvalidResourceName;
        if (!validFederationId(args.pool_id) or std.mem.startsWith(u8, args.pool_id, "gcp-")) return error.InvalidPoolId;
        if (!validBoundedText(args.display_name, 32) or (args.description.len > 0 and !validBoundedText(args.description, 256))) {
            return error.InvalidPoolId;
        }
        const resource_name = try std.fmt.allocPrint(
            allocator,
            "projects/{s}/locations/global/workloadIdentityPools/{s}",
            .{ args.project_number, args.pool_id },
        );
        defer allocator.free(resource_name);
        const fields = [_]value.Field{
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "disabled", .value = .{ .boolean = args.disabled } },
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "pool_id", .value = .{ .string = args.pool_id } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "project_number", .value = .{ .string = args.project_number } },
            .{ .name = "resource_name", .value = .{ .string = resource_name } },
        };
        const node = try initManagedIamNode(
            allocator,
            "gcp.iam.WorkloadIdentityPool",
            args.pool_id,
            &fields,
            args.retain_on_delete,
        );
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .state = Outputs.State.fromResource(node.id),
        };
    }

    pub fn deinit(self: *WorkloadIdentityPool, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const AttributeMapping = struct {
    key: []const u8,
    expression: []const u8,
};

pub const WorkloadIdentityPoolProviderArgs = struct {
    provider_id: []const u8,
    pool: output.Output([]const u8, .public),
    display_name: []const u8 = "",
    description: []const u8 = "",
    disabled: bool = false,
    issuer_uri: []const u8,
    allowed_audiences: []const []const u8 = &.{},
    attribute_mapping: []const AttributeMapping,
    attribute_condition: []const u8 = "",
    retain_on_delete: bool = false,
};

pub const WorkloadIdentityPoolProvider = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    state: Outputs.State.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: WorkloadIdentityPoolProviderArgs,
    ) BuildError!WorkloadIdentityPoolProvider {
        try provider.validate();
        if (!validFederationId(args.provider_id) or std.mem.startsWith(u8, args.provider_id, "gcp-")) return error.InvalidProviderId;
        if (!std.mem.startsWith(u8, args.issuer_uri, "https://") or args.issuer_uri.len <= "https://".len) return error.InvalidIssuer;
        if ((args.display_name.len > 0 and !validBoundedText(args.display_name, 32)) or
            (args.description.len > 0 and !validBoundedText(args.description, 256)) or
            (args.attribute_condition.len > 4096 or (args.attribute_condition.len > 0 and !validIamText(args.attribute_condition))))
        {
            return error.InvalidAttributeMapping;
        }
        if (args.allowed_audiences.len > 10) return error.InvalidAttributeMapping;
        for (args.allowed_audiences) |audience| if (!validBoundedText(audience, 256)) return error.InvalidAttributeMapping;
        const mapping_json = try canonicalAttributeMappingJsonAlloc(allocator, args.attribute_mapping);
        defer allocator.free(mapping_json);
        const audiences = try canonicalStringListValueAlloc(allocator, args.allowed_audiences, error.InvalidAttributeMapping);
        defer allocator.free(audiences.list);
        const pool_value = try publicOutputValue(args.pool);
        const fields = [_]value.Field{
            .{ .name = "allowed_audiences", .value = audiences },
            .{ .name = "attribute_condition", .value = .{ .string = args.attribute_condition } },
            .{ .name = "attribute_mapping_json", .value = .{ .string = mapping_json } },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "disabled", .value = .{ .boolean = args.disabled } },
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "issuer_uri", .value = .{ .string = args.issuer_uri } },
            .{ .name = "pool", .value = pool_value },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "provider_id", .value = .{ .string = args.provider_id } },
        };
        const node = try initManagedIamNode(
            allocator,
            "gcp.iam.WorkloadIdentityPoolProvider",
            args.provider_id,
            &fields,
            args.retain_on_delete,
        );
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .state = Outputs.State.fromResource(node.id),
        };
    }

    pub fn deinit(self: *WorkloadIdentityPoolProvider, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn CustomRoleResource(comptime type_name: []const u8, comptime Args: type, comptime scope: PolicyScope) type {
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
            if (!validCustomRoleId(args.role_id) or !validBoundedText(args.title, 100) or
                (args.description.len > 0 and !validBoundedText(args.description, 256)))
            {
                return error.InvalidCustomRole;
            }
            const permissions = try canonicalPermissionsValueAlloc(allocator, args.included_permissions);
            defer allocator.free(permissions.list);
            const parent = switch (scope) {
                .project => try std.fmt.allocPrint(allocator, "projects/{s}", .{provider.project_id}),
                .organization => blk: {
                    if (!validNumericId(args.organization_id)) return error.InvalidResourceName;
                    break :blk try std.fmt.allocPrint(allocator, "organizations/{s}", .{args.organization_id});
                },
                else => unreachable,
            };
            defer allocator.free(parent);
            const resource_name = try std.fmt.allocPrint(allocator, "{s}/roles/{s}", .{ parent, args.role_id });
            defer allocator.free(resource_name);
            const fields = [_]value.Field{
                .{ .name = "description", .value = .{ .string = args.description } },
                .{ .name = "included_permissions", .value = permissions },
                .{ .name = "parent", .value = .{ .string = parent } },
                .{ .name = "project_id", .value = .{ .string = provider.project_id } },
                .{ .name = "resource_name", .value = .{ .string = resource_name } },
                .{ .name = "role_id", .value = .{ .string = args.role_id } },
                .{ .name = "stage", .value = .{ .string = args.stage.apiName() } },
                .{ .name = "title", .value = .{ .string = args.title } },
            };
            const node = try initManagedIamNode(allocator, type_name, args.role_id, &fields, args.retain_on_delete);
            return .{
                .node = node,
                .name = Outputs.Name.fromResource(node.id),
                .etag = Outputs.Etag.fromResource(node.id),
            };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.node.deinit(allocator);
            self.* = undefined;
        }
    };
}

fn initManagedIamNode(
    allocator: std.mem.Allocator,
    comptime type_name: []const u8,
    logical_id: []const u8,
    fields: []const value.Field,
    retain_on_delete: bool,
) BuildError!resource.ResourceNode {
    const id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_name, logical_id });
    defer allocator.free(id);
    return resource.ResourceNode.initOwned(allocator, .{
        .id = id,
        .provider = .gcp,
        .type_name = type_name,
        .schema_version = 1,
        .logical_id = logical_id,
        .inputs = .{ .object = fields },
        .lifecycle = .{ .retain_on_delete = retain_on_delete },
    }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
    };
}

fn canonicalPermissionsValueAlloc(allocator: std.mem.Allocator, permissions: []const []const u8) BuildError!value.Value {
    if (permissions.len == 0) return error.InvalidCustomRole;
    const result = try allocator.alloc(value.Value, permissions.len);
    errdefer allocator.free(result);
    for (permissions, 0..) |permission, index| {
        if (!validPermission(permission)) return error.InvalidCustomRole;
        for (permissions[0..index]) |prior| if (std.mem.eql(u8, prior, permission)) return error.DuplicatePermission;
        result[index] = .{ .string = permission };
    }
    std.mem.sort(value.Value, result, {}, lessThanMemberValue);
    return .{ .list = result };
}

fn validPermission(permission: []const u8) bool {
    if (permission.len < 3 or std.mem.indexOfScalar(u8, permission, '.') == null) return false;
    for (permission) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_') return false;
    return true;
}

fn validCustomRoleId(role_id: []const u8) bool {
    if (role_id.len < 3 or role_id.len > 64) return false;
    for (role_id) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '.') return false;
    return true;
}

fn validFederationId(id: []const u8) bool {
    if (id.len < 4 or id.len > 32 or !std.ascii.isLower(id[0])) return false;
    if (!std.ascii.isLower(id[id.len - 1]) and !std.ascii.isDigit(id[id.len - 1])) return false;
    for (id) |byte| if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '-') return false;
    return true;
}

fn validBoundedText(text: []const u8, maximum: usize) bool {
    return text.len > 0 and text.len <= maximum and validIamText(text);
}

fn canonicalAttributeMappingJsonAlloc(allocator: std.mem.Allocator, mappings: []const AttributeMapping) BuildError![]const u8 {
    if (mappings.len == 0 or mappings.len > 50) return error.InvalidAttributeMapping;
    var has_subject = false;
    const sorted = try allocator.dupe(AttributeMapping, mappings);
    defer allocator.free(sorted);
    for (mappings, 0..) |mapping, index| {
        if (!validMappingKey(mapping.key) or !validIamText(mapping.expression) or mapping.expression.len > 2048) {
            return error.InvalidAttributeMapping;
        }
        if (std.mem.eql(u8, mapping.key, "google.subject")) has_subject = true;
        for (mappings[0..index]) |prior| if (std.mem.eql(u8, prior.key, mapping.key)) return error.InvalidAttributeMapping;
    }
    if (!has_subject) return error.MissingSubjectMapping;
    std.mem.sort(AttributeMapping, sorted, {}, lessThanMapping);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var object: std.json.ObjectMap = .empty;
    for (sorted) |mapping| try object.put(arena_state.allocator(), mapping.key, .{ .string = mapping.expression });
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = object }, .{}) catch error.OutOfMemory;
}

fn validMappingKey(key: []const u8) bool {
    if (std.mem.eql(u8, key, "google.subject") or std.mem.eql(u8, key, "google.groups")) return true;
    if (!std.mem.startsWith(u8, key, "attribute.") or key.len <= "attribute.".len or key.len > 100) return false;
    for (key["attribute.".len..]) |byte| if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '_') return false;
    return true;
}

fn lessThanMapping(_: void, left: AttributeMapping, right: AttributeMapping) bool {
    return std.mem.lessThan(u8, left.key, right.key);
}

fn canonicalStringListValueAlloc(
    allocator: std.mem.Allocator,
    strings: []const []const u8,
    invalid_error: BuildError,
) BuildError!value.Value {
    const result = try allocator.alloc(value.Value, strings.len);
    errdefer allocator.free(result);
    for (strings, 0..) |text, index| {
        if (text.len == 0) return invalid_error;
        for (strings[0..index]) |prior| if (std.mem.eql(u8, prior, text)) return invalid_error;
        result[index] = .{ .string = text };
    }
    std.mem.sort(value.Value, result, {}, lessThanMemberValue);
    return .{ .list = result };
}

fn publicOutputValue(source: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (source) {
        .value => |text| .{ .string = text },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn MemberResource(comptime type_name: []const u8, comptime Args: type, comptime scope: PolicyScope) type {
    return struct {
        pub const Outputs = struct {
            pub const BindingId = output.Descriptor("binding_id", []const u8, .public);

            pub fn field(comptime name: []const u8) type {
                if (std.mem.eql(u8, name, "binding_id")) return BindingId;
                @compileError("ZIAC120 unknown " ++ type_name ++ " output field: " ++ name);
            }
        };

        node: resource.ResourceNode,
        binding_id: Outputs.BindingId.OutputType,

        pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: Args) BuildError!@This() {
            try provider.validate();
            try validateNameRoleAndCondition(args.name, args.role, args.member, args.condition);
            const resource_name = try policyResourceNameAlloc(allocator, provider, args, scope);
            defer allocator.free(resource_name);
            if (isPublicPrincipal(args.member)) return error.InvalidMember;
            const condition = args.condition orelse Condition{ .title = "", .expression = "" };
            const fields = [_]value.Field{
                .{ .name = "condition_description", .value = .{ .string = condition.description } },
                .{ .name = "condition_expression", .value = .{ .string = condition.expression } },
                .{ .name = "condition_title", .value = .{ .string = condition.title } },
                .{ .name = "member", .value = .{ .string = args.member } },
                .{ .name = "name", .value = .{ .string = args.name } },
                .{ .name = "ownership_mode", .value = .{ .string = OwnershipMode.member.apiName() } },
                .{ .name = "project_id", .value = .{ .string = provider.project_id } },
                .{ .name = "resource_name", .value = .{ .string = resource_name } },
                .{ .name = "role", .value = .{ .string = args.role } },
            };
            const node = try initIamNode(allocator, type_name, args.name, &fields);
            return .{ .node = node, .binding_id = Outputs.BindingId.fromResource(node.id) };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.node.deinit(allocator);
            self.* = undefined;
        }
    };
}

fn BindingResource(comptime type_name: []const u8, comptime Args: type, comptime scope: PolicyScope) type {
    return struct {
        pub const Outputs = struct {
            pub const BindingId = output.Descriptor("binding_id", []const u8, .public);
        };

        node: resource.ResourceNode,
        binding_id: Outputs.BindingId.OutputType,

        pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: Args) BuildError!@This() {
            try provider.validate();
            if (args.name.len == 0) return error.MissingName;
            try validateRole(args.role);
            try validateMembers(args.members, args.condition);
            if (args.condition) |condition| for (args.members) |member| try validateCondition(args.role, member, condition);
            const resource_name = try policyResourceNameAlloc(allocator, provider, args, scope);
            defer allocator.free(resource_name);
            const members = try canonicalMembersValueAlloc(allocator, args.members);
            defer allocator.free(members.list);
            const condition = args.condition orelse Condition{ .title = "", .expression = "" };
            const fields = [_]value.Field{
                .{ .name = "condition_description", .value = .{ .string = condition.description } },
                .{ .name = "condition_expression", .value = .{ .string = condition.expression } },
                .{ .name = "condition_title", .value = .{ .string = condition.title } },
                .{ .name = "members", .value = members },
                .{ .name = "name", .value = .{ .string = args.name } },
                .{ .name = "ownership_mode", .value = .{ .string = OwnershipMode.binding.apiName() } },
                .{ .name = "project_id", .value = .{ .string = provider.project_id } },
                .{ .name = "resource_name", .value = .{ .string = resource_name } },
                .{ .name = "role", .value = .{ .string = args.role } },
            };
            const node = try initIamNode(allocator, type_name, args.name, &fields);
            return .{ .node = node, .binding_id = Outputs.BindingId.fromResource(node.id) };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.node.deinit(allocator);
            self.* = undefined;
        }
    };
}

fn PolicyResource(comptime type_name: []const u8, comptime Args: type, comptime scope: PolicyScope) type {
    return struct {
        pub const Outputs = struct {
            pub const PolicyId = output.Descriptor("policy_id", []const u8, .public);
        };

        node: resource.ResourceNode,
        policy_id: Outputs.PolicyId.OutputType,

        pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: Args) BuildError!@This() {
            try provider.validate();
            if (args.name.len == 0) return error.MissingName;
            const resource_name = try policyResourceNameAlloc(allocator, provider, args, scope);
            defer allocator.free(resource_name);
            const bindings_json = try canonicalBindingsJsonAlloc(allocator, args.bindings);
            defer allocator.free(bindings_json);
            const fields = [_]value.Field{
                .{ .name = "bindings_json", .value = .{ .string = bindings_json } },
                .{ .name = "name", .value = .{ .string = args.name } },
                .{ .name = "ownership_mode", .value = .{ .string = OwnershipMode.policy.apiName() } },
                .{ .name = "project_id", .value = .{ .string = provider.project_id } },
                .{ .name = "resource_name", .value = .{ .string = resource_name } },
            };
            const node = try initIamNode(allocator, type_name, args.name, &fields);
            return .{ .node = node, .policy_id = Outputs.PolicyId.fromResource(node.id) };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.node.deinit(allocator);
            self.* = undefined;
        }
    };
}

fn initIamNode(
    allocator: std.mem.Allocator,
    comptime type_name: []const u8,
    name: []const u8,
    fields: []const value.Field,
) BuildError!resource.ResourceNode {
    const id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_name, name });
    defer allocator.free(id);
    return resource.ResourceNode.initOwned(allocator, .{
        .id = id,
        .provider = .gcp,
        .type_name = type_name,
        .schema_version = 2,
        .logical_id = name,
        .inputs = .{ .object = fields },
    }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
    };
}

fn validateNameRoleAndCondition(name: []const u8, role: []const u8, member: []const u8, condition: ?Condition) BuildError!void {
    if (name.len == 0) return error.MissingName;
    try validateRole(role);
    if (!validPrincipal(member)) return error.InvalidMember;
    if (condition) |entry| try validateCondition(role, member, entry);
}

fn validateMembers(members: []const []const u8, condition: ?Condition) BuildError!void {
    if (members.len == 0) return error.InvalidMember;
    for (members, 0..) |member, index| {
        if (!validPrincipal(member) or isPublicPrincipal(member)) return error.InvalidMember;
        if (condition) |entry| try validateCondition("roles/placeholder", member, entry);
        for (members[0..index]) |prior| if (std.mem.eql(u8, prior, member)) return error.DuplicateMember;
    }
}

fn validateRole(role: []const u8) BuildError!void {
    if (std.mem.startsWith(u8, role, "roles/") and role.len > "roles/".len) return;
    if ((std.mem.startsWith(u8, role, "projects/") or std.mem.startsWith(u8, role, "organizations/")) and
        std.mem.indexOf(u8, role, "/roles/") != null) return;
    return error.InvalidRole;
}

fn validateCondition(role: []const u8, member: []const u8, condition: Condition) BuildError!void {
    if (isPublicPrincipal(member) or isBasicRole(role)) return error.InvalidIamCondition;
    if (!validIamText(condition.title) or condition.title.len > 100 or
        !validIamText(condition.expression) or condition.expression.len > 4096 or
        (condition.description.len > 0 and (!validIamText(condition.description) or condition.description.len > 256)))
    {
        return error.InvalidIamCondition;
    }
}

fn isBasicRole(role: []const u8) bool {
    return std.mem.eql(u8, role, "roles/owner") or std.mem.eql(u8, role, "roles/editor") or std.mem.eql(u8, role, "roles/viewer");
}

fn validPrincipal(member: []const u8) bool {
    if (isPublicPrincipal(member)) return true;
    const prefixes = [_][]const u8{
        "user:",          "group:",                  "serviceAccount:",                 "domain:",                            "deleted:user:",
        "deleted:group:", "deleted:serviceAccount:", "principal://iam.googleapis.com/", "principalSet://iam.googleapis.com/", "projectOwner:",
        "projectEditor:", "projectViewer:",
    };
    for (prefixes) |prefix| if (std.mem.startsWith(u8, member, prefix) and member.len > prefix.len) return true;
    return false;
}

fn isPublicPrincipal(member: []const u8) bool {
    return std.mem.eql(u8, member, "allUsers") or std.mem.eql(u8, member, "allAuthenticatedUsers");
}

fn validIamText(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |byte| if (byte < 0x20 and byte != '\n' and byte != '\t') return false;
    return true;
}

fn policyResourceNameAlloc(
    allocator: std.mem.Allocator,
    provider: config_mod.ProviderConfig,
    args: anytype,
    comptime scope: PolicyScope,
) BuildError![]const u8 {
    return switch (scope) {
        .project => std.fmt.allocPrint(allocator, "projects/{s}", .{provider.project_id}),
        .folder => blk: {
            if (!validNumericId(args.folder_id)) return error.InvalidResourceName;
            break :blk std.fmt.allocPrint(allocator, "folders/{s}", .{args.folder_id});
        },
        .organization => blk: {
            if (!validNumericId(args.organization_id)) return error.InvalidResourceName;
            break :blk std.fmt.allocPrint(allocator, "organizations/{s}", .{args.organization_id});
        },
        .service_account => blk: {
            if (!validServiceAccountEmail(args.service_account_email)) return error.InvalidResourceName;
            break :blk std.fmt.allocPrint(
                allocator,
                "projects/{s}/serviceAccounts/{s}",
                .{ provider.project_id, args.service_account_email },
            );
        },
    };
}

fn validNumericId(id: []const u8) bool {
    if (id.len < 6 or id.len > 32) return false;
    for (id) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn validServiceAccountEmail(email: []const u8) bool {
    return std.mem.indexOfScalar(u8, email, '@') != null and std.mem.endsWith(u8, email, ".iam.gserviceaccount.com");
}

fn canonicalMembersValueAlloc(allocator: std.mem.Allocator, members: []const []const u8) BuildError!value.Value {
    const values = try allocator.alloc(value.Value, members.len);
    for (members, 0..) |member, index| values[index] = .{ .string = member };
    std.mem.sort(value.Value, values, {}, lessThanMemberValue);
    return .{ .list = values };
}

fn lessThanMemberValue(_: void, left: value.Value, right: value.Value) bool {
    return std.mem.lessThan(u8, left.string, right.string);
}

fn canonicalBindingsJsonAlloc(allocator: std.mem.Allocator, bindings: []const Binding) BuildError![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sorted = try arena.dupe(Binding, bindings);
    std.mem.sort(Binding, sorted, {}, lessThanBinding);
    for (sorted, 0..) |binding, index| {
        try validateRole(binding.role);
        try validateMembers(binding.members, binding.condition);
        if (binding.condition) |condition| {
            for (binding.members) |member| try validateCondition(binding.role, member, condition);
        }
        if (index > 0 and sameBindingIdentity(sorted[index - 1], binding)) return error.DuplicateBinding;
    }
    var array = std.json.Array.init(arena);
    for (sorted) |binding| {
        var object: std.json.ObjectMap = .empty;
        try object.put(arena, "role", .{ .string = binding.role });
        const members = try canonicalMembersValueAlloc(arena, binding.members);
        var json_members = std.json.Array.init(arena);
        for (members.list) |member| try json_members.append(.{ .string = member.string });
        try object.put(arena, "members", .{ .array = json_members });
        if (binding.condition) |condition| {
            var condition_object: std.json.ObjectMap = .empty;
            try condition_object.put(arena, "title", .{ .string = condition.title });
            try condition_object.put(arena, "description", .{ .string = condition.description });
            try condition_object.put(arena, "expression", .{ .string = condition.expression });
            try object.put(arena, "condition", .{ .object = condition_object });
        }
        try array.append(.{ .object = object });
    }
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .array = array }, .{}) catch return error.OutOfMemory;
}

fn lessThanBinding(_: void, left: Binding, right: Binding) bool {
    const role_order = std.mem.order(u8, left.role, right.role);
    if (role_order != .eq) return role_order == .lt;
    const left_title = if (left.condition) |condition| condition.title else "";
    const right_title = if (right.condition) |condition| condition.title else "";
    const title_order = std.mem.order(u8, left_title, right_title);
    if (title_order != .eq) return title_order == .lt;
    const left_expression = if (left.condition) |condition| condition.expression else "";
    const right_expression = if (right.condition) |condition| condition.expression else "";
    return std.mem.lessThan(u8, left_expression, right_expression);
}

fn sameBindingIdentity(left: Binding, right: Binding) bool {
    if (!std.mem.eql(u8, left.role, right.role)) return false;
    if ((left.condition == null) != (right.condition == null)) return false;
    if (left.condition) |left_condition| {
        const right_condition = right.condition.?;
        return std.mem.eql(u8, left_condition.title, right_condition.title) and
            std.mem.eql(u8, left_condition.description, right_condition.description) and
            std.mem.eql(u8, left_condition.expression, right_condition.expression);
    }
    return true;
}

fn validAccountId(account_id: []const u8) bool {
    if (account_id.len < 6 or account_id.len > 30 or account_id[0] < 'a' or account_id[0] > 'z') return false;
    if (!std.ascii.isAlphanumeric(account_id[account_id.len - 1])) return false;
    for (account_id[1..]) |byte| {
        if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '-') return false;
    }
    return true;
}
