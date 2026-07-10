const std = @import("std");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;

const Kind = enum {
    global_address,
    regional_neg,
    backend_service,
    url_map,
    redirect_url_map,
    managed_ssl_certificate,
    target_http_proxy,
    target_https_proxy,
    global_forwarding_rule,
};

pub const CertificateReadinessPolicy = struct {
    poll_interval_millis: u64 = 5_000,
    max_transient_failures: usize = 4,
};

pub const Handler = struct {
    client: *client_mod.Client,
    operation_policy: operation.Policy,
    conflict_retries: usize,

    pub fn read(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_override: ?[]const u8,
    ) ProviderError!provider_mod.ReadResult {
        const resource_kind = kind(node) orelse return error.InvalidConfiguration;
        if (context.operation_handle) |handle| try self.waitOperation(context, node, resource_kind, handle);
        const generated = if (physical_override == null) try physicalIdAlloc(context.allocator, node, resource_kind) else null;
        defer if (generated) |physical_id| context.allocator.free(physical_id);
        const physical_id = physical_override orelse generated.?;
        const path = try restResourcePathAlloc(context.allocator, physical_id);
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .compute, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try resultFromJson(context, node, resource_kind, response.body) };
    }

    pub fn diff(
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        observed: *const provider_mod.ResourceResult,
    ) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        const resource_kind = kind(node) orelse return error.InvalidConfiguration;
        const diff_kind: provider_mod.DiffKind = if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash))
            .noop
        else switch (resource_kind) {
            .backend_service, .url_map, .redirect_url_map, .target_http_proxy, .target_https_proxy => if (sameIdentity(node.inputs, observed.observed_inputs)) .update else .replace,
            .global_address, .regional_neg, .managed_ssl_certificate, .global_forwarding_rule => .replace,
        };
        const reasons: []const []const u8 = if (diff_kind == .noop) &.{} else &.{"Compute desired state differs from observed resource"};
        return provider_mod.DiffResult.init(context.allocator, diff_kind, reasons);
    }

    pub fn create(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        const resource_kind = kind(node) orelse return error.InvalidConfiguration;
        const body = try desiredBodyAlloc(context, node, resource_kind);
        defer context.allocator.free(body);
        const path = try collectionPathAlloc(context.allocator, node, resource_kind);
        defer context.allocator.free(path);
        const handle = try self.startOperation(context, path, "POST", body);
        defer context.allocator.free(handle);
        return pendingResult(context.allocator, node, resource_kind, handle);
    }

    pub fn update(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!provider_mod.ResourceResult {
        const resource_kind = kind(node) orelse return error.InvalidConfiguration;
        switch (resource_kind) {
            .backend_service, .url_map, .redirect_url_map, .target_http_proxy, .target_https_proxy => {},
            else => return error.InvalidConfiguration,
        }
        const path = try restResourcePathAlloc(context.allocator, physical_id);
        defer context.allocator.free(path);
        var conflicts: usize = 0;
        while (true) {
            var remote = try self.request(context, .{ .api = .compute, .method = "GET", .path = path });
            defer remote.deinit(context.allocator);
            const merged = try mergeUpdateBodyAlloc(context, node, resource_kind, remote.body);
            defer context.allocator.free(merged);
            const method = if (resource_kind == .backend_service) "PUT" else "PATCH";
            const handle = self.startOperation(context, path, method, merged) catch |err| {
                if (err == error.Conflict and conflicts < self.conflict_retries) {
                    conflicts += 1;
                    continue;
                }
                return err;
            };
            defer context.allocator.free(handle);
            return pendingResult(context.allocator, node, resource_kind, handle);
        }
    }

    pub fn delete(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!void {
        const resource_kind = kind(node) orelse return error.InvalidConfiguration;
        const path = try restResourcePathAlloc(context.allocator, physical_id);
        defer context.allocator.free(path);
        const handle = self.startOperation(context, path, "DELETE", "") catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer context.allocator.free(handle);
        try self.waitOperation(context, node, resource_kind, handle);
    }

    fn startOperation(
        self: Handler,
        context: *provider_mod.OperationContext,
        path: []const u8,
        method: []const u8,
        body: []const u8,
    ) ProviderError![]const u8 {
        var response = try self.request(context, .{ .api = .compute, .method = method, .path = path, .body = body });
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const object = asObject(parsed.value) orelse return error.ProviderBug;
        const name = asString(object.get("name")) orelse return error.ProviderBug;
        return context.allocator.dupe(u8, name) catch return error.OutOfMemory;
    }

    fn waitOperation(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        resource_kind: Kind,
        handle: []const u8,
    ) ProviderError!void {
        const base = try std.fmt.allocPrint(
            context.allocator,
            "{s}/compute/v1",
            .{std.mem.trimEnd(u8, self.client.endpoints.compute, "/")},
        );
        defer context.allocator.free(base);
        const project_id = try requiredString(node.inputs, "project_id");
        var target = switch (resource_kind) {
            .regional_neg => operation.Target.computeRegionalAlloc(
                context.allocator,
                base,
                project_id,
                try requiredString(node.inputs, "region"),
                handle,
            ),
            else => operation.Target.computeGlobalAlloc(context.allocator, base, project_id, handle),
        } catch return error.OutOfMemory;
        defer target.deinit(context.allocator);
        var completed = try operation.waitAlloc(self.client, context, target, self.operation_policy);
        completed.deinit(context.allocator);
    }

    fn request(
        self: Handler,
        context: *provider_mod.OperationContext,
        request_value: client_mod.Request,
    ) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, request_value, &diagnostic);
    }
};

pub fn supports(node: resource.ResourceNode) bool {
    return kind(node) != null;
}

pub fn waitManagedSslCertificateReady(
    client: *client_mod.Client,
    context: *provider_mod.OperationContext,
    physical_id: []const u8,
    policy: CertificateReadinessPolicy,
) ProviderError!void {
    if (!std.mem.startsWith(u8, physical_id, "projects/") or
        std.mem.indexOf(u8, physical_id, "/global/sslCertificates/") == null)
    {
        return error.InvalidConfiguration;
    }
    const path = try restResourcePathAlloc(context.allocator, physical_id);
    defer context.allocator.free(path);
    var diagnostic = client_mod.Diagnostic.init(context.allocator);
    defer diagnostic.deinit();
    var transient_failures: usize = 0;
    while (true) {
        try context.checkActive();
        var response = client.requestJsonAlloc(context, .{ .api = .compute, .method = "GET", .path = path }, &diagnostic) catch |err| {
            if ((err == error.TransientFailure or err == error.RateLimited) and
                transient_failures < policy.max_transient_failures)
            {
                transient_failures += 1;
                context.sleep(diagnostic.retry_after_millis orelse policy.poll_interval_millis);
                continue;
            }
            return err;
        };
        defer response.deinit(context.allocator);
        transient_failures = 0;
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const remote = asObject(parsed.value) orelse return error.ProviderBug;
        const managed = try requiredObject(remote, "managed");
        if (managedCertificateReady(managed)) return;
        if (managedCertificateFailed(managed)) return error.InvalidConfiguration;
        context.sleep(policy.poll_interval_millis);
    }
}

fn kind(node: resource.ResourceNode) ?Kind {
    const names = .{
        .{ "gcp.compute.GlobalAddress", Kind.global_address },
        .{ "gcp.compute.RegionServerlessNeg", Kind.regional_neg },
        .{ "gcp.compute.BackendService", Kind.backend_service },
        .{ "gcp.compute.UrlMap", Kind.url_map },
        .{ "gcp.compute.HttpRedirectUrlMap", Kind.redirect_url_map },
        .{ "gcp.compute.ManagedSslCertificate", Kind.managed_ssl_certificate },
        .{ "gcp.compute.TargetHttpProxy", Kind.target_http_proxy },
        .{ "gcp.compute.TargetHttpsProxy", Kind.target_https_proxy },
        .{ "gcp.compute.GlobalForwardingRule", Kind.global_forwarding_rule },
    };
    inline for (names) |entry| if (std.mem.eql(u8, node.type_name, entry[0])) return entry[1];
    return null;
}

fn pendingResult(
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    resource_kind: Kind,
    handle: []const u8,
) ProviderError!provider_mod.ResourceResult {
    const physical_id = try physicalIdAlloc(allocator, node, resource_kind);
    defer allocator.free(physical_id);
    const standard_outputs = [_]state.StateOutput{
        .{ .name = "self_link", .value = .{ .unknown_reason = "Compute operation pending" } },
    };
    const certificate_outputs = [_]state.StateOutput{
        .{ .name = "self_link", .value = .{ .unknown_reason = "Compute operation pending" } },
        .{ .name = "status", .value = .{ .unknown_reason = "Certificate provisioning not observed" } },
        .{ .name = "domains_ready", .value = .{ .unknown_reason = "Certificate provisioning not observed" } },
    };
    const outputs = if (resource_kind == .managed_ssl_certificate) certificate_outputs[0..] else standard_outputs[0..];
    var result = try provider_mod.ResourceResult.init(allocator, physical_id, node.inputs, outputs, handle);
    result.completed = false;
    return result;
}

fn resultFromJson(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    resource_kind: Kind,
    body: []const u8,
) ProviderError!provider_mod.ResourceResult {
    const allocator = context.allocator;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const remote = asObject(parsed.value) orelse return error.ProviderBug;
    const name = try requiredJsonString(remote, "name");
    const self_link = try requiredJsonString(remote, "selfLink");
    const physical_id = try physicalIdFromNameAlloc(allocator, node, resource_kind, name);
    defer allocator.free(physical_id);
    var observed = try normalizedInputsAlloc(context, node, resource_kind, remote);
    defer observed.deinit(allocator);
    var outputs: [4]state.StateOutput = undefined;
    var count: usize = 0;
    switch (resource_kind) {
        .global_address => {
            outputs[count] = .{ .name = "address", .value = .{ .string = try requiredJsonString(remote, "address") } };
            count += 1;
        },
        .global_forwarding_rule => {
            outputs[count] = .{ .name = "ip_address", .value = .{ .string = try requiredJsonString(remote, "IPAddress") } };
            count += 1;
        },
        .managed_ssl_certificate => {
            const managed = try requiredObject(remote, "managed");
            outputs[count] = .{ .name = "status", .value = .{ .string = try requiredJsonString(managed, "status") } };
            count += 1;
            outputs[count] = .{ .name = "domains_ready", .value = .{ .boolean = managedCertificateReady(managed) } };
            count += 1;
        },
        else => {},
    }
    outputs[count] = .{ .name = "self_link", .value = .{ .string = self_link } };
    count += 1;
    if (asString(remote.get("fingerprint"))) |fingerprint| {
        outputs[count] = .{ .name = "fingerprint", .value = .{ .string = fingerprint } };
        count += 1;
    }
    return provider_mod.ResourceResult.init(allocator, physical_id, observed, outputs[0..count], null);
}

fn normalizedInputsAlloc(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    resource_kind: Kind,
    remote: std.json.ObjectMap,
) ProviderError!value.Value {
    const allocator = context.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var normalized: std.json.ObjectMap = .empty;
    try normalized.put(arena, "name", .{ .string = try requiredJsonString(remote, "name") });
    try normalized.put(arena, "project_id", .{ .string = try requiredString(node.inputs, "project_id") });
    switch (resource_kind) {
        .global_address => try normalized.put(arena, "network_tier", .{ .string = try requiredJsonString(remote, "networkTier") }),
        .regional_neg => {
            const cloud_run = try requiredObject(remote, "cloudRun");
            try normalized.put(arena, "cloud_run_service", .{ .string = try requiredJsonString(cloud_run, "service") });
            try normalized.put(arena, "network_endpoint_type", .{ .string = try requiredJsonString(remote, "networkEndpointType") });
            try normalized.put(arena, "region", .{ .string = try requiredString(node.inputs, "region") });
        },
        .backend_service => {
            try normalized.put(arena, "protocol", .{ .string = try requiredJsonString(remote, "protocol") });
            try normalized.put(arena, "load_balancing_scheme", .{ .string = try requiredJsonString(remote, "loadBalancingScheme") });
            const backends_value = remote.get("backends") orelse return error.ProviderBug;
            const remote_backends = asArray(backends_value) orelse return error.ProviderBug;
            var backends = std.json.Array.init(arena);
            for (remote_backends.items) |backend_value| {
                const backend = asObject(backend_value) orelse return error.ProviderBug;
                const group = try requiredJsonString(backend, "group");
                var normalized_backend: std.json.ObjectMap = .empty;
                try normalized_backend.put(arena, "group", .{ .string = group });
                try normalized_backend.put(arena, "region", .{ .string = regionFromGroup(group) orelse return error.ProviderBug });
                try backends.append(.{ .object = normalized_backend });
            }
            try normalized.put(arena, "backends", .{ .array = backends });
            try normalized.put(arena, "outlier_detection", try normalizedOutlierDetection(arena, remote.get("outlierDetection")));
        },
        .url_map => try normalized.put(arena, "default_service", .{ .string = try requiredJsonString(remote, "defaultService") }),
        .redirect_url_map => {
            const redirect = try requiredObject(remote, "defaultUrlRedirect");
            try normalized.put(arena, "https_redirect", .{ .bool = try requiredJsonBool(redirect, "httpsRedirect") });
            try normalized.put(arena, "redirect_response_code", .{ .string = try requiredJsonString(redirect, "redirectResponseCode") });
            try normalized.put(arena, "strip_query", .{ .bool = try requiredJsonBool(redirect, "stripQuery") });
        },
        .managed_ssl_certificate => {
            const managed = try requiredObject(remote, "managed");
            try normalized.put(arena, "domains", managed.get("domains") orelse return error.ProviderBug);
        },
        .target_http_proxy => try normalized.put(arena, "url_map", .{ .string = try requiredJsonString(remote, "urlMap") }),
        .target_https_proxy => {
            try normalized.put(arena, "url_map", .{ .string = try requiredJsonString(remote, "urlMap") });
            try normalized.put(arena, "ssl_certificates", remote.get("sslCertificates") orelse return error.ProviderBug);
        },
        .global_forwarding_rule => {
            const desired_address = try requiredValue(node.inputs, "address");
            const resolved_address = try resolveStringValue(context, desired_address);
            const remote_address = try requiredJsonString(remote, "IPAddress");
            try normalized.put(
                arena,
                "address",
                if (std.mem.eql(u8, resolved_address, remote_address))
                    try valueToJson(arena, desired_address)
                else
                    .{ .string = remote_address },
            );
            try normalized.put(arena, "load_balancing_scheme", .{ .string = try requiredJsonString(remote, "loadBalancingScheme") });
            try normalized.put(arena, "network_tier", .{ .string = try requiredJsonString(remote, "networkTier") });
            try normalized.put(arena, "port", .{ .integer = try firstPort(remote) });
            try normalized.put(arena, "target", .{ .string = try requiredJsonString(remote, "target") });
        },
    }
    const json = std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = normalized }, .{}) catch return error.OutOfMemory;
    defer allocator.free(json);
    return value.Value.parseJsonAlloc(allocator, json) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ProviderBug,
    };
}

fn desiredBodyAlloc(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    resource_kind: Kind,
) ProviderError![]const u8 {
    const allocator = context.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var body: std.json.ObjectMap = .empty;
    try body.put(arena, "name", .{ .string = try requiredString(node.inputs, "name") });
    switch (resource_kind) {
        .global_address => try body.put(arena, "networkTier", .{ .string = try requiredString(node.inputs, "network_tier") }),
        .regional_neg => {
            try body.put(arena, "networkEndpointType", .{ .string = "SERVERLESS" });
            var cloud_run: std.json.ObjectMap = .empty;
            try cloud_run.put(arena, "service", .{ .string = try requiredString(node.inputs, "cloud_run_service") });
            try body.put(arena, "cloudRun", .{ .object = cloud_run });
        },
        .backend_service => {
            try body.put(arena, "protocol", .{ .string = try requiredString(node.inputs, "protocol") });
            try body.put(arena, "loadBalancingScheme", .{ .string = try requiredString(node.inputs, "load_balancing_scheme") });
            const desired_backends = try requiredValue(node.inputs, "backends");
            const items = switch (desired_backends) {
                .list => |items| items,
                else => return error.InvalidConfiguration,
            };
            var backends = std.json.Array.init(arena);
            for (items) |item| {
                var backend: std.json.ObjectMap = .empty;
                try backend.put(arena, "group", .{ .string = try requiredString(item, "group") });
                try backends.append(.{ .object = backend });
            }
            try body.put(arena, "backends", .{ .array = backends });
            try body.put(arena, "outlierDetection", try outlierDetectionRequestJson(arena, try requiredValue(node.inputs, "outlier_detection")));
        },
        .url_map => try body.put(arena, "defaultService", .{ .string = try requiredString(node.inputs, "default_service") }),
        .redirect_url_map => {
            var redirect: std.json.ObjectMap = .empty;
            try redirect.put(arena, "httpsRedirect", .{ .bool = try requiredBoolean(node.inputs, "https_redirect") });
            try redirect.put(arena, "redirectResponseCode", .{ .string = try requiredString(node.inputs, "redirect_response_code") });
            try redirect.put(arena, "stripQuery", .{ .bool = try requiredBoolean(node.inputs, "strip_query") });
            try body.put(arena, "defaultUrlRedirect", .{ .object = redirect });
        },
        .managed_ssl_certificate => {
            try body.put(arena, "type", .{ .string = "MANAGED" });
            var managed: std.json.ObjectMap = .empty;
            try managed.put(arena, "domains", try stringListJson(arena, try requiredValue(node.inputs, "domains")));
            try body.put(arena, "managed", .{ .object = managed });
        },
        .target_http_proxy => try body.put(arena, "urlMap", .{ .string = try requiredString(node.inputs, "url_map") }),
        .target_https_proxy => {
            try body.put(arena, "urlMap", .{ .string = try requiredString(node.inputs, "url_map") });
            try body.put(arena, "sslCertificates", try stringListJson(arena, try requiredValue(node.inputs, "ssl_certificates")));
        },
        .global_forwarding_rule => {
            try body.put(arena, "IPAddress", .{ .string = try resolveStringValue(context, try requiredValue(node.inputs, "address")) });
            try body.put(arena, "IPProtocol", .{ .string = "TCP" });
            const port_range = try std.fmt.allocPrint(arena, "{d}-{d}", .{
                try requiredInteger(node.inputs, "port"),
                try requiredInteger(node.inputs, "port"),
            });
            try body.put(arena, "portRange", .{ .string = port_range });
            try body.put(arena, "target", .{ .string = try requiredString(node.inputs, "target") });
            try body.put(arena, "loadBalancingScheme", .{ .string = try requiredString(node.inputs, "load_balancing_scheme") });
            try body.put(arena, "networkTier", .{ .string = try requiredString(node.inputs, "network_tier") });
        },
    }
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = body }, .{}) catch return error.OutOfMemory;
}

fn mergeUpdateBodyAlloc(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    resource_kind: Kind,
    remote_json: []const u8,
) ProviderError![]const u8 {
    const allocator = context.allocator;
    var remote = std.json.parseFromSlice(std.json.Value, allocator, remote_json, .{}) catch return error.ProviderBug;
    defer remote.deinit();
    const object = switch (remote.value) {
        .object => |*object| object,
        else => return error.ProviderBug,
    };
    const desired_json = try desiredBodyAlloc(context, node, resource_kind);
    defer allocator.free(desired_json);
    var desired = std.json.parseFromSlice(std.json.Value, allocator, desired_json, .{}) catch return error.ProviderBug;
    defer desired.deinit();
    const desired_object = asObject(desired.value) orelse return error.ProviderBug;
    const arena = remote.arena.allocator();
    const managed_fields: []const []const u8 = switch (resource_kind) {
        .backend_service => &.{ "name", "protocol", "loadBalancingScheme", "backends", "outlierDetection" },
        .url_map => &.{ "name", "defaultService" },
        .redirect_url_map => &.{ "name", "defaultUrlRedirect" },
        .target_http_proxy => &.{ "name", "urlMap" },
        .target_https_proxy => &.{ "name", "urlMap", "sslCertificates" },
        else => return error.InvalidConfiguration,
    };
    for (managed_fields) |field| {
        const desired_value = desired_object.get(field) orelse return error.ProviderBug;
        const copied = try cloneJsonValue(arena, desired_value);
        try object.put(arena, field, copied);
    }
    _ = object.orderedRemove("selfLink");
    _ = object.orderedRemove("id");
    _ = object.orderedRemove("creationTimestamp");
    return std.json.Stringify.valueAlloc(allocator, remote.value, .{}) catch return error.OutOfMemory;
}

fn cloneJsonValue(allocator: std.mem.Allocator, input: std.json.Value) ProviderError!std.json.Value {
    const json = std.json.Stringify.valueAlloc(allocator, input, .{}) catch return error.OutOfMemory;
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{}) catch return error.ProviderBug;
}

fn collectionPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, resource_kind: Kind) ProviderError![]const u8 {
    const project_id = try requiredString(node.inputs, "project_id");
    return switch (resource_kind) {
        .global_address => std.fmt.allocPrint(allocator, "/compute/v1/projects/{s}/global/addresses", .{project_id}),
        .regional_neg => std.fmt.allocPrint(allocator, "/compute/v1/projects/{s}/regions/{s}/networkEndpointGroups", .{
            project_id,
            try requiredString(node.inputs, "region"),
        }),
        .backend_service => std.fmt.allocPrint(allocator, "/compute/v1/projects/{s}/global/backendServices", .{project_id}),
        .url_map => std.fmt.allocPrint(allocator, "/compute/v1/projects/{s}/global/urlMaps", .{project_id}),
        .redirect_url_map => std.fmt.allocPrint(allocator, "/compute/v1/projects/{s}/global/urlMaps", .{project_id}),
        .managed_ssl_certificate => std.fmt.allocPrint(allocator, "/compute/v1/projects/{s}/global/sslCertificates", .{project_id}),
        .target_http_proxy => std.fmt.allocPrint(allocator, "/compute/v1/projects/{s}/global/targetHttpProxies", .{project_id}),
        .target_https_proxy => std.fmt.allocPrint(allocator, "/compute/v1/projects/{s}/global/targetHttpsProxies", .{project_id}),
        .global_forwarding_rule => std.fmt.allocPrint(allocator, "/compute/v1/projects/{s}/global/forwardingRules", .{project_id}),
    } catch return error.OutOfMemory;
}

fn physicalIdAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, resource_kind: Kind) ProviderError![]const u8 {
    return physicalIdFromNameAlloc(allocator, node, resource_kind, try requiredString(node.inputs, "name"));
}

fn physicalIdFromNameAlloc(
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    resource_kind: Kind,
    name: []const u8,
) ProviderError![]const u8 {
    const project_id = try requiredString(node.inputs, "project_id");
    return switch (resource_kind) {
        .global_address => std.fmt.allocPrint(allocator, "projects/{s}/global/addresses/{s}", .{ project_id, name }),
        .regional_neg => std.fmt.allocPrint(allocator, "projects/{s}/regions/{s}/networkEndpointGroups/{s}", .{
            project_id,
            try requiredString(node.inputs, "region"),
            name,
        }),
        .backend_service => std.fmt.allocPrint(allocator, "projects/{s}/global/backendServices/{s}", .{ project_id, name }),
        .url_map => std.fmt.allocPrint(allocator, "projects/{s}/global/urlMaps/{s}", .{ project_id, name }),
        .redirect_url_map => std.fmt.allocPrint(allocator, "projects/{s}/global/urlMaps/{s}", .{ project_id, name }),
        .managed_ssl_certificate => std.fmt.allocPrint(allocator, "projects/{s}/global/sslCertificates/{s}", .{ project_id, name }),
        .target_http_proxy => std.fmt.allocPrint(allocator, "projects/{s}/global/targetHttpProxies/{s}", .{ project_id, name }),
        .target_https_proxy => std.fmt.allocPrint(allocator, "projects/{s}/global/targetHttpsProxies/{s}", .{ project_id, name }),
        .global_forwarding_rule => std.fmt.allocPrint(allocator, "projects/{s}/global/forwardingRules/{s}", .{ project_id, name }),
    } catch return error.OutOfMemory;
}

fn restResourcePathAlloc(allocator: std.mem.Allocator, physical_id: []const u8) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "/compute/v1/{s}", .{std.mem.trimStart(u8, physical_id, "/")}) catch return error.OutOfMemory;
}

fn sameIdentity(node_inputs: value.Value, observed: value.Value) bool {
    for ([_][]const u8{ "project_id", "name" }) |field| {
        const desired = requiredString(node_inputs, field) catch return false;
        const remote = requiredString(observed, field) catch return false;
        if (!std.mem.eql(u8, desired, remote)) return false;
    }
    return true;
}

fn regionFromGroup(group: []const u8) ?[]const u8 {
    const marker = "/regions/";
    const start = (std.mem.indexOf(u8, group, marker) orelse return null) + marker.len;
    const end_relative = std.mem.indexOfScalar(u8, group[start..], '/') orelse return null;
    return group[start .. start + end_relative];
}

fn firstPort(remote: std.json.ObjectMap) ProviderError!i64 {
    const range = try requiredJsonString(remote, "portRange");
    const dash = std.mem.indexOfScalar(u8, range, '-') orelse range.len;
    return std.fmt.parseInt(i64, range[0..dash], 10) catch return error.ProviderBug;
}

fn stringListJson(allocator: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    const values = switch (input) {
        .list => |values| values,
        else => return error.InvalidConfiguration,
    };
    var array = std.json.Array.init(allocator);
    for (values) |item| switch (item) {
        .string => |string| try array.append(.{ .string = string }),
        else => return error.InvalidConfiguration,
    };
    return .{ .array = array };
}

fn requiredValue(input: value.Value, name: []const u8) ProviderError!value.Value {
    const fields = switch (input) {
        .object => |fields| fields,
        else => return error.InvalidConfiguration,
    };
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return error.InvalidConfiguration;
}

fn requiredString(input: value.Value, name: []const u8) ProviderError![]const u8 {
    const found = try requiredValue(input, name);
    return switch (found) {
        .string => |string| string,
        else => error.InvalidConfiguration,
    };
}

fn requiredInteger(input: value.Value, name: []const u8) ProviderError!i64 {
    const found = try requiredValue(input, name);
    return switch (found) {
        .integer => |integer| integer,
        else => error.InvalidConfiguration,
    };
}

fn requiredBoolean(input: value.Value, name: []const u8) ProviderError!bool {
    const found = try requiredValue(input, name);
    return switch (found) {
        .boolean => |boolean| boolean,
        else => error.InvalidConfiguration,
    };
}

fn resolveStringValue(context: *provider_mod.OperationContext, input: value.Value) ProviderError![]const u8 {
    return switch (input) {
        .string => |string| string,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}

fn valueToJson(allocator: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    const json = input.canonicalJsonAlloc(allocator) catch |err| switch (err) {
        error.DuplicateField => return error.InvalidConfiguration,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{}) catch return error.ProviderBug;
}

fn outlierDetectionRequestJson(allocator: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    const fields = switch (input) {
        .object => |fields| fields,
        else => return error.InvalidConfiguration,
    };
    if (fields.len == 0) return .{ .object = .empty };
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "consecutiveErrors", .{ .integer = try requiredInteger(input, "consecutive_errors") });
    try object.put(allocator, "consecutiveGatewayFailure", .{ .integer = try requiredInteger(input, "consecutive_gateway_failures") });
    try object.put(allocator, "interval", try durationJson(allocator, try requiredInteger(input, "interval_seconds")));
    try object.put(allocator, "baseEjectionTime", try durationJson(allocator, try requiredInteger(input, "base_ejection_time_seconds")));
    try object.put(allocator, "maxEjectionPercent", .{ .integer = try requiredInteger(input, "max_ejection_percent") });
    try object.put(allocator, "enforcingConsecutiveErrors", .{ .integer = try requiredInteger(input, "enforcing_consecutive_errors") });
    try object.put(allocator, "enforcingConsecutiveGatewayFailure", .{ .integer = try requiredInteger(input, "enforcing_consecutive_gateway_failures") });
    return .{ .object = object };
}

fn durationJson(allocator: std.mem.Allocator, seconds: i64) ProviderError!std.json.Value {
    const seconds_string = std.fmt.allocPrint(allocator, "{d}", .{seconds}) catch return error.OutOfMemory;
    var duration: std.json.ObjectMap = .empty;
    try duration.put(allocator, "seconds", .{ .string = seconds_string });
    try duration.put(allocator, "nanos", .{ .integer = 0 });
    return .{ .object = duration };
}

fn normalizedOutlierDetection(
    allocator: std.mem.Allocator,
    maybe_input: ?std.json.Value,
) ProviderError!std.json.Value {
    const input_value = maybe_input orelse return .{ .object = .empty };
    const input = asObject(input_value) orelse return error.ProviderBug;
    var normalized: std.json.ObjectMap = .empty;
    try normalized.put(allocator, "base_ejection_time_seconds", .{ .integer = try durationSeconds(input, "baseEjectionTime") });
    try normalized.put(allocator, "consecutive_errors", .{ .integer = try requiredJsonInteger(input, "consecutiveErrors") });
    try normalized.put(allocator, "consecutive_gateway_failures", .{ .integer = try requiredJsonInteger(input, "consecutiveGatewayFailure") });
    try normalized.put(allocator, "enforcing_consecutive_errors", .{ .integer = try requiredJsonInteger(input, "enforcingConsecutiveErrors") });
    try normalized.put(allocator, "enforcing_consecutive_gateway_failures", .{ .integer = try requiredJsonInteger(input, "enforcingConsecutiveGatewayFailure") });
    try normalized.put(allocator, "interval_seconds", .{ .integer = try durationSeconds(input, "interval") });
    try normalized.put(allocator, "max_ejection_percent", .{ .integer = try requiredJsonInteger(input, "maxEjectionPercent") });
    return .{ .object = normalized };
}

fn durationSeconds(object: std.json.ObjectMap, name: []const u8) ProviderError!i64 {
    const duration = try requiredObject(object, name);
    const seconds = try requiredJsonString(duration, "seconds");
    return std.fmt.parseInt(i64, seconds, 10) catch return error.ProviderBug;
}

fn requiredObject(object: std.json.ObjectMap, name: []const u8) ProviderError!std.json.ObjectMap {
    const found = object.get(name) orelse return error.ProviderBug;
    return asObject(found) orelse error.ProviderBug;
}

fn requiredJsonString(object: std.json.ObjectMap, name: []const u8) ProviderError![]const u8 {
    return asString(object.get(name)) orelse error.ProviderBug;
}

fn requiredJsonBool(object: std.json.ObjectMap, name: []const u8) ProviderError!bool {
    const found = object.get(name) orelse return error.ProviderBug;
    return switch (found) {
        .bool => |boolean| boolean,
        else => error.ProviderBug,
    };
}

fn requiredJsonInteger(object: std.json.ObjectMap, name: []const u8) ProviderError!i64 {
    const found = object.get(name) orelse return error.ProviderBug;
    return switch (found) {
        .integer => |integer| integer,
        else => error.ProviderBug,
    };
}

fn managedCertificateReady(managed: std.json.ObjectMap) bool {
    const status = asString(managed.get("status")) orelse return false;
    if (!std.mem.eql(u8, status, "ACTIVE")) return false;
    const domain_status_value = managed.get("domainStatus") orelse return false;
    const domain_status = asObject(domain_status_value) orelse return false;
    if (domain_status.count() == 0) return false;
    var iterator = domain_status.iterator();
    while (iterator.next()) |entry| {
        const value_string = asString(entry.value_ptr.*) orelse return false;
        if (!std.mem.eql(u8, value_string, "ACTIVE")) return false;
    }
    return true;
}

fn managedCertificateFailed(managed: std.json.ObjectMap) bool {
    if (asString(managed.get("status"))) |status| {
        if (std.mem.startsWith(u8, status, "FAILED")) return true;
    }
    const domain_status_value = managed.get("domainStatus") orelse return false;
    const domain_status = asObject(domain_status_value) orelse return false;
    var iterator = domain_status.iterator();
    while (iterator.next()) |entry| {
        const status = asString(entry.value_ptr.*) orelse continue;
        if (std.mem.startsWith(u8, status, "FAILED")) return true;
    }
    return false;
}

fn asObject(input: std.json.Value) ?std.json.ObjectMap {
    return switch (input) {
        .object => |object| object,
        else => null,
    };
}

fn asArray(input: std.json.Value) ?std.json.Array {
    return switch (input) {
        .array => |array| array,
        else => null,
    };
}

fn asString(maybe_input: ?std.json.Value) ?[]const u8 {
    const input = maybe_input orelse return null;
    return switch (input) {
        .string => |string| string,
        else => null,
    };
}
