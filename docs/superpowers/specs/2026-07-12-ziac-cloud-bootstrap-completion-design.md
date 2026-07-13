# Ziac Cloud Bootstrap Completion Design

## Status

Validated implementation design for the first self-hosted Ziac Cloud deployment.

## Outcome

A clean checkout can install Ziac, scaffold a `ziac-cloud` monorepo, compile every
stack, produce immutable saved plans, and use the local dashboard to approve and
execute those plans. With Google ADC, a GCP project, DNS, and Cockroach
credentials, the same project can bootstrap the hosted Estate control plane and
billing ingestion service.

The credential-free release gate proves graph completeness and command wiring.
The authenticated qualification gate proves deployment. CI must never describe
configuration estimates as actual billing data.

## Product Boundary

Ziac Cloud remains a local-first developer tool:

- project compilation, plan review, canvas rendering, and agent interaction run
  locally;
- the hosted control plane owns identity, entitlement, encrypted Google
  connections, billing snapshots, reports, and audit records;
- no hosted service receives source code, local state, or broad Google
  credentials;
- dashboard mutations are fixed Ziac argv operations, never browser-provided
  shell text.

## Self-hosted Project

`ziac init --preset ziac-cloud` creates a workspace containing independent Ziac
projects. The initial projects are:

1. `platform/bootstrap`: required APIs, remote-state bucket, KMS key ring and
   crypto key, retained Artifact Registry repository, and deployment identities.
   It starts with local state and emits the remote backend coordinates.
2. `platform/data`: the Cockroach database, SQL user, grants, generated
   connection secret, and ordered control-plane and billing migrations.
3. `platform/control-plane`: the global Estate API, Secret Manager bindings,
   least-privilege runtime IAM, and global HTTPS routing.
4. `platform/billing`: the authenticated billing ingestion service and its
   least-privilege BigQuery and Cloud Billing access, plus an hourly Cloud
   Scheduler trigger using a dedicated OIDC identity.

Each project has its own state and deployment cadence. Running `ziac dashboard`
at the repository root merges them into one graph while preserving project
ownership and filtering.

The bootstrap stack cannot use the GCS backend it creates. Its first deployment
uses local state, then `ziac state-migrate` moves that state into the emitted
bucket. All other projects require the remote backend.

## Dashboard Operation Protocol

The native host exposes these bindings:

- `ziac_operation_plan(request)`
- `ziac_operation_apply(request)`
- `ziac_operation_cancel(request)`
- `ziac_operation_status(request)`

Requests contain project id, stack, stage, provider, and operation id. The host
resolves the project from workspace discovery, validates every identifier, and
constructs fixed argv. A plan is always saved beneath `.ziac/dashboard/plans`.
Apply requires the exact saved-plan digest returned by plan. Destructive plans
also require explicit confirmation. The operation projection contains bounded,
redacted stdout/stderr, exit status, phase, timestamps, and plan metadata.

The browser cannot supply an executable, working directory, plan path, or raw
command. Cancellation targets only a child process started by the host.

## Incremental Workspace Protocol

Each project revision is the SHA-256 digest of its manifest and declared program
inputs. The host maintains per-project compiled artifacts and the last known good
workspace projection. On refresh it:

1. rediscovers manifests only when the workspace manifest set changes;
2. computes project revisions;
3. recompiles only changed projects;
4. atomically publishes a monotonically increasing workspace revision;
5. preserves the previous artifact and reports a compile diagnostic if a changed
   project fails.

The browser requests a revision after the last revision it observed. Unchanged
responses do not resend the graph. This is bounded revision polling at the WebUI
transport boundary, not full-workspace polling or recompilation; the compiler is
strictly affected-project incremental.

## Authoritative Cost Model

Cost data has three non-interchangeable origins:

- `configuration_estimate`: Cloud Billing Catalog prices applied to explicit
  usage assumptions;
- `actual_billed`: normalized BigQuery detailed billing export rows, including
  credits;
- `projected_month_end`: a projection derived only from partial actual rows.

The Cloud Billing client paginates SKU data and preserves currency, effective
time, usage units, and every tier. The BigQuery client submits parameterized
queries, polls incomplete jobs, and parses decimal amounts without binary-float
rounding.

Attribution returns:

- costs matched by exact Google global resource name;
- costs matched by explicit Ziac resource labels;
- unattributed cost as a first-class total;
- coverage in basis points;
- query window, source table, currency, and observed time.

The dashboard may show actual spend only when `is_billing_export` is true. It
must label all other values as estimates.

## Hosted Services

The existing `ziac-estate-control-plane` is the control-plane image entrypoint.
The new billing worker uses the same typed HTTP, ADC, BigQuery, Cloud Billing,
and Cockroach boundaries. A production scheduler invokes it with OIDC; retries
are idempotent by account, project, and billing window.

The bootstrap qualification builds both Linux/amd64 images from the installed
Ziac distribution in Cloud Build, resolves immutable Artifact Registry digests,
and feeds only those digests to the service projects. The native Linux recipe
pins Zig 0.16 and carries the OpenSSL runtime needed for verified Cockroach TLS.

The control-plane database adds billing source, snapshot, resource attribution,
and ingestion run tables. Raw credentials and OAuth tokens remain envelope
encrypted with Cloud KMS. Billing rows contain provider identifiers and monetary
facts, never credentials.

## Verification Gates

### Credential-free

`zig build self-host-gate` must:

- compile bootstrap, control-plane, and billing graphs;
- verify every resource type has a live GCP provider handler;
- run dashboard operation protocol tests with a fixed fake executable;
- prove only one changed project recompiles;
- parse paginated Catalog and BigQuery fixtures;
- prove attributed plus unattributed equals billed total;
- scaffold and compile a fresh external `ziac-cloud` repository.

### Authenticated qualification

`packages/ziac/scripts/qualify-ziac-cloud.sh` requires explicit environment
variables and then:

1. deploys bootstrap from local state;
2. migrates bootstrap state to GCS;
3. builds and publishes immutable hosted-service images when refs are absent;
4. deploys Cockroach data, control-plane, and billing stacks from remote state;
5. probes control-plane health and the configured export;
6. forces the managed Scheduler job and requires a successful billing-worker
   attempt;
7. verifies an actual snapshot with an explicit unattributed remainder;
8. records cleanup commands and resource identifiers.

Absent credentials produce a documented skip, never a pass.

## Non-goals For This Milestone

- hiding unattributed billing under estimates;
- accepting arbitrary shell commands from the dashboard;
- moving the primary dashboard into the hosted control plane;
- automatically creating a customer's Cloud Billing export, which Google owns
  at the billing-account boundary and requires explicit billing administration;
- claiming production readiness without running the authenticated qualification
  gate in the intended organization.
