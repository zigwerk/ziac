const std = @import("std");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;

const Kind = enum {
    firewall,
    route,
    health_check,
    region_health_check,
    internal_address,
    region_backend_service,
    region_url_map,
    region_target_http_proxy,
    forwarding_rule,
};

const Scope = enum { global, region };

pub const Handler = struct {
    client: *client_mod.Client,
    operation_policy: operation.Policy = .{},
    conflict_retries: usize = 2,

    pub fn read(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
        const resource_kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (context.operation_handle) |handle| try self.waitOperation(context, node, resource_kind, handle);
        const expected = try physicalIdAlloc(context.allocator, node, resource_kind);
        defer context.allocator.free(expected);
        const physical_id = physical_override orelse expected;
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        const path = try resourcePathAlloc(context.allocator, physical_id);
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .compute, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try resultFromJson(context, node, resource_kind, response.body) };
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
        const resource_kind = kindOf(node) orelse return error.InvalidConfiguration;
        const diff_kind: provider_mod.DiffKind = if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash))
            .noop
        else if (!sameIdentity(node.inputs, observed.observed_inputs, resource_kind))
            .replace
        else switch (resource_kind) {
            .firewall, .health_check, .region_health_check, .region_backend_service, .region_url_map, .region_target_http_proxy => .update,
            .route, .internal_address, .forwarding_rule => .replace,
        };
        const reasons: []const []const u8 = switch (diff_kind) {
            .noop => &.{},
            .update => &.{"Network delivery policy will update in place"},
            .replace => &.{"Network delivery identity or immutable frontend changed"},
        };
        return provider_mod.DiffResult.init(context.allocator, diff_kind, reasons);
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        const resource_kind = kindOf(node) orelse return error.InvalidConfiguration;
        const body = try desiredBodyAlloc(context, node, resource_kind, null);
        defer context.allocator.free(body);
        const path = try collectionPathAlloc(context.allocator, node, resource_kind);
        defer context.allocator.free(path);
        const handle = try self.startOperation(context, path, "POST", body);
        defer context.allocator.free(handle);
        return pendingResult(context.allocator, node, resource_kind, handle);
    }

    pub fn update(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        const resource_kind = kindOf(node) orelse return error.InvalidConfiguration;
        switch (resource_kind) {
            .firewall, .health_check, .region_health_check, .region_backend_service, .region_url_map, .region_target_http_proxy => {},
            .route, .internal_address, .forwarding_rule => return error.InvalidConfiguration,
        }
        try validatePhysicalId(context.allocator, node, resource_kind, observed.physical_id);
        const path = try resourcePathAlloc(context.allocator, observed.physical_id);
        defer context.allocator.free(path);
        var conflicts: usize = 0;
        while (true) {
            var remote = try self.request(context, .{ .api = .compute, .method = "GET", .path = path });
            defer remote.deinit(context.allocator);
            const body = try desiredBodyAlloc(context, node, resource_kind, remote.body);
            defer context.allocator.free(body);
            const mutation_path = if (resource_kind == .region_target_http_proxy)
                try std.fmt.allocPrint(context.allocator, "{s}/setUrlMap", .{path})
            else
                try context.allocator.dupe(u8, path);
            defer context.allocator.free(mutation_path);
            const method = if (resource_kind == .region_target_http_proxy) "POST" else "PATCH";
            const handle = self.startOperation(context, mutation_path, method, body) catch |err| {
                if ((err == error.Conflict or err == error.PreconditionFailed) and conflicts < self.conflict_retries) {
                    conflicts += 1;
                    continue;
                }
                return err;
            };
            defer context.allocator.free(handle);
            return pendingResult(context.allocator, node, resource_kind, handle);
        }
    }

    pub fn delete(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!void {
        const resource_kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysicalId(context.allocator, node, resource_kind, physical_id);
        const path = try resourcePathAlloc(context.allocator, physical_id);
        defer context.allocator.free(path);
        const handle = self.startOperation(context, path, "DELETE", "") catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer context.allocator.free(handle);
        try self.waitOperation(context, node, resource_kind, handle);
    }

    fn startOperation(self: Handler, context: *provider_mod.OperationContext, path: []const u8, method: []const u8, body: []const u8) ProviderError![]const u8 {
        var response = try self.request(context, .{ .api = .compute, .method = method, .path = path, .body = body });
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        return context.allocator.dupe(u8, try requiredJsonString(asObject(parsed.value) orelse return error.ProviderBug, "name")) catch return error.OutOfMemory;
    }

    fn waitOperation(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, resource_kind: Kind, handle: []const u8) ProviderError!void {
        const base = try std.fmt.allocPrint(context.allocator, "{s}/compute/v1", .{std.mem.trimEnd(u8, self.client.endpoints.compute, "/")});
        defer context.allocator.free(base);
        const project = try requiredString(node.inputs, "project_id");
        var target = switch (scopeOf(resource_kind)) {
            .global => operation.Target.computeGlobalAlloc(context.allocator, base, project, handle),
            .region => operation.Target.computeRegionalAlloc(context.allocator, base, project, try requiredString(node.inputs, "region"), handle),
        } catch return error.OutOfMemory;
        defer target.deinit(context.allocator);
        var completed = try operation.waitAlloc(self.client, context, target, self.operation_policy);
        completed.deinit(context.allocator);
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
        .{ "gcp.compute.Firewall", Kind.firewall },
        .{ "gcp.compute.Route", Kind.route },
        .{ "gcp.compute.HealthCheck", Kind.health_check },
        .{ "gcp.compute.RegionHealthCheck", Kind.region_health_check },
        .{ "gcp.compute.InternalAddress", Kind.internal_address },
        .{ "gcp.compute.RegionBackendService", Kind.region_backend_service },
        .{ "gcp.compute.RegionUrlMap", Kind.region_url_map },
        .{ "gcp.compute.RegionTargetHttpProxy", Kind.region_target_http_proxy },
        .{ "gcp.compute.ForwardingRule", Kind.forwarding_rule },
    };
    inline for (mappings) |mapping| if (std.mem.eql(u8, node.type_name, mapping[0])) return mapping[1];
    return null;
}

fn scopeOf(resource_kind: Kind) Scope {
    return switch (resource_kind) {
        .firewall, .route, .health_check => .global,
        else => .region,
    };
}

fn collectionName(resource_kind: Kind) []const u8 {
    return switch (resource_kind) {
        .firewall => "firewalls",
        .route => "routes",
        .health_check, .region_health_check => "healthChecks",
        .internal_address => "addresses",
        .region_backend_service => "backendServices",
        .region_url_map => "urlMaps",
        .region_target_http_proxy => "targetHttpProxies",
        .forwarding_rule => "forwardingRules",
    };
}

fn collectionPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, resource_kind: Kind) ProviderError![]const u8 {
    const project = try requiredString(node.inputs, "project_id");
    return switch (scopeOf(resource_kind)) {
        .global => std.fmt.allocPrint(allocator, "/compute/v1/projects/{s}/global/{s}", .{ project, collectionName(resource_kind) }),
        .region => std.fmt.allocPrint(allocator, "/compute/v1/projects/{s}/regions/{s}/{s}", .{ project, try requiredString(node.inputs, "region"), collectionName(resource_kind) }),
    } catch return error.OutOfMemory;
}

fn physicalIdAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, resource_kind: Kind) ProviderError![]const u8 {
    const project = try requiredString(node.inputs, "project_id");
    const name = try requiredString(node.inputs, "name");
    return switch (scopeOf(resource_kind)) {
        .global => std.fmt.allocPrint(allocator, "projects/{s}/global/{s}/{s}", .{ project, collectionName(resource_kind), name }),
        .region => std.fmt.allocPrint(allocator, "projects/{s}/regions/{s}/{s}/{s}", .{ project, try requiredString(node.inputs, "region"), collectionName(resource_kind), name }),
    } catch return error.OutOfMemory;
}

fn validatePhysicalId(allocator: std.mem.Allocator, node: resource.ResourceNode, resource_kind: Kind, physical_id: []const u8) ProviderError!void {
    const expected = try physicalIdAlloc(allocator, node, resource_kind);
    defer allocator.free(expected);
    if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
}

fn resourcePathAlloc(allocator: std.mem.Allocator, physical_id: []const u8) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "/compute/v1/{s}", .{std.mem.trimStart(u8, physical_id, "/")}) catch return error.OutOfMemory;
}

fn desiredBodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, resource_kind: Kind, remote_json: ?[]const u8) ProviderError![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root: std.json.ObjectMap = .empty;
    try root.put(arena, "name", .{ .string = try requiredString(node.inputs, "name") });
    switch (resource_kind) {
        .firewall => try firewallBody(arena, context, node, &root),
        .route => try routeBody(arena, context, node, &root),
        .health_check, .region_health_check => try healthBody(arena, node, &root),
        .internal_address => try addressBody(arena, context, node, &root),
        .region_backend_service => try backendBody(arena, context, node, &root),
        .region_url_map => try root.put(arena, "defaultService", .{ .string = try resolveString(context, try requiredValue(node.inputs, "default_service")) }),
        .region_target_http_proxy => try root.put(arena, "urlMap", .{ .string = try resolveString(context, try requiredValue(node.inputs, "url_map")) }),
        .forwarding_rule => try forwardingBody(arena, context, node, &root),
    }
    if (remote_json) |bytes| if (fingerprintFromJson(arena, bytes)) |fingerprint| try root.put(arena, "fingerprint", .{ .string = fingerprint });
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch return error.OutOfMemory;
}

fn firewallBody(allocator: std.mem.Allocator, context: *provider_mod.OperationContext, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    try root.put(allocator, "network", .{ .string = try resolveString(context, try requiredValue(node.inputs, "network")) });
    try root.put(allocator, "direction", .{ .string = try requiredString(node.inputs, "direction") });
    try root.put(allocator, "priority", .{ .integer = try requiredInteger(node.inputs, "priority") });
    try root.put(allocator, "disabled", .{ .bool = try requiredBoolean(node.inputs, "disabled") });
    try root.put(allocator, "sourceRanges", try stringListJson(allocator, try requiredValue(node.inputs, "source_ranges")));
    try root.put(allocator, "destinationRanges", try stringListJson(allocator, try requiredValue(node.inputs, "destination_ranges")));
    try root.put(allocator, "sourceTags", try stringListJson(allocator, try requiredValue(node.inputs, "source_tags")));
    try root.put(allocator, "targetTags", try stringListJson(allocator, try requiredValue(node.inputs, "target_tags")));
    try root.put(allocator, "sourceServiceAccounts", try stringListJson(allocator, try requiredValue(node.inputs, "source_service_accounts")));
    try root.put(allocator, "targetServiceAccounts", try stringListJson(allocator, try requiredValue(node.inputs, "target_service_accounts")));
    const field_name = if (std.mem.eql(u8, try requiredString(node.inputs, "action"), "ALLOW")) "allowed" else "denied";
    var rules = std.json.Array.init(allocator);
    for (try requiredList(node.inputs, "rules")) |candidate| {
        var rule: std.json.ObjectMap = .empty;
        try rule.put(allocator, "IPProtocol", .{ .string = try requiredString(candidate, "protocol") });
        try rule.put(allocator, "ports", try stringListJson(allocator, try requiredValue(candidate, "ports")));
        try rules.append(.{ .object = rule });
    }
    try root.put(allocator, field_name, .{ .array = rules });
    var logging: std.json.ObjectMap = .empty;
    try logging.put(allocator, "enable", .{ .bool = try requiredBoolean(node.inputs, "logging") });
    try root.put(allocator, "logConfig", .{ .object = logging });
}

fn routeBody(allocator: std.mem.Allocator, context: *provider_mod.OperationContext, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    try root.put(allocator, "network", .{ .string = try resolveString(context, try requiredValue(node.inputs, "network")) });
    try root.put(allocator, "destRange", .{ .string = try requiredString(node.inputs, "destination_range") });
    try root.put(allocator, "priority", .{ .integer = try requiredInteger(node.inputs, "priority") });
    try root.put(allocator, "tags", try stringListJson(allocator, try requiredValue(node.inputs, "tags")));
    const field_name = if (std.mem.eql(u8, try requiredString(node.inputs, "next_hop_kind"), "gateway"))
        "nextHopGateway"
    else if (std.mem.eql(u8, try requiredString(node.inputs, "next_hop_kind"), "instance"))
        "nextHopInstance"
    else if (std.mem.eql(u8, try requiredString(node.inputs, "next_hop_kind"), "ip_address"))
        "nextHopIp"
    else if (std.mem.eql(u8, try requiredString(node.inputs, "next_hop_kind"), "vpn_tunnel"))
        "nextHopVpnTunnel"
    else
        "nextHopIlb";
    try root.put(allocator, field_name, .{ .string = try resolveString(context, try requiredValue(node.inputs, "next_hop_value")) });
}

fn healthBody(allocator: std.mem.Allocator, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    try root.put(allocator, "checkIntervalSec", .{ .integer = try requiredInteger(node.inputs, "check_interval_seconds") });
    try root.put(allocator, "timeoutSec", .{ .integer = try requiredInteger(node.inputs, "timeout_seconds") });
    try root.put(allocator, "healthyThreshold", .{ .integer = try requiredInteger(node.inputs, "healthy_threshold") });
    try root.put(allocator, "unhealthyThreshold", .{ .integer = try requiredInteger(node.inputs, "unhealthy_threshold") });
    const protocol = try requiredString(node.inputs, "protocol");
    const config_name = if (std.mem.eql(u8, protocol, "HTTP"))
        "httpHealthCheck"
    else if (std.mem.eql(u8, protocol, "HTTPS"))
        "httpsHealthCheck"
    else if (std.mem.eql(u8, protocol, "HTTP2"))
        "http2HealthCheck"
    else if (std.mem.eql(u8, protocol, "TCP"))
        "tcpHealthCheck"
    else if (std.mem.eql(u8, protocol, "SSL"))
        "sslHealthCheck"
    else
        "grpcHealthCheck";
    var config: std.json.ObjectMap = .empty;
    try config.put(allocator, "port", .{ .integer = try requiredInteger(node.inputs, "port") });
    const port_name = try requiredString(node.inputs, "port_name");
    if (port_name.len > 0) try config.put(allocator, "portName", .{ .string = port_name });
    try config.put(allocator, "proxyHeader", .{ .string = try requiredString(node.inputs, "proxy_header") });
    if (std.mem.eql(u8, protocol, "HTTP") or std.mem.eql(u8, protocol, "HTTPS") or std.mem.eql(u8, protocol, "HTTP2")) {
        try config.put(allocator, "requestPath", .{ .string = try requiredString(node.inputs, "request_path") });
        const host = try requiredString(node.inputs, "host");
        if (host.len > 0) try config.put(allocator, "host", .{ .string = host });
    }
    if (std.mem.eql(u8, protocol, "GRPC")) try config.put(allocator, "grpcServiceName", .{ .string = try requiredString(node.inputs, "grpc_service_name") });
    try root.put(allocator, config_name, .{ .object = config });
    var logging: std.json.ObjectMap = .empty;
    try logging.put(allocator, "enable", .{ .bool = try requiredBoolean(node.inputs, "logging") });
    try root.put(allocator, "logConfig", .{ .object = logging });
}

fn addressBody(allocator: std.mem.Allocator, context: *provider_mod.OperationContext, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    try root.put(allocator, "addressType", .{ .string = "INTERNAL" });
    try root.put(allocator, "purpose", .{ .string = try requiredString(node.inputs, "purpose") });
    try root.put(allocator, "subnetwork", .{ .string = try resolveString(context, try requiredValue(node.inputs, "subnetwork")) });
    const address = try requiredString(node.inputs, "address");
    if (address.len > 0) try root.put(allocator, "address", .{ .string = address });
}

fn backendBody(allocator: std.mem.Allocator, context: *provider_mod.OperationContext, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    try root.put(allocator, "loadBalancingScheme", .{ .string = try requiredString(node.inputs, "load_balancing_scheme") });
    try root.put(allocator, "protocol", .{ .string = try requiredString(node.inputs, "protocol") });
    try root.put(allocator, "network", .{ .string = try resolveString(context, try requiredValue(node.inputs, "network")) });
    var checks = std.json.Array.init(allocator);
    try checks.append(.{ .string = try resolveString(context, try requiredValue(node.inputs, "health_check")) });
    try root.put(allocator, "healthChecks", .{ .array = checks });
    const port_name = try requiredString(node.inputs, "port_name");
    if (port_name.len > 0) try root.put(allocator, "portName", .{ .string = port_name });
    try root.put(allocator, "timeoutSec", .{ .integer = try requiredInteger(node.inputs, "timeout_seconds") });
    try root.put(allocator, "sessionAffinity", .{ .string = try requiredString(node.inputs, "session_affinity") });
    try root.put(allocator, "localityLbPolicy", .{ .string = try requiredString(node.inputs, "locality_lb_policy") });
    var draining: std.json.ObjectMap = .empty;
    try draining.put(allocator, "drainingTimeoutSec", .{ .integer = try requiredInteger(node.inputs, "connection_draining_seconds") });
    try root.put(allocator, "connectionDraining", .{ .object = draining });
    var backends = std.json.Array.init(allocator);
    for (try requiredList(node.inputs, "backends")) |candidate| {
        var backend: std.json.ObjectMap = .empty;
        try backend.put(allocator, "group", .{ .string = try resolveString(context, try requiredValue(candidate, "group")) });
        try backend.put(allocator, "balancingMode", .{ .string = try requiredString(candidate, "balancing_mode") });
        try backend.put(allocator, "capacityScaler", .{ .float = @as(f64, @floatFromInt(try requiredInteger(candidate, "capacity_scaler_micros"))) / 1_000_000.0 });
        try backend.put(allocator, "failover", .{ .bool = try requiredBoolean(candidate, "failover") });
        if (std.mem.eql(u8, try requiredString(candidate, "balancing_mode"), "UTILIZATION")) try backend.put(allocator, "maxUtilization", .{ .float = @as(f64, @floatFromInt(try requiredInteger(candidate, "max_utilization_micros"))) / 1_000_000.0 });
        try backends.append(.{ .object = backend });
    }
    try root.put(allocator, "backends", .{ .array = backends });
}

fn forwardingBody(allocator: std.mem.Allocator, context: *provider_mod.OperationContext, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    try root.put(allocator, "loadBalancingScheme", .{ .string = try requiredString(node.inputs, "load_balancing_scheme") });
    try root.put(allocator, "network", .{ .string = try resolveString(context, try requiredValue(node.inputs, "network")) });
    try root.put(allocator, "subnetwork", .{ .string = try resolveString(context, try requiredValue(node.inputs, "subnetwork")) });
    try root.put(allocator, "IPAddress", .{ .string = try resolveString(context, try requiredValue(node.inputs, "address")) });
    try root.put(allocator, "IPProtocol", .{ .string = try requiredString(node.inputs, "protocol") });
    try root.put(allocator, "allPorts", .{ .bool = try requiredBoolean(node.inputs, "all_ports") });
    try root.put(allocator, "allowGlobalAccess", .{ .bool = try requiredBoolean(node.inputs, "allow_global_access") });
    try root.put(allocator, "ports", try stringListJson(allocator, try requiredValue(node.inputs, "ports")));
    const field_name = if (std.mem.eql(u8, try requiredString(node.inputs, "target_kind"), "backend_service")) "backendService" else "target";
    try root.put(allocator, field_name, .{ .string = try resolveString(context, try requiredValue(node.inputs, "target_value")) });
}

fn resultFromJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, resource_kind: Kind, body: []const u8) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const remote = asObject(parsed.value) orelse return error.ProviderBug;
    if (!std.mem.eql(u8, try requiredString(node.inputs, "name"), try requiredJsonString(remote, "name"))) return error.InvalidConfiguration;
    const physical_id = try physicalIdAlloc(context.allocator, node, resource_kind);
    defer context.allocator.free(physical_id);
    var observed = node.inputs.clone(context.allocator) catch |err| return mapValueError(err);
    defer observed.deinit(context.allocator);
    switch (resource_kind) {
        .firewall => {
            if (jsonInteger(remote.get("priority"))) |present| try replaceInteger(context.allocator, &observed, "priority", present);
            if (jsonBool(remote.get("disabled"))) |present| try replaceBoolean(context.allocator, &observed, "disabled", present);
        },
        .route => if (jsonInteger(remote.get("priority"))) |present| try replaceInteger(context.allocator, &observed, "priority", present),
        .health_check, .region_health_check => {
            if (jsonInteger(remote.get("checkIntervalSec"))) |present| try replaceInteger(context.allocator, &observed, "check_interval_seconds", present);
            if (jsonInteger(remote.get("timeoutSec"))) |present| try replaceInteger(context.allocator, &observed, "timeout_seconds", present);
        },
        .region_backend_service => if (jsonInteger(remote.get("timeoutSec"))) |present| try replaceInteger(context.allocator, &observed, "timeout_seconds", present),
        .forwarding_rule => {
            if (jsonBool(remote.get("allowGlobalAccess"))) |present| try replaceBoolean(context.allocator, &observed, "allow_global_access", present);
            if (remote.get("ports")) |ports| try replaceStringListFromJson(context.allocator, &observed, "ports", ports);
        },
        .internal_address, .region_url_map, .region_target_http_proxy => {},
    }
    var outputs: [3]state.StateOutput = undefined;
    var count: usize = 0;
    outputs[count] = .{ .name = "self_link", .value = .{ .string = try requiredJsonString(remote, "selfLink") } };
    count += 1;
    switch (resource_kind) {
        .firewall, .health_check, .region_health_check, .region_backend_service, .region_url_map, .region_target_http_proxy => {
            outputs[count] = .{ .name = "fingerprint", .value = .{ .string = jsonString(remote.get("fingerprint")) orelse "" } };
            count += 1;
            if (resource_kind == .health_check or resource_kind == .region_health_check) {
                outputs[count] = .{ .name = "status", .value = .{ .string = "READY" } };
                count += 1;
            } else if (resource_kind == .region_backend_service) {
                outputs[count] = .{ .name = "health", .value = .{ .string = "UNKNOWN" } };
                count += 1;
            }
        },
        .route => {
            outputs[count] = .{ .name = "status", .value = .{ .string = jsonString(remote.get("status")) orelse "UNKNOWN" } };
            count += 1;
        },
        .internal_address, .forwarding_rule => {
            outputs[count] = .{ .name = "address", .value = .{ .string = jsonString(remote.get("address")) orelse jsonString(remote.get("IPAddress")) orelse "" } };
            count += 1;
        },
    }
    return provider_mod.ResourceResult.init(context.allocator, physical_id, observed, outputs[0..count], null);
}

fn pendingResult(allocator: std.mem.Allocator, node: resource.ResourceNode, resource_kind: Kind, handle: []const u8) ProviderError!provider_mod.ResourceResult {
    const physical_id = try physicalIdAlloc(allocator, node, resource_kind);
    defer allocator.free(physical_id);
    var outputs: [3]state.StateOutput = undefined;
    var count: usize = 0;
    outputs[count] = .{ .name = "self_link", .value = .{ .unknown_reason = "Compute operation pending" } };
    count += 1;
    switch (resource_kind) {
        .firewall, .health_check, .region_health_check, .region_backend_service, .region_url_map, .region_target_http_proxy => {
            outputs[count] = .{ .name = "fingerprint", .value = .{ .unknown_reason = "Compute operation pending" } };
            count += 1;
            if (resource_kind == .health_check or resource_kind == .region_health_check) {
                outputs[count] = .{ .name = "status", .value = .{ .unknown_reason = "Compute operation pending" } };
                count += 1;
            } else if (resource_kind == .region_backend_service) {
                outputs[count] = .{ .name = "health", .value = .{ .unknown_reason = "Compute operation pending" } };
                count += 1;
            }
        },
        .route => {
            outputs[count] = .{ .name = "status", .value = .{ .unknown_reason = "Compute operation pending" } };
            count += 1;
        },
        .internal_address, .forwarding_rule => {
            outputs[count] = .{ .name = "address", .value = .{ .unknown_reason = "Compute operation pending" } };
            count += 1;
        },
    }
    var result = try provider_mod.ResourceResult.init(allocator, physical_id, node.inputs, outputs[0..count], handle);
    result.completed = false;
    return result;
}

fn sameIdentity(desired: value.Value, observed: value.Value, resource_kind: Kind) bool {
    const fields = switch (scopeOf(resource_kind)) {
        .global => &[_][]const u8{ "project_id", "name" },
        .region => &[_][]const u8{ "project_id", "region", "name" },
    };
    for (fields) |field| if (!std.mem.eql(u8, requiredString(desired, field) catch return false, requiredString(observed, field) catch return false)) return false;
    return true;
}

fn fingerprintFromJson(allocator: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch return null;
    return jsonString((asObject(parsed) orelse return null).get("fingerprint"));
}

fn replaceStringListFromJson(allocator: std.mem.Allocator, inputs: *value.Value, name: []const u8, candidate: std.json.Value) ProviderError!void {
    const array = asArray(candidate) orelse return error.ProviderBug;
    const items = allocator.alloc(value.Value, array.items.len) catch return error.OutOfMemory;
    defer allocator.free(items);
    for (array.items, 0..) |item, index| items[index] = .{ .string = jsonString(item) orelse return error.ProviderBug };
    var replacement = value.Value.initOwned(allocator, .{ .list = items }) catch |err| return mapValueError(err);
    defer replacement.deinit(allocator);
    try replaceValue(allocator, inputs, name, replacement);
}

fn replaceInteger(allocator: std.mem.Allocator, inputs: *value.Value, name: []const u8, replacement: i64) ProviderError!void {
    try replaceValue(allocator, inputs, name, .{ .integer = replacement });
}

fn replaceBoolean(allocator: std.mem.Allocator, inputs: *value.Value, name: []const u8, replacement: bool) ProviderError!void {
    try replaceValue(allocator, inputs, name, .{ .boolean = replacement });
}

fn replaceValue(allocator: std.mem.Allocator, inputs: *value.Value, name: []const u8, replacement: value.Value) ProviderError!void {
    if (inputs.* != .object) return error.ProviderBug;
    const fields: []value.Field = @constCast(inputs.object);
    for (fields) |*field| {
        if (!std.mem.eql(u8, field.name, name)) continue;
        const owned = replacement.clone(allocator) catch |err| return mapValueError(err);
        field.value.deinit(allocator);
        field.value = owned;
        return;
    }
    return error.ProviderBug;
}

fn stringListJson(allocator: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    var array = std.json.Array.init(allocator);
    for (try asValueList(input)) |item| try array.append(.{ .string = try valueString(item) });
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
        .integer => |integer| integer,
        else => error.InvalidConfiguration,
    };
}

fn requiredBoolean(input: value.Value, name: []const u8) ProviderError!bool {
    return switch (try requiredValue(input, name)) {
        .boolean => |boolean| boolean,
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
        .string => |string| string,
        else => error.InvalidConfiguration,
    };
}

fn resolveString(context: *provider_mod.OperationContext, input: value.Value) ProviderError![]const u8 {
    return switch (input) {
        .string => |string| string,
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

fn asArray(candidate: std.json.Value) ?std.json.Array {
    return switch (candidate) {
        .array => |array| array,
        else => null,
    };
}

fn jsonString(candidate: ?std.json.Value) ?[]const u8 {
    const present = candidate orelse return null;
    return switch (present) {
        .string => |string| string,
        else => null,
    };
}

fn jsonInteger(candidate: ?std.json.Value) ?i64 {
    const present = candidate orelse return null;
    return switch (present) {
        .integer => |integer| integer,
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

fn requiredJsonString(object: std.json.ObjectMap, name: []const u8) ProviderError![]const u8 {
    return jsonString(object.get(name)) orelse error.ProviderBug;
}

fn mapValueError(err: anyerror) ProviderError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ProviderBug,
    };
}
