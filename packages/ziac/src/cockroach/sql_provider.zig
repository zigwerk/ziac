const std = @import("std");
const fx = @import("zigeffect_std").fx;
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const secret = @import("../secret.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");
const sql = @import("sql.zig");

const ProviderError = provider_mod.ProviderError;
const database_type = "cockroach.Database";
const grants_type = "cockroach.Grants";
const migration_type = "cockroach.Migration";

const GrantList = struct {
    allocator: std.mem.Allocator,
    items: []const []const u8,

    fn deinit(self: *GrantList) void {
        for (self.items) |item| self.allocator.free(item);
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub const RetryPolicy = struct {
    max_attempts: usize = 4,
    base_delay_millis: u64 = 25,
    max_delay_millis: u64 = 1_000,
};

pub const Handler = struct {
    executor: sql.Executor,
    secret_source: secret.SecretSource,
    retry_policy: RetryPolicy,
    migration_lock: *fx.SpinLock,

    pub fn read(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ReadResult {
        if (isType(node, database_type)) return self.readDatabase(context, node);
        if (isType(node, grants_type)) return self.readGrants(context, node);
        if (isType(node, migration_type)) return self.readMigration(context, node);
        return error.InvalidConfiguration;
    }

    pub fn diff(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        observed: *const provider_mod.ResourceResult,
    ) ProviderError!provider_mod.DiffResult {
        _ = self;
        try context.checkActive();
        if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash)) {
            return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        }
        if (isType(node, database_type)) {
            if (identityChanged(node.inputs, observed.observed_inputs, &.{ "cluster_id", "name" })) {
                return provider_mod.DiffResult.init(context.allocator, .replace, &.{"database identity changed"});
            }
            return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        }
        if (isType(node, grants_type)) {
            if (identityChanged(node.inputs, observed.observed_inputs, &.{ "cluster_id", "database", "grantee" })) {
                return provider_mod.DiffResult.init(context.allocator, .replace, &.{"grant identity changed"});
            }
            return provider_mod.DiffResult.init(context.allocator, .update, &.{"database privileges changed"});
        }
        if (isType(node, migration_type)) {
            return provider_mod.DiffResult.init(context.allocator, .replace, &.{"applied migrations are immutable"});
        }
        return error.InvalidConfiguration;
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        if (isType(node, database_type)) return self.ensureDatabase(context, node);
        if (isType(node, grants_type)) return self.ensureGrants(context, node);
        if (isType(node, migration_type)) return self.ensureMigration(context, node);
        return error.InvalidConfiguration;
    }

    pub fn update(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        observed: *const provider_mod.ResourceResult,
    ) ProviderError!provider_mod.ResourceResult {
        if (isType(node, database_type)) return observed.clone(context.allocator);
        if (isType(node, grants_type)) return self.ensureGrants(context, node);
        return error.InvalidConfiguration;
    }

    pub fn delete(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!void {
        const expected = try physicalIdAlloc(context.allocator, node);
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        if (isType(node, migration_type)) return;
        if (isType(node, database_type)) return self.deleteDatabase(context, node);
        if (isType(node, grants_type)) return self.deleteGrants(context, node);
        return error.InvalidConfiguration;
    }

    pub fn importResource(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!provider_mod.ResourceResult {
        const expected = try physicalIdAlloc(context.allocator, node);
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        return switch (try self.read(context, node)) {
            .absent => error.NotFound,
            .present => |present| present,
        };
    }

    fn readDatabase(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ReadResult {
        var payload = try self.resolveConnection(context, node);
        defer payload.deinit();
        const statement = try databaseExistsSqlAlloc(context.allocator, try inputString(node.inputs, "name"));
        defer context.allocator.free(statement);
        var result = try self.queryWithRetry(context, payload.bytes, statement);
        defer result.deinit();
        if (!try existenceResult(result)) return .absent;
        return .{ .present = try desiredResult(context.allocator, node) };
    }

    fn ensureDatabase(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        var payload = try self.resolveConnection(context, node);
        defer payload.deinit();
        const exists_sql = try databaseExistsSqlAlloc(context.allocator, try inputString(node.inputs, "name"));
        defer context.allocator.free(exists_sql);
        var existing = try self.queryWithRetry(context, payload.bytes, exists_sql);
        defer existing.deinit();
        if (!try existenceResult(existing)) {
            const statement = try databaseMutationSqlAlloc(context.allocator, "CREATE DATABASE", try inputString(node.inputs, "name"));
            defer context.allocator.free(statement);
            _ = try self.executeWithRetry(context, payload.bytes, statement);
        }
        return desiredResult(context.allocator, node);
    }

    fn deleteDatabase(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!void {
        var payload = try self.resolveConnection(context, node);
        defer payload.deinit();
        const exists_sql = try databaseExistsSqlAlloc(context.allocator, try inputString(node.inputs, "name"));
        defer context.allocator.free(exists_sql);
        var existing = try self.queryWithRetry(context, payload.bytes, exists_sql);
        defer existing.deinit();
        if (!try existenceResult(existing)) return;
        const statement = try databaseMutationSqlAlloc(context.allocator, "DROP DATABASE", try inputString(node.inputs, "name"));
        defer context.allocator.free(statement);
        _ = try self.executeWithRetry(context, payload.bytes, statement);
    }

    fn readGrants(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ReadResult {
        var payload = try self.resolveConnection(context, node);
        defer payload.deinit();
        var grants = try self.fetchGrants(context, node, payload.bytes);
        defer grants.deinit();
        if (grants.items.len == 0) return .absent;
        return .{ .present = try grantsResult(context.allocator, node, grants.items) };
    }

    fn ensureGrants(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        var payload = try self.resolveConnection(context, node);
        defer payload.deinit();
        var remote = try self.fetchGrants(context, node, payload.bytes);
        defer remote.deinit();
        const desired = try inputStringsAlloc(context.allocator, node.inputs, "privileges");
        defer context.allocator.free(desired);
        const statement = try grantReconcileSqlAlloc(context.allocator, node, remote.items, desired, false);
        defer context.allocator.free(statement);
        if (statement.len != 0) _ = try self.executeWithRetry(context, payload.bytes, statement);
        return desiredResult(context.allocator, node);
    }

    fn deleteGrants(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!void {
        var payload = try self.resolveConnection(context, node);
        defer payload.deinit();
        var remote = try self.fetchGrants(context, node, payload.bytes);
        defer remote.deinit();
        const desired = try inputStringsAlloc(context.allocator, node.inputs, "privileges");
        defer context.allocator.free(desired);
        const statement = try grantReconcileSqlAlloc(context.allocator, node, remote.items, desired, true);
        defer context.allocator.free(statement);
        if (statement.len != 0) _ = try self.executeWithRetry(context, payload.bytes, statement);
    }

    fn readMigration(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ReadResult {
        var payload = try self.resolveConnection(context, node);
        defer payload.deinit();
        return self.readMigrationWithConnection(context, node, payload.bytes);
    }

    fn readMigrationWithConnection(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        connection_uri: []const u8,
    ) ProviderError!provider_mod.ReadResult {
        const table_exists_statement = try migrationTableExistsSqlAlloc(context.allocator, try inputString(node.inputs, "table"));
        defer context.allocator.free(table_exists_statement);
        var table_exists = try self.queryWithRetry(context, connection_uri, table_exists_statement);
        defer table_exists.deinit();
        if (!try existenceResult(table_exists)) return .absent;
        const statement = try migrationChecksumSqlAlloc(context.allocator, node);
        defer context.allocator.free(statement);
        var result = try self.queryWithRetry(context, connection_uri, statement);
        defer result.deinit();
        if (result.rows.len == 0) return .absent;
        if (result.rows.len != 1) return error.ProviderBug;
        const checksum = result.rows[0].get("checksum") orelse return error.ProviderBug;
        if (!std.mem.eql(u8, checksum, try inputString(node.inputs, "checksum"))) return error.Conflict;
        return .{ .present = try desiredResult(context.allocator, node) };
    }

    fn ensureMigration(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        self.migration_lock.lock();
        defer self.migration_lock.unlock();
        var payload = try self.resolveConnection(context, node);
        defer payload.deinit();
        switch (try self.readMigrationWithConnection(context, node, payload.bytes)) {
            .present => |present| return present,
            .absent => {},
        }
        const transaction = try migrationTransactionSqlAlloc(context.allocator, node);
        defer context.allocator.free(transaction);
        _ = try self.executeWithRetry(context, payload.bytes, transaction);
        return desiredResult(context.allocator, node);
    }

    fn fetchGrants(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        connection_uri: []const u8,
    ) ProviderError!GrantList {
        const statement = try showGrantsSqlAlloc(context.allocator, try inputString(node.inputs, "database"));
        defer context.allocator.free(statement);
        var result = try self.queryWithRetry(context, connection_uri, statement);
        defer result.deinit();
        var privileges: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (privileges.items) |privilege| context.allocator.free(privilege);
            privileges.deinit(context.allocator);
        }
        const expected_grantee = try inputString(node.inputs, "grantee");
        for (result.rows) |row| {
            const grantee = row.get("grantee") orelse return error.ProviderBug;
            if (!std.mem.eql(u8, grantee, expected_grantee)) continue;
            const privilege = row.get("privilege_type") orelse return error.ProviderBug;
            if (!validPrivilege(privilege)) return error.ProviderBug;
            const owned = context.allocator.dupe(u8, privilege) catch return error.OutOfMemory;
            privileges.append(context.allocator, owned) catch {
                context.allocator.free(owned);
                return error.OutOfMemory;
            };
        }
        std.mem.sort([]const u8, privileges.items, {}, stringLessThan);
        return .{
            .allocator = context.allocator,
            .items = try privileges.toOwnedSlice(context.allocator),
        };
    }

    fn resolveConnection(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!secret.SecretPayload {
        return self.secret_source.resolve(
            context,
            context.allocator,
            try inputSecretReference(context, node.inputs, "connection_secret"),
        );
    }

    fn queryWithRetry(self: Handler, context: *provider_mod.OperationContext, connection_uri: []const u8, statement: []const u8) ProviderError!sql.QueryResult {
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            try context.checkActive();
            var diagnostic = sql.Diagnostic{};
            return self.executor.query(context, connection_uri, statement, &diagnostic) catch |err| {
                if (shouldRetry(self.retry_policy, diagnostic, attempt)) {
                    context.sleep(retryDelay(self.retry_policy, attempt));
                    continue;
                }
                return mapSqlError(err, diagnostic);
            };
        }
    }

    fn executeWithRetry(self: Handler, context: *provider_mod.OperationContext, connection_uri: []const u8, statement: []const u8) ProviderError!sql.ExecuteResult {
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            try context.checkActive();
            var diagnostic = sql.Diagnostic{};
            return self.executor.execute(context, connection_uri, statement, &diagnostic) catch |err| {
                if (shouldRetry(self.retry_policy, diagnostic, attempt)) {
                    context.sleep(retryDelay(self.retry_policy, attempt));
                    continue;
                }
                return mapSqlError(err, diagnostic);
            };
        }
    }
};

pub fn supports(node: resource.ResourceNode) bool {
    return isType(node, database_type) or isType(node, grants_type) or isType(node, migration_type);
}

fn databaseExistsSqlAlloc(allocator: std.mem.Allocator, name: []const u8) ProviderError![]const u8 {
    const literal = sql.quoteLiteralAlloc(allocator, name) catch |err| return mapSqlTextError(err);
    defer allocator.free(literal);
    return std.fmt.allocPrint(allocator, "SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = {s}) AS exists", .{literal}) catch return error.OutOfMemory;
}

fn databaseMutationSqlAlloc(allocator: std.mem.Allocator, action: []const u8, name: []const u8) ProviderError![]const u8 {
    const identifier = sql.quoteIdentifierAlloc(allocator, name) catch |err| return mapSqlTextError(err);
    defer allocator.free(identifier);
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ action, identifier }) catch return error.OutOfMemory;
}

fn showGrantsSqlAlloc(allocator: std.mem.Allocator, database: []const u8) ProviderError![]const u8 {
    const identifier = sql.quoteIdentifierAlloc(allocator, database) catch |err| return mapSqlTextError(err);
    defer allocator.free(identifier);
    return std.fmt.allocPrint(allocator, "SHOW GRANTS ON DATABASE {s}", .{identifier}) catch return error.OutOfMemory;
}

fn migrationTableExistsSqlAlloc(allocator: std.mem.Allocator, table: []const u8) ProviderError![]const u8 {
    const table_name = sql.quoteLiteralAlloc(allocator, table) catch |err| return mapSqlTextError(err);
    defer allocator.free(table_name);
    return std.fmt.allocPrint(
        allocator,
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = current_schema() AND table_name = {s}) AS exists",
        .{table_name},
    ) catch return error.OutOfMemory;
}

fn migrationChecksumSqlAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]const u8 {
    const table = sql.quoteIdentifierAlloc(allocator, try inputString(node.inputs, "table")) catch |err| return mapSqlTextError(err);
    defer allocator.free(table);
    const migration_id = sql.quoteLiteralAlloc(allocator, try inputString(node.inputs, "id")) catch |err| return mapSqlTextError(err);
    defer allocator.free(migration_id);
    return std.fmt.allocPrint(
        allocator,
        "SELECT checksum FROM {s} WHERE id = {s}",
        .{ table, migration_id },
    ) catch return error.OutOfMemory;
}

fn migrationTransactionSqlAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]const u8 {
    const table_name = try inputString(node.inputs, "table");
    const lock_name = std.fmt.allocPrint(allocator, "{s}_lock", .{table_name}) catch return error.OutOfMemory;
    defer allocator.free(lock_name);
    const table = sql.quoteIdentifierAlloc(allocator, table_name) catch |err| return mapSqlTextError(err);
    defer allocator.free(table);
    const lock_table = sql.quoteIdentifierAlloc(allocator, lock_name) catch |err| return mapSqlTextError(err);
    defer allocator.free(lock_table);
    const migration_id = sql.quoteLiteralAlloc(allocator, try inputString(node.inputs, "id")) catch |err| return mapSqlTextError(err);
    defer allocator.free(migration_id);
    const checksum = sql.quoteLiteralAlloc(allocator, try inputString(node.inputs, "checksum")) catch |err| return mapSqlTextError(err);
    defer allocator.free(checksum);
    const migration_sql = try inputString(node.inputs, "sql");
    return std.fmt.allocPrint(
        allocator,
        "BEGIN;\nCREATE TABLE IF NOT EXISTS {s} (id STRING PRIMARY KEY, checksum STRING NOT NULL, applied_at TIMESTAMPTZ NOT NULL DEFAULT now());\nCREATE TABLE IF NOT EXISTS {s} (id INT PRIMARY KEY CHECK (id = 1));\nUPSERT INTO {s} (id) VALUES (1);\nSELECT id FROM {s} WHERE id = 1 FOR UPDATE;\n{s}{s}\nINSERT INTO {s} (id, checksum) VALUES ({s}, {s});\nCOMMIT;",
        .{ table, lock_table, lock_table, lock_table, migration_sql, if (std.mem.endsWith(u8, std.mem.trim(u8, migration_sql, " \r\n\t"), ";")) "" else ";", table, migration_id, checksum },
    ) catch return error.OutOfMemory;
}

fn grantReconcileSqlAlloc(
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    remote: []const []const u8,
    desired: []const []const u8,
    deleting: bool,
) ProviderError![]const u8 {
    var grants: std.ArrayList([]const u8) = .empty;
    defer grants.deinit(allocator);
    var revokes: std.ArrayList([]const u8) = .empty;
    defer revokes.deinit(allocator);
    if (!deleting) for (desired) |privilege| {
        if (!containsString(remote, privilege)) try grants.append(allocator, privilege);
    };
    for (remote) |privilege| {
        if ((deleting and containsString(desired, privilege)) or (!deleting and !containsString(desired, privilege))) {
            try revokes.append(allocator, privilege);
        }
    }
    if (grants.items.len == 0 and revokes.items.len == 0) return allocator.dupe(u8, "") catch return error.OutOfMemory;
    const database = sql.quoteIdentifierAlloc(allocator, try inputString(node.inputs, "database")) catch |err| return mapSqlTextError(err);
    defer allocator.free(database);
    const grantee = sql.quoteIdentifierAlloc(allocator, try inputString(node.inputs, "grantee")) catch |err| return mapSqlTextError(err);
    defer allocator.free(grantee);
    var output_bytes: std.ArrayList(u8) = .empty;
    errdefer output_bytes.deinit(allocator);
    if (grants.items.len != 0) {
        try output_bytes.appendSlice(allocator, "GRANT ");
        try appendJoined(&output_bytes, allocator, grants.items);
        try output_bytes.print(allocator, " ON DATABASE {s} TO {s};", .{ database, grantee });
    }
    if (revokes.items.len != 0) {
        if (output_bytes.items.len != 0) try output_bytes.append(allocator, '\n');
        try output_bytes.appendSlice(allocator, "REVOKE ");
        try appendJoined(&output_bytes, allocator, revokes.items);
        try output_bytes.print(allocator, " ON DATABASE {s} FROM {s};", .{ database, grantee });
    }
    return output_bytes.toOwnedSlice(allocator);
}

fn appendJoined(output_bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, values: []const []const u8) std.mem.Allocator.Error!void {
    for (values, 0..) |item, index| {
        if (index != 0) try output_bytes.appendSlice(allocator, ", ");
        try output_bytes.appendSlice(allocator, item);
    }
}

fn existenceResult(result: sql.QueryResult) ProviderError!bool {
    if (result.rows.len != 1) return error.ProviderBug;
    const exists = result.rows[0].get("exists") orelse return error.ProviderBug;
    if (std.mem.eql(u8, exists, "true") or std.mem.eql(u8, exists, "t")) return true;
    if (std.mem.eql(u8, exists, "false") or std.mem.eql(u8, exists, "f")) return false;
    return error.ProviderBug;
}

fn desiredResult(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
    const physical_id = try physicalIdAlloc(allocator, node);
    defer allocator.free(physical_id);
    var outputs: [2]state.StateOutput = undefined;
    const output_count: usize = if (isType(node, database_type)) blk: {
        outputs[0] = .{ .name = "name", .value = .{ .string = try inputString(node.inputs, "name") } };
        break :blk 1;
    } else if (isType(node, grants_type)) blk: {
        outputs[0] = .{ .name = "grantee", .value = .{ .string = try inputString(node.inputs, "grantee") } };
        break :blk 1;
    } else blk: {
        outputs[0] = .{ .name = "applied_id", .value = .{ .string = try inputString(node.inputs, "id") } };
        outputs[1] = .{ .name = "checksum", .value = .{ .string = try inputString(node.inputs, "checksum") } };
        break :blk 2;
    };
    return provider_mod.ResourceResult.init(allocator, physical_id, node.inputs, outputs[0..output_count], null);
}

fn grantsResult(
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    privileges: []const []const u8,
) ProviderError!provider_mod.ResourceResult {
    const values = try allocator.alloc(value.Value, privileges.len);
    defer allocator.free(values);
    for (privileges, 0..) |privilege, index| values[index] = .{ .string = privilege };
    const fields = [_]value.Field{
        .{ .name = "cluster_id", .value = .{ .string = try inputString(node.inputs, "cluster_id") } },
        .{ .name = "connection_secret", .value = try inputValue(node.inputs, "connection_secret") },
        .{ .name = "database", .value = .{ .string = try inputString(node.inputs, "database") } },
        .{ .name = "grantee", .value = .{ .string = try inputString(node.inputs, "grantee") } },
        .{ .name = "privileges", .value = .{ .list = values } },
    };
    const physical_id = try physicalIdAlloc(allocator, node);
    defer allocator.free(physical_id);
    const outputs = [_]state.StateOutput{.{ .name = "grantee", .value = .{ .string = try inputString(node.inputs, "grantee") } }};
    return provider_mod.ResourceResult.init(allocator, physical_id, .{ .object = &fields }, &outputs, null);
}

fn physicalIdAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]const u8 {
    if (isType(node, database_type)) return std.fmt.allocPrint(allocator, "clusters/{s}/databases/{s}", .{
        try inputString(node.inputs, "cluster_id"),
        try inputString(node.inputs, "name"),
    }) catch return error.OutOfMemory;
    if (isType(node, grants_type)) return std.fmt.allocPrint(allocator, "clusters/{s}/databases/{s}/grants/{s}", .{
        try inputString(node.inputs, "cluster_id"),
        try inputString(node.inputs, "database"),
        try inputString(node.inputs, "grantee"),
    }) catch return error.OutOfMemory;
    if (isType(node, migration_type)) return std.fmt.allocPrint(allocator, "clusters/{s}/databases/{s}/migrations/{s}", .{
        try inputString(node.inputs, "cluster_id"),
        try inputString(node.inputs, "database"),
        try inputString(node.inputs, "id"),
    }) catch return error.OutOfMemory;
    return error.InvalidConfiguration;
}

fn shouldRetry(policy: RetryPolicy, diagnostic: sql.Diagnostic, attempt: usize) bool {
    return policy.max_attempts > 0 and attempt + 1 < policy.max_attempts and
        diagnostic.outcome == .definite and
        diagnostic.sqlstateSlice() != null and
        std.mem.eql(u8, diagnostic.sqlstateSlice().?, "40001");
}

fn retryDelay(policy: RetryPolicy, attempt: usize) u64 {
    var delay = policy.base_delay_millis;
    var index: usize = 0;
    while (index < attempt and delay < policy.max_delay_millis) : (index += 1) {
        delay = @min(policy.max_delay_millis, std.math.mul(u64, delay, 2) catch policy.max_delay_millis);
    }
    return delay;
}

fn mapSqlError(err: sql.Error, diagnostic: sql.Diagnostic) ProviderError {
    if (diagnostic.outcome == .ambiguous or (diagnostic.sqlstateSlice() != null and
        std.mem.eql(u8, diagnostic.sqlstateSlice().?, "40003"))) return error.Conflict;
    return switch (err) {
        error.AuthenticationFailed => error.AuthenticationFailed,
        error.AuthorizationFailed => error.AuthorizationFailed,
        error.ConnectionFailed => error.TransientFailure,
        error.QueryFailed => error.InvalidConfiguration,
        error.Timeout => error.ProviderTimeout,
        error.Cancelled => error.ProviderCancelled,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn mapSqlTextError(err: sql.SqlTextError) ProviderError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidIdentifier, error.InvalidLiteral => error.InvalidConfiguration,
    };
}

fn inputSecretReference(
    context: *provider_mod.OperationContext,
    input: value.Value,
    name: []const u8,
) ProviderError!value.SecretReference {
    return switch (try inputValue(input, name)) {
        .secret_ref => |reference| reference,
        .output_ref => |reference| context.resolveOutputSecret(reference),
        else => error.InvalidConfiguration,
    };
}

fn inputStringsAlloc(allocator: std.mem.Allocator, input: value.Value, name: []const u8) ProviderError![]const []const u8 {
    const items = switch (try inputValue(input, name)) {
        .list => |items| items,
        else => return error.InvalidConfiguration,
    };
    const strings = allocator.alloc([]const u8, items.len) catch return error.OutOfMemory;
    for (items, 0..) |item, index| strings[index] = switch (item) {
        .string => |text| text,
        else => {
            allocator.free(strings);
            return error.InvalidConfiguration;
        },
    };
    return strings;
}

fn inputValue(input: value.Value, name: []const u8) ProviderError!value.Value {
    const fields = switch (input) {
        .object => |fields| fields,
        else => return error.InvalidConfiguration,
    };
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return error.InvalidConfiguration;
}

fn inputString(input: value.Value, name: []const u8) ProviderError![]const u8 {
    return switch (try inputValue(input, name)) {
        .string => |text| text,
        else => error.InvalidConfiguration,
    };
}

fn identityChanged(desired: value.Value, observed: value.Value, fields: []const []const u8) bool {
    for (fields) |field| {
        const left = inputString(desired, field) catch return true;
        const right = inputString(observed, field) catch return true;
        if (!std.mem.eql(u8, left, right)) return true;
    }
    return false;
}

fn validPrivilege(privilege: []const u8) bool {
    return inline for (&.{ "ALL", "CONNECT", "CREATE", "DROP" }) |valid| {
        if (std.mem.eql(u8, valid, privilege)) break true;
    } else false;
}

fn containsString(values: []const []const u8, expected: []const u8) bool {
    for (values) |item| if (std.mem.eql(u8, item, expected)) return true;
    return false;
}

fn stringLessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn isType(node: resource.ResourceNode, type_name: []const u8) bool {
    return std.mem.eql(u8, node.type_name, type_name);
}
