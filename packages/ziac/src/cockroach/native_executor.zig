const std = @import("std");
const pg = @import("zigeffect_postgres");
const provider = @import("../provider.zig");
const psql_executor = @import("psql_executor.zig");
const sql = @import("sql.zig");

pub const NativeExecutor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: pg.Native.Options,
    pool: ?pg.Native.Pool = null,
    connection_hash: [32]u8 = [_]u8{0} ** 32,
    has_connection: bool = false,
    active_operations: usize = 0,
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: pg.Native.Options) NativeExecutor {
        return .{ .allocator = allocator, .io = io, .options = options };
    }

    pub fn deinit(self: *NativeExecutor) void {
        self.mutex.lockUncancelable(self.io);
        std.debug.assert(self.active_operations == 0);
        if (self.pool) |*pool| pool.deinit();
        std.crypto.secureZero(u8, &self.connection_hash);
        self.mutex.unlock(self.io);
        self.* = undefined;
    }

    pub fn executor(self: *NativeExecutor) sql.Executor {
        return .{ .ptr = self, .queryFn = query, .executeFn = execute };
    }

    fn query(
        raw: *anyopaque,
        context: *provider.OperationContext,
        connection_uri: []const u8,
        statement: []const u8,
        diagnostic: *sql.Diagnostic,
    ) sql.Error!sql.QueryResult {
        const self: *NativeExecutor = @ptrCast(@alignCast(raw));
        const pool = try self.beginOperation(connection_uri, context.nowMillis());
        defer self.endOperation();
        var native_diagnostic = pg.Native.Diagnostic{};
        var result = pool.queryDetailedAlloc(context.allocator, statement, &native_diagnostic, context.nowMillis()) catch |err| {
            copyDiagnostic(diagnostic, native_diagnostic);
            return mapNativeError(err, native_diagnostic);
        };
        defer result.deinit(context.allocator);
        copyDiagnostic(diagnostic, native_diagnostic);
        return psql_executor.queryResultFromPsqlAlloc(context.allocator, result);
    }

    fn execute(
        raw: *anyopaque,
        context: *provider.OperationContext,
        connection_uri: []const u8,
        statement: []const u8,
        diagnostic: *sql.Diagnostic,
    ) sql.Error!sql.ExecuteResult {
        const self: *NativeExecutor = @ptrCast(@alignCast(raw));
        const pool = try self.beginOperation(connection_uri, context.nowMillis());
        defer self.endOperation();
        var native_diagnostic = pg.Native.Diagnostic{};
        const affected = pool.executeDetailed(statement, &native_diagnostic, context.nowMillis()) catch |err| {
            copyDiagnostic(diagnostic, native_diagnostic);
            return mapNativeError(err, native_diagnostic);
        };
        copyDiagnostic(diagnostic, native_diagnostic);
        return .{ .rows_affected = affectedRows(affected) };
    }

    fn beginOperation(self: *NativeExecutor, connection_uri: []const u8, now_millis: u64) sql.Error!*pg.Native.Pool {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(connection_uri, &hash, .{});
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.has_connection or !std.mem.eql(u8, &self.connection_hash, &hash)) {
            if (self.active_operations != 0) return error.ConnectionFailed;
            const replacement = pg.Native.Pool.init(
                self.allocator,
                self.io,
                connection_uri,
                self.options,
                now_millis,
            ) catch |err| return mapNativeError(err, .{});
            if (self.pool) |*current| current.deinit();
            self.pool = replacement;
            self.connection_hash = hash;
            self.has_connection = true;
        }
        self.active_operations += 1;
        return &self.pool.?;
    }

    fn endOperation(self: *NativeExecutor) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.active_operations > 0);
        self.active_operations -= 1;
    }
};

pub fn classifyNativeFailure(sqlstate: []const u8, outcome: pg.Native.Outcome) sql.Error {
    _ = outcome;
    if (sqlstate.len == 5) {
        if (std.mem.eql(u8, sqlstate[0..2], "28")) return error.AuthenticationFailed;
        if (std.mem.eql(u8, sqlstate, "42501")) return error.AuthorizationFailed;
        if (std.mem.eql(u8, sqlstate[0..2], "08")) return error.ConnectionFailed;
        return error.QueryFailed;
    }
    return error.ConnectionFailed;
}

fn mapNativeError(err: anyerror, diagnostic: pg.Native.Diagnostic) sql.Error {
    if (diagnostic.sqlstateSlice()) |sqlstate| return classifyNativeFailure(sqlstate, diagnostic.outcome);
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (err == error.Canceled) return error.Cancelled;
    if (err == error.Timeout) return error.Timeout;
    if (err == error.UnsupportedColumnType) return error.QueryFailed;
    return error.ConnectionFailed;
}

fn copyDiagnostic(target: *sql.Diagnostic, source: pg.Native.Diagnostic) void {
    target.reset();
    target.outcome = switch (source.outcome) {
        .definite => .definite,
        .ambiguous => .ambiguous,
        .connection => .connection,
    };
    if (source.sqlstateSlice()) |sqlstate| target.setSqlstate(sqlstate) catch unreachable;
}

fn affectedRows(count: ?i64) ?u64 {
    const value = count orelse return null;
    return if (value >= 0) @intCast(value) else null;
}

test "native affected row counts reject invalid negative driver results" {
    try std.testing.expectEqual(@as(?u64, null), affectedRows(null));
    try std.testing.expectEqual(@as(?u64, null), affectedRows(-1));
    try std.testing.expectEqual(@as(?u64, 0), affectedRows(0));
    try std.testing.expectEqual(@as(?u64, 42), affectedRows(42));
}
