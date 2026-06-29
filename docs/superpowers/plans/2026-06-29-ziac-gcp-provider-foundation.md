# Ziac GCP Provider Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a plan-only GCP provider foundation with typed provider config, Artifact Registry and Cloud Run resource builders, and an upgraded `hello-global` fixture stack.

**Architecture:** Add a new `packages/ziac/src/gcp/` namespace that produces deterministic `ResourceNode`s and output strings while leaving live Google API calls out of scope. The existing stack registry and CLI continue using the generic graph/planner/fake-provider pipeline, but the fixture graph becomes a realistic GCP graph.

**Tech Stack:** Zig 0.16, `bun:test` root command through `bun run ziac:test`, Ziac resource graph/state/plan/apply modules, `zigeffect_std` for testable CLI and redaction.

---

## File Structure

Create:

- `packages/ziac/src/gcp/root.zig` — public GCP namespace exports.
- `packages/ziac/src/gcp/validation.zig` — shared GCP validation error set.
- `packages/ziac/src/gcp/config.zig` — provider config, network tier, labels, validation.
- `packages/ziac/src/gcp/artifact_registry.zig` — Docker repository resource builder.
- `packages/ziac/src/gcp/cloud_run.zig` — Cloud Run service resource builder.
- `packages/ziac/test/gcp_config_test.zig` — config validation tests.
- `packages/ziac/test/gcp_artifact_registry_test.zig` — Artifact Registry tests.
- `packages/ziac/test/gcp_cloud_run_test.zig` — Cloud Run service tests.

Modify:

- `packages/ziac/src/ziac.zig` — export `gcp`.
- `packages/ziac/src/stack_registry.zig` — build `hello-global` from GCP builders.
- `packages/ziac/test/all_test.zig` — import GCP tests.
- `packages/ziac/test/stack_registry_test.zig` — expect two-resource GCP graph and stable outputs.
- `packages/ziac/test/cli_test.zig` — expect two creates and GCP output names.
- `packages/ziac/README.md` — mention plan-only GCP foundation.
- `packages/ziac/docs/roadmap.md` — mark Phase 3 foundation progress.

Do not modify:

- `packages/zigeffect/**`
- `packages/zigeffect-std/**`
- any live cloud or Alchemy files

---

### Task 1: GCP Config Validation

**Files:**
- Create: `packages/ziac/src/gcp/root.zig`
- Create: `packages/ziac/src/gcp/validation.zig`
- Create: `packages/ziac/src/gcp/config.zig`
- Modify: `packages/ziac/src/ziac.zig`
- Create: `packages/ziac/test/gcp_config_test.zig`
- Modify: `packages/ziac/test/all_test.zig`

- [ ] **Step 1: Write failing config tests**

Create `packages/ziac/test/gcp_config_test.zig`:

```zig
const std = @import("std");
const ziac = @import("ziac");

test "gcp provider config validates project region labels and service regions" {
    const regions = [_][]const u8{ "europe-west1", "us-central1" };
    const labels = [_]ziac.gcp.config.Label{
        .{ .key = "app", .value = "hello-global" },
    };
    const config = ziac.gcp.config.ProviderConfig{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
        .service_regions = regions[0..],
        .network_tier = .premium,
        .service_account = "hello-global@ziac-dev.iam.gserviceaccount.com",
        .labels = labels[0..],
    };

    try config.validate();
    try std.testing.expectEqual(@as(usize, 2), config.regionCount());
}

test "gcp provider config rejects missing project id" {
    try std.testing.expectError(error.MissingProjectId, ziac.gcp.config.ProviderConfig{
        .project_id = "",
        .primary_region = "europe-west1",
    }.validate());
}

test "gcp provider config rejects missing primary region" {
    try std.testing.expectError(error.MissingRegion, ziac.gcp.config.ProviderConfig{
        .project_id = "ziac-dev",
        .primary_region = "",
    }.validate());
}

test "gcp provider config requires premium tier for multiple regions" {
    const regions = [_][]const u8{ "europe-west1", "us-central1" };
    try std.testing.expectError(error.PremiumTierRequired, ziac.gcp.config.ProviderConfig{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
        .service_regions = regions[0..],
        .network_tier = .standard,
    }.validate());
}

test "gcp provider config rejects empty labels" {
    const labels = [_]ziac.gcp.config.Label{
        .{ .key = "", .value = "hello-global" },
    };
    try std.testing.expectError(error.MissingLabel, ziac.gcp.config.ProviderConfig{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
        .labels = labels[0..],
    }.validate());
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
    _ = @import("local_state_test.zig");
    _ = @import("cli_test.zig");
    _ = @import("gcp_config_test.zig");
}
```

- [ ] **Step 2: Run test to verify RED**

Run:

```sh
cd packages/ziac && zig build test
```

Expected: FAIL because `ziac.gcp` is not exported.

- [ ] **Step 3: Implement config module**

Create `packages/ziac/src/gcp/validation.zig`:

```zig
pub const ValidationError = error{
    MissingProjectId,
    MissingRegion,
    MissingName,
    MissingImage,
    InvalidPort,
    DuplicateEnvVar,
    MissingLabel,
    PremiumTierRequired,
};
```

Create `packages/ziac/src/gcp/config.zig`:

```zig
const std = @import("std");
const validation = @import("validation.zig");

pub const ValidationError = validation.ValidationError;

pub const NetworkTier = enum {
    standard,
    premium,
};

pub const Label = struct {
    key: []const u8,
    value: []const u8,
};

pub const ProviderConfig = struct {
    project_id: []const u8,
    primary_region: []const u8,
    service_regions: []const []const u8 = &.{},
    network_tier: NetworkTier = .standard,
    service_account: ?[]const u8 = null,
    labels: []const Label = &.{},

    pub fn validate(self: ProviderConfig) ValidationError!void {
        if (self.project_id.len == 0) return error.MissingProjectId;
        if (self.primary_region.len == 0) return error.MissingRegion;
        for (self.service_regions) |region| {
            if (region.len == 0) return error.MissingRegion;
        }
        if (self.regionCount() > 1 and self.network_tier != .premium) {
            return error.PremiumTierRequired;
        }
        for (self.labels) |label| {
            if (label.key.len == 0 or label.value.len == 0) return error.MissingLabel;
        }
    }

    pub fn regionCount(self: ProviderConfig) usize {
        if (self.service_regions.len == 0) return 1;
        return self.service_regions.len;
    }
};

test "ProviderConfig region count defaults to primary region" {
    const config = ProviderConfig{ .project_id = "p", .primary_region = "europe-west1" };
    try std.testing.expectEqual(@as(usize, 1), config.regionCount());
}
```

Create `packages/ziac/src/gcp/root.zig`:

```zig
pub const validation = @import("validation.zig");
pub const config = @import("config.zig");

pub const ValidationError = validation.ValidationError;
pub const ProviderConfig = config.ProviderConfig;
pub const NetworkTier = config.NetworkTier;
```

Modify `packages/ziac/src/ziac.zig`:

```zig
pub const gcp = @import("gcp/root.zig");
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
git add packages/ziac/src/gcp/root.zig packages/ziac/src/gcp/validation.zig packages/ziac/src/gcp/config.zig packages/ziac/src/ziac.zig packages/ziac/test/gcp_config_test.zig packages/ziac/test/all_test.zig
git commit -m "Add Ziac GCP provider config validation"
```

---

### Task 2: Artifact Registry Docker Repository Builder

**Files:**
- Create: `packages/ziac/src/gcp/artifact_registry.zig`
- Modify: `packages/ziac/src/gcp/root.zig`
- Create: `packages/ziac/test/gcp_artifact_registry_test.zig`
- Modify: `packages/ziac/test/all_test.zig`

- [ ] **Step 1: Write failing Artifact Registry tests**

Create `packages/ziac/test/gcp_artifact_registry_test.zig`:

```zig
const std = @import("std");
const ziac = @import("ziac");

test "artifact registry docker repository builds stable resource and url" {
    const provider = ziac.gcp.config.ProviderConfig{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    };

    var repo = try ziac.gcp.artifact_registry.DockerRepository.build(std.testing.allocator, provider, .{
        .name = "hello-global",
    });
    defer repo.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.artifact.Repository.europe-west1.hello-global", repo.node.id);
    try std.testing.expectEqualStrings("gcp.artifact.Repository", repo.node.type_name);
    try std.testing.expectEqualStrings("hello-global", repo.node.logical_id);
    try std.testing.expectEqualStrings("europe-west1-docker.pkg.dev/ziac-dev/hello-global", repo.repository_url);
}

test "artifact registry docker repository can override location" {
    const provider = ziac.gcp.config.ProviderConfig{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    };

    var repo = try ziac.gcp.artifact_registry.DockerRepository.build(std.testing.allocator, provider, .{
        .name = "api-images",
        .location = "us-central1",
    });
    defer repo.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.artifact.Repository.us-central1.api-images", repo.node.id);
    try std.testing.expectEqualStrings("us-central1-docker.pkg.dev/ziac-dev/api-images", repo.repository_url);
}

test "artifact registry docker repository rejects missing name" {
    const provider = ziac.gcp.config.ProviderConfig{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    };

    try std.testing.expectError(error.MissingName, ziac.gcp.artifact_registry.DockerRepository.build(std.testing.allocator, provider, .{
        .name = "",
    }));
}
```

Modify `packages/ziac/test/all_test.zig` to add:

```zig
_ = @import("gcp_artifact_registry_test.zig");
```

- [ ] **Step 2: Run test to verify RED**

Run:

```sh
cd packages/ziac && zig build test
```

Expected: FAIL because `ziac.gcp.artifact_registry` is missing.

- [ ] **Step 3: Implement Artifact Registry builder**

Create `packages/ziac/src/gcp/artifact_registry.zig`:

```zig
const std = @import("std");
const config_mod = @import("config.zig");
const resource = @import("../resource.zig");
const validation = @import("validation.zig");

pub const BuildError = validation.ValidationError || std.mem.Allocator.Error;

pub const DockerRepositoryArgs = struct {
    name: []const u8,
    location: ?[]const u8 = null,
};

pub const DockerRepository = struct {
    node: resource.ResourceNode,
    repository_url: []const u8,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: DockerRepositoryArgs,
    ) BuildError!DockerRepository {
        try provider.validate();
        if (args.name.len == 0) return error.MissingName;
        const location = args.location orelse provider.primary_region;
        if (location.len == 0) return error.MissingRegion;

        const id = try std.fmt.allocPrint(allocator, "gcp.artifact.Repository.{s}.{s}", .{ location, args.name });
        errdefer allocator.free(id);
        const repository_url = try std.fmt.allocPrint(allocator, "{s}-docker.pkg.dev/{s}/{s}", .{ location, provider.project_id, args.name });
        errdefer allocator.free(repository_url);

        return .{
            .node = .{
                .id = id,
                .type_name = "gcp.artifact.Repository",
                .logical_id = args.name,
            },
            .repository_url = repository_url,
        };
    }

    pub fn deinit(self: *DockerRepository, allocator: std.mem.Allocator) void {
        allocator.free(self.node.id);
        allocator.free(self.repository_url);
    }
};
```

Modify `packages/ziac/src/gcp/root.zig`:

```zig
pub const validation = @import("validation.zig");
pub const config = @import("config.zig");
pub const artifact_registry = @import("artifact_registry.zig");

pub const ValidationError = validation.ValidationError;
pub const ProviderConfig = config.ProviderConfig;
pub const NetworkTier = config.NetworkTier;
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
git add packages/ziac/src/gcp/artifact_registry.zig packages/ziac/src/gcp/root.zig packages/ziac/test/gcp_artifact_registry_test.zig packages/ziac/test/all_test.zig
git commit -m "Add Ziac GCP Artifact Registry resource builder"
```

---

### Task 3: Cloud Run Service Builder

**Files:**
- Create: `packages/ziac/src/gcp/cloud_run.zig`
- Modify: `packages/ziac/src/gcp/root.zig`
- Create: `packages/ziac/test/gcp_cloud_run_test.zig`
- Modify: `packages/ziac/test/all_test.zig`

- [ ] **Step 1: Write failing Cloud Run tests**

Create `packages/ziac/test/gcp_cloud_run_test.zig`:

```zig
const std = @import("std");
const ziac = @import("ziac");

test "cloud run service builds stable resource url and default service account" {
    const provider = ziac.gcp.config.ProviderConfig{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
        .service_account = "runtime@ziac-dev.iam.gserviceaccount.com",
    };

    var service = try ziac.gcp.cloud_run.Service.build(std.testing.allocator, provider, .{
        .name = "api",
        .image = "europe-west1-docker.pkg.dev/ziac-dev/hello-global/api:latest",
    });
    defer service.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.run.Service.europe-west1.api", service.node.id);
    try std.testing.expectEqualStrings("gcp.run.Service", service.node.type_name);
    try std.testing.expectEqualStrings("api", service.node.logical_id);
    try std.testing.expectEqualStrings("https://api-europe-west1-ziac-dev.run.app", service.service_url);
    try std.testing.expectEqualStrings("runtime@ziac-dev.iam.gserviceaccount.com", service.service_account);
}

test "cloud run service can override region and service account" {
    const provider = ziac.gcp.config.ProviderConfig{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    };

    var service = try ziac.gcp.cloud_run.Service.build(std.testing.allocator, provider, .{
        .name = "api",
        .image = "us-central1-docker.pkg.dev/ziac-dev/hello-global/api:latest",
        .region = "us-central1",
        .service_account = "api@ziac-dev.iam.gserviceaccount.com",
    });
    defer service.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.run.Service.us-central1.api", service.node.id);
    try std.testing.expectEqualStrings("api@ziac-dev.iam.gserviceaccount.com", service.service_account);
}

test "cloud run service rejects missing image invalid port and duplicate env" {
    const provider = ziac.gcp.config.ProviderConfig{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    };

    try std.testing.expectError(error.MissingImage, ziac.gcp.cloud_run.Service.build(std.testing.allocator, provider, .{
        .name = "api",
        .image = "",
    }));

    try std.testing.expectError(error.InvalidPort, ziac.gcp.cloud_run.Service.build(std.testing.allocator, provider, .{
        .name = "api",
        .image = "image",
        .port = 0,
    }));

    const env = [_]ziac.gcp.cloud_run.EnvVar{
        .{ .name = "DATABASE_URL", .value = "secret", .secret = true },
        .{ .name = "DATABASE_URL", .value = "duplicate" },
    };
    try std.testing.expectError(error.DuplicateEnvVar, ziac.gcp.cloud_run.Service.build(std.testing.allocator, provider, .{
        .name = "api",
        .image = "image",
        .env = env[0..],
    }));
}
```

Modify `packages/ziac/test/all_test.zig` to add:

```zig
_ = @import("gcp_cloud_run_test.zig");
```

- [ ] **Step 2: Run test to verify RED**

Run:

```sh
cd packages/ziac && zig build test
```

Expected: FAIL because `ziac.gcp.cloud_run` is missing.

- [ ] **Step 3: Implement Cloud Run builder**

Create `packages/ziac/src/gcp/cloud_run.zig`:

```zig
const std = @import("std");
const config_mod = @import("config.zig");
const resource = @import("../resource.zig");
const validation = @import("validation.zig");

pub const BuildError = validation.ValidationError || std.mem.Allocator.Error;

pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
    secret: bool = false,
};

pub const ServiceArgs = struct {
    name: []const u8,
    image: []const u8,
    region: ?[]const u8 = null,
    port: u16 = 8080,
    service_account: ?[]const u8 = null,
    env: []const EnvVar = &.{},
};

pub const Service = struct {
    node: resource.ResourceNode,
    service_url: []const u8,
    service_account: []const u8,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: ServiceArgs,
    ) BuildError!Service {
        try provider.validate();
        if (args.name.len == 0) return error.MissingName;
        if (args.image.len == 0) return error.MissingImage;
        if (args.port == 0) return error.InvalidPort;

        const region = args.region orelse provider.primary_region;
        if (region.len == 0) return error.MissingRegion;
        try validateEnv(args.env);

        const selected_service_account = args.service_account orelse provider.service_account orelse "default";
        const id = try std.fmt.allocPrint(allocator, "gcp.run.Service.{s}.{s}", .{ region, args.name });
        errdefer allocator.free(id);
        const service_url = try std.fmt.allocPrint(allocator, "https://{s}-{s}-{s}.run.app", .{ args.name, region, provider.project_id });
        errdefer allocator.free(service_url);
        const owned_service_account = try allocator.dupe(u8, selected_service_account);
        errdefer allocator.free(owned_service_account);

        return .{
            .node = .{
                .id = id,
                .type_name = "gcp.run.Service",
                .logical_id = args.name,
            },
            .service_url = service_url,
            .service_account = owned_service_account,
        };
    }

    pub fn deinit(self: *Service, allocator: std.mem.Allocator) void {
        allocator.free(self.node.id);
        allocator.free(self.service_url);
        allocator.free(self.service_account);
    }
};

fn validateEnv(env: []const EnvVar) validation.ValidationError!void {
    for (env, 0..) |left, left_index| {
        if (left.name.len == 0) return error.MissingName;
        for (env[left_index + 1 ..]) |right| {
            if (std.mem.eql(u8, left.name, right.name)) return error.DuplicateEnvVar;
        }
    }
}
```

Modify `packages/ziac/src/gcp/root.zig`:

```zig
pub const validation = @import("validation.zig");
pub const config = @import("config.zig");
pub const artifact_registry = @import("artifact_registry.zig");
pub const cloud_run = @import("cloud_run.zig");

pub const ValidationError = validation.ValidationError;
pub const ProviderConfig = config.ProviderConfig;
pub const NetworkTier = config.NetworkTier;
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
git add packages/ziac/src/gcp/cloud_run.zig packages/ziac/src/gcp/root.zig packages/ziac/test/gcp_cloud_run_test.zig packages/ziac/test/all_test.zig
git commit -m "Add Ziac GCP Cloud Run resource builder"
```

---

### Task 4: Upgrade Fixture Stack And CLI Expectations

**Files:**
- Modify: `packages/ziac/src/stack_registry.zig`
- Modify: `packages/ziac/test/stack_registry_test.zig`
- Modify: `packages/ziac/test/cli_test.zig`
- Modify: `packages/ziac/test/local_state_test.zig`

- [ ] **Step 1: Write failing fixture and CLI tests**

Modify `packages/ziac/test/stack_registry_test.zig`:

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
```

Modify `packages/ziac/test/cli_test.zig` expected lines:

```zig
try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "Plan: 2 create, 0 update, 0 delete, 0 noop") != null);
try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "+ gcp.artifact.Repository hello-global") != null);
try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "+ gcp.run.Service api") != null);
```

In the outputs test, replace URL expectations with:

```zig
try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "service_url=https://api-europe-west1-ziac-dev.run.app") != null);
try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "repository_url=europe-west1-docker.pkg.dev/ziac-dev/hello-global") != null);
try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "database_url=[REDACTED]") != null);
```

In the state test, expect both resources:

```zig
try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "gcp.artifact.Repository.europe-west1.hello-global created") != null);
try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "gcp.run.Service.europe-west1.api created") != null);
```

Modify `packages/ziac/test/local_state_test.zig` load fixture resource ID:

```zig
try fs.writeFile(".ziac/state/hello-global/dev/resources.json",
    \\{"resources":[{"resource_id":"gcp.run.Service.europe-west1.api","type_name":"gcp.run.Service","logical_id":"api","inputs_hash":"v1","status":"created"}]}
);
const record = loaded.store.get("gcp.run.Service.europe-west1.api") orelse return error.MissingRecord;
```

- [ ] **Step 2: Run test to verify RED**

Run:

```sh
cd packages/ziac && zig build test
```

Expected: FAIL because the fixture still builds one resource and old outputs.

- [ ] **Step 3: Implement fixture graph upgrade**

Modify `packages/ziac/src/stack_registry.zig`:

```zig
const std = @import("std");
const gcp = @import("gcp/root.zig");
const resource = @import("resource.zig");

pub const StackError = error{
    UnknownStack,
    DuplicateResource,
    MissingResource,
    OutOfMemory,
    MissingProjectId,
    MissingRegion,
    MissingName,
    MissingImage,
    InvalidPort,
    DuplicateEnvVar,
    MissingLabel,
    PremiumTierRequired,
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
        for (self.outputs.items) |entry| {
            self.allocator.free(entry.value);
        }
        self.outputs.deinit(self.allocator);
    }
};

pub const StackRegistry = struct {
    pub fn build(_: StackRegistry, allocator: std.mem.Allocator, args: StackArgs) StackError!StackProgram {
        if (!std.mem.eql(u8, args.stack, "hello-global")) return error.UnknownStack;

        const provider = gcp.config.ProviderConfig{
            .project_id = "ziac-dev",
            .primary_region = "europe-west1",
            .service_account = "hello-global@ziac-dev.iam.gserviceaccount.com",
        };

        var repo = try gcp.artifact_registry.DockerRepository.build(allocator, provider, .{
            .name = "hello-global",
        });
        defer repo.deinit(allocator);

        const image = try std.fmt.allocPrint(allocator, "{s}/api:latest", .{repo.repository_url});
        defer allocator.free(image);

        const env = [_]gcp.cloud_run.EnvVar{
            .{ .name = "DATABASE_URL", .value = "postgres://user:sentinel-secret-for-tests@localhost:26257/app", .secret = true },
        };
        var service = try gcp.cloud_run.Service.build(allocator, provider, .{
            .name = "api",
            .image = image,
            .env = env[0..],
        });
        defer service.deinit(allocator);

        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        try graph.addResource(repo.node);
        try graph.addResource(service.node);
        try graph.addDependency(service.node.id, repo.node.id);

        var outputs = std.ArrayList(OutputEntry).empty;
        errdefer {
            for (outputs.items) |entry| allocator.free(entry.value);
            outputs.deinit(allocator);
        }
        try appendOutput(allocator, &outputs, "repository_url", repo.repository_url, false);
        try appendOutput(allocator, &outputs, "service_url", service.service_url, false);
        try appendOutput(allocator, &outputs, "service_name", "api", false);
        try appendOutput(allocator, &outputs, "service_region", "europe-west1", false);
        try appendOutput(allocator, &outputs, "service_account", service.service_account, false);
        try appendOutput(allocator, &outputs, "database_url", "postgres://user:sentinel-secret-for-tests@localhost:26257/app", true);

        return .{ .allocator = allocator, .graph = graph, .outputs = outputs };
    }
};

fn appendOutput(
    allocator: std.mem.Allocator,
    outputs: *std.ArrayList(OutputEntry),
    name: []const u8,
    value: []const u8,
    secret: bool,
) !void {
    try outputs.append(allocator, .{
        .name = name,
        .value = try allocator.dupe(u8, value),
        .secret = secret,
    });
}

pub fn fixtureRegistry() StackRegistry {
    return .{};
}
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
git add packages/ziac/src/stack_registry.zig packages/ziac/test/stack_registry_test.zig packages/ziac/test/cli_test.zig packages/ziac/test/local_state_test.zig
git commit -m "Upgrade Ziac fixture stack to GCP resources"
```

---

### Task 5: Docs And Final Verification

**Files:**
- Modify: `packages/ziac/README.md`
- Modify: `packages/ziac/docs/roadmap.md`

- [ ] **Step 1: Update README**

Add this section to `packages/ziac/README.md` after the local CLI section:

```markdown
## GCP Provider Foundation

The current GCP support is plan-only. `hello-global` now models an Artifact
Registry Docker repository and Cloud Run service, then runs through the local
planner, JSON state store, and fake provider.

Live Google API calls, Cloud Run deployment, load balancers, and CockroachDB
resources are intentionally deferred until the typed provider model is stable.
```

- [ ] **Step 2: Update roadmap**

Modify Phase 3 in `packages/ziac/docs/roadmap.md`:

```markdown
## Phase 3: GCP Provider

- GCP provider config. Foundation implemented as plan-only validation.
- Artifact Registry Docker repository. Foundation implemented as plan-only
  resource builder.
- Existing-image Cloud Run service. Foundation implemented as plan-only resource
  builder.
- Live GCP API adapter, authentication, read/adopt, and drift detection remain
  future Phase 3 work.
```

- [ ] **Step 3: Verify final package checks**

Run:

```sh
bun run ziac:test
cd packages/ziac && zig build examples && zig build
```

Expected: all commands PASS.

- [ ] **Step 4: Commit**

Run:

```sh
git add packages/ziac/README.md packages/ziac/docs/roadmap.md
git commit -m "Document Ziac GCP provider foundation"
```

---

## Plan Self-Review

- Spec coverage: Tasks cover public `gcp` namespace, provider config, Artifact
  Registry, Cloud Run, fixture graph/output upgrade, CLI expectation update, and
  docs.
- Placeholder scan: No placeholder markers or omitted implementation steps.
- Type consistency: Tests and implementation use `ziac.gcp.config`,
  `ziac.gcp.artifact_registry`, `ziac.gcp.cloud_run`, and shared
  `ValidationError` names consistently.
