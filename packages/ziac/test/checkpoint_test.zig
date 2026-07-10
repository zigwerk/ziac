const std = @import("std");
const ziac = @import("ziac");

const Recorder = struct {
    serials: [8]u64 = [_]u64{0} ** 8,
    calls: usize = 0,
    fail_next: bool = false,

    fn checkpoint(self: *Recorder) ziac.checkpoint.Checkpoint {
        return .{ .ptr = self, .saveFn = save };
    }

    fn save(raw: *anyopaque, store: *ziac.InMemoryStateStore) ziac.checkpoint.CheckpointError!void {
        const self: *Recorder = @ptrCast(@alignCast(raw));
        if (self.fail_next) {
            self.fail_next = false;
            return error.CheckpointFailed;
        }
        self.serials[self.calls] = store.serialValue();
        self.calls += 1;
    }
};

const FaultFiles = struct {
    memory: ziac.zstd.FileSystem.MemoryFileSystem,
    fail_atomic: bool = false,
    ordinary_writes: usize = 0,
    atomic_writes: usize = 0,

    fn init(allocator: std.mem.Allocator) FaultFiles {
        return .{ .memory = ziac.zstd.FileSystem.MemoryFileSystem.init(allocator) };
    }

    fn deinit(self: *FaultFiles) void {
        self.memory.deinit();
    }

    fn files(self: *FaultFiles) ziac.local_state.FileStore {
        return .{
            .ptr = self,
            .readFileAllocFn = readFileAlloc,
            .writeFileFn = writeFile,
            .atomicWriteFileFn = atomicWriteFile,
            .createExclusiveFileFn = createExclusiveFile,
            .deleteFileFn = deleteFile,
            .existsFn = exists,
        };
    }

    fn readFileAlloc(
        raw: *anyopaque,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) anyerror![]const u8 {
        const self: *FaultFiles = @ptrCast(@alignCast(raw));
        return self.memory.readFileAlloc(allocator, path);
    }

    fn writeFile(raw: *anyopaque, path: []const u8, content: []const u8) anyerror!void {
        const self: *FaultFiles = @ptrCast(@alignCast(raw));
        self.ordinary_writes += 1;
        try self.memory.writeFile(path, content);
    }

    fn atomicWriteFile(
        raw: *anyopaque,
        allocator: std.mem.Allocator,
        path: []const u8,
        content: []const u8,
    ) anyerror!void {
        _ = allocator;
        const self: *FaultFiles = @ptrCast(@alignCast(raw));
        self.atomic_writes += 1;
        if (self.fail_atomic) return error.InjectedWriteFailure;
        try self.memory.atomicWriteFile(path, content);
    }

    fn createExclusiveFile(raw: *anyopaque, path: []const u8, content: []const u8) anyerror!void {
        const self: *FaultFiles = @ptrCast(@alignCast(raw));
        if (self.memory.exists(path)) return error.PathAlreadyExists;
        try self.memory.writeFile(path, content);
    }

    fn deleteFile(raw: *anyopaque, path: []const u8) anyerror!void {
        const self: *FaultFiles = @ptrCast(@alignCast(raw));
        if (!self.memory.exists(path)) return error.FileNotFound;
        self.memory.deleteFile(path);
    }

    fn exists(raw: *anyopaque, path: []const u8) anyerror!bool {
        const self: *FaultFiles = @ptrCast(@alignCast(raw));
        return self.memory.exists(path);
    }
};

fn addNode(graph: *ziac.ResourceGraph, id: []const u8) !void {
    try graph.addResource(.{
        .id = id,
        .provider = .gcp,
        .type_name = "gcp.test.Resource",
        .logical_id = id,
    });
}

test "executor checkpoints after every completed provider mutation" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try addNode(&graph, "consumer");
    try addNode(&graph, "dependency");
    try graph.addDependency("consumer", "dependency");
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    var plan = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer plan.deinit();
    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    var providers = ziac.provider.ProviderRegistry{};
    providers.register(.gcp, fake.provider());
    var recorder = Recorder{};

    try ziac.executor.executePlan(std.testing.allocator, &plan, &state, providers, .{
        .checkpoint = recorder.checkpoint(),
    });

    try std.testing.expectEqual(@as(usize, 2), recorder.calls);
    try std.testing.expectEqual(@as(u64, 2), recorder.serials[0]);
    try std.testing.expectEqual(@as(u64, 4), recorder.serials[1]);
}

test "checkpoint failure stops execution after preserving in-memory remote identity" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try addNode(&graph, "service");
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    var plan = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer plan.deinit();
    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    var providers = ziac.provider.ProviderRegistry{};
    providers.register(.gcp, fake.provider());
    var recorder = Recorder{ .fail_next = true };

    try std.testing.expectError(
        error.CheckpointFailed,
        ziac.executor.executePlan(std.testing.allocator, &plan, &state, providers, .{
            .checkpoint = recorder.checkpoint(),
        }),
    );
    const record = state.get("service").?;
    try std.testing.expectEqual(ziac.ResourceStatus.created, record.status);
    try std.testing.expectEqualStrings("fake/service", record.physical_id.?);
    try std.testing.expectEqual(@as(usize, 1), fake.creates);
}

test "failed atomic resource save leaves the previous state file intact" {
    var files = FaultFiles.init(std.testing.allocator);
    defer files.deinit();
    const local = ziac.local_state.Store.init(std.testing.allocator, files.files());
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    try state.put(.{
        .resource_id = "service",
        .type_name = "test.Resource",
        .logical_id = "service",
        .desired_hash = "v1",
        .status = .created,
    });
    try local.saveResources("stack", "dev", &state);
    const path = ".ziac/state/stack/dev/resources.json";
    const before = try files.memory.readFileAlloc(std.testing.allocator, path);
    defer std.testing.allocator.free(before);

    try state.markFailed("service");
    files.fail_atomic = true;
    try std.testing.expectError(
        error.InjectedWriteFailure,
        local.saveResources("stack", "dev", &state),
    );
    const after = files.memory.readFile(path).?;
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expectEqual(@as(usize, 2), files.atomic_writes);
    try std.testing.expectEqual(@as(usize, 0), files.ordinary_writes);
}

test "pending provider operation checkpoints its handle before completing by read" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try addNode(&graph, "service");
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    var first_plan = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer first_plan.deinit();
    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    fake.result_operation_handle = "operations/create-service";
    fake.result_completed = false;
    var providers = ziac.provider.ProviderRegistry{};
    providers.register(.gcp, fake.provider());
    var first_checkpoints = Recorder{};

    try ziac.executor.executePlan(std.testing.allocator, &first_plan, &state, providers, .{
        .checkpoint = first_checkpoints.checkpoint(),
    });

    const adopted = state.get("service").?;
    try std.testing.expectEqual(ziac.ResourceStatus.created, adopted.status);
    try std.testing.expectEqualStrings("fake/service", adopted.physical_id.?);
    try std.testing.expect(adopted.operation_handle == null);
    try std.testing.expectEqual(@as(usize, 1), fake.creates);
    try std.testing.expectEqual(@as(usize, 2), first_checkpoints.calls);
}

test "pending operation that is not remotely visible is never duplicated" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try addNode(&graph, "service");
    const desired_hash = std.fmt.bytesToHex(graph.resources.items[0].inputs_hash, .lower);
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    try state.put(.{
        .resource_id = "service",
        .provider = .gcp,
        .type_name = "gcp.test.Resource",
        .logical_id = "service",
        .desired_hash = desired_hash[0..],
        .status = .creating,
        .operation_handle = "operations/still-running",
    });
    var plan = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer plan.deinit();
    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    var providers = ziac.provider.ProviderRegistry{};
    providers.register(.gcp, fake.provider());

    try std.testing.expectError(
        error.OperationPending,
        ziac.executor.executePlan(std.testing.allocator, &plan, &state, providers, .{}),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.creates);
    try std.testing.expectEqualStrings(
        "operations/still-running",
        state.get("service").?.operation_handle.?,
    );
}

test "incomplete create without an operation handle retries when remote is absent" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try addNode(&graph, "service");
    const desired_hash = std.fmt.bytesToHex(graph.resources.items[0].inputs_hash, .lower);
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    try state.put(.{
        .resource_id = "service",
        .provider = .gcp,
        .type_name = "gcp.test.Resource",
        .logical_id = "service",
        .desired_hash = desired_hash[0..],
        .status = .creating,
    });
    var plan = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer plan.deinit();
    try std.testing.expectEqual(ziac.plan.OperationKind.create, plan.operations[0].kind);
    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    var providers = ziac.provider.ProviderRegistry{};
    providers.register(.gcp, fake.provider());

    try ziac.executor.executePlan(std.testing.allocator, &plan, &state, providers, .{});
    try std.testing.expectEqual(@as(usize, 1), fake.creates);
    try std.testing.expectEqual(ziac.ResourceStatus.created, state.get("service").?.status);
}

test "refresh adopts remote create completed before any local checkpoint" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try addNode(&graph, "service");
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    var created = try fake.provider().create(std.testing.allocator, graph.resources.items[0]);
    defer created.deinit();
    var providers = ziac.provider.ProviderRegistry{};
    providers.register(.gcp, fake.provider());
    var plan = try ziac.plan.buildRefreshedPlan(
        std.testing.allocator,
        &graph,
        &state,
        providers,
    );
    defer plan.deinit();
    try std.testing.expectEqual(ziac.plan.OperationKind.noop, plan.operations[0].kind);

    try ziac.executor.executePlan(std.testing.allocator, &plan, &state, providers, .{});
    try std.testing.expectEqual(@as(usize, 1), fake.creates);
    try std.testing.expectEqual(ziac.ResourceStatus.adopted, state.get("service").?.status);
}

test "state snapshot owns a serial-consistent copy across later mutations" {
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    try state.put(.{
        .resource_id = "service",
        .type_name = "test.Resource",
        .logical_id = "service",
        .desired_hash = "v1",
        .status = .created,
    });

    var snapshot = try state.snapshotAlloc(std.testing.allocator);
    defer snapshot.deinit();
    try state.markFailed("service");

    try std.testing.expectEqual(@as(u64, 1), snapshot.serial);
    try std.testing.expectEqual(@as(usize, 1), snapshot.records.len);
    try std.testing.expectEqual(ziac.ResourceStatus.created, snapshot.records[0].status);
    try std.testing.expectEqualStrings("service", snapshot.records[0].resource_id);
    try std.testing.expectEqual(ziac.ResourceStatus.failed, state.get("service").?.status);
}
