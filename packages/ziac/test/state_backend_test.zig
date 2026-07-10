const std = @import("std");
const ziac = @import("ziac");

test "object store enforces absent and exact generation preconditions" {
    var memory = ziac.state_backend.MemoryObjectStore.init(std.testing.allocator);
    defer memory.deinit();
    const objects = memory.objectStore();

    var created = try objects.put("state.json", "one", .absent);
    defer created.deinit();
    try std.testing.expectEqualStrings("1", created.generation);
    try std.testing.expectError(error.Conflict, objects.put("state.json", "duplicate", .absent));

    var read = try objects.get("state.json");
    defer read.deinit();
    try std.testing.expectEqualStrings("one", read.bytes);
    try std.testing.expectEqualStrings("1", read.generation);

    var updated = try objects.put("state.json", "two", .{ .generation = read.generation });
    defer updated.deinit();
    try std.testing.expectEqualStrings("2", updated.generation);
    try std.testing.expectError(error.Conflict, objects.put("state.json", "stale", .{ .generation = "1" }));
    try std.testing.expectError(error.Conflict, objects.delete("state.json", "1"));
    try objects.delete("state.json", updated.generation);
    try std.testing.expectError(error.NotFound, objects.get("state.json"));
}

test "remote resources use generation CAS and reject a concurrent writer" {
    var memory = ziac.state_backend.MemoryObjectStore.init(std.testing.allocator);
    defer memory.deinit();
    var first = try ziac.state_backend.Remote.init(std.testing.allocator, memory.objectStore(), .{});
    defer first.deinit();
    var second = try ziac.state_backend.Remote.init(std.testing.allocator, memory.objectStore(), .{});
    defer second.deinit();
    const first_store = first.store();
    const second_store = second.store();

    var initial = try first_store.loadResourcesOrEmpty("api", "prod");
    defer initial.deinit();
    try initial.store.put(record("api", "v1"));
    try first_store.saveResources("api", "prod", &initial.store);

    var competing = try second_store.loadResources("api", "prod");
    defer competing.deinit();
    try initial.store.put(record("api", "v2"));
    try first_store.saveResources("api", "prod", &initial.store);
    try competing.store.put(record("api", "competing"));
    try std.testing.expectError(
        error.StateConflict,
        second_store.saveResources("api", "prod", &competing.store),
    );

    var current = try first_store.loadResources("api", "prod");
    defer current.deinit();
    try std.testing.expectEqualStrings("v2", current.store.get("test.Resource.api").?.desired_hash);
}

test "remote writer leases expose owner expiry renewal and stale takeover" {
    var memory = ziac.state_backend.MemoryObjectStore.init(std.testing.allocator);
    defer memory.deinit();
    var first = try ziac.state_backend.Remote.init(std.testing.allocator, memory.objectStore(), .{
        .lease_duration_millis = 1_000,
    });
    defer first.deinit();
    var second = try ziac.state_backend.Remote.init(std.testing.allocator, memory.objectStore(), .{
        .lease_duration_millis = 1_000,
    });
    defer second.deinit();
    const first_store = first.store();
    const second_store = second.store();

    try first_store.acquireLock("api", "prod", .{
        .owner_id = "writer-one",
        .command = "deploy",
        .acquired_at_millis = 100,
    });
    var lock = try first_store.inspectLock("api", "prod");
    defer lock.deinit();
    try std.testing.expectEqualStrings("writer-one", lock.metadata.owner_id);
    try std.testing.expectEqual(@as(?u64, 1_100), lock.metadata.expires_at_millis);
    try std.testing.expect(!lock.metadata.isExpired(1_099));

    try std.testing.expectError(error.LockConflict, second_store.acquireLock("api", "prod", .{
        .owner_id = "writer-two",
        .command = "deploy",
        .acquired_at_millis = 200,
    }));
    try first_store.renewLock("api", "prod", "writer-one", 500);
    var renewed = try first_store.inspectLock("api", "prod");
    defer renewed.deinit();
    try std.testing.expectEqual(@as(?u64, 1_500), renewed.metadata.expires_at_millis);

    try second_store.acquireLock("api", "prod", .{
        .owner_id = "writer-two",
        .command = "refresh",
        .acquired_at_millis = 1_501,
    });
    try std.testing.expectError(
        error.LockOwnershipMismatch,
        first_store.releaseLock("api", "prod", "writer-one"),
    );
    try second_store.releaseLock("api", "prod", "writer-two");
    try std.testing.expect(!try second_store.hasLock("api", "prod"));
}

test "expired remote lock takeover is one generation-matched overwrite" {
    var memory = ziac.state_backend.MemoryObjectStore.init(std.testing.allocator);
    defer memory.deinit();
    var guarded = NoDeleteObjectStore{ .delegate = &memory };
    var first = try ziac.state_backend.Remote.init(std.testing.allocator, guarded.objectStore(), .{
        .lease_duration_millis = 1_000,
    });
    defer first.deinit();
    var second = try ziac.state_backend.Remote.init(std.testing.allocator, guarded.objectStore(), .{
        .lease_duration_millis = 1_000,
    });
    defer second.deinit();

    try first.store().acquireLock("api", "prod", .{
        .owner_id = "writer-one",
        .command = "deploy",
        .acquired_at_millis = 100,
    });
    try second.store().acquireLock("api", "prod", .{
        .owner_id = "writer-two",
        .command = "refresh",
        .acquired_at_millis = 1_101,
    });

    var current = try second.store().inspectLock("api", "prod");
    defer current.deinit();
    try std.testing.expectEqualStrings("writer-two", current.metadata.owner_id);
}

test "remote checkpoint renews its writer lease before state CAS" {
    var memory = ziac.state_backend.MemoryObjectStore.init(std.testing.allocator);
    defer memory.deinit();
    var remote = try ziac.state_backend.Remote.init(std.testing.allocator, memory.objectStore(), .{
        .lease_duration_millis = 1_000,
    });
    defer remote.deinit();
    const backend = remote.store();
    try backend.acquireLock("api", "prod", .{
        .owner_id = "writer-one",
        .command = "deploy",
        .acquired_at_millis = 100,
    });
    var loaded = try backend.loadResourcesOrEmpty("api", "prod");
    defer loaded.deinit();
    try loaded.store.put(record("api", "checkpointed"));
    var checkpoint = ziac.checkpoint.Resources{
        .store = backend,
        .stack = "api",
        .stage = "prod",
        .lock_owner_id = "writer-one",
        .now_millis = 500,
    };

    try checkpoint.checkpoint().save(&loaded.store);
    var lock = try backend.inspectLock("api", "prod");
    defer lock.deinit();
    try std.testing.expectEqual(@as(?u64, 1_500), lock.metadata.expires_at_millis);
    try std.testing.expect(memory.content("ziac/state/api/prod/resources.json") != null);
}

test "local migration preserves lineage serial typed secrets and redacted outputs" {
    var files = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer files.deinit();
    const local = ziac.local_state.Store.init(std.testing.allocator, ziac.local_state.memoryFiles(&files));
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    state.setLineage("api/prod");
    try state.put(.{
        .resource_id = "gcp.secret.SecretVersion.database.initial",
        .provider = .gcp,
        .type_name = "gcp.secret.SecretVersion",
        .logical_id = "initial",
        .desired_hash = "secret-version",
        .outputs = &.{.{ .name = "version", .value = .{ .secret_ref = .{
            .provider = "gcp-secret-manager",
            .resource = "projects/example/secrets/database-url",
            .version = "7",
        } } }},
        .status = .created,
    });
    try local.saveResources("api", "prod", &state);
    try local.saveOutputs("api", "prod", &.{
        .{ .name = "url", .value = "https://api.example.com" },
        .{ .name = "database_url", .value = "sentinel-secret-for-tests", .secret = true },
    });

    var memory = ziac.state_backend.MemoryObjectStore.init(std.testing.allocator);
    defer memory.deinit();
    var remote = try ziac.state_backend.Remote.init(std.testing.allocator, memory.objectStore(), .{});
    defer remote.deinit();
    const target = remote.store();
    try ziac.state_backend.migrateLocalToBackend(std.testing.allocator, local, target, "api", "prod");
    try std.testing.expectError(
        error.TargetStateExists,
        ziac.state_backend.migrateLocalToBackend(std.testing.allocator, local, target, "api", "prod"),
    );

    var loaded = try target.loadResources("api", "prod");
    defer loaded.deinit();
    const before = state.metadata();
    const after = loaded.store.metadata();
    try std.testing.expectEqual(before.serial, after.serial);
    try std.testing.expectEqualSlices(u8, &before.lineage_hash, &after.lineage_hash);
    const secret = loaded.store.get("gcp.secret.SecretVersion.database.initial").?.outputs[0].value.secret_ref;
    try std.testing.expectEqualStrings("gcp-secret-manager", secret.provider);
    try std.testing.expectEqualStrings("projects/example/secrets/database-url", secret.resource);

    var outputs = try target.loadOutputs("api", "prod");
    defer outputs.deinit();
    try std.testing.expectEqualStrings("[REDACTED]", outputs.items[1].value);
    try std.testing.expect(std.mem.indexOf(u8, memory.content("ziac/state/api/prod/outputs.json").?, "sentinel-secret-for-tests") == null);
}

fn record(logical_id: []const u8, desired_hash: []const u8) ziac.StateRecord {
    return .{
        .resource_id = "test.Resource.api",
        .type_name = "test.Resource",
        .logical_id = logical_id,
        .desired_hash = desired_hash,
        .status = .created,
    };
}

const NoDeleteObjectStore = struct {
    delegate: *ziac.state_backend.MemoryObjectStore,

    fn objectStore(self: *NoDeleteObjectStore) ziac.state_backend.ObjectStore {
        return .{ .ptr = self, .getFn = get, .putFn = put, .deleteFn = delete };
    }

    fn get(raw: *anyopaque, key: []const u8) anyerror!ziac.state_backend.Object {
        const self: *NoDeleteObjectStore = @ptrCast(@alignCast(raw));
        return self.delegate.objectStore().get(key);
    }

    fn put(
        raw: *anyopaque,
        key: []const u8,
        bytes: []const u8,
        precondition: ziac.state_backend.Precondition,
    ) anyerror!ziac.state_backend.PutResult {
        const self: *NoDeleteObjectStore = @ptrCast(@alignCast(raw));
        return self.delegate.objectStore().put(key, bytes, precondition);
    }

    fn delete(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {
        return error.DeleteForbidden;
    }
};
