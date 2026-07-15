# Ziac Roadmap

This is Ziac's only forward roadmap. Work shipped through M83 is recorded in
[`shipped.md`](shipped.md); dated designs and implementation plans are retained
as evidence rather than competing status sources.

- **Roadmap date:** 2026-07-15
- **Current baseline:** 253 managed GCP resource types, a versioned isolated
  provider RPC boundary, and a complete local Testing v2 receipt with 974
  executed tests
- **Immediate objective:** turn broad credential-free implementation into a
  qualified, self-hosted and externally usable private beta

## Status Rules

- **Planned:** accepted work that has not met its exit gate.
- **In progress:** implementation is active and evidence is incomplete.
- **Shipped:** merged implementation passes its deterministic gate.
- **Qualified:** the declared authenticated environment produced a complete,
  redacted and reproducible acceptance receipt.
- **Blocked externally:** implementation can make no further progress without
  credentials, billing, DNS, a disposable project or another declared operator
  input.

A local emulator, scripted HTTP adapter or skipped credential test cannot
qualify a cloud claim.

## Product Direction

The next phase optimizes for trust and adoption, not raw provider count. Ziac
already covers the common platform surface. New resource families enter the
roadmap only when they unblock a real architecture or arrive through the
governed contract automation in M89.

The target product remains local first:

- agents edit and compile infrastructure beside application source;
- humans monitor plans, evidence, topology and cost in the local dashboard;
- the hosted Ziac Cloud plane supplies identity, entitlements, scheduled
  discovery, billing intelligence, collaboration and reports; and
- customer credentials and live mutation authority remain narrowly scoped,
  explicit and auditable.

Provider extensibility follows the same rule. Registry discovery is data-only;
credentialed GCP and Cockroach lifecycle code runs behind the bounded
`ziac.provider.rpc.v1` process boundary. Process pools, artifact signatures and
OS sandbox profiles remain M87 reliability work.

## Delivery Order

| Milestone | Priority | Depends on | Outcome |
| --- | --- | --- | --- |
| M84 | P0 | Current baseline | Authenticated GCP and Cockroach qualification gauntlet |
| M85 | P0 | M84 bootstrap lanes | Ziac Cloud deployed and operated using Ziac |
| M86 | P0 | M84-M85 | Ten-minute clean-repository developer journey |
| M87 | P1 | M84 evidence | Recovery, drift and provider reliability campaign |
| M88 | P1 | M85-M87 | Paid Estate Pro and authoritative cost intelligence |
| M89 | P2 | M87 contracts | Automated Google contract and provider evolution |
| M90 | Release | M84-M89 | Evidence-backed private beta |

M84, M85 and M86 may proceed in parallel where their authority boundaries do
not overlap. M90 cannot pass with an incomplete predecessor.

## M84: Authenticated Qualification Gauntlet

**Status:** In progress. Fail-closed runners and the M84C Hermes Desktop Compute
compatibility stack are shipped locally; operator authentication, a qualification
hostname, and disposable environments are not currently available to automation.

### Objective

Produce reproducible real-cloud evidence for the provider and application
claims already implemented. This milestone validates shipped code; it does not
quietly add unrelated provider breadth.

### Qualification Ladder

- **M84A, provider canary:** deploy one small Ziac-owned Zig service with Secret
  Manager, Storage and one event resource. This is the fast authentication,
  service enablement, IAM, quota and provider-lifecycle diagnostic.
- **M84B, golden global E2E:** create a separate repository, run `ziac init`,
  check, plan and deploy a multi-region Cloud Run, global HTTPS, Cockroach,
  storage/event fixture, then prove updates, traffic, interruption, resume,
  drift, import, failure, dashboard evidence and cleanup.
- **M84C, third-party compatibility:** deploy applications Ziac does not own
  after the provider canary is reliable. Hermes Agent on Compute Engine is the
  first lane; GKE or more demanding compatibility applications follow only when
  they answer a distinct workload question.

### M84C: Hermes On Compute

**Deterministic status:** Shipped locally. `gcp.HermesCompute`, its external
stack example, reviewed startup script, reserved-address and TLS-edge topology
tests, fail-closed qualification runner and operator guide pass the
credential-free gate.

**Authenticated status:** Pending. Qualification requires a billed project
ending in `-ziac-disposable`, an operator with IAP and OS Login authority, a
non-production Hermes environment secret, a test hostname in Cloud DNS, and a
Nous dashboard OAuth client registered for that hostname.

The default is one `e2-medium` Shielded VM, a 30 GiB retained balanced disk, a
reserved regional address, a pinned Caddy TLS edge, a dedicated service account,
one secret-scoped accessor grant, and no direct public Hermes port. Hermes
Desktop connects to the typed HTTPS output and authenticates with Nous OAuth.
The live receipt must prove TLS, OAuth advertisement, rejected unauthenticated
WebSocket upgrade, IAP recovery, localhost gateway/backend listeners, restart
persistence, no-op plan and empty cleanup inventory. See
[`hermes-compute.md`](hermes-compute.md).

### Deliverables

- Create a dedicated GCP qualification folder or organization boundary with
  billed projects whose IDs end in `-ziac-disposable`.
- Define least-privilege qualification identities, short-lived ADC/WIF access,
  budgets, quotas, labels, TTLs and emergency cleanup.
- Put the Google Cloud SDK and Ziac qualification toolchain on the declared
  runner `PATH`; record versions without recording tokens.
- Run create, read, update, import, no-op, drift, replacement, interruption,
  resume and delete lanes for every hardened provider family.
- Exercise Cloud Storage data, Pub/Sub delivery and retry, Tasks dispatch,
  Eventarc delivery, Cloud Run jobs, worker pools, build and deploy promotion,
  database migrations and Vertex governed actions.
- Deploy a real multi-region Zig service through global HTTPS, prove certificate
  readiness, regional failover, failback, rollback and reverse-order cleanup.
- Provision or bind a disposable Cockroach cluster, prove verified-TLS SQL,
  Secret Manager rotation, PSC or declared public egress, regional locality,
  retained data and explicit cleanup.
- Query Cloud Asset Inventory, Logging, Monitoring, IAM, org policy, quotas and
  billing from the same graph and reconcile the results with Ziac's preflight.
- Publish redacted Testing v2 and cloud qualification receipts with project,
  region, resource, digest, operation and cleanup identities.
- Run the Hermes Compute compatibility lane after the provider canary and retain
  its TLS, OAuth, desktop-protocol, IAP recovery, restart, no-op and cleanup
  receipt separately from core E2E evidence.

### Evidence

- one immutable manifest naming every qualification lane and authority;
- one receipt per service family with no silent skips;
- a global application receipt covering source, image, deploy, traffic,
  database, failure and cleanup;
- zero leaked credentials or plaintext secrets; and
- a cleanup report proving no unapproved billable resource remains.

### Exit Gate

M84 is qualified only when all required lanes pass in freshly created
disposable projects, every discovered test executes, all destructive operations
are explicitly confirmed, and the cleanup inventory is empty except for
declared retained fixtures.

## M85: Self-Host Ziac Cloud With Ziac

**Status:** Planned. The four-project typed workspace and credential-free
self-host gate are shipped.

### Objective

Bootstrap, deploy and operate Ziac's own hosted product entirely from Ziac
projects. This is the canonical proof that the product can manage a serious
platform without a second IaC system hiding underneath it.

### Deliverables

- Split first-run bootstrap authority from steady-state Ziac-managed authority.
- Apply APIs, Artifact Registry, KMS, retained GCS state and deployer IAM from a
  guarded local bootstrap state, then migrate and verify remote state.
- Deploy Cockroach schema, account/session/entitlement models, grants, secrets
  and ordered control-plane and billing migrations.
- Finish KMS request and response CRC32C integrity verification.
- Make first-account creation, credential persistence and OAuth challenge
  consumption atomic and replay-safe.
- Add challenge cleanup, rate limiting, recoverable failures and bounded audit
  retention.
- Deploy the multi-region control plane and private billing worker from
  immutable images produced by Ziac.
- Connect global load balancing, DNS, certificates, service identity, Cloud
  Scheduler OIDC, Logging, Monitoring, alerts and SLOs.
- Add production project-connection creation and preflight.
- Exchange vaulted Google refresh credentials for narrowly scoped access tokens
  without exposing credentials to the local browser or causal artifacts.
- Prove upgrade, rollback, state recovery, key rotation and bootstrap disaster
  recovery from documented operator commands.

### Evidence

- bootstrap, state-migration, data, control-plane and billing plan receipts;
- health, OAuth, entitlement, scheduler and billing worker probes;
- a topology artifact showing only Ziac-managed and explicitly referenced
  resources;
- rollback and disaster-recovery receipts; and
- a self-host bill-of-materials with image and contract digests.

### Exit Gate

A clean operator environment uses the installed Ziac CLI to create the hosted
platform, migrate state, deploy all services, pass health and scheduled billing
work, perform one safe upgrade and rollback, and recover from a simulated lost
local bootstrap directory.

## M86: Golden External Developer Journey

**Status:** In progress. Installed-prefix and generated-project gates are
shipped. M86A-M86C implement the local component and template ecosystem; the
published global journey and hosted M86D-M86E surfaces are not yet qualified.

### M86A-M86E: Reusable Infrastructure Ecosystem

| Tranche | Status | Outcome |
| --- | --- | --- |
| M86A | Implemented at the local gate | Canonical package manifests, component descriptors and graph/visual provenance |
| M86B | Implemented at the local gate | Independent `ziac-gcpx` package with Asset Bucket and Hermes Desktop components |
| M86C | Implemented at the local gate | Three source templates, verified local registry, CLI discovery and installed-prefix scaffold qualification |
| M86D | Planned | Signed hosted community registry, maintainer identity, revocation, attestations and structured dependency updates |
| M86E | Planned | Local dashboard marketplace, expansion previews, cost and permission summaries, evidence badges and update/ejection UX |

Provider remains a privileged term for cloud-authoritative CRUD code. Resources
are one-to-one GCP declarations, components are unprivileged graph compilers,
and templates become user-owned source. Community authors may publish
components and templates; provider additions still require trusted code review
and lifecycle conformance.

M86A-M86C exit when an installed CLI can verify the bundled registry, scaffold
all official templates into clean repositories, compile their programs and
preserve component provenance without a Ziac source-checkout dependency. The
detailed contract and hosted continuation are in
[`ecosystem.md`](ecosystem.md).

### Objective

Take a developer from an empty Git repository to a globally deployed Zig API
with a useful local canvas in under ten minutes, without any path back to the
Ziac source checkout.

### Deliverables

- Publish versioned, checksummed and signed CLI artifacts for supported host
  platforms with deterministic installation and uninstall instructions.
- Run interactive `ziac init` inside an existing monorepo directory and support
  multiple independently deployable Ziac projects beneath one Git root.
- Install project-local Codex, Claude Code and Gemini skills, MCP configuration
  and official GCP research capability without embedding credentials.
- Make `ziac doctor` explain Zig, Google, Cockroach, billing, DNS, permissions,
  quotas, entitlement and dashboard readiness with repair commands.
- Make `ziac dev` start the local service, dashboard, affected-project compiler,
  causal log stream and stable proxy with one command.
- Show one merged canvas by default and project, dependency and connected slices
  from the local filter menu.
- Wire real preview, approval, deploy, watch, cancellation, logs, rollback and
  recovery through the local dashboard and CLI.
- Ship one production-grade scaffold for a globally routed Zig API with
  CockroachDB, secrets, observability, CI and environment separation.
- Exercise an application change, an infrastructure change, a failed build, a
  failed readiness probe and a regional failure from the generated project.

### Experience Budgets

- first valid local plan within two minutes after prerequisites are present;
- first local hot reload within one second for a small service;
- no-op plan without provider mutation;
- unchanged-image watch deploy uploads no existing blob;
- every failure returns a stable diagnostic, causal evidence and next action;
  and
- no command requires editing generated registry code.

### Exit Gate

Three clean external repositories, including one multi-project monorepo, install
the published CLI and independently complete init, local development, plan,
global deployment, dashboard observation, update, rollback and cleanup. Median
time to the first healthy global endpoint is under ten minutes after cloud
prerequisites are ready.

## M87: Provider And State Reliability Campaign

**Status:** Planned.

### Objective

Turn broad provider coverage into boring, recoverable operational behaviour
under failures, concurrency and Google eventual consistency.

### Deliverables

- Build a capability-derived conformance matrix so every managed resource runs
  the lifecycle lanes it claims to support.
- Test credential expiry, 401/403 refresh, quota exhaustion, rate limiting,
  transient 5xx, malformed responses, LRO loss, cancellation and deadline
  expiry.
- Prove update-mask ownership, etag conflicts, immutable replacement,
  create-before-destroy and retained cleanup for each hardened family.
- Exercise concurrent writers, lock expiry, lease renewal, interrupted state
  writes, checkpoint replay and remote-state migration.
- Add bounded readiness stabilization for eventually consistent IAM, DNS,
  certificates, Cloud Run revisions, service agents and Cloud Asset Inventory.
- Prove import, refresh, external drift, missing resources, partial reads and
  zero-change adoption.
- Add versioned state migrations and provider contract upgrade fixtures with
  backward compatibility and rollback.
- Add signed provider artifact locks, revocation, process pools, cooperative
  cancel frames and OS-level credential/network sandbox profiles on top of the
  shipped `ziac.provider.rpc.v1` process boundary.
- Define latency, memory, request-count and retry budgets for plan, refresh,
  apply, watch and dashboard patch propagation.
- Run multi-seed deterministic fault campaigns and scheduled real-cloud canaries.

### Exit Gate

Every catalog capability is backed by its declared conformance lane; the full
fault matrix produces no corrupt state, leaked lease, unbounded retry or
unexplained plan; and scheduled cloud canaries remain green for 30 consecutive
days.

## M88: Estate Pro And Cost Intelligence

**Status:** Planned. Read-only discovery, ownership and cost kernels are
shipped; the paid service is not.

### Objective

Deliver the paid local-first product: connect a Google account, understand an
existing estate and its cost, compare it with Ziac-managed intent, and adopt
resources deliberately.

### Deliverables

- Complete hosted Google OAuth callback, account creation, GCP connection
  preflight, revocation and credential rotation.
- Add subscription checkout, signed and replay-safe billing webhooks,
  entitlement renewal/cancellation and operator grants.
- Issue short-lived signed local feature leases that can be verified offline
  without storing customer cloud credentials in the browser.
- Schedule Cloud Asset Inventory snapshots and feeds with immutable history and
  change causality.
- Ingest detailed BigQuery billing exports, Catalog/Pricing data, credits,
  contract pricing where authorized and resource attribution confidence.
- Display actual billed cost, projected month end and configuration estimate as
  visibly distinct values.
- Explain what changed, why cost changed, attribution gaps and actionable waste
  findings with evidence.
- Merge observed, referenced and managed infrastructure in one local canvas,
  preserving ownership and mutation isolation.
- Generate reviewable Ziac code from observed assets and permit adoption only
  after a zero-change import plan.
- Add account, team, project, report, retention, export and deletion controls.
- Build a separate least-privilege internal admin surface with append-only audit
  evidence; never put admin authority in the customer dashboard.

### Exit Gate

A paid test customer signs in, connects and later revokes a disposable GCP
project, scans its estate, sees authoritative and estimated cost with attribution
coverage, receives a change report, generates Ziac code, adopts one supported
resource with a zero-change plan and proves that observed-only resources cannot
be mutated.

## M89: Automated Google Contract And Provider Evolution

**Status:** Planned.

### Objective

Keep 253-resource coverage current without turning generated schemas into an
unsafe provider or requiring hand-maintained drift across every Google API.

### Deliverables

- Fetch and pin Google protobuf, Discovery and Cloud Asset contracts with
  canonical digests and reproducible closure manifests.
- Generate semantic diffs for fields, methods, resource names, scopes,
  immutability, etags, update masks, LROs, IAM, API versions and deprecations.
- Classify changes as additive, behaviour-changing, state-migrating, breaking or
  preview-only and require explicit review for every non-additive change.
- Generate low-level declarations, serializers, import parsers, capability
  metadata, documentation stubs and conformance cases from one contract model.
- Keep handwritten lifecycle adapters and high-level components separate from
  regenerated code with stable ownership boundaries.
- Make preview resources opt-in, versioned and accompanied by explicit state
  and migration policy.
- Produce a provider-upgrade report explaining new capabilities, permission and
  API changes, state effects and required operator action.
- Add demand telemetry that records unsupported resource kinds without customer
  identifiers or configuration payloads.

### Exit Gate

Two consecutive upstream Google contract revisions regenerate deterministically,
produce reviewed semantic reports, preserve handwritten provider behaviour and
pass catalog parity, compile, lifecycle, migration and documentation gates with
no unexplained state change.

## M90: Private Beta Release

**Status:** Planned.

### Objective

Release Ziac to design partners with evidence-backed claims, bounded support and
a reversible upgrade path.

### Deliverables

- Freeze the supported host, Zig, GCP, Cockroach and browser compatibility
  matrix.
- Publish signed binaries, provenance, SBOMs, checksums, licenses, release notes
  and upgrade/rollback instructions.
- Document supported resources and capabilities directly from the catalog.
- Publish honest service SLOs, status communication, data retention, deletion,
  incident response and security disclosure policies.
- Run onboarding with at least three external teams and capture structured time,
  failure and support evidence.
- Prove hosted control-plane backup, restore, key rotation, dependency outage and
  regional failover.
- Establish release promotion, canary, rollback and support ownership.

### Beta Definition Of Done

- M84-M89 exit gates pass without hidden skips.
- Three external repositories deploy and operate real workloads for 30 days.
- Ziac Cloud is deployed from Ziac code and restored from documented backups.
- No known critical state-corruption, credential-leak or authority-escalation
  defect remains open.
- Cost surfaces never conflate actual, projected and estimated values.
- Every supported mutation is tied to a saved plan, capability, approval and
  causal receipt.
- Every public claim maps to a reproducible evidence artifact.

## Explicit Non-Goals Before Beta

- competing with Terraform on every historical Google resource;
- another browser-only cloud console;
- implicit autonomous production mutation;
- importing an estate directly into managed state without a zero-change gate;
- calling configuration estimates live or actual spend;
- enabling experimental protobuf-over-HTTP or unaudited HTTP/2 transports; and
- adding Cloudflare or another primary cloud provider.

## Canonical References

- shipped capabilities: [`shipped.md`](shipped.md)
- architecture: [`architecture.md`](architecture.md)
- provider catalog: [`gcp-provider-coverage.md`](gcp-provider-coverage.md)
- provider process protocol: [`provider-rpc.md`](provider-rpc.md)
- self-host and paid boundary: [`estate-control-plane.md`](estate-control-plane.md)
- local developer platform: [`agent-development.md`](agent-development.md)
- visual tooling: [`visual-workbench.md`](visual-workbench.md)
- releases and live gates: [`release.md`](release.md)
- consolidation design:
  `docs/superpowers/specs/2026-07-15-ziac-roadmap-consolidation-design.md`
