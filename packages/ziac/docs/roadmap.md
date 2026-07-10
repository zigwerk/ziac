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
- GCP config, Artifact Registry, and Cloud Run resource builders: implemented as
  plan-only foundations.
- Engine V2 canonical values, owned desired/state records, provider lifecycle,
  refresh planning, and dependency-ordered bounded execution: implemented and
  tested.
- Engine V2 checkpoint/resume, atomic state persistence, and writer locking: in
  progress.
- Live GCP calls, global routing, CockroachDB, comptime app bindings, remote
  state, and source builds: not yet implemented.

## M0: Integration And Architecture

- Integrate the plan-only GCP foundation.
- Freeze alpha and beta product scope.
- Record the Engine V2, comptime, GCP, CockroachDB, build, state, and operations
  architecture.

Gate: authoritative design and executable implementation plan are committed,
and the integrated baseline passes all Ziac tests and builds.

## M1: Engine V2

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

## M2: Comptime Contracts

- Typed public and secret outputs.
- Automatic dependency derivation from output references.
- App `Env` and binding validation.
- Provider-set validation.
- Stable compile-fail diagnostics.

Gate: valid fixtures compile and invalid binding/provider/output fixtures fail
with their expected Ziac diagnostic codes.

## M3: Transport And Authentication

- Owned HTTP response headers, structured errors, timeout, cancellation, and
  `Retry-After` support.
- Native Google Application Default Credentials and token caching.
- Google REST and long-running operation client.
- Version-pinned CockroachDB Cloud API client.
- `ziac auth doctor`.

Gate: Google and Cockroach scripted transport suites pass without leaking
credentials.

## M4: Live GCP Primitives

- Project API enablement.
- IAM service accounts and bindings.
- Artifact Registry.
- Secret Manager.
- Cloud Run v2.
- Live provider selection and guarded disposable-project tests.

Gate: an existing image completes create/read/update/noop/destroy in one Cloud
Run region with real physical state and outputs.

## M5: Global ContainerService

- Global address, serverless NEGs, backend service, URL map, managed TLS,
  forwarding rules, and optional Cloud DNS.
- `ziac.gcp.global.ContainerService`.
- Premium-tier validation, restricted Cloud Run ingress, readiness, and regional
  failover policy.

Gate: a live two-region HTTPS service remains available during a tested regional
failure and destroys in reverse dependency order.

## M6: CockroachDB

- Existing-cluster reference first.
- SQL users and GCP Secret Manager connection bindings.
- Direct VPC egress, static NAT addresses, and narrow public allowlists.
- Database, grants, migrations, transaction retry handling, and native pooled
  SQL/TLS runtime.
- Protected cluster provisioning and Private Service Connect.

Gate: the global Cloud Run sample reads and writes CockroachDB over TLS without
secret plaintext in state or artifacts.

## M7: ZigService

- Deterministic source archives and build digests.
- Cloud Build to Artifact Registry immutable image pipeline.
- `ziac.gcp.global.ZigService`.
- Typed app environment wiring into the global service.

Gate: one command takes a clean Zig source checkout to an updated, globally
routed service with a working CockroachDB binding.

## M8: Production Operations

- GCS remote state with generation locking.
- Saved plan preconditions and approval.
- Workload Identity Federation and preview stages.
- Canary regional rollouts, rollback, recovery, and protection.
- Release gate, complete docs, and clean-checkout end-to-end verification.

Gate: all automated suites and the configured live end-to-end workflow pass,
including regional failover, database TLS, update, interruption recovery, import,
protected data retention, and secret leak scanning.
