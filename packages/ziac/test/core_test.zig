const std = @import("std");
const ziac = @import("ziac");

test "logical ids reject empty strings and path separators" {
    try std.testing.expectError(error.EmptyName, ziac.core.validateLogicalId(""));
    try std.testing.expectError(error.InvalidName, ziac.core.validateLogicalId("api/prod"));
    try std.testing.expectError(error.InvalidName, ziac.core.validateLogicalId("api prod"));
    try ziac.core.validateLogicalId("api-prod_1");
}

test "physical names are stable from stack stage and logical id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const name = try ziac.core.physicalName(
        arena.allocator(),
        .{ .stack = "hello", .stage = "dev", .logical_id = "api" },
    );

    try std.testing.expectEqualStrings("hello-dev-api", name);
}

test "diagnostic formats code and message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const diagnostic = ziac.core.Diagnostic{
        .code = "ZIAC001",
        .message = "missing provider",
        .subject = "gcp",
    };

    const text = try diagnostic.format(arena.allocator());
    try std.testing.expectEqualStrings("ZIAC001: missing provider (gcp)", text);
}
