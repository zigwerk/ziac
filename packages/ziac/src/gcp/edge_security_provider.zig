const std = @import("std");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;

const Kind = enum {
    backend_bucket,
    security_policy,
    ssl_policy,
    dns_authorization,
    certificate,
    certificate_map,
    certificate_map_entry,
    target_https_proxy,
};

pub const Handler = struct {
    client: *client_mod.Client,
    operation_policy: operation.Policy = .{},
    conflict_retries: usize = 2,

    pub fn read(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (context.operation_handle) |handle| {
            if (isCompute(kind)) {
                try self.waitComputeOperation(context, node, handle);
            } else {
                const response = try self.waitGenericOperationResponseAlloc(context, handle);
                defer context.allocator.free(response);
                return .{ .present = try resultFromJson(context, node, kind, response) };
            }
        }
        const expected = try physicalIdAlloc(context, node, kind);
        defer context.allocator.free(expected);
        const physical = physical_override orelse expected;
        if (!std.mem.eql(u8, expected, physical)) return error.InvalidConfiguration;
        const path = try resourcePathAlloc(context.allocator, kind, physical);
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = apiFor(kind), .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try resultFromJson(context, node, kind, response.body) };
    }

    pub fn importResource(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!provider_mod.ResourceResult {
        const result = try self.read(context, node, physical_id);
        return switch (result) {
            .absent => error.NotFound,
            .present => |present| present,
        };
    }

    pub fn diff(context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        const diff_kind: provider_mod.DiffKind = if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash))
            .noop
        else if (!sameIdentity(node.inputs, observed.observed_inputs, kind))
            .replace
        else switch (kind) {
            .backend_bucket, .security_policy, .ssl_policy => .update,
            .dns_authorization, .certificate, .certificate_map, .certificate_map_entry, .target_https_proxy => .replace,
        };
        return provider_mod.DiffResult.init(context.allocator, diff_kind, switch (diff_kind) {
            .noop => &.{},
            .update => &.{"Edge policy will update with remote concurrency control"},
            .replace => &.{"Edge identity or immutable certificate configuration changed"},
        });
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        const body = try desiredBodyAlloc(context, node, kind, null);
        defer context.allocator.free(body);
        const path = try collectionPathAlloc(context, node, kind);
        defer context.allocator.free(path);
        const handle = try self.startOperation(context, kind, "POST", path, body);
        defer context.allocator.free(handle);
        return pendingResult(context, node, kind, handle);
    }

    pub fn update(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        switch (kind) {
            .backend_bucket, .security_policy, .ssl_policy => {},
            else => return error.InvalidConfiguration,
        }
        try validatePhysicalId(context, node, kind, observed.physical_id);
        const path = try resourcePathAlloc(context.allocator, kind, observed.physical_id);
        defer context.allocator.free(path);
        var conflicts: usize = 0;
        while (true) {
            var remote = try self.request(context, .{ .api = .compute, .method = "GET", .path = path });
            defer remote.deinit(context.allocator);
            const body = try desiredBodyAlloc(context, node, kind, remote.body);
            defer context.allocator.free(body);
            const handle = self.startOperation(context, kind, "PATCH", path, body) catch |err| {
                if ((err == error.PreconditionFailed or err == error.Conflict) and conflicts < self.conflict_retries) {
                    conflicts += 1;
                    continue;
                }
                return err;
            };
            defer context.allocator.free(handle);
            return pendingResult(context, node, kind, handle);
        }
    }

    pub fn delete(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!void {
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysicalId(context, node, kind, physical_id);
        const path = try resourcePathAlloc(context.allocator, kind, physical_id);
        defer context.allocator.free(path);
        const handle = self.startOperation(context, kind, "DELETE", path, "") catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer context.allocator.free(handle);
        if (isCompute(kind)) try self.waitComputeOperation(context, node, handle) else try self.waitGenericOperation(context, handle);
    }

    fn startOperation(self: Handler, context: *provider_mod.OperationContext, kind: Kind, method: []const u8, path: []const u8, body: []const u8) ProviderError![]const u8 {
        var response = try self.request(context, .{ .api = apiFor(kind), .method = method, .path = path, .body = body });
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        return context.allocator.dupe(u8, try requiredJsonString(asObject(parsed.value) orelse return error.ProviderBug, "name")) catch return error.OutOfMemory;
    }

    fn waitComputeOperation(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, handle: []const u8) ProviderError!void {
        const base = try fmt(context.allocator, "{s}/compute/v1", .{std.mem.trimEnd(u8, self.client.endpoints.compute, "/")});
        defer context.allocator.free(base);
        var target = operation.Target.computeGlobalAlloc(context.allocator, base, try requiredString(node.inputs, "project_id"), handle) catch return error.OutOfMemory;
        defer target.deinit(context.allocator);
        var completed = try operation.waitAlloc(self.client, context, target, self.operation_policy);
        completed.deinit(context.allocator);
    }

    fn waitGenericOperation(self: Handler, context: *provider_mod.OperationContext, handle: []const u8) ProviderError!void {
        const response = try self.waitGenericOperationResponseAlloc(context, handle);
        context.allocator.free(response);
    }

    fn waitGenericOperationResponseAlloc(self: Handler, context: *provider_mod.OperationContext, handle: []const u8) ProviderError![]const u8 {
        const base = try fmt(context.allocator, "{s}/v1", .{std.mem.trimEnd(u8, self.client.endpoints.certificate_manager, "/")});
        defer context.allocator.free(base);
        var target = operation.Target.genericAlloc(context.allocator, base, handle) catch return error.OutOfMemory;
        defer target.deinit(context.allocator);
        var completed = try operation.waitAlloc(self.client, context, target, self.operation_policy);
        defer completed.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, completed.payload, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const response = (asObject(parsed.value) orelse return error.ProviderBug).get("response") orelse return error.ProviderBug;
        return std.json.Stringify.valueAlloc(context.allocator, response, .{}) catch error.OutOfMemory;
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, request_value: client_mod.Request) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, request_value, &diagnostic);
    }
};

pub fn supports(node: resource.ResourceNode) bool {
    return kindOf(node) != null;
}

fn kindOf(node: resource.ResourceNode) ?Kind {
    const mappings = .{
        .{ "gcp.compute.BackendBucket", Kind.backend_bucket },
        .{ "gcp.compute.SecurityPolicy", Kind.security_policy },
        .{ "gcp.compute.SslPolicy", Kind.ssl_policy },
        .{ "gcp.certificatemanager.DnsAuthorization", Kind.dns_authorization },
        .{ "gcp.certificatemanager.Certificate", Kind.certificate },
        .{ "gcp.certificatemanager.CertificateMap", Kind.certificate_map },
        .{ "gcp.certificatemanager.CertificateMapEntry", Kind.certificate_map_entry },
        .{ "gcp.compute.CertificateMapTargetHttpsProxy", Kind.target_https_proxy },
    };
    inline for (mappings) |mapping| if (std.mem.eql(u8, node.type_name, mapping[0])) return mapping[1];
    return null;
}

fn isCompute(kind: Kind) bool {
    return switch (kind) {
        .backend_bucket, .security_policy, .ssl_policy, .target_https_proxy => true,
        else => false,
    };
}

fn apiFor(kind: Kind) client_mod.Api {
    return if (isCompute(kind)) .compute else .certificate_manager;
}

fn collectionName(kind: Kind) []const u8 {
    return switch (kind) {
        .backend_bucket => "backendBuckets",
        .security_policy => "securityPolicies",
        .ssl_policy => "sslPolicies",
        .dns_authorization => "dnsAuthorizations",
        .certificate => "certificates",
        .certificate_map => "certificateMaps",
        .certificate_map_entry => "certificateMapEntries",
        .target_https_proxy => "targetHttpsProxies",
    };
}

fn collectionPathAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    const project = try requiredString(node.inputs, "project_id");
    if (isCompute(kind)) return fmt(context.allocator, "/compute/v1/projects/{s}/global/{s}", .{ project, collectionName(kind) });
    const name = try requiredString(node.inputs, "name");
    if (kind == .certificate_map_entry) {
        const map = try resolveString(context, try requiredValue(node.inputs, "map"));
        return fmt(context.allocator, "/v1/{s}/certificateMapEntries?certificateMapEntryId={s}", .{ std.mem.trimStart(u8, map, "/"), name });
    }
    const location = try requiredString(node.inputs, "location");
    const id_parameter = switch (kind) {
        .dns_authorization => "dnsAuthorizationId",
        .certificate => "certificateId",
        .certificate_map => "certificateMapId",
        else => unreachable,
    };
    return fmt(context.allocator, "/v1/projects/{s}/locations/{s}/{s}?{s}={s}", .{ project, location, collectionName(kind), id_parameter, name });
}

fn physicalIdAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    const project = try requiredString(node.inputs, "project_id");
    const name = try requiredString(node.inputs, "name");
    if (isCompute(kind)) return fmt(context.allocator, "projects/{s}/global/{s}/{s}", .{ project, collectionName(kind), name });
    if (kind == .certificate_map_entry) {
        const map = try resolveString(context, try requiredValue(node.inputs, "map"));
        return fmt(context.allocator, "{s}/certificateMapEntries/{s}", .{ std.mem.trimEnd(u8, map, "/"), name });
    }
    return fmt(context.allocator, "projects/{s}/locations/{s}/{s}/{s}", .{ project, try requiredString(node.inputs, "location"), collectionName(kind), name });
}

fn validatePhysicalId(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, physical_id: []const u8) ProviderError!void {
    const expected = try physicalIdAlloc(context, node, kind);
    defer context.allocator.free(expected);
    if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
}

fn resourcePathAlloc(allocator: std.mem.Allocator, kind: Kind, physical_id: []const u8) ProviderError![]const u8 {
    const normalized = std.mem.trimStart(u8, physical_id, "/");
    return if (isCompute(kind))
        fmt(allocator, "/compute/v1/{s}", .{normalized})
    else
        fmt(allocator, "/v1/{s}", .{normalized});
}

fn desiredBodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, remote_json: ?[]const u8) ProviderError![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root: std.json.ObjectMap = .empty;
    if (isCompute(kind)) try root.put(arena, "name", .{ .string = try requiredString(node.inputs, "name") });
    switch (kind) {
        .backend_bucket => try backendBucketBody(arena, context, node, &root),
        .security_policy => try securityPolicyBody(arena, node, &root),
        .ssl_policy => try sslPolicyBody(arena, node, &root),
        .dns_authorization => {
            try root.put(arena, "domain", .{ .string = try requiredString(node.inputs, "domain") });
            try root.put(arena, "type", .{ .string = try requiredString(node.inputs, "authorization_type") });
        },
        .certificate => try certificateBody(arena, context, node, &root),
        .certificate_map => {},
        .certificate_map_entry => try certificateMapEntryBody(arena, context, node, &root),
        .target_https_proxy => try targetProxyBody(arena, context, node, &root),
    }
    if (remote_json) |bytes| if (fingerprintFromJson(arena, bytes)) |fingerprint| try root.put(arena, "fingerprint", .{ .string = fingerprint });
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch error.OutOfMemory;
}

fn backendBucketBody(allocator: std.mem.Allocator, context: *provider_mod.OperationContext, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    try root.put(allocator, "bucketName", .{ .string = try resolveString(context, try requiredValue(node.inputs, "bucket")) });
    try root.put(allocator, "enableCdn", .{ .bool = try requiredBoolean(node.inputs, "enable_cdn") });
    try root.put(allocator, "compressionMode", .{ .string = try requiredString(node.inputs, "compression_mode") });
    const edge_policy = try resolveOptionalString(context, try requiredValue(node.inputs, "edge_security_policy"));
    if (edge_policy.len > 0) try root.put(allocator, "edgeSecurityPolicy", .{ .string = edge_policy });
    var cache: std.json.ObjectMap = .empty;
    try cache.put(allocator, "cacheMode", .{ .string = try requiredString(node.inputs, "cache_mode") });
    try cache.put(allocator, "clientTtl", .{ .integer = try requiredInteger(node.inputs, "client_ttl_seconds") });
    try cache.put(allocator, "defaultTtl", .{ .integer = try requiredInteger(node.inputs, "default_ttl_seconds") });
    try cache.put(allocator, "maxTtl", .{ .integer = try requiredInteger(node.inputs, "max_ttl_seconds") });
    try cache.put(allocator, "negativeCaching", .{ .bool = try requiredBoolean(node.inputs, "negative_caching") });
    try cache.put(allocator, "serveWhileStale", .{ .integer = try requiredInteger(node.inputs, "serve_while_stale_seconds") });
    try cache.put(allocator, "requestCoalescing", .{ .bool = try requiredBoolean(node.inputs, "request_coalescing") });
    try cache.put(allocator, "signedUrlCacheMaxAgeSec", .{ .integer = try requiredInteger(node.inputs, "signed_url_cache_max_age_seconds") });
    var key: std.json.ObjectMap = .empty;
    try key.put(allocator, "includeHost", .{ .bool = try requiredBoolean(node.inputs, "include_host") });
    try key.put(allocator, "includeProtocol", .{ .bool = try requiredBoolean(node.inputs, "include_protocol") });
    try key.put(allocator, "includeQueryString", .{ .bool = try requiredBoolean(node.inputs, "include_query_string") });
    try cache.put(allocator, "cacheKeyPolicy", .{ .object = key });
    try root.put(allocator, "cdnPolicy", .{ .object = cache });
}

fn securityPolicyBody(allocator: std.mem.Allocator, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    try root.put(allocator, "type", .{ .string = try requiredString(node.inputs, "policy_type") });
    var rules = std.json.Array.init(allocator);
    for (try requiredList(node.inputs, "rules")) |candidate| {
        var rule: std.json.ObjectMap = .empty;
        try rule.put(allocator, "priority", .{ .integer = try requiredInteger(candidate, "priority") });
        try rule.put(allocator, "description", .{ .string = try requiredString(candidate, "description") });
        try rule.put(allocator, "action", .{ .string = try requiredString(candidate, "action") });
        try rule.put(allocator, "preview", .{ .bool = try requiredBoolean(candidate, "preview") });
        var match: std.json.ObjectMap = .empty;
        const match_kind = try requiredString(candidate, "match_kind");
        if (std.mem.eql(u8, match_kind, "EXPR")) {
            var expr: std.json.ObjectMap = .empty;
            try expr.put(allocator, "expression", .{ .string = try valueString(try requiredValue(candidate, "match_values")) });
            try match.put(allocator, "expr", .{ .object = expr });
        } else {
            try match.put(allocator, "versionedExpr", .{ .string = match_kind });
            var config: std.json.ObjectMap = .empty;
            try config.put(allocator, "srcIpRanges", try stringListJson(allocator, try requiredValue(candidate, "match_values")));
            try match.put(allocator, "config", .{ .object = config });
        }
        try rule.put(allocator, "match", .{ .object = match });
        if (std.mem.eql(u8, try requiredString(candidate, "action"), "throttle")) {
            var rate_limit: std.json.ObjectMap = .empty;
            var threshold: std.json.ObjectMap = .empty;
            try threshold.put(allocator, "count", .{ .integer = try requiredInteger(candidate, "rate_limit_count") });
            try threshold.put(allocator, "intervalSec", .{ .integer = try requiredInteger(candidate, "rate_limit_interval_seconds") });
            try rate_limit.put(allocator, "rateLimitThreshold", .{ .object = threshold });
            try rate_limit.put(allocator, "conformAction", .{ .string = "allow" });
            try rate_limit.put(allocator, "exceedAction", .{ .string = "deny(429)" });
            try rule.put(allocator, "rateLimitOptions", .{ .object = rate_limit });
        }
        try rules.append(.{ .object = rule });
    }
    try root.put(allocator, "rules", .{ .array = rules });
}

fn sslPolicyBody(allocator: std.mem.Allocator, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    try root.put(allocator, "minTlsVersion", .{ .string = try requiredString(node.inputs, "minimum_tls_version") });
    try root.put(allocator, "profile", .{ .string = try requiredString(node.inputs, "profile") });
    try root.put(allocator, "customFeatures", try stringListJson(allocator, try requiredValue(node.inputs, "custom_features")));
}

fn certificateBody(allocator: std.mem.Allocator, context: *provider_mod.OperationContext, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    var managed: std.json.ObjectMap = .empty;
    try managed.put(allocator, "domains", try stringListJson(allocator, try requiredValue(node.inputs, "domains")));
    try managed.put(allocator, "dnsAuthorizations", try resolvedStringListJson(allocator, context, try requiredValue(node.inputs, "dns_authorizations")));
    try root.put(allocator, "managed", .{ .object = managed });
    try root.put(allocator, "scope", .{ .string = try requiredString(node.inputs, "scope") });
}

fn certificateMapEntryBody(allocator: std.mem.Allocator, context: *provider_mod.OperationContext, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    if (std.mem.eql(u8, try requiredString(node.inputs, "matcher_kind"), "PRIMARY"))
        try root.put(allocator, "matcher", .{ .string = "PRIMARY" })
    else
        try root.put(allocator, "hostname", .{ .string = try requiredString(node.inputs, "matcher_value") });
    try root.put(allocator, "certificates", try resolvedStringListJson(allocator, context, try requiredValue(node.inputs, "certificates")));
}

fn targetProxyBody(allocator: std.mem.Allocator, context: *provider_mod.OperationContext, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    try root.put(allocator, "urlMap", .{ .string = try resolveString(context, try requiredValue(node.inputs, "url_map")) });
    const map = try resolveString(context, try requiredValue(node.inputs, "certificate_map"));
    const map_url = try std.fmt.allocPrint(allocator, "//certificatemanager.googleapis.com/{s}", .{std.mem.trimStart(u8, map, "/")});
    try root.put(allocator, "certificateMap", .{ .string = map_url });
    try root.put(allocator, "quicOverride", .{ .string = try requiredString(node.inputs, "quic_override") });
    const ssl_policy = try resolveOptionalString(context, try requiredValue(node.inputs, "ssl_policy"));
    if (ssl_policy.len > 0) try root.put(allocator, "sslPolicy", .{ .string = ssl_policy });
}

fn resultFromJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, body: []const u8) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = asObject(parsed.value) orelse return error.ProviderBug;
    const expected = try physicalIdAlloc(context, node, kind);
    defer context.allocator.free(expected);
    const physical = if (isCompute(kind)) expected else jsonString(root.get("name")) orelse expected;
    if (!std.mem.eql(u8, expected, physical)) return error.InvalidConfiguration;
    var observed = value.Value.initOwned(context.allocator, node.inputs) catch |err| return mapValueError(err);
    defer observed.deinit(context.allocator);
    try normalizeObserved(context, &observed, kind, root);
    var outputs: [4]state.StateOutput = undefined;
    var count: usize = 0;
    if (isCompute(kind)) {
        outputs[count] = .{ .name = "self_link", .value = .{ .string = jsonString(root.get("selfLink")) orelse "" } };
        count += 1;
        outputs[count] = .{ .name = "fingerprint", .value = .{ .string = jsonString(root.get("fingerprint")) orelse "" } };
        count += 1;
    } else {
        outputs[count] = .{ .name = "name", .value = .{ .string = physical } };
        count += 1;
        if (kind == .dns_authorization) {
            if (asObject(root.get("dnsResourceRecord") orelse .null)) |record| {
                outputs[count] = .{ .name = "dns_record_name", .value = .{ .string = jsonString(record.get("name")) orelse "" } };
                count += 1;
                outputs[count] = .{ .name = "dns_record_type", .value = .{ .string = jsonString(record.get("type")) orelse "" } };
                count += 1;
                outputs[count] = .{ .name = "dns_record_data", .value = .{ .string = jsonString(record.get("data")) orelse "" } };
                count += 1;
            }
        } else if (kind == .certificate) {
            const managed = asObject(root.get("managed") orelse .null);
            outputs[count] = .{ .name = "state", .value = .{ .string = if (managed) |item| jsonString(item.get("state")) orelse "" else "" } };
            count += 1;
        }
    }
    return provider_mod.ResourceResult.init(context.allocator, physical, observed, outputs[0..count], null);
}

fn normalizeObserved(context: *provider_mod.OperationContext, observed: *value.Value, kind: Kind, remote: std.json.ObjectMap) ProviderError!void {
    const allocator = context.allocator;
    switch (kind) {
        .backend_bucket => {
            if (jsonString(remote.get("bucketName"))) |present| try replaceResolvedString(context, observed, "bucket", present);
            try replaceResolvedString(context, observed, "edge_security_policy", canonicalResourceName(jsonString(remote.get("edgeSecurityPolicy")) orelse ""));
            if (jsonBool(remote.get("enableCdn"))) |present| try replaceValue(allocator, observed, "enable_cdn", .{ .boolean = present });
            if (jsonString(remote.get("compressionMode"))) |present| try replaceValue(allocator, observed, "compression_mode", .{ .string = present });
            if (asObject(remote.get("cdnPolicy") orelse .null)) |cache| {
                if (jsonString(cache.get("cacheMode"))) |present| try replaceValue(allocator, observed, "cache_mode", .{ .string = present });
                if (jsonIntegerOrString(cache.get("clientTtl"))) |present| try replaceValue(allocator, observed, "client_ttl_seconds", .{ .integer = present });
                if (jsonIntegerOrString(cache.get("defaultTtl"))) |present| try replaceValue(allocator, observed, "default_ttl_seconds", .{ .integer = present });
                if (jsonIntegerOrString(cache.get("maxTtl"))) |present| try replaceValue(allocator, observed, "max_ttl_seconds", .{ .integer = present });
                if (jsonBool(cache.get("negativeCaching"))) |present| try replaceValue(allocator, observed, "negative_caching", .{ .boolean = present });
                if (jsonIntegerOrString(cache.get("serveWhileStale"))) |present| try replaceValue(allocator, observed, "serve_while_stale_seconds", .{ .integer = present });
                if (jsonBool(cache.get("requestCoalescing"))) |present| try replaceValue(allocator, observed, "request_coalescing", .{ .boolean = present });
                if (jsonIntegerOrString(cache.get("signedUrlCacheMaxAgeSec"))) |present| try replaceValue(allocator, observed, "signed_url_cache_max_age_seconds", .{ .integer = present });
                if (asObject(cache.get("cacheKeyPolicy") orelse .null)) |key| {
                    if (jsonBool(key.get("includeHost"))) |present| try replaceValue(allocator, observed, "include_host", .{ .boolean = present });
                    if (jsonBool(key.get("includeProtocol"))) |present| try replaceValue(allocator, observed, "include_protocol", .{ .boolean = present });
                    if (jsonBool(key.get("includeQueryString"))) |present| try replaceValue(allocator, observed, "include_query_string", .{ .boolean = present });
                }
            }
        },
        .security_policy => {
            if (jsonString(remote.get("type"))) |present| try replaceValue(allocator, observed, "policy_type", .{ .string = present });
            var rules = try securityRulesFromJsonAlloc(allocator, remote.get("rules") orelse return error.ProviderBug);
            defer rules.deinit(allocator);
            try replaceValue(allocator, observed, "rules", rules);
        },
        .ssl_policy => {
            if (jsonString(remote.get("minTlsVersion"))) |present| try replaceValue(allocator, observed, "minimum_tls_version", .{ .string = present });
            if (jsonString(remote.get("profile"))) |present| try replaceValue(allocator, observed, "profile", .{ .string = present });
            if (remote.get("customFeatures")) |present| try replaceStringListFromJson(allocator, observed, "custom_features", present, false);
        },
        .dns_authorization => {
            if (jsonString(remote.get("domain"))) |present| try replaceValue(allocator, observed, "domain", .{ .string = present });
            if (jsonString(remote.get("type"))) |present| try replaceValue(allocator, observed, "authorization_type", .{ .string = present });
        },
        .certificate => {
            const managed = asObject(remote.get("managed") orelse return error.ProviderBug) orelse return error.ProviderBug;
            try replaceStringListFromJson(allocator, observed, "domains", managed.get("domains") orelse return error.ProviderBug, false);
            try replaceResolvedStringList(context, observed, "dns_authorizations", managed.get("dnsAuthorizations") orelse return error.ProviderBug);
            try replaceValue(allocator, observed, "scope", .{ .string = jsonString(remote.get("scope")) orelse "DEFAULT" });
        },
        .certificate_map => {},
        .certificate_map_entry => {
            if (jsonString(remote.get("matcher"))) |matcher| {
                try replaceValue(allocator, observed, "matcher_kind", .{ .string = matcher });
                try replaceValue(allocator, observed, "matcher_value", .{ .string = matcher });
            } else if (jsonString(remote.get("hostname"))) |hostname| {
                try replaceValue(allocator, observed, "matcher_kind", .{ .string = "HOSTNAME" });
                try replaceValue(allocator, observed, "matcher_value", .{ .string = hostname });
            } else return error.ProviderBug;
            try replaceResolvedStringList(context, observed, "certificates", remote.get("certificates") orelse return error.ProviderBug);
            if (jsonString(remote.get("name"))) |name| if (parentBefore(name, "/certificateMapEntries/")) |map| try replaceResolvedString(context, observed, "map", map);
        },
        .target_https_proxy => {
            if (jsonString(remote.get("urlMap"))) |present| try replaceResolvedString(context, observed, "url_map", canonicalResourceName(present));
            if (jsonString(remote.get("certificateMap"))) |present| try replaceResolvedString(context, observed, "certificate_map", canonicalResourceName(present));
            try replaceResolvedString(context, observed, "ssl_policy", canonicalResourceName(jsonString(remote.get("sslPolicy")) orelse ""));
            if (jsonString(remote.get("quicOverride"))) |present| try replaceValue(allocator, observed, "quic_override", .{ .string = present });
        },
    }
}

fn pendingResult(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, handle: []const u8) ProviderError!provider_mod.ResourceResult {
    const physical = try physicalIdAlloc(context, node, kind);
    defer context.allocator.free(physical);
    var result = try provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &.{}, handle);
    result.completed = false;
    return result;
}

fn sameIdentity(desired: value.Value, observed: value.Value, kind: Kind) bool {
    const common = [_][]const u8{ "project_id", "name" };
    for (common) |field| if (!equalField(desired, observed, field)) return false;
    return switch (kind) {
        .backend_bucket => equalField(desired, observed, "bucket"),
        .security_policy => equalField(desired, observed, "policy_type"),
        .ssl_policy, .target_https_proxy => true,
        .dns_authorization, .certificate, .certificate_map => equalField(desired, observed, "location"),
        .certificate_map_entry => equalField(desired, observed, "location") and equalField(desired, observed, "map"),
    };
}

fn equalField(left: value.Value, right: value.Value, name: []const u8) bool {
    const left_value = requiredValue(left, name) catch return false;
    const right_value = requiredValue(right, name) catch return false;
    return valuesEqual(left_value, right_value);
}

fn valuesEqual(left: value.Value, right: value.Value) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .string => |text| std.mem.eql(u8, text, right.string),
        .integer => |number| number == right.integer,
        .boolean => |boolean| boolean == right.boolean,
        .unknown_reason => |text| std.mem.eql(u8, text, right.unknown_reason),
        .output_ref => |reference| std.mem.eql(u8, reference.resource_id, right.output_ref.resource_id) and std.mem.eql(u8, reference.field, right.output_ref.field),
        .secret_ref => |reference| std.mem.eql(u8, reference.provider, right.secret_ref.provider) and std.mem.eql(u8, reference.resource, right.secret_ref.resource) and optionalTextEqual(reference.version, right.secret_ref.version) and optionalTextEqual(reference.field, right.secret_ref.field),
        .list => |items| blk: {
            if (items.len != right.list.len) break :blk false;
            for (items, right.list) |left_item, right_item| if (!valuesEqual(left_item, right_item)) break :blk false;
            break :blk true;
        },
        .object => |fields| blk: {
            if (fields.len != right.object.len) break :blk false;
            for (fields, right.object) |left_field, right_field| {
                if (!std.mem.eql(u8, left_field.name, right_field.name) or !valuesEqual(left_field.value, right_field.value)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn optionalTextEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if ((left == null) != (right == null)) return false;
    return if (left) |text| std.mem.eql(u8, text, right.?) else true;
}

fn fingerprintFromJson(allocator: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch return null;
    return jsonString((asObject(parsed) orelse return null).get("fingerprint"));
}

fn replaceValue(allocator: std.mem.Allocator, input: *value.Value, name: []const u8, replacement: value.Value) ProviderError!void {
    if (input.* != .object) return error.ProviderBug;
    const fields: []value.Field = @constCast(input.object);
    for (fields) |*field| {
        if (!std.mem.eql(u8, field.name, name)) continue;
        const owned = replacement.clone(allocator) catch |err| return mapValueError(err);
        field.value.deinit(allocator);
        field.value = owned;
        return;
    }
}

fn replaceResolvedString(context: *provider_mod.OperationContext, inputs: *value.Value, name: []const u8, remote: []const u8) ProviderError!void {
    const desired = try requiredValue(inputs.*, name);
    const resolved = resolveString(context, desired) catch "";
    if (!std.mem.eql(u8, canonicalResourceName(resolved), canonicalResourceName(remote)))
        try replaceValue(context.allocator, inputs, name, .{ .string = canonicalResourceName(remote) });
}

fn replaceResolvedStringList(context: *provider_mod.OperationContext, inputs: *value.Value, name: []const u8, remote_json: std.json.Value) ProviderError!void {
    const remote = asArray(remote_json) orelse return error.ProviderBug;
    const desired = try asValueList(try requiredValue(inputs.*, name));
    if (try resolvedListEqualsJson(context, desired, remote)) return;
    try replaceStringListFromJson(context.allocator, inputs, name, remote_json, true);
}

fn resolvedListEqualsJson(context: *provider_mod.OperationContext, desired: []const value.Value, remote: std.json.Array) ProviderError!bool {
    if (desired.len != remote.items.len) return false;
    const matched = context.allocator.alloc(bool, remote.items.len) catch return error.OutOfMemory;
    defer context.allocator.free(matched);
    @memset(matched, false);
    for (desired) |candidate| {
        const resolved = resolveString(context, candidate) catch return false;
        var found = false;
        for (remote.items, 0..) |remote_item, index| {
            if (matched[index]) continue;
            const remote_string = jsonString(remote_item) orelse return error.ProviderBug;
            if (std.mem.eql(u8, canonicalResourceName(resolved), canonicalResourceName(remote_string))) {
                matched[index] = true;
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn replaceStringListFromJson(allocator: std.mem.Allocator, inputs: *value.Value, name: []const u8, remote_json: std.json.Value, canonicalize: bool) ProviderError!void {
    const remote = asArray(remote_json) orelse return error.ProviderBug;
    const strings = allocator.alloc([]const u8, remote.items.len) catch return error.OutOfMemory;
    defer allocator.free(strings);
    for (remote.items, 0..) |item, index| {
        const text = jsonString(item) orelse return error.ProviderBug;
        strings[index] = if (canonicalize) canonicalResourceName(text) else text;
    }
    var replacement = try stringListValueAlloc(allocator, strings);
    defer replacement.deinit(allocator);
    try replaceValue(allocator, inputs, name, replacement);
}

fn stringListValueAlloc(allocator: std.mem.Allocator, source: []const []const u8) ProviderError!value.Value {
    const sorted = allocator.dupe([]const u8, source) catch return error.OutOfMemory;
    defer allocator.free(sorted);
    std.mem.sort([]const u8, sorted, {}, lessString);
    const items = allocator.alloc(value.Value, sorted.len) catch return error.OutOfMemory;
    defer allocator.free(items);
    for (sorted, 0..) |item, index| items[index] = .{ .string = item };
    return value.Value.initOwned(allocator, .{ .list = items }) catch |err| return mapValueError(err);
}

fn securityRulesFromJsonAlloc(allocator: std.mem.Allocator, remote_json: std.json.Value) ProviderError!value.Value {
    const remote = asArray(remote_json) orelse return error.ProviderBug;
    const items = allocator.alloc(value.Value, remote.items.len) catch return error.OutOfMemory;
    defer allocator.free(items);
    var initialized: usize = 0;
    defer for (items[0..initialized]) |*item| item.deinit(allocator);
    for (remote.items, 0..) |candidate, index| {
        const rule = asObject(candidate) orelse return error.ProviderBug;
        const match = asObject(rule.get("match") orelse return error.ProviderBug) orelse return error.ProviderBug;
        const match_kind: []const u8, var match_values: value.Value = if (asObject(match.get("expr") orelse .null)) |expression|
            .{ "EXPR", value.Value.initOwned(allocator, .{ .string = jsonString(expression.get("expression")) orelse return error.ProviderBug }) catch |err| return mapValueError(err) }
        else blk: {
            const config = asObject(match.get("config") orelse return error.ProviderBug) orelse return error.ProviderBug;
            const ranges = try stringListFromJsonAlloc(allocator, config.get("srcIpRanges") orelse return error.ProviderBug, false);
            break :blk .{ jsonString(match.get("versionedExpr")) orelse return error.ProviderBug, ranges };
        };
        defer match_values.deinit(allocator);
        const action = jsonString(rule.get("action")) orelse return error.ProviderBug;
        var rate_count: i64 = 0;
        var rate_interval: i64 = 0;
        if (std.mem.eql(u8, action, "throttle")) {
            const options = asObject(rule.get("rateLimitOptions") orelse return error.ProviderBug) orelse return error.ProviderBug;
            const threshold = asObject(options.get("rateLimitThreshold") orelse return error.ProviderBug) orelse return error.ProviderBug;
            rate_count = jsonIntegerOrString(threshold.get("count")) orelse return error.ProviderBug;
            rate_interval = jsonIntegerOrString(threshold.get("intervalSec")) orelse return error.ProviderBug;
        }
        const fields = [_]value.Field{
            .{ .name = "action", .value = .{ .string = action } },
            .{ .name = "description", .value = .{ .string = jsonString(rule.get("description")) orelse "" } },
            .{ .name = "match_kind", .value = .{ .string = match_kind } },
            .{ .name = "match_values", .value = match_values },
            .{ .name = "preview", .value = .{ .boolean = jsonBool(rule.get("preview")) orelse false } },
            .{ .name = "priority", .value = .{ .integer = jsonIntegerOrString(rule.get("priority")) orelse return error.ProviderBug } },
            .{ .name = "rate_limit_count", .value = .{ .integer = rate_count } },
            .{ .name = "rate_limit_interval_seconds", .value = .{ .integer = rate_interval } },
        };
        items[index] = value.Value.initOwned(allocator, .{ .object = &fields }) catch |err| return mapValueError(err);
        initialized += 1;
    }
    std.mem.sort(value.Value, items, {}, lessRuleValue);
    return value.Value.initOwned(allocator, .{ .list = items }) catch |err| return mapValueError(err);
}

fn stringListFromJsonAlloc(allocator: std.mem.Allocator, remote_json: std.json.Value, canonicalize: bool) ProviderError!value.Value {
    const remote = asArray(remote_json) orelse return error.ProviderBug;
    const strings = allocator.alloc([]const u8, remote.items.len) catch return error.OutOfMemory;
    defer allocator.free(strings);
    for (remote.items, 0..) |item, index| {
        const text = jsonString(item) orelse return error.ProviderBug;
        strings[index] = if (canonicalize) canonicalResourceName(text) else text;
    }
    return stringListValueAlloc(allocator, strings);
}

fn lessRuleValue(_: void, left: value.Value, right: value.Value) bool {
    return (requiredInteger(left, "priority") catch 0) < (requiredInteger(right, "priority") catch 0);
}

fn lessString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn canonicalResourceName(input: []const u8) []const u8 {
    if (std.mem.indexOf(u8, input, "projects/")) |start| return input[start..];
    return std.mem.trimStart(u8, input, "/");
}

fn parentBefore(input: []const u8, marker: []const u8) ?[]const u8 {
    const end = std.mem.indexOf(u8, input, marker) orelse return null;
    return input[0..end];
}

fn stringListJson(allocator: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    var array = std.json.Array.init(allocator);
    for (try asValueList(input)) |item| try array.append(.{ .string = try valueString(item) });
    return .{ .array = array };
}

fn resolvedStringListJson(allocator: std.mem.Allocator, context: *provider_mod.OperationContext, input: value.Value) ProviderError!std.json.Value {
    var array = std.json.Array.init(allocator);
    for (try asValueList(input)) |item| try array.append(.{ .string = try resolveString(context, item) });
    return .{ .array = array };
}

fn requiredValue(input: value.Value, name: []const u8) ProviderError!value.Value {
    if (input != .object) return error.InvalidConfiguration;
    for (input.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return error.InvalidConfiguration;
}

fn requiredString(input: value.Value, name: []const u8) ProviderError![]const u8 {
    return valueString(try requiredValue(input, name));
}

fn requiredInteger(input: value.Value, name: []const u8) ProviderError!i64 {
    return switch (try requiredValue(input, name)) {
        .integer => |present| present,
        else => error.InvalidConfiguration,
    };
}

fn requiredBoolean(input: value.Value, name: []const u8) ProviderError!bool {
    return switch (try requiredValue(input, name)) {
        .boolean => |present| present,
        else => error.InvalidConfiguration,
    };
}

fn requiredList(input: value.Value, name: []const u8) ProviderError![]const value.Value {
    return asValueList(try requiredValue(input, name));
}

fn asValueList(input: value.Value) ProviderError![]const value.Value {
    return switch (input) {
        .list => |items| items,
        else => error.InvalidConfiguration,
    };
}

fn valueString(input: value.Value) ProviderError![]const u8 {
    return switch (input) {
        .string => |text| text,
        else => error.InvalidConfiguration,
    };
}

fn resolveString(context: *provider_mod.OperationContext, input: value.Value) ProviderError![]const u8 {
    return switch (input) {
        .string => |text| text,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}

fn resolveOptionalString(context: *provider_mod.OperationContext, input: value.Value) ProviderError![]const u8 {
    return switch (input) {
        .string => |text| text,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}

fn asObject(candidate: std.json.Value) ?std.json.ObjectMap {
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

fn jsonInteger(candidate: ?std.json.Value) ?i64 {
    const present = candidate orelse return null;
    return switch (present) {
        .integer => |number| number,
        else => null,
    };
}

fn jsonIntegerOrString(candidate: ?std.json.Value) ?i64 {
    const present = candidate orelse return null;
    return switch (present) {
        .integer => |number| number,
        .string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
}

fn jsonBool(candidate: ?std.json.Value) ?bool {
    const present = candidate orelse return null;
    return switch (present) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn asArray(candidate: std.json.Value) ?std.json.Array {
    return switch (candidate) {
        .array => |array| array,
        else => null,
    };
}

fn requiredJsonString(object: std.json.ObjectMap, name: []const u8) ProviderError![]const u8 {
    return jsonString(object.get(name)) orelse error.ProviderBug;
}

fn mapValueError(err: anyerror) ProviderError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ProviderBug,
    };
}

fn fmt(allocator: std.mem.Allocator, comptime format: []const u8, args: anytype) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, format, args) catch error.OutOfMemory;
}
