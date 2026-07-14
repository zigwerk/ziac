const std = @import("std");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;

const Kind = enum {
    cluster,
    node_pool,
    fleet,
    membership,
    function_v2,
    function_iam_member,
    batch_job,
};

pub const Handler = struct {
    client: *client_mod.Client,
    operation_policy: operation.Policy = .{},

    pub fn read(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        const physical = try physicalIdAlloc(context.allocator, node, kind);
        defer context.allocator.free(physical);
        if (physical_override) |candidate| if (!std.mem.eql(u8, physical, candidate)) return error.InvalidConfiguration;
        if (context.operation_handle) |handle| try self.waitOperation(context, node, kind, handle);
        if (kind == .function_iam_member) return self.readFunctionIam(context, node);
        const path = try readPathAlloc(context.allocator, node, kind);
        defer context.allocator.free(path);
        var response = self.request(context, apiFor(kind), "GET", path, "") catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try resultFromJson(context, node, kind, response.body) };
    }

    pub fn diff(context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash)) return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        const replacement = switch (kind) {
            .batch_job => true,
            .cluster => identityChanged(node.inputs, observed.observed_inputs, &.{
                "project_id", "location", "name", "mode", "network", "subnetwork", "cluster_secondary_range", "services_secondary_range", "master_ipv4_cidr", "private_nodes",
            }),
            .node_pool => identityChanged(node.inputs, observed.observed_inputs, &.{ "project_id", "location", "cluster_name", "name", "cluster" }),
            .fleet => identityChanged(node.inputs, observed.observed_inputs, &.{ "project_id", "name" }),
            .membership => identityChanged(node.inputs, observed.observed_inputs, &.{ "project_id", "location", "name" }),
            .function_v2 => identityChanged(node.inputs, observed.observed_inputs, &.{ "project_id", "location", "name" }),
            .function_iam_member => identityChanged(node.inputs, observed.observed_inputs, &.{ "project_id", "location", "function_name", "role", "member" }),
        };
        return provider_mod.DiffResult.init(context.allocator, if (replacement) .replace else .update, &.{if (replacement) "immutable container platform identity changed" else "container platform configuration differs"});
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (kind == .function_iam_member) return self.mutateFunctionIam(context, node, true);
        var body = try bodyAlloc(context, node, kind);
        defer body.deinit(context.allocator);
        const path = try createPathAlloc(context.allocator, node, kind);
        defer context.allocator.free(path);
        var response = try self.request(context, apiFor(kind), "POST", path, body.bytes);
        defer response.deinit(context.allocator);
        if (kind == .batch_job) return resultFromJson(context, node, kind, response.body);
        const handle = try operationNameAlloc(context.allocator, response.body);
        defer context.allocator.free(handle);
        return pendingResult(context.allocator, node, kind, handle);
    }

    pub fn update(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        return switch (kind) {
            .cluster => self.updateCluster(context, node, observed),
            .node_pool => self.updateNodePool(context, node, observed),
            .fleet, .membership, .function_v2 => self.patchGeneric(context, node, kind),
            .function_iam_member => self.mutateFunctionIam(context, node, true),
            .batch_job => error.InvalidConfiguration,
        };
    }

    pub fn delete(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!void {
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(context.allocator, node, kind, physical_id);
        if (kind == .function_iam_member) {
            var result = try self.mutateFunctionIam(context, node, false);
            result.deinit();
            return;
        }
        const path = try readPathAlloc(context.allocator, node, kind);
        defer context.allocator.free(path);
        var response = self.request(context, apiFor(kind), "DELETE", path, "") catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer response.deinit(context.allocator);
        const handle = try operationNameAlloc(context.allocator, response.body);
        defer context.allocator.free(handle);
        try self.waitOperation(context, node, kind, handle);
    }

    pub fn importResource(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!provider_mod.ResourceResult {
        var read_result = try self.read(context, node, physical_id);
        defer read_result.deinit();
        return switch (read_result) {
            .absent => error.NotFound,
            .present => |present| present.clone(context.allocator) catch error.OutOfMemory,
        };
    }

    pub fn cancelBatchJob(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!void {
        if (kindOf(node) != .batch_job) return error.InvalidConfiguration;
        const read_path = try readPathAlloc(context.allocator, node, .batch_job);
        defer context.allocator.free(read_path);
        const path = try std.fmt.allocPrint(context.allocator, "{s}:cancel", .{read_path});
        defer context.allocator.free(path);
        var response = try self.request(context, .batch, "POST", path, "{}");
        defer response.deinit(context.allocator);
        const handle = try operationNameAlloc(context.allocator, response.body);
        defer context.allocator.free(handle);
        try self.waitOperation(context, node, .batch_job, handle);
    }

    fn updateCluster(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        const path = try readPathAlloc(context.allocator, node, .cluster);
        defer context.allocator.free(path);
        const labels_changed = !fieldEqual(node.inputs, observed.observed_inputs, "labels");
        if (labels_changed) {
            const action = try std.fmt.allocPrint(context.allocator, "{s}:setResourceLabels", .{path});
            defer context.allocator.free(action);
            const body = try clusterLabelsBodyAlloc(context, node, outputString(observed, "label_fingerprint") orelse "");
            defer context.allocator.free(body);
            return self.startPending(context, node, .cluster, "POST", action, body);
        }
        const body = try clusterUpdateBodyAlloc(context, node);
        defer context.allocator.free(body);
        return self.startPending(context, node, .cluster, "PUT", path, body);
    }

    fn updateNodePool(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        const base = try readPathAlloc(context.allocator, node, .node_pool);
        defer context.allocator.free(base);
        if (!fieldEqual(node.inputs, observed.observed_inputs, "node_count")) {
            const path = try std.fmt.allocPrint(context.allocator, "{s}:setSize", .{base});
            defer context.allocator.free(path);
            const physical = try physicalIdAlloc(context.allocator, node, .node_pool);
            defer context.allocator.free(physical);
            const body = try std.fmt.allocPrint(context.allocator, "{{\"name\":\"{s}\",\"nodeCount\":{d}}}", .{ physical, try requiredInteger(node.inputs, "node_count") });
            defer context.allocator.free(body);
            return self.startPending(context, node, .node_pool, "POST", path, body);
        }
        inline for (&.{ "autoscaling_enabled", "min_nodes", "max_nodes", "total_min_nodes", "total_max_nodes" }) |field| {
            if (!fieldEqual(node.inputs, observed.observed_inputs, field)) {
                const path = try std.fmt.allocPrint(context.allocator, "{s}:setAutoscaling", .{base});
                defer context.allocator.free(path);
                const body = try nodePoolAutoscalingBodyAlloc(context, node);
                defer context.allocator.free(body);
                return self.startPending(context, node, .node_pool, "POST", path, body);
            }
        }
        const body = try nodePoolUpdateBodyAlloc(context, node);
        defer context.allocator.free(body);
        return self.startPending(context, node, .node_pool, "PUT", base, body);
    }

    fn patchGeneric(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind) ProviderError!provider_mod.ResourceResult {
        var body = try bodyAlloc(context, node, kind);
        defer body.deinit(context.allocator);
        const path = try updatePathAlloc(context.allocator, node, kind);
        defer context.allocator.free(path);
        return self.startPending(context, node, kind, "PATCH", path, body.bytes);
    }

    fn startPending(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, method: []const u8, path: []const u8, body: []const u8) ProviderError!provider_mod.ResourceResult {
        var response = try self.request(context, apiFor(kind), method, path, body);
        defer response.deinit(context.allocator);
        const handle = try operationNameAlloc(context.allocator, response.body);
        defer context.allocator.free(handle);
        return pendingResult(context.allocator, node, kind, handle);
    }

    fn waitOperation(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, handle: []const u8) ProviderError!void {
        if (kind == .cluster or kind == .node_pool) return self.waitContainerOperation(context, node, handle);
        const api = apiFor(kind);
        const version = if (kind == .function_v2 or kind == .function_iam_member) "v2" else "v1";
        const base = try std.fmt.allocPrint(context.allocator, "{s}/{s}", .{ std.mem.trimEnd(u8, self.client.endpoints.get(api), "/"), version });
        defer context.allocator.free(base);
        var target = operation.Target.genericAlloc(context.allocator, base, handle) catch return error.OutOfMemory;
        defer target.deinit(context.allocator);
        var completed = try operation.waitAlloc(self.client, context, target, self.operation_policy);
        completed.deinit(context.allocator);
    }

    fn waitContainerOperation(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, handle: []const u8) ProviderError!void {
        var failures: usize = 0;
        const path = if (std.mem.startsWith(u8, handle, "projects/"))
            try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{handle})
        else
            try std.fmt.allocPrint(context.allocator, "/v1/projects/{s}/locations/{s}/operations/{s}", .{ try requiredString(node.inputs, "project_id"), try requiredString(node.inputs, "location"), handle });
        defer context.allocator.free(path);
        while (true) {
            try context.checkActive();
            var response = self.request(context, .container, "GET", path, "") catch |err| {
                if ((err == error.TransientFailure or err == error.RateLimited) and failures < self.operation_policy.max_transient_failures) {
                    failures += 1;
                    context.sleep(self.operation_policy.poll_interval_millis);
                    continue;
                }
                return err;
            };
            defer response.deinit(context.allocator);
            failures = 0;
            var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
            defer parsed.deinit();
            const root = jsonObject(parsed.value) orelse return error.ProviderBug;
            const status = jsonString(root.get("status")) orelse return error.ProviderBug;
            if (!std.mem.eql(u8, status, "DONE")) {
                context.sleep(self.operation_policy.poll_interval_millis);
                continue;
            }
            if (root.get("error")) |present| if (jsonObject(present) != null) return error.ProviderBug;
            return;
        }
    }

    fn readFunctionIam(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ReadResult {
        const path = try functionIamPathAlloc(context.allocator, node, "getIamPolicy");
        defer context.allocator.free(path);
        var response = self.request(context, .cloud_functions, "GET", path, "") catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const policy = jsonObject(parsed.value) orelse return error.ProviderBug;
        if (!policyHasMember(policy, try requiredString(node.inputs, "role"), try requiredString(node.inputs, "member"))) return .absent;
        return .{ .present = try iamResult(context, node, jsonString(policy.get("etag")) orelse "") };
    }

    fn mutateFunctionIam(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, should_exist: bool) ProviderError!provider_mod.ResourceResult {
        const get_path = try functionIamPathAlloc(context.allocator, node, "getIamPolicy");
        defer context.allocator.free(get_path);
        var response = self.request(context, .cloud_functions, "GET", get_path, "") catch |err| {
            if (err == error.NotFound and !should_exist) return iamResult(context, node, "");
            return err;
        };
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const changed = try mutatePolicy(parsed.arena.allocator(), &parsed.value, try requiredString(node.inputs, "role"), try requiredString(node.inputs, "member"), should_exist);
        if (!changed) return iamResult(context, node, jsonString((jsonObject(parsed.value) orelse return error.ProviderBug).get("etag")) orelse "");
        var body_root: std.json.ObjectMap = .empty;
        try body_root.put(parsed.arena.allocator(), "policy", parsed.value);
        const body = std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = body_root }, .{}) catch return error.OutOfMemory;
        defer context.allocator.free(body);
        const set_path = try functionIamPathAlloc(context.allocator, node, "setIamPolicy");
        defer context.allocator.free(set_path);
        var set_response = try self.request(context, .cloud_functions, "POST", set_path, body);
        defer set_response.deinit(context.allocator);
        var set_parsed = std.json.parseFromSlice(std.json.Value, context.allocator, set_response.body, .{}) catch return error.ProviderBug;
        defer set_parsed.deinit();
        const policy = jsonObject(set_parsed.value) orelse return error.ProviderBug;
        return iamResult(context, node, jsonString(policy.get("etag")) orelse "");
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, api: client_mod.Api, method: []const u8, path: []const u8, body: []const u8) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, .{ .api = api, .method = method, .path = path, .body = body }, &diagnostic);
    }
};

pub fn supports(node: resource.ResourceNode) bool {
    return kindOf(node) != null;
}

const Body = struct {
    bytes: []const u8,
    fn deinit(self: *Body, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

fn kindOf(node: resource.ResourceNode) ?Kind {
    const entries = .{
        .{ "gcp.container.Cluster", Kind.cluster },
        .{ "gcp.container.NodePool", Kind.node_pool },
        .{ "gcp.gkehub.Fleet", Kind.fleet },
        .{ "gcp.gkehub.Membership", Kind.membership },
        .{ "gcp.functions.FunctionV2", Kind.function_v2 },
        .{ "gcp.functions.FunctionIamMember", Kind.function_iam_member },
        .{ "gcp.batch.Job", Kind.batch_job },
    };
    inline for (entries) |entry| if (std.mem.eql(u8, node.type_name, entry[0])) return entry[1];
    return null;
}

fn apiFor(kind: Kind) client_mod.Api {
    return switch (kind) {
        .cluster, .node_pool => .container,
        .fleet, .membership => .gke_hub,
        .function_v2, .function_iam_member => .cloud_functions,
        .batch_job => .batch,
    };
}

fn bodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind) ProviderError!Body {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root: std.json.ObjectMap = .empty;
    switch (kind) {
        .cluster => try root.put(arena, "cluster", try clusterJson(context, node, arena)),
        .node_pool => try root.put(arena, "nodePool", try nodePoolJson(context, node, arena)),
        .fleet => try fleetJson(context, node, arena, &root),
        .membership => try membershipJson(context, node, arena, &root),
        .function_v2 => try functionJson(context, node, arena, &root),
        .batch_job => try batchJson(context, node, arena, &root),
        .function_iam_member => return error.InvalidConfiguration,
    }
    return .{ .bytes = std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch return error.OutOfMemory };
}

fn clusterJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, allocator: std.mem.Allocator) ProviderError!std.json.Value {
    var cluster: std.json.ObjectMap = .empty;
    try cluster.put(allocator, "name", .{ .string = try requiredString(node.inputs, "name") });
    try cluster.put(allocator, "description", .{ .string = try requiredString(node.inputs, "description") });
    try cluster.put(allocator, "network", .{ .string = try resolveString(context, try requiredValue(node.inputs, "network")) });
    try cluster.put(allocator, "subnetwork", .{ .string = try resolveString(context, try requiredValue(node.inputs, "subnetwork")) });
    try cluster.put(allocator, "deletionProtection", .{ .bool = try requiredBoolean(node.inputs, "deletion_protection") });
    try cluster.put(allocator, "resourceLabels", try valueToJson(allocator, try requiredValue(node.inputs, "labels")));
    const mode = try requiredString(node.inputs, "mode");
    if (std.mem.eql(u8, mode, "AUTOPILOT")) {
        var autopilot: std.json.ObjectMap = .empty;
        try autopilot.put(allocator, "enabled", .{ .bool = true });
        try cluster.put(allocator, "autopilot", .{ .object = autopilot });
    } else {
        try cluster.put(allocator, "initialNodeCount", .{ .integer = 1 });
        try cluster.put(allocator, "removeDefaultNodePool", .{ .bool = true });
    }
    var release: std.json.ObjectMap = .empty;
    try release.put(allocator, "channel", .{ .string = try requiredString(node.inputs, "release_channel") });
    try cluster.put(allocator, "releaseChannel", .{ .object = release });
    var identity: std.json.ObjectMap = .empty;
    try identity.put(allocator, "workloadPool", .{ .string = try requiredString(node.inputs, "workload_pool") });
    try cluster.put(allocator, "workloadIdentityConfig", .{ .object = identity });
    var ip: std.json.ObjectMap = .empty;
    try ip.put(allocator, "useIpAliases", .{ .bool = true });
    const pod_range = try requiredString(node.inputs, "cluster_secondary_range");
    const service_range = try requiredString(node.inputs, "services_secondary_range");
    if (pod_range.len > 0) try ip.put(allocator, "clusterSecondaryRangeName", .{ .string = pod_range });
    if (service_range.len > 0) try ip.put(allocator, "servicesSecondaryRangeName", .{ .string = service_range });
    try cluster.put(allocator, "ipAllocationPolicy", .{ .object = ip });
    var private: std.json.ObjectMap = .empty;
    try private.put(allocator, "enablePrivateNodes", .{ .bool = try requiredBoolean(node.inputs, "private_nodes") });
    try private.put(allocator, "enablePrivateEndpoint", .{ .bool = try requiredBoolean(node.inputs, "private_endpoint") });
    const master_cidr = try requiredString(node.inputs, "master_ipv4_cidr");
    if (master_cidr.len > 0) try private.put(allocator, "masterIpv4CidrBlock", .{ .string = master_cidr });
    try cluster.put(allocator, "privateClusterConfig", .{ .object = private });
    try cluster.put(allocator, "masterAuthorizedNetworksConfig", try authorizedNetworksJson(allocator, try requiredList(node.inputs, "authorized_networks")));
    var binary: std.json.ObjectMap = .empty;
    try binary.put(allocator, "evaluationMode", .{ .string = try requiredString(node.inputs, "binary_authorization") });
    try cluster.put(allocator, "binaryAuthorization", .{ .object = binary });
    try cluster.put(allocator, "loggingConfig", try componentConfigJson(allocator, try requiredList(node.inputs, "logging_components")));
    try cluster.put(allocator, "monitoringConfig", try componentConfigJson(allocator, try requiredList(node.inputs, "monitoring_components")));
    return .{ .object = cluster };
}

fn nodePoolJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, allocator: std.mem.Allocator) ProviderError!std.json.Value {
    var pool: std.json.ObjectMap = .empty;
    try pool.put(allocator, "name", .{ .string = try requiredString(node.inputs, "name") });
    try pool.put(allocator, "initialNodeCount", .{ .integer = try requiredInteger(node.inputs, "node_count") });
    try pool.put(allocator, "locations", try valueToJson(allocator, try requiredValue(node.inputs, "locations")));
    var config: std.json.ObjectMap = .empty;
    try config.put(allocator, "machineType", .{ .string = try requiredString(node.inputs, "machine_type") });
    try config.put(allocator, "diskType", .{ .string = try requiredString(node.inputs, "disk_type") });
    try config.put(allocator, "diskSizeGb", .{ .integer = try requiredInteger(node.inputs, "disk_size_gb") });
    try config.put(allocator, "imageType", .{ .string = try requiredString(node.inputs, "image_type") });
    try config.put(allocator, "serviceAccount", .{ .string = try resolveString(context, try requiredValue(node.inputs, "service_account")) });
    try config.put(allocator, "oauthScopes", try valueToJson(allocator, try requiredValue(node.inputs, "oauth_scopes")));
    try config.put(allocator, "spot", .{ .bool = try requiredBoolean(node.inputs, "spot") });
    try config.put(allocator, "labels", try valueToJson(allocator, try requiredValue(node.inputs, "labels")));
    try pool.put(allocator, "config", .{ .object = config });
    try pool.put(allocator, "autoscaling", try autoscalingJson(allocator, node));
    var management: std.json.ObjectMap = .empty;
    try management.put(allocator, "autoRepair", .{ .bool = try requiredBoolean(node.inputs, "auto_repair") });
    try management.put(allocator, "autoUpgrade", .{ .bool = try requiredBoolean(node.inputs, "auto_upgrade") });
    try pool.put(allocator, "management", .{ .object = management });
    return .{ .object = pool };
}

fn fleetJson(_: *provider_mod.OperationContext, node: resource.ResourceNode, allocator: std.mem.Allocator, root: *std.json.ObjectMap) ProviderError!void {
    const physical = try physicalIdAlloc(allocator, node, .fleet);
    try root.put(allocator, "name", .{ .string = physical });
    try root.put(allocator, "displayName", .{ .string = try requiredString(node.inputs, "display_name") });
    try root.put(allocator, "labels", try valueToJson(allocator, try requiredValue(node.inputs, "labels")));
}

fn membershipJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, allocator: std.mem.Allocator, root: *std.json.ObjectMap) ProviderError!void {
    const physical = try physicalIdAlloc(allocator, node, .membership);
    try root.put(allocator, "name", .{ .string = physical });
    try root.put(allocator, "description", .{ .string = try requiredString(node.inputs, "description") });
    try root.put(allocator, "labels", try valueToJson(allocator, try requiredValue(node.inputs, "labels")));
    var gke: std.json.ObjectMap = .empty;
    try gke.put(allocator, "resourceLink", .{ .string = try resolveString(context, try requiredValue(node.inputs, "cluster")) });
    var endpoint: std.json.ObjectMap = .empty;
    try endpoint.put(allocator, "gkeCluster", .{ .object = gke });
    try root.put(allocator, "endpoint", .{ .object = endpoint });
}

fn functionJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, allocator: std.mem.Allocator, root: *std.json.ObjectMap) ProviderError!void {
    const physical = try physicalIdAlloc(allocator, node, .function_v2);
    try root.put(allocator, "name", .{ .string = physical });
    try root.put(allocator, "labels", try valueToJson(allocator, try requiredValue(node.inputs, "labels")));
    const kms = try resolveString(context, try requiredValue(node.inputs, "kms_key"));
    if (kms.len > 0) try root.put(allocator, "kmsKeyName", .{ .string = kms });
    var source: std.json.ObjectMap = .empty;
    var storage: std.json.ObjectMap = .empty;
    try storage.put(allocator, "bucket", .{ .string = try requiredString(node.inputs, "source_bucket") });
    try storage.put(allocator, "object", .{ .string = try requiredString(node.inputs, "source_object") });
    const generation = try requiredInteger(node.inputs, "source_generation");
    if (generation > 0) try storage.put(allocator, "generation", .{ .string = try std.fmt.allocPrint(allocator, "{d}", .{generation}) });
    try source.put(allocator, "storageSource", .{ .object = storage });
    var build: std.json.ObjectMap = .empty;
    try build.put(allocator, "runtime", .{ .string = try requiredString(node.inputs, "runtime") });
    try build.put(allocator, "entryPoint", .{ .string = try requiredString(node.inputs, "entry_point") });
    try build.put(allocator, "serviceAccount", .{ .string = try resolveString(context, try requiredValue(node.inputs, "build_service_account")) });
    try build.put(allocator, "source", .{ .object = source });
    try root.put(allocator, "buildConfig", .{ .object = build });
    var service: std.json.ObjectMap = .empty;
    try service.put(allocator, "serviceAccountEmail", .{ .string = try resolveString(context, try requiredValue(node.inputs, "service_account")) });
    try service.put(allocator, "availableMemory", .{ .string = try requiredString(node.inputs, "available_memory") });
    try service.put(allocator, "availableCpu", .{ .string = try requiredString(node.inputs, "available_cpu") });
    try service.put(allocator, "timeoutSeconds", .{ .integer = try requiredInteger(node.inputs, "timeout_seconds") });
    try service.put(allocator, "minInstanceCount", .{ .integer = try requiredInteger(node.inputs, "min_instances") });
    try service.put(allocator, "maxInstanceCount", .{ .integer = try requiredInteger(node.inputs, "max_instances") });
    try service.put(allocator, "maxInstanceRequestConcurrency", .{ .integer = try requiredInteger(node.inputs, "max_concurrency") });
    try service.put(allocator, "ingressSettings", .{ .string = try requiredString(node.inputs, "ingress") });
    try service.put(allocator, "environmentVariables", try valueToJson(allocator, try requiredValue(node.inputs, "environment")));
    try service.put(allocator, "secretEnvironmentVariables", try functionSecretEnvJson(allocator, try requiredList(node.inputs, "secret_environment")));
    const connector = try resolveString(context, try requiredValue(node.inputs, "vpc_connector"));
    if (connector.len > 0) {
        try service.put(allocator, "vpcConnector", .{ .string = connector });
        try service.put(allocator, "vpcConnectorEgressSettings", .{ .string = try requiredString(node.inputs, "vpc_egress") });
    }
    try root.put(allocator, "serviceConfig", .{ .object = service });
    if (std.mem.eql(u8, try requiredString(node.inputs, "trigger_kind"), "EVENTARC")) {
        var trigger: std.json.ObjectMap = .empty;
        try trigger.put(allocator, "eventType", .{ .string = try requiredString(node.inputs, "event_type") });
        try trigger.put(allocator, "triggerRegion", .{ .string = try requiredString(node.inputs, "trigger_region") });
        try trigger.put(allocator, "eventFilters", try valueToJson(allocator, try requiredValue(node.inputs, "event_filters")));
        try trigger.put(allocator, "serviceAccountEmail", .{ .string = try resolveString(context, try requiredValue(node.inputs, "trigger_service_account")) });
        try trigger.put(allocator, "retryPolicy", .{ .string = if (try requiredBoolean(node.inputs, "retry")) "RETRY_POLICY_RETRY" else "RETRY_POLICY_DO_NOT_RETRY" });
        const topic = try resolveString(context, try requiredValue(node.inputs, "pubsub_topic"));
        if (topic.len > 0) try trigger.put(allocator, "pubsubTopic", .{ .string = topic });
        try root.put(allocator, "eventTrigger", .{ .object = trigger });
    }
}

fn batchJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, allocator: std.mem.Allocator, root: *std.json.ObjectMap) ProviderError!void {
    try root.put(allocator, "labels", try valueToJson(allocator, try requiredValue(node.inputs, "labels")));
    try root.put(allocator, "priority", .{ .integer = try requiredInteger(node.inputs, "priority") });
    var container: std.json.ObjectMap = .empty;
    try container.put(allocator, "imageUri", .{ .string = try requiredString(node.inputs, "image") });
    try container.put(allocator, "commands", try valueToJson(allocator, try requiredValue(node.inputs, "commands")));
    var runnable: std.json.ObjectMap = .empty;
    try runnable.put(allocator, "container", .{ .object = container });
    var runnables = std.json.Array.init(allocator);
    try runnables.append(.{ .object = runnable });
    var environment: std.json.ObjectMap = .empty;
    try environment.put(allocator, "variables", try valueToJson(allocator, try requiredValue(node.inputs, "environment")));
    try environment.put(allocator, "secretVariables", try valueToJson(allocator, try requiredValue(node.inputs, "secret_environment")));
    var task: std.json.ObjectMap = .empty;
    try task.put(allocator, "runnables", .{ .array = runnables });
    try task.put(allocator, "environment", .{ .object = environment });
    try task.put(allocator, "maxRetryCount", .{ .integer = try requiredInteger(node.inputs, "max_retry_count") });
    try task.put(allocator, "maxRunDuration", .{ .string = try std.fmt.allocPrint(allocator, "{d}s", .{try requiredInteger(node.inputs, "max_run_seconds")}) });
    var group: std.json.ObjectMap = .empty;
    try group.put(allocator, "taskCount", .{ .integer = try requiredInteger(node.inputs, "task_count") });
    try group.put(allocator, "parallelism", .{ .integer = try requiredInteger(node.inputs, "parallelism") });
    try group.put(allocator, "taskSpec", .{ .object = task });
    var groups = std.json.Array.init(allocator);
    try groups.append(.{ .object = group });
    try root.put(allocator, "taskGroups", .{ .array = groups });
    var policy: std.json.ObjectMap = .empty;
    try policy.put(allocator, "machineType", .{ .string = try requiredString(node.inputs, "machine_type") });
    try policy.put(allocator, "provisioningModel", .{ .string = try requiredString(node.inputs, "provisioning_model") });
    var instance: std.json.ObjectMap = .empty;
    try instance.put(allocator, "policy", .{ .object = policy });
    var instances = std.json.Array.init(allocator);
    try instances.append(.{ .object = instance });
    var allocation: std.json.ObjectMap = .empty;
    try allocation.put(allocator, "instances", .{ .array = instances });
    var account: std.json.ObjectMap = .empty;
    try account.put(allocator, "email", .{ .string = try resolveString(context, try requiredValue(node.inputs, "service_account")) });
    try allocation.put(allocator, "serviceAccount", .{ .object = account });
    const network = try resolveString(context, try requiredValue(node.inputs, "network"));
    const subnetwork = try resolveString(context, try requiredValue(node.inputs, "subnetwork"));
    if (network.len > 0 or subnetwork.len > 0) {
        var interface: std.json.ObjectMap = .empty;
        if (network.len > 0) try interface.put(allocator, "network", .{ .string = network });
        if (subnetwork.len > 0) try interface.put(allocator, "subnetwork", .{ .string = subnetwork });
        var interfaces = std.json.Array.init(allocator);
        try interfaces.append(.{ .object = interface });
        var network_policy: std.json.ObjectMap = .empty;
        try network_policy.put(allocator, "networkInterfaces", .{ .array = interfaces });
        try allocation.put(allocator, "network", .{ .object = network_policy });
    }
    try root.put(allocator, "allocationPolicy", .{ .object = allocation });
    var logs: std.json.ObjectMap = .empty;
    try logs.put(allocator, "destination", .{ .string = try requiredString(node.inputs, "logs") });
    try root.put(allocator, "logsPolicy", .{ .object = logs });
}

fn clusterUpdateBodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var update: std.json.ObjectMap = .empty;
    var release: std.json.ObjectMap = .empty;
    try release.put(arena, "channel", .{ .string = try requiredString(node.inputs, "release_channel") });
    try update.put(arena, "desiredReleaseChannel", .{ .object = release });
    var identity: std.json.ObjectMap = .empty;
    try identity.put(arena, "workloadPool", .{ .string = try requiredString(node.inputs, "workload_pool") });
    try update.put(arena, "desiredWorkloadIdentityConfig", .{ .object = identity });
    try update.put(arena, "desiredMasterAuthorizedNetworksConfig", try authorizedNetworksJson(arena, try requiredList(node.inputs, "authorized_networks")));
    var binary: std.json.ObjectMap = .empty;
    try binary.put(arena, "evaluationMode", .{ .string = try requiredString(node.inputs, "binary_authorization") });
    try update.put(arena, "desiredBinaryAuthorization", .{ .object = binary });
    try update.put(arena, "desiredLoggingConfig", try componentConfigJson(arena, try requiredList(node.inputs, "logging_components")));
    try update.put(arena, "desiredMonitoringConfig", try componentConfigJson(arena, try requiredList(node.inputs, "monitoring_components")));
    var root: std.json.ObjectMap = .empty;
    const physical = try physicalIdAlloc(arena, node, .cluster);
    try root.put(arena, "name", .{ .string = physical });
    try root.put(arena, "update", .{ .object = update });
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch return error.OutOfMemory;
}

fn clusterLabelsBodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, fingerprint: []const u8) ProviderError![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root: std.json.ObjectMap = .empty;
    const physical = try physicalIdAlloc(arena, node, .cluster);
    try root.put(arena, "name", .{ .string = physical });
    try root.put(arena, "resourceLabels", try valueToJson(arena, try requiredValue(node.inputs, "labels")));
    try root.put(arena, "labelFingerprint", .{ .string = fingerprint });
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch return error.OutOfMemory;
}

fn nodePoolAutoscalingBodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root: std.json.ObjectMap = .empty;
    const physical = try physicalIdAlloc(arena, node, .node_pool);
    try root.put(arena, "name", .{ .string = physical });
    try root.put(arena, "autoscaling", try autoscalingJson(arena, node));
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch return error.OutOfMemory;
}

fn nodePoolUpdateBodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root: std.json.ObjectMap = .empty;
    const physical = try physicalIdAlloc(arena, node, .node_pool);
    try root.put(arena, "name", .{ .string = physical });
    try root.put(arena, "machineType", .{ .string = try requiredString(node.inputs, "machine_type") });
    try root.put(arena, "diskType", .{ .string = try requiredString(node.inputs, "disk_type") });
    try root.put(arena, "diskSizeGb", .{ .integer = try requiredInteger(node.inputs, "disk_size_gb") });
    try root.put(arena, "imageType", .{ .string = try requiredString(node.inputs, "image_type") });
    try root.put(arena, "locations", try valueToJson(arena, try requiredValue(node.inputs, "locations")));
    try root.put(arena, "labels", try valueToJson(arena, try requiredValue(node.inputs, "labels")));
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch return error.OutOfMemory;
}

fn autoscalingJson(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError!std.json.Value {
    var autoscaling: std.json.ObjectMap = .empty;
    try autoscaling.put(allocator, "enabled", .{ .bool = try requiredBoolean(node.inputs, "autoscaling_enabled") });
    try autoscaling.put(allocator, "minNodeCount", .{ .integer = try requiredInteger(node.inputs, "min_nodes") });
    try autoscaling.put(allocator, "maxNodeCount", .{ .integer = try requiredInteger(node.inputs, "max_nodes") });
    const total_min = try requiredInteger(node.inputs, "total_min_nodes");
    const total_max = try requiredInteger(node.inputs, "total_max_nodes");
    if (total_min > 0) try autoscaling.put(allocator, "totalMinNodeCount", .{ .integer = total_min });
    if (total_max > 0) try autoscaling.put(allocator, "totalMaxNodeCount", .{ .integer = total_max });
    return .{ .object = autoscaling };
}

fn authorizedNetworksJson(allocator: std.mem.Allocator, networks: []const value.Value) ProviderError!std.json.Value {
    var cidrs = std.json.Array.init(allocator);
    for (networks) |network| {
        const object = try requiredObject(network);
        var entry: std.json.ObjectMap = .empty;
        try entry.put(allocator, "displayName", .{ .string = try requiredObjectString(object, "name") });
        try entry.put(allocator, "cidrBlock", .{ .string = try requiredObjectString(object, "cidr") });
        try cidrs.append(.{ .object = entry });
    }
    var root: std.json.ObjectMap = .empty;
    try root.put(allocator, "enabled", .{ .bool = networks.len > 0 });
    try root.put(allocator, "cidrBlocks", .{ .array = cidrs });
    return .{ .object = root };
}

fn componentConfigJson(allocator: std.mem.Allocator, components: []const value.Value) ProviderError!std.json.Value {
    var component: std.json.ObjectMap = .empty;
    try component.put(allocator, "enableComponents", try valueToJson(allocator, .{ .list = components }));
    var root: std.json.ObjectMap = .empty;
    try root.put(allocator, "componentConfig", .{ .object = component });
    return .{ .object = root };
}

fn functionSecretEnvJson(allocator: std.mem.Allocator, secrets: []const value.Value) ProviderError!std.json.Value {
    var result = std.json.Array.init(allocator);
    for (secrets) |secret| {
        const object = try requiredObject(secret);
        var encoded: std.json.ObjectMap = .empty;
        try encoded.put(allocator, "key", .{ .string = try requiredObjectString(object, "key") });
        try encoded.put(allocator, "projectId", .{ .string = try requiredObjectString(object, "project_id") });
        try encoded.put(allocator, "secret", .{ .string = try requiredObjectString(object, "secret") });
        try encoded.put(allocator, "version", .{ .string = try requiredObjectString(object, "version") });
        try result.append(.{ .object = encoded });
    }
    return .{ .array = result };
}

fn createPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    const project = try requiredString(node.inputs, "project_id");
    const name = try requiredString(node.inputs, "name");
    return switch (kind) {
        .cluster => std.fmt.allocPrint(allocator, "/v1/projects/{s}/locations/{s}/clusters", .{ project, try requiredString(node.inputs, "location") }),
        .node_pool => std.fmt.allocPrint(allocator, "/v1/projects/{s}/locations/{s}/clusters/{s}/nodePools", .{ project, try requiredString(node.inputs, "location"), try requiredString(node.inputs, "cluster_name") }),
        .fleet => std.fmt.allocPrint(allocator, "/v1/projects/{s}/locations/global/fleets?fleetId={s}", .{ project, name }),
        .membership => std.fmt.allocPrint(allocator, "/v1/projects/{s}/locations/{s}/memberships?membershipId={s}", .{ project, try requiredString(node.inputs, "location"), name }),
        .function_v2 => std.fmt.allocPrint(allocator, "/v2/projects/{s}/locations/{s}/functions?functionId={s}", .{ project, try requiredString(node.inputs, "location"), name }),
        .batch_job => std.fmt.allocPrint(allocator, "/v1/projects/{s}/locations/{s}/jobs?jobId={s}", .{ project, try requiredString(node.inputs, "location"), name }),
        .function_iam_member => error.InvalidConfiguration,
    };
}

fn readPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    const physical = try physicalIdAlloc(allocator, node, kind);
    defer allocator.free(physical);
    return std.fmt.allocPrint(allocator, "/{s}/{s}", .{ if (kind == .function_v2 or kind == .function_iam_member) "v2" else "v1", physical });
}

fn updatePathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    const base = try readPathAlloc(allocator, node, kind);
    defer allocator.free(base);
    const mask = switch (kind) {
        .fleet => "displayName%2Clabels",
        .membership => "description%2Clabels%2Cendpoint",
        .function_v2 => "buildConfig%2CserviceConfig%2CeventTrigger%2Clabels%2CkmsKeyName",
        else => return error.InvalidConfiguration,
    };
    return std.fmt.allocPrint(allocator, "{s}?updateMask={s}", .{ base, mask });
}

fn physicalIdAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    const project = try requiredString(node.inputs, "project_id");
    const name = try requiredString(node.inputs, if (kind == .function_iam_member) "function_name" else "name");
    return switch (kind) {
        .cluster => std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}/clusters/{s}", .{ project, try requiredString(node.inputs, "location"), name }),
        .node_pool => std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}/clusters/{s}/nodePools/{s}", .{ project, try requiredString(node.inputs, "location"), try requiredString(node.inputs, "cluster_name"), name }),
        .fleet => std.fmt.allocPrint(allocator, "projects/{s}/locations/global/fleets/{s}", .{ project, name }),
        .membership => std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}/memberships/{s}", .{ project, try requiredString(node.inputs, "location"), name }),
        .function_v2 => std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}/functions/{s}", .{ project, try requiredString(node.inputs, "location"), name }),
        .function_iam_member => std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}/functions/{s}#iam/{s}/{s}", .{ project, try requiredString(node.inputs, "location"), name, try requiredString(node.inputs, "role"), try requiredString(node.inputs, "member") }),
        .batch_job => std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}/jobs/{s}", .{ project, try requiredString(node.inputs, "location"), name }),
    };
}

fn functionIamPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, action: []const u8) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "/v2/projects/{s}/locations/{s}/functions/{s}:{s}", .{ try requiredString(node.inputs, "project_id"), try requiredString(node.inputs, "location"), try requiredString(node.inputs, "function_name"), action });
}

fn validatePhysical(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind, candidate: []const u8) ProviderError!void {
    const expected = try physicalIdAlloc(allocator, node, kind);
    defer allocator.free(expected);
    if (!std.mem.eql(u8, expected, candidate)) return error.InvalidConfiguration;
}

fn resultFromJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, body: []const u8) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const remote = jsonObject(parsed.value) orelse return error.ProviderBug;
    const physical = try physicalIdAlloc(context.allocator, node, kind);
    defer context.allocator.free(physical);
    var observed = node.inputs.clone(context.allocator) catch |err| switch (err) {
        error.DuplicateField => return error.ProviderBug,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer observed.deinit(context.allocator);
    var outputs: [8]state.StateOutput = undefined;
    var count: usize = 0;
    switch (kind) {
        .cluster => {
            try normalizeCluster(context, &observed, remote);
            outputs[count] = .{ .name = "name", .value = .{ .string = physical } };
            count += 1;
            outputs[count] = .{ .name = "endpoint", .value = .{ .string = jsonString(remote.get("endpoint")) orelse "" } };
            count += 1;
            outputs[count] = .{ .name = "status", .value = .{ .string = jsonString(remote.get("status")) orelse "UNKNOWN" } };
            count += 1;
            const identity = jsonObject(remote.get("workloadIdentityConfig") orelse .{ .object = .empty });
            outputs[count] = .{ .name = "workload_pool", .value = .{ .string = if (identity) |present| jsonString(present.get("workloadPool")) orelse "" else "" } };
            count += 1;
            outputs[count] = .{ .name = "label_fingerprint", .value = .{ .string = jsonString(remote.get("labelFingerprint")) orelse "" } };
            count += 1;
        },
        .node_pool => {
            try normalizeNodePool(context, &observed, remote);
            outputs[count] = .{ .name = "name", .value = .{ .string = physical } };
            count += 1;
            outputs[count] = .{ .name = "status", .value = .{ .string = jsonString(remote.get("status")) orelse "UNKNOWN" } };
            count += 1;
        },
        .fleet => {
            try replaceString(context.allocator, &observed, "display_name", jsonString(remote.get("displayName")) orelse "");
            try replaceJsonField(context.allocator, &observed, "labels", remote.get("labels") orelse .{ .object = .empty });
            addGenericOutputs(&outputs, &count, physical, remote);
        },
        .membership => {
            try normalizeMembership(context, &observed, remote);
            addGenericOutputs(&outputs, &count, physical, remote);
            outputs[count] = .{ .name = "unique_id", .value = .{ .string = jsonString(remote.get("uniqueId")) orelse "" } };
            count += 1;
        },
        .function_v2 => {
            try normalizeFunction(context, &observed, remote);
            outputs[count] = .{ .name = "name", .value = .{ .string = physical } };
            count += 1;
            outputs[count] = .{ .name = "url", .value = .{ .string = jsonString(remote.get("url")) orelse "" } };
            count += 1;
            outputs[count] = .{ .name = "state", .value = .{ .string = jsonString(remote.get("state")) orelse "UNKNOWN" } };
            count += 1;
            const service = jsonObject(remote.get("serviceConfig") orelse .{ .object = .empty });
            outputs[count] = .{ .name = "service", .value = .{ .string = if (service) |present| jsonString(present.get("service")) orelse "" else "" } };
            count += 1;
        },
        .batch_job => {
            outputs[count] = .{ .name = "name", .value = .{ .string = jsonString(remote.get("name")) orelse physical } };
            count += 1;
            outputs[count] = .{ .name = "uid", .value = .{ .string = jsonString(remote.get("uid")) orelse "" } };
            count += 1;
            const status = jsonObject(remote.get("status") orelse .{ .object = .empty });
            outputs[count] = .{ .name = "state", .value = .{ .string = if (status) |present| jsonString(present.get("state")) orelse "UNKNOWN" else "UNKNOWN" } };
            count += 1;
        },
        .function_iam_member => return error.InvalidConfiguration,
    }
    return provider_mod.ResourceResult.init(context.allocator, physical, observed, outputs[0..count], null);
}

fn normalizeCluster(context: *provider_mod.OperationContext, observed: *value.Value, remote: std.json.ObjectMap) ProviderError!void {
    try replaceResolvedString(context, observed, "network", jsonString(remote.get("network")) orelse return error.ProviderBug);
    try replaceResolvedString(context, observed, "subnetwork", jsonString(remote.get("subnetwork")) orelse return error.ProviderBug);
    try replaceString(context.allocator, observed, "description", jsonString(remote.get("description")) orelse "");
    try replaceBoolean(context.allocator, observed, "deletion_protection", jsonBool(remote.get("deletionProtection")) orelse false);
    try replaceJsonField(context.allocator, observed, "labels", remote.get("resourceLabels") orelse .{ .object = .empty });
    const autopilot = jsonObject(remote.get("autopilot") orelse .{ .object = .empty });
    try replaceString(context.allocator, observed, "mode", if (autopilot != null and (jsonBool(autopilot.?.get("enabled")) orelse false)) "AUTOPILOT" else "STANDARD");
    if (jsonObject(remote.get("releaseChannel") orelse .{ .object = .empty })) |release| try replaceString(context.allocator, observed, "release_channel", jsonString(release.get("channel")) orelse "UNSPECIFIED");
    if (jsonObject(remote.get("workloadIdentityConfig") orelse .{ .object = .empty })) |identity| try replaceString(context.allocator, observed, "workload_pool", jsonString(identity.get("workloadPool")) orelse "");
    if (jsonObject(remote.get("ipAllocationPolicy") orelse .{ .object = .empty })) |ip| {
        try replaceString(context.allocator, observed, "cluster_secondary_range", jsonString(ip.get("clusterSecondaryRangeName")) orelse "");
        try replaceString(context.allocator, observed, "services_secondary_range", jsonString(ip.get("servicesSecondaryRangeName")) orelse "");
    }
    if (jsonObject(remote.get("privateClusterConfig") orelse .{ .object = .empty })) |private| {
        try replaceBoolean(context.allocator, observed, "private_nodes", jsonBool(private.get("enablePrivateNodes")) orelse false);
        try replaceBoolean(context.allocator, observed, "private_endpoint", jsonBool(private.get("enablePrivateEndpoint")) orelse false);
        try replaceString(context.allocator, observed, "master_ipv4_cidr", jsonString(private.get("masterIpv4CidrBlock")) orelse "");
    }
}

fn normalizeNodePool(context: *provider_mod.OperationContext, observed: *value.Value, remote: std.json.ObjectMap) ProviderError!void {
    try replaceInteger(context.allocator, observed, "node_count", jsonInteger(remote.get("initialNodeCount") orelse .{ .integer = 1 }) orelse 1);
    if (jsonObject(remote.get("config") orelse .{ .object = .empty })) |config| {
        try replaceString(context.allocator, observed, "machine_type", jsonString(config.get("machineType")) orelse "");
        try replaceString(context.allocator, observed, "disk_type", jsonString(config.get("diskType")) orelse "pd-balanced");
        try replaceInteger(context.allocator, observed, "disk_size_gb", jsonInteger(config.get("diskSizeGb") orelse .{ .integer = 100 }) orelse 100);
        try replaceString(context.allocator, observed, "image_type", jsonString(config.get("imageType")) orelse "COS_CONTAINERD");
        if (jsonString(config.get("serviceAccount"))) |account| try replaceResolvedString(context, observed, "service_account", account);
        try replaceBoolean(context.allocator, observed, "spot", jsonBool(config.get("spot")) orelse false);
        try replaceJsonField(context.allocator, observed, "labels", config.get("labels") orelse .{ .object = .empty });
    }
    if (jsonObject(remote.get("autoscaling") orelse .{ .object = .empty })) |scaling| {
        try replaceBoolean(context.allocator, observed, "autoscaling_enabled", jsonBool(scaling.get("enabled")) orelse false);
        try replaceInteger(context.allocator, observed, "min_nodes", jsonInteger(scaling.get("minNodeCount") orelse .{ .integer = 0 }) orelse 0);
        try replaceInteger(context.allocator, observed, "max_nodes", jsonInteger(scaling.get("maxNodeCount") orelse .{ .integer = 0 }) orelse 0);
    }
}

fn normalizeMembership(context: *provider_mod.OperationContext, observed: *value.Value, remote: std.json.ObjectMap) ProviderError!void {
    try replaceString(context.allocator, observed, "description", jsonString(remote.get("description")) orelse "");
    try replaceJsonField(context.allocator, observed, "labels", remote.get("labels") orelse .{ .object = .empty });
    const endpoint = jsonObject(remote.get("endpoint") orelse return error.ProviderBug) orelse return error.ProviderBug;
    const gke = jsonObject(endpoint.get("gkeCluster") orelse return error.ProviderBug) orelse return error.ProviderBug;
    try replaceResolvedString(context, observed, "cluster", jsonString(gke.get("resourceLink")) orelse return error.ProviderBug);
}

fn normalizeFunction(context: *provider_mod.OperationContext, observed: *value.Value, remote: std.json.ObjectMap) ProviderError!void {
    try replaceJsonField(context.allocator, observed, "labels", remote.get("labels") orelse .{ .object = .empty });
    const build = jsonObject(remote.get("buildConfig") orelse return error.ProviderBug) orelse return error.ProviderBug;
    try replaceString(context.allocator, observed, "runtime", jsonString(build.get("runtime")) orelse return error.ProviderBug);
    try replaceString(context.allocator, observed, "entry_point", jsonString(build.get("entryPoint")) orelse return error.ProviderBug);
    if (jsonString(build.get("serviceAccount"))) |account| try replaceResolvedString(context, observed, "build_service_account", account);
    const service = jsonObject(remote.get("serviceConfig") orelse return error.ProviderBug) orelse return error.ProviderBug;
    if (jsonString(service.get("serviceAccountEmail"))) |account| try replaceResolvedString(context, observed, "service_account", account);
    try replaceString(context.allocator, observed, "available_memory", jsonString(service.get("availableMemory")) orelse "256Mi");
    try replaceString(context.allocator, observed, "available_cpu", jsonString(service.get("availableCpu")) orelse "1");
    try replaceInteger(context.allocator, observed, "timeout_seconds", jsonInteger(service.get("timeoutSeconds") orelse .{ .integer = 60 }) orelse 60);
    try replaceInteger(context.allocator, observed, "min_instances", jsonInteger(service.get("minInstanceCount") orelse .{ .integer = 0 }) orelse 0);
    try replaceInteger(context.allocator, observed, "max_instances", jsonInteger(service.get("maxInstanceCount") orelse .{ .integer = 100 }) orelse 100);
    try replaceInteger(context.allocator, observed, "max_concurrency", jsonInteger(service.get("maxInstanceRequestConcurrency") orelse .{ .integer = 1 }) orelse 1);
    try replaceString(context.allocator, observed, "ingress", jsonString(service.get("ingressSettings")) orelse "ALLOW_ALL");
    try replaceJsonField(context.allocator, observed, "environment", service.get("environmentVariables") orelse .{ .object = .empty });
}

fn addGenericOutputs(outputs: *[8]state.StateOutput, count: *usize, physical: []const u8, remote: std.json.ObjectMap) void {
    outputs[count.*] = .{ .name = "name", .value = .{ .string = physical } };
    count.* += 1;
    const state_object = jsonObject(remote.get("state") orelse .{ .object = .empty });
    outputs[count.*] = .{ .name = "state", .value = .{ .string = if (state_object) |present| jsonString(present.get("code")) orelse "UNKNOWN" else "UNKNOWN" } };
    count.* += 1;
    outputs[count.*] = .{ .name = "uid", .value = .{ .string = jsonString(remote.get("uid")) orelse "" } };
    count.* += 1;
}

fn pendingResult(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind, handle: []const u8) ProviderError!provider_mod.ResourceResult {
    const physical = try physicalIdAlloc(allocator, node, kind);
    defer allocator.free(physical);
    var result = try provider_mod.ResourceResult.init(allocator, physical, node.inputs, &.{}, handle);
    result.completed = false;
    return result;
}

fn iamResult(context: *provider_mod.OperationContext, node: resource.ResourceNode, etag: []const u8) ProviderError!provider_mod.ResourceResult {
    const physical = try physicalIdAlloc(context.allocator, node, .function_iam_member);
    defer context.allocator.free(physical);
    const outputs = [_]state.StateOutput{.{ .name = "etag", .value = .{ .string = etag } }};
    return provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &outputs, null);
}

fn operationNameAlloc(allocator: std.mem.Allocator, body: []const u8) ProviderError![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    return allocator.dupe(u8, jsonString(root.get("name")) orelse return error.ProviderBug) catch return error.OutOfMemory;
}

fn mutatePolicy(allocator: std.mem.Allocator, policy_value: *std.json.Value, role: []const u8, member: []const u8, should_exist: bool) ProviderError!bool {
    const policy = switch (policy_value.*) {
        .object => |*object| object,
        else => return error.ProviderBug,
    };
    const current = if (policy.get("bindings")) |present| jsonArray(present) orelse return error.ProviderBug else std.json.Array.init(allocator);
    var next = std.json.Array.init(allocator);
    var found_role = false;
    var changed = false;
    for (current.items) |binding_value| {
        const binding = jsonObject(binding_value) orelse return error.ProviderBug;
        const binding_role = jsonString(binding.get("role")) orelse return error.ProviderBug;
        if (!std.mem.eql(u8, binding_role, role)) {
            try next.append(binding_value);
            continue;
        }
        found_role = true;
        const members = jsonArray(binding.get("members")) orelse return error.ProviderBug;
        var next_members = std.json.Array.init(allocator);
        var found_member = false;
        for (members.items) |entry| {
            const text = jsonString(entry) orelse return error.ProviderBug;
            if (std.mem.eql(u8, text, member)) {
                found_member = true;
                if (!should_exist) {
                    changed = true;
                    continue;
                }
            }
            try next_members.append(entry);
        }
        if (should_exist and !found_member) {
            try next_members.append(.{ .string = member });
            changed = true;
        }
        if (next_members.items.len > 0) {
            var replacement: std.json.ObjectMap = .empty;
            try replacement.put(allocator, "role", .{ .string = role });
            try replacement.put(allocator, "members", .{ .array = next_members });
            try next.append(.{ .object = replacement });
        }
    }
    if (should_exist and !found_role) {
        var members = std.json.Array.init(allocator);
        try members.append(.{ .string = member });
        var binding: std.json.ObjectMap = .empty;
        try binding.put(allocator, "role", .{ .string = role });
        try binding.put(allocator, "members", .{ .array = members });
        try next.append(.{ .object = binding });
        changed = true;
    }
    try policy.put(allocator, "bindings", .{ .array = next });
    return changed;
}

fn policyHasMember(policy: std.json.ObjectMap, role: []const u8, member: []const u8) bool {
    const bindings = jsonArray(policy.get("bindings")) orelse return false;
    for (bindings.items) |entry| {
        const binding = jsonObject(entry) orelse continue;
        if (!std.mem.eql(u8, jsonString(binding.get("role")) orelse continue, role)) continue;
        const members = jsonArray(binding.get("members")) orelse continue;
        for (members.items) |candidate| if (std.mem.eql(u8, jsonString(candidate) orelse continue, member)) return true;
    }
    return false;
}

fn identityChanged(desired: value.Value, observed: value.Value, fields: []const []const u8) bool {
    for (fields) |field| if (!fieldEqual(desired, observed, field)) return true;
    return false;
}

fn fieldEqual(left: value.Value, right: value.Value, name: []const u8) bool {
    const left_field = findField(left, name) orelse return false;
    const right_field = findField(right, name) orelse return false;
    return valueEqual(left_field, right_field);
}

fn valueEqual(left: value.Value, right: value.Value) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .string => |text| std.mem.eql(u8, text, right.string),
        .integer => |number| number == right.integer,
        .boolean => |flag| flag == right.boolean,
        .output_ref => |reference| std.mem.eql(u8, reference.resource_id, right.output_ref.resource_id) and std.mem.eql(u8, reference.field, right.output_ref.field),
        .secret_ref => |reference| std.mem.eql(u8, reference.provider, right.secret_ref.provider) and
            std.mem.eql(u8, reference.resource, right.secret_ref.resource) and
            optionalStringEqual(reference.version, right.secret_ref.version) and
            optionalStringEqual(reference.field, right.secret_ref.field),
        .list => |items| blk: {
            if (items.len != right.list.len) break :blk false;
            for (items, right.list) |a, b| if (!valueEqual(a, b)) break :blk false;
            break :blk true;
        },
        .object => |fields| blk: {
            if (fields.len != right.object.len) break :blk false;
            for (fields) |field| if (!fieldEqual(.{ .object = fields }, right, field.name)) break :blk false;
            break :blk true;
        },
        .unknown_reason => |reason| std.mem.eql(u8, reason, right.unknown_reason),
    };
}

fn optionalStringEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn findField(object: value.Value, name: []const u8) ?value.Value {
    if (object != .object) return null;
    for (object.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return null;
}

fn requiredValue(object: value.Value, name: []const u8) ProviderError!value.Value {
    return findField(object, name) orelse error.InvalidConfiguration;
}

fn requiredString(object: value.Value, name: []const u8) ProviderError![]const u8 {
    return switch (try requiredValue(object, name)) {
        .string => |text| text,
        else => error.InvalidConfiguration,
    };
}

fn requiredInteger(object: value.Value, name: []const u8) ProviderError!i64 {
    return switch (try requiredValue(object, name)) {
        .integer => |number| number,
        else => error.InvalidConfiguration,
    };
}

fn requiredBoolean(object: value.Value, name: []const u8) ProviderError!bool {
    return switch (try requiredValue(object, name)) {
        .boolean => |flag| flag,
        else => error.InvalidConfiguration,
    };
}

fn requiredList(object: value.Value, name: []const u8) ProviderError![]const value.Value {
    return switch (try requiredValue(object, name)) {
        .list => |items| items,
        else => error.InvalidConfiguration,
    };
}

fn requiredObject(item: value.Value) ProviderError![]const value.Field {
    return switch (item) {
        .object => |fields| fields,
        else => error.InvalidConfiguration,
    };
}

fn requiredObjectString(fields: []const value.Field, name: []const u8) ProviderError![]const u8 {
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return switch (field.value) {
        .string => |text| text,
        else => error.InvalidConfiguration,
    };
    return error.InvalidConfiguration;
}

fn resolveString(context: *provider_mod.OperationContext, item: value.Value) ProviderError![]const u8 {
    return switch (item) {
        .string => |text| text,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}

fn outputString(result: *const provider_mod.ResourceResult, name: []const u8) ?[]const u8 {
    for (result.outputs) |entry| if (std.mem.eql(u8, entry.name, name)) return switch (entry.value) {
        .string => |text| text,
        else => null,
    };
    return null;
}

fn valueToJson(allocator: std.mem.Allocator, item: value.Value) ProviderError!std.json.Value {
    return switch (item) {
        .string => |text| .{ .string = text },
        .integer => |number| .{ .integer = number },
        .boolean => |flag| .{ .bool = flag },
        .list => |items| blk: {
            var array = std.json.Array.init(allocator);
            for (items) |entry| try array.append(try valueToJson(allocator, entry));
            break :blk .{ .array = array };
        },
        .object => |fields| blk: {
            var object: std.json.ObjectMap = .empty;
            for (fields) |field| try object.put(allocator, field.name, try valueToJson(allocator, field.value));
            break :blk .{ .object = object };
        },
        else => error.InvalidConfiguration,
    };
}

fn replaceString(allocator: std.mem.Allocator, object: *value.Value, name: []const u8, replacement: []const u8) ProviderError!void {
    return replaceField(allocator, object, name, .{ .string = replacement });
}

fn replaceInteger(allocator: std.mem.Allocator, object: *value.Value, name: []const u8, replacement: i64) ProviderError!void {
    return replaceField(allocator, object, name, .{ .integer = replacement });
}

fn replaceBoolean(allocator: std.mem.Allocator, object: *value.Value, name: []const u8, replacement: bool) ProviderError!void {
    return replaceField(allocator, object, name, .{ .boolean = replacement });
}

fn replaceJsonField(allocator: std.mem.Allocator, object: *value.Value, name: []const u8, replacement: std.json.Value) ProviderError!void {
    var converted = try jsonToValueAlloc(allocator, replacement);
    errdefer converted.deinit(allocator);
    if (object.* != .object) return error.ProviderBug;
    const fields: []value.Field = @constCast(object.object);
    for (fields) |*field| {
        if (!std.mem.eql(u8, field.name, name)) continue;
        field.value.deinit(allocator);
        field.value = converted;
        return;
    }
    return error.ProviderBug;
}

fn replaceResolvedString(context: *provider_mod.OperationContext, object: *value.Value, name: []const u8, remote: []const u8) ProviderError!void {
    const current = findField(object.*, name) orelse return error.ProviderBug;
    if (current == .output_ref) {
        const resolved = try context.resolveOutputString(current.output_ref);
        if (std.mem.eql(u8, resolved, remote)) return;
    }
    return replaceString(context.allocator, object, name, remote);
}

fn replaceField(allocator: std.mem.Allocator, object: *value.Value, name: []const u8, replacement: value.Value) ProviderError!void {
    if (object.* != .object) return error.ProviderBug;
    const fields: []value.Field = @constCast(object.object);
    for (fields) |*field| {
        if (!std.mem.eql(u8, field.name, name)) continue;
        field.value.deinit(allocator);
        field.value = value.Value.initOwned(allocator, replacement) catch |err| switch (err) {
            error.DuplicateField => return error.ProviderBug,
            error.OutOfMemory => return error.OutOfMemory,
        };
        return;
    }
    return error.ProviderBug;
}

fn jsonToValueAlloc(allocator: std.mem.Allocator, json: std.json.Value) ProviderError!value.Value {
    return switch (json) {
        .string => |text| ownValueAlloc(allocator, .{ .string = text }),
        .integer => |number| ownValueAlloc(allocator, .{ .integer = number }),
        .bool => |flag| ownValueAlloc(allocator, .{ .boolean = flag }),
        .array => |array| blk: {
            const items = try allocator.alloc(value.Value, array.items.len);
            defer allocator.free(items);
            for (array.items, 0..) |entry, index| {
                items[index] = try jsonToValueAlloc(allocator, entry);
            }
            defer for (items) |*item| item.deinit(allocator);
            break :blk ownValueAlloc(allocator, .{ .list = items });
        },
        .object => |object| blk: {
            const fields = try allocator.alloc(value.Field, object.count());
            defer allocator.free(fields);
            var iterator = object.iterator();
            var index: usize = 0;
            while (iterator.next()) |entry| : (index += 1) fields[index] = .{ .name = entry.key_ptr.*, .value = try jsonToValueAlloc(allocator, entry.value_ptr.*) };
            defer for (fields) |*field| field.value.deinit(allocator);
            break :blk ownValueAlloc(allocator, .{ .object = fields });
        },
        else => return error.ProviderBug,
    };
}

fn ownValueAlloc(allocator: std.mem.Allocator, borrowed: value.Value) ProviderError!value.Value {
    return value.Value.initOwned(allocator, borrowed) catch |err| switch (err) {
        error.DuplicateField => error.ProviderBug,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn jsonObject(item: ?std.json.Value) ?std.json.ObjectMap {
    const present = item orelse return null;
    return switch (present) {
        .object => |object| object,
        else => null,
    };
}

fn jsonArray(item: ?std.json.Value) ?std.json.Array {
    const present = item orelse return null;
    return switch (present) {
        .array => |array| array,
        else => null,
    };
}

fn jsonString(item: ?std.json.Value) ?[]const u8 {
    const present = item orelse return null;
    return switch (present) {
        .string => |text| text,
        else => null,
    };
}

fn jsonInteger(item: ?std.json.Value) ?i64 {
    const present = item orelse return null;
    return switch (present) {
        .integer => |number| number,
        else => null,
    };
}

fn jsonBool(item: ?std.json.Value) ?bool {
    const present = item orelse return null;
    return switch (present) {
        .bool => |flag| flag,
        else => null,
    };
}
