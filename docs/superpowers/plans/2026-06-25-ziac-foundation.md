# Ziac Foundation Implementation Plan

**Canonical status:** Shipped. This is a historical TDD execution record; its
original task boxes were not maintained after delivery and are superseded by
`packages/ziac/docs/shipped.md`.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create the first working `/packages/ziac` package: a zigeffect-backed IaC foundation with graph/output/state/planner/provider/apply primitives and fake-provider tests, without touching live GCP yet.

**Architecture:** Ziac starts as a separate Zig package that imports `../zigeffect/src/zigeffect.zig` directly, following the `packages/zgroach` package pattern. The first slice builds a deterministic in-memory engine: typed resource/output graph, local state model, planner, fake provider lifecycle, and apply execution hooks. GCP global Cloud Run components come after this foundation is green.

**Tech Stack:** Zig 0.16, `std.ArrayList(...).empty` allocation style, `std.StringHashMap`, zigeffect facade import, Bun workspace scripts, `zig build test`.

---

## Scope Check

The approved Ziac vision covers multiple subsystems: core engine, GCP provider,
Cloud Run global load balancing, CockroachDB data bindings, CLI, multi-stack
references, and production hardening. This plan intentionally implements only
the first standalone foundation slice:

```text
packages/ziac scaffold
core names/diagnostics
outputs and secret references
resource graph
state records and in-memory state store
planner
provider lifecycle vtable and fake provider
apply engine skeleton
docs seeded inside packages/ziac/docs
```

Live GCP, image building, Cloud Run, load balancers, CockroachDB provider/data
components, and CLI binaries are separate follow-up plans.

## File Structure

Create:

- `packages/ziac/build.zig` — package build and test step, importing sibling zigeffect.
- `packages/ziac/build.zig.zon` — package metadata and included paths.
- `packages/ziac/README.md` — short product description and first verification command.
- `packages/ziac/src/ziac.zig` — public facade.
- `packages/ziac/src/core.zig` — names, IDs, validation helpers, diagnostics.
- `packages/ziac/src/output.zig` — `Output(T)`, output references, secret references.
- `packages/ziac/src/resource.zig` — resource nodes, dependency edges, graph registration, cycle detection.
- `packages/ziac/src/state.zig` — resource state records and in-memory state store.
- `packages/ziac/src/plan.zig` — plan operation model and deterministic planner.
- `packages/ziac/src/provider.zig` — provider operation vtable and fake provider.
- `packages/ziac/src/apply.zig` — apply executor over fake-provider-capable plans.
- `packages/ziac/test/all_test.zig` — aggregate test imports.
- `packages/ziac/test/smoke_test.zig` — package import and zigeffect import smoke test.
- `packages/ziac/test/core_test.zig` — name validation and physical name tests.
- `packages/ziac/test/output_test.zig` — output and secret reference tests.
- `packages/ziac/test/resource_graph_test.zig` — graph registration and cycle tests.
- `packages/ziac/test/state_test.zig` — state store tests.
- `packages/ziac/test/plan_test.zig` — planner tests.
- `packages/ziac/test/provider_apply_test.zig` — fake provider and apply tests.
- `packages/ziac/docs/vision.md` — short copy of current product vision.
- `packages/ziac/docs/roadmap.md` — first package-local roadmap.
- `packages/ziac/docs/architecture.md` — package architecture summary.

Modify:

- `package.json` — add `ziac:test` and `ziac:examples` scripts.

Do not modify:

- `packages/zigeffect/**` in this plan.
- existing zigeffect uncommitted files.
- live Alchemy stack files.

---

### Task 1: Scaffold Buildable Package

**Files:**
- Create: `packages/ziac/build.zig`
- Create: `packages/ziac/build.zig.zon`
- Create: `packages/ziac/src/ziac.zig`
- Create: `packages/ziac/test/all_test.zig`
- Create: `packages/ziac/test/smoke_test.zig`
- Create: `packages/ziac/README.md`
- Modify: `package.json`

- [ ] **Step 1: Create the failing smoke test first**

Create `packages/ziac/test/smoke_test.zig`:

```zig
const std = @import("std");
const ziac = @import("ziac");

test "ziac facade exposes product name and zigeffect facade" {
    try std.testing.expectEqualStrings("Ziac", ziac.product_name);
    const _ = ziac.fx.Effect;
}
```

Create `packages/ziac/test/all_test.zig`:

```zig
comptime {
    _ = @import("smoke_test.zig");
}
```

- [ ] **Step 2: Run the smoke test and verify RED**

Run:

```sh
cd packages/ziac && zig test test/all_test.zig
```

Expected: FAIL because the `ziac` module is not configured yet. A valid failure mentions that module `ziac` cannot be found.

- [ ] **Step 3: Add the package build file**

Create `packages/ziac/build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigeffect = b.createModule(.{
        .root_source_file = b.path("../zigeffect/src/zigeffect.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ziac = b.addModule("ziac", .{
        .root_source_file = b.path("src/ziac.zig"),
        .target = target,
        .optimize = optimize,
    });
    ziac.addImport("zigeffect", zigeffect);

    const tests = b.createModule(.{
        .root_source_file = b.path("test/all_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.addImport("zigeffect", zigeffect);
    tests.addImport("ziac", ziac);

    const unit_tests = b.addTest(.{
        .name = "ziac-tests",
        .root_module = tests,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run Ziac tests");
    test_step.dependOn(&run_unit_tests.step);

    const examples_step = b.step("examples", "Build Ziac examples");
    examples_step.dependOn(test_step);
}
```

Create `packages/ziac/build.zig.zon`:

```zig
.{
    .name = .ziac,
    .version = "0.1.0",
    .minimum_zig_version = "0.16.0",
    .paths = .{
        "README.md",
        "build.zig",
        "build.zig.zon",
        "src",
        "test",
    },
}
```

- [ ] **Step 4: Add the minimal facade**

Create `packages/ziac/src/ziac.zig`:

```zig
pub const product_name = "Ziac";
pub const fx = @import("zigeffect");
```

Create `packages/ziac/README.md`:

```markdown
# Ziac

Ziac is a comptime-checked Infrastructure-as-Code engine for Zig backends,
powered by zigeffect.

The first product target is an AWSx-style high-level GCP component for globally
routed Cloud Run deployments of Zig HTTP services.

```sh
cd packages/ziac
zig build test
```
```

- [ ] **Step 5: Add root scripts**

Modify `package.json` scripts by adding these entries near the existing Zig scripts:

```json
"ziac:test": "cd packages/ziac && zig build test",
"ziac:examples": "cd packages/ziac && zig build examples",
```

Do not remove existing scripts.

- [ ] **Step 6: Verify GREEN**

Run:

```sh
cd packages/ziac && zig build test
```

Expected: PASS.

Run:

```sh
bun run ziac:test
```

Expected: PASS.

Run:

```sh
bun run ziac:examples
```

Expected: PASS. In this foundation slice, the `examples` build step depends on the package tests until real examples exist.

- [ ] **Step 7: Commit**

Run:

```sh
git add package.json packages/ziac
git commit -m "Add Ziac package scaffold"
```

Expected: commit succeeds and only `package.json` plus `packages/ziac/**` are staged.

---

### Task 2: Core Names And Diagnostics

**Files:**
- Create: `packages/ziac/src/core.zig`
- Modify: `packages/ziac/src/ziac.zig`
- Modify: `packages/ziac/test/all_test.zig`
- Create: `packages/ziac/test/core_test.zig`

- [ ] **Step 1: Write failing core tests**

Create `packages/ziac/test/core_test.zig`:

```zig
const std = @import("std");
const ziac = @import("ziac");

test "logical ids reject empty strings and path separators" {
    try std.testing.expectError(error.EmptyName, ziac.core.validateLogicalId(""));
    try std.testing.expectError(error.InvalidName, ziac.core.validateLogicalId("api/prod"));
    try std.testing.expectError(error.InvalidName, ziac.core.validateLogicalId("api prod"));
    try ziac.core.validateLogicalId("api-prod_1");
}

test "physical names are stable from stack stage and logical id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const name = try ziac.core.physicalName(
        arena.allocator(),
        .{ .stack = "hello", .stage = "dev", .logical_id = "api" },
    );

    try std.testing.expectEqualStrings("hello-dev-api", name);
}

test "diagnostic formats code and message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const diagnostic = ziac.core.Diagnostic{
        .code = "ZIAC001",
        .message = "missing provider",
        .subject = "gcp",
    };

    const text = try diagnostic.format(arena.allocator());
    try std.testing.expectEqualStrings("ZIAC001: missing provider (gcp)", text);
}
```

Modify `packages/ziac/test/all_test.zig`:

```zig
comptime {
    _ = @import("smoke_test.zig");
    _ = @import("core_test.zig");
}
```

- [ ] **Step 2: Run test to verify RED**

Run:

```sh
cd packages/ziac && zig build test
```

Expected: FAIL because `ziac.core` is not exported.

- [ ] **Step 3: Implement core module**

Create `packages/ziac/src/core.zig`:

```zig
const std = @import("std");

pub const CoreError = error{
    EmptyName,
    InvalidName,
    OutOfMemory,
};

pub const PhysicalNameInput = struct {
    stack: []const u8,
    stage: []const u8,
    logical_id: []const u8,
};

pub const Diagnostic = struct {
    code: []const u8,
    message: []const u8,
    subject: []const u8,

    pub fn format(self: Diagnostic, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        return std.fmt.allocPrint(
            allocator,
            "{s}: {s} ({s})",
            .{ self.code, self.message, self.subject },
        );
    }
};

pub fn validateLogicalId(value: []const u8) CoreError!void {
    if (value.len == 0) return error.EmptyName;
    for (value) |char| {
        const ok =
            (char >= 'a' and char <= 'z') or
            (char >= 'A' and char <= 'Z') or
            (char >= '0' and char <= '9') or
            char == '-' or
            char == '_';
        if (!ok) return error.InvalidName;
    }
}

pub fn physicalName(
    allocator: std.mem.Allocator,
    input: PhysicalNameInput,
) CoreError![]const u8 {
    try validateLogicalId(input.stack);
    try validateLogicalId(input.stage);
    try validateLogicalId(input.logical_id);
    return std.fmt.allocPrint(
        allocator,
        "{s}-{s}-{s}",
        .{ input.stack, input.stage, input.logical_id },
    );
}
```

Modify `packages/ziac/src/ziac.zig`:

```zig
pub const product_name = "Ziac";
pub const fx = @import("zigeffect");

pub const core = @import("core.zig");
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
git add packages/ziac/src/core.zig packages/ziac/src/ziac.zig packages/ziac/test/all_test.zig packages/ziac/test/core_test.zig
git commit -m "Add Ziac core names and diagnostics"
```

---

### Task 3: Outputs And Secret References

**Files:**
- Create: `packages/ziac/src/output.zig`
- Modify: `packages/ziac/src/ziac.zig`
- Modify: `packages/ziac/test/all_test.zig`
- Create: `packages/ziac/test/output_test.zig`

- [ ] **Step 1: Write failing output tests**

Create `packages/ziac/test/output_test.zig`:

```zig
const std = @import("std");
const ziac = @import("ziac");

test "known output stores a value" {
    const value = ziac.Output([]const u8).known("https://example.com");
    try std.testing.expect(value == .value);
    try std.testing.expectEqualStrings("https://example.com", value.value);
}

test "resource output stores resource and field reference" {
    const value = ziac.Output([]const u8).fromResource("gcp.run.Service.api", "url");
    try std.testing.expect(value == .resource_ref);
    try std.testing.expectEqualStrings("gcp.run.Service.api", value.resource_ref.resource_id);
    try std.testing.expectEqualStrings("url", value.resource_ref.field);
}

test "secret ref is never a plain string output" {
    const secret = ziac.SecretRef.named("database-url");
    try std.testing.expectEqualStrings("database-url", secret.name);
}
```

Modify `packages/ziac/test/all_test.zig`:

```zig
comptime {
    _ = @import("smoke_test.zig");
    _ = @import("core_test.zig");
    _ = @import("output_test.zig");
}
```

- [ ] **Step 2: Run test to verify RED**

Run:

```sh
cd packages/ziac && zig build test
```

Expected: FAIL because `ziac.Output` and `ziac.SecretRef` are missing.

- [ ] **Step 3: Implement outputs**

Create `packages/ziac/src/output.zig`:

```zig
pub const OutputRef = struct {
    resource_id: []const u8,
    field: []const u8,
};

pub const SecretRef = struct {
    name: []const u8,

    pub fn named(name: []const u8) SecretRef {
        return .{ .name = name };
    }
};

pub fn Output(comptime T: type) type {
    return union(enum) {
        value: T,
        resource_ref: OutputRef,
        unknown_reason: []const u8,

        pub fn known(value: T) @This() {
            return .{ .value = value };
        }

        pub fn fromResource(resource_id: []const u8, field: []const u8) @This() {
            return .{ .resource_ref = .{ .resource_id = resource_id, .field = field } };
        }

        pub fn unknown(reason: []const u8) @This() {
            return .{ .unknown_reason = reason };
        }
    };
}
```

Modify `packages/ziac/src/ziac.zig`:

```zig
pub const product_name = "Ziac";
pub const fx = @import("zigeffect");

pub const core = @import("core.zig");
pub const output = @import("output.zig");

pub const Output = output.Output;
pub const OutputRef = output.OutputRef;
pub const SecretRef = output.SecretRef;
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
git add packages/ziac/src/output.zig packages/ziac/src/ziac.zig packages/ziac/test/all_test.zig packages/ziac/test/output_test.zig
git commit -m "Add Ziac outputs and secret references"
```

---

### Task 4: Resource Graph And Cycle Detection

**Files:**
- Create: `packages/ziac/src/resource.zig`
- Modify: `packages/ziac/src/ziac.zig`
- Modify: `packages/ziac/test/all_test.zig`
- Create: `packages/ziac/test/resource_graph_test.zig`

- [ ] **Step 1: Write failing graph tests**

Create `packages/ziac/test/resource_graph_test.zig`:

```zig
const std = @import("std");
const ziac = @import("ziac");

test "resource graph registers resources and dependencies" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();

    try graph.addResource(.{
        .id = "gcp.run.Service.api",
        .type_name = "gcp.run.Service",
        .logical_id = "api",
    });
    try graph.addResource(.{
        .id = "gcp.loadbalancing.BackendService.api",
        .type_name = "gcp.loadbalancing.BackendService",
        .logical_id = "api-backend",
    });
    try graph.addDependency("gcp.loadbalancing.BackendService.api", "gcp.run.Service.api");

    try std.testing.expectEqual(@as(usize, 2), graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 1), graph.dependencies.items.len);
    try graph.validateAcyclic();
}

test "resource graph rejects duplicate resource ids" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();

    try graph.addResource(.{
        .id = "gcp.run.Service.api",
        .type_name = "gcp.run.Service",
        .logical_id = "api",
    });
    try std.testing.expectError(error.DuplicateResource, graph.addResource(.{
        .id = "gcp.run.Service.api",
        .type_name = "gcp.run.Service",
        .logical_id = "api-copy",
    }));
}

test "resource graph detects a dependency cycle" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();

    try graph.addResource(.{ .id = "a", .type_name = "test.A", .logical_id = "a" });
    try graph.addResource(.{ .id = "b", .type_name = "test.B", .logical_id = "b" });
    try graph.addDependency("a", "b");
    try graph.addDependency("b", "a");

    try std.testing.expectError(error.DependencyCycle, graph.validateAcyclic());
}
```

Modify `packages/ziac/test/all_test.zig`:

```zig
comptime {
    _ = @import("smoke_test.zig");
    _ = @import("core_test.zig");
    _ = @import("output_test.zig");
    _ = @import("resource_graph_test.zig");
}
```

- [ ] **Step 2: Run test to verify RED**

Run:

```sh
cd packages/ziac && zig build test
```

Expected: FAIL because `ziac.ResourceGraph` is missing.

- [ ] **Step 3: Implement resource graph**

Create `packages/ziac/src/resource.zig`:

```zig
const std = @import("std");

pub const ResourceGraphError = error{
    DuplicateResource,
    MissingResource,
    DependencyCycle,
    OutOfMemory,
};

pub const ResourceNode = struct {
    id: []const u8,
    type_name: []const u8,
    logical_id: []const u8,
};

pub const DependencyEdge = struct {
    from: []const u8,
    to: []const u8,
};

pub const ResourceGraph = struct {
    allocator: std.mem.Allocator,
    resources: std.ArrayList(ResourceNode),
    dependencies: std.ArrayList(DependencyEdge),

    pub fn init(allocator: std.mem.Allocator) ResourceGraph {
        return .{
            .allocator = allocator,
            .resources = std.ArrayList(ResourceNode).empty,
            .dependencies = std.ArrayList(DependencyEdge).empty,
        };
    }

    pub fn deinit(self: *ResourceGraph) void {
        self.resources.deinit(self.allocator);
        self.dependencies.deinit(self.allocator);
    }

    pub fn addResource(self: *ResourceGraph, node: ResourceNode) ResourceGraphError!void {
        if (self.indexOf(node.id) != null) return error.DuplicateResource;
        try self.resources.append(self.allocator, node);
    }

    pub fn addDependency(self: *ResourceGraph, from: []const u8, to: []const u8) ResourceGraphError!void {
        if (self.indexOf(from) == null) return error.MissingResource;
        if (self.indexOf(to) == null) return error.MissingResource;
        try self.dependencies.append(self.allocator, .{ .from = from, .to = to });
    }

    pub fn validateAcyclic(self: *const ResourceGraph) ResourceGraphError!void {
        for (self.resources.items) |node| {
            if (try self.hasPath(node.id, node.id, 0)) return error.DependencyCycle;
        }
    }

    fn indexOf(self: *const ResourceGraph, id: []const u8) ?usize {
        for (self.resources.items, 0..) |node, index| {
            if (std.mem.eql(u8, node.id, id)) return index;
        }
        return null;
    }

    fn hasPath(self: *const ResourceGraph, start: []const u8, target: []const u8, depth: usize) ResourceGraphError!bool {
        if (depth > self.resources.items.len) return error.DependencyCycle;
        for (self.dependencies.items) |edge| {
            if (!std.mem.eql(u8, edge.from, start)) continue;
            if (std.mem.eql(u8, edge.to, target)) return true;
            if (try self.hasPath(edge.to, target, depth + 1)) return true;
        }
        return false;
    }
};
```

Modify `packages/ziac/src/ziac.zig`:

```zig
pub const product_name = "Ziac";
pub const fx = @import("zigeffect");

pub const core = @import("core.zig");
pub const output = @import("output.zig");
pub const resource = @import("resource.zig");

pub const Output = output.Output;
pub const OutputRef = output.OutputRef;
pub const SecretRef = output.SecretRef;
pub const ResourceGraph = resource.ResourceGraph;
pub const ResourceNode = resource.ResourceNode;
pub const DependencyEdge = resource.DependencyEdge;
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
git add packages/ziac/src/resource.zig packages/ziac/src/ziac.zig packages/ziac/test/all_test.zig packages/ziac/test/resource_graph_test.zig
git commit -m "Add Ziac resource graph"
```

---

### Task 5: State Records And In-Memory State Store

**Files:**
- Create: `packages/ziac/src/state.zig`
- Modify: `packages/ziac/src/ziac.zig`
- Modify: `packages/ziac/test/all_test.zig`
- Create: `packages/ziac/test/state_test.zig`

- [ ] **Step 1: Write failing state tests**

Create `packages/ziac/test/state_test.zig`:

```zig
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
```

Modify `packages/ziac/test/all_test.zig`:

```zig
comptime {
    _ = @import("smoke_test.zig");
    _ = @import("core_test.zig");
    _ = @import("output_test.zig");
    _ = @import("resource_graph_test.zig");
    _ = @import("state_test.zig");
}
```

- [ ] **Step 2: Run test to verify RED**

Run:

```sh
cd packages/ziac && zig build test
```

Expected: FAIL because `ziac.InMemoryStateStore` is missing.

- [ ] **Step 3: Implement state module**

Create `packages/ziac/src/state.zig`:

```zig
const std = @import("std");

pub const StateError = error{
    MissingRecord,
    OutOfMemory,
};

pub const ResourceStatus = enum {
    planned,
    creating,
    created,
    updating,
    updated,
    replacing,
    deleting,
    deleted,
    failed,
    tainted,
    adopted,
};

pub const StateRecord = struct {
    resource_id: []const u8,
    type_name: []const u8,
    logical_id: []const u8,
    inputs_hash: []const u8,
    status: ResourceStatus,
};

pub const InMemoryStateStore = struct {
    allocator: std.mem.Allocator,
    records: std.StringHashMap(StateRecord),

    pub fn init(allocator: std.mem.Allocator) InMemoryStateStore {
        return .{
            .allocator = allocator,
            .records = std.StringHashMap(StateRecord).init(allocator),
        };
    }

    pub fn deinit(self: *InMemoryStateStore) void {
        self.records.deinit();
    }

    pub fn put(self: *InMemoryStateStore, record: StateRecord) StateError!void {
        try self.records.put(record.resource_id, record);
    }

    pub fn get(self: *InMemoryStateStore, resource_id: []const u8) ?StateRecord {
        return self.records.get(resource_id);
    }

    pub fn markFailed(self: *InMemoryStateStore, resource_id: []const u8) StateError!void {
        var record = self.records.get(resource_id) orelse return error.MissingRecord;
        record.status = .failed;
        try self.records.put(resource_id, record);
    }
};
```

Modify `packages/ziac/src/ziac.zig`:

```zig
pub const product_name = "Ziac";
pub const fx = @import("zigeffect");

pub const core = @import("core.zig");
pub const output = @import("output.zig");
pub const resource = @import("resource.zig");
pub const state = @import("state.zig");

pub const Output = output.Output;
pub const OutputRef = output.OutputRef;
pub const SecretRef = output.SecretRef;
pub const ResourceGraph = resource.ResourceGraph;
pub const ResourceNode = resource.ResourceNode;
pub const DependencyEdge = resource.DependencyEdge;
pub const ResourceStatus = state.ResourceStatus;
pub const StateRecord = state.StateRecord;
pub const InMemoryStateStore = state.InMemoryStateStore;
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
git add packages/ziac/src/state.zig packages/ziac/src/ziac.zig packages/ziac/test/all_test.zig packages/ziac/test/state_test.zig
git commit -m "Add Ziac in-memory state store"
```

---

### Task 6: Deterministic Planner

**Files:**
- Create: `packages/ziac/src/plan.zig`
- Modify: `packages/ziac/src/ziac.zig`
- Modify: `packages/ziac/test/all_test.zig`
- Create: `packages/ziac/test/plan_test.zig`

- [ ] **Step 1: Write failing planner tests**

Create `packages/ziac/test/plan_test.zig`:

```zig
const std = @import("std");
const ziac = @import("ziac");

test "planner creates missing resources" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();

    try graph.addResource(.{
        .id = "gcp.run.Service.api",
        .type_name = "gcp.run.Service",
        .logical_id = "api",
    });

    var plan = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer plan.deinit();

    try std.testing.expectEqual(@as(usize, 1), plan.operations.len);
    try std.testing.expectEqual(ziac.plan.OperationKind.create, plan.operations[0].kind);
}

test "planner noops resources with matching state" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();

    try graph.addResource(.{
        .id = "gcp.run.Service.api",
        .type_name = "gcp.run.Service",
        .logical_id = "api",
    });
    try state.put(.{
        .resource_id = "gcp.run.Service.api",
        .type_name = "gcp.run.Service",
        .logical_id = "api",
        .inputs_hash = "v1",
        .status = .created,
    });

    var plan = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer plan.deinit();

    try std.testing.expectEqual(@as(usize, 1), plan.operations.len);
    try std.testing.expectEqual(ziac.plan.OperationKind.noop, plan.operations[0].kind);
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
}
```

- [ ] **Step 2: Run test to verify RED**

Run:

```sh
cd packages/ziac && zig build test
```

Expected: FAIL because `ziac.plan.buildPlan` is missing.

- [ ] **Step 3: Implement planner**

Create `packages/ziac/src/plan.zig`:

```zig
const std = @import("std");
const resource = @import("resource.zig");
const state = @import("state.zig");

pub const PlanError = error{
    DependencyCycle,
    OutOfMemory,
};

pub const OperationKind = enum {
    create,
    update,
    replace,
    delete,
    read,
    noop,
};

pub const PlanOperation = struct {
    kind: OperationKind,
    resource: resource.ResourceNode,
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    operations: []PlanOperation,

    pub fn deinit(self: *Plan) void {
        self.allocator.free(self.operations);
    }
};

pub fn buildPlan(
    allocator: std.mem.Allocator,
    graph: *const resource.ResourceGraph,
    store: *state.InMemoryStateStore,
) PlanError!Plan {
    try graph.validateAcyclic();

    var operations = std.ArrayList(PlanOperation).empty;
    errdefer operations.deinit(allocator);

    for (graph.resources.items) |node| {
        const existing = store.get(node.id);
        const kind: OperationKind = if (existing == null) .create else .noop;
        try operations.append(allocator, .{ .kind = kind, .resource = node });
    }

    return .{
        .allocator = allocator,
        .operations = try operations.toOwnedSlice(allocator),
    };
}
```

Modify `packages/ziac/src/ziac.zig`:

```zig
pub const product_name = "Ziac";
pub const fx = @import("zigeffect");

pub const core = @import("core.zig");
pub const output = @import("output.zig");
pub const resource = @import("resource.zig");
pub const state = @import("state.zig");
pub const plan = @import("plan.zig");

pub const Output = output.Output;
pub const OutputRef = output.OutputRef;
pub const SecretRef = output.SecretRef;
pub const ResourceGraph = resource.ResourceGraph;
pub const ResourceNode = resource.ResourceNode;
pub const DependencyEdge = resource.DependencyEdge;
pub const ResourceStatus = state.ResourceStatus;
pub const StateRecord = state.StateRecord;
pub const InMemoryStateStore = state.InMemoryStateStore;
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
git add packages/ziac/src/plan.zig packages/ziac/src/ziac.zig packages/ziac/test/all_test.zig packages/ziac/test/plan_test.zig
git commit -m "Add Ziac deterministic planner"
```

---

### Task 7: Provider Lifecycle And Apply Engine

**Files:**
- Create: `packages/ziac/src/provider.zig`
- Create: `packages/ziac/src/apply.zig`
- Modify: `packages/ziac/src/ziac.zig`
- Modify: `packages/ziac/test/all_test.zig`
- Create: `packages/ziac/test/provider_apply_test.zig`

- [ ] **Step 1: Write failing provider/apply tests**

Create `packages/ziac/test/provider_apply_test.zig`:

```zig
const std = @import("std");
const ziac = @import("ziac");

test "fake provider records reconcile for create operations" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();

    try graph.addResource(.{
        .id = "gcp.run.Service.api",
        .type_name = "gcp.run.Service",
        .logical_id = "api",
    });

    var planned = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer planned.deinit();

    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();

    try ziac.apply.applyPlan(std.testing.allocator, &planned, &state, fake.provider());

    try std.testing.expectEqual(@as(usize, 1), fake.reconciled.items.len);
    try std.testing.expectEqualStrings("gcp.run.Service.api", fake.reconciled.items[0]);

    const record = state.get("gcp.run.Service.api") orelse return error.MissingRecord;
    try std.testing.expectEqual(ziac.ResourceStatus.created, record.status);
}

test "fake provider failure marks state failed" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();

    try graph.addResource(.{
        .id = "gcp.run.Service.api",
        .type_name = "gcp.run.Service",
        .logical_id = "api",
    });

    var planned = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer planned.deinit();

    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    fake.fail_reconcile = true;

    try std.testing.expectError(
        error.ProviderFailed,
        ziac.apply.applyPlan(std.testing.allocator, &planned, &state, fake.provider()),
    );

    const record = state.get("gcp.run.Service.api") orelse return error.MissingRecord;
    try std.testing.expectEqual(ziac.ResourceStatus.failed, record.status);
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
}
```

- [ ] **Step 2: Run test to verify RED**

Run:

```sh
cd packages/ziac && zig build test
```

Expected: FAIL because provider and apply modules are missing.

- [ ] **Step 3: Implement provider module**

Create `packages/ziac/src/provider.zig`:

```zig
const std = @import("std");
const resource = @import("resource.zig");

pub const ProviderError = error{
    ProviderFailed,
    OutOfMemory,
};

pub const Provider = struct {
    ptr: *anyopaque,
    reconcileFn: *const fn (*anyopaque, resource.ResourceNode) ProviderError!void,
    deleteFn: *const fn (*anyopaque, resource.ResourceNode) ProviderError!void,

    pub fn reconcile(self: Provider, node: resource.ResourceNode) ProviderError!void {
        return self.reconcileFn(self.ptr, node);
    }

    pub fn delete(self: Provider, node: resource.ResourceNode) ProviderError!void {
        return self.deleteFn(self.ptr, node);
    }
};

pub const FakeProvider = struct {
    allocator: std.mem.Allocator,
    reconciled: std.ArrayList([]const u8),
    deleted: std.ArrayList([]const u8),
    fail_reconcile: bool = false,
    fail_delete: bool = false,

    pub fn init(allocator: std.mem.Allocator) FakeProvider {
        return .{
            .allocator = allocator,
            .reconciled = std.ArrayList([]const u8).empty,
            .deleted = std.ArrayList([]const u8).empty,
        };
    }

    pub fn deinit(self: *FakeProvider) void {
        self.reconciled.deinit(self.allocator);
        self.deleted.deinit(self.allocator);
    }

    pub fn provider(self: *FakeProvider) Provider {
        return .{
            .ptr = self,
            .reconcileFn = reconcile,
            .deleteFn = delete,
        };
    }

    fn reconcile(raw: *anyopaque, node: resource.ResourceNode) ProviderError!void {
        const self: *FakeProvider = @ptrCast(@alignCast(raw));
        if (self.fail_reconcile) return error.ProviderFailed;
        try self.reconciled.append(self.allocator, node.id);
    }

    fn delete(raw: *anyopaque, node: resource.ResourceNode) ProviderError!void {
        const self: *FakeProvider = @ptrCast(@alignCast(raw));
        if (self.fail_delete) return error.ProviderFailed;
        try self.deleted.append(self.allocator, node.id);
    }
};
```

- [ ] **Step 4: Implement apply module**

Create `packages/ziac/src/apply.zig`:

```zig
const std = @import("std");
const plan_mod = @import("plan.zig");
const provider_mod = @import("provider.zig");
const state_mod = @import("state.zig");

pub const ApplyError = error{
    ProviderFailed,
    MissingRecord,
    OutOfMemory,
};

pub fn applyPlan(
    allocator: std.mem.Allocator,
    planned: *const plan_mod.Plan,
    store: *state_mod.InMemoryStateStore,
    provider: provider_mod.Provider,
) ApplyError!void {
    _ = allocator;

    for (planned.operations) |operation| {
        switch (operation.kind) {
            .create, .update, .replace => {
                try store.put(.{
                    .resource_id = operation.resource.id,
                    .type_name = operation.resource.type_name,
                    .logical_id = operation.resource.logical_id,
                    .inputs_hash = "v1",
                    .status = .creating,
                });
                provider.reconcile(operation.resource) catch |err| {
                    try store.markFailed(operation.resource.id);
                    return err;
                };
                try store.put(.{
                    .resource_id = operation.resource.id,
                    .type_name = operation.resource.type_name,
                    .logical_id = operation.resource.logical_id,
                    .inputs_hash = "v1",
                    .status = .created,
                });
            },
            .delete => {
                provider.delete(operation.resource) catch |err| {
                    try store.markFailed(operation.resource.id);
                    return err;
                };
                try store.put(.{
                    .resource_id = operation.resource.id,
                    .type_name = operation.resource.type_name,
                    .logical_id = operation.resource.logical_id,
                    .inputs_hash = "v1",
                    .status = .deleted,
                });
            },
            .read, .noop => {},
        }
    }
}
```

- [ ] **Step 5: Export provider and apply modules**

Modify `packages/ziac/src/ziac.zig`:

```zig
pub const product_name = "Ziac";
pub const fx = @import("zigeffect");

pub const core = @import("core.zig");
pub const output = @import("output.zig");
pub const resource = @import("resource.zig");
pub const state = @import("state.zig");
pub const plan = @import("plan.zig");
pub const provider = @import("provider.zig");
pub const apply = @import("apply.zig");

pub const Output = output.Output;
pub const OutputRef = output.OutputRef;
pub const SecretRef = output.SecretRef;
pub const ResourceGraph = resource.ResourceGraph;
pub const ResourceNode = resource.ResourceNode;
pub const DependencyEdge = resource.DependencyEdge;
pub const ResourceStatus = state.ResourceStatus;
pub const StateRecord = state.StateRecord;
pub const InMemoryStateStore = state.InMemoryStateStore;
```

- [ ] **Step 6: Verify GREEN**

Run:

```sh
cd packages/ziac && zig build test
```

Expected: PASS.

- [ ] **Step 7: Commit**

Run:

```sh
git add packages/ziac/src/provider.zig packages/ziac/src/apply.zig packages/ziac/src/ziac.zig packages/ziac/test/all_test.zig packages/ziac/test/provider_apply_test.zig
git commit -m "Add Ziac provider lifecycle and apply engine"
```

---

### Task 8: Seed Package Documentation

**Files:**
- Create: `packages/ziac/docs/vision.md`
- Create: `packages/ziac/docs/architecture.md`
- Create: `packages/ziac/docs/roadmap.md`
- Modify: `packages/ziac/build.zig.zon`

- [ ] **Step 1: Create package docs**

Create `packages/ziac/docs/vision.md`:

```markdown
# Ziac Vision

Ziac is a comptime-checked Infrastructure-as-Code engine for Zig backends,
powered by zigeffect.

The first product promise is simple: deploy a Zig HTTP service globally on
Google Cloud Run behind a global HTTPS load balancer without hand-assembling the
cloud resource graph.

Ziac follows an AWSx-style product model: high-level components first, raw
resources second. The first high-level components are:

- `ziac.gcp.global.ContainerService`
- `ziac.gcp.global.ZigService`

CockroachDB is the first data provider. Ziac should make database connection
secrets, TLS certificates, and app environment contracts part of the same
comptime-validated graph as the GCP service.
```

Create `packages/ziac/docs/architecture.md`:

```markdown
# Ziac Architecture

Ziac is a separate package from zigeffect. zigeffect provides effects, layers,
structured concurrency, scopes, and causal traces. Ziac provides the IaC product
layer: stacks, resources, outputs, providers, state, plans, applies, and
component libraries.

Initial source domains:

- `core.zig`: names, IDs, physical names, diagnostics.
- `output.zig`: lazy outputs and secret references.
- `resource.zig`: resource graph and dependency validation.
- `state.zig`: resource state records and in-memory store.
- `plan.zig`: deterministic plan operations.
- `provider.zig`: provider lifecycle vtable and fake provider.
- `apply.zig`: plan executor.

Provider implementations must sit behind the provider lifecycle interface so the
engine can be tested without live cloud credentials.
```

Create `packages/ziac/docs/roadmap.md`:

```markdown
# Ziac Roadmap

## Phase 1: Foundation

- Package scaffold.
- Core graph, outputs, state, planner, provider lifecycle, fake apply engine.

## Phase 2: Local State And CLI

- Local JSON state store.
- `ziac plan`, `ziac deploy`, `ziac destroy`, `ziac outputs`.

## Phase 3: GCP Provider

- GCP provider config.
- Artifact Registry.
- Existing-image Cloud Run service.

## Phase 4: Global GCP Components

- `ziac.gcp.global.ContainerService`.
- Global HTTPS load balancer.
- Multi-region Cloud Run routing.

## Phase 5: Zig Service Preset

- `ziac.gcp.global.ZigService`.
- Zig source to image to global service.
- Comptime environment validation.

## Phase 6: CockroachDB Data Components

- CockroachDB provider config.
- Existing cluster references.
- Database and user resources where safe.
- Connection URL and TLS certificate secret bindings.
- GCP service env validation against CockroachDB outputs.
- Migration hook planning.
```

- [ ] **Step 2: Include docs in the package manifest**

Modify `packages/ziac/build.zig.zon`:

```zig
.{
    .name = .ziac,
    .version = "0.1.0",
    .minimum_zig_version = "0.16.0",
    .paths = .{
        "README.md",
        "build.zig",
        "build.zig.zon",
        "docs",
        "src",
        "test",
    },
}
```

- [ ] **Step 3: Verify docs are present**

Run:

```sh
test -f packages/ziac/docs/vision.md
test -f packages/ziac/docs/architecture.md
test -f packages/ziac/docs/roadmap.md
```

Expected: all commands exit 0.

- [ ] **Step 4: Verify package tests still pass**

Run:

```sh
cd packages/ziac && zig build test
```

Expected: PASS.

- [ ] **Step 5: Commit**

Run:

```sh
git add packages/ziac/docs packages/ziac/build.zig.zon
git commit -m "Document Ziac foundation architecture"
```

---

### Task 9: Final Foundation Verification

**Files:**
- Verify: `packages/ziac/**`
- Verify: `package.json`

- [ ] **Step 1: Run package verification**

Run:

```sh
bun run ziac:test
```

Expected: PASS.

- [ ] **Step 2: Run existing zigeffect package tests**

Run:

```sh
bun run zigeffect:test
```

Expected: PASS. If unrelated existing zigeffect worktree changes fail this command, record the failure output and do not claim zigeffect is green.

- [ ] **Step 3: Run whitespace verification**

Run:

```sh
git diff --check
```

Expected: PASS.

- [ ] **Step 4: Inspect staged and untracked files**

Run:

```sh
git status --short
```

Expected: Ziac commits are complete. Existing unrelated zigeffect worktree changes may remain and must not be reverted.

- [ ] **Step 5: Report completion with evidence**

Report:

```text
Ziac foundation package created at packages/ziac.
Verification:
- bun run ziac:test: <result>
- bun run zigeffect:test: <result or unrelated failure summary>
- git diff --check: <result>
```

Do not say the whole Ziac vision is complete. Only the foundation slice is complete.

## Self-Review Notes

Spec coverage in this plan:

- `packages/ziac` package boundary: Tasks 1 and 8.
- zigeffect remains substrate: Task 1 imports sibling zigeffect and does not modify zigeffect.
- high-level product docs: Task 8.
- core graph, outputs, state, planner, provider, apply: Tasks 2-7.
- fake-provider-first execution: Task 7.
- GCP global Cloud Run path: documented in Task 8, deferred to a separate GCP provider plan.
- comptime env validation: documented as product goal, deferred until `ZigService` component plan because this foundation slice has no app source component yet.
- CLI: deferred until local state and package foundation are stable.
