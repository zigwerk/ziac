const std = @import("std");
const client_mod = @import("client.zig");
const connection_secret = @import("connection_secret.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const secret = @import("../secret.zig");
const sql = @import("sql.zig");
const sql_provider = @import("sql_provider.zig");
const state = @import("../state.zig");
const validation = @import("validation.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;
const cluster_type = "cockroach.Cluster";
const existing_cluster_type = "cockroach.Cluster.Existing";
const sql_user_type = "cockroach.SqlUser";
const authorized_network_type = "cockroach.AuthorizedNetwork";
const cluster_region_type = "cockroach.ClusterRegion";
const private_endpoint_service_type = "cockroach.PrivateEndpointService";
const private_endpoint_connection_type = "cockroach.PrivateEndpointConnection";

pub const LiveProvider = struct {
    client: *client_mod.Client,
    secret_source: ?secret.SecretSource = null,
    sql_executor: ?sql.Executor = null,
    sql_retry_policy: sql_provider.RetryPolicy = .{},
    cluster_poll_interval_millis: u64 = 5_000,
    private_endpoint_poll_interval_millis: u64 = 5_000,
    migration_lock: @import("zigeffect_std").fx.SpinLock = .{},

    pub fn init(client: *client_mod.Client) LiveProvider {
        return .{ .client = client };
    }

    pub fn provider(self: *LiveProvider) provider_mod.Provider {
        return .{
            .ptr = self,
            .readFn = read,
            .diffFn = diff,
            .createFn = create,
            .updateFn = update,
            .deleteFn = delete,
            .importFn = importResource,
        };
    }

    fn read(
        ptr: *anyopaque,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ReadResult {
        const self: *LiveProvider = @ptrCast(@alignCast(ptr));
        if (!isSupported(node)) return error.InvalidConfiguration;
        if (isType(node, cluster_region_type)) return self.readClusterRegion(context, node);
        if (isType(node, private_endpoint_service_type)) return self.readPrivateEndpointService(context, node);
        if (isType(node, private_endpoint_connection_type)) return self.readPrivateEndpointConnection(context, node);
        if (isType(node, sql_user_type)) return self.readSqlUser(context, node);
        if (isType(node, authorized_network_type)) return self.readAuthorizedNetwork(context, node);
        if (sql_provider.supports(node)) return (try self.sqlHandler()).read(context, node);
        if (isType(node, cluster_type)) return self.readManagedCluster(context, node);
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        var cluster = self.client.getClusterAlloc(context, try inputString(node.inputs, "cluster_id"), &diagnostic) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer cluster.deinit(context.allocator);
        return .{ .present = try resultFromCluster(context.allocator, node, cluster) };
    }

    fn diff(
        ptr: *anyopaque,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        observed: *const provider_mod.ResourceResult,
    ) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        if (!isSupported(node)) return error.InvalidConfiguration;
        if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash)) {
            return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        }
        if (isPrivateEndpointType(node)) {
            return provider_mod.DiffResult.init(context.allocator, .replace, &.{"private endpoint identity changed"});
        }
        if (isType(node, sql_user_type)) return sqlUserDiff(context.allocator, node.inputs, observed.observed_inputs);
        if (isType(node, authorized_network_type)) return authorizedNetworkDiff(context.allocator, node.inputs, observed.observed_inputs);
        if (isType(node, cluster_type)) return managedClusterDiff(context.allocator, node.inputs, observed.observed_inputs);
        if (sql_provider.supports(node)) {
            const self: *LiveProvider = @ptrCast(@alignCast(ptr));
            return (try self.sqlHandler()).diff(context, node, observed);
        }
        return topologyDiff(context.allocator, node.inputs, observed.observed_inputs);
    }

    fn create(
        ptr: *anyopaque,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        const self: *LiveProvider = @ptrCast(@alignCast(ptr));
        if (isType(node, cluster_region_type)) return self.readRequiredClusterRegion(context, node);
        if (isType(node, private_endpoint_service_type)) return self.ensurePrivateEndpointService(context, node);
        if (isType(node, private_endpoint_connection_type)) return self.ensurePrivateEndpointConnection(context, node);
        if (isType(node, sql_user_type)) return self.ensureSqlUser(context, node);
        if (isType(node, authorized_network_type)) return self.writeAuthorizedNetwork(context, node, false);
        if (sql_provider.supports(node)) return (try self.sqlHandler()).create(context, node);
        if (isType(node, cluster_type)) return self.createManagedCluster(context, node);
        return self.readExact(context, node);
    }

    fn update(
        ptr: *anyopaque,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        observed: *const provider_mod.ResourceResult,
    ) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        if (!isSupported(node)) return error.InvalidConfiguration;
        if (isPrivateEndpointType(node)) {
            if (!std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash)) return error.InvalidConfiguration;
            return observed.clone(context.allocator);
        }
        if (isType(node, sql_user_type)) {
            const self: *LiveProvider = @ptrCast(@alignCast(ptr));
            return self.ensureSqlUser(context, node);
        }
        if (isType(node, authorized_network_type)) {
            const self: *LiveProvider = @ptrCast(@alignCast(ptr));
            return self.writeAuthorizedNetwork(context, node, true);
        }
        if (sql_provider.supports(node)) {
            const self: *LiveProvider = @ptrCast(@alignCast(ptr));
            return (try self.sqlHandler()).update(context, node, observed);
        }
        if (isType(node, cluster_type)) {
            const self: *LiveProvider = @ptrCast(@alignCast(ptr));
            return self.updateManagedCluster(context, node, observed);
        }
        var result_diff = try topologyDiff(context.allocator, node.inputs, observed.observed_inputs);
        defer result_diff.deinit();
        if (result_diff.kind != .noop) return error.InvalidConfiguration;
        return observed.clone(context.allocator);
    }

    fn delete(
        ptr: *anyopaque,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!void {
        try context.checkActive();
        if (!isSupported(node)) return error.InvalidConfiguration;
        if (isType(node, cluster_region_type) or isType(node, private_endpoint_service_type)) {
            const expected = try privateRegionalPhysicalIdAlloc(context, node);
            defer context.allocator.free(expected);
            if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
            return;
        }
        if (isType(node, private_endpoint_connection_type)) {
            const self: *LiveProvider = @ptrCast(@alignCast(ptr));
            return self.deletePrivateEndpointConnection(context, node, physical_id);
        }
        if (isType(node, sql_user_type)) {
            const self: *LiveProvider = @ptrCast(@alignCast(ptr));
            return self.deleteSqlUser(context, node, physical_id);
        }
        if (isType(node, authorized_network_type)) {
            const self: *LiveProvider = @ptrCast(@alignCast(ptr));
            return self.deleteAuthorizedNetwork(context, node, physical_id);
        }
        if (sql_provider.supports(node)) {
            const self: *LiveProvider = @ptrCast(@alignCast(ptr));
            return (try self.sqlHandler()).delete(context, node, physical_id);
        }
        if (isType(node, cluster_type)) {
            const self: *LiveProvider = @ptrCast(@alignCast(ptr));
            return self.deleteManagedCluster(context, node, physical_id);
        }
        if (!std.mem.eql(u8, try inputString(node.inputs, "cluster_id"), physical_id)) {
            return error.InvalidConfiguration;
        }
    }

    fn importResource(
        ptr: *anyopaque,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!provider_mod.ResourceResult {
        const self: *LiveProvider = @ptrCast(@alignCast(ptr));
        if (!isSupported(node)) return error.InvalidConfiguration;
        if (isPrivateEndpointType(node)) {
            const expected = if (isType(node, private_endpoint_connection_type))
                try privateConnectionPhysicalIdAlloc(context, node)
            else
                try privateRegionalPhysicalIdAlloc(context, node);
            defer context.allocator.free(expected);
            if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
            const found = try read(ptr, context, node);
            return switch (found) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (isType(node, sql_user_type)) {
            const expected = try sqlUserPhysicalIdAlloc(context.allocator, node);
            defer context.allocator.free(expected);
            if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
            return switch (try self.readSqlUser(context, node)) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (isType(node, authorized_network_type)) {
            const expected = try authorizedNetworkPhysicalIdAlloc(context, node);
            defer context.allocator.free(expected);
            if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
            return switch (try self.readAuthorizedNetwork(context, node)) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (sql_provider.supports(node)) return (try self.sqlHandler()).importResource(context, node, physical_id);
        if (isType(node, cluster_type)) return self.importManagedCluster(context, node, physical_id);
        if (!std.mem.eql(u8, try inputString(node.inputs, "cluster_id"), physical_id)) {
            return error.InvalidConfiguration;
        }
        return self.readExact(context, node);
    }

    fn readExact(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        var result = switch (try read(self, context, node)) {
            .absent => return error.NotFound,
            .present => |present| present,
        };
        errdefer result.deinit();
        var result_diff = try topologyDiff(context.allocator, node.inputs, result.observed_inputs);
        defer result_diff.deinit();
        if (result_diff.kind != .noop) return error.InvalidConfiguration;
        return result;
    }

    fn readManagedCluster(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ReadResult {
        const physical_id = context.physical_id orelse return .absent;
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        var cluster = self.client.getClusterAlloc(context, physical_id, &diagnostic) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer cluster.deinit(context.allocator);
        if (cluster.state) |remote_state| {
            if (std.mem.eql(u8, remote_state, "DELETED")) return .absent;
        }
        return .{ .present = try managedClusterResult(context.allocator, node, cluster) };
    }

    fn createManagedCluster(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        var spec = try managedSpecFromInputsAlloc(context.allocator, node.inputs);
        defer spec.deinit();
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        var cluster = try self.client.createClusterAlloc(context, spec.value, &diagnostic);
        cluster = try self.waitForClusterReady(context, cluster, &diagnostic);
        defer cluster.deinit(context.allocator);
        return managedClusterResult(context.allocator, node, cluster);
    }

    fn updateManagedCluster(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        observed: *const provider_mod.ResourceResult,
    ) ProviderError!provider_mod.ResourceResult {
        var result_diff = try managedClusterDiff(context.allocator, node.inputs, observed.observed_inputs);
        defer result_diff.deinit();
        if (result_diff.kind == .replace) return error.InvalidConfiguration;
        if (result_diff.kind == .noop) return observed.clone(context.allocator);
        const physical_id = context.physical_id orelse observed.physical_id;
        var spec = try managedSpecFromInputsAlloc(context.allocator, node.inputs);
        defer spec.deinit();
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        var cluster = try self.client.updateClusterAlloc(context, physical_id, spec.value, &diagnostic);
        cluster = try self.waitForClusterReady(context, cluster, &diagnostic);
        defer cluster.deinit(context.allocator);
        return managedClusterResult(context.allocator, node, cluster);
    }

    fn importManagedCluster(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!provider_mod.ResourceResult {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        var cluster = try self.client.getClusterAlloc(context, physical_id, &diagnostic);
        defer cluster.deinit(context.allocator);
        var result = try managedClusterResult(context.allocator, node, cluster);
        errdefer result.deinit();
        var result_diff = try managedClusterDiff(context.allocator, node.inputs, result.observed_inputs);
        defer result_diff.deinit();
        if (result_diff.kind != .noop) return error.InvalidConfiguration;
        return result;
    }

    fn deleteManagedCluster(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!void {
        if (try inputBoolean(node.inputs, "protect")) return error.InvalidConfiguration;
        if (!context.destructive_confirmation) return error.DestructiveConfirmationRequired;
        if (physical_id.len == 0) return error.InvalidConfiguration;
        if (context.physical_id) |tracked_id| {
            if (!std.mem.eql(u8, tracked_id, physical_id)) return error.InvalidConfiguration;
        }
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        var cluster = self.client.getClusterAlloc(context, physical_id, &diagnostic) catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer cluster.deinit(context.allocator);
        if (cluster.delete_protection == null or !std.mem.eql(u8, cluster.delete_protection.?, "DISABLED")) {
            return error.InvalidConfiguration;
        }
        try self.client.deleteCluster(context, physical_id, &diagnostic);
    }

    fn waitForClusterReady(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        initial: client_mod.Cluster,
        diagnostic: *client_mod.Diagnostic,
    ) ProviderError!client_mod.Cluster {
        var current = initial;
        errdefer current.deinit(context.allocator);
        while (true) {
            const remote_state = current.state orelse return error.ProviderBug;
            if (std.mem.eql(u8, remote_state, "CREATED")) return current;
            if (std.mem.eql(u8, remote_state, "CREATION_FAILED") or std.mem.eql(u8, remote_state, "DELETED")) {
                return error.ProviderBug;
            }
            if (!std.mem.eql(u8, remote_state, "CREATING") and !std.mem.eql(u8, remote_state, "LOCKED")) {
                return error.ProviderBug;
            }
            try context.checkActive();
            context.sleep(self.cluster_poll_interval_millis);
            try context.checkActive();
            const next = try self.client.getClusterAlloc(context, current.id, diagnostic);
            current.deinit(context.allocator);
            current = next;
        }
    }

    fn readClusterRegion(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ReadResult {
        const cluster_id = try resolveInputString(context, node.inputs, "cluster_id");
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        var cluster = self.client.getClusterAlloc(context, cluster_id, &diagnostic) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer cluster.deinit(context.allocator);
        try validateGcpCluster(cluster, null, try inputString(node.inputs, "region"));
        return .{ .present = try clusterRegionResult(context, node, cluster) };
    }

    fn readRequiredClusterRegion(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        return switch (try self.readClusterRegion(context, node)) {
            .absent => error.NotFound,
            .present => |present| present,
        };
    }

    fn readPrivateEndpointService(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ReadResult {
        const cluster_id = try resolveInputString(context, node.inputs, "cluster_id");
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        var cluster = self.client.getClusterAlloc(context, cluster_id, &diagnostic) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer cluster.deinit(context.allocator);
        const region = try inputString(node.inputs, "region");
        try validateGcpCluster(cluster, try inputString(node.inputs, "plan"), region);
        const services = try self.client.listPrivateEndpointServicesAlloc(context, cluster_id, &diagnostic);
        defer client_mod.freePrivateEndpointServices(context.allocator, services);
        const service = findPrivateEndpointService(services, region) orelse return .absent;
        return switch (service.status) {
            .available => .{ .present = try privateEndpointServiceResult(context, node, service) },
            .creating => .absent,
            .create_failed, .deleting, .delete_failed => error.ProviderBug,
        };
    }

    fn ensurePrivateEndpointService(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        const cluster_id = try resolveInputString(context, node.inputs, "cluster_id");
        const plan = try inputString(node.inputs, "plan");
        const region = try inputString(node.inputs, "region");
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        var cluster = try self.client.getClusterAlloc(context, cluster_id, &diagnostic);
        defer cluster.deinit(context.allocator);
        try validateGcpCluster(cluster, plan, region);

        if (!std.mem.eql(u8, plan, "ADVANCED") and !std.mem.eql(u8, plan, "STANDARD")) {
            return error.InvalidConfiguration;
        }
        var services = try self.client.listPrivateEndpointServicesAlloc(context, cluster_id, &diagnostic);
        defer client_mod.freePrivateEndpointServices(context.allocator, services);
        if (std.mem.eql(u8, plan, "ADVANCED") and findPrivateEndpointService(services, region) == null) {
            const enabled_services = try self.client.enablePrivateEndpointServicesAlloc(context, cluster_id, &diagnostic);
            client_mod.freePrivateEndpointServices(context.allocator, services);
            services = enabled_services;
        }
        while (true) {
            if (findPrivateEndpointService(services, region)) |service| {
                switch (service.status) {
                    .available => return privateEndpointServiceResult(context, node, service),
                    .creating => {},
                    .create_failed, .deleting, .delete_failed => return error.ProviderBug,
                }
            }
            try context.checkActive();
            context.sleep(self.private_endpoint_poll_interval_millis);
            try context.checkActive();
            const next = try self.client.listPrivateEndpointServicesAlloc(context, cluster_id, &diagnostic);
            client_mod.freePrivateEndpointServices(context.allocator, services);
            services = next;
        }
    }

    fn readPrivateEndpointConnection(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ReadResult {
        const cluster_id = try resolveInputString(context, node.inputs, "cluster_id");
        const endpoint_id = try resolveInputString(context, node.inputs, "endpoint_id");
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        const connections = self.client.listPrivateEndpointConnectionsAlloc(context, cluster_id, &diagnostic) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer client_mod.freePrivateEndpointConnections(context.allocator, connections);
        const connection = findPrivateEndpointConnection(connections, endpoint_id) orelse return .absent;
        try validatePrivateEndpointConnection(context, node, connection);
        return switch (connection.status) {
            .available => .{ .present = try privateEndpointConnectionResult(context, node, connection) },
            .pending, .pending_acceptance, .rejected => .absent,
            .deleting, .deleted, .failed, .expired, .stale => error.ProviderBug,
        };
    }

    fn ensurePrivateEndpointConnection(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        const cluster_id = try resolveInputString(context, node.inputs, "cluster_id");
        const endpoint_id = try resolveInputString(context, node.inputs, "endpoint_id");
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        var registered = false;
        while (true) {
            const connections = try self.client.listPrivateEndpointConnectionsAlloc(context, cluster_id, &diagnostic);
            defer client_mod.freePrivateEndpointConnections(context.allocator, connections);
            if (findPrivateEndpointConnection(connections, endpoint_id)) |connection| {
                try validatePrivateEndpointConnection(context, node, connection);
                registered = true;
                switch (connection.status) {
                    .available => return privateEndpointConnectionResult(context, node, connection),
                    .pending, .pending_acceptance, .rejected => {},
                    .deleting, .deleted, .failed, .expired, .stale => return error.ProviderBug,
                }
            } else if (!registered) {
                try self.client.addPrivateEndpointConnection(context, cluster_id, endpoint_id, &diagnostic);
                registered = true;
                continue;
            }
            try context.checkActive();
            context.sleep(self.private_endpoint_poll_interval_millis);
            try context.checkActive();
        }
    }

    fn deletePrivateEndpointConnection(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!void {
        const expected = try privateConnectionPhysicalIdAlloc(context, node);
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        try self.client.deletePrivateEndpointConnection(
            context,
            try resolveInputString(context, node.inputs, "cluster_id"),
            try resolveInputString(context, node.inputs, "endpoint_id"),
            &diagnostic,
        );
    }

    fn readSqlUser(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ReadResult {
        const cluster_id = try inputString(node.inputs, "cluster_id");
        const username = try inputString(node.inputs, "username");
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        const users = try self.client.listAllSqlUsersAlloc(context, cluster_id, &diagnostic);
        defer client_mod.freeSqlUsers(context.allocator, users);
        for (users) |user| {
            if (std.mem.eql(u8, user.name, username)) {
                return .{ .present = try sqlUserResult(context.allocator, node) };
            }
        }
        return .absent;
    }

    fn ensureSqlUser(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        const source = self.secret_source orelse return error.InvalidConfiguration;
        const cluster_id = try inputString(node.inputs, "cluster_id");
        const username = try inputString(node.inputs, "username");
        const reference = try inputSecretReference(context, node.inputs, "connection_secret");
        var payload = try source.resolve(context, context.allocator, reference);
        defer payload.deinit();
        const password = connection_secret.passwordFromConnectionUriAlloc(
            context.allocator,
            payload.bytes,
            username,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidConfiguration,
        };
        defer {
            std.crypto.secureZero(u8, password);
            context.allocator.free(password);
        }
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        const users = try self.client.listAllSqlUsersAlloc(context, cluster_id, &diagnostic);
        defer client_mod.freeSqlUsers(context.allocator, users);
        var exists = false;
        for (users) |user| {
            if (std.mem.eql(u8, user.name, username)) {
                exists = true;
                break;
            }
        }
        if (exists) {
            try self.client.resetSqlUserPassword(context, cluster_id, username, password, &diagnostic);
        } else {
            try self.client.createSqlUser(context, cluster_id, username, password, &diagnostic);
        }
        return sqlUserResult(context.allocator, node);
    }

    fn deleteSqlUser(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!void {
        const expected = try sqlUserPhysicalIdAlloc(context.allocator, node);
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        try self.client.deleteSqlUser(
            context,
            try inputString(node.inputs, "cluster_id"),
            try inputString(node.inputs, "username"),
            &diagnostic,
        );
    }

    fn readAuthorizedNetwork(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ReadResult {
        const cluster_id = try inputString(node.inputs, "cluster_id");
        const expected_ip = try resolveInputString(context, node.inputs, "ip_address");
        const expected_mask = try inputU8(node.inputs, "cidr_mask");
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        const entries = try self.client.listAllowlistEntriesAlloc(context, cluster_id, &diagnostic);
        defer client_mod.freeAllowlistEntries(context.allocator, entries);
        for (entries) |entry| {
            if (entry.cidr_mask == expected_mask and std.mem.eql(u8, entry.cidr_ip, expected_ip)) {
                return .{ .present = try authorizedNetworkResult(context, node, entry) };
            }
        }
        return .absent;
    }

    fn writeAuthorizedNetwork(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        update_existing: bool,
    ) ProviderError!provider_mod.ResourceResult {
        const cluster_id = try inputString(node.inputs, "cluster_id");
        const entry = client_mod.AllowlistEntry{
            .cidr_ip = try resolveInputString(context, node.inputs, "ip_address"),
            .cidr_mask = try inputU8(node.inputs, "cidr_mask"),
            .name = try inputString(node.inputs, "name"),
            .sql = try inputBoolean(node.inputs, "sql"),
            .ui = try inputBoolean(node.inputs, "ui"),
        };
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        if (update_existing) {
            try self.client.updateAllowlistEntry(context, cluster_id, entry, &diagnostic);
        } else {
            try self.client.putAllowlistEntry(context, cluster_id, entry, &diagnostic);
        }
        return authorizedNetworkResult(context, node, entry);
    }

    fn deleteAuthorizedNetwork(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!void {
        const expected = try authorizedNetworkPhysicalIdAlloc(context, node);
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        try self.client.deleteAllowlistEntry(
            context,
            try inputString(node.inputs, "cluster_id"),
            try resolveInputString(context, node.inputs, "ip_address"),
            try inputU8(node.inputs, "cidr_mask"),
            &diagnostic,
        );
    }

    fn sqlHandler(self: *LiveProvider) ProviderError!sql_provider.Handler {
        return .{
            .executor = self.sql_executor orelse return error.InvalidConfiguration,
            .secret_source = self.secret_source orelse return error.InvalidConfiguration,
            .retry_policy = self.sql_retry_policy,
            .migration_lock = &self.migration_lock,
        };
    }
};

fn clusterRegionResult(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    cluster: client_mod.Cluster,
) ProviderError!provider_mod.ResourceResult {
    const region_name = try inputString(node.inputs, "region");
    const region = findClusterRegion(cluster.regions, region_name) orelse return error.InvalidConfiguration;
    const cluster_input = try normalizedResolvedInput(context, node.inputs, "cluster_id", cluster.id);
    const fields = [_]value.Field{
        .{ .name = "cluster_id", .value = cluster_input },
        .{ .name = "region", .value = .{ .string = region.name } },
    };
    const physical_id = try privateRegionalPhysicalIdAlloc(context, node);
    defer context.allocator.free(physical_id);
    const outputs = [_]state.StateOutput{
        .{ .name = "cluster_id", .value = .{ .string = cluster.id } },
        .{ .name = "region", .value = .{ .string = region.name } },
        .{ .name = "sql_dns", .value = .{ .string = region.sql_dns } },
        .{ .name = "internal_dns", .value = .{ .string = region.internal_dns } },
        .{ .name = "private_endpoint_dns", .value = .{ .string = region.private_endpoint_dns } },
        .{ .name = "ui_dns", .value = .{ .string = region.ui_dns } },
        .{ .name = "node_count", .value = .{ .integer = region.node_count } },
        .{ .name = "primary", .value = .{ .boolean = region.primary orelse false } },
    };
    return provider_mod.ResourceResult.init(context.allocator, physical_id, .{ .object = &fields }, &outputs, null);
}

fn privateEndpointServiceResult(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    service: client_mod.PrivateEndpointService,
) ProviderError!provider_mod.ResourceResult {
    try validatePrivateEndpointService(service, try inputString(node.inputs, "region"));
    const cluster_id = try resolveInputString(context, node.inputs, "cluster_id");
    const fields = [_]value.Field{
        .{ .name = "cluster_id", .value = try normalizedResolvedInput(context, node.inputs, "cluster_id", cluster_id) },
        .{ .name = "plan", .value = .{ .string = try inputString(node.inputs, "plan") } },
        .{ .name = "region", .value = .{ .string = service.region_name } },
    };
    const physical_id = try privateRegionalPhysicalIdAlloc(context, node);
    defer context.allocator.free(physical_id);
    const outputs = [_]state.StateOutput{
        .{ .name = "service_attachment", .value = .{ .string = service.name } },
        .{ .name = "endpoint_service_id", .value = .{ .string = service.endpoint_service_id } },
        .{ .name = "region", .value = .{ .string = service.region_name } },
        .{ .name = "status", .value = .{ .string = service.status.apiName() } },
    };
    return provider_mod.ResourceResult.init(context.allocator, physical_id, .{ .object = &fields }, &outputs, null);
}

fn privateEndpointConnectionResult(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    connection: client_mod.PrivateEndpointConnection,
) ProviderError!provider_mod.ResourceResult {
    try validatePrivateEndpointConnection(context, node, connection);
    const expected_region = try inputString(node.inputs, "region");
    const cluster_id = try resolveInputString(context, node.inputs, "cluster_id");
    const fields = [_]value.Field{
        .{ .name = "cluster_id", .value = try normalizedResolvedInput(context, node.inputs, "cluster_id", cluster_id) },
        .{ .name = "endpoint_id", .value = try normalizedResolvedInput(context, node.inputs, "endpoint_id", connection.endpoint_id) },
        .{ .name = "endpoint_service_id", .value = try normalizedResolvedInput(context, node.inputs, "endpoint_service_id", connection.endpoint_service_id) },
        .{ .name = "region", .value = .{ .string = expected_region } },
    };
    const physical_id = try privateConnectionPhysicalIdAlloc(context, node);
    defer context.allocator.free(physical_id);
    const outputs = [_]state.StateOutput{
        .{ .name = "endpoint_id", .value = .{ .string = connection.endpoint_id } },
        .{ .name = "endpoint_service_id", .value = .{ .string = connection.endpoint_service_id } },
        .{ .name = "region", .value = .{ .string = expected_region } },
        .{ .name = "service_name", .value = .{ .string = connection.service_name } },
        .{ .name = "status", .value = .{ .string = connection.status.apiName() } },
    };
    return provider_mod.ResourceResult.init(context.allocator, physical_id, .{ .object = &fields }, &outputs, null);
}

fn validatePrivateEndpointConnection(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    connection: client_mod.PrivateEndpointConnection,
) ProviderError!void {
    const expected_endpoint = try resolveInputString(context, node.inputs, "endpoint_id");
    const expected_service = try resolveInputString(context, node.inputs, "endpoint_service_id");
    const expected_region = try inputString(node.inputs, "region");
    if (!std.mem.eql(u8, connection.cloud_provider, "GCP") or
        !std.mem.eql(u8, connection.endpoint_id, expected_endpoint) or
        !std.mem.eql(u8, connection.endpoint_service_id, expected_service) or
        !std.mem.eql(u8, connection.region_name orelse return error.InvalidConfiguration, expected_region) or
        !serviceAttachmentMatchesRegion(connection.service_name, expected_region))
    {
        return error.InvalidConfiguration;
    }
}

fn normalizedResolvedInput(
    context: *provider_mod.OperationContext,
    inputs: value.Value,
    name: []const u8,
    remote: []const u8,
) ProviderError!value.Value {
    const desired = try inputValue(inputs, name);
    const resolved = try resolveValueString(context, desired);
    return if (std.mem.eql(u8, resolved, remote)) desired else .{ .string = remote };
}

fn privateRegionalPhysicalIdAlloc(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
) ProviderError![]const u8 {
    return std.fmt.allocPrint(
        context.allocator,
        "{s}:{s}",
        .{ try resolveInputString(context, node.inputs, "cluster_id"), try inputString(node.inputs, "region") },
    ) catch return error.OutOfMemory;
}

fn privateConnectionPhysicalIdAlloc(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
) ProviderError![]const u8 {
    return std.fmt.allocPrint(
        context.allocator,
        "{s}:{s}",
        .{
            try resolveInputString(context, node.inputs, "cluster_id"),
            try resolveInputString(context, node.inputs, "endpoint_id"),
        },
    ) catch return error.OutOfMemory;
}

fn validateGcpCluster(cluster: client_mod.Cluster, expected_plan: ?[]const u8, region: []const u8) ProviderError!void {
    if (!std.mem.eql(u8, cluster.cloud_provider orelse return error.InvalidConfiguration, "GCP")) return error.InvalidConfiguration;
    if (expected_plan) |plan| {
        if (!std.mem.eql(u8, cluster.plan orelse return error.InvalidConfiguration, plan)) return error.InvalidConfiguration;
        if (!std.mem.eql(u8, plan, "STANDARD") and !std.mem.eql(u8, plan, "ADVANCED")) return error.InvalidConfiguration;
    }
    if (findClusterRegion(cluster.regions, region) == null) return error.InvalidConfiguration;
}

fn validatePrivateEndpointService(service: client_mod.PrivateEndpointService, expected_region: []const u8) ProviderError!void {
    if (!std.mem.eql(u8, service.cloud_provider, "GCP") or
        !std.mem.eql(u8, service.region_name, expected_region) or
        service.endpoint_service_id.len == 0 or
        !serviceAttachmentMatchesRegion(service.name, expected_region))
    {
        return error.InvalidConfiguration;
    }
}

fn serviceAttachmentMatchesRegion(name: []const u8, expected_region: []const u8) bool {
    const marker = "/regions/";
    const start = (std.mem.indexOf(u8, name, marker) orelse return false) + marker.len;
    const remainder = name[start..];
    const end = std.mem.indexOfScalar(u8, remainder, '/') orelse return false;
    return std.mem.eql(u8, remainder[0..end], expected_region) and
        std.mem.startsWith(u8, remainder[end..], "/serviceAttachments/");
}

fn findClusterRegion(regions: []const client_mod.Region, expected: []const u8) ?client_mod.Region {
    for (regions) |region| if (std.mem.eql(u8, region.name, expected)) return region;
    return null;
}

fn findPrivateEndpointService(
    services: []const client_mod.PrivateEndpointService,
    region: []const u8,
) ?client_mod.PrivateEndpointService {
    for (services) |service| if (std.mem.eql(u8, service.region_name, region)) return service;
    return null;
}

fn findPrivateEndpointConnection(
    connections: []const client_mod.PrivateEndpointConnection,
    endpoint_id: []const u8,
) ?client_mod.PrivateEndpointConnection {
    for (connections) |connection| if (std.mem.eql(u8, connection.endpoint_id, endpoint_id)) return connection;
    return null;
}

fn authorizedNetworkResult(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    entry: client_mod.AllowlistEntry,
) ProviderError!provider_mod.ResourceResult {
    const allocator = context.allocator;
    const desired_address = try inputValue(node.inputs, "ip_address");
    const resolved_address = try resolveValueString(context, desired_address);
    const address_value: value.Value = if (std.mem.eql(u8, resolved_address, entry.cidr_ip))
        desired_address
    else
        .{ .string = entry.cidr_ip };
    const fields = [_]value.Field{
        .{ .name = "cidr_mask", .value = .{ .integer = entry.cidr_mask } },
        .{ .name = "cluster_id", .value = .{ .string = try inputString(node.inputs, "cluster_id") } },
        .{ .name = "ip_address", .value = address_value },
        .{ .name = "name", .value = .{ .string = entry.name orelse "" } },
        .{ .name = "sql", .value = .{ .boolean = entry.sql } },
        .{ .name = "ui", .value = .{ .boolean = entry.ui } },
    };
    const physical_id = try authorizedNetworkPhysicalIdAlloc(context, node);
    defer allocator.free(physical_id);
    const cidr = try std.fmt.allocPrint(allocator, "{s}/{d}", .{ entry.cidr_ip, entry.cidr_mask });
    defer allocator.free(cidr);
    const outputs = [_]state.StateOutput{
        .{ .name = "cidr", .value = .{ .string = cidr } },
    };
    return provider_mod.ResourceResult.init(allocator, physical_id, .{ .object = &fields }, &outputs, null);
}

fn authorizedNetworkPhysicalIdAlloc(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
) ProviderError![]const u8 {
    return std.fmt.allocPrint(
        context.allocator,
        "clusters/{s}/networking/allowlist/{s}/{d}",
        .{
            try inputString(node.inputs, "cluster_id"),
            try resolveInputString(context, node.inputs, "ip_address"),
            try inputU8(node.inputs, "cidr_mask"),
        },
    ) catch return error.OutOfMemory;
}

fn authorizedNetworkDiff(
    allocator: std.mem.Allocator,
    desired: value.Value,
    observed: value.Value,
) ProviderError!provider_mod.DiffResult {
    inline for (&.{ "cluster_id", "cidr_mask", "ip_address" }) |field| {
        const desired_value = try inputValue(desired, field);
        const observed_value = try inputValue(observed, field);
        const desired_json = desired_value.canonicalJsonAlloc(allocator) catch return error.OutOfMemory;
        defer allocator.free(desired_json);
        const observed_json = observed_value.canonicalJsonAlloc(allocator) catch return error.OutOfMemory;
        defer allocator.free(observed_json);
        if (!std.mem.eql(u8, desired_json, observed_json)) {
            return provider_mod.DiffResult.init(allocator, .replace, &.{"authorized network identity changed"});
        }
    }
    return provider_mod.DiffResult.init(allocator, .update, &.{"authorized network flags changed"});
}

fn sqlUserResult(
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
) ProviderError!provider_mod.ResourceResult {
    const username = try inputString(node.inputs, "username");
    const physical_id = try sqlUserPhysicalIdAlloc(allocator, node);
    defer allocator.free(physical_id);
    const outputs = [_]state.StateOutput{
        .{ .name = "username", .value = .{ .string = username } },
    };
    return provider_mod.ResourceResult.init(allocator, physical_id, node.inputs, &outputs, null);
}

fn sqlUserPhysicalIdAlloc(
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
) ProviderError![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "clusters/{s}/sql-users/{s}",
        .{ try inputString(node.inputs, "cluster_id"), try inputString(node.inputs, "username") },
    ) catch return error.OutOfMemory;
}

fn sqlUserDiff(
    allocator: std.mem.Allocator,
    desired: value.Value,
    observed: value.Value,
) ProviderError!provider_mod.DiffResult {
    inline for (&.{ "cluster_id", "username" }) |field| {
        if (!std.mem.eql(u8, try inputString(desired, field), try inputString(observed, field))) {
            return provider_mod.DiffResult.init(allocator, .replace, &.{"SQL user identity changed"});
        }
    }
    return provider_mod.DiffResult.init(allocator, .update, &.{"connection secret changed"});
}

const ManagedSpec = struct {
    allocator: std.mem.Allocator,
    regions: []client_mod.ClusterRegionSpec,
    value: client_mod.ManagedClusterSpec,

    fn deinit(self: *ManagedSpec) void {
        self.allocator.free(self.regions);
        self.* = undefined;
    }
};

fn managedSpecFromInputsAlloc(allocator: std.mem.Allocator, inputs: value.Value) ProviderError!ManagedSpec {
    const plan_name = try inputString(inputs, "plan");
    const plan: client_mod.ClusterPlan = if (std.mem.eql(u8, plan_name, "BASIC"))
        .basic
    else if (std.mem.eql(u8, plan_name, "STANDARD"))
        .standard
    else if (std.mem.eql(u8, plan_name, "ADVANCED"))
        .advanced
    else
        return error.InvalidConfiguration;
    const region_values = try inputList(inputs, "regions");
    const regions = allocator.alloc(client_mod.ClusterRegionSpec, region_values.len) catch return error.OutOfMemory;
    errdefer allocator.free(regions);
    for (region_values, 0..) |region, index| {
        regions[index] = .{
            .name = try inputString(region, "name"),
            .node_count = try inputInteger(region, "node_count"),
            .primary = try inputBoolean(region, "primary"),
        };
    }
    return .{
        .allocator = allocator,
        .regions = regions,
        .value = .{
            .name = try inputString(inputs, "name"),
            .plan = plan,
            .protect = try inputBoolean(inputs, "protect"),
            .regions = regions,
            .provisioned_virtual_cpus = if (plan == .standard) try inputInteger(inputs, "provisioned_virtual_cpus") else null,
            .request_unit_limit = if (plan == .basic) positiveOptional(try inputInteger(inputs, "request_unit_limit")) else null,
            .storage_mib_limit = if (plan == .basic) positiveOptional(try inputInteger(inputs, "storage_mib_limit")) else null,
            .num_virtual_cpus = if (plan == .advanced) try inputInteger(inputs, "num_virtual_cpus") else null,
            .storage_gib = if (plan == .advanced) positiveOptional(try inputInteger(inputs, "storage_gib")) else null,
            .cockroach_version = if (plan == .advanced) nonEmptyOptional(try inputString(inputs, "cockroach_version")) else null,
            .private_network_visibility = if (plan == .advanced) try inputBoolean(inputs, "private_network_visibility") else false,
            .cidr_range = if (plan == .advanced) nonEmptyOptional(try inputString(inputs, "cidr_range")) else null,
        },
    };
}

fn managedClusterResult(
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    cluster: client_mod.Cluster,
) ProviderError!provider_mod.ResourceResult {
    const cloud_provider = cluster.cloud_provider orelse return error.ProviderBug;
    const plan = cluster.plan orelse return error.ProviderBug;
    const remote_state = cluster.state orelse return error.ProviderBug;
    const delete_protection = cluster.delete_protection orelse return error.ProviderBug;
    if (cluster.regions.len == 0) return error.ProviderBug;

    const sorted_regions = allocator.dupe(client_mod.Region, cluster.regions) catch return error.OutOfMemory;
    defer allocator.free(sorted_regions);
    std.mem.sort(client_mod.Region, sorted_regions, {}, lessThanClientRegion);
    const region_values = allocator.alloc(value.Value, sorted_regions.len) catch return error.OutOfMemory;
    defer allocator.free(region_values);
    const region_fields = allocator.alloc(value.Field, sorted_regions.len * 3) catch return error.OutOfMemory;
    defer allocator.free(region_fields);
    for (sorted_regions, 0..) |region, index| {
        const start = index * 3;
        region_fields[start..][0..3].* = .{
            .{ .name = "name", .value = .{ .string = region.name } },
            .{ .name = "node_count", .value = .{ .integer = region.node_count } },
            .{ .name = "primary", .value = .{ .boolean = region.primary orelse false } },
        };
        if (sorted_regions.len == 1 and !std.mem.eql(u8, plan, "ADVANCED")) {
            region_fields[start + 2].value = .{ .boolean = true };
        }
        region_values[index] = .{ .object = region_fields[start..][0..3] };
    }

    var observed_fields = std.ArrayList(value.Field).empty;
    defer observed_fields.deinit(allocator);
    if (std.mem.eql(u8, plan, "ADVANCED")) {
        const desired_cidr = inputStringOr(node.inputs, "cidr_range", "");
        const desired_version = inputStringOr(node.inputs, "cockroach_version", "");
        try observed_fields.appendSlice(allocator, &.{
            .{ .name = "cidr_range", .value = .{ .string = managedRemoteString(desired_cidr, cluster.cidr_range) } },
            .{ .name = "cloud_provider", .value = .{ .string = cloud_provider } },
            .{ .name = "cockroach_version", .value = .{ .string = managedRemoteVersion(desired_version, cluster.cockroach_version) } },
            .{ .name = "name", .value = .{ .string = cluster.name } },
            .{ .name = "num_virtual_cpus", .value = .{ .integer = cluster.num_virtual_cpus orelse 0 } },
            .{ .name = "plan", .value = .{ .string = plan } },
            .{ .name = "private_network_visibility", .value = .{ .boolean = cluster.private_network_visibility orelse false } },
            .{ .name = "protect", .value = .{ .boolean = std.mem.eql(u8, delete_protection, "ENABLED") } },
            .{ .name = "regions", .value = .{ .list = region_values } },
            .{ .name = "storage_gib", .value = .{ .integer = managedRemoteInteger(inputIntegerOr(node.inputs, "storage_gib", 0), cluster.storage_gib) } },
        });
    } else {
        const primary = primaryRegion(sorted_regions);
        try observed_fields.appendSlice(allocator, &.{
            .{ .name = "cloud_provider", .value = .{ .string = cloud_provider } },
            .{ .name = "name", .value = .{ .string = cluster.name } },
            .{ .name = "plan", .value = .{ .string = plan } },
            .{ .name = "primary_region", .value = .{ .string = primary.name } },
            .{ .name = "protect", .value = .{ .boolean = std.mem.eql(u8, delete_protection, "ENABLED") } },
        });
        if (std.mem.eql(u8, plan, "STANDARD")) {
            try observed_fields.append(allocator, .{ .name = "provisioned_virtual_cpus", .value = .{ .integer = cluster.provisioned_virtual_cpus orelse 0 } });
        }
        try observed_fields.append(allocator, .{ .name = "regions", .value = .{ .list = region_values } });
        if (std.mem.eql(u8, plan, "BASIC")) {
            try observed_fields.appendSlice(allocator, &.{
                .{ .name = "request_unit_limit", .value = .{ .integer = cluster.request_unit_limit orelse 0 } },
                .{ .name = "storage_mib_limit", .value = .{ .integer = cluster.storage_mib_limit orelse 0 } },
            });
        }
    }

    const region_names = allocator.alloc([]const u8, sorted_regions.len) catch return error.OutOfMemory;
    defer allocator.free(region_names);
    for (sorted_regions, 0..) |region, index| region_names[index] = region.name;
    const regions_csv = std.mem.join(allocator, ",", region_names) catch return error.OutOfMemory;
    defer allocator.free(regions_csv);
    const primary = primaryRegion(sorted_regions);
    const sql_dns = cluster.sql_dns orelse primary.sql_dns;
    const outputs = [_]state.StateOutput{
        .{ .name = "cluster_id", .value = .{ .string = cluster.id } },
        .{ .name = "name", .value = .{ .string = cluster.name } },
        .{ .name = "cloud_provider", .value = .{ .string = cloud_provider } },
        .{ .name = "plan", .value = .{ .string = plan } },
        .{ .name = "state", .value = .{ .string = remote_state } },
        .{ .name = "delete_protection", .value = .{ .boolean = std.mem.eql(u8, delete_protection, "ENABLED") } },
        .{ .name = "sql_dns", .value = .{ .string = sql_dns } },
        .{ .name = "regions", .value = .{ .string = regions_csv } },
        .{ .name = "primary_region", .value = .{ .string = primary.name } },
        .{ .name = "primary_sql_dns", .value = .{ .string = primary.sql_dns } },
        .{ .name = "primary_internal_dns", .value = .{ .string = primary.internal_dns } },
        .{ .name = "primary_private_endpoint_dns", .value = .{ .string = primary.private_endpoint_dns } },
    };
    return provider_mod.ResourceResult.init(
        allocator,
        cluster.id,
        .{ .object = observed_fields.items },
        &outputs,
        null,
    );
}

fn managedClusterDiff(
    allocator: std.mem.Allocator,
    desired: value.Value,
    observed: value.Value,
) ProviderError!provider_mod.DiffResult {
    if (try valuesEqualAlloc(allocator, desired, observed)) {
        return provider_mod.DiffResult.init(allocator, .noop, &.{});
    }
    inline for (&.{ "cloud_provider", "name" }) |field| {
        if (!std.mem.eql(u8, try inputString(desired, field), try inputString(observed, field))) {
            return provider_mod.DiffResult.init(allocator, .replace, &.{"cluster identity changed"});
        }
    }
    const desired_plan = try inputString(desired, "plan");
    const observed_plan = try inputString(observed, "plan");
    const desired_advanced = std.mem.eql(u8, desired_plan, "ADVANCED");
    const observed_advanced = std.mem.eql(u8, observed_plan, "ADVANCED");
    if (desired_advanced != observed_advanced) {
        return provider_mod.DiffResult.init(allocator, .replace, &.{"serverless and Advanced plans are not interchangeable"});
    }
    if (desired_advanced) {
        inline for (&.{ "cidr_range", "cockroach_version", "private_network_visibility" }) |field| {
            if (!try inputFieldEqualAlloc(allocator, desired, observed, field)) {
                return provider_mod.DiffResult.init(allocator, .replace, &.{"Advanced creation settings changed"});
            }
        }
    } else {
        const desired_regions = try inputRegionNamesAlloc(allocator, desired);
        defer allocator.free(desired_regions);
        const observed_regions = try inputRegionNamesAlloc(allocator, observed);
        defer allocator.free(observed_regions);
        for (observed_regions) |region| {
            if (!containsString(desired_regions, region)) {
                return provider_mod.DiffResult.init(allocator, .replace, &.{"serverless regions cannot be removed in place"});
            }
        }
    }
    return provider_mod.DiffResult.init(allocator, .update, &.{"managed cluster configuration changed"});
}

fn managedRemoteString(desired: []const u8, remote: ?[]const u8) []const u8 {
    if (desired.len == 0) return "";
    return remote orelse "";
}

fn managedRemoteVersion(desired: []const u8, remote: ?[]const u8) []const u8 {
    if (desired.len == 0) return "";
    const actual = remote orelse return "";
    return if (std.mem.startsWith(u8, actual, desired)) desired else actual;
}

fn managedRemoteInteger(desired: i64, remote: ?i64) i64 {
    if (desired == 0) return 0;
    return remote orelse 0;
}

fn valuesEqualAlloc(allocator: std.mem.Allocator, left: value.Value, right: value.Value) ProviderError!bool {
    const left_json = left.canonicalJsonAlloc(allocator) catch return error.OutOfMemory;
    defer allocator.free(left_json);
    const right_json = right.canonicalJsonAlloc(allocator) catch return error.OutOfMemory;
    defer allocator.free(right_json);
    return std.mem.eql(u8, left_json, right_json);
}

fn inputFieldEqualAlloc(
    allocator: std.mem.Allocator,
    left: value.Value,
    right: value.Value,
    field: []const u8,
) ProviderError!bool {
    return valuesEqualAlloc(allocator, try inputValue(left, field), try inputValue(right, field));
}

fn inputRegionNamesAlloc(allocator: std.mem.Allocator, inputs: value.Value) ProviderError![]const []const u8 {
    const regions = try inputList(inputs, "regions");
    const names = allocator.alloc([]const u8, regions.len) catch return error.OutOfMemory;
    errdefer allocator.free(names);
    for (regions, 0..) |region, index| names[index] = try inputString(region, "name");
    return names;
}

fn containsString(values: []const []const u8, expected: []const u8) bool {
    for (values) |item| if (std.mem.eql(u8, item, expected)) return true;
    return false;
}

fn lessThanClientRegion(_: void, left: client_mod.Region, right: client_mod.Region) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}

fn resultFromCluster(
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    cluster: client_mod.Cluster,
) ProviderError!provider_mod.ResourceResult {
    const declared_id = try inputString(node.inputs, "cluster_id");
    if (!std.mem.eql(u8, declared_id, cluster.id)) return error.ProviderBug;
    const cloud_provider = cluster.cloud_provider orelse return error.ProviderBug;
    const plan = cluster.plan orelse return error.ProviderBug;
    if (cluster.regions.len == 0) return error.ProviderBug;

    const region_names = try allocator.alloc([]const u8, cluster.regions.len);
    defer allocator.free(region_names);
    for (cluster.regions, 0..) |region, index| region_names[index] = region.name;
    std.mem.sort([]const u8, region_names, {}, lessThanString);
    const region_values = try allocator.alloc(value.Value, region_names.len);
    defer allocator.free(region_values);
    for (region_names, 0..) |name, index| region_values[index] = .{ .string = name };
    const observed_fields = [_]value.Field{
        .{ .name = "cloud_provider", .value = .{ .string = cloud_provider } },
        .{ .name = "cluster_id", .value = .{ .string = cluster.id } },
        .{ .name = "plan", .value = .{ .string = plan } },
        .{ .name = "regions", .value = .{ .list = region_values } },
    };

    const regions_csv = try std.mem.join(allocator, ",", region_names);
    defer allocator.free(regions_csv);
    const primary = primaryRegion(cluster.regions);
    const sql_dns = cluster.sql_dns orelse primary.sql_dns;
    const outputs = [_]state.StateOutput{
        .{ .name = "cluster_id", .value = .{ .string = cluster.id } },
        .{ .name = "name", .value = .{ .string = cluster.name } },
        .{ .name = "cloud_provider", .value = .{ .string = cloud_provider } },
        .{ .name = "plan", .value = .{ .string = plan } },
        .{ .name = "sql_dns", .value = .{ .string = sql_dns } },
        .{ .name = "regions", .value = .{ .string = regions_csv } },
        .{ .name = "primary_region", .value = .{ .string = primary.name } },
        .{ .name = "primary_sql_dns", .value = .{ .string = primary.sql_dns } },
        .{ .name = "primary_internal_dns", .value = .{ .string = primary.internal_dns } },
        .{ .name = "primary_private_endpoint_dns", .value = .{ .string = primary.private_endpoint_dns } },
    };
    return provider_mod.ResourceResult.init(
        allocator,
        cluster.id,
        .{ .object = &observed_fields },
        &outputs,
        null,
    );
}

fn topologyDiff(
    allocator: std.mem.Allocator,
    desired: value.Value,
    observed: value.Value,
) ProviderError!provider_mod.DiffResult {
    var reasons = std.ArrayList([]const u8).empty;
    defer reasons.deinit(allocator);
    defer for (reasons.items) |reason| allocator.free(reason);

    const desired_id = try inputString(desired, "cluster_id");
    const observed_id = try inputString(observed, "cluster_id");
    if (!std.mem.eql(u8, desired_id, observed_id)) {
        const reason = std.fmt.allocPrint(allocator, "cluster_id: expected {s}, observed {s}", .{ desired_id, observed_id }) catch return error.OutOfMemory;
        try appendOwnedReason(allocator, &reasons, reason);
        return provider_mod.DiffResult.init(allocator, .replace, reasons.items);
    }

    inline for (&.{ "cloud_provider", "plan" }) |field| {
        const expected = try inputString(desired, field);
        const actual = try inputString(observed, field);
        if (!std.mem.eql(u8, expected, actual)) {
            const reason = std.fmt.allocPrint(allocator, "{s}: expected {s}, observed {s}", .{ field, expected, actual }) catch return error.OutOfMemory;
            try appendOwnedReason(allocator, &reasons, reason);
        }
    }
    const expected_regions = try inputStringListAlloc(allocator, desired, "regions");
    defer allocator.free(expected_regions);
    const actual_regions = try inputStringListAlloc(allocator, observed, "regions");
    defer allocator.free(actual_regions);
    var compatibility = validation.regionCompatibilityAlloc(allocator, expected_regions, actual_regions) catch return error.OutOfMemory;
    defer compatibility.deinit();
    if (!compatibility.compatible()) {
        const reason = compatibility.reasonAlloc(allocator) catch return error.OutOfMemory;
        try appendOwnedReason(allocator, &reasons, reason);
    }
    return provider_mod.DiffResult.init(allocator, if (reasons.items.len == 0) .noop else .update, reasons.items);
}

fn appendOwnedReason(
    allocator: std.mem.Allocator,
    reasons: *std.ArrayList([]const u8),
    reason: []const u8,
) ProviderError!void {
    reasons.append(allocator, reason) catch |err| {
        allocator.free(reason);
        return err;
    };
}

fn inputString(input: value.Value, name: []const u8) ProviderError![]const u8 {
    const found = try inputValue(input, name);
    return switch (found) {
        .string => |text| text,
        else => error.InvalidConfiguration,
    };
}

fn inputStringOr(input: value.Value, name: []const u8, fallback: []const u8) []const u8 {
    return inputString(input, name) catch fallback;
}

fn inputValue(input: value.Value, name: []const u8) ProviderError!value.Value {
    const fields = switch (input) {
        .object => |fields| fields,
        else => return error.InvalidConfiguration,
    };
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field.value;
    }
    return error.InvalidConfiguration;
}

fn inputList(input: value.Value, name: []const u8) ProviderError![]const value.Value {
    return switch (try inputValue(input, name)) {
        .list => |items| if (items.len > 0) items else error.InvalidConfiguration,
        else => error.InvalidConfiguration,
    };
}

fn inputInteger(input: value.Value, name: []const u8) ProviderError!i64 {
    return switch (try inputValue(input, name)) {
        .integer => |integer| integer,
        else => error.InvalidConfiguration,
    };
}

fn inputIntegerOr(input: value.Value, name: []const u8, fallback: i64) i64 {
    return inputInteger(input, name) catch fallback;
}

fn inputU8(input: value.Value, name: []const u8) ProviderError!u8 {
    return switch (try inputValue(input, name)) {
        .integer => |integer| if (integer >= 0 and integer <= std.math.maxInt(u8)) @intCast(integer) else error.InvalidConfiguration,
        else => error.InvalidConfiguration,
    };
}

fn inputBoolean(input: value.Value, name: []const u8) ProviderError!bool {
    return switch (try inputValue(input, name)) {
        .boolean => |boolean| boolean,
        else => error.InvalidConfiguration,
    };
}

fn positiveOptional(number: i64) ?i64 {
    return if (number > 0) number else null;
}

fn nonEmptyOptional(text: []const u8) ?[]const u8 {
    return if (text.len > 0) text else null;
}

fn resolveInputString(
    context: *provider_mod.OperationContext,
    input: value.Value,
    name: []const u8,
) ProviderError![]const u8 {
    return resolveValueString(context, try inputValue(input, name));
}

fn resolveValueString(
    context: *provider_mod.OperationContext,
    input: value.Value,
) ProviderError![]const u8 {
    return switch (input) {
        .string => |text| text,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}

fn inputSecretReference(
    context: *provider_mod.OperationContext,
    input: value.Value,
    name: []const u8,
) ProviderError!value.SecretReference {
    const fields = switch (input) {
        .object => |fields| fields,
        else => return error.InvalidConfiguration,
    };
    for (fields) |field| {
        if (!std.mem.eql(u8, field.name, name)) continue;
        return switch (field.value) {
            .secret_ref => |reference| reference,
            .output_ref => |reference| try context.resolveOutputSecret(reference),
            else => error.InvalidConfiguration,
        };
    }
    return error.InvalidConfiguration;
}

fn inputStringListAlloc(
    allocator: std.mem.Allocator,
    input: value.Value,
    name: []const u8,
) ProviderError![]const []const u8 {
    const fields = switch (input) {
        .object => |fields| fields,
        else => return error.InvalidConfiguration,
    };
    for (fields) |field| {
        if (!std.mem.eql(u8, field.name, name)) continue;
        const items = switch (field.value) {
            .list => |items| items,
            else => return error.InvalidConfiguration,
        };
        if (items.len == 0) return error.InvalidConfiguration;
        const strings = allocator.alloc([]const u8, items.len) catch return error.OutOfMemory;
        errdefer allocator.free(strings);
        for (items, 0..) |item, index| {
            strings[index] = switch (item) {
                .string => |text| text,
                else => return error.InvalidConfiguration,
            };
        }
        return strings;
    }
    return error.InvalidConfiguration;
}

fn primaryRegion(regions: []const client_mod.Region) client_mod.Region {
    for (regions) |region| if (region.primary orelse false) return region;
    return regions[0];
}

pub fn supports(node: resource.ResourceNode) bool {
    return isType(node, cluster_type) or isType(node, existing_cluster_type) or isType(node, sql_user_type) or
        isType(node, authorized_network_type) or isPrivateEndpointType(node) or sql_provider.supports(node);
}

fn isSupported(node: resource.ResourceNode) bool {
    return supports(node);
}

fn isPrivateEndpointType(node: resource.ResourceNode) bool {
    return isType(node, cluster_region_type) or isType(node, private_endpoint_service_type) or
        isType(node, private_endpoint_connection_type);
}

fn isType(node: resource.ResourceNode, type_name: []const u8) bool {
    return std.mem.eql(u8, node.type_name, type_name);
}

fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
