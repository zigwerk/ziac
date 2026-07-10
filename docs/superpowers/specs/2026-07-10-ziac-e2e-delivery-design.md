# Ziac End-to-End Delivery Design

Date: 2026-07-10

Status: approved by the user directive to deliver Ziac end to end

## 1. Purpose

Ziac is a Zig-native Infrastructure-as-Code product for deploying Zig backends
globally on Google Cloud Run with CockroachDB as the first data platform. It is
powered by zigeffect and zigeffect-std, but it is a separate product package with
its own resource model, state format, provider lifecycle, CLI, and high-level
components.

The product promise is:

> A developer can point Ziac at a Zig HTTP application, declare its typed
> environment, choose GCP regions and a CockroachDB cluster, and receive a
> globally routed, TLS-secured deployment whose app bindings, provider
> availability, resource dependencies, secret handling, and output wiring are
> validated at compile time.

This design replaces the previous feature-list roadmap with an end-to-end
architecture, delivery order, acceptance gates, and production completion
criteria.

## 2. Current Baseline

The completed baseline contains:

- A standalone `packages/ziac` Zig package and executable.
- Resource identity and dependency graph primitives.
- In-memory state and deterministic local JSON persistence.
- Create/noop and destroy planning.
- A provider vtable and fake provider.
- `plan`, `deploy`, `destroy`, `outputs`, and `state` CLI commands.
- Secret redaction in persisted and displayed outputs.
- Plan-only GCP provider config, Artifact Registry repository, and Cloud Run
  service builders.
- A two-resource `hello-global` fixture stack.
- Forty passing package and example tests.

The baseline intentionally has no live provider calls. It proves the local
command loop, but it is not yet a deployable alpha.

Important limitations in the baseline:

- `ResourceNode` discards desired resource inputs after validation.
- The planner only distinguishes absent and present resources.
- Provider mutations return no physical IDs, outputs, or observed state.
- Apply order relies on insertion order rather than the dependency graph.
- The CLI always uses the fake provider and a hard-coded fixture registry.
- Outputs are copied strings rather than typed references resolved after apply.
- Zigeffect does not yet execute provider operations.
- CockroachDB and compile-time app bindings are not implemented.

## 3. Product Scope

### 3.1 Alpha Product

The first usable alpha supports:

1. One GCP project.
2. An existing container image in Artifact Registry.
3. Two or more regional Cloud Run services.
4. A global external Application Load Balancer with one serverless NEG per
   region.
5. A custom domain, Google-managed TLS certificate, and optional Cloud DNS
   record.
6. An existing CockroachDB Cloud cluster.
7. A generated or existing SQL user credential stored in GCP Secret Manager.
8. Public CockroachDB connectivity through Cloud Run Direct VPC egress, Cloud
   NAT, a static egress address, and a narrow CockroachDB allowlist.
9. Comptime validation between an application `Env` type and resource bindings.
10. Local state for development and a GCS state backend with optimistic locking
    for shared environments.
11. Native GCP authentication through Application Default Credentials.
12. Repeatable plan, deploy, refresh, outputs, import, and destroy behavior.

### 3.2 Beta Product

Beta adds:

- Zig source-to-image builds through Cloud Build.
- `ziac.gcp.global.ZigService` as the primary product API.
- CockroachDB Cloud cluster creation for Basic, Standard, and Advanced plans.
- GCP Private Service Connect for eligible CockroachDB Standard and Advanced
  clusters.
- Regional CockroachDB connection selection.
- Migration jobs and deployment gates.
- Workload Identity Federation for CI.
- Preview stacks and protected production resources.
- Canary regional rollouts and automated failover verification.

### 3.3 Explicit Non-Goals

The initial product does not support:

- Cloudflare, AWS, Azure, Kubernetes, or arbitrary Terraform providers.
- Self-hosted CockroachDB provisioning.
- A general-purpose HCL or YAML configuration language.
- Dynamic plugins loaded into the Ziac process.
- Storing plaintext secret values in state.
- Reimplementing a complete PostgreSQL client before the first live GCP slice.

## 4. Product API

The intended user experience is a compiled Zig stack program:

```zig
const ziac = @import("ziac");

const Api = struct {
    pub const Env = struct {
        database_url: ziac.binding.Secret(ziac.cockroach.ConnectionUrl),
        region: ziac.binding.Value(ziac.gcp.Region),
    };

    pub fn run(env: Env) !void {
        _ = env;
    }
};

pub fn stack(ctx: anytype) !void {
    const database = try ctx.cockroach.existingCluster("app-db", .{
        .cluster_id = ctx.config.secret("COCKROACH_CLUSTER_ID"),
        .networking = .public_static_egress,
    });

    const service = try ctx.gcp.global.zigService(Api, "api", .{
        .regions = &.{ "europe-west1", "us-central1" },
        .domain = "api.example.com",
        .env = .{
            .database_url = database.connection_url,
            .region = ziac.gcp.currentRegion(),
        },
    });

    ctx.exportValue("url", service.url);
}

pub fn main() !void {
    try ziac.run(.{
        .name = "example",
        .providers = .{ .gcp, .cockroach },
        .program = stack,
    });
}
```

The exact spelling can evolve during implementation. The required properties
are stable:

- The stack is a normal Zig program.
- Provider availability is part of the stack type.
- Application environment requirements are ordinary Zig types.
- Bindings are typed outputs, not strings.
- Dependencies are derived from output references.
- Invalid wiring fails at compile time where the information is static.
- Provider and runtime failures remain typed zigeffect failures.

## 5. Core Resource Model

### 5.1 Desired Resource

Every graph node must retain a canonical desired resource document:

```zig
pub const DesiredResource = struct {
    id: []const u8,
    provider: ProviderId,
    type_name: []const u8,
    schema_version: u32,
    logical_id: []const u8,
    inputs_json: []const u8,
    inputs_hash: [32]u8,
    dependencies: []const ResourceId,
    lifecycle: Lifecycle,
};
```

Typed resource builders own their public argument structs and normalize them
into deterministic JSON. The graph owns the resulting bytes. Secret inputs are
represented by opaque secret references; plaintext values are never serialized
into the desired document.

### 5.2 Lifecycle

Lifecycle configuration includes:

- `protect`: reject deletion unless explicitly overridden.
- `retain_on_delete`: remove from Ziac state without deleting the remote object.
- `replace_before_delete`: opt into create-before-destroy where supported.
- `ignore_changes`: a typed list of provider-approved fields.
- operation timeouts.

Lifecycle behavior is part of planning, not provider-specific ad hoc logic.

### 5.3 Typed Outputs

Resource wrappers expose outputs as typed references:

```zig
pub fn Output(comptime T: type, comptime secrecy: Secrecy) type;
```

Each output reference contains:

- The source resource ID.
- The provider output field.
- The Zig value type.
- Whether the value is public or secret.
- Whether the value is known during planning.

Passing an output into another resource automatically adds a dependency edge.
Secret outputs cannot be coerced to plain strings or exported as public outputs.

### 5.4 Values In State

Provider outputs use a small owned value algebra:

- string
- integer
- boolean
- string list
- object
- secret reference
- unknown

The value algebra is deterministic, serializable, and independent of any one
provider. It does not store secret plaintext.

## 6. Comptime Contracts

Comptime validation is Ziac's defining product feature.

### 6.1 App Environment Validation

`validateBindings(App.Env, bindings)` uses Zig reflection to enforce:

1. Every required `Env` field has exactly one binding.
2. No unknown binding names are supplied.
3. Binding value types match environment field types.
4. Secret fields receive secret outputs.
5. Public fields cannot accidentally receive secret outputs.
6. Optional environment fields may be omitted.
7. Region-dependent values can only be bound inside a regional service.

Diagnostics use stable codes such as:

- `ZIAC100`: missing app binding.
- `ZIAC101`: unknown app binding.
- `ZIAC102`: binding type mismatch.
- `ZIAC103`: secret/public mismatch.
- `ZIAC104`: regional binding used outside regional scope.

### 6.2 Provider Availability

The stack context is parameterized by a comptime provider set. Calling a GCP
resource without `.gcp` or a Cockroach resource without `.cockroach` produces a
compile error before graph construction.

### 6.3 Output Wiring

Output field names and types are declarations on resource types. A reference to
an unknown field or incompatible output type fails to compile. The reference
also contributes its source resource to the consumer's dependency set.

### 6.4 Compile-Fail Tests

The build includes fixture programs that are expected to fail compilation with a
specific Ziac diagnostic code. Required fixtures cover missing bindings, extra
bindings, type mismatches, secret mismatches, absent providers, and invalid
regional wiring.

## 7. Provider Lifecycle

The provider boundary evolves from `reconcile/delete` into an explicit resource
lifecycle:

```text
normalize -> read -> diff -> create/update/replace/delete -> read
```

Provider operations receive a context containing the allocator, HTTP client,
credentials, clock, cancellation scope, logger, and state transaction.

Required operations:

- `normalize`: validate and canonicalize desired inputs.
- `read`: return present/absent plus observed inputs and outputs.
- `diff`: classify changes as noop, update, replace, or delete/recreate.
- `create`: create the remote object and return physical state.
- `update`: mutate the remote object and return physical state.
- `delete`: delete the remote object or confirm it is already absent.
- `import`: turn a provider identifier into managed state.

Mutation results include physical ID, observed inputs hash, owned outputs,
provider metadata, and an optional asynchronous operation handle.

Provider error categories are stable:

- authentication
- authorization
- invalid configuration
- conflict
- not found
- quota
- rate limited
- transient
- timeout
- cancelled
- provider bug

Raw provider response bodies are redacted before diagnostics or traces.

## 8. Planning And Execution

### 8.1 Refresh And Diff

Planning refreshes managed resources unless `--refresh=false` is explicitly
selected. The planner compares desired, prior, and observed state to produce:

- create
- update
- replace
- delete
- import
- read
- noop

Resources present in prior state but absent from the desired graph are planned
for deletion. Provider diff logic determines which field changes require
replacement.

### 8.2 Ordering

Create and update operations run in topological dependency order. Delete
operations run in reverse topological order. Independent operations may run in
parallel up to a configurable bound.

### 8.3 Zigeffect Runtime

Every operation is a zigeffect effect with:

- A child scope.
- Cancellation propagation.
- Structured timeout and retry policy.
- Causal spans and redacted operation facts.
- A deterministic completion value.

The first failure interrupts dependent work. Successful independent operations
remain recorded in state so a rerun can resume safely. Automatic destructive
rollback is only used where the resource explicitly declares a safe
compensation; Ziac does not pretend arbitrary infrastructure changes are
transactional.

### 8.4 State Checkpoints

State is checkpointed after every completed mutation. A process interruption can
leave operations in an `applying` state with their provider operation handle.
The next refresh reconciles those handles before generating a new plan.

## 9. State Architecture

### 9.1 State Document

The state envelope contains:

- format version
- stack and stage
- lineage ID
- monotonically increasing serial
- writer identity
- created and updated timestamps
- resource records
- exported output records

Resource records contain desired and observed hashes, physical ID, provider
metadata, typed outputs, status, dependencies, and the last operation handle.

### 9.2 Local State

Local state remains under `.ziac/state/<stack>/<stage>/`, but writes become
atomic through a temporary file and rename. A lock file prevents concurrent
local writers. State migrations are tested from every released format version.

### 9.3 GCS Remote State

The first remote backend is GCS. It uses object generation preconditions as an
optimistic lock. A writer reads generation N and can only write N+1 if N remains
current. State conflict diagnostics identify the competing writer and do not
overwrite remote state.

### 9.4 Secrets

State stores only secret resource names, versions, and provider references.
Secret plaintext may exist briefly in memory while creating a Secret Manager
version or Cockroach SQL user, but it is never written to state, plan output,
logs, traces, receipts, or crash artifacts.

## 10. Transport And Authentication

### 10.1 HTTP

zigeffect-std HTTP must support:

- Owned response headers.
- Bounded request and response bodies.
- Connect and operation timeouts.
- Cancellation.
- Redirect policy.
- Structured transport errors.
- Retry policy with `Retry-After` support.
- Test transports that can script response sequences.

### 10.2 Google Authentication

Ziac implements Application Default Credentials in documented search order:

1. `GOOGLE_APPLICATION_CREDENTIALS` credential configuration.
2. The local ADC file created by `gcloud auth application-default login`.
3. The attached service account metadata server.

Credential sources support authorized-user refresh tokens, service-account JWT
exchange, external-account Workload Identity Federation, and metadata tokens.
Tokens are cached until shortly before expiry and never logged.

An `ziac auth doctor` command reports which source was selected, the project and
principal when discoverable, and permission probes without displaying tokens.

### 10.3 Cockroach Cloud Authentication

The Cockroach Cloud provider reads a service-account API key from a secret config
source, sends it as a bearer token, and pins the supported `Cc-Version` header.
The client honors `Retry-After` and the documented API rate limit.

## 11. GCP Provider

### 11.1 Initial Raw Resources

The live GCP provider implements:

- `gcp.project.Service`
- `gcp.iam.ServiceAccount`
- `gcp.iam.ProjectMember`
- `gcp.artifact.Repository`
- `gcp.secret.Secret`
- `gcp.secret.SecretVersion`
- `gcp.secret.SecretIamMember`
- `gcp.run.Service`
- `gcp.compute.GlobalAddress`
- `gcp.compute.RegionServerlessNeg`
- `gcp.compute.BackendService`
- `gcp.compute.UrlMap`
- `gcp.compute.ManagedSslCertificate`
- `gcp.compute.TargetHttpsProxy`
- `gcp.compute.GlobalForwardingRule`
- `gcp.dns.RecordSet`
- VPC, subnet, router, NAT, and static egress address resources needed for safe
  CockroachDB public connectivity.

Every resource has read/create/update/delete behavior, import syntax, replacement
rules, deterministic state normalization, and fake transport contract tests.

### 11.2 Long-Running Operations

Google APIs that return operations are polled with bounded exponential backoff.
Operation names are checkpointed in state. Polling resumes after interruption.
Terminal Google errors are converted to structured provider failures.

### 11.3 Cloud Run Service

Cloud Run uses the v2 REST API and supports:

- Immutable image digest input.
- Port and command configuration.
- CPU, memory, concurrency, timeout, min/max instance settings.
- Service identity.
- Plain environment values.
- Secret Manager environment and volume references.
- Startup, liveness, and readiness probes.
- Direct VPC egress.
- `internal-and-cloud-load-balancing` ingress for globally fronted services.
- Public invoker or authenticated invocation policy.
- Revision output and canonical service URI from the live API.

Synthetic planning URLs are removed once live outputs exist.

## 12. Global Container Component

`ziac.gcp.global.ContainerService` is the first AWSx-style product component.

Inputs include:

- image reference or digest
- regions
- domain
- optional existing DNS zone
- service account and IAM grants
- environment bindings
- scaling and resource limits
- readiness path
- failover mode
- protection and retention policy

The component expands into:

1. Required GCP APIs.
2. One Cloud Run service per region.
3. One serverless NEG per region.
4. One global backend service.
5. A global static anycast address.
6. URL map.
7. Managed certificate.
8. HTTPS proxy and forwarding rule.
9. Optional HTTP redirect resources.
10. Optional Cloud DNS record.

Premium network tier is mandatory. Region names must be unique. The service and
NEG must share a region and project.

The production default failover mode uses Cloud Run service health with at least
one service-level minimum instance per region and a readiness probe. A lower-cost
mode can use outlier detection with an explicit diagnostic explaining its weaker
failure behavior.

Completion requires a live two-region test that demonstrates:

- DNS and certificate readiness.
- Requests reaching both regional deployments from controlled probes.
- The global URL remaining available after one regional service is made
  unhealthy.
- Direct `run.app` ingress being rejected from the public internet.

## 13. CockroachDB Provider

### 13.1 Resource Progression

CockroachDB support is delivered in this order:

1. `cockroach.ExistingCluster`
2. `cockroach.SqlUser`
3. `cockroach.ConnectionSecret`
4. `cockroach.Database`
5. `cockroach.Grants`
6. `cockroach.Migration`
7. `cockroach.Cluster`
8. private connectivity resources

Existing-cluster support comes first so the GCP data path can be proven without
making expensive cluster lifecycle mistakes.

### 13.2 Cloud API Resources

The Cockroach Cloud API manages cluster discovery, cluster creation where
enabled, SQL users, network allowlists, and private connectivity. Cluster
resources default to `protect = true`. Destroying a cluster requires both a plan
showing protection removal and an explicit confirmation flag.

### 13.3 SQL Resources

Database, grants, and migrations use a SQL executor behind a provider interface.
The first implementation may use the existing `psql` adapter for local tooling,
but production `ZigService` completion requires a native PostgreSQL wire client
with TLS, connection pooling, cancellation, and structured SQLSTATE errors.

Cockroach transaction helpers recognize retryable `40001` errors and ambiguous
`40003` outcomes. Migration operations are serialized and recorded in a
dedicated migration table.

### 13.4 Secrets

SQL passwords are generated with a cryptographically secure random source. The
password is written to a GCP Secret Manager version and applied to the Cockroach
SQL user without entering Ziac state. Retry logic can safely converge after a
partial failure by resetting the SQL user password to the already-created secret
value.

Connection bindings include host, port, database, username, TLS mode, and CA
material. The application normally receives one Secret Manager-backed
`DATABASE_URL` or discrete typed fields.

### 13.5 Networking

Supported modes:

- `existing`: the user supplies a reachable endpoint and manages authorization.
- `public_static_egress`: Ziac creates regional Direct VPC egress, Cloud NAT,
  static addresses, and Cockroach allowlist rules.
- `private_service_connect`: Ziac creates the GCP and Cockroach Cloud resources
  required for eligible Standard or Advanced clusters.

Production validation rejects unrestricted public allowlists unless an explicit
unsafe override is supplied. Application regions are compared with CockroachDB
regions, and Ziac warns or fails when no region-local database gateway exists,
according to the component policy.

## 14. Zig Source-To-Image

`ziac.gcp.global.ZigService` wraps `ContainerService` and adds a build pipeline.

The pipeline:

1. Discovers `build.zig` and the selected executable artifact.
2. Creates a deterministic source archive honoring ignore rules.
3. Computes a source and build-configuration digest.
4. Uploads the build context to Cloud Build.
5. Builds a Linux container image using a pinned Zig toolchain image.
6. Pushes the image to Artifact Registry.
7. Resolves the immutable image digest.
8. Deploys the digest to all regional Cloud Run services.

The generated container follows the Cloud Run contract, listens on `PORT`, runs
as a non-root user where possible, and includes no build toolchain in the final
image.

The build digest is a resource input. Unchanged source and build configuration
produce a noop plan and reuse the existing image.

## 15. CLI And Developer Experience

The production CLI supports:

- `ziac plan`
- `ziac deploy`
- `ziac refresh`
- `ziac destroy`
- `ziac outputs`
- `ziac state`
- `ziac import`
- `ziac auth doctor`
- `ziac unlock`

User stacks are compiled executables that call `ziac.run`; the standalone CLI
remains useful for fixtures, state inspection, and package development. Commands
support human and stable JSON output.

Plans display reasons, dependencies, replacements, unknown outputs, protected
deletes, and estimated provider operations. Deploy can consume a saved plan and
rejects it if state serial or desired input hashes have changed.

## 16. CI And Operations

CI uses Workload Identity Federation rather than exported service-account keys.
Each preview stage has isolated names and state. Production deployment supports
manual approval of a saved plan.

Operational requirements:

- Structured redacted logs and causal traces.
- Per-resource timing and retry metrics.
- Provider request IDs in diagnostics.
- State conflict visibility.
- Crash and cancellation tests.
- Quota and rate-limit tests.
- Resource protection.
- Documented disaster recovery for lost local state and locked remote state.

## 17. Test Strategy

### 17.1 Unit Tests

- Canonical input encoding and hashes.
- Graph ordering and cycle diagnostics.
- Desired/prior/observed diff cases.
- State version migrations.
- Secret non-disclosure.
- Provider response parsing and error classification.
- Comptime contract fixtures.

### 17.2 Contract Tests

Each provider resource runs against a scripted HTTP or SQL transport covering
create, read, update, delete, already-absent, rate limit, transient error,
permission failure, malformed response, and interrupted long-running operation.

### 17.3 Local Integration Tests

- Full CLI plan/deploy/refresh/destroy loop through fake providers.
- Concurrent DAG execution with deterministic checkpoints.
- Resume after forced process interruption.
- GCS state conflict simulation.
- Cockroach migration planning through the local adapter.

### 17.4 Live End-To-End Tests

Live tests use disposable, explicitly configured GCP and CockroachDB resources.
They are opt-in locally and scheduled in protected CI.

Required live gates:

1. Artifact Registry and single-region Cloud Run lifecycle.
2. Two-region global ContainerService with TLS and failover.
3. Existing CockroachDB cluster, SQL user, Secret Manager binding, and successful
   TLS query from Cloud Run.
4. Zig source build to immutable image and global deployment.
5. GCS state conflict and interrupted-operation resume.
6. Complete destroy with protected Cockroach cluster retained by default.

## 18. Delivery Milestones

### M0: Integration And Architecture

- Integrate the plan-only GCP foundation.
- Commit this design and the executable implementation plan.
- Replace the package roadmap with acceptance-gated milestones.

### M1: Engine V2

- Retained desired inputs and hashes.
- Typed provider state and outputs.
- Read/diff/create/update/delete lifecycle.
- Correct DAG ordering and checkpointed execution.
- Versioned atomic local state.

### M2: Comptime Contracts

- Typed bindings and outputs.
- App `Env` validation.
- Provider-set validation.
- Automatic dependency derivation.
- Compile-fail test suite.

### M3: Transport And Authentication

- Production HTTP behavior.
- Google ADC and token caching.
- Cockroach Cloud API client.
- Auth diagnostics.

### M4: Live GCP Primitives

- API enablement, IAM, Artifact Registry, Secret Manager, and Cloud Run.
- Live single-region lifecycle gate.

### M5: Global ContainerService

- Load-balancer primitives and component expansion.
- Multi-region TLS and failover gate.

### M6: CockroachDB

- Existing cluster, SQL user, secrets, SQL resources, and networking.
- Cloud Run-to-Cockroach TLS data-path gate.
- Cluster provisioning and PSC.

### M7: ZigService

- Cloud Build source pipeline.
- Immutable image deployment.
- Comptime app environment integration.

### M8: Production Operations

- GCS state, locking, WIF, preview stages, saved plans, rollouts, recovery, and
  complete live end-to-end verification.

## 19. Completion Definition

The end-to-end goal is complete only when all of the following are true:

1. A sample Zig backend declares a typed `Env` and fails compilation for invalid
   resource wiring.
2. One command builds its image and deploys it to at least two Cloud Run regions.
3. A global HTTPS URL routes to those services and survives a tested regional
   failure.
4. The backend connects to CockroachDB over TLS using a Secret Manager binding.
5. Plan, refresh, update, import, interrupted resume, and destroy are verified.
6. State supports safe concurrent use through GCS generation locking.
7. No secret plaintext appears in state, output, logs, traces, or test artifacts.
8. CI authenticates without long-lived GCP service-account keys.
9. All package, contract, integration, compile-fail, and configured live tests
   pass from a clean checkout.
10. The public API, architecture, operations, and recovery procedures are
    documented with a working example.

## 20. External Platform References

- Google Cloud Run multi-region routing:
  https://docs.cloud.google.com/run/docs/multiple-regions
- Cloud Run service health:
  https://docs.cloud.google.com/run/docs/configuring/configure-service-health
- Serverless NEG behavior:
  https://docs.cloud.google.com/load-balancing/docs/negs/serverless-neg-concepts
- Cloud Run v2 REST service:
  https://docs.cloud.google.com/run/docs/reference/rest/v2/projects.locations.services
- Application Default Credentials:
  https://docs.cloud.google.com/docs/authentication/application-default-credentials
- Cloud Run Secret Manager bindings:
  https://docs.cloud.google.com/run/docs/configuring/services/secrets
- Cloud Run Direct VPC egress:
  https://docs.cloud.google.com/run/docs/configuring/vpc-direct-vpc
- CockroachDB Cloud API:
  https://www.cockroachlabs.com/docs/cockroachcloud/cloud-api
- CockroachDB network authorization:
  https://www.cockroachlabs.com/docs/cockroachcloud/network-authorization
- CockroachDB connection security:
  https://www.cockroachlabs.com/docs/cockroachcloud/authentication
- CockroachDB transaction retries:
  https://www.cockroachlabs.com/docs/stable/transactions
- CockroachDB connection pooling:
  https://www.cockroachlabs.com/docs/stable/connection-pooling
