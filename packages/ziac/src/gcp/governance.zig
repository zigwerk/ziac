const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    DuplicateItem,
    InvalidAccessLevel,
    InvalidCondition,
    InvalidConstraint,
    InvalidName,
    InvalidParent,
    InvalidPerimeter,
    InvalidPolicy,
    InvalidPrincipal,
    InvalidPurpose,
    InvalidResource,
    InvalidService,
    InvalidShortName,
    OutputNotKnown,
};

pub const RemovalPolicy = enum { retain, delete };

pub const ParameterValue = union(enum) {
    string: []const u8,
    boolean: bool,
    integer: i64,
    strings: []const []const u8,
};

pub const Parameter = struct {
    name: []const u8,
    value: ParameterValue,
};

pub const PolicyValues = struct {
    allowed: []const []const u8 = &.{},
    denied: []const []const u8 = &.{},
};

pub const PolicyEffect = union(enum) {
    enforce: bool,
    allow_all: void,
    deny_all: void,
    values: PolicyValues,
};

pub const PolicyRule = struct {
    condition: ?[]const u8 = null,
    effect: PolicyEffect,
    parameters: []const Parameter = &.{},
};

pub const PolicySpec = struct {
    inherit_from_parent: bool = false,
    reset: bool = false,
    rules: []const PolicyRule = &.{},
};

pub const PolicyArgs = struct {
    name: []const u8,
    parent: output.Output([]const u8, .public),
    constraint: []const u8,
    spec: PolicySpec,
    dry_run_spec: ?PolicySpec = null,
    removal_policy: RemovalPolicy = .retain,
};

pub const Policy = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
        pub const SpecEtag = output.Descriptor("spec_etag", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    etag: Outputs.Etag.OutputType,
    spec_etag: Outputs.SpecEtag.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: PolicyArgs) BuildError!Policy {
        try provider.validate();
        try validateLogicalName(args.name);
        try validateHierarchyOutput(args.parent);
        if (!validConstraint(args.constraint)) return error.InvalidConstraint;
        try validatePolicySpec(args.spec);
        if (args.dry_run_spec) |spec| try validatePolicySpec(spec);
        var spec = try policySpecValue(allocator, args.spec);
        defer spec.deinit(allocator);
        var dry_run = if (args.dry_run_spec) |selected| try policySpecValue(allocator, selected) else try ownedValue(allocator, .{ .object = &.{} });
        defer dry_run.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "constraint", .value = .{ .string = args.constraint } },
            .{ .name = "dry_run_spec", .value = dry_run },
            .{ .name = "has_dry_run_spec", .value = .{ .boolean = args.dry_run_spec != null } },
            .{ .name = "parent", .value = try outputValue(args.parent) },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
            .{ .name = "spec", .value = spec },
        };
        const node = try initNode(allocator, "gcp.orgpolicy.Policy", args.name, &fields, .{ .retain_on_delete = args.removal_policy == .retain });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .etag = Outputs.Etag.fromResource(node.id),
            .spec_etag = Outputs.SpecEtag.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Policy, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const MethodType = enum { create, update, remove_grant, govern_tags };
pub const ConstraintAction = enum { allow, deny };

pub const CustomConstraintArgs = struct {
    name: []const u8,
    organization: output.Output([]const u8, .public),
    constraint_id: []const u8,
    resource_types: []const []const u8,
    method_types: []const MethodType,
    action: ConstraintAction,
    condition: []const u8,
    display_name: []const u8,
    description: []const u8 = "",
    removal_policy: RemovalPolicy = .retain,
};

pub const CustomConstraint = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const UpdateTime = output.Descriptor("update_time", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    update_time: Outputs.UpdateTime.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: CustomConstraintArgs) BuildError!CustomConstraint {
        try provider.validate();
        try validateLogicalName(args.name);
        try validateOrganizationOutput(args.organization);
        if (!validCustomConstraint(args.constraint_id)) return error.InvalidConstraint;
        if (args.resource_types.len == 0 or args.method_types.len == 0 or args.condition.len == 0 or args.condition.len > 1000 or args.display_name.len == 0 or args.display_name.len > 200 or args.description.len > 2000) return error.InvalidConstraint;
        try validateUniqueStrings(args.resource_types);
        for (args.resource_types) |item| if (!validResourceType(item)) return error.InvalidResource;
        try validateUniqueEnums(MethodType, args.method_types);
        var resources = try stringsValue(allocator, args.resource_types);
        defer resources.deinit(allocator);
        var methods = try enumStringsValue(MethodType, allocator, args.method_types, methodTypeWire);
        defer methods.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "action", .value = .{ .string = if (args.action == .allow) "ALLOW" else "DENY" } },
            .{ .name = "condition", .value = .{ .string = args.condition } },
            .{ .name = "constraint_id", .value = .{ .string = args.constraint_id } },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "method_types", .value = methods },
            .{ .name = "organization", .value = try outputValue(args.organization) },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
            .{ .name = "resource_types", .value = resources },
        };
        const node = try initNode(allocator, "gcp.orgpolicy.CustomConstraint", args.name, &fields, .{ .retain_on_delete = args.removal_policy == .retain });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .update_time = Outputs.UpdateTime.fromResource(node.id) };
    }

    pub fn deinit(self: *CustomConstraint, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const TagPurpose = enum { unspecified, gce_firewall, data_governance };

pub const TagKeyArgs = struct {
    name: []const u8,
    parent: output.Output([]const u8, .public),
    short_name: []const u8,
    description: []const u8 = "",
    purpose: TagPurpose = .unspecified,
    purpose_data: []const config_mod.Label = &.{},
    allowed_values_regex: []const u8 = "",
    removal_policy: RemovalPolicy = .retain,
};

pub const TagKey = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const NamespacedName = output.Descriptor("namespaced_name", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    namespaced_name: Outputs.NamespacedName.OutputType,
    etag: Outputs.Etag.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: TagKeyArgs) BuildError!TagKey {
        try provider.validate();
        try validateLogicalName(args.name);
        try validateTagKeyParentOutput(args.parent);
        if (!validTagShortName(args.short_name)) return error.InvalidShortName;
        if (args.description.len > 256 or args.allowed_values_regex.len > 1024) return error.InvalidName;
        try validatePurpose(args.purpose, args.purpose_data);
        var purpose_data = try labelsValue(allocator, args.purpose_data);
        defer purpose_data.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "allowed_values_regex", .value = .{ .string = args.allowed_values_regex } },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "parent", .value = try outputValue(args.parent) },
            .{ .name = "purpose", .value = .{ .string = tagPurposeWire(args.purpose) } },
            .{ .name = "purpose_data", .value = purpose_data },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
            .{ .name = "short_name", .value = .{ .string = args.short_name } },
        };
        const node = try initNode(allocator, "gcp.tags.TagKey", args.name, &fields, .{ .retain_on_delete = args.removal_policy == .retain });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .namespaced_name = Outputs.NamespacedName.fromResource(node.id),
            .etag = Outputs.Etag.fromResource(node.id),
        };
    }

    pub fn deinit(self: *TagKey, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const TagValueArgs = struct {
    name: []const u8,
    parent: output.Output([]const u8, .public),
    short_name: []const u8,
    description: []const u8 = "",
    removal_policy: RemovalPolicy = .retain,
};

pub const TagValue = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const NamespacedName = output.Descriptor("namespaced_name", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    namespaced_name: Outputs.NamespacedName.OutputType,
    etag: Outputs.Etag.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: TagValueArgs) BuildError!TagValue {
        try provider.validate();
        try validateLogicalName(args.name);
        try validateOutputPrefix(args.parent, "tagKeys/");
        if (!validTagShortName(args.short_name)) return error.InvalidShortName;
        if (args.description.len > 256) return error.InvalidName;
        const fields = [_]value.Field{
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "parent", .value = try outputValue(args.parent) },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
            .{ .name = "short_name", .value = .{ .string = args.short_name } },
        };
        const node = try initNode(allocator, "gcp.tags.TagValue", args.name, &fields, .{ .retain_on_delete = args.removal_policy == .retain });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .namespaced_name = Outputs.NamespacedName.fromResource(node.id),
            .etag = Outputs.Etag.fromResource(node.id),
        };
    }

    pub fn deinit(self: *TagValue, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const TagBindingArgs = struct {
    name: []const u8,
    parent: output.Output([]const u8, .public),
    tag_value: output.Output([]const u8, .public),
    removal_policy: RemovalPolicy = .retain,
};

pub const TagBinding = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: TagBindingArgs) BuildError!TagBinding {
        try provider.validate();
        try validateLogicalName(args.name);
        try validateFullResourceOutput(args.parent);
        try validateOutputPrefix(args.tag_value, "tagValues/");
        const fields = [_]value.Field{
            .{ .name = "parent", .value = try outputValue(args.parent) },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
            .{ .name = "tag_value", .value = try outputValue(args.tag_value) },
        };
        const node = try initNode(allocator, "gcp.tags.TagBinding", args.name, &fields, .{ .retain_on_delete = args.removal_policy == .retain });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
    }

    pub fn deinit(self: *TagBinding, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const TagHoldArgs = struct {
    name: []const u8,
    parent: output.Output([]const u8, .public),
    holder: []const u8,
    origin: []const u8 = "",
    help_link: []const u8 = "",
    removal_policy: RemovalPolicy = .retain,
};

pub const TagHold = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const CreateTime = output.Descriptor("create_time", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    create_time: Outputs.CreateTime.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: TagHoldArgs) BuildError!TagHold {
        try provider.validate();
        try validateLogicalName(args.name);
        try validateOutputPrefix(args.parent, "tagValues/");
        if (!validFullResourceName(args.holder) or args.holder.len >= 200 or args.origin.len >= 200 or (args.help_link.len != 0 and !std.mem.startsWith(u8, args.help_link, "https://"))) return error.InvalidResource;
        const fields = [_]value.Field{
            .{ .name = "help_link", .value = .{ .string = args.help_link } },
            .{ .name = "holder", .value = .{ .string = args.holder } },
            .{ .name = "origin", .value = .{ .string = args.origin } },
            .{ .name = "parent", .value = try outputValue(args.parent) },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
        };
        const node = try initNode(allocator, "gcp.tags.TagHold", args.name, &fields, .{ .retain_on_delete = args.removal_policy == .retain });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .create_time = Outputs.CreateTime.fromResource(node.id) };
    }

    pub fn deinit(self: *TagHold, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const AccessPolicyArgs = struct {
    name: []const u8,
    parent: output.Output([]const u8, .public),
    title: []const u8,
    scope: ?output.Output([]const u8, .public) = null,
    request_delete: bool = false,
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const AccessPolicy = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    etag: Outputs.Etag.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: AccessPolicyArgs) BuildError!AccessPolicy {
        try provider.validate();
        try validateLogicalName(args.name);
        try validateOrganizationOutput(args.parent);
        if (args.title.len == 0 or args.title.len > 50) return error.InvalidName;
        var scope_value: value.Value = .{ .string = "" };
        if (args.scope) |scope| {
            try validateProjectOrFolderOutput(scope);
            scope_value = try outputValue(scope);
        }
        const fields = [_]value.Field{
            .{ .name = "parent", .value = try outputValue(args.parent) },
            .{ .name = "request_delete", .value = .{ .boolean = args.request_delete } },
            .{ .name = "scope", .value = scope_value },
            .{ .name = "title", .value = .{ .string = args.title } },
        };
        const node = try initNode(allocator, "gcp.accesscontextmanager.AccessPolicy", args.name, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
            .operation_timeout_millis = 30 * 60 * 1000,
        });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .etag = Outputs.Etag.fromResource(node.id) };
    }

    pub fn deinit(self: *AccessPolicy, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const CombiningFunction = enum { and_all, or_any };

pub const AccessCondition = struct {
    ip_subnetworks: []const []const u8 = &.{},
    members: []const []const u8 = &.{},
    regions: []const []const u8 = &.{},
    required_access_levels: []const output.Output([]const u8, .public) = &.{},
    negate: bool = false,
};

pub const BasicAccessLevel = struct {
    combining_function: CombiningFunction = .and_all,
    conditions: []const AccessCondition,
};

pub const AccessLevelDefinition = union(enum) {
    basic: BasicAccessLevel,
    custom: []const u8,
};

pub const AccessLevelArgs = struct {
    name: []const u8,
    policy: output.Output([]const u8, .public),
    title: []const u8,
    description: []const u8 = "",
    level: AccessLevelDefinition,
    removal_policy: RemovalPolicy = .retain,
};

pub const AccessLevel = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: AccessLevelArgs) BuildError!AccessLevel {
        try provider.validate();
        if (!validAccessIdentifier(args.name)) return error.InvalidAccessLevel;
        try validateOutputPrefix(args.policy, "accessPolicies/");
        if (args.title.len == 0 or args.title.len > 50 or args.description.len > 200) return error.InvalidAccessLevel;
        try validateAccessDefinition(args.level);
        var definition = try accessDefinitionValue(allocator, args.level);
        defer definition.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "level", .value = definition },
            .{ .name = "policy", .value = try outputValue(args.policy) },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
            .{ .name = "title", .value = .{ .string = args.title } },
        };
        const node = try initNode(allocator, "gcp.accesscontextmanager.AccessLevel", args.name, &fields, .{ .retain_on_delete = args.removal_policy == .retain, .operation_timeout_millis = 30 * 60 * 1000 });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
    }

    pub fn deinit(self: *AccessLevel, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const PerimeterType = enum { regular, bridge };
pub const IdentityType = enum { any_identity, any_user_account, any_service_account };

pub const ApiOperation = struct {
    service: []const u8,
    methods: []const []const u8 = &.{},
    permissions: []const []const u8 = &.{},
};

pub const IngressPolicy = struct {
    source_resources: []const []const u8 = &.{},
    source_access_levels: []const output.Output([]const u8, .public) = &.{},
    identities: []const []const u8 = &.{},
    identity_type: ?IdentityType = null,
    target_resources: []const []const u8 = &.{},
    operations: []const ApiOperation = &.{},
    roles: []const []const u8 = &.{},
};

pub const EgressPolicy = struct {
    identities: []const []const u8 = &.{},
    identity_type: ?IdentityType = null,
    target_resources: []const []const u8 = &.{},
    operations: []const ApiOperation = &.{},
};

pub const VpcAccessibleServices = struct {
    enabled: bool = false,
    allowed_services: []const []const u8 = &.{},
};

pub const ServicePerimeterConfig = struct {
    resources: []const output.Output([]const u8, .public) = &.{},
    restricted_services: []const []const u8 = &.{},
    access_levels: []const output.Output([]const u8, .public) = &.{},
    ingress_policies: []const IngressPolicy = &.{},
    egress_policies: []const EgressPolicy = &.{},
    vpc_accessible_services: VpcAccessibleServices = .{},
};

pub const ServicePerimeterArgs = struct {
    name: []const u8,
    policy: output.Output([]const u8, .public),
    title: []const u8,
    description: []const u8 = "",
    perimeter_type: PerimeterType = .regular,
    status: ServicePerimeterConfig,
    dry_run: ?ServicePerimeterConfig = null,
    removal_policy: RemovalPolicy = .retain,
};

pub const ServicePerimeter = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    etag: Outputs.Etag.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ServicePerimeterArgs) BuildError!ServicePerimeter {
        try provider.validate();
        if (!validAccessIdentifier(args.name)) return error.InvalidPerimeter;
        try validateOutputPrefix(args.policy, "accessPolicies/");
        if (args.title.len == 0 or args.title.len > 50 or args.description.len > 200) return error.InvalidPerimeter;
        try validatePerimeterConfig(args.status, args.perimeter_type);
        if (args.dry_run) |selected| try validatePerimeterConfig(selected, args.perimeter_type);
        var status = try perimeterConfigValue(allocator, args.status);
        defer status.deinit(allocator);
        var dry_run = if (args.dry_run) |selected| try perimeterConfigValue(allocator, selected) else try ownedValue(allocator, .{ .object = &.{} });
        defer dry_run.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "dry_run", .value = dry_run },
            .{ .name = "has_dry_run", .value = .{ .boolean = args.dry_run != null } },
            .{ .name = "perimeter_type", .value = .{ .string = if (args.perimeter_type == .regular) "PERIMETER_TYPE_REGULAR" else "PERIMETER_TYPE_BRIDGE" } },
            .{ .name = "policy", .value = try outputValue(args.policy) },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
            .{ .name = "status", .value = status },
            .{ .name = "title", .value = .{ .string = args.title } },
        };
        const node = try initNode(allocator, "gcp.accesscontextmanager.ServicePerimeter", args.name, &fields, .{ .retain_on_delete = args.removal_policy == .retain, .operation_timeout_millis = 30 * 60 * 1000 });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .etag = Outputs.Etag.fromResource(node.id) };
    }

    pub fn deinit(self: *ServicePerimeter, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const GcpUserAccessBindingArgs = struct {
    name: []const u8,
    organization: output.Output([]const u8, .public),
    group_key: []const u8,
    access_level: ?output.Output([]const u8, .public) = null,
    dry_run_access_level: ?output.Output([]const u8, .public) = null,
    removal_policy: RemovalPolicy = .retain,
};

pub const GcpUserAccessBinding = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: GcpUserAccessBindingArgs) BuildError!GcpUserAccessBinding {
        try provider.validate();
        try validateLogicalName(args.name);
        try validateOrganizationOutput(args.organization);
        if (args.group_key.len == 0 or args.group_key.len > 128 or (args.access_level == null and args.dry_run_access_level == null)) return error.InvalidAccessLevel;
        var access: value.Value = .{ .string = "" };
        if (args.access_level) |selected| {
            try validateOutputContains(selected, "/accessLevels/");
            access = try outputValue(selected);
        }
        var dry_run: value.Value = .{ .string = "" };
        if (args.dry_run_access_level) |selected| {
            try validateOutputContains(selected, "/accessLevels/");
            dry_run = try outputValue(selected);
        }
        const fields = [_]value.Field{
            .{ .name = "access_level", .value = access },
            .{ .name = "dry_run_access_level", .value = dry_run },
            .{ .name = "group_key", .value = .{ .string = args.group_key } },
            .{ .name = "organization", .value = try outputValue(args.organization) },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
        };
        const node = try initNode(allocator, "gcp.accesscontextmanager.GcpUserAccessBinding", args.name, &fields, .{ .retain_on_delete = args.removal_policy == .retain, .operation_timeout_millis = 30 * 60 * 1000 });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
    }

    pub fn deinit(self: *GcpUserAccessBinding, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn initNode(allocator: std.mem.Allocator, type_name: []const u8, logical_name: []const u8, fields: []const value.Field, lifecycle: resource.Lifecycle) BuildError!resource.ResourceNode {
    const id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_name, logical_name });
    defer allocator.free(id);
    return resource.ResourceNode.initOwned(allocator, .{
        .id = id,
        .provider = .gcp,
        .type_name = type_name,
        .schema_version = 1,
        .logical_id = logical_name,
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

fn policySpecValue(allocator: std.mem.Allocator, spec: PolicySpec) BuildError!value.Value {
    const rules = try allocator.alloc(value.Value, spec.rules.len);
    defer allocator.free(rules);
    for (spec.rules, 0..) |rule, index| rules[index] = try policyRuleValue(allocator, rule);
    defer for (rules) |*item| item.deinit(allocator);
    const fields = [_]value.Field{
        .{ .name = "inherit_from_parent", .value = .{ .boolean = spec.inherit_from_parent } },
        .{ .name = "reset", .value = .{ .boolean = spec.reset } },
        .{ .name = "rules", .value = .{ .list = rules } },
    };
    return ownedValue(allocator, .{ .object = &fields });
}

fn policyRuleValue(allocator: std.mem.Allocator, rule: PolicyRule) BuildError!value.Value {
    var effect = try policyEffectValue(allocator, rule.effect);
    defer effect.deinit(allocator);
    var parameters = try parametersValue(allocator, rule.parameters);
    defer parameters.deinit(allocator);
    const fields = [_]value.Field{
        .{ .name = "condition", .value = if (rule.condition) |condition| .{ .string = condition } else .{ .string = "" } },
        .{ .name = "effect", .value = effect },
        .{ .name = "parameters", .value = parameters },
    };
    return ownedValue(allocator, .{ .object = &fields });
}

fn policyEffectValue(allocator: std.mem.Allocator, effect: PolicyEffect) BuildError!value.Value {
    return switch (effect) {
        .enforce => |enabled| blk: {
            const fields = [_]value.Field{.{ .name = "enforce", .value = .{ .boolean = enabled } }};
            break :blk ownedValue(allocator, .{ .object = &fields });
        },
        .allow_all => blk: {
            const fields = [_]value.Field{.{ .name = "allow_all", .value = .{ .boolean = true } }};
            break :blk ownedValue(allocator, .{ .object = &fields });
        },
        .deny_all => blk: {
            const fields = [_]value.Field{.{ .name = "deny_all", .value = .{ .boolean = true } }};
            break :blk ownedValue(allocator, .{ .object = &fields });
        },
        .values => |selected| blk: {
            var allowed = try stringsValue(allocator, selected.allowed);
            defer allowed.deinit(allocator);
            var denied = try stringsValue(allocator, selected.denied);
            defer denied.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "allowed", .value = allowed },
                .{ .name = "denied", .value = denied },
            };
            break :blk ownedValue(allocator, .{ .object = &fields });
        },
    };
}

fn parametersValue(allocator: std.mem.Allocator, parameters: []const Parameter) BuildError!value.Value {
    const fields = try allocator.alloc(value.Field, parameters.len);
    defer allocator.free(fields);
    for (parameters, 0..) |parameter, index| {
        if (!validParameterName(parameter.name)) return error.InvalidPolicy;
        for (parameters[0..index]) |previous| if (std.mem.eql(u8, previous.name, parameter.name)) return error.DuplicateItem;
        fields[index] = .{ .name = parameter.name, .value = try parameterValue(allocator, parameter.value) };
    }
    defer for (fields) |*field| field.value.deinit(allocator);
    return ownedValue(allocator, .{ .object = fields });
}

fn parameterValue(allocator: std.mem.Allocator, selected: ParameterValue) BuildError!value.Value {
    return switch (selected) {
        .string => |item| ownedValue(allocator, .{ .string = item }),
        .boolean => |item| .{ .boolean = item },
        .integer => |item| .{ .integer = item },
        .strings => |items| stringsValue(allocator, items),
    };
}

fn accessDefinitionValue(allocator: std.mem.Allocator, definition: AccessLevelDefinition) BuildError!value.Value {
    return switch (definition) {
        .custom => |expression| blk: {
            const fields = [_]value.Field{.{ .name = "custom", .value = .{ .string = expression } }};
            break :blk ownedValue(allocator, .{ .object = &fields });
        },
        .basic => |basic| blk: {
            const conditions = try allocator.alloc(value.Value, basic.conditions.len);
            defer allocator.free(conditions);
            for (basic.conditions, 0..) |condition, index| conditions[index] = try conditionValue(allocator, condition);
            defer for (conditions) |*item| item.deinit(allocator);
            const basic_fields = [_]value.Field{
                .{ .name = "combining_function", .value = .{ .string = if (basic.combining_function == .and_all) "AND" else "OR" } },
                .{ .name = "conditions", .value = .{ .list = conditions } },
            };
            var basic_value = try ownedValue(allocator, .{ .object = &basic_fields });
            defer basic_value.deinit(allocator);
            const fields = [_]value.Field{.{ .name = "basic", .value = basic_value }};
            break :blk ownedValue(allocator, .{ .object = &fields });
        },
    };
}

fn conditionValue(allocator: std.mem.Allocator, condition: AccessCondition) BuildError!value.Value {
    var ips = try stringsValue(allocator, condition.ip_subnetworks);
    defer ips.deinit(allocator);
    var members = try stringsValue(allocator, condition.members);
    defer members.deinit(allocator);
    var regions = try stringsValue(allocator, condition.regions);
    defer regions.deinit(allocator);
    var levels = try outputsValue(allocator, condition.required_access_levels);
    defer levels.deinit(allocator);
    const fields = [_]value.Field{
        .{ .name = "ip_subnetworks", .value = ips },
        .{ .name = "members", .value = members },
        .{ .name = "negate", .value = .{ .boolean = condition.negate } },
        .{ .name = "regions", .value = regions },
        .{ .name = "required_access_levels", .value = levels },
    };
    return ownedValue(allocator, .{ .object = &fields });
}

fn perimeterConfigValue(allocator: std.mem.Allocator, config: ServicePerimeterConfig) BuildError!value.Value {
    var resources = try outputsValue(allocator, config.resources);
    defer resources.deinit(allocator);
    var services = try stringsValue(allocator, config.restricted_services);
    defer services.deinit(allocator);
    var levels = try outputsValue(allocator, config.access_levels);
    defer levels.deinit(allocator);
    var ingress = try ingressPoliciesValue(allocator, config.ingress_policies);
    defer ingress.deinit(allocator);
    var egress = try egressPoliciesValue(allocator, config.egress_policies);
    defer egress.deinit(allocator);
    var vpc = try vpcAccessibleValue(allocator, config.vpc_accessible_services);
    defer vpc.deinit(allocator);
    const fields = [_]value.Field{
        .{ .name = "access_levels", .value = levels },
        .{ .name = "egress_policies", .value = egress },
        .{ .name = "ingress_policies", .value = ingress },
        .{ .name = "resources", .value = resources },
        .{ .name = "restricted_services", .value = services },
        .{ .name = "vpc_accessible_services", .value = vpc },
    };
    return ownedValue(allocator, .{ .object = &fields });
}

fn ingressPoliciesValue(allocator: std.mem.Allocator, policies: []const IngressPolicy) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, policies.len);
    defer allocator.free(items);
    for (policies, 0..) |policy, index| {
        var sources = try stringsValue(allocator, policy.source_resources);
        defer sources.deinit(allocator);
        var levels = try outputsValue(allocator, policy.source_access_levels);
        defer levels.deinit(allocator);
        var identities = try stringsValue(allocator, policy.identities);
        defer identities.deinit(allocator);
        var targets = try stringsValue(allocator, policy.target_resources);
        defer targets.deinit(allocator);
        var operations = try operationsValue(allocator, policy.operations);
        defer operations.deinit(allocator);
        var roles = try stringsValue(allocator, policy.roles);
        defer roles.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "identities", .value = identities },
            .{ .name = "identity_type", .value = if (policy.identity_type) |kind| .{ .string = identityTypeWire(kind) } else .{ .string = "" } },
            .{ .name = "operations", .value = operations },
            .{ .name = "roles", .value = roles },
            .{ .name = "source_access_levels", .value = levels },
            .{ .name = "source_resources", .value = sources },
            .{ .name = "target_resources", .value = targets },
        };
        items[index] = try ownedValue(allocator, .{ .object = &fields });
    }
    defer for (items) |*item| item.deinit(allocator);
    return ownedValue(allocator, .{ .list = items });
}

fn egressPoliciesValue(allocator: std.mem.Allocator, policies: []const EgressPolicy) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, policies.len);
    defer allocator.free(items);
    for (policies, 0..) |policy, index| {
        var identities = try stringsValue(allocator, policy.identities);
        defer identities.deinit(allocator);
        var targets = try stringsValue(allocator, policy.target_resources);
        defer targets.deinit(allocator);
        var operations = try operationsValue(allocator, policy.operations);
        defer operations.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "identities", .value = identities },
            .{ .name = "identity_type", .value = if (policy.identity_type) |kind| .{ .string = identityTypeWire(kind) } else .{ .string = "" } },
            .{ .name = "operations", .value = operations },
            .{ .name = "target_resources", .value = targets },
        };
        items[index] = try ownedValue(allocator, .{ .object = &fields });
    }
    defer for (items) |*item| item.deinit(allocator);
    return ownedValue(allocator, .{ .list = items });
}

fn operationsValue(allocator: std.mem.Allocator, operations: []const ApiOperation) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, operations.len);
    defer allocator.free(items);
    for (operations, 0..) |operation, index| {
        var methods = try stringsValue(allocator, operation.methods);
        defer methods.deinit(allocator);
        var permissions = try stringsValue(allocator, operation.permissions);
        defer permissions.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "methods", .value = methods },
            .{ .name = "permissions", .value = permissions },
            .{ .name = "service", .value = .{ .string = operation.service } },
        };
        items[index] = try ownedValue(allocator, .{ .object = &fields });
    }
    defer for (items) |*item| item.deinit(allocator);
    return ownedValue(allocator, .{ .list = items });
}

fn vpcAccessibleValue(allocator: std.mem.Allocator, selected: VpcAccessibleServices) BuildError!value.Value {
    var services = try stringsValue(allocator, selected.allowed_services);
    defer services.deinit(allocator);
    const fields = [_]value.Field{
        .{ .name = "allowed_services", .value = services },
        .{ .name = "enabled", .value = .{ .boolean = selected.enabled } },
    };
    return ownedValue(allocator, .{ .object = &fields });
}

fn labelsValue(allocator: std.mem.Allocator, labels: []const config_mod.Label) BuildError!value.Value {
    const fields = try allocator.alloc(value.Field, labels.len);
    defer allocator.free(fields);
    for (labels, 0..) |label, index| {
        if (label.key.len == 0 or label.value.len == 0) return error.InvalidPurpose;
        for (labels[0..index]) |previous| if (std.mem.eql(u8, previous.key, label.key)) return error.DuplicateItem;
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

fn outputsValue(allocator: std.mem.Allocator, outputs: []const output.Output([]const u8, .public)) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, outputs.len);
    defer allocator.free(items);
    for (outputs, 0..) |item, index| items[index] = try outputValue(item);
    return ownedValue(allocator, .{ .list = items });
}

fn enumStringsValue(comptime T: type, allocator: std.mem.Allocator, enums: []const T, comptime wire: fn (T) []const u8) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, enums.len);
    defer allocator.free(items);
    for (enums, 0..) |item, index| items[index] = .{ .string = wire(item) };
    return ownedValue(allocator, .{ .list = items });
}

fn ownedValue(allocator: std.mem.Allocator, source: value.Value) BuildError!value.Value {
    return value.Value.initOwned(allocator, source) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn validatePolicySpec(spec: PolicySpec) BuildError!void {
    if (spec.reset) {
        if (spec.inherit_from_parent or spec.rules.len != 0) return error.InvalidPolicy;
        return;
    }
    if (spec.rules.len == 0) return error.InvalidPolicy;
    for (spec.rules) |rule| {
        if (rule.condition) |condition| if (condition.len == 0 or condition.len > 1000) return error.InvalidPolicy;
        switch (rule.effect) {
            .values => |selected| {
                if (selected.allowed.len == 0 and selected.denied.len == 0) return error.InvalidPolicy;
                if (selected.allowed.len != 0 and selected.denied.len != 0) return error.InvalidPolicy;
                try validateUniqueStrings(if (selected.allowed.len != 0) selected.allowed else selected.denied);
            },
            else => {},
        }
    }
}

fn validateAccessDefinition(definition: AccessLevelDefinition) BuildError!void {
    switch (definition) {
        .custom => |expression| if (expression.len == 0 or expression.len > 4096) return error.InvalidCondition,
        .basic => |basic| {
            if (basic.conditions.len == 0) return error.InvalidCondition;
            for (basic.conditions) |condition| {
                if (condition.ip_subnetworks.len == 0 and condition.members.len == 0 and condition.regions.len == 0 and condition.required_access_levels.len == 0) return error.InvalidCondition;
                for (condition.ip_subnetworks) |cidr| if (!validCidr(cidr)) return error.InvalidCondition;
                for (condition.members) |member| if (!validAccessMember(member)) return error.InvalidPrincipal;
                for (condition.regions) |region| if (region.len != 2 or !std.ascii.isUpper(region[0]) or !std.ascii.isUpper(region[1])) return error.InvalidCondition;
                for (condition.required_access_levels) |level| try validateOutputContains(level, "/accessLevels/");
            }
        },
    }
}

fn validatePerimeterConfig(config: ServicePerimeterConfig, perimeter_type: PerimeterType) BuildError!void {
    for (config.resources) |item| try validatePerimeterResourceOutput(item);
    for (config.restricted_services) |service| if (!validServiceName(service)) return error.InvalidService;
    for (config.access_levels) |level| try validateOutputContains(level, "/accessLevels/");
    for (config.vpc_accessible_services.allowed_services) |service| if (!std.mem.eql(u8, service, "RESTRICTED-SERVICES") and !validServiceName(service)) return error.InvalidService;
    if (!config.vpc_accessible_services.enabled and config.vpc_accessible_services.allowed_services.len != 0) return error.InvalidPerimeter;
    for (config.ingress_policies) |policy| try validateIngressPolicy(policy);
    for (config.egress_policies) |policy| try validateEgressPolicy(policy);
    if (perimeter_type == .bridge and (config.restricted_services.len != 0 or config.access_levels.len != 0 or config.ingress_policies.len != 0 or config.egress_policies.len != 0 or config.vpc_accessible_services.enabled)) return error.InvalidPerimeter;
}

fn validateIngressPolicy(policy: IngressPolicy) BuildError!void {
    for (policy.source_resources) |item| if (!validPerimeterResource(item)) return error.InvalidResource;
    for (policy.source_access_levels) |level| try validateOutputContains(level, "/accessLevels/");
    for (policy.identities) |identity| if (!validAccessMember(identity)) return error.InvalidPrincipal;
    for (policy.target_resources) |item| if (!std.mem.eql(u8, item, "*") and !canonicalProjectName(item)) return error.InvalidResource;
    try validateOperations(policy.operations);
    for (policy.roles) |role| if (!std.mem.startsWith(u8, role, "roles/")) return error.InvalidPrincipal;
    if (policy.identity_type != null and policy.identities.len != 0) return error.InvalidPerimeter;
}

fn validateEgressPolicy(policy: EgressPolicy) BuildError!void {
    for (policy.identities) |identity| if (!validAccessMember(identity)) return error.InvalidPrincipal;
    for (policy.target_resources) |item| if (!std.mem.eql(u8, item, "*") and !canonicalProjectName(item)) return error.InvalidResource;
    try validateOperations(policy.operations);
    if (policy.identity_type != null and policy.identities.len != 0) return error.InvalidPerimeter;
}

fn validateOperations(operations: []const ApiOperation) BuildError!void {
    for (operations) |operation| {
        if (!std.mem.eql(u8, operation.service, "*") and !validServiceName(operation.service)) return error.InvalidService;
        if (operation.methods.len == 0 and operation.permissions.len == 0) return error.InvalidPerimeter;
        for (operation.methods) |method| if (method.len == 0) return error.InvalidPerimeter;
        for (operation.permissions) |permission| if (std.mem.indexOfScalar(u8, permission, '.') == null) return error.InvalidPerimeter;
    }
}

fn validatePurpose(purpose: TagPurpose, data: []const config_mod.Label) BuildError!void {
    switch (purpose) {
        .unspecified, .data_governance => if (data.len != 0) return error.InvalidPurpose,
        .gce_firewall => {
            if (data.len != 1 or !std.mem.eql(u8, data[0].key, "network") or data[0].value.len == 0) return error.InvalidPurpose;
        },
    }
}

fn validateHierarchyOutput(selected: output.Output([]const u8, .public)) BuildError!void {
    switch (selected) {
        .value => |known| if (!canonicalOrganization(known) and !canonicalFolder(known) and !canonicalProjectName(known)) return error.InvalidParent,
        .resource_ref => {},
        .unknown_reason => return error.OutputNotKnown,
    }
}

fn validateOrganizationOutput(selected: output.Output([]const u8, .public)) BuildError!void {
    return validateOutputPrefix(selected, "organizations/");
}

fn validateTagKeyParentOutput(selected: output.Output([]const u8, .public)) BuildError!void {
    switch (selected) {
        .value => |known| if (!canonicalOrganization(known) and !canonicalProjectName(known)) return error.InvalidParent,
        .resource_ref => {},
        .unknown_reason => return error.OutputNotKnown,
    }
}

fn validateProjectOrFolderOutput(selected: output.Output([]const u8, .public)) BuildError!void {
    switch (selected) {
        .value => |known| if (!canonicalFolder(known) and !canonicalProjectName(known)) return error.InvalidParent,
        .resource_ref => {},
        .unknown_reason => return error.OutputNotKnown,
    }
}

fn validateFullResourceOutput(selected: output.Output([]const u8, .public)) BuildError!void {
    switch (selected) {
        .value => |known| if (!validFullResourceName(known)) return error.InvalidParent,
        .resource_ref => {},
        .unknown_reason => return error.OutputNotKnown,
    }
}

fn validatePerimeterResourceOutput(selected: output.Output([]const u8, .public)) BuildError!void {
    switch (selected) {
        .value => |known| if (!validPerimeterResource(known)) return error.InvalidResource,
        .resource_ref => {},
        .unknown_reason => return error.OutputNotKnown,
    }
}

fn validateOutputPrefix(selected: output.Output([]const u8, .public), prefix: []const u8) BuildError!void {
    switch (selected) {
        .value => |known| if (!std.mem.startsWith(u8, known, prefix) or known.len == prefix.len) return error.InvalidParent,
        .resource_ref => {},
        .unknown_reason => return error.OutputNotKnown,
    }
}

fn validateOutputContains(selected: output.Output([]const u8, .public), needle: []const u8) BuildError!void {
    switch (selected) {
        .value => |known| if (std.mem.indexOf(u8, known, needle) == null) return error.InvalidAccessLevel,
        .resource_ref => {},
        .unknown_reason => return error.OutputNotKnown,
    }
}

fn validateLogicalName(name: []const u8) BuildError!void {
    if (name.len == 0 or name.len > 80) return error.InvalidName;
    for (name) |char| if (!std.ascii.isAlphanumeric(char) and char != '-' and char != '_') return error.InvalidName;
}

fn validConstraint(candidate: []const u8) bool {
    if (candidate.len == 0 or candidate.len > 200) return false;
    for (candidate) |char| if (!std.ascii.isAlphanumeric(char) and char != '.' and char != '_' and char != '-') return false;
    return true;
}

fn validCustomConstraint(candidate: []const u8) bool {
    return std.mem.startsWith(u8, candidate, "custom.") and candidate.len > "custom.".len and validConstraint(candidate);
}

fn validResourceType(candidate: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, candidate, '/') orelse return false;
    return validServiceName(candidate[0..slash]) and slash + 1 < candidate.len and std.ascii.isUpper(candidate[slash + 1]);
}

fn validTagShortName(candidate: []const u8) bool {
    if (candidate.len == 0 or candidate.len > 256 or !std.ascii.isAlphanumeric(candidate[0]) or !std.ascii.isAlphanumeric(candidate[candidate.len - 1])) return false;
    for (candidate) |char| if (!std.ascii.isAlphanumeric(char) and char != '-' and char != '_' and char != '.') return false;
    return true;
}

fn validAccessIdentifier(candidate: []const u8) bool {
    if (candidate.len == 0 or candidate.len > 50 or !std.ascii.isAlphabetic(candidate[0])) return false;
    for (candidate[1..]) |char| if (!std.ascii.isAlphanumeric(char) and char != '_') return false;
    return true;
}

fn validParameterName(candidate: []const u8) bool {
    if (candidate.len == 0 or !std.ascii.isAlphabetic(candidate[0])) return false;
    for (candidate[1..]) |char| if (!std.ascii.isAlphanumeric(char) and char != '_') return false;
    return true;
}

fn validServiceName(candidate: []const u8) bool {
    return std.mem.endsWith(u8, candidate, ".googleapis.com") and candidate.len > ".googleapis.com".len;
}

fn validFullResourceName(candidate: []const u8) bool {
    return std.mem.startsWith(u8, candidate, "//") and std.mem.indexOf(u8, candidate[2..], "/") != null and std.mem.indexOfAny(u8, candidate, "?# \t\r\n") == null;
}

fn validPerimeterResource(candidate: []const u8) bool {
    return canonicalProjectName(candidate) or (std.mem.startsWith(u8, candidate, "//compute.googleapis.com/projects/") and std.mem.indexOf(u8, candidate, "/global/networks/") != null);
}

fn validAccessMember(candidate: []const u8) bool {
    const prefixes = [_][]const u8{ "user:", "serviceAccount:" };
    for (prefixes) |prefix| if (std.mem.startsWith(u8, candidate, prefix)) {
        const email = candidate[prefix.len..];
        return email.len > 3 and std.mem.indexOfScalar(u8, email, '@') != null and std.mem.indexOfAny(u8, email, " \t\r\n") == null;
    };
    return false;
}

fn validCidr(candidate: []const u8) bool {
    const slash = std.mem.lastIndexOfScalar(u8, candidate, '/') orelse return false;
    const address = candidate[0..slash];
    const prefix = std.fmt.parseInt(u8, candidate[slash + 1 ..], 10) catch return false;
    if (std.mem.indexOfScalar(u8, address, ':') != null) {
        if (prefix > 128 or address.len < 2) return false;
        for (address) |char| if (!std.ascii.isHex(char) and char != ':' and char != '.') return false;
        return true;
    }
    if (prefix > 32) return false;
    var octets: [4]u8 = undefined;
    var iterator = std.mem.splitScalar(u8, address, '.');
    var count: usize = 0;
    while (iterator.next()) |part| {
        if (count == 4) return false;
        octets[count] = std.fmt.parseInt(u8, part, 10) catch return false;
        count += 1;
    }
    if (count != 4) return false;
    const raw = (@as(u32, octets[0]) << 24) | (@as(u32, octets[1]) << 16) | (@as(u32, octets[2]) << 8) | octets[3];
    const host_mask: u32 = if (prefix == 32)
        0
    else if (prefix == 0)
        std.math.maxInt(u32)
    else
        (@as(u32, 1) << @intCast(32 - prefix)) - 1;
    return (raw & host_mask) == 0;
}

fn canonicalOrganization(candidate: []const u8) bool {
    return canonicalNumeric(candidate, "organizations/");
}

fn canonicalFolder(candidate: []const u8) bool {
    return canonicalNumeric(candidate, "folders/");
}

fn canonicalProjectName(candidate: []const u8) bool {
    if (!std.mem.startsWith(u8, candidate, "projects/")) return false;
    const suffix = candidate["projects/".len..];
    if (suffix.len == 0) return false;
    for (suffix) |char| if (!std.ascii.isAlphanumeric(char) and char != '-') return false;
    return true;
}

fn canonicalNumeric(candidate: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, candidate, prefix) or candidate.len == prefix.len) return false;
    for (candidate[prefix.len..]) |char| if (!std.ascii.isDigit(char)) return false;
    return true;
}

fn validateUniqueStrings(items: []const []const u8) BuildError!void {
    for (items, 0..) |item, index| for (items[index + 1 ..]) |other| if (std.mem.eql(u8, item, other)) return error.DuplicateItem;
}

fn validateUniqueEnums(comptime T: type, items: []const T) BuildError!void {
    for (items, 0..) |item, index| for (items[index + 1 ..]) |other| if (item == other) return error.DuplicateItem;
}

fn methodTypeWire(method: MethodType) []const u8 {
    return switch (method) {
        .create => "CREATE",
        .update => "UPDATE",
        .remove_grant => "REMOVE_GRANT",
        .govern_tags => "GOVERN_TAGS",
    };
}

fn tagPurposeWire(purpose: TagPurpose) []const u8 {
    return switch (purpose) {
        .unspecified => "PURPOSE_UNSPECIFIED",
        .gce_firewall => "GCE_FIREWALL",
        .data_governance => "DATA_GOVERNANCE",
    };
}

fn identityTypeWire(identity: IdentityType) []const u8 {
    return switch (identity) {
        .any_identity => "ANY_IDENTITY",
        .any_user_account => "ANY_USER_ACCOUNT",
        .any_service_account => "ANY_SERVICE_ACCOUNT",
    };
}
