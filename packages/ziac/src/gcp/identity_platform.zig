const std = @import("std");
const config_mod = @import("config.zig");
const iam = @import("iam.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || resource.ResourceGraphError || std.mem.Allocator.Error || error{
    DuplicateAuthorizedDomain,
    InvalidAuthorizedDomain,
    InvalidCallbackUri,
    InvalidCertificate,
    InvalidCondition,
    InvalidDisplayName,
    InvalidIssuer,
    InvalidMember,
    InvalidProviderId,
    InvalidRole,
    InvalidTenant,
    InvalidTenantId,
    OutputNotKnown,
};

pub const MfaState = enum {
    disabled,
    enabled,
    mandatory,

    pub fn apiName(self: MfaState) []const u8 {
        return switch (self) {
            .disabled => "DISABLED",
            .enabled => "ENABLED",
            .mandatory => "MANDATORY",
        };
    }
};

pub const ProjectConfigArgs = struct {
    authorized_domains: []const []const u8 = &.{},
    email_privacy: bool = true,
    allow_duplicate_emails: bool = false,
    multi_tenant: bool = false,
    mfa_state: MfaState = .disabled,
    monitoring_request_logging: bool = true,
};

pub const ProjectConfig = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    etag: Outputs.Etag.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ProjectConfigArgs) BuildError!ProjectConfig {
        try provider.validate();
        var domains = try stringListValueAlloc(allocator, args.authorized_domains, validateDomain);
        defer domains.deinit(allocator);
        for (args.authorized_domains, 0..) |domain, index| for (args.authorized_domains[0..index]) |previous| if (std.mem.eql(u8, domain, previous)) return error.DuplicateAuthorizedDomain;
        const fields = [_]value.Field{
            .{ .name = "allow_duplicate_emails", .value = .{ .boolean = args.allow_duplicate_emails } },
            .{ .name = "authorized_domains", .value = domains },
            .{ .name = "email_privacy", .value = .{ .boolean = args.email_privacy } },
            .{ .name = "mfa_state", .value = .{ .string = args.mfa_state.apiName() } },
            .{ .name = "monitoring_request_logging", .value = .{ .boolean = args.monitoring_request_logging } },
            .{ .name = "multi_tenant", .value = .{ .boolean = args.multi_tenant } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.identity.ProjectConfig.{s}", .{provider.project_id});
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.identity.ProjectConfig", provider.project_id, &fields, .{ .protect = true, .retain_on_delete = true });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .etag = Outputs.Etag.fromResource(node.id) };
    }

    pub fn deinit(self: *ProjectConfig, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const TenantArgs = struct {
    tenant_id: []const u8,
    display_name: []const u8,
    allow_password_signup: bool = true,
    email_link_signin: bool = false,
    disable_auth: bool = false,
    mfa_state: MfaState = .disabled,
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const Tenant = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    etag: Outputs.Etag.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: TenantArgs) BuildError!Tenant {
        try provider.validate();
        try validateTenantId(args.tenant_id);
        try validateDisplayName(args.display_name);
        const fields = [_]value.Field{
            .{ .name = "allow_password_signup", .value = .{ .boolean = args.allow_password_signup } },
            .{ .name = "disable_auth", .value = .{ .boolean = args.disable_auth } },
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "email_link_signin", .value = .{ .boolean = args.email_link_signin } },
            .{ .name = "mfa_state", .value = .{ .string = args.mfa_state.apiName() } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "tenant_id", .value = .{ .string = args.tenant_id } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.identity.Tenant.{s}", .{args.tenant_id});
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.identity.Tenant", args.tenant_id, &fields, .{ .protect = args.protect, .retain_on_delete = args.retain_on_delete });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .etag = Outputs.Etag.fromResource(node.id) };
    }

    pub fn deinit(self: *Tenant, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const ProjectOAuthIdpConfigArgs = struct {
    provider_id: []const u8,
    display_name: []const u8,
    issuer: []const u8,
    client_id: []const u8,
    client_secret: output.Output(value.SecretReference, .secret),
    enabled: bool = true,
};

pub const TenantOAuthIdpConfigArgs = struct {
    tenant: output.Output([]const u8, .public),
    tenant_id: []const u8,
    provider_id: []const u8,
    display_name: []const u8,
    issuer: []const u8,
    client_id: []const u8,
    client_secret: output.Output(value.SecretReference, .secret),
    enabled: bool = true,
};

pub const ProjectOAuthIdpConfig = OAuthResource("gcp.identity.ProjectOAuthIdpConfig", ProjectOAuthIdpConfigArgs, false);
pub const TenantOAuthIdpConfig = OAuthResource("gcp.identity.TenantOAuthIdpConfig", TenantOAuthIdpConfigArgs, true);

fn OAuthResource(comptime type_name: []const u8, comptime Args: type, comptime tenant_scope: bool) type {
    return struct {
        pub const Outputs = struct {
            pub const Name = output.Descriptor("name", []const u8, .public);
        };
        node: resource.ResourceNode,
        name: Outputs.Name.OutputType,

        pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: Args) BuildError!@This() {
            try provider.validate();
            try validateProviderId(args.provider_id, "oidc.");
            try validateDisplayName(args.display_name);
            if (!validHttpsUrl(args.issuer) or std.mem.endsWith(u8, args.issuer, "/")) return error.InvalidIssuer;
            if (args.client_id.len == 0 or args.client_id.len > 256 or std.mem.indexOfAny(u8, args.client_id, "\x00\r\n") != null) return error.InvalidProviderId;
            if (comptime tenant_scope) try validateTenantId(args.tenant_id);
            const tenant = if (comptime tenant_scope) try publicOutputValue(args.tenant) else value.Value{ .string = "" };
            if (comptime tenant_scope) if (tenant == .string and !validTenantName(tenant.string, provider.project_id, args.tenant_id)) return error.InvalidTenant;
            const fields = [_]value.Field{
                .{ .name = "client_id", .value = .{ .string = args.client_id } },
                .{ .name = "client_secret", .value = try secretOutputValue(args.client_secret) },
                .{ .name = "display_name", .value = .{ .string = args.display_name } },
                .{ .name = "enabled", .value = .{ .boolean = args.enabled } },
                .{ .name = "issuer", .value = .{ .string = args.issuer } },
                .{ .name = "project_id", .value = .{ .string = provider.project_id } },
                .{ .name = "provider_id", .value = .{ .string = args.provider_id } },
                .{ .name = "tenant", .value = tenant },
                .{ .name = "tenant_id", .value = .{ .string = if (comptime tenant_scope) args.tenant_id else "" } },
            };
            const id = if (comptime tenant_scope)
                try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ type_name, args.tenant_id, args.provider_id })
            else
                try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_name, args.provider_id });
            defer allocator.free(id);
            const node = try nodeOwned(allocator, id, type_name, args.provider_id, &fields, .{ .retain_on_delete = true });
            return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.node.deinit(allocator);
            self.* = undefined;
        }
    };
}

pub const ProjectInboundSamlConfigArgs = struct {
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

pub const TenantInboundSamlConfigArgs = struct {
    tenant: output.Output([]const u8, .public),
    tenant_id: []const u8,
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

pub const ProjectInboundSamlConfig = SamlResource("gcp.identity.ProjectInboundSamlConfig", ProjectInboundSamlConfigArgs, false);
pub const TenantInboundSamlConfig = SamlResource("gcp.identity.TenantInboundSamlConfig", TenantInboundSamlConfigArgs, true);

fn SamlResource(comptime type_name: []const u8, comptime Args: type, comptime tenant_scope: bool) type {
    return struct {
        pub const Outputs = struct {
            pub const Name = output.Descriptor("name", []const u8, .public);
        };
        node: resource.ResourceNode,
        name: Outputs.Name.OutputType,

        pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: Args) BuildError!@This() {
            try provider.validate();
            try validateProviderId(args.provider_id, "saml.");
            try validateDisplayName(args.display_name);
            if (!validHttpsUrl(args.sso_url) or args.idp_entity_id.len == 0 or args.sp_entity_id.len == 0) return error.InvalidIssuer;
            if (!validHttpsUrl(args.callback_uri)) return error.InvalidCallbackUri;
            if (args.idp_certificates.len == 0 or args.idp_certificates.len > 8) return error.InvalidCertificate;
            for (args.idp_certificates) |certificate| if (!validCertificate(certificate)) return error.InvalidCertificate;
            if (comptime tenant_scope) try validateTenantId(args.tenant_id);
            const tenant = if (comptime tenant_scope) try publicOutputValue(args.tenant) else value.Value{ .string = "" };
            if (comptime tenant_scope) if (tenant == .string and !validTenantName(tenant.string, provider.project_id, args.tenant_id)) return error.InvalidTenant;
            var certificates = try stringListValueAlloc(allocator, args.idp_certificates, validateCertificateValue);
            defer certificates.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "callback_uri", .value = .{ .string = args.callback_uri } },
                .{ .name = "display_name", .value = .{ .string = args.display_name } },
                .{ .name = "enabled", .value = .{ .boolean = args.enabled } },
                .{ .name = "idp_certificates", .value = certificates },
                .{ .name = "idp_entity_id", .value = .{ .string = args.idp_entity_id } },
                .{ .name = "project_id", .value = .{ .string = provider.project_id } },
                .{ .name = "provider_id", .value = .{ .string = args.provider_id } },
                .{ .name = "sp_entity_id", .value = .{ .string = args.sp_entity_id } },
                .{ .name = "sp_private_key", .value = try secretOutputValue(args.sp_private_key) },
                .{ .name = "sso_url", .value = .{ .string = args.sso_url } },
                .{ .name = "tenant", .value = tenant },
                .{ .name = "tenant_id", .value = .{ .string = if (comptime tenant_scope) args.tenant_id else "" } },
            };
            const id = if (comptime tenant_scope)
                try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ type_name, args.tenant_id, args.provider_id })
            else
                try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_name, args.provider_id });
            defer allocator.free(id);
            const node = try nodeOwned(allocator, id, type_name, args.provider_id, &fields, .{ .retain_on_delete = true });
            return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.node.deinit(allocator);
            self.* = undefined;
        }
    };
}

pub const TenantIamMemberArgs = struct {
    name: []const u8,
    tenant: output.Output([]const u8, .public),
    tenant_id: []const u8,
    role: []const u8,
    member: []const u8,
    condition: ?iam.Condition = null,
};

pub const TenantIamMember = struct {
    pub const Outputs = struct {
        pub const BindingId = output.Descriptor("binding_id", []const u8, .public);
    };
    node: resource.ResourceNode,
    binding_id: Outputs.BindingId.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: TenantIamMemberArgs) BuildError!TenantIamMember {
        try provider.validate();
        try validateTenantId(args.tenant_id);
        try validateRole(args.role);
        try validateMember(args.member);
        try validateCondition(args.condition);
        const fields = [_]value.Field{
            .{ .name = "condition_description", .value = .{ .string = if (args.condition) |item| item.description else "" } },
            .{ .name = "condition_expression", .value = .{ .string = if (args.condition) |item| item.expression else "" } },
            .{ .name = "condition_title", .value = .{ .string = if (args.condition) |item| item.title else "" } },
            .{ .name = "member", .value = .{ .string = args.member } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "ownership_mode", .value = .{ .string = "member" } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "role", .value = .{ .string = args.role } },
            .{ .name = "tenant", .value = try publicOutputValue(args.tenant) },
            .{ .name = "tenant_id", .value = .{ .string = args.tenant_id } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.identity.TenantIamMember.{s}.{s}", .{ args.tenant_id, args.name });
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.identity.TenantIamMember", args.name, &fields, .{});
        return .{ .node = node, .binding_id = Outputs.BindingId.fromResource(node.id) };
    }

    pub fn deinit(self: *TenantIamMember, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn validateTenantId(text: []const u8) BuildError!void {
    if (text.len == 0 or text.len > 64 or !std.ascii.isAlphanumeric(text[0]) or !std.ascii.isAlphanumeric(text[text.len - 1])) return error.InvalidTenantId;
    for (text) |character| if (!std.ascii.isAlphanumeric(character) and character != '-') return error.InvalidTenantId;
}

fn validateProviderId(text: []const u8, prefix: []const u8) BuildError!void {
    if (!std.mem.startsWith(u8, text, prefix) or text.len <= prefix.len or text.len > 128) return error.InvalidProviderId;
    for (text[prefix.len..]) |character| if (!std.ascii.isAlphanumeric(character) and character != '-' and character != '.' and character != '_') return error.InvalidProviderId;
}

fn validateDisplayName(text: []const u8) BuildError!void {
    if (text.len == 0 or text.len > 256 or std.mem.indexOfAny(u8, text, "\x00\r\n") != null) return error.InvalidDisplayName;
}

fn validateDomain(text: []const u8) BuildError!void {
    if (text.len == 0 or text.len > 253 or std.mem.indexOfAny(u8, text, "\x00\r\n /:") != null) return error.InvalidAuthorizedDomain;
}

fn validateCertificateValue(text: []const u8) BuildError!void {
    if (!validCertificate(text)) return error.InvalidCertificate;
}

fn validCertificate(text: []const u8) bool {
    return text.len <= 64 * 1024 and std.mem.startsWith(u8, text, "-----BEGIN CERTIFICATE-----") and std.mem.endsWith(u8, text, "-----END CERTIFICATE-----");
}

fn validHttpsUrl(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "https://") and text.len > "https://".len and std.mem.indexOfAny(u8, text, "\x00\r\n ") == null;
}

fn validTenantName(text: []const u8, project_id: []const u8, tenant_id: []const u8) bool {
    var expected_buffer: [512]u8 = undefined;
    const expected = std.fmt.bufPrint(&expected_buffer, "projects/{s}/tenants/{s}", .{ project_id, tenant_id }) catch return false;
    return std.mem.eql(u8, text, expected);
}

fn stringListValueAlloc(allocator: std.mem.Allocator, values: []const []const u8, validator: *const fn ([]const u8) BuildError!void) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, values.len);
    defer allocator.free(items);
    for (values, 0..) |item, index| {
        try validator(item);
        items[index] = .{ .string = item };
    }
    return value.Value.initOwned(allocator, .{ .list = items });
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
