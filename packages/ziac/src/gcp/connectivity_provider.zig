const std = @import("std");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const secret_mod = @import("../secret.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;

const Kind = enum {
    ha_vpn_gateway,
    external_vpn_gateway,
    vpn_tunnel,
    router_interface,
    router_bgp_peer,
    network_peering,
    hub,
    spoke,
    service_connection_policy,
};

pub const Handler = struct {
    client: *client_mod.Client,
    operation_policy: operation.Policy = .{},
    conflict_retries: usize = 2,
    secret_source: ?secret_mod.SecretSource = null,

    pub fn read(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
        const resource_kind = kindOf(node) orelse return error.InvalidConfiguration;
        const expected = try physicalIdAlloc(context.allocator, node, resource_kind);
        defer context.allocator.free(expected);
        if (physical_override) |physical| if (!std.mem.eql(u8, expected, physical)) return error.InvalidConfiguration;
        if (context.operation_handle) |handle| try self.waitOperation(context, node, resource_kind, handle);
        const path = try readPathAlloc(context.allocator, node, resource_kind);
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = apiFor(resource_kind), .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return resultFromJson(context, node, resource_kind, response.body);
    }

    pub fn diff(context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        const resource_kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash)) return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        const replacement = switch (resource_kind) {
            .ha_vpn_gateway, .external_vpn_gateway, .vpn_tunnel => true,
            .router_interface => identityChanged(node.inputs, observed.observed_inputs, &.{ "project_id", "region", "router_name", "name" }),
            .router_bgp_peer => identityChanged(node.inputs, observed.observed_inputs, &.{ "project_id", "region", "router_name", "name" }),
            .network_peering => identityChanged(node.inputs, observed.observed_inputs, &.{ "project_id", "network_name", "name" }),
            .hub => identityChanged(node.inputs, observed.observed_inputs, &.{ "project_id", "name", "policy_mode", "topology" }),
            .spoke => identityChanged(node.inputs, observed.observed_inputs, &.{ "project_id", "location", "name", "hub", "link_kind", "links" }),
            .service_connection_policy => identityChanged(node.inputs, observed.observed_inputs, &.{ "project_id", "location", "name", "network", "service_class" }),
        };
        return provider_mod.DiffResult.init(context.allocator, if (replacement) .replace else .update, &.{if (replacement) "immutable connectivity identity changed" else "connectivity policy differs"});
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        const resource_kind = kindOf(node) orelse return error.InvalidConfiguration;
        return switch (resource_kind) {
            .router_interface, .router_bgp_peer => self.mutateRouterChild(context, node, resource_kind, true),
            .network_peering => self.mutatePeering(context, node, .add),
            .ha_vpn_gateway, .external_vpn_gateway, .vpn_tunnel => self.createCompute(context, node, resource_kind),
            .hub, .spoke, .service_connection_policy => self.createNcc(context, node, resource_kind),
        };
    }

    pub fn update(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        const resource_kind = kindOf(node) orelse return error.InvalidConfiguration;
        return switch (resource_kind) {
            .router_interface, .router_bgp_peer => self.mutateRouterChild(context, node, resource_kind, true),
            .network_peering => self.mutatePeering(context, node, .update),
            .hub, .spoke, .service_connection_policy => self.updateNcc(context, node, resource_kind, observed),
            .ha_vpn_gateway, .external_vpn_gateway, .vpn_tunnel => error.InvalidConfiguration,
        };
    }

    pub fn delete(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!void {
        const resource_kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(context.allocator, node, resource_kind, physical_id);
        switch (resource_kind) {
            .router_interface, .router_bgp_peer => {
                var pending = try self.mutateRouterChild(context, node, resource_kind, false);
                defer pending.deinit();
                if (pending.operation_handle) |handle| try self.waitOperation(context, node, resource_kind, handle);
            },
            .network_peering => {
                var pending = try self.mutatePeering(context, node, .remove);
                defer pending.deinit();
                if (pending.operation_handle) |handle| try self.waitOperation(context, node, resource_kind, handle);
            },
            .ha_vpn_gateway, .external_vpn_gateway, .vpn_tunnel => {
                const path = try readPathAlloc(context.allocator, node, resource_kind);
                defer context.allocator.free(path);
                const handle = self.startComputeOperation(context, "DELETE", path, "") catch |err| {
                    if (err == error.NotFound) return;
                    return err;
                };
                defer context.allocator.free(handle);
                try self.waitOperation(context, node, resource_kind, handle);
            },
            .hub, .spoke, .service_connection_policy => try self.deleteNcc(context, node, resource_kind),
        }
    }

    pub fn importResource(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!provider_mod.ResourceResult {
        var read_result = try self.read(context, node, physical_id);
        defer read_result.deinit();
        return switch (read_result) {
            .absent => error.NotFound,
            .present => |present| present.clone(context.allocator) catch error.OutOfMemory,
        };
    }

    fn createCompute(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, resource_kind: Kind) ProviderError!provider_mod.ResourceResult {
        var body = try self.bodyAlloc(context, node, resource_kind, null);
        defer body.deinit(context.allocator);
        const path = try collectionPathAlloc(context.allocator, node, resource_kind);
        defer context.allocator.free(path);
        const handle = try self.startComputeOperation(context, "POST", path, body.bytes);
        defer context.allocator.free(handle);
        return pendingResult(context.allocator, node, resource_kind, handle);
    }

    fn createNcc(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, resource_kind: Kind) ProviderError!provider_mod.ResourceResult {
        var body = try self.bodyAlloc(context, node, resource_kind, null);
        defer body.deinit(context.allocator);
        const path = try createNccPathAlloc(context.allocator, node, resource_kind);
        defer context.allocator.free(path);
        const handle = try self.startGenericOperation(context, "POST", path, body.bytes);
        defer context.allocator.free(handle);
        return pendingResult(context.allocator, node, resource_kind, handle);
    }

    fn updateNcc(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, resource_kind: Kind, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        var body = try self.bodyAlloc(context, node, resource_kind, outputString(observed, "etag"));
        defer body.deinit(context.allocator);
        const path = try updateNccPathAlloc(context.allocator, node, resource_kind);
        defer context.allocator.free(path);
        const handle = try self.startGenericOperation(context, "PATCH", path, body.bytes);
        defer context.allocator.free(handle);
        return pendingResult(context.allocator, node, resource_kind, handle);
    }

    fn deleteNcc(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, resource_kind: Kind) ProviderError!void {
        const read_path = try readPathAlloc(context.allocator, node, resource_kind);
        defer context.allocator.free(read_path);
        var current = self.request(context, .{ .api = .network_connectivity, .method = "GET", .path = read_path }) catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer current.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, current.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const remote = jsonObject(parsed.value) orelse return error.ProviderBug;
        const etag = jsonString(remote.get("etag")) orelse return error.ProviderBug;
        const path = try std.fmt.allocPrint(context.allocator, "{s}?etag={s}", .{ read_path, etag });
        defer context.allocator.free(path);
        const handle = try self.startGenericOperation(context, "DELETE", path, "");
        defer context.allocator.free(handle);
        try self.waitOperation(context, node, resource_kind, handle);
    }

    fn mutateRouterChild(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, resource_kind: Kind, should_exist: bool) ProviderError!provider_mod.ResourceResult {
        const path = try routerPathAlloc(context.allocator, node);
        defer context.allocator.free(path);
        var conflicts: usize = 0;
        while (true) {
            var current = self.request(context, .{ .api = .compute, .method = "GET", .path = path }) catch |err| {
                if (err == error.NotFound and !should_exist) return desiredResult(context.allocator, node, resource_kind, null);
                return err;
            };
            defer current.deinit(context.allocator);
            const mutation = try routerMutationBodyAlloc(context, node, resource_kind, current.body, should_exist);
            defer context.allocator.free(mutation.bytes);
            if (!mutation.changed) return desiredResult(context.allocator, node, resource_kind, null);
            const handle = self.startComputeOperation(context, "PATCH", path, mutation.bytes) catch |err| {
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

    fn mutatePeering(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, action: PeeringAction) ProviderError!provider_mod.ResourceResult {
        const path = try peeringActionPathAlloc(context.allocator, node, action);
        defer context.allocator.free(path);
        const body = try peeringBodyAlloc(context, node, action);
        defer context.allocator.free(body);
        const handle = try self.startComputeOperation(context, "POST", path, body);
        defer context.allocator.free(handle);
        return pendingResult(context.allocator, node, .network_peering, handle);
    }

    fn startComputeOperation(self: Handler, context: *provider_mod.OperationContext, method: []const u8, path: []const u8, body: []const u8) ProviderError![]const u8 {
        var response = try self.request(context, .{ .api = .compute, .method = method, .path = path, .body = body });
        defer response.deinit(context.allocator);
        return operationNameAlloc(context.allocator, response.body);
    }

    fn startGenericOperation(self: Handler, context: *provider_mod.OperationContext, method: []const u8, path: []const u8, body: []const u8) ProviderError![]const u8 {
        var response = try self.request(context, .{ .api = .network_connectivity, .method = method, .path = path, .body = body });
        defer response.deinit(context.allocator);
        return operationNameAlloc(context.allocator, response.body);
    }

    fn waitOperation(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, resource_kind: Kind, handle: []const u8) ProviderError!void {
        const endpoint = self.client.endpoints.get(apiFor(resource_kind));
        const base = try std.fmt.allocPrint(context.allocator, "{s}/{s}", .{ std.mem.trimEnd(u8, endpoint, "/"), if (isNcc(resource_kind)) "v1" else "compute/v1" });
        defer context.allocator.free(base);
        var target = (if (isNcc(resource_kind))
            operation.Target.genericAlloc(context.allocator, base, handle)
        else if (isRegional(resource_kind))
            operation.Target.computeRegionalAlloc(context.allocator, base, try requiredString(node.inputs, "project_id"), try requiredString(node.inputs, "region"), handle)
        else
            operation.Target.computeGlobalAlloc(context.allocator, base, try requiredString(node.inputs, "project_id"), handle)) catch return error.OutOfMemory;
        defer target.deinit(context.allocator);
        var completed = try operation.waitAlloc(self.client, context, target, self.operation_policy);
        completed.deinit(context.allocator);
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, request_value: client_mod.Request) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, request_value, &diagnostic);
    }

    fn bodyAlloc(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, resource_kind: Kind, etag: ?[]const u8) ProviderError!SensitiveBody {
        var arena_state = std.heap.ArenaAllocator.init(context.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var body: std.json.ObjectMap = .empty;
        var sensitive = false;
        switch (resource_kind) {
            .ha_vpn_gateway => {
                try body.put(arena, "name", .{ .string = try requiredString(node.inputs, "name") });
                try body.put(arena, "network", .{ .string = try resolveString(context, try requiredValue(node.inputs, "network")) });
                try body.put(arena, "stackType", .{ .string = try requiredString(node.inputs, "stack_type") });
            },
            .external_vpn_gateway => {
                try body.put(arena, "name", .{ .string = try requiredString(node.inputs, "name") });
                try body.put(arena, "description", .{ .string = try requiredString(node.inputs, "description") });
                try body.put(arena, "redundancyType", .{ .string = try requiredString(node.inputs, "redundancy_type") });
                try body.put(arena, "interfaces", try externalInterfacesJson(arena, try requiredList(node.inputs, "interfaces")));
            },
            .vpn_tunnel => {
                try body.put(arena, "name", .{ .string = try requiredString(node.inputs, "name") });
                try body.put(arena, "description", .{ .string = try requiredString(node.inputs, "description") });
                try body.put(arena, "ikeVersion", .{ .integer = try requiredInteger(node.inputs, "ike_version") });
                try body.put(arena, "vpnGateway", .{ .string = try resolveString(context, try requiredValue(node.inputs, "vpn_gateway")) });
                try body.put(arena, "vpnGatewayInterface", .{ .integer = try requiredInteger(node.inputs, "vpn_gateway_interface") });
                const peer = try resolveString(context, try requiredValue(node.inputs, "peer_gateway"));
                if (std.mem.eql(u8, try requiredString(node.inputs, "peer_kind"), "EXTERNAL")) {
                    try body.put(arena, "peerExternalGateway", .{ .string = peer });
                    try body.put(arena, "peerExternalGatewayInterface", .{ .integer = try requiredInteger(node.inputs, "peer_gateway_interface") });
                } else try body.put(arena, "peerGcpGateway", .{ .string = peer });
                try body.put(arena, "router", .{ .string = try resolveString(context, try requiredValue(node.inputs, "router")) });
                const reference = try resolveSecret(context, try requiredValue(node.inputs, "shared_secret"));
                const source = self.secret_source orelse return error.AuthorizationFailed;
                var payload = try source.resolve(context, context.allocator, reference);
                defer payload.deinit();
                try body.put(arena, "sharedSecret", .{ .string = try arena.dupe(u8, payload.bytes) });
                sensitive = true;
            },
            .hub => {
                try body.put(arena, "name", .{ .string = try physicalIdAlloc(arena, node, resource_kind) });
                try body.put(arena, "description", .{ .string = try requiredString(node.inputs, "description") });
                try body.put(arena, "labels", try valueToJson(arena, try requiredValue(node.inputs, "labels")));
                try body.put(arena, "policyMode", .{ .string = try requiredString(node.inputs, "policy_mode") });
                try body.put(arena, "presetTopology", .{ .string = try requiredString(node.inputs, "topology") });
                try body.put(arena, "exportPsc", .{ .bool = try requiredBoolean(node.inputs, "export_psc") });
            },
            .spoke => try spokeBody(arena, context, node, &body),
            .service_connection_policy => try servicePolicyBody(arena, context, node, &body),
            .router_interface, .router_bgp_peer, .network_peering => return error.InvalidConfiguration,
        }
        if (etag) |present| try body.put(arena, "etag", .{ .string = present });
        return .{ .bytes = std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = body }, .{}) catch return error.OutOfMemory, .sensitive = sensitive };
    }
};

pub fn supports(node: resource.ResourceNode) bool {
    return kindOf(node) != null;
}

const SensitiveBody = struct {
    bytes: []const u8,
    sensitive: bool,
    fn deinit(self: *SensitiveBody, allocator: std.mem.Allocator) void {
        if (self.sensitive) std.crypto.secureZero(u8, @constCast(self.bytes));
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

const PeeringAction = enum { add, update, remove };
const MutationBody = struct { bytes: []const u8, changed: bool };

fn kindOf(node: resource.ResourceNode) ?Kind {
    const entries = .{
        .{ "gcp.compute.HaVpnGateway", Kind.ha_vpn_gateway },
        .{ "gcp.compute.ExternalVpnGateway", Kind.external_vpn_gateway },
        .{ "gcp.compute.VpnTunnel", Kind.vpn_tunnel },
        .{ "gcp.compute.RouterInterface", Kind.router_interface },
        .{ "gcp.compute.RouterBgpPeer", Kind.router_bgp_peer },
        .{ "gcp.compute.NetworkPeering", Kind.network_peering },
        .{ "gcp.networkconnectivity.Hub", Kind.hub },
        .{ "gcp.networkconnectivity.Spoke", Kind.spoke },
        .{ "gcp.networkconnectivity.ServiceConnectionPolicy", Kind.service_connection_policy },
    };
    inline for (entries) |entry| if (std.mem.eql(u8, node.type_name, entry[0])) return entry[1];
    return null;
}

fn apiFor(resource_kind: Kind) client_mod.Api {
    return if (isNcc(resource_kind)) .network_connectivity else .compute;
}

fn isNcc(resource_kind: Kind) bool {
    return resource_kind == .hub or resource_kind == .spoke or resource_kind == .service_connection_policy;
}

fn isRegional(resource_kind: Kind) bool {
    return resource_kind == .ha_vpn_gateway or resource_kind == .vpn_tunnel or resource_kind == .router_interface or resource_kind == .router_bgp_peer;
}

fn resultFromJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, resource_kind: Kind, body: []const u8) ProviderError!provider_mod.ReadResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const remote = jsonObject(parsed.value) orelse return error.ProviderBug;
    return switch (resource_kind) {
        .router_interface => resultFromRouterChild(context, node, resource_kind, remote, "interfaces"),
        .router_bgp_peer => resultFromRouterChild(context, node, resource_kind, remote, "bgpPeers"),
        .network_peering => resultFromNetworkPeering(context, node, remote),
        else => .{ .present = try resultFromResource(context, node, resource_kind, remote) },
    };
}

fn resultFromResource(context: *provider_mod.OperationContext, node: resource.ResourceNode, resource_kind: Kind, remote: std.json.ObjectMap) ProviderError!provider_mod.ResourceResult {
    const physical = try physicalIdAlloc(context.allocator, node, resource_kind);
    defer context.allocator.free(physical);
    var observed = try normalizedInputsAlloc(context, node, resource_kind, remote);
    defer observed.deinit(context.allocator);
    var outputs: [8]state.StateOutput = undefined;
    var count: usize = 0;
    const self_link = jsonString(remote.get("selfLink")) orelse if (isNcc(resource_kind)) jsonString(remote.get("name")) orelse physical else physical;
    switch (resource_kind) {
        .ha_vpn_gateway => {
            const interfaces = jsonArray(remote.get("vpnInterfaces")) orelse return error.ProviderBug;
            if (interfaces.items.len != 2) return error.ProviderBug;
            outputs[count] = .{ .name = "interface_0_ip", .value = .{ .string = try requiredJsonString(jsonObject(interfaces.items[0]) orelse return error.ProviderBug, "ipAddress") } };
            count += 1;
            outputs[count] = .{ .name = "interface_1_ip", .value = .{ .string = try requiredJsonString(jsonObject(interfaces.items[1]) orelse return error.ProviderBug, "ipAddress") } };
            count += 1;
        },
        .vpn_tunnel => {
            outputs[count] = .{ .name = "status", .value = .{ .string = try requiredJsonString(remote, "status") } };
            count += 1;
            outputs[count] = .{ .name = "detailed_status", .value = .{ .string = jsonString(remote.get("detailedStatus")) orelse "" } };
            count += 1;
            outputs[count] = .{ .name = "shared_secret_hash", .value = .{ .string = try requiredJsonString(remote, "sharedSecretHash") } };
            count += 1;
        },
        .hub, .spoke => {
            outputs[count] = .{ .name = "state", .value = .{ .string = jsonString(remote.get("state")) orelse "UNKNOWN" } };
            count += 1;
            outputs[count] = .{ .name = "etag", .value = .{ .string = try requiredJsonString(remote, "etag") } };
            count += 1;
            outputs[count] = .{ .name = "name", .value = .{ .string = self_link } };
            count += 1;
        },
        .service_connection_policy => {
            outputs[count] = .{ .name = "etag", .value = .{ .string = try requiredJsonString(remote, "etag") } };
            count += 1;
            outputs[count] = .{ .name = "name", .value = .{ .string = self_link } };
            count += 1;
            const limit = if (remote.get("pscConnectionsLimit")) |present| jsonInteger(present) orelse 0 else 0;
            outputs[count] = .{ .name = "psc_connection_limit", .value = .{ .integer = limit } };
            count += 1;
        },
        else => {},
    }
    if (!isNcc(resource_kind)) {
        outputs[count] = .{ .name = "self_link", .value = .{ .string = self_link } };
        count += 1;
    }
    return provider_mod.ResourceResult.init(context.allocator, physical, observed, outputs[0..count], null);
}

fn normalizedInputsAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, resource_kind: Kind, remote: std.json.ObjectMap) ProviderError!value.Value {
    var observed = node.inputs.clone(context.allocator) catch |err| switch (err) {
        error.DuplicateField => return error.ProviderBug,
        error.OutOfMemory => return error.OutOfMemory,
    };
    errdefer observed.deinit(context.allocator);
    switch (resource_kind) {
        .ha_vpn_gateway => {
            try replaceResolvedString(context, &observed, "network", try requiredJsonString(remote, "network"));
            try replaceString(context.allocator, &observed, "stack_type", jsonString(remote.get("stackType")) orelse "IPV4_ONLY");
        },
        .external_vpn_gateway => {
            try replaceString(context.allocator, &observed, "description", jsonString(remote.get("description")) orelse "");
            try replaceString(context.allocator, &observed, "redundancy_type", try requiredJsonString(remote, "redundancyType"));
            try replaceJsonField(context.allocator, &observed, "interfaces", try normalizedExternalInterfaces(context.allocator, remote));
        },
        .vpn_tunnel => {
            try replaceString(context.allocator, &observed, "description", jsonString(remote.get("description")) orelse "");
            try replaceInteger(context.allocator, &observed, "ike_version", try requiredJsonInteger(remote, "ikeVersion"));
            try replaceResolvedString(context, &observed, "vpn_gateway", try requiredJsonString(remote, "vpnGateway"));
            try replaceInteger(context.allocator, &observed, "vpn_gateway_interface", try requiredJsonInteger(remote, "vpnGatewayInterface"));
            const external = jsonString(remote.get("peerExternalGateway"));
            const peer = external orelse jsonString(remote.get("peerGcpGateway")) orelse return error.ProviderBug;
            try replaceResolvedString(context, &observed, "peer_gateway", peer);
            try replaceString(context.allocator, &observed, "peer_kind", if (external != null) "EXTERNAL" else "GCP");
            try replaceInteger(context.allocator, &observed, "peer_gateway_interface", if (external != null) try requiredJsonInteger(remote, "peerExternalGatewayInterface") else -1);
            try replaceResolvedString(context, &observed, "router", try requiredJsonString(remote, "router"));
        },
        .hub => {
            try replaceString(context.allocator, &observed, "description", jsonString(remote.get("description")) orelse "");
            try replaceJsonField(context.allocator, &observed, "labels", remote.get("labels") orelse .{ .object = .empty });
            try replaceString(context.allocator, &observed, "policy_mode", try requiredJsonString(remote, "policyMode"));
            try replaceString(context.allocator, &observed, "topology", try requiredJsonString(remote, "presetTopology"));
            try replaceBoolean(context.allocator, &observed, "export_psc", jsonBool(remote.get("exportPsc")) orelse false);
        },
        .spoke => try normalizeSpoke(context, &observed, remote),
        .service_connection_policy => try normalizeServicePolicy(context, &observed, remote),
        else => {},
    }
    return observed;
}

fn resultFromRouterChild(context: *provider_mod.OperationContext, node: resource.ResourceNode, resource_kind: Kind, router: std.json.ObjectMap, collection: []const u8) ProviderError!provider_mod.ReadResult {
    const items = jsonArray(router.get(collection)) orelse return .absent;
    const name = try requiredString(node.inputs, "name");
    for (items.items) |item| {
        const child = jsonObject(item) orelse return error.ProviderBug;
        if (!std.mem.eql(u8, try requiredJsonString(child, "name"), name)) continue;
        var observed = node.inputs.clone(context.allocator) catch |err| switch (err) {
            error.DuplicateField => return error.ProviderBug,
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer observed.deinit(context.allocator);
        if (resource_kind == .router_interface) {
            try replaceString(context.allocator, &observed, "ip_range", try requiredJsonString(child, "ipRange"));
            try replaceResolvedString(context, &observed, "vpn_tunnel", try requiredJsonString(child, "linkedVpnTunnel"));
        } else {
            try replaceString(context.allocator, &observed, "interface_name", try requiredJsonString(child, "interfaceName"));
            try replaceInteger(context.allocator, &observed, "peer_asn", try requiredJsonInteger(child, "peerAsn"));
            try replaceString(context.allocator, &observed, "ip_address", try requiredJsonString(child, "ipAddress"));
            try replaceString(context.allocator, &observed, "peer_ip_address", try requiredJsonString(child, "peerIpAddress"));
            try replaceInteger(context.allocator, &observed, "route_priority", jsonInteger(child.get("advertisedRoutePriority") orelse .{ .integer = 100 }) orelse 100);
            try replaceString(context.allocator, &observed, "advertise_mode", jsonString(child.get("advertiseMode")) orelse "DEFAULT");
        }
        const physical = try physicalIdAlloc(context.allocator, node, resource_kind);
        defer context.allocator.free(physical);
        var outputs: [2]state.StateOutput = undefined;
        outputs[0] = .{ .name = "resource_id", .value = .{ .string = physical } };
        var count: usize = 1;
        if (resource_kind == .router_bgp_peer) {
            outputs[1] = .{ .name = "status", .value = .{ .string = jsonString(child.get("status")) orelse "UNKNOWN" } };
            count = 2;
        }
        return .{ .present = try provider_mod.ResourceResult.init(context.allocator, physical, observed, outputs[0..count], null) };
    }
    return .absent;
}

fn resultFromNetworkPeering(context: *provider_mod.OperationContext, node: resource.ResourceNode, network: std.json.ObjectMap) ProviderError!provider_mod.ReadResult {
    const peerings = jsonArray(network.get("peerings")) orelse return .absent;
    const name = try requiredString(node.inputs, "name");
    for (peerings.items) |item| {
        const peering = jsonObject(item) orelse return error.ProviderBug;
        if (!std.mem.eql(u8, try requiredJsonString(peering, "name"), name)) continue;
        var observed = node.inputs.clone(context.allocator) catch |err| switch (err) {
            error.DuplicateField => return error.ProviderBug,
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer observed.deinit(context.allocator);
        try replaceResolvedString(context, &observed, "peer_network", try requiredJsonString(peering, "network"));
        try replaceBoolean(context.allocator, &observed, "import_custom_routes", jsonBool(peering.get("importCustomRoutes")) orelse false);
        try replaceBoolean(context.allocator, &observed, "export_custom_routes", jsonBool(peering.get("exportCustomRoutes")) orelse false);
        try replaceBoolean(context.allocator, &observed, "import_subnet_routes_with_public_ip", jsonBool(peering.get("importSubnetRoutesWithPublicIp")) orelse false);
        try replaceBoolean(context.allocator, &observed, "export_subnet_routes_with_public_ip", jsonBool(peering.get("exportSubnetRoutesWithPublicIp")) orelse false);
        try replaceString(context.allocator, &observed, "stack_type", jsonString(peering.get("stackType")) orelse "IPV4_ONLY");
        try replaceString(context.allocator, &observed, "update_strategy", jsonString(peering.get("updateStrategy")) orelse "INDEPENDENT");
        const physical = try physicalIdAlloc(context.allocator, node, .network_peering);
        defer context.allocator.free(physical);
        const outputs = [_]state.StateOutput{
            .{ .name = "resource_id", .value = .{ .string = physical } },
            .{ .name = "state", .value = .{ .string = jsonString(peering.get("state")) orelse "UNKNOWN" } },
        };
        return .{ .present = try provider_mod.ResourceResult.init(context.allocator, physical, observed, &outputs, null) };
    }
    return .absent;
}

fn routerMutationBodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, resource_kind: Kind, body: []const u8, should_exist: bool) ProviderError!MutationBody {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const router = switch (parsed.value) {
        .object => |*object| object,
        else => return error.ProviderBug,
    };
    const arena = parsed.arena.allocator();
    const field = if (resource_kind == .router_interface) "interfaces" else "bgpPeers";
    const current = if (router.get(field)) |present| jsonArray(present) orelse return error.ProviderBug else std.json.Array.init(arena);
    var next = std.json.Array.init(arena);
    var found = false;
    for (current.items) |item| {
        const child = jsonObject(item) orelse return error.ProviderBug;
        if (std.mem.eql(u8, try requiredJsonString(child, "name"), try requiredString(node.inputs, "name"))) {
            found = true;
            if (should_exist) try next.append(try routerChildJson(context, node, resource_kind, arena));
        } else try next.append(item);
    }
    if (should_exist and !found) try next.append(try routerChildJson(context, node, resource_kind, arena));
    if (!should_exist and !found) return .{ .bytes = try context.allocator.dupe(u8, body), .changed = false };
    try router.put(arena, field, .{ .array = next });
    inline for (&.{ "selfLink", "id", "creationTimestamp", "kind", "region" }) |remove| _ = router.orderedRemove(remove);
    return .{ .bytes = std.json.Stringify.valueAlloc(context.allocator, parsed.value, .{}) catch return error.OutOfMemory, .changed = true };
}

fn routerChildJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, resource_kind: Kind, allocator: std.mem.Allocator) ProviderError!std.json.Value {
    var child: std.json.ObjectMap = .empty;
    try child.put(allocator, "name", .{ .string = try requiredString(node.inputs, "name") });
    if (resource_kind == .router_interface) {
        try child.put(allocator, "ipRange", .{ .string = try requiredString(node.inputs, "ip_range") });
        try child.put(allocator, "linkedVpnTunnel", .{ .string = try resolveString(context, try requiredValue(node.inputs, "vpn_tunnel")) });
    } else {
        try child.put(allocator, "interfaceName", .{ .string = try requiredString(node.inputs, "interface_name") });
        try child.put(allocator, "peerAsn", .{ .integer = try requiredInteger(node.inputs, "peer_asn") });
        try child.put(allocator, "ipAddress", .{ .string = try requiredString(node.inputs, "ip_address") });
        try child.put(allocator, "peerIpAddress", .{ .string = try requiredString(node.inputs, "peer_ip_address") });
        try child.put(allocator, "advertisedRoutePriority", .{ .integer = try requiredInteger(node.inputs, "route_priority") });
        try child.put(allocator, "advertiseMode", .{ .string = try requiredString(node.inputs, "advertise_mode") });
        try child.put(allocator, "advertisedGroups", try valueToJson(allocator, try requiredValue(node.inputs, "advertised_groups")));
        if (try requiredBoolean(node.inputs, "bfd_enabled")) {
            var bfd: std.json.ObjectMap = .empty;
            try bfd.put(allocator, "sessionInitializationMode", .{ .string = "ACTIVE" });
            try bfd.put(allocator, "minTransmitInterval", .{ .integer = try requiredInteger(node.inputs, "bfd_min_transmit_ms") });
            try bfd.put(allocator, "minReceiveInterval", .{ .integer = try requiredInteger(node.inputs, "bfd_min_receive_ms") });
            try bfd.put(allocator, "multiplier", .{ .integer = try requiredInteger(node.inputs, "bfd_multiplier") });
            try child.put(allocator, "bfd", .{ .object = bfd });
        }
    }
    return .{ .object = child };
}

fn peeringBodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, action: PeeringAction) ProviderError![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root: std.json.ObjectMap = .empty;
    var peering: std.json.ObjectMap = .empty;
    try peering.put(arena, "name", .{ .string = try requiredString(node.inputs, "name") });
    if (action != .remove) {
        try peering.put(arena, "network", .{ .string = try resolveString(context, try requiredValue(node.inputs, "peer_network")) });
        try peering.put(arena, "importCustomRoutes", .{ .bool = try requiredBoolean(node.inputs, "import_custom_routes") });
        try peering.put(arena, "exportCustomRoutes", .{ .bool = try requiredBoolean(node.inputs, "export_custom_routes") });
        try peering.put(arena, "importSubnetRoutesWithPublicIp", .{ .bool = try requiredBoolean(node.inputs, "import_subnet_routes_with_public_ip") });
        try peering.put(arena, "exportSubnetRoutesWithPublicIp", .{ .bool = try requiredBoolean(node.inputs, "export_subnet_routes_with_public_ip") });
        try peering.put(arena, "stackType", .{ .string = try requiredString(node.inputs, "stack_type") });
        try peering.put(arena, "updateStrategy", .{ .string = try requiredString(node.inputs, "update_strategy") });
    }
    try root.put(arena, "networkPeering", .{ .object = peering });
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch return error.OutOfMemory;
}

fn spokeBody(allocator: std.mem.Allocator, context: *provider_mod.OperationContext, node: resource.ResourceNode, body: *std.json.ObjectMap) ProviderError!void {
    try body.put(allocator, "name", .{ .string = try physicalIdAlloc(allocator, node, .spoke) });
    try body.put(allocator, "description", .{ .string = try requiredString(node.inputs, "description") });
    try body.put(allocator, "labels", try valueToJson(allocator, try requiredValue(node.inputs, "labels")));
    try body.put(allocator, "hub", .{ .string = try resolveString(context, try requiredValue(node.inputs, "hub")) });
    const group = try resolveString(context, try requiredValue(node.inputs, "group"));
    if (group.len > 0) try body.put(allocator, "group", .{ .string = group });
    const links = try requiredList(node.inputs, "links");
    const kind = try requiredString(node.inputs, "link_kind");
    if (std.mem.eql(u8, kind, "VPC_NETWORK")) {
        var link: std.json.ObjectMap = .empty;
        try link.put(allocator, "uri", .{ .string = try resolveString(context, links[0]) });
        try body.put(allocator, "linkedVpcNetwork", .{ .object = link });
    } else {
        var uris = std.json.Array.init(allocator);
        if (std.mem.eql(u8, kind, "ROUTER_APPLIANCES")) {
            for (links) |item| {
                const instance = try requiredObject(item);
                var encoded: std.json.ObjectMap = .empty;
                try encoded.put(allocator, "virtualMachine", .{ .string = try resolveString(context, try requiredObjectValue(instance, "virtual_machine")) });
                try encoded.put(allocator, "ipAddress", .{ .string = try requiredObjectString(instance, "ip_address") });
                try uris.append(.{ .object = encoded });
            }
        } else for (links) |item| try uris.append(.{ .string = try resolveString(context, item) });
        var link: std.json.ObjectMap = .empty;
        const key = if (std.mem.eql(u8, kind, "VPN_TUNNELS")) "uris" else if (std.mem.eql(u8, kind, "INTERCONNECT_ATTACHMENTS")) "uris" else "instances";
        try link.put(allocator, key, .{ .array = uris });
        try link.put(allocator, "siteToSiteDataTransfer", .{ .bool = try requiredBoolean(node.inputs, "site_to_site_data_transfer") });
        try body.put(allocator, if (std.mem.eql(u8, kind, "VPN_TUNNELS")) "linkedVpnTunnels" else if (std.mem.eql(u8, kind, "INTERCONNECT_ATTACHMENTS")) "linkedInterconnectAttachments" else "linkedRouterApplianceInstances", .{ .object = link });
    }
}

fn servicePolicyBody(allocator: std.mem.Allocator, context: *provider_mod.OperationContext, node: resource.ResourceNode, body: *std.json.ObjectMap) ProviderError!void {
    try body.put(allocator, "name", .{ .string = try physicalIdAlloc(allocator, node, .service_connection_policy) });
    try body.put(allocator, "description", .{ .string = try requiredString(node.inputs, "description") });
    try body.put(allocator, "labels", try valueToJson(allocator, try requiredValue(node.inputs, "labels")));
    try body.put(allocator, "network", .{ .string = try resolveString(context, try requiredValue(node.inputs, "network")) });
    try body.put(allocator, "serviceClass", .{ .string = try requiredString(node.inputs, "service_class") });
    var subnetworks = std.json.Array.init(allocator);
    for (try requiredList(node.inputs, "subnetworks")) |item| try subnetworks.append(.{ .string = try resolveString(context, item) });
    var psc: std.json.ObjectMap = .empty;
    try psc.put(allocator, "subnetworks", .{ .array = subnetworks });
    try psc.put(allocator, "producerInstanceLocation", .{ .string = try requiredString(node.inputs, "producer_location") });
    try psc.put(allocator, "allowedGoogleProducersResourceHierarchyLevel", try valueToJson(allocator, try requiredValue(node.inputs, "allowed_producer_hierarchy")));
    try body.put(allocator, "pscConfig", .{ .object = psc });
}

fn normalizeSpoke(context: *provider_mod.OperationContext, observed: *value.Value, remote: std.json.ObjectMap) ProviderError!void {
    try replaceString(context.allocator, observed, "description", jsonString(remote.get("description")) orelse "");
    try replaceJsonField(context.allocator, observed, "labels", remote.get("labels") orelse .{ .object = .empty });
    try replaceResolvedString(context, observed, "hub", try requiredJsonString(remote, "hub"));
    if (jsonString(remote.get("group"))) |group| try replaceResolvedString(context, observed, "group", group) else try replaceString(context.allocator, observed, "group", "");
    var links: []const []const u8 = undefined;
    var kind: []const u8 = undefined;
    var site_transfer = false;
    if (remote.get("linkedVpcNetwork")) |present| {
        const link = jsonObject(present) orelse return error.ProviderBug;
        links = &.{try requiredJsonString(link, "uri")};
        kind = "VPC_NETWORK";
    } else if (remote.get("linkedVpnTunnels")) |present| {
        const link = jsonObject(present) orelse return error.ProviderBug;
        links = try jsonStringSlicesAlloc(context.allocator, jsonArray(link.get("uris")) orelse return error.ProviderBug);
        defer context.allocator.free(links);
        kind = "VPN_TUNNELS";
        site_transfer = jsonBool(link.get("siteToSiteDataTransfer")) orelse false;
    } else if (remote.get("linkedInterconnectAttachments")) |present| {
        const link = jsonObject(present) orelse return error.ProviderBug;
        links = try jsonStringSlicesAlloc(context.allocator, jsonArray(link.get("uris")) orelse return error.ProviderBug);
        defer context.allocator.free(links);
        kind = "INTERCONNECT_ATTACHMENTS";
        site_transfer = jsonBool(link.get("siteToSiteDataTransfer")) orelse false;
    } else if (remote.get("linkedRouterApplianceInstances")) |present| {
        const link = jsonObject(present) orelse return error.ProviderBug;
        const instances = jsonArray(link.get("instances")) orelse return error.ProviderBug;
        try replaceRouterApplianceList(context, observed, instances);
        kind = "ROUTER_APPLIANCES";
        site_transfer = jsonBool(link.get("siteToSiteDataTransfer")) orelse false;
    } else return error.ProviderBug;
    try replaceString(context.allocator, observed, "link_kind", kind);
    if (!std.mem.eql(u8, kind, "ROUTER_APPLIANCES")) try replaceResolvedStringList(context, observed, "links", links);
    try replaceBoolean(context.allocator, observed, "site_to_site_data_transfer", site_transfer);
}

fn normalizeServicePolicy(context: *provider_mod.OperationContext, observed: *value.Value, remote: std.json.ObjectMap) ProviderError!void {
    try replaceString(context.allocator, observed, "description", jsonString(remote.get("description")) orelse "");
    try replaceJsonField(context.allocator, observed, "labels", remote.get("labels") orelse .{ .object = .empty });
    try replaceResolvedString(context, observed, "network", try requiredJsonString(remote, "network"));
    try replaceString(context.allocator, observed, "service_class", try requiredJsonString(remote, "serviceClass"));
    const psc = jsonObject(remote.get("pscConfig") orelse return error.ProviderBug) orelse return error.ProviderBug;
    const subnetworks = try jsonStringSlicesAlloc(context.allocator, jsonArray(psc.get("subnetworks")) orelse return error.ProviderBug);
    defer context.allocator.free(subnetworks);
    try replaceResolvedStringList(context, observed, "subnetworks", subnetworks);
    try replaceString(context.allocator, observed, "producer_location", jsonString(psc.get("producerInstanceLocation")) orelse "PRODUCER_INSTANCE_LOCATION_UNSPECIFIED");
    try replaceJsonField(context.allocator, observed, "allowed_producer_hierarchy", psc.get("allowedGoogleProducersResourceHierarchyLevel") orelse .{ .array = std.json.Array.init(context.allocator) });
}

fn replaceRouterApplianceList(context: *provider_mod.OperationContext, inputs: *value.Value, remote: std.json.Array) ProviderError!void {
    const desired = try requiredList(inputs.*, "links");
    if (desired.len == remote.items.len) {
        var matches = true;
        for (desired, remote.items) |item, remote_item| {
            const instance = try requiredObject(item);
            const observed_instance = jsonObject(remote_item) orelse return error.ProviderBug;
            if (!std.mem.eql(u8, canonicalResourceName(try resolveString(context, try requiredObjectValue(instance, "virtual_machine"))), canonicalResourceName(try requiredJsonString(observed_instance, "virtualMachine"))) or
                !std.mem.eql(u8, try requiredObjectString(instance, "ip_address"), try requiredJsonString(observed_instance, "ipAddress")))
            {
                matches = false;
                break;
            }
        }
        if (matches) return;
    }
    var normalized = std.json.Array.init(context.allocator);
    defer normalized.deinit();
    for (remote.items) |remote_item| {
        const instance = jsonObject(remote_item) orelse return error.ProviderBug;
        var encoded: std.json.ObjectMap = .empty;
        try encoded.put(context.allocator, "ip_address", .{ .string = try requiredJsonString(instance, "ipAddress") });
        try encoded.put(context.allocator, "virtual_machine", .{ .string = canonicalResourceName(try requiredJsonString(instance, "virtualMachine")) });
        try normalized.append(.{ .object = encoded });
    }
    try replaceJsonField(context.allocator, inputs, "links", .{ .array = normalized });
}

fn replaceResolvedStringList(context: *provider_mod.OperationContext, inputs: *value.Value, field: []const u8, remote: []const []const u8) ProviderError!void {
    const desired = switch (try requiredValue(inputs.*, field)) {
        .list => |items| items,
        else => return error.ProviderBug,
    };
    if (desired.len == remote.len) {
        var matches = true;
        for (desired, remote) |item, text| {
            if (!std.mem.eql(u8, canonicalResourceName(try resolveString(context, item)), canonicalResourceName(text))) {
                matches = false;
                break;
            }
        }
        if (matches) return;
    }
    var array = std.json.Array.init(context.allocator);
    defer array.deinit();
    for (remote) |text| try array.append(.{ .string = canonicalResourceName(text) });
    try replaceJsonField(context.allocator, inputs, field, .{ .array = array });
}

fn jsonStringSlicesAlloc(allocator: std.mem.Allocator, array: std.json.Array) ProviderError![]const []const u8 {
    const result = try allocator.alloc([]const u8, array.items.len);
    for (array.items, 0..) |item, index| result[index] = jsonString(item) orelse {
        allocator.free(result);
        return error.ProviderBug;
    };
    return result;
}

fn externalInterfacesJson(allocator: std.mem.Allocator, items: []const value.Value) ProviderError!std.json.Value {
    var result = std.json.Array.init(allocator);
    for (items) |item| {
        var interface: std.json.ObjectMap = .empty;
        try interface.put(allocator, "id", .{ .integer = try requiredInteger(item, "id") });
        try interface.put(allocator, "ipAddress", .{ .string = try requiredString(item, "ip_address") });
        try result.append(.{ .object = interface });
    }
    return .{ .array = result };
}

fn normalizedExternalInterfaces(allocator: std.mem.Allocator, remote: std.json.ObjectMap) ProviderError!std.json.Value {
    const interfaces = jsonArray(remote.get("interfaces")) orelse return error.ProviderBug;
    var result = std.json.Array.init(allocator);
    for (interfaces.items) |item| {
        const interface = jsonObject(item) orelse return error.ProviderBug;
        var normalized: std.json.ObjectMap = .empty;
        try normalized.put(allocator, "id", .{ .integer = try requiredJsonInteger(interface, "id") });
        try normalized.put(allocator, "ip_address", .{ .string = try requiredJsonString(interface, "ipAddress") });
        try result.append(.{ .object = normalized });
    }
    return .{ .array = result };
}

fn pendingResult(allocator: std.mem.Allocator, node: resource.ResourceNode, resource_kind: Kind, handle: []const u8) ProviderError!provider_mod.ResourceResult {
    var result = try desiredResult(allocator, node, resource_kind, handle);
    result.completed = false;
    return result;
}

fn desiredResult(allocator: std.mem.Allocator, node: resource.ResourceNode, resource_kind: Kind, handle: ?[]const u8) ProviderError!provider_mod.ResourceResult {
    const physical = try physicalIdAlloc(allocator, node, resource_kind);
    defer allocator.free(physical);
    const outputs = [_]state.StateOutput{.{ .name = if (isNcc(resource_kind)) "name" else if (resource_kind == .router_interface or resource_kind == .router_bgp_peer or resource_kind == .network_peering) "resource_id" else "self_link", .value = .{ .unknown_reason = "connectivity operation pending" } }};
    return provider_mod.ResourceResult.init(allocator, physical, node.inputs, &outputs, handle);
}

fn readPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, resource_kind: Kind) ProviderError![]const u8 {
    return switch (resource_kind) {
        .router_interface, .router_bgp_peer => routerPathAlloc(allocator, node),
        .network_peering => networkPathAlloc(allocator, node),
        else => blk: {
            const physical = try physicalIdAlloc(allocator, node, resource_kind);
            defer allocator.free(physical);
            break :blk std.fmt.allocPrint(allocator, "/{s}/{s}", .{ if (isNcc(resource_kind)) "v1" else "compute/v1", physical }) catch return error.OutOfMemory;
        },
    };
}

fn collectionPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, resource_kind: Kind) ProviderError![]const u8 {
    const project = try requiredString(node.inputs, "project_id");
    const name = try requiredString(node.inputs, "name");
    _ = name;
    return switch (resource_kind) {
        .ha_vpn_gateway => std.fmt.allocPrint(allocator, "/compute/v1/projects/{s}/regions/{s}/vpnGateways", .{ project, try requiredString(node.inputs, "region") }),
        .external_vpn_gateway => std.fmt.allocPrint(allocator, "/compute/v1/projects/{s}/global/externalVpnGateways", .{project}),
        .vpn_tunnel => std.fmt.allocPrint(allocator, "/compute/v1/projects/{s}/regions/{s}/vpnTunnels", .{ project, try requiredString(node.inputs, "region") }),
        else => return error.InvalidConfiguration,
    } catch return error.OutOfMemory;
}

fn createNccPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, resource_kind: Kind) ProviderError![]const u8 {
    const collection = nccCollection(resource_kind) orelse return error.InvalidConfiguration;
    const id_key = switch (resource_kind) {
        .hub => "hubId",
        .spoke => "spokeId",
        .service_connection_policy => "serviceConnectionPolicyId",
        else => unreachable,
    };
    return std.fmt.allocPrint(allocator, "/v1/projects/{s}/locations/{s}/{s}?{s}={s}", .{ try requiredString(node.inputs, "project_id"), locationFor(node, resource_kind), collection, id_key, try requiredString(node.inputs, "name") }) catch return error.OutOfMemory;
}

fn updateNccPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, resource_kind: Kind) ProviderError![]const u8 {
    const physical = try physicalIdAlloc(allocator, node, resource_kind);
    defer allocator.free(physical);
    const mask = switch (resource_kind) {
        .hub => "description%2Clabels%2CpolicyMode%2CpresetTopology%2CexportPsc",
        .spoke => "description%2Clabels%2Cgroup%2ClinkedVpcNetwork%2ClinkedVpnTunnels%2ClinkedInterconnectAttachments%2ClinkedRouterApplianceInstances",
        .service_connection_policy => "description%2Clabels%2CpscConfig",
        else => return error.InvalidConfiguration,
    };
    return std.fmt.allocPrint(allocator, "/v1/{s}?updateMask={s}", .{ physical, mask }) catch return error.OutOfMemory;
}

fn routerPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "/compute/v1/projects/{s}/regions/{s}/routers/{s}", .{ try requiredString(node.inputs, "project_id"), try requiredString(node.inputs, "region"), try requiredString(node.inputs, "router_name") }) catch return error.OutOfMemory;
}

fn networkPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "/compute/v1/projects/{s}/global/networks/{s}", .{ try requiredString(node.inputs, "project_id"), try requiredString(node.inputs, "network_name") }) catch return error.OutOfMemory;
}

fn peeringActionPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, action: PeeringAction) ProviderError![]const u8 {
    const base = try networkPathAlloc(allocator, node);
    defer allocator.free(base);
    return std.fmt.allocPrint(allocator, "{s}/{s}Peering", .{ base, @tagName(action) }) catch return error.OutOfMemory;
}

fn physicalIdAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, resource_kind: Kind) ProviderError![]const u8 {
    const project = try requiredString(node.inputs, "project_id");
    const name = try requiredString(node.inputs, "name");
    return switch (resource_kind) {
        .ha_vpn_gateway => std.fmt.allocPrint(allocator, "projects/{s}/regions/{s}/vpnGateways/{s}", .{ project, try requiredString(node.inputs, "region"), name }),
        .external_vpn_gateway => std.fmt.allocPrint(allocator, "projects/{s}/global/externalVpnGateways/{s}", .{ project, name }),
        .vpn_tunnel => std.fmt.allocPrint(allocator, "projects/{s}/regions/{s}/vpnTunnels/{s}", .{ project, try requiredString(node.inputs, "region"), name }),
        .router_interface => std.fmt.allocPrint(allocator, "projects/{s}/regions/{s}/routers/{s}/interfaces/{s}", .{ project, try requiredString(node.inputs, "region"), try requiredString(node.inputs, "router_name"), name }),
        .router_bgp_peer => std.fmt.allocPrint(allocator, "projects/{s}/regions/{s}/routers/{s}/bgpPeers/{s}", .{ project, try requiredString(node.inputs, "region"), try requiredString(node.inputs, "router_name"), name }),
        .network_peering => std.fmt.allocPrint(allocator, "projects/{s}/global/networks/{s}/peerings/{s}", .{ project, try requiredString(node.inputs, "network_name"), name }),
        .hub => std.fmt.allocPrint(allocator, "projects/{s}/locations/global/hubs/{s}", .{ project, name }),
        .spoke => std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}/spokes/{s}", .{ project, try requiredString(node.inputs, "location"), name }),
        .service_connection_policy => std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}/serviceConnectionPolicies/{s}", .{ project, try requiredString(node.inputs, "location"), name }),
    } catch return error.OutOfMemory;
}

fn validatePhysical(allocator: std.mem.Allocator, node: resource.ResourceNode, resource_kind: Kind, physical: []const u8) ProviderError!void {
    const expected = try physicalIdAlloc(allocator, node, resource_kind);
    defer allocator.free(expected);
    if (!std.mem.eql(u8, expected, physical)) return error.InvalidConfiguration;
}

fn nccCollection(resource_kind: Kind) ?[]const u8 {
    return switch (resource_kind) {
        .hub => "hubs",
        .spoke => "spokes",
        .service_connection_policy => "serviceConnectionPolicies",
        else => null,
    };
}

fn locationFor(node: resource.ResourceNode, resource_kind: Kind) []const u8 {
    return if (resource_kind == .hub) "global" else requiredString(node.inputs, "location") catch unreachable;
}

fn operationNameAlloc(allocator: std.mem.Allocator, body: []const u8) ProviderError![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    return allocator.dupe(u8, try requiredJsonString(jsonObject(parsed.value) orelse return error.ProviderBug, "name")) catch return error.OutOfMemory;
}

fn outputString(observed: *const provider_mod.ResourceResult, name: []const u8) ?[]const u8 {
    for (observed.outputs) |item| if (std.mem.eql(u8, item.name, name)) return switch (item.value) {
        .string => |text| text,
        else => null,
    };
    return null;
}

fn identityChanged(left: value.Value, right: value.Value, fields: []const []const u8) bool {
    for (fields) |field| if (!valuesEqual(requiredValue(left, field) catch return true, requiredValue(right, field) catch return true)) return true;
    return false;
}

fn valuesEqual(left: value.Value, right: value.Value) bool {
    var left_buffer: [1024]u8 = undefined;
    var right_buffer: [1024]u8 = undefined;
    var left_allocator = std.heap.FixedBufferAllocator.init(&left_buffer);
    var right_allocator = std.heap.FixedBufferAllocator.init(&right_buffer);
    const left_json = left.canonicalJsonAlloc(left_allocator.allocator()) catch return false;
    const right_json = right.canonicalJsonAlloc(right_allocator.allocator()) catch return false;
    return std.mem.eql(u8, left_json, right_json);
}

fn replaceResolvedString(context: *provider_mod.OperationContext, inputs: *value.Value, field: []const u8, remote: []const u8) ProviderError!void {
    const desired = try requiredValue(inputs.*, field);
    if (std.mem.eql(u8, canonicalResourceName(try resolveString(context, desired)), canonicalResourceName(remote))) return;
    try replaceString(context.allocator, inputs, field, canonicalResourceName(remote));
}

fn replaceString(allocator: std.mem.Allocator, inputs: *value.Value, field: []const u8, text: []const u8) ProviderError!void {
    try replaceValue(allocator, inputs, field, .{ .string = text });
}

fn replaceInteger(allocator: std.mem.Allocator, inputs: *value.Value, field: []const u8, number: i64) ProviderError!void {
    try replaceValue(allocator, inputs, field, .{ .integer = number });
}

fn replaceBoolean(allocator: std.mem.Allocator, inputs: *value.Value, field: []const u8, boolean: bool) ProviderError!void {
    try replaceValue(allocator, inputs, field, .{ .boolean = boolean });
}

fn replaceJsonField(allocator: std.mem.Allocator, inputs: *value.Value, field: []const u8, json: std.json.Value) ProviderError!void {
    var converted = value.Value.fromJsonValueAlloc(allocator, json) catch |err| switch (err) {
        error.DuplicateField, error.InvalidJson, error.UnsupportedJsonValue => return error.ProviderBug,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer converted.deinit(allocator);
    try replaceValue(allocator, inputs, field, converted);
}

fn replaceValue(allocator: std.mem.Allocator, inputs: *value.Value, field: []const u8, replacement: value.Value) ProviderError!void {
    const fields = switch (inputs.*) {
        .object => |present| @constCast(present),
        else => return error.ProviderBug,
    };
    for (fields) |*candidate| if (std.mem.eql(u8, candidate.name, field)) {
        const next = replacement.clone(allocator) catch |err| switch (err) {
            error.DuplicateField => return error.ProviderBug,
            error.OutOfMemory => return error.OutOfMemory,
        };
        candidate.value.deinit(allocator);
        candidate.value = next;
        return;
    };
    return error.ProviderBug;
}

fn canonicalResourceName(input: []const u8) []const u8 {
    if (std.mem.indexOf(u8, input, "projects/")) |start| return input[start..];
    return std.mem.trimStart(u8, input, "/");
}

fn valueToJson(allocator: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    const json = input.canonicalJsonAlloc(allocator) catch |err| switch (err) {
        error.DuplicateField => return error.ProviderBug,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{}) catch return error.ProviderBug;
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
    return switch (try requiredValue(input, name)) {
        .string => |text| text,
        else => error.InvalidConfiguration,
    };
}

fn requiredInteger(input: value.Value, name: []const u8) ProviderError!i64 {
    return switch (try requiredValue(input, name)) {
        .integer => |number| number,
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
    return switch (try requiredValue(input, name)) {
        .list => |items| items,
        else => error.InvalidConfiguration,
    };
}

fn requiredObject(input: value.Value) ProviderError![]const value.Field {
    return switch (input) {
        .object => |fields| fields,
        else => error.InvalidConfiguration,
    };
}

fn requiredObjectValue(fields: []const value.Field, name: []const u8) ProviderError!value.Value {
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return error.InvalidConfiguration;
}

fn requiredObjectString(fields: []const value.Field, name: []const u8) ProviderError![]const u8 {
    return switch (try requiredObjectValue(fields, name)) {
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

fn resolveSecret(context: *provider_mod.OperationContext, input: value.Value) ProviderError!value.SecretReference {
    return switch (input) {
        .secret_ref => |reference| reference,
        .output_ref => |reference| context.resolveOutputSecret(reference),
        else => error.InvalidConfiguration,
    };
}

fn requiredJsonString(object: std.json.ObjectMap, name: []const u8) ProviderError![]const u8 {
    return jsonString(object.get(name)) orelse error.ProviderBug;
}

fn requiredJsonInteger(object: std.json.ObjectMap, name: []const u8) ProviderError!i64 {
    return jsonInteger(object.get(name) orelse return error.ProviderBug) orelse error.ProviderBug;
}

fn jsonObject(input: std.json.Value) ?std.json.ObjectMap {
    return switch (input) {
        .object => |object| object,
        else => null,
    };
}

fn jsonArray(maybe_input: ?std.json.Value) ?std.json.Array {
    const input = maybe_input orelse return null;
    return switch (input) {
        .array => |array| array,
        else => null,
    };
}

fn jsonString(maybe_input: ?std.json.Value) ?[]const u8 {
    const input = maybe_input orelse return null;
    return switch (input) {
        .string => |text| text,
        else => null,
    };
}

fn jsonInteger(input: std.json.Value) ?i64 {
    return switch (input) {
        .integer => |number| number,
        else => null,
    };
}

fn jsonBool(maybe_input: ?std.json.Value) ?bool {
    const input = maybe_input orelse return null;
    return switch (input) {
        .bool => |boolean| boolean,
        else => null,
    };
}
