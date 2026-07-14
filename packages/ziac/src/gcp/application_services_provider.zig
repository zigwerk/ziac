const std = @import("std");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const secret_mod = @import("../secret.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;

const supported_types = [_][]const u8{
    "gcp.apigateway.Api",
    "gcp.apigateway.ApiConfig",
    "gcp.apigateway.Gateway",
    "gcp.identity.ProjectConfig",
    "gcp.identity.ProjectInboundSamlConfig",
    "gcp.identity.ProjectOAuthIdpConfig",
    "gcp.identity.Tenant",
    "gcp.identity.TenantInboundSamlConfig",
    "gcp.identity.TenantOAuthIdpConfig",
    "gcp.parametermanager.Parameter",
    "gcp.parametermanager.ParameterVersion",
    "gcp.parametermanager.Template",
    "gcp.parametermanager.TemplateVersion",
    "gcp.workflows.Workflow",
};

const Kind = enum {
    workflow,
    api,
    api_config,
    gateway,
    project_config,
    tenant,
    project_oidc,
    project_saml,
    tenant_oidc,
    tenant_saml,
    parameter,
    parameter_version,
    template,
    template_version,
};

pub const Handler = struct {
    client: *client_mod.Client,
    operation_policy: operation.Policy = .{},
    secret_source: ?secret_mod.SecretSource = null,

    pub fn read(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
        if (context.operation_handle) |handle| {
            const response = try self.waitOperationResponseAlloc(context, node, handle);
            defer context.allocator.free(response);
            return .{ .present = try resultFromJson(context, node, response) };
        }
        const expected = try physicalIdAlloc(context.allocator, node);
        defer context.allocator.free(expected);
        const physical = physical_override orelse expected;
        if (!std.mem.eql(u8, expected, physical)) return error.InvalidConfiguration;
        const path = try resourcePathAlloc(context.allocator, node, physical);
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = apiFor(node), .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try resultFromJson(context, node, response.body) };
    }

    pub fn diff(context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash)) return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        const replacement = identityChanged(node, observed.observed_inputs) or kindOf(node) == .api_config or kindOf(node) == .parameter_version or kindOf(node) == .template_version;
        return provider_mod.DiffResult.init(
            context.allocator,
            if (replacement) .replace else .update,
            &.{if (replacement) "immutable application-service identity or content changed" else "remote application-service configuration differs"},
        );
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        var body = try self.bodyAlloc(context, node, null);
        defer body.deinit(context.allocator);
        const path = try createPathAlloc(context.allocator, node);
        defer context.allocator.free(path);
        const method: []const u8 = if (kindOf(node) == .project_config) "PATCH" else "POST";
        if (usesLongRunningOperation(node)) {
            const handle = try self.startOperation(context, node, method, path, body.bytes);
            defer context.allocator.free(handle);
            return pendingResult(context, node, handle);
        }
        var response = try self.request(context, .{ .api = apiFor(node), .method = method, .path = path, .body = body.bytes });
        defer response.deinit(context.allocator);
        return resultFromJson(context, node, response.body);
    }

    pub fn update(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        if (kindOf(node) == .api_config or kindOf(node) == .parameter_version or kindOf(node) == .template_version) return error.InvalidConfiguration;
        var body = try self.bodyAlloc(context, node, outputString(observed, "etag"));
        defer body.deinit(context.allocator);
        const path = try updatePathAlloc(context.allocator, node, observed.physical_id);
        defer context.allocator.free(path);
        if (usesLongRunningOperation(node)) {
            const handle = try self.startOperation(context, node, "PATCH", path, body.bytes);
            defer context.allocator.free(handle);
            return pendingResult(context, node, handle);
        }
        var response = try self.request(context, .{ .api = apiFor(node), .method = "PATCH", .path = path, .body = body.bytes });
        defer response.deinit(context.allocator);
        return resultFromJson(context, node, response.body);
    }

    pub fn delete(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!void {
        if (kindOf(node) == .project_config) return error.InvalidConfiguration;
        const expected = try physicalIdAlloc(context.allocator, node);
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        const path = try deletePathAlloc(context.allocator, node, physical_id);
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = apiFor(node), .method = "DELETE", .path = path }) catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer response.deinit(context.allocator);
        if (!usesLongRunningOperation(node) or response.body.len == 0) return;
        const handle = try operationNameAlloc(context.allocator, response.body);
        defer context.allocator.free(handle);
        const completed = try self.waitOperationResponseAlloc(context, node, handle);
        context.allocator.free(completed);
    }

    pub fn importResource(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!provider_mod.ResourceResult {
        var read_result = try self.read(context, node, physical_id);
        defer read_result.deinit();
        return switch (read_result) {
            .absent => error.NotFound,
            .present => |present| present.clone(context.allocator) catch error.OutOfMemory,
        };
    }

    fn startOperation(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, method: []const u8, path: []const u8, body: []const u8) ProviderError![]const u8 {
        var response = try self.request(context, .{ .api = apiFor(node), .method = method, .path = path, .body = body });
        defer response.deinit(context.allocator);
        return operationNameAlloc(context.allocator, response.body);
    }

    fn waitOperationResponseAlloc(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, handle: []const u8) ProviderError![]const u8 {
        const endpoint = self.client.endpoints.get(apiFor(node));
        const base = try std.fmt.allocPrint(context.allocator, "{s}/v1", .{std.mem.trimEnd(u8, endpoint, "/")});
        defer context.allocator.free(base);
        var target = operation.Target.genericAlloc(context.allocator, base, handle) catch return error.OutOfMemory;
        defer target.deinit(context.allocator);
        var completed = try operation.waitAlloc(self.client, context, target, self.operation_policy);
        defer completed.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, completed.payload, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const root = jsonObject(parsed.value) orelse return error.ProviderBug;
        const response = root.get("response") orelse return error.ProviderBug;
        return std.json.Stringify.valueAlloc(context.allocator, response, .{}) catch error.OutOfMemory;
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, request_value: client_mod.Request) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, request_value, &diagnostic);
    }

    fn bodyAlloc(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, etag: ?[]const u8) ProviderError!SensitiveBody {
        var arena_state = std.heap.ArenaAllocator.init(context.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var root: std.json.ObjectMap = .empty;
        var sensitive = false;
        switch (kindOf(node)) {
            .workflow => {
                try root.put(arena, "sourceContents", .{ .string = try requiredString(node.inputs, "source_contents") });
                try root.put(arena, "serviceAccount", .{ .string = try resolveString(context, try requiredValue(node.inputs, "service_account")) });
                try root.put(arena, "callLogLevel", .{ .string = try requiredString(node.inputs, "call_log_level") });
                try root.put(arena, "executionHistoryLevel", .{ .string = try requiredString(node.inputs, "execution_history") });
                try putStringMap(arena, &root, "labels", try requiredValue(node.inputs, "labels"));
                try putEnvMap(arena, &root, try requiredValue(node.inputs, "user_env"));
                const kms = try resolveString(context, try requiredValue(node.inputs, "kms_key"));
                if (kms.len > 0) try root.put(arena, "cryptoKeyName", .{ .string = kms });
            },
            .api => try putDisplayLabels(arena, &root, node),
            .api_config => {
                try putDisplayLabels(arena, &root, node);
                var documents = std.json.Array.init(arena);
                for (try requiredList(node.inputs, "documents")) |document_value| {
                    const reference = try resolveSecret(context, try requiredValue(document_value, "contents"));
                    const source = self.secret_source orelse return error.AuthorizationFailed;
                    var payload = try source.resolve(context, context.allocator, reference);
                    defer payload.deinit();
                    try verifyPayloadDigest(payload.bytes, try requiredString(document_value, "sha256"));
                    const encoded = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(payload.bytes.len));
                    _ = std.base64.standard.Encoder.encode(encoded, payload.bytes);
                    var document: std.json.ObjectMap = .empty;
                    try document.put(arena, "path", .{ .string = try requiredString(document_value, "path") });
                    try document.put(arena, "contents", .{ .string = encoded });
                    var wrapper: std.json.ObjectMap = .empty;
                    try wrapper.put(arena, "document", .{ .object = document });
                    try documents.append(.{ .object = wrapper });
                    sensitive = true;
                }
                try root.put(arena, "openapiDocuments", .{ .array = documents });
                const account = try requiredString(node.inputs, "gateway_service_account");
                if (account.len > 0) {
                    var config: std.json.ObjectMap = .empty;
                    try config.put(arena, "gatewayServiceAccount", .{ .string = account });
                    try root.put(arena, "gatewayConfig", .{ .object = config });
                }
            },
            .gateway => {
                try putDisplayLabels(arena, &root, node);
                try root.put(arena, "apiConfig", .{ .string = try resolveString(context, try requiredValue(node.inputs, "api_config")) });
            },
            .project_config => {
                var sign_in: std.json.ObjectMap = .empty;
                var email: std.json.ObjectMap = .empty;
                try email.put(arena, "enabled", .{ .bool = true });
                try sign_in.put(arena, "email", .{ .object = email });
                try sign_in.put(arena, "allowDuplicateEmails", .{ .bool = try requiredBool(node.inputs, "allow_duplicate_emails") });
                try root.put(arena, "signIn", .{ .object = sign_in });
                try root.put(arena, "authorizedDomains", try valueListToJson(arena, try requiredList(node.inputs, "authorized_domains")));
                try root.put(arena, "emailPrivacyConfig", .{ .object = try boolObject(arena, "enableImprovedEmailPrivacy", try requiredBool(node.inputs, "email_privacy")) });
                try root.put(arena, "multiTenant", .{ .object = try boolObject(arena, "allowTenants", try requiredBool(node.inputs, "multi_tenant")) });
                try root.put(arena, "mfa", .{ .object = try stringObject(arena, "state", try requiredString(node.inputs, "mfa_state")) });
                try root.put(arena, "monitoring", .{ .object = try boolObject(arena, "requestLogging", try requiredBool(node.inputs, "monitoring_request_logging")) });
            },
            .tenant => {
                try root.put(arena, "displayName", .{ .string = try requiredString(node.inputs, "display_name") });
                try root.put(arena, "disableAuth", .{ .bool = try requiredBool(node.inputs, "disable_auth") });
                var email: std.json.ObjectMap = .empty;
                try email.put(arena, "enabled", .{ .bool = try requiredBool(node.inputs, "allow_password_signup") });
                try email.put(arena, "passwordRequired", .{ .bool = !try requiredBool(node.inputs, "email_link_signin") });
                var sign_in: std.json.ObjectMap = .empty;
                try sign_in.put(arena, "email", .{ .object = email });
                try root.put(arena, "signInConfig", .{ .object = sign_in });
                try root.put(arena, "mfaConfig", .{ .object = try stringObject(arena, "state", try requiredString(node.inputs, "mfa_state")) });
            },
            .project_oidc, .tenant_oidc => {
                try root.put(arena, "displayName", .{ .string = try requiredString(node.inputs, "display_name") });
                try root.put(arena, "enabled", .{ .bool = try requiredBool(node.inputs, "enabled") });
                try root.put(arena, "issuer", .{ .string = try requiredString(node.inputs, "issuer") });
                try root.put(arena, "clientId", .{ .string = try requiredString(node.inputs, "client_id") });
                const reference = try resolveSecret(context, try requiredValue(node.inputs, "client_secret"));
                const source = self.secret_source orelse return error.AuthorizationFailed;
                var payload = try source.resolve(context, context.allocator, reference);
                defer payload.deinit();
                try root.put(arena, "clientSecret", .{ .string = try arena.dupe(u8, payload.bytes) });
                sensitive = true;
            },
            .project_saml, .tenant_saml => {
                try root.put(arena, "displayName", .{ .string = try requiredString(node.inputs, "display_name") });
                try root.put(arena, "enabled", .{ .bool = try requiredBool(node.inputs, "enabled") });
                var idp: std.json.ObjectMap = .empty;
                try idp.put(arena, "idpEntityId", .{ .string = try requiredString(node.inputs, "idp_entity_id") });
                try idp.put(arena, "ssoUrl", .{ .string = try requiredString(node.inputs, "sso_url") });
                try idp.put(arena, "idpCertificates", try valueListToJson(arena, try requiredList(node.inputs, "idp_certificates")));
                try root.put(arena, "idpConfig", .{ .object = idp });
                var sp: std.json.ObjectMap = .empty;
                try sp.put(arena, "spEntityId", .{ .string = try requiredString(node.inputs, "sp_entity_id") });
                try sp.put(arena, "callbackUri", .{ .string = try requiredString(node.inputs, "callback_uri") });
                const reference = try resolveSecret(context, try requiredValue(node.inputs, "sp_private_key"));
                const source = self.secret_source orelse return error.AuthorizationFailed;
                var payload = try source.resolve(context, context.allocator, reference);
                defer payload.deinit();
                try sp.put(arena, "spPrivateKey", .{ .string = try arena.dupe(u8, payload.bytes) });
                try root.put(arena, "spConfig", .{ .object = sp });
                sensitive = true;
            },
            .parameter, .template => {
                try root.put(arena, "format", .{ .string = try requiredString(node.inputs, "format") });
                try putLabelsText(arena, &root, try requiredString(node.inputs, "labels"));
                const kms = try resolveString(context, try requiredValue(node.inputs, "kms_key"));
                if (kms.len > 0) try root.put(arena, "kmsKey", .{ .string = kms });
            },
            .parameter_version, .template_version => {
                try root.put(arena, "disabled", .{ .bool = try requiredBool(node.inputs, "disabled") });
                const reference = try resolveSecret(context, try requiredValue(node.inputs, "payload"));
                const source = self.secret_source orelse return error.AuthorizationFailed;
                var payload = try source.resolve(context, context.allocator, reference);
                defer payload.deinit();
                try verifyPayloadDigest(payload.bytes, try requiredString(node.inputs, "payload_sha256"));
                const encoded = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(payload.bytes.len));
                _ = std.base64.standard.Encoder.encode(encoded, payload.bytes);
                var payload_object: std.json.ObjectMap = .empty;
                try payload_object.put(arena, "data", .{ .string = encoded });
                try root.put(arena, "payload", .{ .object = payload_object });
                sensitive = true;
            },
        }
        if (etag) |present| try root.put(arena, "etag", .{ .string = present });
        const bytes = std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch return error.OutOfMemory;
        return .{ .bytes = bytes, .sensitive = sensitive };
    }
};

fn verifyPayloadDigest(bytes: []const u8, expected: []const u8) ProviderError!void {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &actual, expected)) return error.InvalidConfiguration;
}

pub fn supports(node: resource.ResourceNode) bool {
    for (supported_types) |type_name| if (std.mem.eql(u8, node.type_name, type_name)) return true;
    return false;
}

fn kindOf(node: resource.ResourceNode) Kind {
    const name = node.type_name;
    if (std.mem.eql(u8, name, "gcp.workflows.Workflow")) return .workflow;
    if (std.mem.eql(u8, name, "gcp.apigateway.Api")) return .api;
    if (std.mem.eql(u8, name, "gcp.apigateway.ApiConfig")) return .api_config;
    if (std.mem.eql(u8, name, "gcp.apigateway.Gateway")) return .gateway;
    if (std.mem.eql(u8, name, "gcp.identity.ProjectConfig")) return .project_config;
    if (std.mem.eql(u8, name, "gcp.identity.Tenant")) return .tenant;
    if (std.mem.eql(u8, name, "gcp.identity.ProjectOAuthIdpConfig")) return .project_oidc;
    if (std.mem.eql(u8, name, "gcp.identity.ProjectInboundSamlConfig")) return .project_saml;
    if (std.mem.eql(u8, name, "gcp.identity.TenantOAuthIdpConfig")) return .tenant_oidc;
    if (std.mem.eql(u8, name, "gcp.identity.TenantInboundSamlConfig")) return .tenant_saml;
    if (std.mem.eql(u8, name, "gcp.parametermanager.Parameter")) return .parameter;
    if (std.mem.eql(u8, name, "gcp.parametermanager.ParameterVersion")) return .parameter_version;
    if (std.mem.eql(u8, name, "gcp.parametermanager.Template")) return .template;
    if (std.mem.eql(u8, name, "gcp.parametermanager.TemplateVersion")) return .template_version;
    unreachable;
}

fn apiFor(node: resource.ResourceNode) client_mod.Api {
    return switch (kindOf(node)) {
        .workflow => .workflows,
        .api, .api_config, .gateway => .api_gateway,
        .project_config, .tenant, .project_oidc, .project_saml, .tenant_oidc, .tenant_saml => .identity_toolkit,
        .parameter, .parameter_version, .template, .template_version => .parameter_manager,
    };
}

fn usesLongRunningOperation(node: resource.ResourceNode) bool {
    return switch (kindOf(node)) {
        .workflow, .api, .api_config, .gateway => true,
        else => false,
    };
}

fn physicalIdAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]const u8 {
    const project = try requiredString(node.inputs, "project_id");
    return switch (kindOf(node)) {
        .workflow => fmt(allocator, "projects/{s}/locations/{s}/workflows/{s}", .{ project, try requiredString(node.inputs, "location"), try requiredString(node.inputs, "workflow_id") }),
        .api => fmt(allocator, "projects/{s}/locations/global/apis/{s}", .{ project, try requiredString(node.inputs, "api_id") }),
        .api_config => fmt(allocator, "projects/{s}/locations/global/apis/{s}/configs/{s}", .{ project, try requiredString(node.inputs, "api_id"), try requiredString(node.inputs, "config_id") }),
        .gateway => fmt(allocator, "projects/{s}/locations/{s}/gateways/{s}", .{ project, try requiredString(node.inputs, "location"), try requiredString(node.inputs, "gateway_id") }),
        .project_config => fmt(allocator, "projects/{s}/config", .{project}),
        .tenant => fmt(allocator, "projects/{s}/tenants/{s}", .{ project, try requiredString(node.inputs, "tenant_id") }),
        .project_oidc => fmt(allocator, "projects/{s}/oauthIdpConfigs/{s}", .{ project, try requiredString(node.inputs, "provider_id") }),
        .project_saml => fmt(allocator, "projects/{s}/inboundSamlConfigs/{s}", .{ project, try requiredString(node.inputs, "provider_id") }),
        .tenant_oidc => fmt(allocator, "projects/{s}/tenants/{s}/oauthIdpConfigs/{s}", .{ project, try requiredString(node.inputs, "tenant_id"), try requiredString(node.inputs, "provider_id") }),
        .tenant_saml => fmt(allocator, "projects/{s}/tenants/{s}/inboundSamlConfigs/{s}", .{ project, try requiredString(node.inputs, "tenant_id"), try requiredString(node.inputs, "provider_id") }),
        .parameter => fmt(allocator, "projects/{s}/locations/{s}/parameters/{s}", .{ project, try requiredString(node.inputs, "location"), try requiredString(node.inputs, "resource_id") }),
        .parameter_version => fmt(allocator, "projects/{s}/locations/{s}/parameters/{s}/versions/{s}", .{ project, try requiredString(node.inputs, "location"), try requiredString(node.inputs, "parent_id"), try requiredString(node.inputs, "version_id") }),
        .template => fmt(allocator, "projects/{s}/locations/{s}/templates/{s}", .{ project, try requiredString(node.inputs, "location"), try requiredString(node.inputs, "resource_id") }),
        .template_version => fmt(allocator, "projects/{s}/locations/{s}/templates/{s}/versions/{s}", .{ project, try requiredString(node.inputs, "location"), try requiredString(node.inputs, "parent_id"), try requiredString(node.inputs, "version_id") }),
    };
}

fn createPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]const u8 {
    const physical = try physicalIdAlloc(allocator, node);
    defer allocator.free(physical);
    const parent = parentName(physical);
    const id = lastSegment(physical);
    return switch (kindOf(node)) {
        .workflow => fmt(allocator, "/v1/{s}?workflowId={s}", .{ parent, id }),
        .api => fmt(allocator, "/v1/{s}?apiId={s}", .{ parent, id }),
        .api_config => fmt(allocator, "/v1/{s}?apiConfigId={s}", .{ parent, id }),
        .gateway => fmt(allocator, "/v1/{s}?gatewayId={s}", .{ parent, id }),
        .project_config => fmt(allocator, "/v2/{s}?updateMask=signIn,authorizedDomains,emailPrivacyConfig,multiTenant,mfa,monitoring", .{physical}),
        .tenant => fmt(allocator, "/v2/{s}?tenantId={s}", .{ parent, id }),
        .project_oidc, .tenant_oidc => fmt(allocator, "/v2/{s}?oauthIdpConfigId={s}", .{ parent, id }),
        .project_saml, .tenant_saml => fmt(allocator, "/v2/{s}?inboundSamlConfigId={s}", .{ parent, id }),
        .parameter => fmt(allocator, "/v1/{s}?parameterId={s}", .{ parent, id }),
        .parameter_version => fmt(allocator, "/v1/{s}?parameterVersionId={s}", .{ parent, id }),
        .template => fmt(allocator, "/v1/{s}?templateId={s}", .{ parent, id }),
        .template_version => fmt(allocator, "/v1/{s}?templateVersionId={s}", .{ parent, id }),
    };
}

fn resourcePathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, physical: []const u8) ProviderError![]const u8 {
    return fmt(allocator, "/{s}/{s}", .{ if (apiFor(node) == .identity_toolkit) "v2" else "v1", physical });
}

fn updatePathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, physical: []const u8) ProviderError![]const u8 {
    const mask = switch (kindOf(node)) {
        .workflow => "sourceContents,serviceAccount,cryptoKeyName,callLogLevel,executionHistoryLevel,labels,userEnvVars",
        .api => "displayName,labels",
        .gateway => "apiConfig,displayName,labels",
        .project_config => "signIn,authorizedDomains,emailPrivacyConfig,multiTenant,mfa,monitoring",
        .tenant => "displayName,disableAuth,signInConfig,mfaConfig",
        .project_oidc, .tenant_oidc => "displayName,enabled,issuer,clientId,clientSecret",
        .project_saml, .tenant_saml => "displayName,enabled,idpConfig,spConfig",
        .parameter, .template => "labels",
        .parameter_version, .template_version, .api_config => return error.InvalidConfiguration,
    };
    return fmt(allocator, "/{s}/{s}?updateMask={s}", .{ if (apiFor(node) == .identity_toolkit) "v2" else "v1", physical, mask });
}

fn deletePathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, physical: []const u8) ProviderError![]const u8 {
    return resourcePathAlloc(allocator, node, physical);
}

fn resultFromJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, body: []const u8) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const expected = try physicalIdAlloc(context.allocator, node);
    defer context.allocator.free(expected);
    const physical = jsonString(root.get("name")) orelse expected;
    if (!std.mem.eql(u8, expected, physical)) return error.InvalidConfiguration;
    var observed = value.Value.initOwned(context.allocator, node.inputs) catch |err| return mapValueError(err);
    defer observed.deinit(context.allocator);
    try normalizeCommon(context.allocator, &observed, root);
    var outputs: std.ArrayList(state.StateOutput) = .empty;
    defer outputs.deinit(context.allocator);
    try outputs.append(context.allocator, .{ .name = "name", .value = .{ .string = physical } });
    switch (kindOf(node)) {
        .workflow => {
            try outputs.append(context.allocator, .{ .name = "revision_id", .value = .{ .string = jsonString(root.get("revisionId")) orelse "" } });
            try outputs.append(context.allocator, .{ .name = "state", .value = .{ .string = jsonString(root.get("state")) orelse "" } });
            try outputs.append(context.allocator, .{ .name = "update_time", .value = .{ .string = jsonString(root.get("updateTime")) orelse "" } });
        },
        .api, .api_config, .gateway => {
            try outputs.append(context.allocator, .{ .name = "state", .value = .{ .string = jsonString(root.get("state")) orelse "" } });
            if (kindOf(node) == .gateway) try outputs.append(context.allocator, .{ .name = "default_hostname", .value = .{ .string = jsonString(root.get("defaultHostname")) orelse "" } });
            if (kindOf(node) == .api_config) try outputs.append(context.allocator, .{ .name = "service_account", .value = .{ .string = jsonString(root.get("serviceAccount")) orelse "" } });
        },
        .project_config, .tenant, .project_oidc, .project_saml, .tenant_oidc, .tenant_saml => try outputs.append(context.allocator, .{ .name = "etag", .value = .{ .string = jsonString(root.get("etag")) orelse "" } }),
        .parameter, .parameter_version, .template, .template_version => {
            try outputs.append(context.allocator, .{ .name = "etag", .value = .{ .string = jsonString(root.get("etag")) orelse "" } });
            if (kindOf(node) == .parameter_version or kindOf(node) == .template_version) try outputs.append(context.allocator, .{ .name = "state", .value = .{ .string = if (jsonBool(root.get("disabled")) orelse false) "DISABLED" else "ENABLED" } });
        },
    }
    return provider_mod.ResourceResult.init(context.allocator, physical, observed, outputs.items, null);
}

fn normalizeCommon(allocator: std.mem.Allocator, observed: *value.Value, remote: std.json.ObjectMap) ProviderError!void {
    const mappings = [_]struct { input: []const u8, wire: []const u8 }{
        .{ .input = "display_name", .wire = "displayName" },
        .{ .input = "source_contents", .wire = "sourceContents" },
        .{ .input = "call_log_level", .wire = "callLogLevel" },
        .{ .input = "execution_history", .wire = "executionHistoryLevel" },
        .{ .input = "issuer", .wire = "issuer" },
        .{ .input = "client_id", .wire = "clientId" },
        .{ .input = "format", .wire = "format" },
    };
    for (mappings) |mapping| if (jsonString(remote.get(mapping.wire))) |text| try replaceInputIfPresent(observed, allocator, mapping.input, .{ .string = text });
    const bool_mappings = [_]struct { input: []const u8, wire: []const u8 }{
        .{ .input = "enabled", .wire = "enabled" },
        .{ .input = "disabled", .wire = "disabled" },
        .{ .input = "disable_auth", .wire = "disableAuth" },
    };
    for (bool_mappings) |mapping| if (jsonBool(remote.get(mapping.wire))) |present| try replaceInputIfPresent(observed, allocator, mapping.input, .{ .boolean = present });
}

fn pendingResult(context: *provider_mod.OperationContext, node: resource.ResourceNode, handle: []const u8) ProviderError!provider_mod.ResourceResult {
    const physical = try physicalIdAlloc(context.allocator, node);
    defer context.allocator.free(physical);
    return provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &.{}, handle);
}

const SensitiveBody = struct {
    bytes: []u8,
    sensitive: bool,
    fn deinit(self: *SensitiveBody, allocator: std.mem.Allocator) void {
        if (self.sensitive) std.crypto.secureZero(u8, self.bytes);
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

fn putDisplayLabels(allocator: std.mem.Allocator, root: *std.json.ObjectMap, node: resource.ResourceNode) ProviderError!void {
    const display = try requiredString(node.inputs, "display_name");
    if (display.len > 0) try root.put(allocator, "displayName", .{ .string = display });
    try putLabelsText(allocator, root, try requiredString(node.inputs, "labels"));
}

fn putLabelsText(allocator: std.mem.Allocator, root: *std.json.ObjectMap, text: []const u8) ProviderError!void {
    if (text.len == 0) return;
    var labels: std.json.ObjectMap = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfiguration;
        try labels.put(allocator, line[0..equals], .{ .string = line[equals + 1 ..] });
    }
    try root.put(allocator, "labels", .{ .object = labels });
}

fn putStringMap(allocator: std.mem.Allocator, root: *std.json.ObjectMap, name: []const u8, input: value.Value) ProviderError!void {
    if (input != .object or input.object.len == 0) return;
    var mapped: std.json.ObjectMap = .empty;
    for (input.object) |field| try mapped.put(allocator, field.name, .{ .string = switch (field.value) {
        .string => |text| text,
        else => return error.InvalidConfiguration,
    } });
    try root.put(allocator, name, .{ .object = mapped });
}

fn putEnvMap(allocator: std.mem.Allocator, root: *std.json.ObjectMap, input: value.Value) ProviderError!void {
    if (input != .list or input.list.len == 0) return;
    var mapped: std.json.ObjectMap = .empty;
    for (input.list) |entry| try mapped.put(allocator, try requiredString(entry, "key"), .{ .string = try requiredString(entry, "value") });
    try root.put(allocator, "userEnvVars", .{ .object = mapped });
}

fn valueListToJson(allocator: std.mem.Allocator, items: []const value.Value) ProviderError!std.json.Value {
    var array = std.json.Array.init(allocator);
    for (items) |item| try array.append(.{ .string = switch (item) {
        .string => |text| text,
        else => return error.InvalidConfiguration,
    } });
    return .{ .array = array };
}

fn boolObject(allocator: std.mem.Allocator, name: []const u8, present: bool) ProviderError!std.json.ObjectMap {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, name, .{ .bool = present });
    return object;
}

fn stringObject(allocator: std.mem.Allocator, name: []const u8, text: []const u8) ProviderError!std.json.ObjectMap {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, name, .{ .string = text });
    return object;
}

fn identityChanged(node: resource.ResourceNode, observed: value.Value) bool {
    const names = switch (kindOf(node)) {
        .workflow => &[_][]const u8{ "project_id", "location", "workflow_id" },
        .api => &[_][]const u8{ "project_id", "api_id" },
        .api_config => &[_][]const u8{ "project_id", "api_id", "config_id", "documents" },
        .gateway => &[_][]const u8{ "project_id", "location", "gateway_id" },
        .project_config => &[_][]const u8{"project_id"},
        .tenant => &[_][]const u8{ "project_id", "tenant_id" },
        .project_oidc, .project_saml => &[_][]const u8{ "project_id", "provider_id" },
        .tenant_oidc, .tenant_saml => &[_][]const u8{ "project_id", "tenant_id", "provider_id" },
        .parameter, .template => &[_][]const u8{ "project_id", "location", "resource_id", "format", "kms_key" },
        .parameter_version, .template_version => &[_][]const u8{ "project_id", "location", "parent_id", "version_id", "payload_sha256" },
    };
    for (names) |name| {
        const desired = findValue(node.inputs, name) orelse continue;
        const remote = findValue(observed, name) orelse return true;
        const left = desired.canonicalJsonAlloc(std.heap.page_allocator) catch return true;
        defer std.heap.page_allocator.free(left);
        const right = remote.canonicalJsonAlloc(std.heap.page_allocator) catch return true;
        defer std.heap.page_allocator.free(right);
        if (!std.mem.eql(u8, left, right)) return true;
    }
    return false;
}

fn replaceInputIfPresent(target: *value.Value, allocator: std.mem.Allocator, name: []const u8, replacement: value.Value) ProviderError!void {
    if (target.* != .object) return error.ProviderBug;
    for (@constCast(target.object)) |*field| {
        if (!std.mem.eql(u8, field.name, name)) continue;
        field.value.deinit(allocator);
        field.value = value.Value.initOwned(allocator, replacement) catch |err| return mapValueError(err);
        return;
    }
}

fn operationNameAlloc(allocator: std.mem.Allocator, body: []const u8) ProviderError![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    return allocator.dupe(u8, jsonString(root.get("name")) orelse return error.ProviderBug) catch error.OutOfMemory;
}

fn outputString(result: *const provider_mod.ResourceResult, name: []const u8) ?[]const u8 {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name) and item.value == .string) return item.value.string;
    return null;
}

fn resolveString(context: *provider_mod.OperationContext, candidate: value.Value) ProviderError![]const u8 {
    return switch (candidate) {
        .string => |text| text,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}

fn resolveSecret(context: *provider_mod.OperationContext, candidate: value.Value) ProviderError!value.SecretReference {
    return switch (candidate) {
        .secret_ref => |reference| reference,
        .output_ref => |reference| context.resolveOutputSecret(reference),
        else => error.InvalidConfiguration,
    };
}

fn requiredValue(input: value.Value, name: []const u8) ProviderError!value.Value {
    return findValue(input, name) orelse error.InvalidConfiguration;
}

fn requiredString(input: value.Value, name: []const u8) ProviderError![]const u8 {
    return switch (try requiredValue(input, name)) {
        .string => |text| text,
        else => error.InvalidConfiguration,
    };
}

fn requiredBool(input: value.Value, name: []const u8) ProviderError!bool {
    return switch (try requiredValue(input, name)) {
        .boolean => |present| present,
        else => error.InvalidConfiguration,
    };
}

fn requiredList(input: value.Value, name: []const u8) ProviderError![]const value.Value {
    return switch (try requiredValue(input, name)) {
        .list => |items| items,
        else => error.InvalidConfiguration,
    };
}

fn findValue(input: value.Value, name: []const u8) ?value.Value {
    if (input != .object) return null;
    for (input.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return null;
}

fn parentName(text: []const u8) []const u8 {
    return text[0 .. std.mem.lastIndexOfScalar(u8, text, '/') orelse 0];
}

fn lastSegment(text: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, text, '/')) |index| text[index + 1 ..] else text;
}

fn jsonObject(candidate: std.json.Value) ?std.json.ObjectMap {
    return switch (candidate) {
        .object => |object| object,
        else => null,
    };
}

fn jsonString(candidate: ?std.json.Value) ?[]const u8 {
    const present = candidate orelse return null;
    return switch (present) {
        .string => |text| text,
        else => null,
    };
}

fn jsonBool(candidate: ?std.json.Value) ?bool {
    const present = candidate orelse return null;
    return switch (present) {
        .bool => |value_bool| value_bool,
        else => null,
    };
}

fn mapValueError(err: anyerror) ProviderError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateField => error.ProviderBug,
        else => error.ProviderBug,
    };
}

fn fmt(allocator: std.mem.Allocator, comptime format: []const u8, args: anytype) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, format, args) catch error.OutOfMemory;
}
