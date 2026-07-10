const std = @import("std");
const pg = @import("zigeffect_postgres");
const zstd = @import("zigeffect_std");
const provider = @import("../provider.zig");
const sql = @import("sql.zig");

pub const PsqlExecutor = struct {
    io: std.Io,
    psql_path: []const u8 = "psql",

    pub fn executor(self: *PsqlExecutor) sql.Executor {
        return .{ .ptr = self, .queryFn = query, .executeFn = execute };
    }

    fn query(
        raw: *anyopaque,
        context: *provider.OperationContext,
        connection_uri: []const u8,
        statement: []const u8,
        diagnostic: *sql.Diagnostic,
    ) sql.Error!sql.QueryResult {
        const self: *PsqlExecutor = @ptrCast(@alignCast(raw));
        var client = pg.PsqlClient.init(.{ .url = connection_uri, .psql_path = self.psql_path }, self.io);
        var pg_diagnostic = pg.Diagnostic{};
        var result = client.queryDetailedAlloc(context.allocator, .{ .sql = statement }, &pg_diagnostic) catch |err| {
            copyDiagnostic(diagnostic, pg_diagnostic);
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return classifyFailure(pg_diagnostic.sqlstateSlice() orelse "", pg_diagnostic.outcome);
        };
        defer result.deinit(context.allocator);
        copyDiagnostic(diagnostic, pg_diagnostic);
        return queryResultFromPsqlAlloc(context.allocator, result);
    }

    fn execute(
        raw: *anyopaque,
        context: *provider.OperationContext,
        connection_uri: []const u8,
        statement: []const u8,
        diagnostic: *sql.Diagnostic,
    ) sql.Error!sql.ExecuteResult {
        const self: *PsqlExecutor = @ptrCast(@alignCast(raw));
        var client = pg.PsqlClient.init(.{ .url = connection_uri, .psql_path = self.psql_path }, self.io);
        var pg_diagnostic = pg.Diagnostic{};
        const command_output = client.executeRawDetailedAlloc(context.allocator, statement, &pg_diagnostic) catch |err| {
            copyDiagnostic(diagnostic, pg_diagnostic);
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return classifyFailure(pg_diagnostic.sqlstateSlice() orelse "", pg_diagnostic.outcome);
        };
        defer {
            std.crypto.secureZero(u8, command_output);
            context.allocator.free(command_output);
        }
        copyDiagnostic(diagnostic, pg_diagnostic);
        return .{};
    }
};

pub fn classifyFailure(sqlstate: []const u8, outcome: pg.Outcome) sql.Error {
    _ = outcome;
    if (sqlstate.len == 5) {
        if (std.mem.eql(u8, sqlstate[0..2], "28")) return error.AuthenticationFailed;
        if (std.mem.eql(u8, sqlstate, "42501")) return error.AuthorizationFailed;
        if (std.mem.eql(u8, sqlstate[0..2], "08")) return error.ConnectionFailed;
        return error.QueryFailed;
    }
    return error.ConnectionFailed;
}

pub fn queryResultFromPsqlAlloc(
    allocator: std.mem.Allocator,
    result: zstd.Sql.QueryResult,
) std.mem.Allocator.Error!sql.QueryResult {
    const rows = try allocator.alloc(sql.Row, result.rows.len);
    defer allocator.free(rows);
    var initialized: usize = 0;
    defer for (rows[0..initialized]) |row| freeTemporaryCells(allocator, row.cells);
    for (result.rows, 0..) |source_row, row_index| {
        const cells = try allocator.alloc(sql.Cell, source_row.fields.len);
        var cell_count: usize = 0;
        errdefer {
            for (cells[0..cell_count]) |cell| if (cell.value) |text| allocator.free(text);
            allocator.free(cells);
        }
        for (source_row.fields, 0..) |field, field_index| {
            cells[field_index] = .{
                .name = field.name,
                .value = try valueTextAlloc(allocator, field.value),
            };
            cell_count += 1;
        }
        rows[row_index] = .{ .cells = cells };
        initialized += 1;
    }
    return sql.QueryResult.initOwned(allocator, rows);
}

fn valueTextAlloc(allocator: std.mem.Allocator, input: zstd.Sql.Value) std.mem.Allocator.Error!?[]const u8 {
    return switch (input) {
        .null_value => null,
        .text => |text| try allocator.dupe(u8, text),
        .integer => |integer| try std.fmt.allocPrint(allocator, "{d}", .{integer}),
        .boolean => |boolean| try allocator.dupe(u8, if (boolean) "true" else "false"),
    };
}

fn freeTemporaryCells(allocator: std.mem.Allocator, cells: []const sql.Cell) void {
    for (cells) |cell| if (cell.value) |text| allocator.free(text);
    allocator.free(cells);
}

fn copyDiagnostic(target: *sql.Diagnostic, source: pg.Diagnostic) void {
    target.reset();
    target.outcome = switch (source.outcome) {
        .definite => .definite,
        .ambiguous => .ambiguous,
        .connection => .connection,
    };
    if (source.sqlstateSlice()) |sqlstate| target.setSqlstate(sqlstate) catch unreachable;
}
