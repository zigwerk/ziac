const std = @import("std");
const ziac = @import("ziac");

test "fixture registry builds hello global stack graph and outputs" {
    var registry = ziac.stack_registry.fixtureRegistry();

    var program = try registry.build(std.testing.allocator, .{
        .stack = "hello-global",
        .stage = "dev",
    });
    defer program.deinit();

    try std.testing.expectEqual(@as(usize, 2), program.graph.resources.items.len);
    try std.testing.expectEqualStrings("gcp.artifact.Repository.europe-west1.hello-global", program.graph.resources.items[0].id);
    try std.testing.expectEqualStrings("gcp.run.Service.europe-west1.api", program.graph.resources.items[1].id);
    try std.testing.expectEqual(@as(usize, 1), program.graph.dependencies.items.len);
    try std.testing.expectEqualStrings("gcp.run.Service.europe-west1.api", program.graph.dependencies.items[0].from);
    try std.testing.expectEqualStrings("gcp.artifact.Repository.europe-west1.hello-global", program.graph.dependencies.items[0].to);
    try std.testing.expectEqual(@as(usize, 6), program.outputs.items.len);
    try std.testing.expectEqualStrings("repository_url", program.outputs.items[0].name);
    try std.testing.expectEqualStrings("service_url", program.outputs.items[1].name);
    try std.testing.expectEqualStrings("service_name", program.outputs.items[2].name);
    try std.testing.expectEqualStrings("service_region", program.outputs.items[3].name);
    try std.testing.expectEqualStrings("service_account", program.outputs.items[4].name);
    try std.testing.expectEqualStrings("database_url", program.outputs.items[5].name);
    try std.testing.expect(program.outputs.items[5].secret);
}

test "fixture registry rejects unknown stack names" {
    var registry = ziac.stack_registry.fixtureRegistry();

    try std.testing.expectError(error.UnknownStack, registry.build(std.testing.allocator, .{
        .stack = "missing",
        .stage = "dev",
    }));
}
