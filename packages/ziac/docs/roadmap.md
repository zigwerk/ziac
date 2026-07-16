# Ziac Roadmap

This is Ziac's only forward roadmap. Work shipped through M83 is recorded in
[`shipped.md`](shipped.md); dated designs and implementation plans are retained
as evidence rather than competing status sources.

- **Roadmap date:** 2026-07-16
- **Current baseline:** 253 managed GCP resource types, a versioned isolated
  provider RPC boundary, and a complete local Testing v2 receipt with 983
  executed tests (982 passed and one credential-gated skip)
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

The public ecosystem is a Ziac Cloud responsibility. Provider, component and
template source remains in its author's repository, while Ziac Cloud owns the
searchable package record, immutable release artifacts, qualification evidence,
publisher identity, signatures and revocation. The planned public surfaces are
`registry.ziac.dev` for metadata and discovery and `packages.ziac.dev` for
artifact delivery, subject to domain and production-environment setup. Public
discovery and installation must not require a paid subscription; private
packages, organization policy and scheduled qualification are paid hosted
capabilities.

## Delivery Order

| Milestone | Priority | Depends on | Outcome |
| --- | --- | --- | --- |
| M84 | P0 | Current baseline | Authenticated GCP and Cockroach qualification gauntlet |
| M85 | P0 | M84 bootstrap lanes | Five-project Ziac Cloud, including the registry, deployed and operated using Ziac |
| M86 | P0 | M84-M85 | Ten-minute developer journey plus hosted package publication and discovery |
| M87 | P1 | M84 evidence and M86D contracts | Signed third-party provider installation, sandboxing, recovery, drift and reliability |
| M88 | P1 | M85-M87 | Paid Estate Pro and authoritative cost intelligence |
| M89 | P2 | M87 contracts | Automated Google contract and provider evolution |
| M90 | Release | M84-M89 | Evidence-backed private beta |

M84, M85 and M86 may proceed in parallel where their authority boundaries do
not overlap. The M85 registry deployment and M86D API contracts evolve
together; M87A external execution begins only after signed metadata and
immutable artifact promotion exist. M90 cannot pass with an incomplete
predecessor.

## Runtime Control-Flow Foundation

**Status:** Implemented at the deterministic local gate. Immutable watch
deployment now uses a typed finite statechart, fsynced durable workflow
activities, restart replay, project catalog projections, and NenDB causal
records. The event-driven project template generates the same baseline.

Provider long-running operations, leases, estate paging, billing batches, and
the full provider-operation lifecycle remain ordered migration slices. Their
contracts and gates are tracked in
[`statecharts-and-workflows.md`](statecharts-and-workflows.md); authenticated
provider behavior remains part of M84 rather than being implied by local
workflow tests.

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
self-host gate are shipped. The hosted registry is accepted as a fifth project
and has not yet been implemented or authenticated.

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
- Add `platform/registry` as an independently deployable Ziac project beside
  bootstrap, data, control-plane and billing. Provision its APIs, service
  identities, Cockroach schema, GCS package and signed-index buckets, build/job
  workers, global HTTPS routes, DNS, certificates, monitoring and budgets using
  Ziac itself.
- Deploy `registry-api` and `publisher-api` on Cloud Run. Keep public search and
  download authority separate from authenticated publishing and revocation.
- Run deterministic provider qualification in bounded Cloud Build or Cloud Run
  Job workers. Live `cloud_qualified` lanes use separate disposable projects and
  explicit M84 capability envelopes.
- Publish immutable registry snapshots and package artifacts from GCS through
  Google's edge. Cockroach stores searchable package, version, publisher,
  qualification and revocation metadata; it is not the binary store.
- Connect global load balancing, DNS, certificates, service identity, Cloud
  Scheduler OIDC, Logging, Monitoring, alerts and SLOs.
- Add production project-connection creation and preflight.
- Exchange vaulted Google refresh credentials for narrowly scoped access tokens
  without exposing credentials to the local browser or causal artifacts.
- Prove upgrade, rollback, state recovery, key rotation and bootstrap disaster
  recovery from documented operator commands.

### Evidence

- bootstrap, state-migration, data, control-plane, billing and registry plan
  receipts;
- health, OAuth, entitlement, scheduler and billing worker probes;
- public registry search, publisher authentication, artifact promotion,
  signature verification, revocation and edge-download probes;
- a topology artifact showing only Ziac-managed and explicitly referenced
  resources;
- rollback and disaster-recovery receipts; and
- a self-host bill-of-materials with image and contract digests.

### Exit Gate

A clean operator environment uses the installed Ziac CLI to create the hosted
platform, migrate state, deploy all services, pass health, registry and
scheduled billing work, perform one safe upgrade and rollback, and recover from
a simulated lost local bootstrap directory. No Terraform, Pulumi or manually
provisioned registry resource may remain beneath the self-host claim.

## M86: Golden External Developer Journey

**Status:** In progress. Installed-prefix and generated-project gates are
shipped. M86A-M86C implement the local component and template ecosystem and
M86F ships the cross-harness provider development team; the published global
journey and hosted M86D-M86E surfaces are not yet qualified.

### M86A-M86F: Reusable Infrastructure Ecosystem

| Tranche | Status | Outcome |
| --- | --- | --- |
| M86A | Implemented at the local gate | Canonical package manifests, component descriptors and graph/visual provenance |
| M86B | Implemented at the local gate | Independent `ziac-gcpx` package with Asset Bucket and Hermes Desktop components |
| M86C | Implemented at the local gate | Three source templates, verified local registry, CLI discovery and installed-prefix scaffold qualification |
| M86D | Planned | Ziac Cloud public registry, publisher identity, immutable package artifacts, signed metadata, revocation and qualification records |
| M86E | Planned | Local dashboard marketplace, expansion previews, cost and permission summaries, evidence badges and update/ejection UX |
| M86F | Shipped at the deterministic gate | Creator, maintainer, qualifier and GCP researcher skills and agents for Codex, Claude Code and Gemini |

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

M86F deliberately does not open third-party executable loading. It makes the
shared provider RPC authorable and independently qualifiable while preserving
the M87 signed-artifact, revocation and sandbox gate.

### M86D: Ziac Cloud Registry And Publication

**Current state:** The CLI ships a digest-pinned static index at
`share/ziac-templates/index.json`. Publishing currently means changing the Ziac
repository and waiting for a CLI release. There is no public registry endpoint,
publisher workflow or safe external-provider installer yet.

**Ownership boundary:**

- the author owns the source repository, tests and release intent;
- the local CLI owns authoring, deterministic tests, local qualification,
  installation locks, verification and provider process launch;
- Ziac Cloud owns publisher identity, package names, searchable metadata,
  immutable artifacts, qualification records, signatures, revocation and
  delivery; and
- registry metadata never grants cloud credentials or executable authority by
  itself.

All package kinds use one registry and retain their distinct authority:

- providers are privileged RPC executables;
- components are unprivileged typed graph compilers; and
- templates are bounded user-owned source trees.

#### Hosted Architecture

The target `platform/registry` project contains:

| Surface | Runtime | Responsibility |
| --- | --- | --- |
| `registry-api` | Cloud Run | Public package search, versions, compatibility, trust and revocation metadata |
| `publisher-api` | Cloud Run | Publisher authentication, namespaces, upload sessions and release intent |
| qualification workers | Cloud Build or Cloud Run Jobs | Isolated package, RPC, compatibility and optional disposable-cloud gates |
| registry metadata | CockroachDB | Packages, versions, publishers, evidence, policies and revocations |
| package artifacts | GCS | Immutable per-platform archives, manifests, SBOMs, provenance and signatures |
| signed index | GCS plus edge delivery | Offline-verifiable public snapshots, timestamp and rollback protection |

`registry.ziac.dev` is the planned metadata/search endpoint.
`packages.ziac.dev` is the planned immutable artifact endpoint. Source URLs
continue to point to the author's repository. Ziac Cloud may ingest from an
author-owned release, but accepted artifacts are promoted into Ziac-owned
immutable storage so an upstream deletion cannot silently change a locked
installation.

#### Publisher Journey

The intended author workflow is:

```sh
ziac auth login
ziac provider init acme/fastly
ziac package verify .
zig build provider-rpc-test
zig build test --summary failures
ziac provider qualify
ziac provider publish
```

`provider init`, `qualify` and `publish` are roadmap commands, not shipped CLI
claims. The generated creator, maintainer and qualifier agents drive the same
contract without gaining publication or cloud authority implicitly.

Publication must:

1. authenticate a publisher and prove control of the namespace;
2. freeze the source revision, manifest and candidate digest;
3. upload source and per-platform artifacts to a private staging bucket;
4. run schema, secret scanning, dependency, deterministic build, RPC fault,
   lifecycle, migration and compatibility gates;
5. retain creator and maintainer evidence separately from independent qualifier
   evidence;
6. produce an SBOM, build provenance, checksums and signatures;
7. optionally run explicit disposable-cloud qualification without delaying a
   deterministic `verified` release;
8. promote accepted bytes immutably and append the signed registry record; and
9. retain revocation and replacement metadata without mutating an old version.

A provider release is expected to contain archives such as
`darwin-arm64.tar.zst`, `darwin-x86_64.tar.zst`, `linux-arm64.tar.zst` and
`linux-x86_64.tar.zst`, plus its canonical manifest, provenance, SPDX SBOM and
signatures. Unsupported platforms remain explicit rather than falling back to
an unverified local build.

#### Registry Trust

- Publisher identity and build provenance use a Sigstore-style signing model.
- The registry index uses a TUF-style root, targets, snapshot and timestamp
  model so clients can detect rollback, freeze and stale metadata.
- Every qualification label belongs to one immutable package digest.
- `community` means bounded metadata, `verified` means deterministic package and
  conformance evidence, `official` adds Ziac release ownership, and
  `cloud_qualified` requires current authenticated evidence for its declared
  matrix.
- Revocation can block new installation immediately while preserving enough
  metadata to explain and recover existing lockfiles. Critical revocations must
  surface locally even when a package has disappeared from search.

#### Commercial Boundary

Public package search and installation are free. A free Ziac Cloud identity is
required to publish or maintain a namespace, not to consume public metadata.
Paid capabilities include private providers and packages, organization-scoped
registries, approval and allow/deny policy, private artifact retention,
scheduled requalification, support SLAs, audit exports, estate discovery and
cost intelligence. Payment must never become a way to bypass qualification.

#### M86D Delivery Tranches

| Tranche | Outcome |
| --- | --- |
| M86D1 | Versioned registry schemas, package namespaces, public search API and signed static snapshot |
| M86D2 | Publisher identity, namespace verification, staging uploads and immutable release intent |
| M86D3 | Deterministic qualification workers, evidence records, SBOM/provenance generation and promotion |
| M86D4 | GCS artifact delivery, signatures, revocation, mirrors, backup and restore |
| M86D5 | CLI auth, search and publish workflows for providers, components and templates |
| M86D6 | Private organization packages, policy controls and scheduled requalification |

M86D exits when an external publisher can release a component, template and
non-executable provider record from outside the Ziac repository; another clean
machine can discover the exact versions, verify signed metadata and download
the immutable artifacts; revocation propagates without rewriting history; and
the complete registry is deployed, upgraded, backed up and restored by Ziac.
Safe installation and execution of the provider binary is the M87A gate.

### M86 Overall Objective

Take a developer from an empty Git repository to a globally deployed Zig API
with a useful local canvas in under ten minutes, without any path back to the
Ziac source checkout.

### M86 Overall Deliverables

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

### M86 Experience Budgets

- first valid local plan within two minutes after prerequisites are present;
- first local hot reload within one second for a small service;
- no-op plan without provider mutation;
- unchanged-image watch deploy uploads no existing blob;
- every failure returns a stable diagnostic, causal evidence and next action;
  and
- no command requires editing generated registry code.

### M86 Exit Gate

Three clean external repositories, including one multi-project monorepo, install
the published CLI and independently complete init, local development, plan,
global deployment, dashboard observation, update, rollback and cleanup. Median
time to the first healthy global endpoint is under ten minutes after cloud
prerequisites are ready.

## M87: Provider And State Reliability Campaign

**Status:** Planned. M87A is the security gate that turns an M86D provider
artifact into an installable external provider without trusting registry text
as an executable path.

### Objective

Turn broad provider coverage into boring, recoverable operational behaviour
under failures, concurrency and Google eventual consistency.

### Deliverables

#### M87A: Signed External Provider Installation

The intended consumer workflow is:

```sh
ziac registry search fastly --kind provider
ziac provider install acme/fastly@0.1.0
ziac provider list
```

These installation commands are M87A targets and are not shipped today.

- Add `ziac provider install <namespace/name>@<version>`, `update`, `remove` and
  `list` using only signed registry metadata and immutable artifact digests.
- Resolve the current OS and architecture exactly, verify TUF-style registry
  metadata, publisher and registry signatures, artifact digest, provenance,
  SBOM identity, package compatibility and revocation before extraction.
- Install into a Ziac-controlled content-addressed directory and write
  `ziac.lock` with package, version, manifest digest, artifact digest, publisher,
  qualification label, protocol, executable identity and allowed resource type
  prefixes.
- Launch only binaries selected from the verified lockfile. Never execute a
  manifest path, registry command, install hook, project-local shadow binary or
  mutable `PATH` lookup.
- Require an exact RPC handshake matching the lock before sending a resource.
  Restrict the process to declared resource prefixes and explicit project,
  stage, operation, secret-reference, network and deadline capabilities.
- Add OS-level filesystem, process, credential and network sandbox profiles,
  with a visible unsupported-platform failure rather than an unsafe fallback.
- Support offline verification and locked execution from cached bytes while
  enforcing metadata expiry and critical revocation policy explicitly.
- Prove malicious archives, traversal, symlinks, digest substitution, stale
  metadata, rollback, publisher compromise, revoked keys, identity mismatch and
  resource-prefix escalation all fail closed.

#### M87B: Provider And State Reliability

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
- Add provider process pools, cooperative cancel frames and bounded restart
  policy on top of the locked and sandboxed M87A `ziac.provider.rpc.v1`
  process boundary.
- Define latency, memory, request-count and retry budgets for plan, refresh,
  apply, watch and dashboard patch propagation.
- Run multi-seed deterministic fault campaigns and scheduled real-cloud canaries.

### Exit Gate

Every catalog capability is backed by its declared conformance lane; the full
fault matrix produces no corrupt state, leaked lease, unbounded retry or
unexplained plan; and scheduled cloud canaries remain green for 30 consecutive
days. In addition, one independently maintained third-party provider must be
published through Ziac Cloud, installed by digest on every supported platform,
run in the declared sandbox, complete deterministic create/read/update/import/
no-op/delete qualification, reject a simulated malicious update, and respond to
a registry revocation without executing untrusted bytes.

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
- Operate `registry.ziac.dev` and `packages.ziac.dev` with documented SLOs,
  publisher recovery, namespace disputes, key rotation, revocation, backup and
  restore.
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
- Public registry search, free package installation and one independently
  maintained external provider pass the M86D and M87A gates.
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
- provider authoring and qualification: [`provider-development-kit.md`](provider-development-kit.md)
- package ecosystem and trust: [`ecosystem.md`](ecosystem.md)
- self-host and paid boundary: [`estate-control-plane.md`](estate-control-plane.md)
- local developer platform: [`agent-development.md`](agent-development.md)
- visual tooling: [`visual-workbench.md`](visual-workbench.md)
- releases and live gates: [`release.md`](release.md)
- consolidation design:
  `docs/superpowers/specs/2026-07-15-ziac-roadmap-consolidation-design.md`
