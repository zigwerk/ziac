const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

test "Cockroach psql adapter owns text representations for driver-neutral rows" {
    const fields = [_]zstd.Sql.Field{
        .{ .name = "active", .value = .{ .boolean = true } },
        .{ .name = "count", .value = .{ .integer = 42 } },
        .{ .name = "missing", .value = .null_value },
        .{ .name = "name", .value = .{ .text = "project" } },
    };
    const rows = [_]zstd.Sql.Row{.{ .fields = &fields }};
    var converted = try ziac.cockroach.psql_executor.queryResultFromPsqlAlloc(
        std.testing.allocator,
        .{ .rows = &rows },
    );
    defer converted.deinit();

    try std.testing.expectEqual(@as(usize, 1), converted.rows.len);
    try std.testing.expectEqualStrings("true", converted.rows[0].get("active").?);
    try std.testing.expectEqualStrings("42", converted.rows[0].get("count").?);
    try std.testing.expect(converted.rows[0].get("missing") == null);
    try std.testing.expectEqualStrings("project", converted.rows[0].get("name").?);
}

test "Cockroach psql adapter maps SQLSTATE classes without server messages" {
    try std.testing.expectEqual(
        ziac.cockroach.sql.Error.AuthenticationFailed,
        ziac.cockroach.psql_executor.classifyFailure("28P01", .definite),
    );
    try std.testing.expectEqual(
        ziac.cockroach.sql.Error.AuthorizationFailed,
        ziac.cockroach.psql_executor.classifyFailure("42501", .definite),
    );
    try std.testing.expectEqual(
        ziac.cockroach.sql.Error.ConnectionFailed,
        ziac.cockroach.psql_executor.classifyFailure("08006", .connection),
    );
    try std.testing.expectEqual(
        ziac.cockroach.sql.Error.QueryFailed,
        ziac.cockroach.psql_executor.classifyFailure("40001", .definite),
    );
}

test "Cockroach native executor exposes the same redacted SQLSTATE contract" {
    var executor = ziac.cockroach.native_executor.NativeExecutor.init(
        std.testing.allocator,
        std.testing.io,
        .{},
    );
    defer executor.deinit();
    _ = executor.executor();
    try std.testing.expectEqual(
        ziac.cockroach.sql.Error.AuthenticationFailed,
        ziac.cockroach.native_executor.classifyNativeFailure("28P01", .definite),
    );
    try std.testing.expectEqual(
        ziac.cockroach.sql.Error.QueryFailed,
        ziac.cockroach.native_executor.classifyNativeFailure("40003", .ambiguous),
    );
}
