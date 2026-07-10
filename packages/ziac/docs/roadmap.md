# Ziac Roadmap

Ziac is being delivered against the authoritative end-to-end design and
implementation plan:

- `docs/superpowers/specs/2026-07-10-ziac-e2e-delivery-design.md`
- `docs/superpowers/plans/2026-07-10-ziac-e2e-delivery.md`

The roadmap is acceptance-gated. A milestone is complete only when its stated
automated and live tests pass.

## Current Readiness

- Package scaffold, graph, local state, CLI, fake provider, and executable:
  implemented and tested.
- GCP config, Artifact Registry, Cloud Run, networking, global load balancing,
  public DNS, private DNS, and PSC resource builders: implemented with native
  provider lifecycles and scripted conformance coverage.
- Engine V2 canonical values, owned desired/state records, provider lifecycle,
  refresh planning, and dependency-ordered bounded execution: implemented and
  tested.
- Engine V2 checkpoint/resume, atomic state persistence, writer locking,
  refresh/import/unlock, and JSON command receipts: implemented and tested.
- Lineage, serial, canonical desired-graph, and operation-integrity plan
  preconditions: implemented and tested before provider access.
- Comptime app bindings, scoped outputs, and provider-set validation: implemented
  and compile-fail tested.
- Production HTTP transport contract: implemented and tested with owned headers,
  typed failures, cancellation, body limits, `Retry-After`, and credential
  redaction.
- Native Google ADC, authenticated Google REST/LRO clients, and the
  version-pinned CockroachDB Cloud client: implemented and scripted-transport
  tested without credential leakage.
- Live GCP provider calls, raw global-routing resources, and the high-level
  global component are implemented behind explicit safety gates. The
  CockroachDB existing-cluster, protected cluster provisioning, SQL user,
  database, grants, migrations, native verified-TLS, and multi-region Private
  Service Connect slices are implemented. Authenticated cloud acceptance,
  remote state, and source builds remain pending.

## M0: Integration And Architecture

- Integrate the plan-only GCP foundation.
- Freeze alpha and beta product scope.
- Record the Engine V2, comptime, GCP, CockroachDB, build, state, and operations
  architecture.

Gate: authoritative design and executable implementation plan are committed,
and the integrated baseline passes all Ziac tests and builds.

## M1: Engine V2 (Complete)

- Canonical resource values and input hashes.
- Retained desired resource inputs.
- Versioned state with physical IDs, observed values, outputs, and operation
  handles.
- Provider read/diff/create/update/delete/import lifecycle.
- Refresh-aware planning and removed-resource deletion.
- Topological zigeffect execution, reverse destroy, checkpoints, and resume.
- Atomic local state and writer locking.

Gate: a fake remote system passes create/update/replace/delete/import, drift, and
interrupted-resume integration tests.

## M2: Comptime Contracts (Complete)

- Typed public and secret outputs: implemented and tested.
- Automatic dependency derivation from output references: implemented and
  tested.
- Canonical provider-output inputs and state-backed provider resolution:
  implemented and exercised by Cloud DNS global-address wiring.
- App `Env` and binding validation: implemented and compile-fail tested.
- Provider-set validation: implemented and compile-fail tested.
- Stable compile-fail diagnostics: all required fixtures enforced by
  `zig build test`.

Gate: valid fixtures compile and invalid binding/provider/output fixtures fail
with their expected Ziac diagnostic codes.

## M3: Transport And Authentication (Complete)

- Owned HTTP response headers, structured errors, timeout, cancellation, and
  `Retry-After` support: complete.
- Native Google Application Default Credentials and token caching: complete.
- Google REST and long-running operation client: complete.
- Version-pinned CockroachDB Cloud API client: complete.
- `ziac auth doctor`: complete.

Gate: Google and Cockroach scripted transport suites pass without leaking
credentials.

## M4: Live GCP Primitives

- Project API enablement: scripted lifecycle complete; live gate pending.
- IAM service accounts and bindings: scripted lifecycle complete; live gate
  pending.
- Artifact Registry: scripted lifecycle complete; live gate pending.
- Secret Manager: scripted metadata, version, and IAM lifecycle complete; live
  gate pending.
- Cloud Run v2: scripted full-runtime lifecycle complete; live gate pending.
- Live provider selection and disposable-project guard: complete; authenticated
  smoke pending configured ADC and project.

Gate: an existing image completes create/read/update/noop/destroy in one Cloud
Run region with real physical state and outputs.

## M5: Global ContainerService

- Global address, serverless NEGs, backend service, URL map, HTTPS proxy, and
  forwarding rule scripted lifecycles: complete.
- Managed TLS, explicit certificate readiness, optional HTTP-to-HTTPS redirect,
  and existing-zone Cloud DNS record sets: scripted lifecycles complete.
- `ziac.gcp.global.ContainerService`: deterministic graph and example complete.
- Premium-tier, unique-region, restricted Cloud Run ingress, and production
  warm-instance/probe policy: implemented and tested.
- Serverless NEG outlier detection for cross-region error reduction:
  implemented, normalized, and enabled by the component.
- Authenticated certificate readiness and regional failover/failback: live gate
  harness implemented; configured live execution pending.

Gate: a live two-region HTTPS service remains available during a tested regional
failure and destroys in reverse dependency order.

## M6: CockroachDB

- Secret-reference provider config: complete.
- Existing-cluster topology, endpoint outputs, retained ownership, and scripted
  refresh/import lifecycle: complete.
- Idempotent SQL users, generated GCP Secret Manager connection bindings, and
  persisted-secret retry convergence: complete.
- Direct VPC egress, static NAT addresses, and narrow public allowlists:
  complete with scripted GCP/Cockroach lifecycles; authenticated live execution
  pending.
- Database, exact grants, immutable migrations, transaction retry handling,
  concurrent serialization, high-level application database composition, and
  native pooled SQL/TLS runtime: complete, including a disposable secure local
  CockroachDB gate.
- Protected Basic, Standard, and Advanced cluster provisioning: scripted
  lifecycle complete; authenticated creation pending configured credentials.
- GCP Private Service Connect address and endpoint lifecycles, Cockroach
  endpoint-service enablement and connection acceptance, VPC-bound private DNS,
  per-region Cloud Run Direct VPC bindings, and the high-level private graph:
  complete with scripted provider and composition tests; authenticated regional
  data-path execution remains pending.

Gate: the global Cloud Run sample reads and writes CockroachDB over TLS without
secret plaintext in state or artifacts.

## M7: ZigService

- Deterministic source archives and build digests: complete with native
  sorted tar/gzip output, normalized metadata, mandatory secret/state/cache
  exclusions, additive `.ziacignore` globs, no-follow reads, symlink rejection,
  generated-file collision checks, and bounded source/archive sizes.
- Cloud Build to Artifact Registry immutable image pipeline: complete.
- `ziac.gcp.global.ZigService`: complete.
- Typed app environment wiring into the global service: complete, including
  provider/project validation for Secret Manager references.
- Generated Zig 0.15.2 musl recipe: verified for amd64 and arm64 in pinned
  distroless nonroot containers with startup and liveness probes.

Remaining gate: authenticated source deployment must take a clean Zig source
checkout to an updated, globally routed service with a working CockroachDB
binding. The local source-to-container and complete graph gates pass; external
GCP/Cockroach credentials, project, domain, and DNS zone are not configured in
this checkout.

## M8: Production Operations

- GCS remote state with generation locking: complete, including expiring
  writer leases, checkpoint renewal, fail-closed ADC selection, and verified
  local migration.
- Saved plan preconditions and approval.
- Workload Identity Federation and preview stages.
- Canary regional rollouts, rollback, recovery, and protection.
- Release gate, complete docs, and clean-checkout end-to-end verification.

Gate: all automated suites and the configured live end-to-end workflow pass,
including regional failover, database TLS, update, interruption recovery, import,
protected data retention, and secret leak scanning.
