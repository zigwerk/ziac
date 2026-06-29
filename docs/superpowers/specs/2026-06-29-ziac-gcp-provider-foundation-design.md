# Ziac GCP Provider Foundation Design

Date: 2026-06-29

Status: approved for implementation after "Do it"

## Context

Ziac now has a local command loop with deterministic JSON state, a fixture stack
registry, a fake provider, and a real `ziac` executable. The next product step
is GCP support for globally deployed Zig backends. The full product vision is a
high-level AWSx-style component for globally routed Cloud Run services with
CockroachDB bindings, but the next implementation slice should harden the GCP
resource model before any live cloud calls.

The current Ziac package exposes generic graph, state, plan, provider, apply,
CLI, and stack-registry modules. It does not yet have provider-specific resource
types, provider configuration, or GCP output conventions.

## Source Notes

Official Google Cloud documentation establishes the platform shape this design
targets:

- Serverless NEGs are the load-balancer backend bridge for Cloud Run, App Engine,
  API Gateway, and Cloud Run functions.
- Serverless NEGs point at serverless resources in the same region.
- Global external Application Load Balancers can route to Cloud Run through
  serverless NEGs.
- Premium Network Service Tier is required for multi-region serverless NEGs.
- Cloud Run services accept configured environment variables.
- Artifact Registry stores private Docker container images in regional
  repositories.

References:

- https://docs.cloud.google.com/load-balancing/docs/negs/serverless-neg-concepts
- https://docs.cloud.google.com/load-balancing/docs/https/setup-global-ext-https-serverless
- https://docs.cloud.google.com/run/docs/configuring/services/environment-variables
- https://docs.cloud.google.com/artifact-registry/docs/docker/store-docker-container-images

## Selected Approach

Build a plan-only GCP provider foundation.

This means Ziac will gain typed GCP provider configuration and typed GCP
resource builders that produce deterministic `ResourceNode`s and output values,
but the provider will not call Google APIs yet. CLI `plan` and `deploy` will
still run through the fake provider for now. The goal is to make GCP resource
identity, validation, dependencies, and output wiring stable before adding live
authentication and API clients.

Rejected alternatives:

1. Jump straight to live Cloud Run deploys. This would mix resource modeling,
   auth, IAM, eventual consistency, API shape drift, state semantics, and error
   handling too early.
2. Build `gcp.global.ContainerService` first. That is the eventual product
   surface, but it should compose hardened lower-level GCP primitives rather
   than inventing them implicitly.

## Goals

1. Add a public `ziac.gcp` namespace.
2. Model provider config for project, regions, network tier, service account,
   and default labels.
3. Model typed GCP resources for Artifact Registry Docker repositories and Cloud
   Run services.
4. Add validation that catches missing project IDs, empty regions, empty image
   references, invalid ports, duplicate environment variable names, and invalid
   multi-region network-tier combinations.
5. Generate stable resource IDs and dependencies that can be planned, applied by
   the fake provider, and persisted in local state.
6. Generate stable outputs for repository URL, service URL, service name,
   service region, and service account.
7. Upgrade the fixture `hello-global` stack from one generic Cloud Run node to a
   realistic GCP graph with Artifact Registry and Cloud Run resources.
8. Keep live GCP calls, credentials, and remote state out of scope.

## Non-Goals

1. No Google API calls.
2. No OAuth, ADC, service-account key, or Workload Identity support.
3. No container image builds or pushes.
4. No load balancer, serverless NEG, certificate, DNS, or domain resources in
   this slice.
5. No CockroachDB provider resources in this slice.
6. No comptime app `Env` struct validation in this slice; the public types
   should leave room for that planned validation surface.

## Architecture

### `gcp/root.zig`

Public module root for provider-specific types. It re-exports:

- `config.zig`
- `artifact_registry.zig`
- `cloud_run.zig`
- `validation.zig`

`ziac.zig` exports this module as `pub const gcp = @import("gcp/root.zig");`.

### `gcp/config.zig`

Owns provider configuration and network-tier validation.

Public shape:

```zig
pub const NetworkTier = enum { standard, premium };

pub const ProviderConfig = struct {
    project_id: []const u8,
    primary_region: []const u8,
    service_regions: []const []const u8 = &.{},
    network_tier: NetworkTier = .standard,
    service_account: ?[]const u8 = null,
    labels: []const Label = &.{},

    pub fn validate(self: ProviderConfig) ValidationError!void;
    pub fn regionCount(self: ProviderConfig) usize;
};
```

Validation rules:

- `project_id` must be non-empty.
- `primary_region` must be non-empty.
- Every `service_regions` entry must be non-empty.
- `regionCount() > 1` requires `network_tier == .premium`.
- Labels must have non-empty keys and values.

### `gcp/artifact_registry.zig`

Owns Docker repository resource construction.

Public shape:

```zig
pub const DockerRepositoryArgs = struct {
    name: []const u8,
    location: ?[]const u8 = null,
};

pub const DockerRepository = struct {
    node: resource.ResourceNode,
    repository_url: []const u8,

    pub fn build(
        allocator: std.mem.Allocator,
        config: config.ProviderConfig,
        args: DockerRepositoryArgs,
    ) !DockerRepository;
    pub fn deinit(self: *DockerRepository, allocator: std.mem.Allocator) void;
};
```

Resource ID format:

```text
gcp.artifact.Repository.<location>.<name>
```

Repository URL format:

```text
<location>-docker.pkg.dev/<project_id>/<name>
```

### `gcp/cloud_run.zig`

Owns Cloud Run service resource construction.

Public shape:

```zig
pub const EnvVar = struct { name: []const u8, value: []const u8, secret: bool = false };

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
        config: config.ProviderConfig,
        args: ServiceArgs,
    ) !Service;
    pub fn deinit(self: *Service, allocator: std.mem.Allocator) void;
};
```

Resource ID format:

```text
gcp.run.Service.<region>.<name>
```

Service URL format for the plan-only foundation:

```text
https://<name>-<region>-<project_id>.run.app
```

This is a deterministic planning stand-in, not a claim that live Cloud Run will
always issue exactly that URL.

Validation rules:

- `name` must be non-empty.
- `image` must be non-empty.
- `region` defaults to `config.primary_region` and must be non-empty.
- `port` must be greater than zero.
- Environment variable names must be non-empty and unique within the service.
- Secret env values must never be surfaced in outputs.

### `stack_registry.zig`

The fixture registry should use the new GCP builders.

`hello-global` should build:

1. Artifact Registry Docker repository:
   `gcp.artifact.Repository.europe-west1.hello-global`
2. Cloud Run service:
   `gcp.run.Service.europe-west1.api`
3. Dependency from Cloud Run service to Artifact Registry repository.

Fixture outputs should include:

- `repository_url`
- `service_url`
- `service_name`
- `service_region`
- `service_account`
- `database_url` as a redacted secret value reserved for the coming CockroachDB
  slice

The stack is still local/fake-provider backed; deploy does not create live GCP
resources.

## Error Handling

Provider-specific validation should use a narrow error set:

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

Where resource construction allocates strings, public build functions can return
`ValidationError || std.mem.Allocator.Error`.

The CLI can continue mapping these failures through existing stack/graph error
paths in this slice. Dedicated GCP CLI diagnostics are assigned to the live
provider implementation slice.

## Testing

Tests should cover:

1. Provider config validates project, region, labels, and multi-region network
   tier rules.
2. Artifact Registry builder creates stable resource IDs and repository URLs.
3. Cloud Run builder creates stable resource IDs, service URLs, service account
   defaults, and rejects invalid env/port/image inputs.
4. Fixture stack graph contains the repository, Cloud Run service, and dependency
   in stable order.
5. Fixture outputs are stable and secret output redaction still works through
   the existing local-state persistence tests.
6. CLI `plan` shows the new two-resource GCP graph.

Verification commands:

```sh
bun run ziac:test
cd packages/ziac && zig build examples && zig build
```

## Migration And Compatibility

The `hello-global` fixture plan summary will change from one create to two
creates. This is acceptable because the local CLI state feature is still fixture
based and not a public stable stack contract.

Existing resource graph, plan, apply, provider, local-state, and CLI APIs should
continue to work. The new GCP module should be additive except for fixture
expectation updates.

## Future Work

1. Live GCP provider adapter with ADC/service-account authentication.
2. Cloud Run read/adopt/drift detection.
3. Serverless NEG and global external Application Load Balancer resources.
4. `gcp.global.ContainerService`.
5. Zig source-to-image build pipeline.
6. CockroachDB provider/resources and app env binding validation.
7. Comptime validation between app env structs, resource bindings, provider
   availability, and output wiring.
