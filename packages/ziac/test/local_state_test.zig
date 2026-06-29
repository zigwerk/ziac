const std = @import("std");
const ziac = @import("ziac");

test "local state saves resources as deterministic JSON" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();

    var store = ziac.local_state.Store.init(std.testing.allocator, ziac.local_state.memoryFiles(&fs));

    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    try state.put(.{
        .resource_id = "z.resource",
        .type_name = "test.Z",
        .logical_id = "z",
        .inputs_hash = "v1",
        .status = .created,
    });
    try state.put(.{
        .resource_id = "a.resource",
        .type_name = "test.A",
        .logical_id = "a",
        .inputs_hash = "v1",
        .status = .failed,
    });

    try store.saveResources("hello-global", "dev", &state);

    const json = fs.readFile(".ziac/state/hello-global/dev/resources.json") orelse return error.MissingStateFile;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"resource_id\":\"a.resource\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"resource_id\":\"z.resource\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"created\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "a.resource").? < std.mem.indexOf(u8, json, "z.resource").?);
}

test "local state loads resources from JSON" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    try fs.writeFile(".ziac/state/hello-global/dev/resources.json",
        \\{"resources":[{"resource_id":"gcp.run.Service.europe-west1.api","type_name":"gcp.run.Service","logical_id":"api","inputs_hash":"v1","status":"created"}]}
    );

    var store = ziac.local_state.Store.init(std.testing.allocator, ziac.local_state.memoryFiles(&fs));
    var loaded = try store.loadResources("hello-global", "dev");
    defer loaded.deinit();

    const record = loaded.store.get("gcp.run.Service.europe-west1.api") orelse return error.MissingRecord;
    try std.testing.expectEqual(ziac.ResourceStatus.created, record.status);
    try std.testing.expectEqualStrings("api", record.logical_id);
}

test "local state saves outputs with secret values redacted" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();

    var store = ziac.local_state.Store.init(std.testing.allocator, ziac.local_state.memoryFiles(&fs));
    const outputs = [_]ziac.stack_registry.OutputEntry{
        .{ .name = "url", .value = "https://hello-global.example.local" },
        .{ .name = "database_url", .value = "postgres://user:sentinel-secret-for-tests@localhost/db", .secret = true },
    };

    try store.saveOutputs("hello-global", "dev", outputs[0..]);

    const json = fs.readFile(".ziac/state/hello-global/dev/outputs.json") orelse return error.MissingOutputsFile;
    try std.testing.expect(std.mem.indexOf(u8, json, "https://hello-global.example.local") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "sentinel-secret-for-tests") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "[REDACTED]") != null);
}
