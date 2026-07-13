const std = @import("std");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const secret_mod = @import("../secret.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;
const instance_type = "gcp.redis.Instance";
const cluster_type = "gcp.redis.Cluster";
const acl_type = "gcp.redis.AclPolicy";
const Kind = enum { instance, cluster, acl };
const ResumeIntent = enum { create, update, unknown };
const ResumeCheckpoint = struct { intent: ResumeIntent, operation: []const u8 };

pub const Handler = struct {
    client: *client_mod.Client,
    operation_policy: operation.Policy = .{},
    secret_source: ?secret_mod.SecretSource = null,

    pub fn read(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
        const kind = try kindFor(node);
        const checkpoint = if (context.operation_handle) |handle| parseResumeCheckpoint(handle) else null;
        if (checkpoint) |pending| try self.waitOperation(context, pending.operation);
        const physical = if (physical_override) |provided| try canonicalPhysicalAlloc(context.allocator, node, kind, provided) else try deterministicPhysicalAlloc(context.allocator, node, kind);
        defer context.allocator.free(physical);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .redis, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        const persist_auth = kind == .instance and checkpoint != null and checkpoint.?.intent == .create and try requiredBool(node.inputs, "auth_enabled");
        const auth_reference = if (kind == .instance and try requiredBool(node.inputs, "auth_enabled"))
            if (persist_auth) try self.persistGeneratedAuth(context, node, physical) else try latestAuthReference(context, node)
        else
            null;
        defer if (persist_auth) if (auth_reference) |reference| if (reference.version) |version| context.allocator.free(version);
        return .{ .present = try resultFromJson(self, context, node, kind, response.body, auth_reference) };
    }

    pub fn diff(context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        const kind = try kindFor(node);
        if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash)) return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        const replacement = switch (kind) {
            .instance => changedAny(node.inputs, observed.observed_inputs, &.{ "project_id", "location", "instance_id", "tier", "network", "connect_mode", "kms_key_name", "reserved_ip_range", "transit_encryption" }),
            .cluster => changedAny(node.inputs, observed.observed_inputs, &.{ "project_id", "location", "cluster_id", "network", "kms_key_name" }),
            .acl => changedAny(node.inputs, observed.observed_inputs, &.{ "project_id", "location", "policy_id" }),
        };
        return provider_mod.DiffResult.init(context.allocator, if (replacement) .replace else .update, if (replacement) &.{"Memorystore immutable identity, network, tier or encryption differs"} else &.{"Memorystore mutable configuration differs"});
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        const kind = try kindFor(node);
        const path = try createPathAlloc(context.allocator, node, kind);
        defer context.allocator.free(path);
        const body = try self.bodyAlloc(context, node, kind, null);
        defer freeBody(context.allocator, body, kind == .acl);
        var response = try self.request(context, .{ .api = .redis, .method = "POST", .path = path, .body = body });
        defer response.deinit(context.allocator);
        if (kind == .acl) return resultFromJson(self, context, node, kind, response.body, null);
        const handle = try operationNameAlloc(context.allocator, response.body);
        defer context.allocator.free(handle);
        return pendingResult(context, node, kind, .create, handle);
    }

    pub fn update(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        const kind = try kindFor(node);
        if (kind == .instance and changedField(node.inputs, observed.observed_inputs, "redis_version")) {
            const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}:upgrade", .{observed.physical_id});
            defer context.allocator.free(path);
            const body = try std.fmt.allocPrint(context.allocator, "{{\"redisVersion\":\"{s}\"}}", .{try requiredString(node.inputs, "redis_version")});
            defer context.allocator.free(body);
            var response = try self.request(context, .{ .api = .redis, .method = "POST", .path = path, .body = body });
            defer response.deinit(context.allocator);
            const handle = try operationNameAlloc(context.allocator, response.body);
            defer context.allocator.free(handle);
            return pendingResult(context, node, kind, .update, handle);
        }
        const mask = try updateMaskAlloc(context.allocator, node, observed.observed_inputs, kind);
        defer context.allocator.free(mask);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}?updateMask={s}", .{ observed.physical_id, mask });
        defer context.allocator.free(path);
        const body = try self.bodyAlloc(context, node, kind, observed.physical_id);
        defer freeBody(context.allocator, body, kind == .acl);
        var response = try self.request(context, .{ .api = .redis, .method = "PATCH", .path = path, .body = body });
        defer response.deinit(context.allocator);
        if (kind == .acl) return resultFromJson(self, context, node, kind, response.body, null);
        const handle = try operationNameAlloc(context.allocator, response.body);
        defer context.allocator.free(handle);
        return pendingResult(context, node, kind, .update, handle);
    }

    pub fn delete(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!void {
        const kind = try kindFor(node);
        const physical = try canonicalPhysicalAlloc(context.allocator, node, kind, physical_id);
        defer context.allocator.free(physical);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .redis, .method = "DELETE", .path = path }) catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer response.deinit(context.allocator);
        if (kind == .acl) return;
        const handle = try operationNameAlloc(context.allocator, response.body);
        defer context.allocator.free(handle);
        try self.waitOperation(context, handle);
    }

    pub fn importResource(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!provider_mod.ResourceResult {
        const read_result = try self.read(context, node, physical_id);
        return switch (read_result) {
            .absent => error.NotFound,
            .present => |present| present,
        };
    }

    fn waitOperation(self: Handler, context: *provider_mod.OperationContext, handle: []const u8) ProviderError!void {
        const base = try std.fmt.allocPrint(context.allocator, "{s}/v1", .{std.mem.trimEnd(u8, self.client.endpoints.redis, "/")});
        defer context.allocator.free(base);
        var target = operation.Target.genericAlloc(context.allocator, base, handle) catch return error.OutOfMemory;
        defer target.deinit(context.allocator);
        var completed = try operation.waitAlloc(self.client, context, target, self.operation_policy);
        completed.deinit(context.allocator);
    }

    fn persistGeneratedAuth(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical: []const u8) ProviderError!value.SecretReference {
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}/authString", .{physical});
        defer context.allocator.free(path);
        var response = try self.request(context, .{ .api = .redis, .method = "GET", .path = path });
        defer {
            std.crypto.secureZero(u8, @constCast(response.body));
            response.deinit(context.allocator);
        }
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const auth_string = jsonString((jsonObject(parsed.value) orelse return error.ProviderBug).get("authString")) orelse return error.ProviderBug;
        defer std.crypto.secureZero(u8, @constCast(auth_string));
        const secret_resource = try resolveStringInput(context, node.inputs, "auth_secret");
        return self.persistSecretVersion(context, secret_resource, auth_string);
    }

    fn persistSecretVersion(self: Handler, context: *provider_mod.OperationContext, secret_resource: []const u8, secret_bytes: []const u8) ProviderError!value.SecretReference {
        const encoded_size = std.base64.standard.Encoder.calcSize(secret_bytes.len);
        const encoded = try context.allocator.alloc(u8, encoded_size);
        defer {
            std.crypto.secureZero(u8, encoded);
            context.allocator.free(encoded);
        }
        _ = std.base64.standard.Encoder.encode(encoded, secret_bytes);
        const body = try std.fmt.allocPrint(context.allocator, "{{\"payload\":{{\"data\":\"{s}\"}}}}", .{encoded});
        defer freeBody(context.allocator, body, true);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}:addVersion", .{secret_resource});
        defer context.allocator.free(path);
        var response = try self.request(context, .{ .api = .secret_manager, .method = "POST", .path = path, .body = body });
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const version_name = jsonString((jsonObject(parsed.value) orelse return error.ProviderBug).get("name")) orelse return error.ProviderBug;
        const separator = std.mem.lastIndexOf(u8, version_name, "/versions/") orelse return error.ProviderBug;
        return .{
            .provider = "gcp-secret-manager",
            .resource = secret_resource,
            .version = try context.allocator.dupe(u8, version_name[separator + "/versions/".len ..]),
        };
    }

    fn bodyAlloc(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, physical: ?[]const u8) ProviderError![]u8 {
        var arena_state = std.heap.ArenaAllocator.init(context.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var root: std.json.ObjectMap = .empty;
        if (physical) |name| try root.put(arena, "name", .{ .string = name });
        switch (kind) {
            .instance => {
                try root.put(arena, "displayName", .{ .string = try requiredString(node.inputs, "display_name") });
                try root.put(arena, "tier", .{ .string = try requiredString(node.inputs, "tier") });
                try root.put(arena, "memorySizeGb", .{ .integer = try requiredInteger(node.inputs, "memory_size_gb") });
                try root.put(arena, "redisVersion", .{ .string = try requiredString(node.inputs, "redis_version") });
                try root.put(arena, "authorizedNetwork", .{ .string = try requiredString(node.inputs, "network") });
                try root.put(arena, "connectMode", .{ .string = try requiredString(node.inputs, "connect_mode") });
                try root.put(arena, "authEnabled", .{ .bool = try requiredBool(node.inputs, "auth_enabled") });
                try root.put(arena, "transitEncryptionMode", .{ .string = try requiredString(node.inputs, "transit_encryption") });
                try root.put(arena, "replicaCount", .{ .integer = try requiredInteger(node.inputs, "read_replicas") });
                try root.put(arena, "readReplicasMode", .{ .string = if (try requiredInteger(node.inputs, "read_replicas") > 0) "READ_REPLICAS_ENABLED" else "READ_REPLICAS_DISABLED" });
                try root.put(arena, "redisConfigs", .{ .object = try keyValuesObject(arena, try requiredString(node.inputs, "configs")) });
                const reserved = try requiredString(node.inputs, "reserved_ip_range");
                if (reserved.len > 0) try root.put(arena, "reservedIpRange", .{ .string = reserved });
                const key = try requiredString(node.inputs, "kms_key_name");
                if (key.len > 0) try root.put(arena, "customerManagedKey", .{ .string = key });
                var persistence: std.json.ObjectMap = .empty;
                try persistence.put(arena, "persistenceMode", .{ .string = try requiredString(node.inputs, "persistence_mode") });
                const snapshot = try requiredString(node.inputs, "snapshot_period");
                if (snapshot.len > 0) try persistence.put(arena, "rdbSnapshotPeriod", .{ .string = snapshot });
                try root.put(arena, "persistenceConfig", .{ .object = persistence });
                const maintenance_day = try requiredString(node.inputs, "maintenance_day");
                if (maintenance_day.len > 0) {
                    var start_time: std.json.ObjectMap = .empty;
                    try start_time.put(arena, "hours", .{ .integer = try requiredInteger(node.inputs, "maintenance_hour_utc") });
                    var window: std.json.ObjectMap = .empty;
                    try window.put(arena, "day", .{ .string = maintenance_day });
                    try window.put(arena, "startTime", .{ .object = start_time });
                    var windows = std.json.Array.init(arena);
                    try windows.append(.{ .object = window });
                    var policy: std.json.ObjectMap = .empty;
                    try policy.put(arena, "weeklyMaintenanceWindow", .{ .array = windows });
                    try root.put(arena, "maintenancePolicy", .{ .object = policy });
                }
            },
            .cluster => {
                try root.put(arena, "shardCount", .{ .integer = try requiredInteger(node.inputs, "shard_count") });
                try root.put(arena, "replicaCount", .{ .integer = try requiredInteger(node.inputs, "replica_count") });
                try root.put(arena, "nodeType", .{ .string = try requiredString(node.inputs, "node_type") });
                try root.put(arena, "authorizationMode", .{ .string = try requiredString(node.inputs, "authorization") });
                try root.put(arena, "transitEncryptionMode", .{ .string = try requiredString(node.inputs, "transit_encryption") });
                try root.put(arena, "deletionProtectionEnabled", .{ .bool = try requiredBool(node.inputs, "deletion_protection") });
                try root.put(arena, "redisConfigs", .{ .object = try keyValuesObject(arena, try requiredString(node.inputs, "configs")) });
                var psc = std.json.Array.init(arena);
                var psc_config: std.json.ObjectMap = .empty;
                try psc_config.put(arena, "network", .{ .string = try requiredString(node.inputs, "network") });
                try psc.append(.{ .object = psc_config });
                try root.put(arena, "pscConfigs", .{ .array = psc });
                var persistence: std.json.ObjectMap = .empty;
                try persistence.put(arena, "mode", .{ .string = try requiredString(node.inputs, "persistence") });
                try root.put(arena, "persistenceConfig", .{ .object = persistence });
                const key = try requiredString(node.inputs, "kms_key_name");
                if (key.len > 0) try root.put(arena, "kmsKey", .{ .string = key });
                const acl_policy = try resolveOptionalStringInput(context, node.inputs, "acl_policy");
                if (acl_policy.len > 0) try root.put(arena, "aclPolicy", .{ .string = acl_policy });
            },
            .acl => {
                const rules = try requiredList(node.inputs, "rules");
                var wire_rules = std.json.Array.init(arena);
                for (rules) |rule_value| {
                    const fields = if (rule_value == .object) rule_value.object else return error.InvalidConfiguration;
                    const username = try requiredString(.{ .object = fields }, "username");
                    const reference = try resolveSecretInput(context, .{ .object = fields }, "rule");
                    var payload = try (self.secret_source orelse return error.InvalidConfiguration).resolve(context, context.allocator, reference);
                    defer payload.deinit();
                    var wire: std.json.ObjectMap = .empty;
                    try wire.put(arena, "username", .{ .string = username });
                    try wire.put(arena, "rule", .{ .string = try arena.dupe(u8, payload.bytes) });
                    try wire_rules.append(.{ .object = wire });
                }
                try root.put(arena, "rules", .{ .array = wire_rules });
            },
        }
        return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch error.OutOfMemory;
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, request_value: client_mod.Request) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, request_value, &diagnostic);
    }
};

pub fn supports(node: resource.ResourceNode) bool {
    return std.mem.eql(u8, node.type_name, instance_type) or std.mem.eql(u8, node.type_name, cluster_type) or std.mem.eql(u8, node.type_name, acl_type);
}

fn kindFor(node: resource.ResourceNode) ProviderError!Kind {
    if (std.mem.eql(u8, node.type_name, instance_type)) return .instance;
    if (std.mem.eql(u8, node.type_name, cluster_type)) return .cluster;
    if (std.mem.eql(u8, node.type_name, acl_type)) return .acl;
    return error.InvalidConfiguration;
}

fn deterministicPhysicalAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}/{s}/{s}", .{
        try requiredString(node.inputs, "project_id"),
        try requiredString(node.inputs, "location"),
        switch (kind) {
            .instance => "instances",
            .cluster => "clusters",
            .acl => "aclPolicies",
        },
        try requiredString(node.inputs, switch (kind) {
            .instance => "instance_id",
            .cluster => "cluster_id",
            .acl => "policy_id",
        }),
    }) catch error.OutOfMemory;
}

fn canonicalPhysicalAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind, physical: []const u8) ProviderError![]const u8 {
    const expected = try deterministicPhysicalAlloc(allocator, node, kind);
    defer allocator.free(expected);
    const canonical = std.mem.trimStart(u8, physical, "/");
    if (!std.mem.eql(u8, expected, canonical)) return error.InvalidConfiguration;
    return allocator.dupe(u8, canonical) catch error.OutOfMemory;
}

fn createPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    const parent = try std.fmt.allocPrint(allocator, "/v1/projects/{s}/locations/{s}", .{ try requiredString(node.inputs, "project_id"), try requiredString(node.inputs, "location") });
    defer allocator.free(parent);
    return std.fmt.allocPrint(allocator, "{s}/{s}?{s}={s}", .{
        parent,
        switch (kind) {
            .instance => "instances",
            .cluster => "clusters",
            .acl => "aclPolicies",
        },
        switch (kind) {
            .instance => "instanceId",
            .cluster => "clusterId",
            .acl => "aclPolicyId",
        },
        try requiredString(node.inputs, switch (kind) {
            .instance => "instance_id",
            .cluster => "cluster_id",
            .acl => "policy_id",
        }),
    }) catch error.OutOfMemory;
}

fn resultFromJson(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, body: []const u8, auth_reference: ?value.SecretReference) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const physical = jsonString(root.get("name")) orelse return error.ProviderBug;
    var observed = try normalizedInputsAlloc(self, context, node, kind, root);
    defer observed.deinit(context.allocator);
    var endpoint_buffer: [256]u8 = undefined;
    const endpoint = if (kind == .cluster) clusterEndpoint(&endpoint_buffer, root) else "";
    const latest = auth_reference orelse value.SecretReference{ .provider = "gcp-secret-manager", .resource = resolveStringInput(context, node.inputs, "auth_secret") catch "", .version = "latest" };
    const outputs = switch (kind) {
        .instance => &[_]state.StateOutput{
            .{ .name = "name", .value = .{ .string = physical } },
            .{ .name = "host", .value = .{ .string = jsonString(root.get("host")) orelse "" } },
            .{ .name = "port", .value = .{ .integer = jsonInteger(root.get("port")) orelse 0 } },
            .{ .name = "read_endpoint", .value = .{ .string = jsonString(root.get("readEndpoint")) orelse "" } },
            .{ .name = "auth_secret_version", .value = .{ .secret_ref = latest } },
            .{ .name = "state", .value = .{ .string = jsonString(root.get("state")) orelse "" } },
        },
        .cluster => &[_]state.StateOutput{
            .{ .name = "name", .value = .{ .string = physical } },
            .{ .name = "discovery_endpoint", .value = .{ .string = endpoint } },
            .{ .name = "state", .value = .{ .string = jsonString(root.get("state")) orelse "" } },
            .{ .name = "uid", .value = .{ .string = jsonString(root.get("uid")) orelse "" } },
        },
        .acl => &[_]state.StateOutput{
            .{ .name = "name", .value = .{ .string = physical } },
            .{ .name = "state", .value = .{ .string = jsonString(root.get("state")) orelse "" } },
            .{ .name = "etag", .value = .{ .string = jsonString(root.get("etag")) orelse "" } },
        },
    };
    return provider_mod.ResourceResult.init(context.allocator, physical, observed, outputs, null);
}

fn normalizedInputsAlloc(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, root: std.json.ObjectMap) ProviderError!value.Value {
    if (kind == .acl) return normalizedAclInputsAlloc(self, context, node, root);
    const configs = try jsonMapTextAlloc(context.allocator, root.get("redisConfigs"));
    defer context.allocator.free(configs);
    if (kind == .instance) {
        const persistence = if (root.get("persistenceConfig")) |candidate| jsonObject(candidate) else null;
        const maintenance = maintenanceWindow(root);
        const fields = [_]value.Field{
            .{ .name = "auth_enabled", .value = .{ .boolean = jsonBool(root.get("authEnabled")) orelse false } },
            .{ .name = "auth_secret", .value = try requiredValue(node.inputs, "auth_secret") },
            .{ .name = "configs", .value = .{ .string = configs } },
            .{ .name = "connect_mode", .value = .{ .string = jsonString(root.get("connectMode")) orelse "DIRECT_PEERING" } },
            .{ .name = "connectivity_dependency", .value = try requiredValue(node.inputs, "connectivity_dependency") },
            .{ .name = "display_name", .value = .{ .string = jsonString(root.get("displayName")) orelse "" } },
            .{ .name = "instance_id", .value = try requiredValue(node.inputs, "instance_id") },
            .{ .name = "kms_key_name", .value = .{ .string = jsonString(root.get("customerManagedKey")) orelse "" } },
            .{ .name = "location", .value = try requiredValue(node.inputs, "location") },
            .{ .name = "maintenance_day", .value = .{ .string = maintenance.day } },
            .{ .name = "maintenance_hour_utc", .value = .{ .integer = maintenance.hour } },
            .{ .name = "memory_size_gb", .value = .{ .integer = jsonInteger(root.get("memorySizeGb")) orelse 0 } },
            .{ .name = "network", .value = .{ .string = jsonString(root.get("authorizedNetwork")) orelse "" } },
            .{ .name = "persistence_mode", .value = .{ .string = if (persistence) |present| jsonString(present.get("persistenceMode")) orelse "DISABLED" else "DISABLED" } },
            .{ .name = "project_id", .value = try requiredValue(node.inputs, "project_id") },
            .{ .name = "read_replicas", .value = .{ .integer = jsonInteger(root.get("replicaCount")) orelse 0 } },
            .{ .name = "redis_version", .value = .{ .string = jsonString(root.get("redisVersion")) orelse "REDIS_7_0" } },
            .{ .name = "reserved_ip_range", .value = .{ .string = jsonString(root.get("reservedIpRange")) orelse "" } },
            .{ .name = "snapshot_period", .value = .{ .string = if (persistence) |present| jsonString(present.get("rdbSnapshotPeriod")) orelse "" else "" } },
            .{ .name = "tier", .value = .{ .string = jsonString(root.get("tier")) orelse "" } },
            .{ .name = "transit_encryption", .value = .{ .string = jsonString(root.get("transitEncryptionMode")) orelse "DISABLED" } },
        };
        return ownedObject(context.allocator, &fields);
    }
    const psc = root.get("pscConfigs") orelse return error.ProviderBug;
    if (psc != .array or psc.array.items.len != 1) return error.ProviderBug;
    const psc_config = jsonObject(psc.array.items[0]) orelse return error.ProviderBug;
    const persistence = if (root.get("persistenceConfig")) |candidate| jsonObject(candidate) else null;
    const fields = [_]value.Field{
        .{ .name = "acl_policy", .value = .{ .string = jsonString(root.get("aclPolicy")) orelse "" } },
        .{ .name = "authorization", .value = .{ .string = jsonString(root.get("authorizationMode")) orelse "AUTH_MODE_DISABLED" } },
        .{ .name = "cluster_id", .value = try requiredValue(node.inputs, "cluster_id") },
        .{ .name = "configs", .value = .{ .string = configs } },
        .{ .name = "deletion_protection", .value = .{ .boolean = jsonBool(root.get("deletionProtectionEnabled")) orelse false } },
        .{ .name = "kms_key_name", .value = .{ .string = jsonString(root.get("kmsKey")) orelse "" } },
        .{ .name = "location", .value = try requiredValue(node.inputs, "location") },
        .{ .name = "network", .value = .{ .string = jsonString(psc_config.get("network")) orelse return error.ProviderBug } },
        .{ .name = "node_type", .value = .{ .string = jsonString(root.get("nodeType")) orelse "" } },
        .{ .name = "persistence", .value = .{ .string = if (persistence) |present| jsonString(present.get("mode")) orelse "DISABLED" else "DISABLED" } },
        .{ .name = "project_id", .value = try requiredValue(node.inputs, "project_id") },
        .{ .name = "replica_count", .value = .{ .integer = jsonInteger(root.get("replicaCount")) orelse 0 } },
        .{ .name = "shard_count", .value = .{ .integer = jsonInteger(root.get("shardCount")) orelse 0 } },
        .{ .name = "transit_encryption", .value = .{ .string = jsonString(root.get("transitEncryptionMode")) orelse "TRANSIT_ENCRYPTION_MODE_DISABLED" } },
    };
    return ownedObject(context.allocator, &fields);
}

fn normalizedAclInputsAlloc(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, root: std.json.ObjectMap) ProviderError!value.Value {
    if (try aclRulesMatch(self, context, node, root)) return value.Value.initOwned(context.allocator, node.inputs) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateField => error.ProviderBug,
    };
    if (node.inputs != .object) return error.InvalidConfiguration;
    const fields = try context.allocator.alloc(value.Field, node.inputs.object.len);
    defer context.allocator.free(fields);
    for (node.inputs.object, 0..) |field, index| {
        fields[index] = field;
        if (std.mem.eql(u8, field.name, "rules")) fields[index].value = .{ .string = "__ziac_remote_acl_drift__" };
    }
    return value.Value.initOwned(context.allocator, .{ .object = fields }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateField => error.ProviderBug,
    };
}

fn aclRulesMatch(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, root: std.json.ObjectMap) ProviderError!bool {
    const desired = try requiredList(node.inputs, "rules");
    const remote_value = root.get("rules") orelse return false;
    if (remote_value != .array or remote_value.array.items.len != desired.len) return false;
    for (desired) |desired_rule| {
        if (desired_rule != .object) return error.InvalidConfiguration;
        const username = try requiredString(desired_rule, "username");
        const reference = try resolveSecretInput(context, desired_rule, "rule");
        const matches = blk: {
            var payload = try (self.secret_source orelse return error.InvalidConfiguration).resolve(context, context.allocator, reference);
            defer payload.deinit();
            for (remote_value.array.items) |remote_candidate| {
                const remote = jsonObject(remote_candidate) orelse return error.ProviderBug;
                if (!std.mem.eql(u8, jsonString(remote.get("username")) orelse continue, username)) continue;
                break :blk std.mem.eql(u8, jsonString(remote.get("rule")) orelse return error.ProviderBug, payload.bytes);
            }
            break :blk false;
        };
        if (!matches) return false;
    }
    return true;
}

fn pendingResult(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, intent: ResumeIntent, handle: []const u8) ProviderError!provider_mod.ResourceResult {
    const physical = try deterministicPhysicalAlloc(context.allocator, node, kind);
    defer context.allocator.free(physical);
    const checkpoint = try std.fmt.allocPrint(context.allocator, "{s}:{s}", .{ @tagName(intent), handle });
    defer context.allocator.free(checkpoint);
    var result = try provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &.{}, checkpoint);
    result.completed = false;
    return result;
}

fn parseResumeCheckpoint(handle: []const u8) ResumeCheckpoint {
    inline for (.{ ResumeIntent.create, ResumeIntent.update }) |intent| {
        const prefix = @tagName(intent) ++ ":";
        if (std.mem.startsWith(u8, handle, prefix)) return .{ .intent = intent, .operation = handle[prefix.len..] };
    }
    return .{ .intent = .unknown, .operation = handle };
}

fn updateMaskAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, observed: value.Value, kind: Kind) ProviderError![]const u8 {
    if (kind == .acl) return allocator.dupe(u8, "rules") catch error.OutOfMemory;
    var mask: std.ArrayList(u8) = .empty;
    defer mask.deinit(allocator);
    const Mapping = struct { input: []const u8, api: []const u8 };
    const mappings: []const Mapping = if (kind == .instance)
        &[_]Mapping{
            .{ .input = "display_name", .api = "displayName" }, .{ .input = "memory_size_gb", .api = "memorySizeGb" }, .{ .input = "configs", .api = "redisConfigs" }, .{ .input = "read_replicas", .api = "replicaCount" }, .{ .input = "persistence_mode", .api = "persistenceConfig" }, .{ .input = "snapshot_period", .api = "persistenceConfig" }, .{ .input = "auth_enabled", .api = "authEnabled" }, .{ .input = "maintenance_day", .api = "maintenancePolicy" }, .{ .input = "maintenance_hour_utc", .api = "maintenancePolicy" },
        }
    else
        &[_]Mapping{
            .{ .input = "shard_count", .api = "shardCount" }, .{ .input = "replica_count", .api = "replicaCount" }, .{ .input = "configs", .api = "redisConfigs" }, .{ .input = "persistence", .api = "persistenceConfig" }, .{ .input = "deletion_protection", .api = "deletionProtectionEnabled" }, .{ .input = "acl_policy", .api = "aclPolicy" },
        };
    for (mappings) |mapping| if (changedField(node.inputs, observed, mapping.input)) {
        if (mask.items.len > 0) try mask.append(allocator, ',');
        try mask.appendSlice(allocator, mapping.api);
    };
    return mask.toOwnedSlice(allocator);
}

const MaintenanceWindow = struct { day: []const u8 = "", hour: i64 = 0 };

fn maintenanceWindow(root: std.json.ObjectMap) MaintenanceWindow {
    const policy = jsonObject(root.get("maintenancePolicy") orelse return .{}) orelse return .{};
    const windows = policy.get("weeklyMaintenanceWindow") orelse return .{};
    if (windows != .array or windows.array.items.len == 0) return .{};
    const window = jsonObject(windows.array.items[0]) orelse return .{};
    const start = jsonObject(window.get("startTime") orelse return .{}) orelse return .{};
    return .{
        .day = jsonString(window.get("day")) orelse "",
        .hour = jsonInteger(start.get("hours")) orelse 0,
    };
}

fn latestAuthReference(context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!value.SecretReference {
    return .{ .provider = "gcp-secret-manager", .resource = try resolveStringInput(context, node.inputs, "auth_secret"), .version = "latest" };
}

fn clusterEndpoint(buffer: []u8, root: std.json.ObjectMap) []const u8 {
    const endpoints = root.get("discoveryEndpoints") orelse return "";
    if (endpoints != .array or endpoints.array.items.len == 0) return "";
    const endpoint = jsonObject(endpoints.array.items[0]) orelse return "";
    const address = jsonString(endpoint.get("address")) orelse return "";
    const port = jsonInteger(endpoint.get("port")) orelse return "";
    return std.fmt.bufPrint(buffer, "{s}:{d}", .{ address, port }) catch "";
}

fn operationNameAlloc(allocator: std.mem.Allocator, body: []const u8) ProviderError![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    return allocator.dupe(u8, jsonString((jsonObject(parsed.value) orelse return error.ProviderBug).get("name")) orelse return error.ProviderBug) catch error.OutOfMemory;
}

fn keyValuesObject(allocator: std.mem.Allocator, text: []const u8) ProviderError!std.json.ObjectMap {
    var object: std.json.ObjectMap = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfiguration;
        try object.put(allocator, line[0..separator], .{ .string = line[separator + 1 ..] });
    }
    return object;
}

const MapEntry = struct { key: []const u8, value_text: []const u8 };
fn jsonMapTextAlloc(allocator: std.mem.Allocator, candidate: ?std.json.Value) ProviderError![]const u8 {
    const object = if (candidate) |present| jsonObject(present) orelse return error.ProviderBug else std.json.ObjectMap.empty;
    const entries = try allocator.alloc(MapEntry, object.count());
    defer allocator.free(entries);
    var iterator = object.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| : (index += 1) entries[index] = .{ .key = entry.key_ptr.*, .value_text = jsonString(entry.value_ptr.*) orelse return error.ProviderBug };
    std.mem.sort(MapEntry, entries, {}, struct {
        fn lessThan(_: void, left: MapEntry, right: MapEntry) bool {
            return std.mem.order(u8, left.key, right.key) == .lt;
        }
    }.lessThan);
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    for (entries, 0..) |entry, entry_index| {
        if (entry_index > 0) try result.append(allocator, '\n');
        try result.appendSlice(allocator, entry.key);
        try result.append(allocator, '=');
        try result.appendSlice(allocator, entry.value_text);
    }
    return result.toOwnedSlice(allocator);
}

fn freeBody(allocator: std.mem.Allocator, body: []u8, sensitive: bool) void {
    if (sensitive) std.crypto.secureZero(u8, body);
    allocator.free(body);
}

fn resolveStringInput(context: *provider_mod.OperationContext, inputs: value.Value, name: []const u8) ProviderError![]const u8 {
    return switch (findValue(inputs, name) orelse return error.InvalidConfiguration) {
        .string => |text| text,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}

fn resolveOptionalStringInput(context: *provider_mod.OperationContext, inputs: value.Value, name: []const u8) ProviderError![]const u8 {
    return switch (findValue(inputs, name) orelse return "") {
        .string => |text| text,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}

fn resolveSecretInput(context: *provider_mod.OperationContext, inputs: value.Value, name: []const u8) ProviderError!value.SecretReference {
    return switch (findValue(inputs, name) orelse return error.InvalidConfiguration) {
        .secret_ref => |reference| reference,
        .output_ref => |reference| context.resolveOutputSecret(reference),
        else => error.InvalidConfiguration,
    };
}

fn changedAny(desired: value.Value, observed: value.Value, names: []const []const u8) bool {
    for (names) |name| if (changedField(desired, observed, name)) return true;
    return false;
}
fn changedField(desired: value.Value, observed: value.Value, name: []const u8) bool {
    const left = findValue(desired, name) orelse return true;
    const right = findValue(observed, name) orelse return true;
    const left_hash = left.sha256(std.heap.page_allocator) catch return true;
    const right_hash = right.sha256(std.heap.page_allocator) catch return true;
    return !std.mem.eql(u8, &left_hash, &right_hash);
}

fn ownedObject(allocator: std.mem.Allocator, fields: []const value.Field) ProviderError!value.Value {
    return value.Value.initOwned(allocator, .{ .object = fields }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateField => error.ProviderBug,
    };
}
fn requiredValue(inputs: value.Value, name: []const u8) ProviderError!value.Value {
    return findValue(inputs, name) orelse error.InvalidConfiguration;
}
fn requiredString(inputs: value.Value, name: []const u8) ProviderError![]const u8 {
    return switch (try requiredValue(inputs, name)) {
        .string => |text| text,
        else => error.InvalidConfiguration,
    };
}
fn requiredInteger(inputs: value.Value, name: []const u8) ProviderError!i64 {
    return switch (try requiredValue(inputs, name)) {
        .integer => |number| number,
        else => error.InvalidConfiguration,
    };
}
fn requiredBool(inputs: value.Value, name: []const u8) ProviderError!bool {
    return switch (try requiredValue(inputs, name)) {
        .boolean => |present| present,
        else => error.InvalidConfiguration,
    };
}
fn requiredList(inputs: value.Value, name: []const u8) ProviderError![]const value.Value {
    return switch (try requiredValue(inputs, name)) {
        .list => |items| items,
        else => error.InvalidConfiguration,
    };
}
fn findValue(inputs: value.Value, name: []const u8) ?value.Value {
    if (inputs != .object) return null;
    for (inputs.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return null;
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
fn jsonInteger(candidate: ?std.json.Value) ?i64 {
    const present = candidate orelse return null;
    return switch (present) {
        .integer => |number| number,
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
