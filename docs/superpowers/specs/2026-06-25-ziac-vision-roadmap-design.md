# Ziac Vision And Roadmap Design

Date: 2026-06-25

Status: user-approved design direction, written for review before implementation planning.

## Executive Summary

Ziac is a new Zig-native Infrastructure-as-Code product package in this
monorepo:

```text
packages/
  zigeffect/   # runtime, effects, fibers, layers, causal traces
  ziac/        # IaC engine, providers, prebuilt stacks, CLI
```

The core thesis is simple:

> Ziac is a comptime-checked Infrastructure-as-Code engine for Zig backends,
> powered by zigeffect.

Ziac borrows the best product lesson from Alchemy v2 and Pulumi AWSx: most users
do not want a giant catalog of raw resources first. They want a small number of
well-designed, production-shaped components that make the common path boring.
For Ziac, the first common path is:

> Build a Zig HTTP backend, deploy it globally on Google Cloud Run, route public
> traffic through a global HTTPS load balancer to the nearest healthy region, and
> get a stable URL with minimal code.

The first flagship component is therefore:

```zig
const api = try ziac.gcp.global.ZigService(.{
    .name = "api",
    .source = .{ .path = "src/main.zig" },
    .regions = .{ "us-central1", "europe-west1" },
    .port = 8080,
});
```

The lower-level variant accepts an existing image when a team already has a
container build pipeline:

```zig
const api = try ziac.gcp.global.ContainerService(.{
    .name = "api",
    .image = "us-docker.pkg.dev/acme/prod/api@sha256:...",
    .regions = .{ "us-central1", "europe-west1" },
    .port = 8080,
});
```

This component should hide the dull hard parts: Zig release build, container
image construction, Artifact Registry, Cloud Run multi-region service,
serverless network endpoint groups, global external Application Load Balancer,
managed certificate, URL map, target proxy, forwarding rule, service account,
health/readiness checks, labels, outputs, and destroy ordering.

## Why Ziac Exists

Alchemy v2 proves that infrastructure and runtime logic can share one typed
program. Pulumi proves that general-purpose languages can manage real cloud
resources. Pulumi AWSx proves that high-level component libraries are often more
valuable than raw resources because they encode production defaults.

Ziac adds a Zig-specific promise:

1. Comptime checks verify the relationship between app code and cloud bindings.
2. zigeffect gives the engine direct-style effects, layers, scoped resources,
   structured concurrency, deterministic planning, and causal traces.
3. The first provider is focused on the easiest real global-container path:
   Google Cloud Run multi-region behind global load balancing.
4. The product favors prebuilt stacks first, raw provider coverage second.

The result should feel closer to "AWSx for global Zig backends" than to
"Terraform in Zig syntax."

## Product Positioning

### Name

The project name is **Ziac**.

Working expansion:

```text
Zig Infrastructure as Code
```

CLI:

```sh
ziac plan
ziac deploy
ziac destroy
ziac outputs
ziac state
```

Package import:

```zig
const ziac = @import("ziac");
```

### Taglines

Primary:

```text
Comptime-checked cloud infrastructure for Zig.
```

Secondary:

```text
Deploy global Zig backends without assembling the cloud by hand.
```

Developer-facing:

```text
Alchemy-style infrastructure as effects, powered by zigeffect.
```

### The AWSx Analogy

Pulumi AWSx packages well-architected AWS patterns, such as a VPC with sensible
defaults and useful outputs, into component resources. Ziac should do the same
for Google Cloud deployments and CockroachDB-backed application data, but with
Zig and zigeffect as the language and runtime foundation.

AWSx-style mental model:

```ts
const vpc = new awsx.ec2.Vpc("custom");
```

Ziac-style mental model:

```zig
const service = try ziac.gcp.global.ZigService(.{
    .name = "api",
    .source = .{ .path = "src/main.zig" },
    .regions = .{ "us-central1", "europe-west1" },
});
```

The user asks for the outcome, not every underlying resource. Ziac expands that
outcome into a plan with raw cloud operations, clear outputs, and a causal trace.

## First Product Goal

Make this workflow easy:

1. Write a Zig HTTP backend.
2. Declare one Ziac global service component and, when needed, one CockroachDB
   data binding.
3. Run `ziac plan` and see exactly what GCP resources will be created.
4. Run `ziac deploy`.
5. Receive a global HTTPS URL.
6. Requests route through a global load balancer to the nearest healthy Cloud Run
   region.
7. The app's declared environment contract is checked against configured
   CockroachDB connection secrets, resource bindings, ports, and outputs before
   deployment.

The first valuable demo is not a resource catalog. It is:

```zig
const std = @import("std");
const ziac = @import("ziac");

const Api = struct {
    pub const Env = struct {
        DATABASE_URL: ziac.Secret,
        DB_CA_CERT: ziac.Secret,
        SERVICE_REGION: []const u8,
    };
};

pub fn main() !void {
    try ziac.run(.{
        .stack = "hello-global",
        .stage = "dev",
    }, struct {
        pub fn stack(ctx: *ziac.StackContext) !ziac.Outputs {
            const database = try ziac.cockroach.Database(.{
                .name = "api-db",
                .cluster = ziac.cockroach.clusterRef("dev-primary"),
                .database = "api_dev",
            });

            const service = try ziac.gcp.global.ZigService(.{
                .name = "api",
                .source = .{ .path = "src/main.zig", .app = Api },
                .regions = .{ "us-central1", "europe-west1" },
                .port = 8080,
                .env = .{
                    .DATABASE_URL = database.connection_url,
                    .DB_CA_CERT = database.ca_cert,
                    .SERVICE_REGION = ziac.gcp.runtimeRegion(),
                },
            });

            return .{
                .url = service.url,
                .database = database.name,
            };
        }
    });
}
```

If `Api.Env` requires `DATABASE_URL` and the stack omits it, compilation should
fail before any deploy command can run. If the stack wires a plain string where a
CockroachDB secret output is required, the same contract check should fail. If
the service declares port `8080` but the container contract cannot expose that
port, planning should fail before the provider is called.

## Provider Strategy

### Provider 1: Google Cloud

Google Cloud is the first provider because the global container story is stable
and productizable:

1. Cloud Run runs OCI containers.
2. Cloud Run supports multi-region services.
3. Global external Application Load Balancing can route traffic across regions.
4. Readiness probes and service health can support regional failover.
5. Artifact Registry is the standard image registry path.

The first Ziac provider should hide the resource choreography while still
showing the exact plan:

```text
Artifact Registry repository
Container image build and push
Cloud Run multi-region service
Regional service identities and IAM
Serverless NEGs
Backend service
URL map
Managed certificate
Target HTTPS proxy
Global forwarding rule
Outputs
```

### Data Provider: CockroachDB

CockroachDB is the first data provider because the flagship backend story should
include durable application data from the beginning. Ziac should make the common
database wiring path as boring as the compute path:

```zig
const database = try ziac.cockroach.Database(.{
    .name = "api-db",
    .cluster = ziac.cockroach.clusterRef("dev-primary"),
    .database = "api_dev",
});
```

The first CockroachDB surface should support:

1. Existing cluster references.
2. Database and user resources where the provider can safely manage them.
3. Connection URL secret outputs.
4. TLS certificate secret outputs.
5. Stage-aware database names.
6. App environment contract validation for `DATABASE_URL` and related secrets.
7. Optional migration hooks as a follow-up, not as a blocker for the first
   global service demo.

### Explicit Non-Goal: AWS First

AWS is not a first-phase target. Pulumi AWSx already owns the AWS component
library story well, and AWS global container routing would pull Ziac toward ECS,
ECR, ALB, CloudFront, Lambda, App Runner, or EKS decisions too early. Ziac should
win first on the crisp GCP global Cloud Run path.

## Ziac's Killer Features

### 1. Comptime App-To-Infrastructure Validation

Ziac should use Zig comptime to validate contracts that TypeScript IaC tools can
only approximate.

Examples:

```zig
const Api = struct {
    pub const Env = struct {
        DATABASE_URL: ziac.Secret,
        ASSETS_BUCKET: ziac.gcp.storage.BucketBinding,
    };
};
```

The stack must prove:

1. Every required env field is bound.
2. Every binding is available on the selected provider.
3. Secret values are passed as secrets, not plain strings.
4. Provider resources exist in the same stage or are referenced explicitly.
5. Outputs used as inputs have compatible types.
6. The app port matches the deployed container port.
7. The chosen regions are valid for the provider and component.
8. The selected high-level component supports the app's declared needs.

### 2. Causal Deployment Traces

Every plan and apply should emit a zigeffect causal graph. Instead of scraping
logs, a user or agent can ask:

```sh
ziac trace resources
ziac trace lineage gcp.load-balancer
ziac trace cause failed-operation-id
ziac trace retries
ziac trace outputs
```

This should answer:

1. Which resource failed?
2. Which output or dependency caused that resource to run?
3. Which provider call was retried?
4. Which compensating operations ran after a failure?
5. Which resources are now live, pending, tainted, or destroyed?

### 3. Deterministic Planning

Planning should run without touching cloud APIs unless a resource explicitly
requires a read for adoption or drift detection. The graph should be deterministic
given the same stack, stage, config, and state.

### 4. Opinionated Global Components

The product should prioritize components like:

```zig
ziac.gcp.global.ZigService
ziac.gcp.global.ContainerService
ziac.gcp.global.StaticSite
ziac.gcp.global.ApiWithCockroach
ziac.gcp.global.WorkerPool
ziac.cockroach.Database
ziac.cockroach.ConnectionSecret
```

Raw resources are still needed, but they are not the initial product promise.

### 5. Provider Availability As A Type Boundary

Using a Google component without Google provider configuration should fail
clearly. The failure should be caught as early as possible:

```zig
const stack = ziac.Stack(.{
    .providers = .{
        ziac.gcp.Provider(...),
        ziac.cockroach.Provider(...),
    },
}, myProgram);
```

If `ziac.gcp.global.ApiWithCockroach` appears without both the Google provider
and the CockroachDB provider, Ziac should produce a precise diagnostic. If an
app declares `DATABASE_URL: ziac.Secret` but the stack wires a non-secret
CockroachDB output, Ziac should fail before planning reaches provider calls.

## Architecture

### Package Boundary

Ziac is a new package:

```text
packages/ziac/
  README.md
  build.zig
  build.zig.zon
  src/
    ziac.zig
    core/
    stack/
    resource/
    output/
    provider/
    state/
    plan/
    apply/
    cli/
    build/
    providers/
      gcp/
      cockroach/
    components/
      gcp/
        global_zig_service.zig
        global_container_service.zig
        api_with_cockroach.zig
      cockroach/
        database.zig
        connection.zig
  test/
  examples/
  docs/
    vision.md
    architecture.md
    roadmap.md
    gcp-global-zig-service.md
```

The public import is:

```zig
const ziac = @import("ziac");
```

Implementation modules import zigeffect directly where needed:

```zig
const fx = @import("zigeffect");
```

### Core Domains

#### `core/`

Owns shared IDs, names, labels, stage, stack identity, diagnostics, and common
error sets.

Key types:

```zig
StackName
StageName
LogicalId
PhysicalName
ProviderName
Region
ZiacError
Diagnostic
```

#### `output/`

Owns lazy values that flow between resources.

Key types:

```zig
Output(T)
Secret(T)
Known(T)
Unknown(T)
OutputRef
```

Outputs are not plain values during planning. They are references that become
known after provider operations complete or after state is read.

#### `resource/`

Owns resource declarations and graph nodes.

Key types:

```zig
ResourceType
ResourceId
ResourceInputs
ResourceOutputs
ResourceNode
ActionNode
DependencyEdge
```

Resources have lifecycle. Actions run deploy-time effects when inputs change.
This mirrors the useful Alchemy split between Resources and Actions.

#### `stack/`

Owns stack construction, multi-stack references, and output exports.

Key types:

```zig
Stack
StackContext
StackRef(T)
StackOutputs(T)
```

Multi-stack references should follow the Alchemy monorepo pattern:

```zig
const backend = try ctx.stackRef(Backend, .{ .stage = "prod" });
```

#### `provider/`

Owns provider lifecycle interfaces.

Provider operations:

```zig
read
diff
reconcile
delete
tailLogs
```

The initial mandatory operations are:

```zig
read
diff
reconcile
delete
```

Provider implementations may use REST APIs, CLIs, or generated clients, but the
Ziac engine should only see the provider vtable.

#### `state/`

Owns persisted resource state.

State records include:

```text
schema
stack
stage
resource_type
logical_id
physical_id
inputs_hash
outputs
status
provider
dependencies
created_at
updated_at
```

Initial state store:

```text
.ziac/state/<stack>/<stage>/<resource>.json
```

Later state stores:

```text
GCS bucket
CockroachDB
Postgres-compatible database
```

#### `plan/`

Owns graph analysis and planning.

Plan operations:

```text
create
update
replace
delete
read
noop
action-run
action-skip
```

Plan output should support:

```sh
ziac plan
ziac plan --json
ziac plan --graph
```

#### `apply/`

Owns execution of a plan.

Apply should use zigeffect structured concurrency:

1. Independent resources run in parallel.
2. Dependencies run in topological order.
3. Failed child operations interrupt dependent work.
4. Scoped cleanup and compensating operations run in reverse ownership order.
5. State is persisted before and after provider calls so interrupted deploys can
   recover honestly.

#### `build/`

Owns build and image preparation.

For the first GCP component:

1. Build Zig release binary.
2. Build an OCI image.
3. Push to Artifact Registry.
4. Produce an image digest output.

The first implementation may shell out to `zig`, `docker`, and `gcloud` through
provider actions, but the long-term design should isolate command execution
behind testable services.

#### `cli/`

Owns the command line:

```sh
ziac init
ziac plan
ziac deploy
ziac destroy
ziac outputs
ziac state list
ziac state show
ziac trace
```

The CLI should never deploy without a clear command. Any command that changes
cloud state should print the selected stack, stage, provider, and project before
execution.

## GCP Component Library

Ziac should expose a high-level GCP namespace:

```zig
ziac.gcp
ziac.gcp.global
ziac.gcp.run
ziac.gcp.artifactregistry
ziac.gcp.loadbalancing
ziac.gcp.iam
ziac.gcp.secretmanager
ziac.gcp.storage
```

The initial "AWSx-like" layer lives under:

```zig
ziac.gcp.global
```

### `ziac.gcp.global.ZigService`

Purpose:

Deploy a Zig HTTP backend as a globally routed Cloud Run service.

Inputs:

```zig
pub const ZigServiceArgs = struct {
    name: []const u8,
    source: Source,
    regions: []const []const u8,
    port: u16 = 8080,
    domain: ?Domain = null,
    env: anytype = .{},
    secrets: anytype = .{},
    min_instances: u32 = 0,
    max_instances: ?u32 = null,
    concurrency: ?u32 = null,
    cpu: ?Cpu = null,
    memory: ?Memory = null,
    service_account: ?ServiceAccountRef = null,
    ingress: Ingress = .public,
    labels: Labels = .{},
};
```

Outputs:

```zig
pub const ZigServiceOutputs = struct {
    url: Output([]const u8),
    load_balancer_ip: Output([]const u8),
    service_name: Output([]const u8),
    regions: Output([]const []const u8),
    image_digest: Output([]const u8),
    service_account_email: Output([]const u8),
};
```

Underlying resource graph:

```text
gcp.project.RequiredApis
gcp.artifactregistry.Repository
ziac.build.ZigBinary
ziac.build.ContainerImage
gcp.artifactregistry.ImagePush
gcp.iam.ServiceAccount
gcp.run.MultiRegionService
gcp.loadbalancing.ServerlessNegSet
gcp.loadbalancing.BackendService
gcp.loadbalancing.UrlMap
gcp.loadbalancing.ManagedCertificate
gcp.loadbalancing.TargetHttpsProxy
gcp.loadbalancing.GlobalForwardingRule
```

Default behavior:

1. Choose a stable physical name from stack, stage, and logical id.
2. Enable required APIs only when configured to manage APIs.
3. Use least-privilege service identity.
4. Build with release-safe Zig defaults.
5. Use image digests, not mutable tags, for deployed revisions.
6. Attach readiness probes when provided.
7. Create a global URL even when no custom domain is configured.
8. Expose all generated names in outputs.

### `ziac.gcp.global.ContainerService`

Same global GCP deployment pattern, but accepts an existing image:

```zig
const service = try ziac.gcp.global.ContainerService(.{
    .name = "api",
    .image = "us-docker.pkg.dev/acme/prod/api@sha256:...",
    .regions = .{ "us-central1", "europe-west1" },
});
```

This should be implemented before or alongside `ZigService` so the provider can
be tested without a Zig build pipeline.

### `ziac.gcp.global.StaticSite`

Later component for frontend pairing:

```zig
const site = try ziac.gcp.global.StaticSite(.{
    .name = "web",
    .dist = "apps/web/dist",
    .api_url = api.url,
});
```

This is lower priority than Zig backend deployment.

## Multi-Stack Model

Ziac should support the Alchemy-style monorepo pattern where backend and frontend
are separate stacks with typed references:

```text
apps/
  backend/
    ziac.zig
  frontend/
    ziac.zig
packages/
  shared-api/
```

Backend:

```zig
pub const Backend = ziac.Stack("Backend", struct {
    url: []const u8,
});
```

Frontend:

```zig
const backend = try ctx.stackRef(Backend, .{ .stage = "prod" });
```

References must be explicit about stack and stage when crossing boundaries.
Implicitly grabbing another stack's dev output is forbidden.

## CLI Experience

### `ziac plan`

Example:

```sh
ziac plan --stack hello-global --stage dev
```

Expected output:

```text
Ziac plan
Stack: hello-global
Stage: dev
Provider: gcp
Project: yachdee-dev

+ gcp.artifactregistry.Repository api-images
+ ziac.build.ZigBinary api
+ ziac.build.ContainerImage api
+ gcp.run.MultiRegionService api
+ gcp.loadbalancing.ServerlessNegSet api
+ gcp.loadbalancing.BackendService api
+ gcp.loadbalancing.UrlMap api
+ gcp.loadbalancing.ManagedCertificate api
+ gcp.loadbalancing.GlobalForwardingRule api

Outputs:
  url: <known after apply>
```

### `ziac deploy`

Example:

```sh
ziac deploy --stack hello-global --stage dev
```

Deploy should:

1. Recompute the plan.
2. Confirm the stack, stage, project, and provider.
3. Execute create/update/delete operations.
4. Persist state transitions.
5. Emit a causal trace artifact.
6. Print final outputs.

### `ziac destroy`

Destroy should:

1. Load state.
2. Build a reverse dependency graph.
3. Delete resources in safe order.
4. Preserve a destroy trace.
5. Leave an auditable tombstone or empty stage marker.

## State And Safety

Ziac must treat state as a first-class product surface. It should avoid the
"partially deployed, nobody knows what happened" failure mode.

State transitions:

```text
planned
creating
created
updating
updated
replacing
deleting
deleted
failed
tainted
adopted
```

Apply rules:

1. Write intent before a provider mutation.
2. Write outputs after a successful provider mutation.
3. Mark failed resources with provider diagnostics.
4. Never pretend a rollback happened unless the delete/update call succeeded.
5. Make recovery explicit on the next plan.

## Testing Strategy

### Unit Tests

Core engine tests:

1. Graph construction.
2. Dependency ordering.
3. Cycle detection.
4. Output type checks.
5. State serialization.
6. Plan diff classification.
7. Provider lifecycle dispatch.
8. Comptime env validation fixtures.

### Provider Tests

Provider tests should start with a fake GCP provider that records operations.
Live GCP tests come later and must be opt-in.

Fake tests:

1. `ContainerService` expands into the expected resource graph.
2. Region lists are validated.
3. Missing provider fails before apply.
4. Missing app env binding fails at comptime.
5. Independent resources apply in parallel.
6. Failed provider operation marks state as failed.

Live tests:

1. Deploy a single-region Cloud Run service.
2. Deploy a two-region global service.
3. Route an HTTP request to the global URL.
4. Destroy all resources.
5. Assert no managed resources remain by Ziac labels.

### Verification Commands

From repo root:

```sh
bun run zigeffect:test
cd packages/ziac && zig build test
```

Once package scripts exist:

```sh
bun run ziac:test
bun run ziac:examples
```

## Documentation Plan

Ziac should own product docs from the start:

```text
packages/ziac/docs/vision.md
packages/ziac/docs/architecture.md
packages/ziac/docs/roadmap.md
packages/ziac/docs/gcp-global-zig-service.md
packages/ziac/docs/state.md
packages/ziac/docs/provider-authoring.md
packages/ziac/docs/comptime-contracts.md
```

The docs should speak in product outcomes first:

1. Deploy a global Zig backend.
2. Add a custom domain.
3. Add secrets.
4. Add a managed database binding.
5. Split frontend and backend into two stacks.
6. Inspect a failed deploy trace.
7. Author a raw provider resource.

## Roadmap

### Phase 0: Project Definition

Goal:

Record the vision, architecture, and delivery roadmap without touching runtime
code yet.

Deliverables:

1. This design spec.
2. Implementation plan.
3. Initial package documentation targets.

Acceptance:

1. User approves the written spec.
2. Implementation plan exists before code edits.

### Phase 1: Package Scaffold

Goal:

Create `/packages/ziac` as a buildable Zig package that imports zigeffect.

Deliverables:

1. `packages/ziac/build.zig`
2. `packages/ziac/build.zig.zon`
3. `packages/ziac/src/ziac.zig`
4. `packages/ziac/test/all_test.zig`
5. Root package scripts:
   - `ziac:test`
   - `ziac:examples`

Acceptance:

1. `cd packages/ziac && zig build test` passes.
2. `bun run ziac:test` passes.
3. No changes to zigeffect behavior are required.

### Phase 2: Core Graph IR

Goal:

Represent stacks, resources, actions, outputs, and dependency edges without any
cloud provider.

Deliverables:

1. `Stack`
2. `StackContext`
3. `ResourceNode`
4. `ActionNode`
5. `Output(T)`
6. `Secret(T)`
7. Dependency graph builder.
8. Cycle detection diagnostics.

Acceptance:

1. A test stack can register three resources.
2. Outputs create dependency edges.
3. Cycles produce readable diagnostics.
4. Graph snapshots are deterministic.

### Phase 3: State Store V1

Goal:

Persist and load local state for deterministic plans.

Deliverables:

1. Local JSON state store.
2. State schema version.
3. State record parser and formatter.
4. Stage directory layout.
5. State status transitions.

Acceptance:

1. State can round-trip through disk.
2. Unknown schema versions fail clearly.
3. Failed resources are preserved for recovery.

### Phase 4: Planner V1

Goal:

Compare desired graph to state and produce a plan.

Deliverables:

1. Plan operation model.
2. Input hash comparison.
3. Create/update/delete/noop classification.
4. Text plan renderer.
5. JSON plan renderer.

Acceptance:

1. Empty state produces create operations.
2. Matching state produces noop operations.
3. Changed inputs produce update or replace according to provider diff.
4. Removed resources produce delete operations.

### Phase 5: Provider Lifecycle

Goal:

Define the provider interface and fake provider test harness.

Deliverables:

1. Provider vtable.
2. Resource type registration.
3. Fake provider.
4. Provider diagnostics.
5. Provider requirement validation.

Acceptance:

1. Missing provider fails before apply.
2. Fake provider receives read/diff/reconcile/delete in expected order.
3. Provider errors become structured plan/apply diagnostics.

### Phase 6: Apply Engine

Goal:

Execute plans with zigeffect structured concurrency and causal traces.

Deliverables:

1. Topological apply executor.
2. Parallel execution for independent resources.
3. State transition writes.
4. Failure handling.
5. Causal event emission for plan/apply/resource/provider steps.

Acceptance:

1. Independent fake resources apply in parallel.
2. Dependent resources wait for upstream outputs.
3. Failed provider operation prevents dependent operations.
4. Causal trace can answer which resource failed.

### Phase 7: GCP Provider Foundation

Goal:

Introduce Google provider config and low-level GCP operations behind a testable
boundary.

Deliverables:

1. GCP provider config.
2. Project and region validation.
3. Auth profile model.
4. Required API resource.
5. Command/API execution service boundary.
6. Fake GCP client.

Acceptance:

1. GCP provider can be configured without live credentials in tests.
2. Invalid regions fail during planning.
3. Live operations remain opt-in.

### Phase 8: Container Image Flow

Goal:

Build and publish a container image for a Zig backend.

Deliverables:

1. `ziac.build.ZigBinary`
2. `ziac.build.ContainerImage`
3. `gcp.artifactregistry.Repository`
4. `gcp.artifactregistry.ImagePush`
5. Image digest output.

Acceptance:

1. Fake provider can plan and apply image resources.
2. Local example builds a minimal Zig HTTP binary.
3. Image resources are skipped when inputs are unchanged.

### Phase 9: Cloud Run Single-Region

Goal:

Deploy an existing image to Cloud Run in one region.

Deliverables:

1. `gcp.run.Service`
2. Service account integration.
3. Environment variable and secret binding support.
4. Public URL output.

Acceptance:

1. Fake provider verifies resource graph and outputs.
2. Optional live test deploys and destroys a single-region service.

### Phase 10: GCP Global Container Service

Goal:

Create the high-level component for globally routed Cloud Run services.

Deliverables:

1. `ziac.gcp.global.ContainerService`
2. Multi-region Cloud Run support.
3. Serverless NEG set.
4. Backend service.
5. URL map.
6. Managed certificate or default HTTPS route.
7. Target proxy.
8. Global forwarding rule.
9. Health/readiness configuration.

Acceptance:

1. Component expands into the expected resource graph.
2. Plan shows high-level component and underlying resources.
3. Optional live test returns a public URL.
4. Destroy removes all managed resources in safe order.

### Phase 11: GCP Global Zig Service

Goal:

Wrap the image flow and global container service into the flagship one-call
component.

Deliverables:

1. `ziac.gcp.global.ZigService`
2. Source-to-image-to-global-service pipeline.
3. App env contract validation.
4. Outputs for URL, image digest, and load balancer IP.

Acceptance:

1. A minimal Zig HTTP service deploys globally through one component.
2. Missing env binding fails at comptime.
3. Invalid port or region fails before provider calls.
4. Plan and apply emit causal traces.

### Phase 12: CockroachDB Data Components

Goal:

Make CockroachDB a first-class data binding for GCP-hosted Zig backends.

Deliverables:

1. `ziac.cockroach.Provider`.
2. Existing cluster reference support.
3. `ziac.cockroach.Database`.
4. Connection URL and TLS certificate secret outputs.
5. Stage-aware naming conventions.
6. `ziac.gcp.global.ApiWithCockroach` preset.
7. Env contract validation between app structs and database outputs.

Acceptance:

1. A global Zig service can receive CockroachDB secrets without hand-written env
   plumbing.
2. Missing database bindings fail before provider calls.
3. Non-secret database connection values are rejected for secret env fields.
4. Plan output shows database resources and service resources with dependency
   ordering.

### Phase 13: CLI V1

Goal:

Make Ziac usable from the command line.

Deliverables:

1. `ziac plan`
2. `ziac deploy`
3. `ziac destroy`
4. `ziac outputs`
5. `ziac trace`

Acceptance:

1. CLI runs the example stack.
2. Deploy prints final outputs.
3. Destroy works from persisted state.
4. Trace command can inspect the latest apply.

### Phase 14: Multi-Stack References

Goal:

Support monorepo multi-stack composition like Alchemy's backend/frontend
example.

Deliverables:

1. Typed stack contracts.
2. Stack output export/import.
3. Stage-explicit references.
4. Reference diagnostics.

Acceptance:

1. Frontend stack can consume backend URL.
2. Missing referenced stack fails clearly.
3. Cross-stage references require explicit stage.

### Phase 15: Production Hardening

Goal:

Make Ziac credible as a real deployment tool.

Deliverables:

1. State locking.
2. Remote state store.
3. Drift detection.
4. Import/adopt flow.
5. Provider operation retries.
6. Cost preview hooks.
7. Better secret redaction.
8. Release gate.

Acceptance:

1. Concurrent deploys cannot corrupt state.
2. Interrupted deploys can be resumed.
3. Drift is detected without accidental mutation.
4. Causal traces remain redacted.

## Risks And Mitigations

### Risk: Building A Raw Provider Catalog Too Early

Mitigation:

Prioritize `gcp.global.ContainerService` and `gcp.global.ZigService`. Add raw
resources only as needed to support these components.

### Risk: GCP Load Balancing Complexity

Mitigation:

Start with fake provider graph tests. Then build a minimal live path with a
small number of regions. Keep custom domain support separate from the first
public URL milestone.

### Risk: Docker Dependency

Mitigation:

Allow the first version to use Docker or compatible local tooling. Keep the
build service abstract so future versions can use Buildpacks, Cloud Build,
native OCI generation, or remote builders.

### Risk: Comptime API Gets Too Clever

Mitigation:

Use comptime for contract validation and diagnostics, not for hiding runtime
cloud behavior. Keep resource graphs inspectable.

### Risk: CockroachDB Credentials And Network Wiring

Mitigation:

Keep the first CockroachDB surface focused on explicit cluster references,
secret outputs, and application env validation. Treat network topology,
private connectivity, and migration orchestration as deliberate follow-up
milestones instead of burying them inside the first provider pass.

## Open Design Decisions For Implementation Planning

These are not blockers for the vision, but the implementation plan must choose
defaults before code edits begin.

1. Whether the first live GCP provider uses REST APIs directly or shells out to
   `gcloud`.
2. Whether `ZigService` creates Dockerfiles or uses a fixed generated image
   build context.
3. Whether custom domains are part of the first global service milestone or a
   follow-up.
4. Whether local state uses one JSON file per resource or a single stage file.
5. Whether live GCP tests are manual-only or gated by environment variables in
   CI.
6. Whether the first CockroachDB provider manages databases/users directly or
   starts with existing cluster references plus generated secret bindings.

## Acceptance Criteria For This Spec

The spec is accepted when:

1. The project name is Ziac.
2. The project lives at `packages/ziac`.
3. zigeffect remains the runtime substrate.
4. The first provider is Google Cloud.
5. The first flagship component is a global Cloud Run service for Zig backends.
6. The product model is AWSx-like high-level components in Alchemy-style stacks.
7. Comptime app-to-infrastructure validation is the signature differentiator.
8. CockroachDB is the first data provider and is part of the initial product
   direction with GCP.
