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
        .desired_hash = "v1",
        .status = .created,
    });
    try state.put(.{
        .resource_id = "a.resource",
        .type_name = "test.A",
        .logical_id = "a",
        .desired_hash = "v1",
        .status = .failed,
    });

    try store.saveResources("hello-global", "dev", &state);

    const json = fs.readFile(".ziac/state/hello-global/dev/resources.json") orelse return error.MissingStateFile;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"format_version\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"lineage_id\":\"hello-global/dev\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"serial\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"stack\":\"hello-global\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"stage\":\"dev\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"resource_id\":\"a.resource\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"resource_id\":\"z.resource\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"created\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "a.resource").? < std.mem.indexOf(u8, json, "z.resource").?);
}

test "local state migrates version one resources from JSON" {
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
    try std.testing.expectEqual(ziac.resource.ProviderId.gcp, record.provider);
    try std.testing.expectEqualStrings("v1", record.desired_hash);
    try std.testing.expectEqual(@as(u32, 1), record.schema_version);
    try std.testing.expectEqual(@as(u32, 1), loaded.source_format_version);
}

test "local state round trips version two physical state and typed outputs" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var store = ziac.local_state.Store.init(std.testing.allocator, ziac.local_state.memoryFiles(&fs));

    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    try state.put(.{
        .resource_id = "gcp.run.Service.europe-west1.api",
        .provider = .gcp,
        .type_name = "gcp.run.Service",
        .schema_version = 2,
        .logical_id = "api",
        .physical_id = "projects/example/locations/europe-west1/services/api",
        .desired_hash = "desired",
        .observed_hash = "observed",
        .dependencies = &.{"gcp.artifact.Repository.europe-west1.repo"},
        .outputs = &.{
            .{ .name = "uri", .value = .{ .string = "https://api.example.test" } },
            .{ .name = "database_url", .value = .{ .secret_ref = .{
                .provider = "gcp",
                .resource = "projects/example/secrets/database-url",
                .version = "4",
            } } },
        },
        .status = .created,
        .operation_handle = "operations/finished",
    });

    try store.saveResources("hello-global", "prod", &state);
    const json = fs.readFile(".ziac/state/hello-global/prod/resources.json") orelse return error.MissingStateFile;
    try std.testing.expect(std.mem.indexOf(u8, json, "sentinel-secret-for-tests") == null);

    var loaded = try store.loadResources("hello-global", "prod");
    defer loaded.deinit();
    const record = loaded.store.get("gcp.run.Service.europe-west1.api") orelse return error.MissingRecord;
    try std.testing.expectEqualStrings("projects/example/locations/europe-west1/services/api", record.physical_id.?);
    try std.testing.expectEqualStrings("observed", record.observed_hash.?);
    try std.testing.expectEqualStrings("gcp.artifact.Repository.europe-west1.repo", record.dependencies[0]);
    try std.testing.expectEqualStrings("https://api.example.test", record.outputs[0].value.string);
    try std.testing.expect(record.outputs[1].value == .secret_ref);
    try std.testing.expectEqualStrings("projects/example/secrets/database-url", record.outputs[1].value.secret_ref.resource);
    try std.testing.expectEqualStrings("operations/finished", record.operation_handle.?);
    try std.testing.expectEqual(@as(u32, 2), loaded.source_format_version);
}

test "local state rejects unsupported future versions" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    try fs.writeFile(".ziac/state/hello-global/dev/resources.json",
        \\{"format_version":99,"lineage_id":"future","serial":0,"stack":"hello-global","stage":"dev","resources":[]}
    );

    var store = ziac.local_state.Store.init(std.testing.allocator, ziac.local_state.memoryFiles(&fs));
    try std.testing.expectError(error.UnsupportedStateVersion, store.loadResources("hello-global", "dev"));
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
