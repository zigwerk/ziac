const std = @import("std");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;
const Kind = enum { pool, authority, template, certificate, pool_iam, template_iam };

pub const Handler = struct {
    client: *client_mod.Client,
    operation_policy: operation.Policy = .{},

    pub fn supports(node: resource.ResourceNode) bool {
        return kindOf(node) != null;
    }

    pub fn read(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (isIam(kind)) return self.readIam(context, node);
        if (context.operation_handle) |handle| {
            const payload = try self.waitOperationAlloc(context, handle);
            defer context.allocator.free(payload);
            const response = try operationResponseAlloc(context.allocator, payload);
            defer context.allocator.free(response);
            return .{ .present = try resultFromJson(context, node, kind, response) };
        }
        const physical = try physicalForReadAlloc(context, node, kind, physical_override);
        defer context.allocator.free(physical);
        try validatePhysical(kind, physical);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical});
        defer context.allocator.free(path);
        var response = self.request(context, "GET", path, "") catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try resultFromJson(context, node, kind, response.body) };
    }

    pub fn diff(context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (isIam(kind)) return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        const remote_json = outputString(observed.*, "__remote_spec") orelse return error.ProviderBug;
        var remote = std.json.parseFromSlice(std.json.Value, context.allocator, remote_json, .{}) catch return error.ProviderBug;
        defer remote.deinit();
        const body = try bodyAlloc(context, node, kind);
        defer context.allocator.free(body);
        var desired = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
        defer desired.deinit();
        const desired_root = jsonObject(desired.value) orelse return error.ProviderBug;
        const remote_root = jsonObject(remote.value) orelse return error.ProviderBug;
        if (jsonContains(desired_root, remote_root)) return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        if (immutableChanged(kind, desired_root, remote_root)) return provider_mod.DiffResult.init(context.allocator, .replace, &.{"Private CA immutable identity differs"});
        return provider_mod.DiffResult.init(context.allocator, .update, &.{"Private CA configuration differs"});
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (isIam(kind)) return self.mutateIam(context, node, true);
        const path = try createPathAlloc(context, node, kind);
        defer context.allocator.free(path);
        const body = try bodyAlloc(context, node, kind);
        defer context.allocator.free(body);
        var response = try self.request(context, "POST", path, body);
        defer response.deinit(context.allocator);
        return if (kind == .certificate)
            resultFromJson(context, node, kind, response.body)
        else
            pendingResult(context, node, kind, response.body);
    }

    pub fn update(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (isIam(kind)) return self.mutateIam(context, node, true);
        try validatePhysical(kind, observed.physical_id);
        const body = try bodyAlloc(context, node, kind);
        defer context.allocator.free(body);
        const path = try updatePathAlloc(context.allocator, kind, observed.physical_id);
        defer context.allocator.free(path);
        var response = try self.request(context, "PATCH", path, body);
        defer response.deinit(context.allocator);
        return if (kind == .certificate)
            resultFromJson(context, node, kind, response.body)
        else
            pendingResultWithPhysical(context, node, kind, observed.physical_id, response.body);
    }

    pub fn delete(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical: []const u8) ProviderError!void {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (isIam(kind)) {
            var removed = try self.mutateIam(context, node, false);
            removed.deinit();
            return;
        }
        if (kind == .certificate or kind == .authority) {
            if (!context.destructive_confirmation) return error.DestructiveConfirmationRequired;
            return error.InvalidConfiguration;
        }
        try validatePhysical(kind, physical);
        if (!std.mem.eql(u8, try requiredLiteralString(node.inputs, "removal_policy"), "delete") or !context.destructive_confirmation) return error.DestructiveConfirmationRequired;
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical});
        defer context.allocator.free(path);
        var response = self.request(context, "DELETE", path, "") catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer response.deinit(context.allocator);
        const handle = try operationNameAlloc(context.allocator, response.body);
        defer context.allocator.free(handle);
        const payload = try self.waitOperationAlloc(context, handle);
        context.allocator.free(payload);
    }

    pub fn importResource(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical: []const u8) ProviderError!provider_mod.ResourceResult {
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (!isIam(kind)) try validatePhysical(kind, physical);
        var found = try self.read(context, node, if (isIam(kind)) null else physical);
        defer found.deinit();
        return switch (found) {
            .absent => error.NotFound,
            .present => |present| present.clone(context.allocator),
        };
    }

    fn readIam(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ReadResult {
        const target = try requiredString(context, node.inputs, "resource");
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}:getIamPolicy?options.requestedPolicyVersion=3", .{target});
        defer context.allocator.free(path);
        var response = self.request(context, "GET", path, "") catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        if (!policyHasExactMember(parsed.value, node)) return .absent;
        return .{ .present = try iamResult(context, node, target) };
    }

    fn mutateIam(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, should_exist: bool) ProviderError!provider_mod.ResourceResult {
        const target = try requiredString(context, node.inputs, "resource");
        const get_path = try std.fmt.allocPrint(context.allocator, "/v1/{s}:getIamPolicy?options.requestedPolicyVersion=3", .{target});
        defer context.allocator.free(get_path);
        var get_response = try self.request(context, "GET", get_path, "");
        defer get_response.deinit(context.allocator);
        var policy = std.json.parseFromSlice(std.json.Value, context.allocator, get_response.body, .{}) catch return error.ProviderBug;
        defer policy.deinit();
        if (try mutatePolicy(&policy, node, should_exist)) {
            const body = try policyBodyAlloc(context.allocator, policy.value);
            defer context.allocator.free(body);
            const set_path = try std.fmt.allocPrint(context.allocator, "/v1/{s}:setIamPolicy", .{target});
            defer context.allocator.free(set_path);
            var response = try self.request(context, "POST", set_path, body);
            response.deinit(context.allocator);
        }
        return iamResult(context, node, target);
    }

    fn waitOperationAlloc(self: Handler, context: *provider_mod.OperationContext, handle: []const u8) ProviderError![]const u8 {
        const base = try std.fmt.allocPrint(context.allocator, "{s}/v1", .{std.mem.trimEnd(u8, self.client.endpoints.get(.private_ca), "/")});
        defer context.allocator.free(base);
        var target = operation.Target.genericAlloc(context.allocator, base, handle) catch return error.OutOfMemory;
        defer target.deinit(context.allocator);
        var completed = try operation.waitAlloc(self.client, context, target, self.operation_policy);
        defer completed.deinit(context.allocator);
        return context.allocator.dupe(u8, completed.payload) catch error.OutOfMemory;
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, method: []const u8, path: []const u8, body: []const u8) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, .{ .api = .private_ca, .method = method, .path = path, .body = body }, &diagnostic);
    }
};

fn kindOf(node: resource.ResourceNode) ?Kind {
    const mappings = [_]struct { []const u8, Kind }{
        .{ "gcp.privateca.CaPool", .pool },
        .{ "gcp.privateca.CertificateAuthority", .authority },
        .{ "gcp.privateca.CertificateTemplate", .template },
        .{ "gcp.privateca.Certificate", .certificate },
        .{ "gcp.privateca.CaPoolIamMember", .pool_iam },
        .{ "gcp.privateca.CertificateTemplateIamMember", .template_iam },
    };
    for (mappings) |mapping| if (std.mem.eql(u8, node.type_name, mapping[0])) return mapping[1];
    return null;
}

fn isIam(kind: Kind) bool {
    return kind == .pool_iam or kind == .template_iam;
}

fn physicalForReadAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, override: ?[]const u8) ProviderError![]const u8 {
    if (override orelse context.physical_id) |physical| return context.allocator.dupe(u8, physical) catch error.OutOfMemory;
    return switch (kind) {
        .pool => std.fmt.allocPrint(context.allocator, "{s}/locations/{s}/caPools/{s}", .{ try requiredString(context, node.inputs, "project"), try requiredLiteralString(node.inputs, "location"), node.logical_id }) catch error.OutOfMemory,
        .authority => std.fmt.allocPrint(context.allocator, "{s}/certificateAuthorities/{s}", .{ try requiredString(context, node.inputs, "pool"), node.logical_id }) catch error.OutOfMemory,
        .template => std.fmt.allocPrint(context.allocator, "{s}/locations/{s}/certificateTemplates/{s}", .{ try requiredString(context, node.inputs, "project"), try requiredLiteralString(node.inputs, "location"), node.logical_id }) catch error.OutOfMemory,
        .certificate => std.fmt.allocPrint(context.allocator, "{s}/certificates/{s}", .{ try requiredString(context, node.inputs, "pool"), node.logical_id }) catch error.OutOfMemory,
        .pool_iam, .template_iam => error.InvalidConfiguration,
    };
}

fn createPathAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    return switch (kind) {
        .pool => std.fmt.allocPrint(context.allocator, "/v1/{s}/locations/{s}/caPools?caPoolId={s}", .{ try requiredString(context, node.inputs, "project"), try requiredLiteralString(node.inputs, "location"), node.logical_id }) catch error.OutOfMemory,
        .authority => std.fmt.allocPrint(context.allocator, "/v1/{s}/certificateAuthorities?certificateAuthorityId={s}", .{ try requiredString(context, node.inputs, "pool"), node.logical_id }) catch error.OutOfMemory,
        .template => std.fmt.allocPrint(context.allocator, "/v1/{s}/locations/{s}/certificateTemplates?certificateTemplateId={s}", .{ try requiredString(context, node.inputs, "project"), try requiredLiteralString(node.inputs, "location"), node.logical_id }) catch error.OutOfMemory,
        .certificate => std.fmt.allocPrint(context.allocator, "/v1/{s}/certificates?certificateId={s}", .{ try requiredString(context, node.inputs, "pool"), node.logical_id }) catch error.OutOfMemory,
        .pool_iam, .template_iam => error.InvalidConfiguration,
    };
}

fn updatePathAlloc(allocator: std.mem.Allocator, kind: Kind, physical: []const u8) ProviderError![]const u8 {
    const mask = switch (kind) {
        .pool => "issuancePolicy%2CpublishingOptions%2Clabels",
        .authority => "labels%2CuserDefinedAccessUrls",
        .template => "predefinedValues%2CidentityConstraints%2CpassthroughExtensions%2Cdescription%2CmaximumLifetime%2Clabels",
        .certificate => "labels",
        .pool_iam, .template_iam => return error.InvalidConfiguration,
    };
    return std.fmt.allocPrint(allocator, "/v1/{s}?updateMask={s}", .{ physical, mask }) catch error.OutOfMemory;
}

fn validatePhysical(kind: Kind, physical: []const u8) ProviderError!void {
    if (!std.mem.startsWith(u8, physical, "projects/") or std.mem.indexOfAny(u8, physical, "?# \t\r\n") != null) return error.InvalidConfiguration;
    const required = switch (kind) {
        .pool => "/caPools/",
        .authority => "/certificateAuthorities/",
        .template => "/certificateTemplates/",
        .certificate => "/certificates/",
        .pool_iam, .template_iam => return error.InvalidConfiguration,
    };
    if (std.mem.indexOf(u8, physical, required) == null) return error.InvalidConfiguration;
}

fn immutableChanged(kind: Kind, desired: std.json.ObjectMap, remote: std.json.ObjectMap) bool {
    const fields: []const []const u8 = switch (kind) {
        .pool => &.{ "tier", "encryptionSpec" },
        .authority => &.{ "type", "keySpec", "subordinateConfig" },
        .template => &.{},
        .certificate => &.{ "config", "pemCsr", "certificateTemplate", "lifetime" },
        .pool_iam, .template_iam => return false,
    };
    for (fields) |field| if (!jsonValueEquivalent(desired.get(field), remote.get(field))) return true;
    return false;
}

fn bodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind) ProviderError![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = std.json.ObjectMap.empty;
    switch (kind) {
        .pool => try poolBody(context, arena, node, &root),
        .authority => try authorityBody(context, arena, node, &root),
        .template => try templateBody(context, arena, node, &root),
        .certificate => try certificateBody(context, arena, node, &root),
        .pool_iam, .template_iam => return error.InvalidConfiguration,
    }
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch error.OutOfMemory;
}

fn poolBody(context: *provider_mod.OperationContext, arena: std.mem.Allocator, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    try root.put(arena, "tier", .{ .string = try requiredLiteralString(node.inputs, "tier") });
    var issuance = std.json.ObjectMap.empty;
    try issuance.put(arena, "maximumLifetime", .{ .string = try durationAlloc(arena, try requiredInteger(node.inputs, "maximum_lifetime_seconds")) });
    try root.put(arena, "issuancePolicy", .{ .object = issuance });
    var publishing = std.json.ObjectMap.empty;
    try publishing.put(arena, "publishCaCert", .{ .bool = try requiredBoolean(node.inputs, "publish_ca_cert") });
    try publishing.put(arena, "publishCrl", .{ .bool = try requiredBoolean(node.inputs, "publish_crl") });
    try root.put(arena, "publishingOptions", .{ .object = publishing });
    try root.put(arena, "labels", try resolvedValueJson(context, arena, try requiredValue(node.inputs, "labels")));
    const kms = try requiredString(context, node.inputs, "kms_key");
    if (kms.len != 0) {
        var encryption = std.json.ObjectMap.empty;
        try encryption.put(arena, "cloudKmsKeyVersion", .{ .string = kms });
        try root.put(arena, "encryptionSpec", .{ .object = encryption });
    }
}

fn authorityBody(context: *provider_mod.OperationContext, arena: std.mem.Allocator, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    try root.put(arena, "type", .{ .string = try requiredLiteralString(node.inputs, "authority_type") });
    try root.put(arena, "lifetime", .{ .string = try durationAlloc(arena, try requiredInteger(node.inputs, "lifetime_seconds")) });
    var key_spec = std.json.ObjectMap.empty;
    try key_spec.put(arena, "algorithm", .{ .string = try requiredLiteralString(node.inputs, "key_algorithm") });
    try root.put(arena, "keySpec", .{ .object = key_spec });
    var config = std.json.ObjectMap.empty;
    var subject_config = std.json.ObjectMap.empty;
    try subject_config.put(arena, "subject", try subjectJson(arena, try requiredValue(node.inputs, "subject")));
    try config.put(arena, "subjectConfig", .{ .object = subject_config });
    var x509 = std.json.ObjectMap.empty;
    var ca_options = std.json.ObjectMap.empty;
    try ca_options.put(arena, "isCa", .{ .bool = true });
    try x509.put(arena, "caOptions", .{ .object = ca_options });
    try config.put(arena, "x509Config", .{ .object = x509 });
    try root.put(arena, "config", .{ .object = config });
    try root.put(arena, "labels", try resolvedValueJson(context, arena, try requiredValue(node.inputs, "labels")));
    const issuer = try requiredString(context, node.inputs, "subordinate_issuer");
    if (issuer.len != 0) {
        var subordinate = std.json.ObjectMap.empty;
        try subordinate.put(arena, "certificateAuthority", .{ .string = issuer });
        try root.put(arena, "subordinateConfig", .{ .object = subordinate });
    }
    const bucket = try requiredLiteralString(node.inputs, "gcs_bucket");
    if (bucket.len != 0) {
        var urls = std.json.ObjectMap.empty;
        var aia = std.json.Array.init(arena);
        try aia.append(.{ .string = try std.fmt.allocPrint(arena, "gs://{s}", .{bucket}) });
        try urls.put(arena, "aiaIssuingCertificateUrls", .{ .array = aia });
        try root.put(arena, "userDefinedAccessUrls", .{ .object = urls });
    }
}

fn templateBody(context: *provider_mod.OperationContext, arena: std.mem.Allocator, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    const description = try requiredLiteralString(node.inputs, "description");
    if (description.len != 0) try root.put(arena, "description", .{ .string = description });
    try root.put(arena, "maximumLifetime", .{ .string = try durationAlloc(arena, try requiredInteger(node.inputs, "maximum_lifetime_seconds")) });
    try root.put(arena, "labels", try resolvedValueJson(context, arena, try requiredValue(node.inputs, "labels")));
    var predefined = std.json.ObjectMap.empty;
    var ca_options = std.json.ObjectMap.empty;
    try ca_options.put(arena, "isCa", .{ .bool = try requiredBoolean(node.inputs, "is_ca") });
    const path_length = try requiredInteger(node.inputs, "max_issuer_path_length");
    if (path_length >= 0) try ca_options.put(arena, "maxIssuerPathLength", .{ .integer = path_length });
    try predefined.put(arena, "caOptions", .{ .object = ca_options });
    try predefined.put(arena, "keyUsage", try keyUsageJson(arena, try requiredValue(node.inputs, "key_usage")));
    try root.put(arena, "predefinedValues", .{ .object = predefined });
    var identity = std.json.ObjectMap.empty;
    try identity.put(arena, "allowSubjectPassthrough", .{ .bool = try requiredBoolean(node.inputs, "allow_subject_passthrough") });
    try identity.put(arena, "allowSubjectAltNamesPassthrough", .{ .bool = try requiredBoolean(node.inputs, "allow_sans_passthrough") });
    try root.put(arena, "identityConstraints", .{ .object = identity });
}

fn certificateBody(context: *provider_mod.OperationContext, arena: std.mem.Allocator, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    try root.put(arena, "lifetime", .{ .string = try durationAlloc(arena, try requiredInteger(node.inputs, "lifetime_seconds")) });
    try root.put(arena, "labels", try resolvedValueJson(context, arena, try requiredValue(node.inputs, "labels")));
    const template = try requiredString(context, node.inputs, "template");
    if (template.len != 0) try root.put(arena, "certificateTemplate", .{ .string = template });
    const request = valueObject(try requiredValue(node.inputs, "request")) orelse return error.InvalidConfiguration;
    const request_kind = try requiredObjectString(request, "kind");
    if (std.mem.eql(u8, request_kind, "pem_csr")) {
        try root.put(arena, "pemCsr", .{ .string = try requiredObjectString(request, "pem_csr") });
        return;
    }
    var config = std.json.ObjectMap.empty;
    var subject_config = std.json.ObjectMap.empty;
    try subject_config.put(arena, "subject", try subjectJson(arena, try requiredObjectValue(request, "subject")));
    var sans = std.json.ObjectMap.empty;
    try sans.put(arena, "dnsNames", try resolvedValueJson(context, arena, try requiredObjectValue(request, "dns_names")));
    try sans.put(arena, "emailAddresses", try resolvedValueJson(context, arena, try requiredObjectValue(request, "email_addresses")));
    try sans.put(arena, "ipAddresses", try resolvedValueJson(context, arena, try requiredObjectValue(request, "ip_addresses")));
    try sans.put(arena, "uris", try resolvedValueJson(context, arena, try requiredObjectValue(request, "uris")));
    try subject_config.put(arena, "subjectAltName", .{ .object = sans });
    try config.put(arena, "subjectConfig", .{ .object = subject_config });
    try root.put(arena, "config", .{ .object = config });
}

fn subjectJson(arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    const fields = valueObject(source) orelse return error.InvalidConfiguration;
    var subject = std.json.ObjectMap.empty;
    const mappings = [_]struct { []const u8, []const u8 }{
        .{ "common_name", "commonName" },   .{ "organization", "organization" }, .{ "organizational_unit", "organizationalUnit" },
        .{ "country_code", "countryCode" }, .{ "locality", "locality" },         .{ "province", "province" },
    };
    for (mappings) |mapping| {
        const text = try requiredObjectString(fields, mapping[0]);
        if (text.len != 0) try subject.put(arena, mapping[1], .{ .string = text });
    }
    return .{ .object = subject };
}

fn keyUsageJson(arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    const fields = valueObject(source) orelse return error.InvalidConfiguration;
    var base = std.json.ObjectMap.empty;
    try base.put(arena, "digitalSignature", .{ .bool = try requiredObjectBoolean(fields, "digital_signature") });
    try base.put(arena, "contentCommitment", .{ .bool = try requiredObjectBoolean(fields, "content_commitment") });
    try base.put(arena, "keyEncipherment", .{ .bool = try requiredObjectBoolean(fields, "key_encipherment") });
    try base.put(arena, "dataEncipherment", .{ .bool = try requiredObjectBoolean(fields, "data_encipherment") });
    try base.put(arena, "keyAgreement", .{ .bool = try requiredObjectBoolean(fields, "key_agreement") });
    try base.put(arena, "certSign", .{ .bool = try requiredObjectBoolean(fields, "cert_sign") });
    try base.put(arena, "crlSign", .{ .bool = try requiredObjectBoolean(fields, "crl_sign") });
    var extended = std.json.ObjectMap.empty;
    try extended.put(arena, "serverAuth", .{ .bool = try requiredObjectBoolean(fields, "server_auth") });
    try extended.put(arena, "clientAuth", .{ .bool = try requiredObjectBoolean(fields, "client_auth") });
    try extended.put(arena, "codeSigning", .{ .bool = try requiredObjectBoolean(fields, "code_signing") });
    try extended.put(arena, "emailProtection", .{ .bool = try requiredObjectBoolean(fields, "email_protection") });
    var result = std.json.ObjectMap.empty;
    try result.put(arena, "baseKeyUsage", .{ .object = base });
    try result.put(arena, "extendedKeyUsage", .{ .object = extended });
    return .{ .object = result };
}

fn durationAlloc(allocator: std.mem.Allocator, seconds: i64) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}s", .{seconds}) catch error.OutOfMemory;
}

fn pendingResult(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, body: []const u8) ProviderError!provider_mod.ResourceResult {
    const physical = try physicalForReadAlloc(context, node, kind, null);
    defer context.allocator.free(physical);
    return pendingResultWithPhysical(context, node, kind, physical, body);
}

fn pendingResultWithPhysical(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, physical: []const u8, body: []const u8) ProviderError!provider_mod.ResourceResult {
    _ = kind;
    const handle = try operationNameAlloc(context.allocator, body);
    defer context.allocator.free(handle);
    const outputs = [_]state.StateOutput{.{ .name = "name", .value = .{ .unknown_reason = "Private CA operation pending" } }};
    var result = try provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &outputs, handle);
    result.completed = false;
    return result;
}

fn resultFromJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, body: []const u8) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const physical = jsonString(root.get("name")) orelse return error.ProviderBug;
    try validatePhysical(kind, physical);
    const observed: value.Value = if (try remoteMatches(context, node, kind, root)) node.inputs else .{ .unknown_reason = "remote Private CA configuration drifted" };
    var outputs: [7]state.StateOutput = undefined;
    var count: usize = 0;
    outputs[count] = .{ .name = "name", .value = .{ .string = physical } };
    count += 1;
    if (kind == .authority) {
        outputs[count] = .{ .name = "state", .value = .{ .string = jsonString(root.get("state")) orelse "" } };
        count += 1;
        outputs[count] = .{ .name = "pem_ca_certificates", .value = try stringArrayValue(context.allocator, root.get("pemCaCertificates")) };
        count += 1;
    }
    if (kind == .certificate) {
        outputs[count] = .{ .name = "pem_certificate", .value = .{ .string = jsonString(root.get("pemCertificate")) orelse "" } };
        count += 1;
        outputs[count] = .{ .name = "pem_certificate_chain", .value = try stringArrayValue(context.allocator, root.get("pemCertificateChain")) };
        count += 1;
        outputs[count] = .{ .name = "issuer", .value = .{ .string = jsonString(root.get("issuerCertificateAuthority")) orelse "" } };
        count += 1;
    }
    outputs[count] = .{ .name = "__remote_spec", .value = .{ .string = body } };
    count += 1;
    const result = try provider_mod.ResourceResult.init(context.allocator, physical, observed, outputs[0..count], null);
    for (outputs[0..count]) |*item| if (item.value == .list) item.value.deinit(context.allocator);
    return result;
}

fn stringArrayValue(allocator: std.mem.Allocator, candidate: ?std.json.Value) ProviderError!value.Value {
    const array = jsonArray(candidate orelse return value.Value.initOwned(allocator, .{ .list = &.{} }) catch error.OutOfMemory) orelse return error.ProviderBug;
    const items = try allocator.alloc(value.Value, array.items.len);
    defer allocator.free(items);
    for (array.items, 0..) |item, index| items[index] = .{ .string = jsonString(item) orelse return error.ProviderBug };
    return value.Value.initOwned(allocator, .{ .list = items }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateField => error.ProviderBug,
    };
}

fn remoteMatches(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, remote: std.json.ObjectMap) ProviderError!bool {
    const body = try bodyAlloc(context, node, kind);
    defer context.allocator.free(body);
    var desired = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer desired.deinit();
    return jsonContains(jsonObject(desired.value) orelse return error.ProviderBug, remote);
}

fn operationNameAlloc(allocator: std.mem.Allocator, body: []const u8) ProviderError![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const name = jsonString(root.get("name")) orelse return error.ProviderBug;
    if (std.mem.indexOf(u8, name, "/operations/") == null) return error.ProviderBug;
    return allocator.dupe(u8, name) catch error.OutOfMemory;
}

fn operationResponseAlloc(allocator: std.mem.Allocator, body: []const u8) ProviderError![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    return std.json.Stringify.valueAlloc(allocator, root.get("response") orelse return error.ProviderBug, .{}) catch error.OutOfMemory;
}

fn iamResult(context: *provider_mod.OperationContext, node: resource.ResourceNode, target: []const u8) ProviderError!provider_mod.ResourceResult {
    const physical = try std.fmt.allocPrint(context.allocator, "{s}/iam/{s}", .{ target, node.logical_id });
    defer context.allocator.free(physical);
    const outputs = [_]state.StateOutput{.{ .name = "binding_id", .value = .{ .string = physical } }};
    return provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &outputs, null);
}

fn policyBodyAlloc(allocator: std.mem.Allocator, policy: std.json.Value) ProviderError![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var wrapper = std.json.ObjectMap.empty;
    try wrapper.put(arena_state.allocator(), "policy", try cloneJson(arena_state.allocator(), policy));
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = wrapper }, .{}) catch error.OutOfMemory;
}

fn policyHasExactMember(policy: std.json.Value, node: resource.ResourceNode) bool {
    const root = jsonObject(policy) orelse return false;
    const bindings = jsonArray(root.get("bindings") orelse return false) orelse return false;
    for (bindings.items) |candidate| {
        const binding = jsonObject(candidate) orelse continue;
        if (!bindingIdentityMatches(binding, node)) continue;
        const members = jsonArray(binding.get("members") orelse continue) orelse continue;
        for (members.items) |member| if (stringEquals(member, inputString(node.inputs, "member") orelse return false)) return true;
    }
    return false;
}

fn mutatePolicy(parsed: *std.json.Parsed(std.json.Value), node: resource.ResourceNode, should_exist: bool) ProviderError!bool {
    const allocator = parsed.arena.allocator();
    const root = switch (parsed.value) {
        .object => |*object| object,
        else => return error.ProviderBug,
    };
    try root.put(allocator, "version", .{ .integer = 3 });
    var bindings_value = root.getPtr("bindings");
    if (bindings_value == null) {
        if (!should_exist) return false;
        try root.put(allocator, "bindings", .{ .array = std.json.Array.init(allocator) });
        bindings_value = root.getPtr("bindings");
    }
    const bindings = switch (bindings_value.?.*) {
        .array => |*array| array,
        else => return error.ProviderBug,
    };
    for (bindings.items, 0..) |*binding_value, binding_index| {
        const binding = switch (binding_value.*) {
            .object => |*object| object,
            else => continue,
        };
        if (!bindingIdentityMatches(binding.*, node)) continue;
        const members_value = binding.getPtr("members") orelse return error.ProviderBug;
        const members = switch (members_value.*) {
            .array => |*array| array,
            else => return error.ProviderBug,
        };
        const member = try requiredLiteralString(node.inputs, "member");
        for (members.items, 0..) |candidate, member_index| if (stringEquals(candidate, member)) {
            if (should_exist) return false;
            _ = members.orderedRemove(member_index);
            if (members.items.len == 0) _ = bindings.orderedRemove(binding_index);
            return true;
        };
        if (!should_exist) return false;
        try members.append(.{ .string = member });
        return true;
    }
    if (!should_exist) return false;
    var members = std.json.Array.init(allocator);
    try members.append(.{ .string = try requiredLiteralString(node.inputs, "member") });
    var binding = std.json.ObjectMap.empty;
    try binding.put(allocator, "role", .{ .string = try requiredLiteralString(node.inputs, "role") });
    try binding.put(allocator, "members", .{ .array = members });
    const condition = try requiredValue(node.inputs, "condition");
    if (!valueIsEmpty(condition)) try binding.put(allocator, "condition", try resolvedValueJsonLiteral(allocator, condition));
    try bindings.append(.{ .object = binding });
    return true;
}

fn bindingIdentityMatches(binding: std.json.ObjectMap, node: resource.ResourceNode) bool {
    if (!stringEquals(binding.get("role"), inputString(node.inputs, "role") orelse return false)) return false;
    const desired = requiredValue(node.inputs, "condition") catch return false;
    if (valueIsEmpty(desired)) return binding.get("condition") == null;
    return jsonMatchesValue(desired, binding.get("condition") orelse return false);
}

fn requiredValue(source: value.Value, name: []const u8) ProviderError!value.Value {
    const fields = valueObject(source) orelse return error.InvalidConfiguration;
    return requiredObjectValue(fields, name);
}
fn requiredLiteralString(source: value.Value, name: []const u8) ProviderError![]const u8 {
    return valueString(try requiredValue(source, name)) orelse error.InvalidConfiguration;
}
fn requiredString(context: *provider_mod.OperationContext, source: value.Value, name: []const u8) ProviderError![]const u8 {
    return resolveString(context, try requiredValue(source, name));
}
fn resolveString(context: *provider_mod.OperationContext, source: value.Value) ProviderError![]const u8 {
    return switch (source) {
        .string => |text| text,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}
fn requiredBoolean(source: value.Value, name: []const u8) ProviderError!bool {
    return switch (try requiredValue(source, name)) {
        .boolean => |flag| flag,
        else => error.InvalidConfiguration,
    };
}
fn requiredInteger(source: value.Value, name: []const u8) ProviderError!i64 {
    return switch (try requiredValue(source, name)) {
        .integer => |number| number,
        else => error.InvalidConfiguration,
    };
}
fn requiredObjectValue(fields: []const value.Field, name: []const u8) ProviderError!value.Value {
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return error.InvalidConfiguration;
}
fn requiredObjectString(fields: []const value.Field, name: []const u8) ProviderError![]const u8 {
    return valueString(try requiredObjectValue(fields, name)) orelse error.InvalidConfiguration;
}
fn requiredObjectBoolean(fields: []const value.Field, name: []const u8) ProviderError!bool {
    return switch (try requiredObjectValue(fields, name)) {
        .boolean => |flag| flag,
        else => error.InvalidConfiguration,
    };
}
fn valueObject(source: value.Value) ?[]const value.Field {
    return if (source == .object) source.object else null;
}
fn valueString(source: value.Value) ?[]const u8 {
    return if (source == .string) source.string else null;
}

fn resolvedValueJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    return switch (source) {
        .string => |text| .{ .string = text },
        .integer => |number| .{ .integer = number },
        .boolean => |flag| .{ .bool = flag },
        .list => |items| blk: {
            var array = std.json.Array.init(arena);
            for (items) |item| try array.append(try resolvedValueJson(context, arena, item));
            break :blk .{ .array = array };
        },
        .object => |fields| blk: {
            var object = std.json.ObjectMap.empty;
            for (fields) |field| try object.put(arena, field.name, try resolvedValueJson(context, arena, field.value));
            break :blk .{ .object = object };
        },
        .output_ref => |reference| .{ .string = try context.resolveOutputString(reference) },
        .secret_ref, .unknown_reason => error.InvalidConfiguration,
    };
}

fn resolvedValueJsonLiteral(arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    return switch (source) {
        .string => |text| .{ .string = text },
        .integer => |number| .{ .integer = number },
        .boolean => |flag| .{ .bool = flag },
        .list => |items| blk: {
            var array = std.json.Array.init(arena);
            for (items) |item| try array.append(try resolvedValueJsonLiteral(arena, item));
            break :blk .{ .array = array };
        },
        .object => |fields| blk: {
            var object = std.json.ObjectMap.empty;
            for (fields) |field| try object.put(arena, field.name, try resolvedValueJsonLiteral(arena, field.value));
            break :blk .{ .object = object };
        },
        .output_ref, .secret_ref, .unknown_reason => error.InvalidConfiguration,
    };
}

fn jsonMatchesValue(desired: value.Value, actual: std.json.Value) bool {
    return switch (desired) {
        .string => |text| actual == .string and std.mem.eql(u8, text, actual.string),
        .integer => |number| actual == .integer and number == actual.integer,
        .boolean => |flag| actual == .bool and flag == actual.bool,
        .object => |fields| blk: {
            const object = jsonObject(actual) orelse break :blk false;
            for (fields) |field| if (!jsonMatchesValue(field.value, object.get(field.name) orelse break :blk false)) break :blk false;
            break :blk true;
        },
        .list => |items| blk: {
            const array = jsonArray(actual) orelse break :blk false;
            if (items.len != array.items.len) break :blk false;
            for (items, array.items) |left, right| if (!jsonMatchesValue(left, right)) break :blk false;
            break :blk true;
        },
        .output_ref, .secret_ref, .unknown_reason => false,
    };
}

fn cloneJson(arena: std.mem.Allocator, source: std.json.Value) ProviderError!std.json.Value {
    return switch (source) {
        .null, .bool, .integer, .float, .number_string, .string => source,
        .array => |items| blk: {
            var result = std.json.Array.init(arena);
            for (items.items) |item| try result.append(try cloneJson(arena, item));
            break :blk .{ .array = result };
        },
        .object => |object| blk: {
            var result = std.json.ObjectMap.empty;
            var iterator = object.iterator();
            while (iterator.next()) |entry| try result.put(arena, entry.key_ptr.*, try cloneJson(arena, entry.value_ptr.*));
            break :blk .{ .object = result };
        },
    };
}

fn jsonContains(desired: std.json.ObjectMap, remote: std.json.ObjectMap) bool {
    var iterator = desired.iterator();
    while (iterator.next()) |entry| if (!jsonValueEquivalent(entry.value_ptr.*, remote.get(entry.key_ptr.*))) return false;
    return true;
}
fn jsonValueEquivalent(desired_optional: ?std.json.Value, remote_optional: ?std.json.Value) bool {
    const desired = desired_optional orelse return remote_optional == null;
    const remote = remote_optional orelse return jsonValueEmpty(desired);
    return switch (desired) {
        .null => remote == .null,
        .bool => |flag| remote == .bool and remote.bool == flag,
        .integer => |number| remote == .integer and remote.integer == number,
        .float => |number| remote == .float and remote.float == number,
        .number_string => |number| remote == .number_string and std.mem.eql(u8, remote.number_string, number),
        .string => |text| remote == .string and std.mem.eql(u8, remote.string, text),
        .array => |items| blk: {
            if (remote != .array or remote.array.items.len != items.items.len) break :blk false;
            for (items.items, remote.array.items) |left, right| if (!jsonValueEquivalent(left, right)) break :blk false;
            break :blk true;
        },
        .object => |object| remote == .object and jsonContains(object, remote.object),
    };
}
fn jsonValueEmpty(candidate: std.json.Value) bool {
    return switch (candidate) {
        .string => |text| text.len == 0,
        .array => |items| items.items.len == 0,
        .object => |object| object.count() == 0,
        .bool => |flag| !flag,
        else => false,
    };
}
fn valueIsEmpty(candidate: value.Value) bool {
    return candidate == .object and candidate.object.len == 0;
}
fn outputString(result: provider_mod.ResourceResult, name: []const u8) ?[]const u8 {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name)) return if (item.value == .string) item.value.string else null;
    return null;
}
fn inputString(input: value.Value, name: []const u8) ?[]const u8 {
    const selected = requiredValue(input, name) catch return null;
    return if (selected == .string) selected.string else null;
}
fn stringEquals(input: ?std.json.Value, expected: []const u8) bool {
    const actual = jsonString(input) orelse return expected.len == 0;
    return std.mem.eql(u8, actual, expected);
}
fn jsonObject(candidate: std.json.Value) ?std.json.ObjectMap {
    return if (candidate == .object) candidate.object else null;
}
fn jsonArray(candidate: std.json.Value) ?std.json.Array {
    return if (candidate == .array) candidate.array else null;
}
fn jsonString(candidate: ?std.json.Value) ?[]const u8 {
    const selected = candidate orelse return null;
    return if (selected == .string) selected.string else null;
}
