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
const existing_cluster_type = "cockroach.Cluster.Existing";
const sql_user_type = "cockroach.SqlUser";
const authorized_network_type = "cockroach.AuthorizedNetwork";

pub const LiveProvider = struct {
    client: *client_mod.Client,
    secret_source: ?secret.SecretSource = null,
    sql_executor: ?sql.Executor = null,
    sql_retry_policy: sql_provider.RetryPolicy = .{},
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
        if (isType(node, sql_user_type)) return self.readSqlUser(context, node);
        if (isType(node, authorized_network_type)) return self.readAuthorizedNetwork(context, node);
        if (sql_provider.supports(node)) return (try self.sqlHandler()).read(context, node);
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
        if (isType(node, sql_user_type)) return sqlUserDiff(context.allocator, node.inputs, observed.observed_inputs);
        if (isType(node, authorized_network_type)) return authorizedNetworkDiff(context.allocator, node.inputs, observed.observed_inputs);
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
        if (isType(node, sql_user_type)) return self.ensureSqlUser(context, node);
        if (isType(node, authorized_network_type)) return self.writeAuthorizedNetwork(context, node, false);
        if (sql_provider.supports(node)) return (try self.sqlHandler()).create(context, node);
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

fn isSupported(node: resource.ResourceNode) bool {
    return isType(node, existing_cluster_type) or isType(node, sql_user_type) or
        isType(node, authorized_network_type) or sql_provider.supports(node);
}

fn isType(node: resource.ResourceNode, type_name: []const u8) bool {
    return std.mem.eql(u8, node.type_name, type_name);
}

fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
