# Ziac End-to-End Delivery Implementation Plan

Date: 2026-07-10

Design:
`docs/superpowers/specs/2026-07-10-ziac-e2e-delivery-design.md`

Goal: deliver a production-capable Ziac path from a typed Zig application to a
globally routed GCP Cloud Run service with CockroachDB bindings, safe state, and
end-to-end verification.

## Execution Rules

Every implementation task follows this loop:

1. Add or update the narrowest failing test first.
2. Run the targeted test and record the expected failure.
3. Implement the smallest production change that satisfies the test.
4. Run the targeted test, `bun run ziac:test`, and `git diff --check`.
5. Run broader dependent-package checks when a shared contract changes.
6. Commit one coherent change with no unrelated files.

Additional rules:

- Keep live provider tests opt-in and credential-gated.
- Never place secret plaintext in fixtures, state, snapshots, diagnostics, or
  process arguments.
- Use scripted transports for provider contract tests.
- Do not add a raw provider resource without read/create/update/delete contract
  coverage.
- Do not mark a milestone complete until its acceptance gate passes.
- Preserve compatibility migrations for every persisted state format.
- Add provider functionality under `packages/ziac/src`, not as report tools.

## Verification Matrix

Run after package-local changes:

```sh
bun run ziac:test
cd packages/ziac && zig build examples
cd packages/ziac && zig build
git diff --check
```

Run when changing zigeffect-std:

```sh
bun run zigeffect:std:test
bun run ziac:test
```

Run when changing Postgres support:

```sh
bun run zigeffect:postgres:test
bun run ziac:test
```

Run before every milestone merge:

```sh
bun run zigeffect:test
bun run zigeffect:std:test
bun run zigeffect:postgres:test
bun run ziac:test
bun run ziac:examples
cd packages/ziac && zig build
git diff --check
```

Live tests require explicit environment configuration and must refuse to run
when the target project is not marked disposable.

---

## Milestone M0: Integration And Architecture

### Task 0.1: Integrate GCP Provider Foundation

Status: completed on 2026-07-10.

Actions:

- Fast-forward `codex/ziac-gcp-provider-foundation` into
  `zigeffect-engine-cleanup`.
- Verify all package tests, examples, and executable build.
- Continue delivery on `codex/ziac-e2e`.

Evidence:

- 39 Ziac package tests passed.
- 1 Ziac example test passed.
- Ziac executable build passed.

### Task 0.2: Commit Authoritative Design And Roadmap

Files:

- Create `docs/superpowers/specs/2026-07-10-ziac-e2e-delivery-design.md`.
- Create `docs/superpowers/plans/2026-07-10-ziac-e2e-delivery.md`.
- Replace `packages/ziac/docs/roadmap.md` with acceptance-gated milestones.
- Update `packages/ziac/README.md` with the current readiness statement.

Acceptance:

- Product scope distinguishes alpha, beta, and explicit non-goals.
- Every milestone has a testable completion gate.
- The docs state that current GCP support is plan-only.
- The docs identify existing CockroachDB clusters as the first data slice.

Commit: `Document Ziac end-to-end delivery roadmap`

---

## Milestone M1: Engine V2

### Task 1.1: Owned Canonical Values

Files:

- Create `packages/ziac/src/value.zig`.
- Create `packages/ziac/test/value_test.zig`.
- Update `packages/ziac/src/ziac.zig`.
- Update `packages/ziac/test/all_test.zig`.

Tests:

- Encode strings, integers, booleans, lists, objects, secret references, and
  unknown values deterministically.
- Sort object fields by key.
- Reject duplicate object fields.
- Clone and deinitialize every value variant without leaks.
- Redact secret references in display JSON.

Implementation:

- Add an owned `Value` union and ordered `Field` representation.
- Add canonical JSON encoding and SHA-256 hashing.
- Add `SecretReference` with provider, resource, version, and optional field.
- Keep secret plaintext out of the value algebra.

Acceptance:

- Equivalent objects produce identical JSON and hashes independent of input
  field order.
- Secret references serialize without secret data.

Commit: `Add Ziac canonical resource values`

### Task 1.2: Retain Desired Resource Inputs

Files:

- Modify `packages/ziac/src/resource.zig`.
- Modify GCP resource builders.
- Modify `packages/ziac/src/stack_registry.zig`.
- Modify resource and GCP tests.

Tests:

- A resource owns provider ID, schema version, canonical inputs, input hash, and
  lifecycle settings.
- Cloud Run desired state retains image, port, env, service identity, and region.
- Artifact Registry desired state retains project, location, format, and labels.
- Graph teardown frees all owned desired values.

Implementation:

- Replace metadata-only `ResourceNode` with an owned desired-resource record.
- Keep public typed argument structs at resource boundaries.
- Normalize args into canonical `Value` objects.
- Move string ownership into the graph.

Acceptance:

- A provider can reconstruct a complete API request from a graph node.
- No provider input exists only in a temporary builder variable.

Commit: `Retain typed desired state in Ziac resources`

### Task 1.3: State Format V2

Files:

- Modify `packages/ziac/src/state.zig`.
- Modify `packages/ziac/src/local_state.zig`.
- Add `packages/ziac/src/state_format.zig`.
- Update state and local-state tests.

Tests:

- State envelope has version, lineage, serial, stack, stage, and timestamps.
- Resource records persist provider, schema version, physical ID, desired hash,
  observed hash, dependencies, outputs, status, and operation handle.
- V1 fixture state migrates deterministically to V2.
- Unknown future versions fail without modifying files.
- Secret references round-trip while plaintext sentinel secrets never appear.

Implementation:

- Separate in-memory state behavior from persisted state schema.
- Own all state strings and values.
- Add format migration dispatch.
- Persist deterministic JSON through structured writers.

Acceptance:

- Existing fixture state remains readable.
- A V2 state round trip is byte stable.

Commit: `Add versioned Ziac state records`

### Task 1.4: Provider Resource Lifecycle

Files:

- Replace `packages/ziac/src/provider.zig` contracts.
- Add `packages/ziac/src/provider_error.zig`.
- Update `packages/ziac/src/apply.zig`.
- Replace provider/apply tests with lifecycle conformance tests.

Tests:

- Read returns absent or observed resource state.
- Diff returns noop, update, or replace with reasons.
- Create and update return physical ID and outputs.
- Delete is idempotent when the remote object is absent.
- Import returns normalized managed state.
- Structured provider errors preserve category and redacted detail.

Implementation:

- Add `ResourceProvider` vtable with normalize/read/diff/create/update/delete and
  import operations.
- Add owned mutation and observation results.
- Upgrade the fake provider to a deterministic in-memory remote system.
- Add a provider registry keyed by provider ID.

Acceptance:

- Fake provider conformance covers the complete lifecycle.
- Apply no longer writes placeholder `inputs_hash = "v1"` records.

Commit: `Add Ziac provider lifecycle contracts`

### Task 1.5: Refresh-Aware Planner

Files:

- Rewrite `packages/ziac/src/plan.zig`.
- Add `packages/ziac/src/refresh.zig`.
- Expand planner tests.

Tests:

- Absent desired resource plans create.
- Matching desired/prior/observed plans noop.
- Mutable changes plan update.
- Immutable changes plan replace.
- Prior-only resources plan delete.
- Drift plans update or records observed-only change according to policy.
- Protected resources reject delete and replace plans.
- Import plans are explicit.
- Reasons and unknown outputs are stable.

Implementation:

- Refresh prior records through provider reads.
- Ask providers for resource-specific diffs.
- Include removed resources in planning.
- Store plan preconditions: lineage, serial, and desired graph digest.

Acceptance:

- Repeated deploys converge to noop after refresh.
- A changed Cloud Run image can eventually plan an update without special CLI
  code.

Commit: `Add refresh-aware Ziac planning`

### Task 1.6: Dependency-Ordered Execution

Files:

- Add `packages/ziac/src/executor.zig`.
- Modify `packages/ziac/src/resource.zig` graph algorithms.
- Retire sequential logic from `packages/ziac/src/apply.zig` or make it a facade.
- Add executor tests.

Tests:

- Dependencies complete before consumers start.
- Deletes run consumers before dependencies.
- Independent resources execute up to the concurrency bound.
- A dependency failure prevents consumer execution.
- Cancellation interrupts children and records incomplete operations.
- Retryable failures follow a deterministic schedule.
- Non-retryable failures stop immediately.

Implementation:

- Add stable topological levels and reverse levels.
- Execute each operation as a zigeffect effect in a child scope.
- Add bounded parallelism, cancellation, timeout, and retry policy.
- Record causal operation facts with redacted details.

Acceptance:

- Execution order is derived from the graph, never insertion order.
- Independent fake resources demonstrably run concurrently.

Commit: `Execute Ziac plans through zigeffect scopes`

### Task 1.7: Checkpoint And Resume

Files:

- Add `packages/ziac/src/checkpoint.zig`.
- Modify executor and state store interfaces.
- Add interruption fixtures and tests.

Tests:

- Every completed mutation increments state serial and persists a checkpoint.
- Interrupted long-running operations retain their operation handle.
- Resume polls or reads an incomplete operation before replanning.
- An already-completed remote create is adopted after a local interruption.
- Failed atomic state writes leave the previous state intact.

Implementation:

- Add a state transaction/checkpoint interface.
- Persist after each provider mutation and terminal operation poll.
- Reconcile `applying` records during refresh.
- Use temporary-file plus rename for local state writes.

Acceptance:

- Killing a fixture deploy mid-plan and rerunning does not duplicate resources.

Commit: `Add checkpointed Ziac deployment recovery`

### Task 1.8: Local Locking And State Commands

Files:

- Modify `packages/ziac/src/local_state.zig`.
- Modify `packages/ziac/src/cli.zig`.
- Add lock and state migration tests.

Tests:

- A second writer receives a lock conflict.
- Stale lock inspection is safe.
- Forced unlock requires matching lineage or explicit override.
- `refresh` updates observed state without mutating desired infrastructure.
- `import` validates provider identifiers.

Implementation:

- Add lock metadata and ownership.
- Add `refresh`, `import`, and `unlock` commands.
- Add stable JSON command output.

M1 Gate:

- Full fake-provider create/update/replace/delete/import lifecycle passes.
- Interrupted deployment resumes without duplicate remote objects.
- Existing V1 local state migrates to V2.
- All dependent package tests pass.

Commit: `Complete Ziac Engine V2 local workflow`

---

## Milestone M2: Comptime Contracts

### Task 2.1: Typed Output References

Files:

- Rewrite `packages/ziac/src/output.zig`.
- Modify resource builders and graph insertion.
- Expand output and graph tests.

Tests:

- Public and secret outputs have distinct types.
- Output references identify resource and field.
- Binding an output adds one dependency edge.
- Duplicate derived edges are removed.
- Secret outputs cannot use public export helpers.
- Unknown planning values remain typed.

Implementation:

- Add `Output(T, secrecy)` and provider output descriptors.
- Add graph-aware input resolution.
- Resolve live output values from state after provider mutation.

Acceptance:

- No GCP or Cockroach resource output is represented by a guessed string.

Commit: `Add typed Ziac output wiring`

### Task 2.2: Binding Types And App Env Validation

Files:

- Add `packages/ziac/src/binding.zig`.
- Add `packages/ziac/test/binding_test.zig`.
- Add compile-success fixtures.

Tests:

- Exact `Env` field and binding match succeeds.
- Optional fields may be omitted.
- Value type and secrecy metadata are inspectable at comptime.
- Regional bindings carry regional scope.

Implementation:

- Add `Value(T)` and `Secret(T)` app environment field descriptors.
- Reflect over `App.Env` and binding structs.
- Return a typed normalized binding set to service builders.

Acceptance:

- A valid sample app binds a Cockroach connection and GCP region without runtime
  name lookup.

Commit: `Add comptime app environment bindings`

### Task 2.3: Provider Set Validation

Files:

- Add `packages/ziac/src/stack.zig`.
- Replace fixture-only stack context incrementally.
- Add provider-set tests.

Tests:

- GCP resources compile with `.gcp` available.
- Cockroach resources compile with `.cockroach` available.
- Provider sets are duplicate-free and stable.
- Runtime provider registry is derived from the comptime provider set.

Implementation:

- Parameterize stack context by a comptime provider tuple.
- Expose typed provider namespaces from the context.
- Construct only declared runtime providers.

Acceptance:

- Provider availability is no longer discovered only after CLI execution.

Commit: `Add comptime Ziac provider sets`

### Task 2.4: Compile-Fail Diagnostic Suite

Files:

- Add `packages/ziac/test/compile_fail/` fixtures.
- Add a Zig build step that checks expected compiler diagnostics.
- Update CI scripts.

Fixtures:

- Missing app binding: `ZIAC100`.
- Extra binding: `ZIAC101`.
- Binding type mismatch: `ZIAC102`.
- Secret/public mismatch: `ZIAC103`.
- Invalid regional scope: `ZIAC104`.
- Missing GCP provider: `ZIAC110`.
- Missing Cockroach provider: `ZIAC111`.
- Unknown resource output field: `ZIAC120`.

M2 Gate:

- Valid fixtures compile.
- Every invalid fixture fails for the intended diagnostic code.
- Output references derive dependencies in the runtime graph.

Commit: `Add Ziac comptime contract diagnostics`

---

## Milestone M3: Transport And Authentication

### Task 3.1: Production HTTP Contract

Files:

- Modify `packages/zigeffect-std/src/http/root.zig`.
- Add focused HTTP transport tests.
- Update Ziac dependency tests.

Tests:

- Live and fake clients preserve owned response headers.
- Header lookup is case-insensitive.
- Body limits produce typed errors.
- Connect/request timeouts and cancellation are typed.
- Retry policy honors integer and HTTP-date `Retry-After` values.
- Authorization headers and credential bodies are redacted.

Implementation:

- Introduce a client interface shared by live and scripted transports.
- Preserve response headers from `std.http.Client`.
- Add structured HTTP errors and retry metadata.

Acceptance:

- Cockroach and Google clients can make policy decisions from headers.

Commit: `Harden zigeffect std HTTP transport`

### Task 3.2: Google ADC Sources

Files:

- Add `packages/ziac/src/gcp/auth/` modules.
- Add credential fixtures with non-secret dummy values.
- Add auth tests.

Tests:

- ADC source order follows Google documentation.
- Authorized-user refresh exchange is encoded correctly.
- Service-account JWT assertion has correct claims and signature shape.
- External-account token exchange request is correct.
- Metadata token request and expiry parsing work.
- Token cache refreshes before expiry.
- No token appears in diagnostics.

Implementation:

- Add `TokenSource` interface and ADC resolver.
- Add JSON credential decoders through zigeffect-std Schema.
- Add OAuth token exchange clients and metadata source.
- Add secure in-memory token cache.

Acceptance:

- `auth doctor` identifies a source without exposing credentials.

Commit: `Add native Google ADC authentication`

### Task 3.3: Google REST And Operation Client

Files:

- Add `packages/ziac/src/gcp/client.zig`.
- Add `packages/ziac/src/gcp/operation.zig`.
- Add scripted client tests.

Tests:

- Authorized JSON requests include expected headers.
- Google error envelopes map to provider error categories.
- Regional, global, and generic long-running operations poll to completion.
- Operation polling handles transient errors, timeout, and cancellation.
- Request IDs are retained in redacted diagnostics.

Implementation:

- Add API base URL injection for tests.
- Add deterministic JSON request/response helpers.
- Add operation strategy descriptors per API family.

Acceptance:

- Provider resources do not call raw HTTP APIs directly.

Commit: `Add Ziac Google REST operation client`

### Task 3.4: Cockroach Cloud Client

Files:

- Add `packages/ziac/src/cockroach/client.zig`.
- Add Cockroach scripted transport tests.

Tests:

- Bearer token and pinned `Cc-Version` headers are present.
- Pagination is deterministic.
- Rate limit responses honor `Retry-After`.
- Cluster and SQL-user responses decode through typed schemas.
- Authentication and permission failures are distinct.

Implementation:

- Add API key secret config source.
- Add versioned API client and typed response decoders.
- Share HTTP retry and error redaction infrastructure.

M3 Gate:

- Google and Cockroach clients pass scripted transport conformance.
- Auth diagnostics pass without network access.
- zigeffect-std, Postgres, and Ziac suites remain green.

Commit: `Add Cockroach Cloud API client`

---

## Milestone M4: Live GCP Primitives

### Task 4.1: Project Services And IAM

Resources:

- `gcp.project.Service`
- `gcp.iam.ServiceAccount`
- `gcp.iam.ProjectMember`

Tests:

- Full lifecycle through scripted Google responses.
- API enable operation polling.
- IAM etag preservation and conflict retry.
- Import and already-present behavior.

Acceptance:

- A disposable project can enable required APIs and create the service identity.

Commit: `Add live GCP project and IAM resources`

### Task 4.2: Artifact Registry

Resource:

- `gcp.artifact.Repository`

Tests:

- Read/create/update labels/delete/import.
- Location and format replacement rules.
- Already-exists adoption behavior.
- Live disposable repository smoke test.

Acceptance:

- Rerunning a repository deploy plans noop after refresh.

Commit: `Add live GCP Artifact Registry provider`

### Task 4.3: Secret Manager

Resources:

- `gcp.secret.Secret`
- `gcp.secret.SecretVersion`
- `gcp.secret.SecretIamMember`

Tests:

- Secret metadata lifecycle.
- Secret version creation without value disclosure.
- Service identity accessor IAM.
- State stores only resource/version references.

Acceptance:

- Sentinel and generated secret values never appear in captured artifacts.

Commit: `Add live GCP Secret Manager resources`

### Task 4.4: Cloud Run V2

Resource:

- `gcp.run.Service`

Tests:

- Create/read/update/delete/import.
- Image, port, scaling, identity, probes, ingress, plain env, secret env, volume,
  and Direct VPC request encoding.
- Live service URI and revision outputs.
- Immutable field replacement classification.
- Operation resume.

Acceptance:

- A disposable project deploys an existing image to one region.
- A second deploy is noop.
- An image change updates the service.
- Destroy removes the service cleanly.

Commit: `Add live GCP Cloud Run V2 provider`

### Task 4.5: Live Provider CLI Selection

Files:

- Modify stack runner and CLI provider registry.
- Add credential and provider configuration handling.
- Add live test command and safety guard.

Tests:

- Fake provider remains the default for fixture tests.
- A compiled user stack selects the live provider.
- Missing credentials fail before mutation.
- Non-disposable live test projects are rejected.

M4 Gate:

- Authenticated Artifact Registry, Secret Manager, and single-region Cloud Run
  lifecycle passes in a disposable GCP project.
- State contains real physical IDs and outputs.

Commit: `Complete Ziac live single-region GCP slice`

---

## Milestone M5: Global ContainerService

### Task 5.1: Compute Load Balancer Resources

Resources:

- global address
- regional serverless NEG
- global backend service
- URL map
- target HTTPS proxy
- global forwarding rule

Tests:

- Scripted lifecycle and operation polling for each resource.
- Fingerprint/etag conflict behavior.
- One serverless NEG per region validation.
- Backend update preserves unrelated provider fields.
- Delete ordering is forwarding rule to address and service.

Commit: `Add GCP global load balancer resources`

### Task 5.2: Certificate And DNS Resources

Status: completed on 2026-07-10, with authenticated M5 live verification still
owned by Task 5.4.

Resources:

- Google-managed SSL certificate
- Cloud DNS record set
- Optional HTTP redirect proxy and forwarding rule

Tests:

- Domain validation and certificate status outputs.
- DNS read/update/delete with rrset identity.
- Existing-zone reference and import.
- Certificate readiness polling is separate from resource creation.

Evidence:

- Managed certificate create/read/delete/import uses checkpointable global
  Compute operations and exposes provisioning status.
- Readiness polling terminates on `ACTIVE` or typed terminal failure and remains
  separate from engine create.
- Redirect URL map and target HTTP proxy pass full scripted lifecycle tests.
- Cloud DNS record sets pass create/read/update/delete/import and identity-change
  tests against the current rrset REST paths.

Commit: `Add GCP certificate and DNS resources`

### Task 5.3: ContainerService Expansion

Status: completed on 2026-07-10, with authenticated regional failure testing
owned by Task 5.4.

Prerequisite completed on 2026-07-10: provider outputs are canonical desired
input values, derive graph dependencies recursively, and resolve from dependency
state during provider execution. Cloud DNS uses this path for the allocated
global address without persisting a guessed IP.

Files:

- Add `packages/ziac/src/gcp/global/container_service.zig`.
- Add component graph and compile-time tests.

Tests:

- N regions produce N Cloud Run services and N serverless NEGs.
- Global resources are singletons.
- Dependencies are derived from outputs.
- Premium tier, unique regions, domain, probes, and failover constraints validate.
- Production service-health mode requires minimum instances.
- Direct public `run.app` ingress is disabled by default.

Acceptance:

- The component graph is deterministic and contains no hand-authored ordering.

Evidence:

- Two regions produce two Cloud Run services and two serverless NEGs while all
  global resources remain singletons.
- Typed allocated-address inputs drive both forwarding rules and optional DNS;
  graph insertion derives their dependency edges automatically.
- Premium tier, unique/two-region minimum, production warm instances, probes,
  domain, DNS, Cloud Run runtime validation, and restricted ingress are covered.
- The component enables serverless-compatible consecutive-error outlier
  detection with typed request/normalization tests.
- The package builds and tests the `global-container-service` example.

Commit: `Add global GCP ContainerService component`

### Task 5.4: Global Live Gate

Status: automated harness implemented on 2026-07-10; authenticated execution is
pending ADC, a disposable project, image, domain, and Cloud DNS zone.

Actions:

- Deploy a known test image to two regions.
- Provision global IP, load balancer, managed certificate, and DNS.
- Wait for certificate and service health readiness.
- Probe the global URL from controlled locations.
- Make one regional service unhealthy and verify failover.
- Verify direct public `run.app` access is denied.
- Restore health and verify failback.
- Destroy all disposable resources.

M5 Gate:

- The global URL remains available through the tested regional failure.
- State refresh is noop after restoration.
- Destroy follows reverse dependency order.

Harness evidence:

- The compiled `global-container` stack plans and fake-deploys all 14 resources.
- `fail-region` is gated by live provider opt-in, `--live-test`, disposable
  project suffix, stack lock, declared region, and existing physical state.
- `scripts/live-global-gate.sh` automates HTTPS readiness, direct-ingress denial,
  regional deletion, continued global availability, restore, noop, optional
  remote probes/secret scan, and teardown.

Commit: `Verify Ziac global Cloud Run deployments`

---

## Milestone M6: CockroachDB

### Task 6.1: Provider Config And Existing Cluster

Status: completed on 2026-07-10. Authenticated Cockroach Cloud verification is
owned by Task 6.7.

Files:

- Add Cockroach provider root, config, validation, and existing-cluster modules.
- Add tests and public exports.

Tests:

- API key is a secret config input.
- Cluster ID, plan, cloud, regions, and connection endpoints decode.
- Existing cluster refresh detects missing and changed topology.
- Region compatibility diagnostics are deterministic.

Evidence:

- API keys are environment-backed secret references and are absent from
  resource state.
- The pinned Cloud API decoder owns cluster, region, and public/private endpoint
  fields from the current response contract.
- Scripted provider and `refreshGraph` tests cover exact topology, changed
  topology, missing clusters, import, and retained detach-only destroy.

Commit: `Add CockroachDB existing cluster resources`

### Task 6.2: SQL User And Connection Secret

Status: completed on 2026-07-10. Authenticated Secret Manager and Cockroach
Cloud verification is owned by Task 6.7.

Resources:

- `cockroach.SqlUser`
- `cockroach.ConnectionSecret`

Tests:

- Cryptographically secure password source is injectable in tests.
- SQL-user create/reset/delete lifecycle is idempotent.
- Partial secret/user failure converges on retry.
- Connection URI encoding handles reserved characters.
- TLS mode defaults to `verify-full`.
- State retains Secret Manager reference only.

Evidence:

- `ConnectionSecret` creates an explicit secret-first, five-resource graph with
  typed dependencies from cluster endpoint through Secret Manager to SQL user.
- Production passwords use `std.Io.randomSecure`; deterministic sources are
  injectable in tests and all owned password/payload buffers are zeroed.
- Secret Manager `versions:access` resolves only typed numeric version
  references, and `SqlUser` creates or resets idempotently from the stored URI.
- Scripted failure coverage proves a persisted secret plus failed user write
  converges on retry without password plaintext in desired or observed state.

Commit: `Add CockroachDB connection secret bindings`

### Task 6.3: Public Static Egress Networking

Status: completed on 2026-07-10. Authenticated GCP and Cockroach Cloud
verification is owned by Task 6.7.

GCP resources:

- VPC
- regional subnet
- router
- NAT
- static address
- Cloud Run Direct VPC configuration

Cockroach resource:

- authorized network rule

Tests:

- One static egress address per configured policy.
- Cockroach allowlist receives only the reserved addresses.
- Unrestricted production CIDRs fail validation.
- Networking dependencies are automatic.

Evidence:

- `PublicStaticEgress` creates one custom global VPC and five resources per
  region: subnet, router, Premium address, manual Router NAT, and SQL-only `/32`
  Cockroach authorized-network entry.
- Cloud Run Direct VPC accepts typed network/subnetwork outputs, resolves them
  only at provider execution, and normalizes concrete API links back to those
  references on refresh.
- Router NAT uses a fingerprinted read-modify-patch lifecycle that preserves
  unrelated router fields and NATs, retries conflicts, and removes only its own
  nested entry.
- Scripted transport tests cover all Compute and Cockroach resource lifecycles,
  exact allowlist requests, typed output resolution, and component dependency
  shape. The Ziac suite passes 207 tests.
- The production policy rejects non-Premium networking, duplicate or mismatched
  regions, broad subnet CIDRs, invalid NAT port sizing, and any Cockroach
  allowlist broader than `/32`.

Commit: `Add safe CockroachDB public connectivity`

### Task 6.4: Database, Grants, And Migrations

Status: completed on 2026-07-10. Authenticated CockroachDB Cloud and Cloud Run
data-path execution remains part of Task 6.7.

Resources:

- `cockroach.Database`
- `cockroach.Grants`
- `cockroach.Migration`

Tests:

- SQL identifier validation and quoting.
- Database and grant read-before-write behavior.
- Migration table and ordered migration application.
- Retryable `40001` handling.
- Ambiguous `40003` results stop for reconciliation.
- Concurrent migration execution is serialized.

Implementation:

- Introduce a SQL executor provider interface.
- Reuse the local `psql` adapter for contract and development tests.
- Add a native PostgreSQL wire/TLS client before M6 production gate.
- Add bounded connection pooling, validation, lifetime, and jitter.

Commit: `Add CockroachDB SQL resources and migrations`

Evidence:

- Full scripted lifecycles cover protected databases, exact direct grants, and
  immutable checksummed migrations.
- `ApplicationDatabase` composes administrator bootstrap, generated application
  credentials, database, grants, and ordered migrations without plaintext state.
- SQLSTATE `40001`, ambiguous `40003`, and concurrent migration callers are
  tested; transaction SQL uses a singleton `FOR UPDATE` lock.
- The local `psql` adapter uses a secret-free argv and redacted diagnostics.
- The pinned native `pg.zig` pool requires `sslmode=verify-full`, validates and
  rotates eager idle generations, and passes the reproducible CockroachDB
  v26.2.3 TLS container gate for a typed query plus real database, grant,
  migration, refresh, revoke, and drop lifecycles.

### Task 6.5: Cockroach Cluster Provisioning

Status: completed on 2026-07-10. Authenticated Cockroach Cloud creation remains
part of the credential-gated M6 live acceptance run.

Resource:

- `cockroach.Cluster`

Tests:

- Basic, Standard, and Advanced request schemas.
- Plan-specific region and sizing validation.
- Long-running readiness polling.
- Cluster protection defaults true.
- Scale updates and immutable replacement rules.
- Delete requires explicit unprotect and confirmation.

Commit: `Add protected CockroachDB Cloud clusters`

Evidence:

- GCP Basic, Standard, and Advanced builders normalize topology and reject
  invalid names, primary regions, CIDRs, and plan-specific sizing.
- The pinned client emits exact structured create/update JSON, string-encoded
  usage limits, an empty serverless IP allowlist, and remote deletion
  protection.
- Scripted provider lifecycles cover create/read/update/import/delete,
  `CREATING`/`LOCKED` readiness, terminal failure, deadlines, scaling, and
  immutable replacement classification.
- Protection is mirrored into managed inputs, Ziac lifecycle state, and the
  Cockroach API. Tests prove the required unprotect deploy followed by
  `destroy --confirm` propagation through the CLI and executor.

### Task 6.6: Private Service Connect

Status: implemented on 2026-07-10. Authenticated regional data-path execution
remains the separate Task 6.7 gate.

Resources:

- Cockroach private connectivity configuration.
- GCP PSC endpoint, address, DNS, and regional network dependencies.

Tests:

- Plan eligibility validation.
- Region and project matching.
- Endpoint acceptance polling.
- Private DNS connection output.
- No public allowlist is created in PSC mode.

Commit: `Add CockroachDB GCP private connectivity`

Evidence:

- Typed Cockroach cluster-region, private-endpoint-service, and accepted
  connection resources implement Standard and Advanced behavior, exact pinned
  Cloud API requests, list-before-mutate interruption recovery, polling,
  import, retention, and deletion semantics.
- Typed GCP internal addresses and PSC forwarding rules implement regional
  Compute lifecycles, expose connection IDs and statuses, enable global PSC
  access, and deliberately finish before Cockroach acceptance to avoid a
  dependency deadlock.
- VPC-bound private managed zones and output-backed record names preserve typed
  references and canonical trailing-dot normalization through refresh. The
  live providers revalidate resolved project, region, IP, network, service
  attachment, and DNS values before mutation.
- `PrivateServiceConnect` creates a global-routing VPC and one complete private
  regional path per declared Cockroach region, returning `PRIVATE_RANGES_ONLY`
  Direct VPC bindings without constructing a public allowlist.
- `ContainerService.base_graph` and `regional_direct_vpc` compose the protected
  cluster, two regional PSC paths, two Cloud Run services, and the global HTTPS
  load balancer into one validated 34-resource example graph.
- Unit, scripted provider, compile-fail, example, and full repository gates are
  recorded in `docs/private-service-connect.md` and the milestone commit.

### Task 6.7: Live Data Path Gate

Actions:

- Reference a protected disposable CockroachDB cluster.
- Create application SQL user and Secret Manager binding.
- Deploy the global test service with the typed database binding.
- Run a TLS query and migration from Cloud Run.
- Verify regional connectivity and transaction retry behavior.
- Rotate the SQL password and verify a new service revision starts.
- Destroy app resources while retaining the protected cluster.

M6 Gate:

- No secret plaintext exists in state or captured output.
- Global Cloud Run service reads and writes CockroachDB successfully over TLS.
- Public static and PSC modes have separate verified contract suites.

Commit: `Verify Ziac CockroachDB bindings end to end`

---

## Milestone M7: ZigService

### Task 7.1: Deterministic Source Archive

Status: implemented on 2026-07-10.

Files:

- Add `packages/ziac/src/build/source_archive.zig`.
- Add archive fixtures and tests.

Tests:

- Stable path ordering and timestamps.
- Ignore rule handling.
- Symlink policy.
- Source/build digest changes only for relevant inputs.
- Secret and state directories are excluded.

Commit: `Add deterministic Zig build contexts`

Evidence:

- Native Zig tar/gzip output is byte-stable across filesystem order and
  timestamp-only rewrites, with sorted paths, zero timestamps and ownership,
  and normalized executable modes.
- Mandatory state, VCS, cache, environment, key, and secret-directory filters
  cannot be negated. Additive `.ziacignore` rules support bounded root-relative
  globs and reject unsupported negation.
- Both collection and final reads reject symlinks and use no-follow,
  resolve-beneath opens. Generated build files share path, collision, and size
  validation.
- The package suite contains 270 tests at this checkpoint: 269 pass and one
  authenticated credential gate is skipped.

### Task 7.2: Cloud Build Resource

Status: implemented on 2026-07-10.

Resources:

- build context object
- Cloud Build invocation
- Artifact Registry image digest output

Tests:

- Pinned Zig builder and final image request.
- Build operation polling and log links.
- Cache/noop behavior by source digest.
- Failed build diagnostics are bounded and redacted.

Commit: `Add Zig source-to-image Cloud Build pipeline`

Evidence:

- Protected regional GCS buckets and content-addressed source objects enforce
  retention, generation-zero creation, local SHA-256/CRC32C/size preflight,
  strict conflict adoption, and no source bytes in state.
- Regional Cloud Build requests pin the GCS generation and Docker builder,
  derive build/image tags from full digests, and recover interrupted creates by
  validating complete build identity behind a digest-tag query.
- Polling covers `STATUS_UNKNOWN`, `PENDING`, `QUEUED`, `WORKING`, and all five
  terminal failure states. Success emits only the matching Artifact Registry
  digest; bounded redacted diagnostics retain a sanitized console link.
- The package suite contains 286 tests at this checkpoint: 285 pass and one
  authenticated credential gate is skipped. Examples, executable build,
  zigeffect std/PostgreSQL suites, local CockroachDB v26.2.3 verified-TLS SQL,
  diff checks, and 46-file tool hygiene all pass.

### Task 7.3: ZigService Component

Status: implemented on 2026-07-10.

Files:

- Add `packages/ziac/src/gcp/global/zig_service.zig`.
- Add a real sample Zig HTTP backend.
- Add compile-time and graph tests.

Tests:

- App type declares `Env`.
- Bindings validate at comptime.
- Build image output feeds ContainerService automatically.
- Port and health paths follow Cloud Run defaults.
- Source changes update image and regional services.

Acceptance:

- Public API requires no hand-written Dockerfile or raw load balancer resources.

Commit: `Add global ZigService component`

Evidence:

- `ZigService(App, Bindings, Providers)` validates `App.Env`, GCP provider
  availability, binding names/types/secrecy, and supported runtime string
  types at comptime.
- A generated, pinned Zig 0.15.2 musl recipe builds to a distroless nonroot
  runtime. The golden recipe and real sample are verified on linux/amd64 and
  linux/arm64, including startup, liveness, root, and not-found responses.
- Source, recipe, and builder identities feed a content-addressed GCS object and
  Cloud Build. The immutable image output feeds every regional Cloud Run
  service through typed references and remains canonical after refresh.
- Separate build/runtime identities, least-privilege build roles, per-secret
  accessor IAM, retained APIs/repository/bucket, and default health probes are
  dependency complete. Foreign-provider and cross-project secret references
  fail before cloud I/O.
- The package suite contains 299 tests at this checkpoint: 298 pass and one
  authenticated credential gate is skipped. All examples and both container
  architectures pass.

### Task 7.4: Live Source Deployment Gate

Actions:

- Build the sample from a clean checkout.
- Push an immutable image digest.
- Deploy to two regions.
- Verify global HTTPS and CockroachDB query behavior.
- Change source, plan, deploy, and verify the new revision.
- Revert source and verify deterministic digest reuse where supported.

M7 Gate:

- One command takes Zig source and typed bindings to a working global service.

Commit: `Verify Zig source to global Cloud Run deployment`

---

## Milestone M8: Production Operations

### Task 8.1: GCS State Backend

Status: implemented on 2026-07-10.

Files:

- Add `packages/ziac/src/state_backend.zig`.
- Add `packages/ziac/src/gcp/gcs_state.zig`.
- Add fake GCS generation tests.

Tests:

- Initial create uses generation zero precondition.
- Update requires the observed generation.
- Concurrent writer produces a state conflict.
- Lock metadata identifies writer and expiry.
- Secret references remain opaque.
- Local-to-GCS migration preserves lineage.

Commit: `Add GCS remote state locking`

Evidence:

- A backend facade preserves the existing v2 state format and executor
  checkpoint contract across local and remote stores.
- Fake object storage proves generation-zero create, exact-generation update
  and delete, stale writer rejection, and two-writer state conflicts.
- GCS reads metadata then pins media bytes to that generation. Scripted HTTP
  tests assert every create, update, and delete precondition and 412 mapping.
- Lock v2 records owner, command, lineage, acquisition, and expiry. Active
  conflicts, renewal, exact-generation release, and stale takeover pass.
- `ZIAC_STATE_BUCKET` selects GCS through native ADC without silent local
  fallback. `state-migrate` preserves lineage, serial, typed secret references,
  and redacted outputs while retaining the local recovery copy.
- The package suite contains 310 tests at this checkpoint: 309 pass and one
  authenticated credential gate is skipped.

### Task 8.2: Saved Plans And Approval

Status: implemented on 2026-07-10.

Files:

- Add plan serialization and apply validation.
- Extend CLI JSON output.

Tests:

- Saved plans include state serial and graph digest.
- Changed state or desired graph rejects stale plans.
- Protected deletes require explicit approval.
- Plan files contain no secret plaintext.

Commit: `Add immutable Ziac saved plans`

Evidence:

- Saved plan format v1 persists target identity, state and graph
  preconditions, full canonical operations, content digest, and approval
  classification in deterministic JSON.
- Create-exclusive files prevent accidental artifact replacement. The strict
  loader verifies schema/version, resource input hashes, operation integrity,
  approval classification, and top-level digest with a 64 MiB bound.
- `deploy --plan` compiles and hashes the current stack but executes only the
  loaded operations. Changed target, state lineage/serial, desired graph,
  inputs, or operation metadata fails before provider access.
- Delete and replacement operations require executor confirmation. Saved plans
  require `--approve` with the exact content digest; lifecycle protection
  remains an absolute planning block.
- `ziac.command.v2` receipts expose plan path, digest, and approval requirement
  without resource inputs or secret payloads.
- The package suite contains 321 tests at this checkpoint: 320 pass and one
  authenticated credential gate is skipped.

### Task 8.3: CI Workload Identity And Preview Stages

Files:

- Add documented GitHub Actions workflow.
- Add stage naming and cleanup helpers.
- Add WIF auth fixtures.

Tests:

- Preview names are deterministic and provider-valid.
- Production stage cannot use preview destroy defaults.
- External-account ADC works through contract tests.
- No service-account key JSON is required.

Commit: `Add keyless Ziac CI deployments`

### Task 8.4: Rollouts And Recovery

Features:

- Canary region selection.
- Revision traffic progression.
- Readiness and service-health gates.
- Rollback to prior image digest.
- Provider quota and rate-limit diagnostics.
- Recovery documentation and commands.

Tests:

- Failed canary stops other regions.
- Healthy canary progresses deterministically.
- Rollback restores previous digest.
- Crash at every checkpoint resumes safely.

Commit: `Add guarded Ziac global rollouts`

### Task 8.5: Public Documentation And Release Gate

Files:

- Rewrite `packages/ziac/README.md` as a working quickstart.
- Update architecture, provider, state, security, operations, and recovery docs.
- Add a full example under `packages/ziac/examples/`.
- Add `zig build release-gate` for Ziac.

Release gate:

- Formatting and static checks.
- Unit and compile-fail tests.
- Provider contract tests.
- Local integration and interruption tests.
- Examples and executable builds.
- Secret leak scan.
- State migration fixtures.
- Configured live test manifest.

### Task 8.6: Final End-To-End Verification

From a clean checkout:

1. Authenticate through ADC/WIF.
2. Initialize or select GCS state.
3. Build the sample Zig service.
4. Provision or reference CockroachDB.
5. Deploy the service globally.
6. Verify HTTPS, regional routing, failover, TLS database access, and migration.
7. Change and redeploy the application.
8. Interrupt and resume a deployment.
9. Import a known resource.
10. Destroy app infrastructure while retaining protected data.
11. Verify final state and secret leak scan.

M8 Gate And Goal Completion:

- All ten completion criteria from the design are satisfied.
- All automated release gates pass.
- Live verification evidence records resource IDs and request outcomes but no
  credentials or secret values.
- Documentation reproduces the workflow from a clean environment.

Commit: `Complete Ziac end-to-end delivery`

---

## Milestone Dependency Order

```text
M0 architecture
  -> M1 engine contracts
    -> M2 comptime contracts
      -> M3 transport/auth
        -> M4 live GCP primitives
          -> M5 global ContainerService
            -> M6 CockroachDB
              -> M7 ZigService
                -> M8 production operations and release
```

Provider-specific request encoding can be prepared in parallel after the M1
contracts stabilize, but no live provider milestone may bypass its dependency
gates.
