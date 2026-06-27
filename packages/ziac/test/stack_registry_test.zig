const std = @import("std");
const ziac = @import("ziac");

test "fixture registry builds hello global stack graph and outputs" {
    var registry = ziac.stack_registry.fixtureRegistry();

    var program = try registry.build(std.testing.allocator, .{
        .stack = "hello-global",
        .stage = "dev",
    });
    defer program.deinit();

    try std.testing.expectEqual(@as(usize, 1), program.graph.resources.items.len);
    try std.testing.expectEqualStrings("gcp.run.Service.api", program.graph.resources.items[0].id);
    try std.testing.expectEqual(@as(usize, 2), program.outputs.items.len);
    try std.testing.expectEqualStrings("url", program.outputs.items[0].name);
    try std.testing.expect(!program.outputs.items[0].secret);
    try std.testing.expectEqualStrings("database_url", program.outputs.items[1].name);
    try std.testing.expect(program.outputs.items[1].secret);
}

test "fixture registry rejects unknown stack names" {
    var registry = ziac.stack_registry.fixtureRegistry();

    try std.testing.expectError(error.UnknownStack, registry.build(std.testing.allocator, .{
        .stack = "missing",
        .stage = "dev",
    }));
}
