const std = @import("std");
const output = @import("../output.zig");
const provider = @import("../provider.zig");
const value = @import("../value.zig");

pub const Error = error{
    AuthenticationFailed,
    AuthorizationFailed,
    ConnectionFailed,
    QueryFailed,
    Timeout,
    Cancelled,
    OutOfMemory,
};

pub const Outcome = enum {
    definite,
    ambiguous,
    connection,
};

pub const Diagnostic = struct {
    sqlstate: ?[5]u8 = null,
    outcome: Outcome = .definite,

    pub fn setSqlstate(self: *Diagnostic, sqlstate: []const u8) error{InvalidSqlstate}!void {
        if (sqlstate.len != 5) return error.InvalidSqlstate;
        for (sqlstate) |byte| if (!std.ascii.isAlphanumeric(byte)) return error.InvalidSqlstate;
        var owned: [5]u8 = undefined;
        @memcpy(&owned, sqlstate);
        self.sqlstate = owned;
    }

    pub fn sqlstateSlice(self: *const Diagnostic) ?[]const u8 {
        return if (self.sqlstate) |*sqlstate| sqlstate else null;
    }

    pub fn reset(self: *Diagnostic) void {
        self.* = .{};
    }
};

pub const Cell = struct {
    name: []const u8,
    value: ?[]const u8,

    fn clone(self: Cell, allocator: std.mem.Allocator) std.mem.Allocator.Error!Cell {
        const name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name);
        return .{
            .name = name,
            .value = if (self.value) |text| try allocator.dupe(u8, text) else null,
        };
    }

    fn deinit(self: *Cell, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.value) |text| allocator.free(text);
        self.* = undefined;
    }
};

pub const Row = struct {
    cells: []const Cell,

    pub fn get(self: Row, name: []const u8) ?[]const u8 {
        for (self.cells) |cell| if (std.mem.eql(u8, cell.name, name)) return cell.value;
        return null;
    }

    fn clone(self: Row, allocator: std.mem.Allocator) std.mem.Allocator.Error!Row {
        const cells = try allocator.alloc(Cell, self.cells.len);
        errdefer allocator.free(cells);
        var initialized: usize = 0;
        errdefer for (cells[0..initialized]) |*cell| cell.deinit(allocator);
        for (self.cells, 0..) |cell, index| {
            cells[index] = try cell.clone(allocator);
            initialized += 1;
        }
        return .{ .cells = cells };
    }

    fn deinit(self: *Row, allocator: std.mem.Allocator) void {
        for (self.cells) |cell| {
            var owned = cell;
            owned.deinit(allocator);
        }
        allocator.free(self.cells);
        self.* = undefined;
    }
};

pub const QueryResult = struct {
    allocator: std.mem.Allocator,
    rows: []const Row,

    pub fn initOwned(allocator: std.mem.Allocator, rows: []const Row) std.mem.Allocator.Error!QueryResult {
        const owned = try allocator.alloc(Row, rows.len);
        errdefer allocator.free(owned);
        var initialized: usize = 0;
        errdefer for (owned[0..initialized]) |*row| row.deinit(allocator);
        for (rows, 0..) |row, index| {
            owned[index] = try row.clone(allocator);
            initialized += 1;
        }
        return .{ .allocator = allocator, .rows = owned };
    }

    pub fn empty(allocator: std.mem.Allocator) std.mem.Allocator.Error!QueryResult {
        return initOwned(allocator, &.{});
    }

    pub fn deinit(self: *QueryResult) void {
        for (self.rows) |row| {
            var owned = row;
            owned.deinit(self.allocator);
        }
        self.allocator.free(self.rows);
        self.* = undefined;
    }
};

pub const ExecuteResult = struct {
    rows_affected: ?u64 = null,
};

pub const Executor = struct {
    ptr: *anyopaque,
    queryFn: *const fn (
        *anyopaque,
        *provider.OperationContext,
        []const u8,
        []const u8,
        *Diagnostic,
    ) Error!QueryResult,
    executeFn: *const fn (
        *anyopaque,
        *provider.OperationContext,
        []const u8,
        []const u8,
        *Diagnostic,
    ) Error!ExecuteResult,

    pub fn query(
        self: Executor,
        context: *provider.OperationContext,
        connection_uri: []const u8,
        statement: []const u8,
        diagnostic: *Diagnostic,
    ) Error!QueryResult {
        diagnostic.reset();
        return self.queryFn(self.ptr, context, connection_uri, statement, diagnostic);
    }

    pub fn execute(
        self: Executor,
        context: *provider.OperationContext,
        connection_uri: []const u8,
        statement: []const u8,
        diagnostic: *Diagnostic,
    ) Error!ExecuteResult {
        diagnostic.reset();
        return self.executeFn(self.ptr, context, connection_uri, statement, diagnostic);
    }
};

pub const SqlTextError = error{ InvalidIdentifier, InvalidLiteral } || std.mem.Allocator.Error;

pub fn validateIdentifier(identifier: []const u8) error{InvalidIdentifier}!void {
    if (identifier.len == 0 or identifier.len > 128 or std.mem.indexOfScalar(u8, identifier, 0) != null or
        !std.unicode.utf8ValidateSlice(identifier)) return error.InvalidIdentifier;
}

pub fn quoteIdentifierAlloc(allocator: std.mem.Allocator, identifier: []const u8) SqlTextError![]const u8 {
    try validateIdentifier(identifier);
    var output_bytes: std.ArrayList(u8) = .empty;
    errdefer output_bytes.deinit(allocator);
    try output_bytes.append(allocator, '"');
    for (identifier) |byte| {
        if (byte == '"') try output_bytes.append(allocator, '"');
        try output_bytes.append(allocator, byte);
    }
    try output_bytes.append(allocator, '"');
    return output_bytes.toOwnedSlice(allocator);
}

pub fn quoteLiteralAlloc(allocator: std.mem.Allocator, literal: []const u8) SqlTextError![]const u8 {
    if (std.mem.indexOfScalar(u8, literal, 0) != null or !std.unicode.utf8ValidateSlice(literal)) return error.InvalidLiteral;
    var output_bytes: std.ArrayList(u8) = .empty;
    errdefer output_bytes.deinit(allocator);
    try output_bytes.append(allocator, '\'');
    for (literal) |byte| {
        if (byte == '\'') try output_bytes.append(allocator, '\'');
        try output_bytes.append(allocator, byte);
    }
    try output_bytes.append(allocator, '\'');
    return output_bytes.toOwnedSlice(allocator);
}

pub fn connectionInput(
    connection_secret: output.Output(value.SecretReference, .secret),
) error{SecretNotKnown}!value.Value {
    return switch (connection_secret) {
        .value => |reference| .{ .secret_ref = reference },
        .resource_ref => |reference| .{ .output_ref = .{
            .resource_id = reference.resource_id,
            .field = reference.field,
        } },
        .unknown_reason => error.SecretNotKnown,
    };
}
