const std = @import("std");
const ziac = @import("ziac");

test "in-memory state can put and get resource records" {
    var store = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer store.deinit();

    try store.put(.{
        .resource_id = "gcp.run.Service.api",
        .provider = .gcp,
        .type_name = "gcp.run.Service",
        .schema_version = 2,
        .logical_id = "api",
        .physical_id = "projects/example/locations/europe-west1/services/api",
        .desired_hash = "abc123",
        .observed_hash = "def456",
        .dependencies = &.{"gcp.artifact.Repository.repo"},
        .outputs = &.{
            .{ .name = "uri", .value = .{ .string = "https://api.example.test" } },
            .{ .name = "database_url", .value = .{ .secret_ref = .{
                .provider = "gcp",
                .resource = "projects/example/secrets/database-url",
                .version = "3",
            } } },
        },
        .status = .created,
        .operation_handle = "operations/create-api",
    });

    const record = store.get("gcp.run.Service.api") orelse return error.MissingRecord;
    try std.testing.expectEqual(ziac.ResourceStatus.created, record.status);
    try std.testing.expectEqual(ziac.resource.ProviderId.gcp, record.provider);
    try std.testing.expectEqual(@as(u32, 2), record.schema_version);
    try std.testing.expectEqualStrings("abc123", record.desired_hash);
    try std.testing.expectEqualStrings("def456", record.observed_hash.?);
    try std.testing.expectEqualStrings("projects/example/locations/europe-west1/services/api", record.physical_id.?);
    try std.testing.expectEqualStrings("gcp.artifact.Repository.repo", record.dependencies[0]);
    try std.testing.expectEqual(@as(usize, 2), record.outputs.len);
    try std.testing.expect(record.outputs[1].value == .secret_ref);
    try std.testing.expectEqualStrings("operations/create-api", record.operation_handle.?);
    try std.testing.expectEqual(@as(u64, 1), store.serial);
}

test "in-memory state marks failed resources" {
    var store = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer store.deinit();

    try store.put(.{
        .resource_id = "gcp.run.Service.api",
        .type_name = "gcp.run.Service",
        .logical_id = "api",
        .desired_hash = "abc123",
        .status = .creating,
    });
    try store.markFailed("gcp.run.Service.api");

    const record = store.get("gcp.run.Service.api") orelse return error.MissingRecord;
    try std.testing.expectEqual(ziac.ResourceStatus.failed, record.status);
}

test "in-memory state lists records in resource id order" {
    var store = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer store.deinit();

    try store.put(.{
        .resource_id = "z.resource",
        .type_name = "test.Z",
        .logical_id = "z",
        .desired_hash = "v1",
        .status = .created,
    });
    try store.put(.{
        .resource_id = "a.resource",
        .type_name = "test.A",
        .logical_id = "a",
        .desired_hash = "v1",
        .status = .created,
    });

    const records = try store.recordsAlloc(std.testing.allocator);
    defer std.testing.allocator.free(records);

    try std.testing.expectEqual(@as(usize, 2), records.len);
    try std.testing.expectEqualStrings("a.resource", records[0].resource_id);
    try std.testing.expectEqualStrings("z.resource", records[1].resource_id);
}

test "in-memory state owns records independently from caller allocations" {
    var store = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer store.deinit();

    const resource_id = try std.testing.allocator.dupe(u8, "owned.resource");
    const physical_id = try std.testing.allocator.dupe(u8, "providers/owned.resource");
    try store.put(.{
        .resource_id = resource_id,
        .type_name = "test.Owned",
        .logical_id = "owned",
        .physical_id = physical_id,
        .desired_hash = "hash",
        .status = .created,
    });
    std.testing.allocator.free(resource_id);
    std.testing.allocator.free(physical_id);

    const record = store.get("owned.resource") orelse return error.MissingRecord;
    try std.testing.expectEqualStrings("owned.resource", record.resource_id);
    try std.testing.expectEqualStrings("providers/owned.resource", record.physical_id.?);
}
