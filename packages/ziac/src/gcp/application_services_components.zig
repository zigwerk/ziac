const std = @import("std");
const api_gateway = @import("api_gateway.zig");
const config_mod = @import("config.zig");
const identity = @import("identity_platform.zig");
const output = @import("../output.zig");
const parameter_manager = @import("parameter_manager.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");
const workflows = @import("workflows.zig");

pub const BuildError = workflows.BuildError || api_gateway.BuildError || identity.BuildError || parameter_manager.BuildError || resource.ResourceGraphError || error{
    DuplicateIamMember,
    DuplicateProvider,
    DuplicateVersion,
    InvalidComponentName,
    MissingVersion,
};

pub const WorkflowProgramArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    location: ?[]const u8 = null,
    source_contents: []const u8,
    service_account: output.Output([]const u8, .public),
    kms_key: ?output.Output([]const u8, .public) = null,
    call_log_level: workflows.CallLogLevel = .errors_only,
    execution_history: workflows.ExecutionHistory = .disabled,
    labels: []const config_mod.Label = &.{},
    user_env: []const workflows.EnvironmentVariable = &.{},
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const WorkflowProgram = struct {
    graph: resource.ResourceGraph,
    name: output.Output([]const u8, .public),
    revision_id: output.Output([]const u8, .public),
    state: output.Output([]const u8, .public),

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: WorkflowProgramArgs) BuildError!WorkflowProgram {
        try validateComponentName(args.name);
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);
        const index = graph.resources.items.len;
        var workflow = try workflows.Workflow.build(allocator, provider, .{
            .workflow_id = args.name,
            .location = args.location,
            .source_contents = args.source_contents,
            .service_account = args.service_account,
            .kms_key = args.kms_key,
            .call_log_level = args.call_log_level,
            .execution_history = args.execution_history,
            .labels = args.labels,
            .user_env = args.user_env,
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
        });
        defer workflow.deinit(allocator);
        try graph.addResource(workflow.node);
        try graph.validateAcyclic();
        const id = graph.resources.items[index].id;
        return .{
            .graph = graph,
            .name = workflows.Workflow.Outputs.Name.fromResource(id),
            .revision_id = workflows.Workflow.Outputs.RevisionId.fromResource(id),
            .state = workflows.Workflow.Outputs.State.fromResource(id),
        };
    }

    pub fn deinit(self: *WorkflowProgram) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

pub const ApiManagementMember = struct {
    name: []const u8,
    role: []const u8,
    member: []const u8,
};

pub const ManagedApiGatewayArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    api_id: []const u8,
    config_id: []const u8,
    gateway_id: []const u8,
    location: ?[]const u8 = null,
    document: api_gateway.Document,
    display_name: []const u8 = "",
    gateway_service_account: []const u8 = "",
    labels: []const config_mod.Label = &.{},
    management_members: []const ApiManagementMember = &.{},
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const ManagedApiGateway = struct {
    graph: resource.ResourceGraph,
    api_name: output.Output([]const u8, .public),
    config_name: output.Output([]const u8, .public),
    gateway_name: output.Output([]const u8, .public),
    default_hostname: output.Output([]const u8, .public),

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ManagedApiGatewayArgs) BuildError!ManagedApiGateway {
        try validateComponentName(args.name);
        for (args.management_members, 0..) |member, index| for (args.management_members[index + 1 ..]) |other| if (std.mem.eql(u8, member.name, other.name)) return error.DuplicateIamMember;
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);

        const api_index = graph.resources.items.len;
        var api = try api_gateway.Api.build(allocator, provider, .{ .api_id = args.api_id, .display_name = args.display_name, .labels = args.labels, .protect = args.protect, .retain_on_delete = args.retain_on_delete });
        defer api.deinit(allocator);
        try graph.addResource(api.node);
        const api_name = api_gateway.Api.Outputs.Name.fromResource(graph.resources.items[api_index].id);

        const config_index = graph.resources.items.len;
        var api_config = try api_gateway.ApiConfig.build(allocator, provider, .{
            .api = api_name,
            .api_id = args.api_id,
            .config_id = args.config_id,
            .display_name = args.display_name,
            .documents = &.{args.document},
            .labels = args.labels,
            .gateway_service_account = args.gateway_service_account,
            .retain_on_delete = args.retain_on_delete,
        });
        defer api_config.deinit(allocator);
        try graph.addResource(api_config.node);
        const config_name = api_gateway.ApiConfig.Outputs.Name.fromResource(graph.resources.items[config_index].id);

        const gateway_index = graph.resources.items.len;
        var gateway = try api_gateway.Gateway.build(allocator, provider, .{
            .gateway_id = args.gateway_id,
            .location = args.location,
            .api_config = config_name,
            .api_id = args.api_id,
            .config_id = args.config_id,
            .display_name = args.display_name,
            .labels = args.labels,
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
        });
        defer gateway.deinit(allocator);
        try graph.addResource(gateway.node);
        const gateway_id = graph.resources.items[gateway_index].id;
        const gateway_name = api_gateway.Gateway.Outputs.Name.fromResource(gateway_id);
        const location = args.location orelse provider.primary_region;

        for (args.management_members) |spec| {
            var member = try api_gateway.GatewayIamMember.build(allocator, provider, .{
                .name = spec.name,
                .resource_name = gateway_name,
                .location = location,
                .gateway_id = args.gateway_id,
                .role = spec.role,
                .member = spec.member,
            });
            defer member.deinit(allocator);
            try graph.addResource(member.node);
        }
        try graph.validateAcyclic();
        return .{
            .graph = graph,
            .api_name = api_name,
            .config_name = config_name,
            .gateway_name = gateway_name,
            .default_hostname = api_gateway.Gateway.Outputs.DefaultHostname.fromResource(gateway_id),
        };
    }

    pub fn deinit(self: *ManagedApiGateway) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

pub const Realm = union(enum) {
    project: ?identity.ProjectConfigArgs,
    tenant: identity.TenantArgs,
};

pub const OidcProviderSpec = struct {
    provider_id: []const u8,
    display_name: []const u8,
    issuer: []const u8,
    client_id: []const u8,
    client_secret: output.Output(value.SecretReference, .secret),
    enabled: bool = true,
};

pub const SamlProviderSpec = struct {
    provider_id: []const u8,
    display_name: []const u8,
    idp_entity_id: []const u8,
    sso_url: []const u8,
    idp_certificates: []const []const u8,
    sp_entity_id: []const u8,
    callback_uri: []const u8,
    sp_private_key: output.Output(value.SecretReference, .secret),
    enabled: bool = true,
};

pub const IdentityRealmArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    realm: Realm,
    oidc_providers: []const OidcProviderSpec = &.{},
    saml_providers: []const SamlProviderSpec = &.{},
};

pub const IdentityRealm = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    realm_name: output.Output([]const u8, .public),
    owned_realm_name: ?[]u8,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: IdentityRealmArgs) BuildError!IdentityRealm {
        try validateComponentName(args.name);
        try validateProviderUniqueness(args.oidc_providers, args.saml_providers);
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);

        var realm_name: output.Output([]const u8, .public) = undefined;
        var owned_realm_name: ?[]u8 = null;
        errdefer if (owned_realm_name) |owned| allocator.free(owned);
        switch (args.realm) {
            .project => |maybe_config| {
                if (maybe_config) |config_args| {
                    const index = graph.resources.items.len;
                    var config = try identity.ProjectConfig.build(allocator, provider, config_args);
                    defer config.deinit(allocator);
                    try graph.addResource(config.node);
                    realm_name = identity.ProjectConfig.Outputs.Name.fromResource(graph.resources.items[index].id);
                } else {
                    owned_realm_name = try std.fmt.allocPrint(allocator, "projects/{s}/config", .{provider.project_id});
                    realm_name = output.PublicOutput([]const u8).known(owned_realm_name.?);
                }
                for (args.oidc_providers) |spec| {
                    var idp = try identity.ProjectOAuthIdpConfig.build(allocator, provider, .{ .provider_id = spec.provider_id, .display_name = spec.display_name, .issuer = spec.issuer, .client_id = spec.client_id, .client_secret = spec.client_secret, .enabled = spec.enabled });
                    defer idp.deinit(allocator);
                    try graph.addResource(idp.node);
                }
                for (args.saml_providers) |spec| {
                    var idp = try identity.ProjectInboundSamlConfig.build(allocator, provider, .{ .provider_id = spec.provider_id, .display_name = spec.display_name, .idp_entity_id = spec.idp_entity_id, .sso_url = spec.sso_url, .idp_certificates = spec.idp_certificates, .sp_entity_id = spec.sp_entity_id, .callback_uri = spec.callback_uri, .sp_private_key = spec.sp_private_key, .enabled = spec.enabled });
                    defer idp.deinit(allocator);
                    try graph.addResource(idp.node);
                }
            },
            .tenant => |tenant_args| {
                const index = graph.resources.items.len;
                var tenant = try identity.Tenant.build(allocator, provider, tenant_args);
                defer tenant.deinit(allocator);
                try graph.addResource(tenant.node);
                realm_name = identity.Tenant.Outputs.Name.fromResource(graph.resources.items[index].id);
                for (args.oidc_providers) |spec| {
                    var idp = try identity.TenantOAuthIdpConfig.build(allocator, provider, .{ .tenant = realm_name, .tenant_id = tenant_args.tenant_id, .provider_id = spec.provider_id, .display_name = spec.display_name, .issuer = spec.issuer, .client_id = spec.client_id, .client_secret = spec.client_secret, .enabled = spec.enabled });
                    defer idp.deinit(allocator);
                    try graph.addResource(idp.node);
                }
                for (args.saml_providers) |spec| {
                    var idp = try identity.TenantInboundSamlConfig.build(allocator, provider, .{ .tenant = realm_name, .tenant_id = tenant_args.tenant_id, .provider_id = spec.provider_id, .display_name = spec.display_name, .idp_entity_id = spec.idp_entity_id, .sso_url = spec.sso_url, .idp_certificates = spec.idp_certificates, .sp_entity_id = spec.sp_entity_id, .callback_uri = spec.callback_uri, .sp_private_key = spec.sp_private_key, .enabled = spec.enabled });
                    defer idp.deinit(allocator);
                    try graph.addResource(idp.node);
                }
            },
        }
        try graph.validateAcyclic();
        return .{ .allocator = allocator, .graph = graph, .realm_name = realm_name, .owned_realm_name = owned_realm_name };
    }

    pub fn deinit(self: *IdentityRealm) void {
        self.graph.deinit();
        if (self.owned_realm_name) |owned| self.allocator.free(owned);
        self.* = undefined;
    }
};

pub const BundleTarget = union(enum) {
    parameter: parameter_manager.ParameterArgs,
    template: parameter_manager.TemplateArgs,
};

pub const VersionSpec = struct {
    version_id: []const u8,
    payload: output.Output(value.SecretReference, .secret),
    payload_sha256: []const u8,
    disabled: bool = false,
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const ParameterBundleArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    target: BundleTarget,
    versions: []const VersionSpec,
};

pub const ParameterBundle = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    name: output.Output([]const u8, .public),
    version_names: []output.Output([]const u8, .public),

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ParameterBundleArgs) BuildError!ParameterBundle {
        try validateComponentName(args.name);
        if (args.versions.len == 0) return error.MissingVersion;
        for (args.versions, 0..) |version, index| for (args.versions[index + 1 ..]) |other| if (std.mem.eql(u8, version.version_id, other.version_id)) return error.DuplicateVersion;
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);
        const parent_index = graph.resources.items.len;
        var parent_name: output.Output([]const u8, .public) = undefined;
        var parent_id: []const u8 = undefined;
        var location: []const u8 = undefined;
        switch (args.target) {
            .parameter => |spec| {
                var parent = try parameter_manager.Parameter.build(allocator, provider, spec);
                defer parent.deinit(allocator);
                try graph.addResource(parent.node);
                parent_name = parameter_manager.Parameter.Outputs.Name.fromResource(graph.resources.items[parent_index].id);
                parent_id = spec.parameter_id;
                location = spec.location;
            },
            .template => |spec| {
                var parent = try parameter_manager.Template.build(allocator, provider, spec);
                defer parent.deinit(allocator);
                try graph.addResource(parent.node);
                parent_name = parameter_manager.Template.Outputs.Name.fromResource(graph.resources.items[parent_index].id);
                parent_id = spec.template_id;
                location = spec.location;
            },
        }
        const version_names = try allocator.alloc(output.Output([]const u8, .public), args.versions.len);
        errdefer allocator.free(version_names);
        for (args.versions, 0..) |version, index| {
            const resource_index = graph.resources.items.len;
            switch (args.target) {
                .parameter => {
                    var built = try parameter_manager.ParameterVersion.build(allocator, provider, .{ .parameter = parent_name, .parameter_id = parent_id, .version_id = version.version_id, .location = location, .payload = version.payload, .payload_sha256 = version.payload_sha256, .disabled = version.disabled, .protect = version.protect, .retain_on_delete = version.retain_on_delete });
                    defer built.deinit(allocator);
                    try graph.addResource(built.node);
                    version_names[index] = parameter_manager.ParameterVersion.Outputs.Name.fromResource(graph.resources.items[resource_index].id);
                },
                .template => {
                    var built = try parameter_manager.TemplateVersion.build(allocator, provider, .{ .template = parent_name, .template_id = parent_id, .version_id = version.version_id, .location = location, .payload = version.payload, .payload_sha256 = version.payload_sha256, .disabled = version.disabled, .protect = version.protect, .retain_on_delete = version.retain_on_delete });
                    defer built.deinit(allocator);
                    try graph.addResource(built.node);
                    version_names[index] = parameter_manager.TemplateVersion.Outputs.Name.fromResource(graph.resources.items[resource_index].id);
                },
            }
        }
        try graph.validateAcyclic();
        return .{ .allocator = allocator, .graph = graph, .name = parent_name, .version_names = version_names };
    }

    pub fn deinit(self: *ParameterBundle) void {
        self.graph.deinit();
        self.allocator.free(self.version_names);
        self.* = undefined;
    }
};

fn validateComponentName(name: []const u8) BuildError!void {
    if (name.len == 0 or name.len > 63 or std.mem.indexOfAny(u8, name, "\x00\r\n /\\") != null) return error.InvalidComponentName;
}

fn validateProviderUniqueness(oidc: []const OidcProviderSpec, saml: []const SamlProviderSpec) BuildError!void {
    for (oidc, 0..) |provider, index| {
        for (oidc[index + 1 ..]) |other| if (std.mem.eql(u8, provider.provider_id, other.provider_id)) return error.DuplicateProvider;
        for (saml) |other| if (std.mem.eql(u8, provider.provider_id, other.provider_id)) return error.DuplicateProvider;
    }
    for (saml, 0..) |provider, index| for (saml[index + 1 ..]) |other| if (std.mem.eql(u8, provider.provider_id, other.provider_id)) return error.DuplicateProvider;
}
