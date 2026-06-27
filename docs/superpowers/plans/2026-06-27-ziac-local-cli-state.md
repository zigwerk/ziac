# Ziac Local CLI State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first usable local `ziac` command loop with fixture stacks, deterministic JSON state, fake-provider deploy/destroy, outputs, and a real executable.

**Architecture:** Add focused modules under `packages/ziac/src`: `stack_registry.zig` builds fixture resource graphs and outputs; `local_state.zig` persists resources and outputs through a small file adapter; `cli.zig` owns command parsing and command execution; `main.zig` is a thin executable wrapper. The CLI uses `zigeffect_std` for command parsing, console output, memory file-system tests, JSON escaping, and redaction while keeping live GCP and CockroachDB out of scope.

**Tech Stack:** Zig 0.16, `zigeffect_std`, `zstd.Cli`, `zstd.Console`, `zstd.FileSystem.MemoryFileSystem`, `zstd.Json`, `zstd.Secrets`, existing Ziac graph/plan/apply/provider/state modules, Bun root scripts.

---

## Scope Check

This plan implements only Phase 2 from the Ziac roadmap:

```text
ziac executable
plan/deploy/destroy/outputs/state commands
fixture stack registry
local JSON resources and outputs state
fake-provider command execution
examples build coverage
```

It does not implement dynamic Zig stack loading, live GCP provider calls,
CockroachDB provider calls, remote state locking, drift detection, or container
image building.

## File Structure

Create:

- `packages/ziac/src/stack_registry.zig` — fixture stack registry and output declarations.
- `packages/ziac/src/local_state.zig` — JSON resource/output persistence plus memory/disk file adapters.
- `packages/ziac/src/cli.zig` — command specs, argument parsing, command execution, exit codes, and output rendering.
- `packages/ziac/src/main.zig` — executable entry point.
- `packages/ziac/examples/local_cli.zig` — example that runs a local plan/deploy/outputs loop in memory.
- `packages/ziac/test/stack_registry_test.zig` — fixture stack tests.
- `packages/ziac/test/local_state_test.zig` — JSON state persistence tests.
- `packages/ziac/test/cli_test.zig` — command parser and command-flow tests.

Modify:

- `packages/ziac/src/ziac.zig` — export new modules.
- `packages/ziac/src/state.zig` — add stable state-record listing for persistence.
- `packages/ziac/src/plan.zig` — add destroy-plan builder over state records.
- `packages/ziac/src/apply.zig` — tolerate delete operations over existing records and keep status transitions deterministic.
- `packages/ziac/build.zig` — add executable and example build/test steps.
- `packages/ziac/build.zig.zon` — include `examples`.
- `packages/ziac/test/all_test.zig` — import new tests.
- `packages/ziac/README.md` and `packages/ziac/docs/roadmap.md` — document the local CLI command loop.

Do not modify:

- `packages/zigeffect/**`
- `packages/zigeffect-std/**`
- live Alchemy stack files

---

### Task 1: Stack Registry Fixture

**Files:**
- Create: `packages/ziac/src/stack_registry.zig`
- Modify: `packages/ziac/src/ziac.zig`
- Modify: `packages/ziac/test/all_test.zig`
- Create: `packages/ziac/test/stack_registry_test.zig`

- [ ] **Step 1: Write failing stack registry tests**

Create `packages/ziac/test/stack_registry_test.zig`:

```zig
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
```

Modify `packages/ziac/test/all_test.zig`:

```zig
comptime {
    _ = @import("smoke_test.zig");
    _ = @import("core_test.zig");
    _ = @import("output_test.zig");
    _ = @import("resource_graph_test.zig");
    _ = @import("state_test.zig");
    _ = @import("plan_test.zig");
    _ = @import("provider_apply_test.zig");
    _ = @import("stack_registry_test.zig");
}
```

- [ ] **Step 2: Run test to verify RED**

Run:

```sh
cd packages/ziac && zig build test
```

Expected: FAIL because `ziac.stack_registry` is not exported.

- [ ] **Step 3: Implement fixture registry**

Create `packages/ziac/src/stack_registry.zig`:

```zig
const std = @import("std");
const resource = @import("resource.zig");

pub const StackError = error{
    UnknownStack,
    DuplicateResource,
    MissingResource,
    OutOfMemory,
};

pub const StackArgs = struct {
    stack: []const u8,
    stage: []const u8,
};

pub const OutputEntry = struct {
    name: []const u8,
    value: []const u8,
    secret: bool = false,
};

pub const StackProgram = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    outputs: std.ArrayList(OutputEntry),

    pub fn deinit(self: *StackProgram) void {
        self.graph.deinit();
        self.outputs.deinit(self.allocator);
    }
};

pub const StackRegistry = struct {
    pub fn build(_: StackRegistry, allocator: std.mem.Allocator, args: StackArgs) StackError!StackProgram {
        if (!std.mem.eql(u8, args.stack, "hello-global")) return error.UnknownStack;

        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        try graph.addResource(.{
            .id = "gcp.run.Service.api",
            .type_name = "gcp.run.Service",
            .logical_id = "api",
        });

        var outputs = std.ArrayList(OutputEntry).empty;
        errdefer outputs.deinit(allocator);
        try outputs.append(allocator, .{
            .name = "url",
            .value = "https://hello-global.example.local",
        });
        try outputs.append(allocator, .{
            .name = "database_url",
            .value = "postgres://user:sentinel-secret-for-tests@localhost:26257/app",
            .secret = true,
        });

        return .{ .allocator = allocator, .graph = graph, .outputs = outputs };
    }
};

pub fn fixtureRegistry() StackRegistry {
    return .{};
}
```

Modify `packages/ziac/src/ziac.zig`:

```zig
pub const stack_registry = @import("stack_registry.zig");
```

- [ ] **Step 4: Verify GREEN**

Run:

```sh
cd packages/ziac && zig build test
```

Expected: PASS.

- [ ] **Step 5: Commit**

Run:

```sh
git add packages/ziac/src/stack_registry.zig packages/ziac/src/ziac.zig packages/ziac/test/all_test.zig packages/ziac/test/stack_registry_test.zig
git commit -m "Add Ziac fixture stack registry"
```

---

### Task 2: Stable State Listing And Destroy Plans

**Files:**
- Modify: `packages/ziac/src/state.zig`
- Modify: `packages/ziac/src/plan.zig`
- Modify: `packages/ziac/test/state_test.zig`
- Modify: `packages/ziac/test/plan_test.zig`

- [ ] **Step 1: Write failing state and destroy-plan tests**

Append to `packages/ziac/test/state_test.zig`:

```zig
test "in-memory state lists records in resource id order" {
    var store = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer store.deinit();

    try store.put(.{ .resource_id = "z.resource", .type_name = "test.Z", .logical_id = "z", .inputs_hash = "v1", .status = .created });
    try store.put(.{ .resource_id = "a.resource", .type_name = "test.A", .logical_id = "a", .inputs_hash = "v1", .status = .created });

    const records = try store.recordsAlloc(std.testing.allocator);
    defer std.testing.allocator.free(records);

    try std.testing.expectEqual(@as(usize, 2), records.len);
    try std.testing.expectEqualStrings("a.resource", records[0].resource_id);
    try std.testing.expectEqualStrings("z.resource", records[1].resource_id);
}
```

Append to `packages/ziac/test/plan_test.zig`:

```zig
test "destroy planner deletes managed resources from state" {
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();

    try state.put(.{
        .resource_id = "gcp.run.Service.api",
        .type_name = "gcp.run.Service",
        .logical_id = "api",
        .inputs_hash = "v1",
        .status = .created,
    });

    var destroy_plan = try ziac.plan.buildDestroyPlan(std.testing.allocator, &state);
    defer destroy_plan.deinit();

    try std.testing.expectEqual(@as(usize, 1), destroy_plan.operations.len);
    try std.testing.expectEqual(ziac.plan.OperationKind.delete, destroy_plan.operations[0].kind);
    try std.testing.expectEqualStrings("gcp.run.Service.api", destroy_plan.operations[0].resource.id);
}
```

- [ ] **Step 2: Run test to verify RED**

Run:

```sh
cd packages/ziac && zig build test
```

Expected: FAIL because `recordsAlloc` and `buildDestroyPlan` are missing.

- [ ] **Step 3: Implement stable record listing**

Modify `packages/ziac/src/state.zig` by adding this method inside `InMemoryStateStore`:

```zig
    pub fn recordsAlloc(self: *InMemoryStateStore, allocator: std.mem.Allocator) StateError![]StateRecord {
        var records = std.ArrayList(StateRecord).empty;
        errdefer records.deinit(allocator);

        var iterator = self.records.valueIterator();
        while (iterator.next()) |record| {
            try records.append(allocator, record.*);
        }

        const owned = try records.toOwnedSlice(allocator);
        std.mem.sort(StateRecord, owned, {}, lessThanRecordId);
        return owned;
    }
```

Add this helper below `InMemoryStateStore`:

```zig
fn lessThanRecordId(_: void, left: StateRecord, right: StateRecord) bool {
    return std.mem.lessThan(u8, left.resource_id, right.resource_id);
}
```

- [ ] **Step 4: Implement destroy planner**

Modify `packages/ziac/src/plan.zig` by adding:

```zig
pub fn buildDestroyPlan(
    allocator: std.mem.Allocator,
    store: *state.InMemoryStateStore,
) (PlanError || state.StateError)!Plan {
    const records = try store.recordsAlloc(allocator);
    defer allocator.free(records);

    var operations = std.ArrayList(PlanOperation).empty;
    errdefer operations.deinit(allocator);

    for (records) |record| {
        if (record.status == .deleted) continue;
        try operations.append(allocator, .{
            .kind = .delete,
            .resource = .{
                .id = record.resource_id,
                .type_name = record.type_name,
                .logical_id = record.logical_id,
            },
        });
    }

    return .{
        .allocator = allocator,
        .operations = try operations.toOwnedSlice(allocator),
    };
}
```

- [ ] **Step 5: Verify GREEN**

Run:

```sh
cd packages/ziac && zig build test
```

Expected: PASS.

- [ ] **Step 6: Commit**

Run:

```sh
git add packages/ziac/src/state.zig packages/ziac/src/plan.zig packages/ziac/test/state_test.zig packages/ziac/test/plan_test.zig
git commit -m "Add Ziac stable state listing and destroy planning"
```

---

### Task 3: Local JSON State Store

**Files:**
- Create: `packages/ziac/src/local_state.zig`
- Modify: `packages/ziac/src/ziac.zig`
- Modify: `packages/ziac/test/all_test.zig`
- Create: `packages/ziac/test/local_state_test.zig`

- [ ] **Step 1: Write failing local state tests**

Create `packages/ziac/test/local_state_test.zig`:

```zig
const std = @import("std");
const ziac = @import("ziac");

test "local state saves resources as deterministic JSON" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();

    var store = ziac.local_state.Store.init(std.testing.allocator, ziac.local_state.memoryFiles(&fs));

    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    try state.put(.{ .resource_id = "z.resource", .type_name = "test.Z", .logical_id = "z", .inputs_hash = "v1", .status = .created });
    try state.put(.{ .resource_id = "a.resource", .type_name = "test.A", .logical_id = "a", .inputs_hash = "v1", .status = .failed });

    try store.saveResources("hello-global", "dev", &state);

    const json = fs.readFile(".ziac/state/hello-global/dev/resources.json") orelse return error.MissingStateFile;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"resource_id\":\"a.resource\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"resource_id\":\"z.resource\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"created\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "a.resource") .? < std.mem.indexOf(u8, json, "z.resource") .?);
}

test "local state loads resources from JSON" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    try fs.writeFile(".ziac/state/hello-global/dev/resources.json",
        \\{"resources":[{"resource_id":"gcp.run.Service.api","type_name":"gcp.run.Service","logical_id":"api","inputs_hash":"v1","status":"created"}]}
    );

    var store = ziac.local_state.Store.init(std.testing.allocator, ziac.local_state.memoryFiles(&fs));
    var loaded = try store.loadResources("hello-global", "dev");
    defer loaded.deinit();

    const record = loaded.store.get("gcp.run.Service.api") orelse return error.MissingRecord;
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
```

Modify `packages/ziac/test/all_test.zig` to import `local_state_test.zig`.

- [ ] **Step 2: Run test to verify RED**

Run:

```sh
cd packages/ziac && zig build test
```

Expected: FAIL because `ziac.local_state` is missing.

- [ ] **Step 3: Implement local state file adapter and path helpers**

Create `packages/ziac/src/local_state.zig` with:

```zig
const std = @import("std");
const zstd = @import("zigeffect_std");
const state_mod = @import("state.zig");
const stack_registry = @import("stack_registry.zig");

pub const LocalStateError = error{
    MissingStateFile,
    InvalidStateFile,
    UnknownStatus,
    OutOfMemory,
};

pub const FileStore = struct {
    ptr: *anyopaque,
    readFileAllocFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror![]const u8,
    writeFileFn: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,
    existsFn: *const fn (*anyopaque, []const u8) anyerror!bool,

    pub fn readFileAlloc(self: FileStore, allocator: std.mem.Allocator, path: []const u8) anyerror![]const u8 {
        return self.readFileAllocFn(self.ptr, allocator, path);
    }

    pub fn writeFile(self: FileStore, path: []const u8, content: []const u8) anyerror!void {
        return self.writeFileFn(self.ptr, path, content);
    }

    pub fn exists(self: FileStore, path: []const u8) anyerror!bool {
        return self.existsFn(self.ptr, path);
    }
};

pub fn memoryFiles(fs: *zstd.FileSystem.MemoryFileSystem) FileStore {
    return .{
        .ptr = fs,
        .readFileAllocFn = memoryReadFileAlloc,
        .writeFileFn = memoryWriteFile,
        .existsFn = memoryExists,
    };
}

fn memoryReadFileAlloc(raw: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]const u8 {
    const fs: *zstd.FileSystem.MemoryFileSystem = @ptrCast(@alignCast(raw));
    return fs.readFileAlloc(allocator, path);
}

fn memoryWriteFile(raw: *anyopaque, path: []const u8, content: []const u8) anyerror!void {
    const fs: *zstd.FileSystem.MemoryFileSystem = @ptrCast(@alignCast(raw));
    try fs.writeFile(path, content);
}

fn memoryExists(raw: *anyopaque, path: []const u8) anyerror!bool {
    const fs: *zstd.FileSystem.MemoryFileSystem = @ptrCast(@alignCast(raw));
    return fs.exists(path);
}
```

Also include `DiskFiles` in the same file:

```zig
pub const DiskFiles = struct {
    pub fn store(self: *DiskFiles) FileStore {
        return .{
            .ptr = self,
            .readFileAllocFn = diskReadFileAlloc,
            .writeFileFn = diskWriteFile,
            .existsFn = diskExists,
        };
    }
};
```

`diskWriteFile` must call `std.fs.cwd().makePath(dirname)` before writing, where
`dirname` comes from `std.fs.path.dirname(path)`.

- [ ] **Step 4: Implement resource and output JSON persistence**

In `packages/ziac/src/local_state.zig`, add:

```zig
pub const Store = struct {
    allocator: std.mem.Allocator,
    files: FileStore,

    pub fn init(allocator: std.mem.Allocator, files: FileStore) Store {
        return .{ .allocator = allocator, .files = files };
    }

    pub fn resourcesPathAlloc(self: Store, stack: []const u8, stage: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, ".ziac/state/{s}/{s}/resources.json", .{ stack, stage });
    }

    pub fn outputsPathAlloc(self: Store, stack: []const u8, stage: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, ".ziac/state/{s}/{s}/outputs.json", .{ stack, stage });
    }
};
```

Add `saveResources`, `loadResources`, `saveOutputs`, and `loadOutputs` to
`Store`. Use manual deterministic JSON writing with `zstd.Json.escapeStringAlloc`
and parse JSON with `std.json.parseFromSlice(std.json.Value, allocator, json,
.{})`. Status strings must map through helpers:

```zig
pub fn statusName(status: state_mod.ResourceStatus) []const u8 { ... }
pub fn parseStatus(value: []const u8) LocalStateError!state_mod.ResourceStatus { ... }
```

`LoadedResources` and `LoadedOutputs` must own duplicated strings and free them
in `deinit`.

- [ ] **Step 5: Export local state and verify GREEN**

Modify `packages/ziac/src/ziac.zig`:

```zig
pub const local_state = @import("local_state.zig");
```

Run:

```sh
cd packages/ziac && zig build test
```

Expected: PASS.

- [ ] **Step 6: Commit**

Run:

```sh
git add packages/ziac/src/local_state.zig packages/ziac/src/ziac.zig packages/ziac/test/all_test.zig packages/ziac/test/local_state_test.zig
git commit -m "Add Ziac local JSON state store"
```

---

### Task 4: CLI Plan/Deploy/Destroy/Outputs/State Commands

**Files:**
- Create: `packages/ziac/src/cli.zig`
- Modify: `packages/ziac/src/ziac.zig`
- Modify: `packages/ziac/test/all_test.zig`
- Create: `packages/ziac/test/cli_test.zig`

- [ ] **Step 1: Write failing CLI tests**

Create `packages/ziac/test/cli_test.zig`:

```zig
const std = @import("std");
const ziac = @import("ziac");

fn testEnv(fs: *ziac.zstd.FileSystem.MemoryFileSystem, console: *ziac.zstd.Console.CapturedConsole) ziac.cli.Env {
    return .{
        .console = console,
        .registry = ziac.stack_registry.fixtureRegistry(),
        .state = ziac.local_state.Store.init(std.testing.allocator, ziac.local_state.memoryFiles(fs)),
    };
}

test "cli plan prints deterministic create summary without writing state" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();

    var env = testEnv(&fs, &console);
    const code = try ziac.cli.run(std.testing.allocator, &.{ "plan", "--stack", "hello-global", "--stage", "dev" }, &env);

    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "Plan: 1 create, 0 update, 0 delete, 0 noop") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "+ gcp.run.Service api") != null);
    try std.testing.expect(!fs.exists(".ziac/state/hello-global/dev/resources.json"));
}

test "cli deploy persists state and redacted outputs" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();

    var env = testEnv(&fs, &console);
    const code = try ziac.cli.run(std.testing.allocator, &.{ "deploy", "--stack", "hello-global", "--stage", "dev" }, &env);

    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(fs.exists(".ziac/state/hello-global/dev/resources.json"));
    try std.testing.expect(fs.exists(".ziac/state/hello-global/dev/outputs.json"));
    const outputs = fs.readFile(".ziac/state/hello-global/dev/outputs.json").?;
    try std.testing.expect(std.mem.indexOf(u8, outputs, "sentinel-secret-for-tests") == null);
}

test "cli outputs prints redacted secret values" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var env = testEnv(&fs, &console);

    _ = try ziac.cli.run(std.testing.allocator, &.{ "deploy", "--stack", "hello-global", "--stage", "dev" }, &env);
    console.stdout.clearRetainingCapacity();
    const code = try ziac.cli.run(std.testing.allocator, &.{ "outputs", "--stack", "hello-global", "--stage", "dev" }, &env);

    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "url=https://hello-global.example.local") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "database_url=[REDACTED]") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "sentinel-secret-for-tests") == null);
}

test "cli destroy marks resource deleted" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var env = testEnv(&fs, &console);

    _ = try ziac.cli.run(std.testing.allocator, &.{ "deploy", "--stack", "hello-global", "--stage", "dev" }, &env);
    console.stdout.clearRetainingCapacity();
    const code = try ziac.cli.run(std.testing.allocator, &.{ "destroy", "--stack", "hello-global", "--stage", "dev" }, &env);

    try std.testing.expectEqual(@as(u8, 0), code);
    const resources = fs.readFile(".ziac/state/hello-global/dev/resources.json").?;
    try std.testing.expect(std.mem.indexOf(u8, resources, "\"status\":\"deleted\"") != null);
}
```

Modify `packages/ziac/test/all_test.zig` to import `cli_test.zig`.

- [ ] **Step 2: Run test to verify RED**

Run:

```sh
cd packages/ziac && zig build test
```

Expected: FAIL because `ziac.cli` is missing.

- [ ] **Step 3: Implement command parser and env**

Create `packages/ziac/src/cli.zig`:

```zig
const std = @import("std");
const zstd = @import("zigeffect_std");
const apply = @import("apply.zig");
const local_state = @import("local_state.zig");
const plan_mod = @import("plan.zig");
const provider_mod = @import("provider.zig");
const stack_registry = @import("stack_registry.zig");
const state_mod = @import("state.zig");

pub const Exit = struct {
    pub const success: u8 = 0;
    pub const usage: u8 = 2;
    pub const missing_stack: u8 = 3;
    pub const invalid_graph: u8 = 4;
    pub const state_error: u8 = 5;
    pub const provider_error: u8 = 6;
};

pub const Env = struct {
    console: *zstd.Console.CapturedConsole,
    registry: stack_registry.StackRegistry,
    state: local_state.Store,
};
```

Add `commandSpec`, `run`, and `parseArgs`. Use `zstd.Cli.CommandSpec` with
subcommands `plan`, `deploy`, `destroy`, `outputs`, and `state`; each subcommand
must require `--stack` and `--stage`.

- [ ] **Step 4: Implement command handlers**

In `packages/ziac/src/cli.zig`, add handlers:

```zig
fn runPlan(allocator: std.mem.Allocator, env: *Env, args: Args) !u8 { ... }
fn runDeploy(allocator: std.mem.Allocator, env: *Env, args: Args) !u8 { ... }
fn runDestroy(allocator: std.mem.Allocator, env: *Env, args: Args) !u8 { ... }
fn runOutputs(allocator: std.mem.Allocator, env: *Env, args: Args) !u8 { ... }
fn runState(allocator: std.mem.Allocator, env: *Env, args: Args) !u8 { ... }
```

`runPlan` must load resources from local state if present, build a plan, and
print summary counts plus operation lines. `runDeploy` must build the fixture
stack, apply through `provider.FakeProvider`, save resources, and save outputs.
`runDestroy` must load resources, build `buildDestroyPlan`, apply through fake
provider, and save resources. `runOutputs` and `runState` must read JSON state
and print stable lines.

- [ ] **Step 5: Export CLI and verify GREEN**

Modify `packages/ziac/src/ziac.zig`:

```zig
pub const cli = @import("cli.zig");
```

Run:

```sh
cd packages/ziac && zig build test
```

Expected: PASS.

- [ ] **Step 6: Commit**

Run:

```sh
git add packages/ziac/src/cli.zig packages/ziac/src/ziac.zig packages/ziac/test/all_test.zig packages/ziac/test/cli_test.zig
git commit -m "Add Ziac local CLI commands"
```

---

### Task 5: Executable And Example

**Files:**
- Create: `packages/ziac/src/main.zig`
- Create: `packages/ziac/examples/local_cli.zig`
- Modify: `packages/ziac/build.zig`
- Modify: `packages/ziac/build.zig.zon`
- Modify: `packages/ziac/README.md`
- Modify: `packages/ziac/docs/roadmap.md`

- [ ] **Step 1: Write failing example first**

Create `packages/ziac/examples/local_cli.zig`:

```zig
const std = @import("std");
const ziac = @import("ziac");

pub fn runLocalCliExample(allocator: std.mem.Allocator) ![]const u8 {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(allocator);
    defer console.deinit();

    var env = ziac.cli.Env{
        .console = &console,
        .registry = ziac.stack_registry.fixtureRegistry(),
        .state = ziac.local_state.Store.init(allocator, ziac.local_state.memoryFiles(&fs)),
    };

    _ = try ziac.cli.run(allocator, &.{ "plan", "--stack", "hello-global", "--stage", "dev" }, &env);
    _ = try ziac.cli.run(allocator, &.{ "deploy", "--stack", "hello-global", "--stage", "dev" }, &env);
    _ = try ziac.cli.run(allocator, &.{ "outputs", "--stack", "hello-global", "--stage", "dev" }, &env);

    return allocator.dupe(u8, console.stdoutText());
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const output = try runLocalCliExample(allocator);
    defer allocator.free(output);
    std.debug.print("{s}", .{output});
}

test "local CLI example plans deploys and prints redacted outputs" {
    const output = try runLocalCliExample(std.testing.allocator);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "Plan: 1 create") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Deploy complete") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "database_url=[REDACTED]") != null);
}
```

- [ ] **Step 2: Run examples to verify RED**

Run:

```sh
cd packages/ziac && zig build examples
```

Expected: FAIL because the example is not wired into `build.zig`.

- [ ] **Step 3: Add executable and example build wiring**

Modify `packages/ziac/build.zig`:

```zig
const cli_module = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});
cli_module.addImport("ziac", ziac);

const executable = b.addExecutable(.{
    .name = "ziac",
    .root_module = cli_module,
});
b.installArtifact(executable);
```

Add a helper like the `zigeffect-std` examples helper and wire:

```zig
addExample(b, examples_step, target, optimize, ziac, "local-cli", "examples/local_cli.zig");
```

Modify `packages/ziac/build.zig.zon` to include `"examples"`.

- [ ] **Step 4: Implement main wrapper**

Create `packages/ziac/src/main.zig`:

```zig
const std = @import("std");
const ziac = @import("ziac");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var console = ziac.zstd.Console.CapturedConsole.init(allocator);
    defer console.deinit();
    var disk = ziac.local_state.DiskFiles{};
    var env = ziac.cli.Env{
        .console = &console,
        .registry = ziac.stack_registry.fixtureRegistry(),
        .state = ziac.local_state.Store.init(allocator, disk.store()),
    };

    const code = try ziac.cli.run(allocator, args[1..], &env);
    if (console.stdoutText().len > 0) std.debug.print("{s}", .{console.stdoutText()});
    if (console.stderrText().len > 0) std.debug.print("{s}", .{console.stderrText()});
    std.process.exit(code);
}
```

- [ ] **Step 5: Document CLI commands**

Update `packages/ziac/README.md` with:

```markdown
## Local CLI

```sh
cd packages/ziac
zig build
zig-out/bin/ziac plan --stack hello-global --stage dev
zig-out/bin/ziac deploy --stack hello-global --stage dev
zig-out/bin/ziac outputs --stack hello-global --stage dev
zig-out/bin/ziac destroy --stack hello-global --stage dev
```
```

Update `packages/ziac/docs/roadmap.md` Phase 2 to note local CLI and JSON state
are implemented by this slice.

- [ ] **Step 6: Verify GREEN**

Run:

```sh
cd packages/ziac && zig build test
cd packages/ziac && zig build examples
cd packages/ziac && zig build
```

Expected: all commands PASS.

- [ ] **Step 7: Commit**

Run:

```sh
git add packages/ziac/src/main.zig packages/ziac/examples/local_cli.zig packages/ziac/build.zig packages/ziac/build.zig.zon packages/ziac/README.md packages/ziac/docs/roadmap.md
git commit -m "Add Ziac executable and local CLI example"
```

---

### Task 6: Final Verification

**Files:**
- Verify: `packages/ziac/**`
- Verify: `package.json`

- [ ] **Step 1: Run Ziac package tests**

Run:

```sh
bun run ziac:test
```

Expected: PASS.

- [ ] **Step 2: Run Ziac examples**

Run:

```sh
bun run ziac:examples
```

Expected: PASS.

- [ ] **Step 3: Run standard library tests**

Run:

```sh
bun run zigeffect:std:test
```

Expected: PASS.

- [ ] **Step 4: Run engine tests**

Run:

```sh
bun run zigeffect:test
```

Expected: PASS.

- [ ] **Step 5: Run whitespace verification**

Run:

```sh
git diff --check
```

Expected: PASS with no output.

- [ ] **Step 6: Review git diff scope**

Run:

```sh
git diff --stat zigeffect-engine-cleanup...HEAD
git status --short
```

Expected: diff only touches `packages/ziac/**`, the implementation plan, and
Ziac docs; working tree is clean after commits.
