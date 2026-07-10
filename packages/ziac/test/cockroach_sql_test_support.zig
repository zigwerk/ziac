const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

pub const sql = ziac.cockroach.sql;

pub const Response = union(enum) {
    query: []const sql.Row,
    execute: sql.ExecuteResult,
    failure: Failure,
};

pub const Failure = struct {
    err: sql.Error,
    sqlstate: ?[]const u8 = null,
    outcome: sql.Outcome = .definite,
};

pub const Method = enum { query, execute };

pub const Operation = struct {
    method: Method,
    statement: []const u8,
};

pub const ScriptedExecutor = struct {
    allocator: std.mem.Allocator,
    responses: []const Response,
    cursor: usize = 0,
    operations: std.ArrayList(Operation) = .empty,

    pub fn init(allocator: std.mem.Allocator, responses: []const Response) ScriptedExecutor {
        return .{ .allocator = allocator, .responses = responses };
    }

    pub fn deinit(self: *ScriptedExecutor) void {
        for (self.operations.items) |operation| self.allocator.free(operation.statement);
        self.operations.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn executor(self: *ScriptedExecutor) sql.Executor {
        return .{ .ptr = self, .queryFn = query, .executeFn = execute };
    }

    fn query(
        raw: *anyopaque,
        context: *ziac.provider.OperationContext,
        connection_uri: []const u8,
        statement: []const u8,
        diagnostic: *sql.Diagnostic,
    ) sql.Error!sql.QueryResult {
        _ = connection_uri;
        const self: *ScriptedExecutor = @ptrCast(@alignCast(raw));
        try self.record(.query, statement);
        return switch (try self.next(diagnostic)) {
            .query => |rows| sql.QueryResult.initOwned(context.allocator, rows),
            else => error.QueryFailed,
        };
    }

    fn execute(
        raw: *anyopaque,
        context: *ziac.provider.OperationContext,
        connection_uri: []const u8,
        statement: []const u8,
        diagnostic: *sql.Diagnostic,
    ) sql.Error!sql.ExecuteResult {
        _ = connection_uri;
        _ = context;
        const self: *ScriptedExecutor = @ptrCast(@alignCast(raw));
        try self.record(.execute, statement);
        return switch (try self.next(diagnostic)) {
            .execute => |result| result,
            else => error.QueryFailed,
        };
    }

    fn next(self: *ScriptedExecutor, diagnostic: *sql.Diagnostic) sql.Error!Response {
        if (self.cursor >= self.responses.len) return error.QueryFailed;
        const response = self.responses[self.cursor];
        self.cursor += 1;
        return switch (response) {
            .failure => |failure| {
                diagnostic.outcome = failure.outcome;
                if (failure.sqlstate) |sqlstate| diagnostic.setSqlstate(sqlstate) catch return error.QueryFailed;
                return failure.err;
            },
            else => response,
        };
    }

    fn record(self: *ScriptedExecutor, method: Method, statement: []const u8) sql.Error!void {
        const owned = self.allocator.dupe(u8, statement) catch return error.OutOfMemory;
        self.operations.append(self.allocator, .{ .method = method, .statement = owned }) catch {
            self.allocator.free(owned);
            return error.OutOfMemory;
        };
    }
};

pub const Harness = struct {
    transport: @import("cockroach_client_test.zig").RecordingTransport,
    client: ziac.cockroach.client.Client,
    executor: ScriptedExecutor,
    secret_source: FixedSecretSource,
    live: ziac.cockroach.live_provider.LiveProvider,

    pub fn init(self: *Harness, responses: []const Response) void {
        self.transport = @import("cockroach_client_test.zig").RecordingTransport.init(std.testing.allocator, &.{});
        self.client = ziac.cockroach.client.Client.init(self.transport.client(), "dummy-key", .{});
        self.executor = ScriptedExecutor.init(std.testing.allocator, responses);
        self.secret_source = .{};
        self.live = ziac.cockroach.live_provider.LiveProvider.init(&self.client);
        self.live.secret_source = self.secret_source.secretSource();
        self.live.sql_executor = self.executor.executor();
        self.live.sql_retry_policy = .{ .max_attempts = 3, .base_delay_millis = 1, .max_delay_millis = 4 };
    }

    pub fn deinit(self: *Harness) void {
        self.executor.deinit();
        self.transport.deinit();
        self.* = undefined;
    }
};

pub const FixedSecretSource = struct {
    resolves: usize = 0,

    fn secretSource(self: *FixedSecretSource) ziac.secret.SecretSource {
        return .{ .ptr = self, .resolveFn = resolve };
    }

    fn resolve(
        raw: *anyopaque,
        _: *ziac.provider.OperationContext,
        allocator: std.mem.Allocator,
        reference: ziac.value.SecretReference,
    ) ziac.provider.ProviderError!ziac.secret.SecretPayload {
        const self: *FixedSecretSource = @ptrCast(@alignCast(raw));
        if (!std.mem.eql(u8, reference.provider, "gcp-secret-manager")) return error.NotFound;
        self.resolves += 1;
        return ziac.secret.SecretPayload.initOwned(
            allocator,
            "postgresql://app_user:sentinel-secret@db.example:26257/defaultdb?sslmode=verify-full",
            null,
        );
    }
};

pub fn secretState() !ziac.InMemoryStateStore {
    var store = ziac.InMemoryStateStore.init(std.testing.allocator);
    errdefer store.deinit();
    try store.put(.{
        .resource_id = "gcp.secretmanager.SecretVersion.database.initial",
        .provider = .gcp,
        .type_name = "gcp.secretmanager.SecretVersion",
        .logical_id = "initial",
        .physical_id = "projects/ziac-dev/secrets/database-url/versions/7",
        .desired_hash = "hash",
        .outputs = &.{.{ .name = "version", .value = .{ .secret_ref = .{
            .provider = "gcp-secret-manager",
            .resource = "projects/ziac-dev/secrets/database-url",
            .version = "7",
        } } }},
        .status = .created,
    });
    return store;
}

pub fn contextWithState(store: *ziac.InMemoryStateStore) ziac.provider.OperationContext {
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    context.state = store;
    return context;
}

pub fn boolRows(comptime value: bool) []const sql.Row {
    const Static = struct {
        const cells = [_]sql.Cell{.{ .name = "exists", .value = if (value) "true" else "false" }};
        const rows = [_]sql.Row{.{ .cells = &cells }};
    };
    return &Static.rows;
}

pub fn grantRows(comptime privileges: []const []const u8) []const sql.Row {
    const Static = struct {
        const cells = makeCells();
        const rows = makeRows();

        fn makeCells() [privileges.len][2]sql.Cell {
            var result_cells: [privileges.len][2]sql.Cell = undefined;
            for (privileges, 0..) |privilege, index| {
                result_cells[index] = .{
                    .{ .name = "grantee", .value = "app_user" },
                    .{ .name = "privilege_type", .value = privilege },
                };
            }
            return result_cells;
        }

        fn makeRows() [privileges.len]sql.Row {
            var result_rows: [privileges.len]sql.Row = undefined;
            for (0..privileges.len) |index| result_rows[index] = .{ .cells = &cells[index] };
            return result_rows;
        }
    };
    return &Static.rows;
}

pub const empty_rows: []const sql.Row = &.{};

pub fn connectionOutput() ziac.SecretOutput(ziac.value.SecretReference) {
    return ziac.SecretOutput(ziac.value.SecretReference).fromResource(
        "gcp.secretmanager.SecretVersion.database.initial",
        "version",
    );
}

pub fn noHttpResponse() zstd.Http.Response {
    return .{ .status = 500, .body = "{}" };
}
