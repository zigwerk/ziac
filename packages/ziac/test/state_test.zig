const std = @import("std");
const ziac = @import("ziac");

test "in-memory state can put and get resource records" {
    var store = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer store.deinit();

    try store.put(.{
        .resource_id = "gcp.run.Service.api",
        .type_name = "gcp.run.Service",
        .logical_id = "api",
        .inputs_hash = "abc123",
        .status = .created,
    });

    const record = store.get("gcp.run.Service.api") orelse return error.MissingRecord;
    try std.testing.expectEqual(ziac.ResourceStatus.created, record.status);
    try std.testing.expectEqualStrings("abc123", record.inputs_hash);
}

test "in-memory state marks failed resources" {
    var store = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer store.deinit();

    try store.put(.{
        .resource_id = "gcp.run.Service.api",
        .type_name = "gcp.run.Service",
        .logical_id = "api",
        .inputs_hash = "abc123",
        .status = .creating,
    });
    try store.markFailed("gcp.run.Service.api");

    const record = store.get("gcp.run.Service.api") orelse return error.MissingRecord;
    try std.testing.expectEqual(ziac.ResourceStatus.failed, record.status);
}
