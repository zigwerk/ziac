const std = @import("std");
const ziac = @import("ziac");

test "second local state writer receives a lock conflict" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    const store = ziac.local_state.Store.init(std.testing.allocator, ziac.local_state.memoryFiles(&fs));

    try store.acquireLock("stack", "dev", .{
        .owner_id = "writer-one",
        .command = "deploy",
        .acquired_at_millis = 100,
    });
    try std.testing.expectError(
        error.LockConflict,
        store.acquireLock("stack", "dev", .{
            .owner_id = "writer-two",
            .command = "destroy",
            .acquired_at_millis = 101,
        }),
    );

    var lock = try store.inspectLock("stack", "dev");
    defer lock.deinit();
    try std.testing.expectEqualStrings("stack/dev", lock.metadata.lineage_id);
    try std.testing.expectEqualStrings("writer-one", lock.metadata.owner_id);
    try std.testing.expectEqualStrings("deploy", lock.metadata.command);
}

test "stale lock inspection is safe and does not remove the lock" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    const store = ziac.local_state.Store.init(std.testing.allocator, ziac.local_state.memoryFiles(&fs));
    try store.acquireLock("stack", "prod", .{
        .owner_id = "old-writer",
        .command = "deploy",
        .acquired_at_millis = 100,
    });

    var lock = try store.inspectLock("stack", "prod");
    defer lock.deinit();
    try std.testing.expect(lock.metadata.isStale(10_100, 10_000));
    try std.testing.expect(try store.hasLock("stack", "prod"));
}

test "lock release requires owner and forced unlock requires lineage or override" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    const store = ziac.local_state.Store.init(std.testing.allocator, ziac.local_state.memoryFiles(&fs));
    try store.acquireLock("stack", "dev", .{
        .owner_id = "writer-one",
        .command = "deploy",
        .acquired_at_millis = 100,
    });

    try std.testing.expectError(
        error.LockOwnershipMismatch,
        store.releaseLock("stack", "dev", "writer-two"),
    );
    try std.testing.expectError(
        error.LockLineageMismatch,
        store.forceUnlock("stack", "dev", "another/lineage", false),
    );
    try std.testing.expect(try store.hasLock("stack", "dev"));
    try store.forceUnlock("stack", "dev", "another/lineage", true);
    try std.testing.expect(!try store.hasLock("stack", "dev"));

    try store.acquireLock("stack", "dev", .{
        .owner_id = "writer-three",
        .command = "refresh",
        .acquired_at_millis = 200,
    });
    try store.releaseLock("stack", "dev", "writer-three");
    try std.testing.expect(!try store.hasLock("stack", "dev"));
}
