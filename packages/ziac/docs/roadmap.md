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
  Service Connect slices are implemented. GCS state, saved plans, source builds,
  canary rollback, and the credential-free release gate are implemented;
  authenticated cloud acceptance remains pending external configuration.
- Google RPC specialization M9 is implemented: pinned descriptor ingestion,
  semantic contract snapshots and upgrade diffs, AIP-aware Cloud Run updates,
  native multi-region architecture selection, graph-derived IAM/preflight,
  topology and rollout intelligence, and fail-closed gRPC qualification.

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
- Generated Zig 0.16.0 musl recipe: verified for amd64 and arm64 in pinned
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
- Immutable saved plans and digest-specific destructive approval: complete,
  including create-exclusive artifacts, current-graph validation, executor
  confirmation, and secret-reference-only persistence.
- Keyless GitHub WIF and isolated preview stages: complete, including native
  GitHub external-account ADC, repository-bound stage names, scoped GCP/DNS
  identities, saved-plan workflow template, and production-proof cleanup.
- Canary regional rollouts, revision readiness, guarded digest rollback,
  interruption recovery, and quota/rate diagnostics: complete.
- Credential-free release gate, complete production example, strict live-test
  manifest, and public operator documentation: complete.
- Clean-checkout automated verification and authenticated end-to-end execution:
  final gate.

Gate: all automated suites and the configured live end-to-end workflow pass,
including regional failover, database TLS, update, interruption recovery, import,
protected data retention, and secret leak scanning.

## M9: Google RPC And GCP Intelligence

- Pinned Google protobuf/AIP method descriptor kernel: complete for Cloud Run.
- Validated resource-template expansion and conservative transport selection:
  complete.
- Cloud Run provider migration to descriptor-owned REST bindings: complete.
- Deterministic proto lock, descriptor-set generator, and semantic upgrade diff:
  complete with a 25-file descriptor closure and generated snapshot.
- AIP-aware field ownership, update masks, etags, validate-only, request IDs,
  LRO/readiness state, typed status causes, and partial-read safety: complete as
  reusable kernels; Cloud Run consumes masks, etags, and readiness directly.
- Bounded unary gRPC framing, trailers, deadlines, capability audit, and REST
  parity contract: complete. No HTTP/2 adapter is enabled until it passes the
  complete audit; REST transcoding remains the production transport.
- Native Cloud Run global multi-region realization with automatic fallback to a
  controlled fleet for PSC, regional bindings, or canary control: complete.
- IAM, org policy, quota, billing, residency, latency, Cockroach locality,
  asset drift, service health, and SLO preflight/intelligence: deterministic
  graph-derived kernels complete.

Deterministic gate: complete. A pinned proto reproduces its lock and semantic
snapshot; upgrade facts produce a breaking/non-breaking diff; automatic
topology proves native and fleet paths; preflight catches IAM, API, region,
quota, org-policy, and topology defects before mutation; incomplete gRPC
adapters fail closed.

External acceptance: a future qualified HTTP/2 adapter must prove REST/gRPC
parity in a disposable project. Authenticated org-policy, quota, Cloud Asset,
Monitoring, regional failover, and Cockroach data-path evidence still requires
the live environment declared by `release/live-tests.json`.

## M10: Visual Infrastructure Workbench (Complete)

- Deterministic, redacted `ziac.visual.v1` exporter for desired graphs and
  plans: complete.
- Generated three-region Cloud Run, global load balancer, DNS, and CockroachDB
  fixture: complete.
- Strict browser parser, graph identity, malformed-reference rejection, region
  catalogue, truth modes, and shared filters: complete.
- Cloudcraft-style orthographic Three.js topology with a square grid, raised
  global/regional/VPC/data planes, beveled resource blocks, semantic routes,
  synchronized selection, architecture/network/VPC/dependency modes, and
  accessible resource navigation: complete.
- Planar contour-following topology traces with deterministic edge ports,
  right-angle channels, translucent pastel semantics, neutral dashed
  dependencies, flat arrowheads, and canvas-aligned IAM badges: complete.
- Intrinsic resource-face identity (type, name, canonical ID), region/VPC slab
  decals, exact object grounding, and resource/scope hover intelligence with
  health, uptime, connection counts, and explicitly estimated expense:
  complete.
- Capacity-aware plane sizing, multi-row region placement, deterministic node
  packing, dynamic grid/camera bounds, and non-overlap contracts through 12
  regions and 48-resource expanded fixtures: complete.
- Official Google Cloud product/category icon catalogue and top-face resource
  artwork with provider-safe fallbacks: complete.
- Product-family zones inside every slab, including deterministic Cloud Run,
  Storage, networking, security, serverless, database, and provider grouping:
  complete.
- Backward-compatible visual access metadata plus same-slab read/write/invoke/
  admin routes and permission badges: complete in the artifact parser, scene
  model, renderer, and representative permission fixture.
- Cloud-estate ownership hierarchy with a GCP account moat, nested global VPC
  around regional slabs, peer third-party account placement, and hoverable
  account/network intelligence: complete.
- Model-owned account/network label footprints with reserved front gutters and
  checked non-overlap against every contained slab and locality: complete.
- Cockroach Cloud account block with exact declared-region locality tiles,
  primary/replica roles, and one canonical cluster resource: complete.
- Projection-aware isometric/top-down camera fitting and context-first narrow
  overview zoom for complete account-boundary framing: complete.
- Compact GCP-console-style command shell, tabbed resource investigation, and
  deployment/live-log/agent dock: complete.
- Annotated density refinement with 40px/34px command chrome, a 38px tool rail,
  unified agent command strip, dense causal event table, and polished 108px
  rollout dock: complete and desktop/mobile browser verified.
- Monochrome MapLibre and deck.gl world map with Cloud Run/Cockroach locality,
  anycast front-door overlay, inferred route arcs, semantic-only accents,
  provenance, and accessible region controls: complete.
- Responsive desktop/mobile behavior and causal Workbench compatibility:
  automated and browser verified.

Gate: the generated Ziac artifact passes Zig and TypeScript contract tests;
Topology and Global Map render nonblank at desktop and mobile viewports;
selection and filters remain synchronized; the existing causal Workbench suite
and production build pass.

## M11: Agent Contract And Authority

Status: Complete. Deterministic package tests cover the contract, authority,
durable session statechart, redacted artifacts and JSON-first CLI.

- Strict `ziac.project.v1` requirements, acceptance, environment and adaptation
  contract.
- Capability envelopes with project/stage/provider/action/expiry boundaries.
- Create, update, delete, region, cost, deadline and approval autonomy budgets.
- Durable agent session state machine and versioned status/next/query/explain/
  handoff artifacts.
- `ziac agent` CLI backed by the same public kernel used by MCP and Workbench.

Gate: an agent can orient, identify the next accepted action, query the graph
and hand off with complete redacted evidence and no terminal parsing.

## M12: Hybrid Hot-Reload Development

Status: Complete. Manifest-owned build/process commands, deterministic source
digests, the native watcher, supervised generations, readiness probes, stable
reverse proxy, structured CLI events and failed-generation preservation are
implemented and covered by a real child-process/proxy E2E.

- `.dev` phase and explicit local/cloud/mock/proxy/skip/remote-only resource
  adaptation.
- Local Zig build/watch, supervised generations, stable reverse proxy, health
  promotion, draining and failed-reload rollback.
- Typed local public/secret bindings and local verified-TLS Cockroach strategy.
- Incremental change classification, affected-subgraph planning, cancellation
  and newest-save convergence.
- `ziac dev` with structured events and automatic smoke verification.

Gate: a local service hot swaps behind one stable URL; failed builds and failed
readiness preserve the prior healthy generation; unchanged infrastructure makes
zero provider calls.

## M13: Unified Causal Logs

Status: Complete. The bounded redacted store, durable JSONL session format,
identity filters, causal explanations, authenticated Cloud Logging adapter,
owned polling cursor, live CLI ingestion and reactive Workbench feed are
implemented.

- Bounded redacted `ziac.log.v1` events for compiler, process, proxy, provider,
  Cloud Run, load balancer, Cockroach, checks, agents and repairs.
- Stable event/parent/session/trace/resource/revision identities.
- Local multiplexing, Cloud Logging cursor ingestion, suppression/drop evidence,
  `tail`, `logs` and `explain`.
- Live Workbench session, timeline, filters and investigation panels.

Gate: local reload and scripted cloud failures share one ordered causal stream,
redact sentinels, and remain queryable from CLI and Workbench.

## M14: Fast Immutable Watch Deploy

Status: Complete. Deterministic OCI planning, missing-blob-only registry
pushes, content-addressed caching, pinned base locks, newest-save convergence,
capability guardrails, no-traffic readiness promotion, CLI event streaming and
measured timing/SLO receipts are implemented.

- Deterministic Zig binary OCI layer/config/manifest planning against pinned
  cached base images.
- Registry blob negotiation and missing-blob-only upload contract.
- Code-only `deploy --watch` path with coalescing, cancellation, tagged/no-
  traffic verification and development traffic promotion.
- Timed SLO receipts and strict production/capability guardrails.

Gate: rapid saves deploy only the newest immutable digest, unchanged blobs are
not uploaded, and production cannot use the watch path without exact authority.

## M15: Governed Agent Tools And Infrastructure Testing

Status: Complete. The deterministic scenario catalog, replay receipts,
immutable repair proposals, MCP authority registry, response contracts,
generated agent guidance and shared CLI/MCP simulation, proposal and declared
verification kernel are implemented. Exact-plan apply remains in the existing
digest/capability/approval executor and cannot be expanded by an agent tool.

- Deterministic region, quota, IAM, stale-etag, interrupted-apply, LRO,
  Cockroach-locality, secret-rotation, reload and rollback scenarios.
- Saved evidence-backed repair proposals and requirement verification.
- Read-only-first MCP adapter, then proposal, verification, exact-plan apply and
  handoff tools over the same kernel.
- Generated Codex and Claude skills with no implicit authority.

Gate: CLI and MCP artifacts agree, scenarios replay exactly, proposals cannot
mutate, and apply remains digest/capability/approval gated.

## M16: Ephemeral Environments And Closed-Loop Operations

Status: In progress. Repository-bound leases, WIF/state/budget projection,
expiry, idempotent cleanup, correlated Cloud Run/Cockroach diagnosis, repair
proposal and closed verification are complete; live provider wiring,
Workbench presentation and final qualification remain open.

- TTL-bound repository stages, WIF identity, isolated GCS state, cost/resource
  budgets, heartbeat, expiry and automatic production-proof cleanup.
- Correlated application Env, binding, secret, identity, IAM, Cloud Run,
  load-balancer, PSC and Cockroach evidence.
- Cloud Run-to-Cockroach missing-IAM diagnosis, saved repair, simulation,
  verification and portable handoff acceptance.

Gate: an expired environment cannot mutate, cleanup converges idempotently, the
broken binding is repaired entirely through structured causal evidence, and all
deterministic release gates pass. Authenticated latency, log-tail, regional
failover and data-path qualification remains separately declared.

## M17: Existing GCP Estate Visualization

Status: In progress. The read-only Workbench vertical slice, S256 PKCE contract,
independent control-plane identity/Pro/connection resolution, authenticated
Cloud Asset Inventory adapter, bounded scanner, CLI command, fixed-argv desktop
host launch and artifact refetch are implemented. A deployed subscription and
Google callback service plus authenticated disposable-project qualification
remain open.

- Backward-compatible `managed`, `observed`, and `referenced` ownership in the
  redacted visual artifact: complete.
- Graph-safe `Ziac`, `Existing`, and `Combined` filtering across canvas, map,
  selection, routes, regions, navigator, and inspector: complete.
- Observed Three.js resource identity, neutral ownership accents, discovery
  provenance, and read-only inspector treatment: complete.
- Fail-closed Google identity, Pro entitlement, and GCP connection projection:
  complete at the Workbench/host contract boundary.
- Connected estate fixture covering managed global services plus existing Cloud
  Run, Cloud SQL, Storage, VPC, load balancing, and Compute resources: complete.
- Control-plane identity/subscription/connection client, installed-app PKCE,
  paginated Cloud Asset Inventory scanning, provider mapping and read-only
  artifact generation: complete.
- Deploying the callback/subscription service and qualifying a paid user against
  a disposable customer project: pending external environment configuration.
- Scheduled scans, asset feeds, cost attribution, code generation, and
  zero-change adoption: deferred to subsequent milestones.

Gate: a paid authenticated user scans a disposable project through the Zig
host, receives a redacted observation artifact with no credentials, and sees
existing and managed resources remain graph-correct and mutation-isolated.

## M18-M25: Product Completion Programme

Status: In progress. The authoritative design and execution checklist are:

- `docs/superpowers/specs/2026-07-12-ziac-product-completion-design.md`
- `docs/superpowers/plans/2026-07-12-ziac-product-completion.md`

The programme closes the remaining boundary between the engine and a usable
product: user-project compilation and scaffolding, the standalone live dashboard
host, a standards-compliant and capability-safe MCP server, native cloud watch
deployment, the Estate Pro control plane, pricing and billing attribution, one
authenticated source-to-global-Cloud-Run-to-Cockroach qualification, and beta
release packaging.

M18 user-project compilation and installed-client packaging are complete at the
credential-free gate. `zig build --prefix <prefix>` installs the CLI, dashboard
host, MCP server, control-plane executable, dashboard bundle, and relocatable
Ziac/ZigEffect package sources. Bare `ziac init` initializes the current Git
repository, derives a stable project name, and generates a real
`gcp.global.ZigService`, Testing v2, fixed program compiler, MCP configurations,
and matching project-local skills for Codex, Claude Code, and Gemini CLI.
An isolated-prefix acceptance gate uses a fresh Zig global cache to run tests,
`ziac check`, plan, fake apply, no-op replay, dashboard artifact generation,
the installed dashboard host, and installed MCP verification without a path back
to the source checkout.

M19 standalone dashboard hosting is complete locally. The Ziac package owns the
native host and every `ziac_*` bridge binding. User project graphs produce real
redacted visual artifacts through `ziac dashboard`; missing hosts fail visibly
instead of selecting fixtures, live files refetch, and heavyweight canvas/map
engines are lazy chunks. The native server and generated-project artifact path
are release-gated.

M20 agent protocol and process authority are complete locally. Ziac serves MCP
`2025-11-25` over bounded newline-delimited stdio, advertises only implemented
tools, and ships generated harness configuration. Acceptance checks are fixed
argv, legacy shell strings are non-executable, process authority is distinct
from read authority, and verification receipts bind both command and manifest
digests. Hostile shell, traversal and capability tests are release-gated.

M21 rapid development is complete at the credential-free implementation gate.
The standalone CLI now wires `deploy --watch` to a graph-derived, project-bound
Cloud Run v2 runtime instead of a scripted-only adapter. A watch rollout must
name an immutable image and an integrity-checked saved plan; it preserves the
current template, pins traffic to the prior revision, waits on the LRO, proves
the candidate revision healthy, then promotes that exact revision. Cross-project
targets, mutable images, production stages, destructive plans, stale graph
digests and self-asserted plan digests fail closed. Phase receipts are persisted
to the same causal log session consumed by the dashboard. Existing native local
watch still provides stable-proxy hot reload and failed-generation preservation.
Authenticated Cloud Run latency evidence remains in M24 rather than being
misreported as locally proven.

M22 Estate Pro has a useful deterministic kernel but is not yet a complete paid
product. The server-side authorization kernel hashes bearer assertions, enforces Google-subject ownership and Pro
expiry, resolves only connected projects, revokes immediately, and writes
append-only audit events without credential metadata. The Google OAuth adapter
performs PKCE code exchange and verifies OIDC audience, issuer, nonce, expiry,
subject and email before exposing a zeroing grant to the callback coordinator.
The callback consumes a challenge through an injected one-time verifier, sends
the refresh token directly to a credential vault, stores only a session digest,
and returns the new assertion once. The Cockroach production schema covers
accounts, sessions, entitlements, encrypted credentials, challenges and audit.
The installed `ziac-estate-control-plane` process composes the native verified-
TLS Cockroach repository, atomic challenge store, secure random issuer, Google
OAuth exchange, Cloud Run ADC, Cloud KMS vault and bounded HTTP server. It
refuses startup when any production dependency is missing. A paid identity scan
against a disposable project remains an M24 authenticated qualification item.

Production blockers retained for M26-M28:

- KMS encryption must send `plaintextCrc32c` and verify both request and response
  integrity instead of requiring a verification flag for a checksum it omitted.
- A first-time account must exist before foreign-keyed credential persistence.
- OAuth challenges need cleanup, rate limiting, and recoverable failure states.
- No production endpoint currently creates and preflights a GCP connection.
- Stored Google refresh credentials are not yet decrypted and exchanged for the
  short-lived access token used by a hosted scan; the CLI scanner still needs ADC.
- Production entitlements are read-only; billing webhooks, operator grants,
  renewal, cancellation, replay protection, and signed local feature leases are
  not implemented.
- The dashboard access action is not yet connected to the hosted OAuth flow.

M23 cost intelligence has completed its credential-free provider and attribution
gate. The shared cost contract now
distinguishes configuration estimates, projected month-end cost and actual
billed cost at the type level. Estimates require explicit SKU, region, unit and
usage assumptions; actuals include exported credits; projections can derive only
from actual billing data; and missing usage returns unavailable rather than a
fabricated range. The authenticated adapter now paginates Cloud Billing Catalog
SKUs, preserves every tier, currency and effective time, submits and resumes
BigQuery jobs, parses integer micros without floating-point loss, and emits exact
attributed and unattributed totals with coverage basis points. The dashboard no
longer invents type-based price ranges; absent billing telemetry is explicitly
unavailable. A Cockroach migration owns billing sources, runs and attributed
resource costs. Scheduling and the first authenticated customer export remain a
live qualification item.

No milestone is described as externally qualified until its authenticated live
gate has produced a complete redacted evidence bundle. Credential-free code
completion and external qualification remain separate roadmap states.

## M26-M40: Local-First SaaS And Self-Hosting Programme

Status: In progress. The authoritative architecture and complete remaining
execution programme are:

- `docs/superpowers/specs/2026-07-12-ziac-local-first-saas-self-hosting-design.md`
- `docs/superpowers/plans/2026-07-12-ziac-local-first-saas-self-hosting.md`

The programme preserves the local dashboard as the primary developer product
while adding a hosted intelligence plane for subscriptions, Google connections,
scheduled estate discovery, actual billing data, history, teams, and reports.
It covers production-blocker closure, customer connection lifecycle, signed
feature leases, realtime graph revisions, real dashboard operations, scheduled
estate snapshots, honest cost intelligence, customer and internal admin portals,
Ziac's typed self-host bootstrap and production stacks, organization features,
reports and adoption, unified authenticated qualification, and private beta.

The immediate client-install gate is complete. M35-M36 now have a typed
credential-free self-host implementation: `ziac init --preset ziac-cloud`
creates independent bootstrap, Cockroach data, control-plane and billing
projects, all four compile through the installed CLI, and one root dashboard
merges them. Bootstrap
owns required APIs, retained GCS state, retained Cloud KMS resources and deployer
IAM, a retained Artifact Registry repository, and credential containers. The data project owns the Cockroach database,
SQL user, grants, generated Secret Manager connection version, and ordered
control-plane/billing migrations. The control plane compiles as a global Cloud
Run service and billing as a private authenticated service with its own native
worker, exact global-name attribution, Cockroach run persistence, and an hourly
Cloud Scheduler OIDC trigger. The qualification builds both hosted Linux images
in Cloud Build and resolves immutable Artifact Registry digests. The authenticated
qualification script applies bootstrap from local state, migrates it to GCS,
deploys data and both hosted services, probes health, queries the configured
detailed export, forces the managed scheduler, and requires a successful worker
attempt. Missing credentials produce exit 77 and an explicit skip receipt.

M26 production blocker closure and M27 hosted GCP connection lifecycle remain
the next hosted-service hardening slices. M39 remains the decisive
end-to-end gate: a clean external project signs in, scans, edits, watches the
local canvas update, deploys globally, reads and writes Cockroach, receives honest
cost data, revokes access, and cleans up while Ziac's own hosted plane is deployed
from Ziac code.

## M41-M46: Monorepo Workspace Dashboard

Status: Complete at the credential-free local product gate. The authoritative
design and implementation record are:

- `docs/superpowers/specs/2026-07-12-ziac-monorepo-workspace-dashboard-design.md`
- `docs/superpowers/plans/2026-07-12-ziac-monorepo-workspace-dashboard.md`

Ziac now treats a Git root as a workspace containing one or more independently
deployable projects. Recursive bounded discovery ignores generated, VCS and
dependency trees, sorts projects deterministically, and rejects duplicate stable
project identities. Every compiler runs from its owning directory and uses the
dashboard target declared by its project manifest.

One root command emits `ziac.workspace-visual.v1` atomically, launches one local
host, and refreshes through fixed argv without shell evaluation. The dashboard
namespaces colliding resource identities by project, validates explicit
cross-project links, renders one physical topology, and offers project
multi-selection with selected, dependency and connected slices. All existing
provider, region, health, operation and estate filters remain graph-safe.

Interactive initialization confirms the inferred workspace setup, generated
projects declare their visualization target, and Codex, Claude Code and Gemini
receive the same monorepo-aware skill at both project and Git roots. The installed
client E2E creates two nested projects and compiles them into one workspace
artifact without a source-checkout escape hatch.

The workspace compiler now hashes only each manifest and its declared source
roots, caches project artifacts by target-aware revision, recompiles only changed
projects, and preserves the last known good child artifact on a failed compile.
The native host now checks declared input revisions on a bounded local interval;
the browser no longer polls complete artifacts. Changed input triggers the
target-aware affected-project compiler and emits a monotonic
`ziac.workspace-patch.v1` containing only complete changed project slices,
removals, ordering and links. Stale bases fall back to one snapshot reload.
OS-specific FSEvents/inotify adapters remain an optional latency optimization;
they no longer require a protocol or frontend redesign.

## M47-M52: Ziac Cloud Bootstrap Completion

Status: Credential-free implementation complete; authenticated qualification
pending operator credentials. The authoritative design and execution record are:

- `docs/superpowers/specs/2026-07-12-ziac-cloud-bootstrap-completion-design.md`
- `docs/superpowers/plans/2026-07-12-ziac-cloud-bootstrap-completion.md`

The local dashboard now invokes fixed-argv Ziac plans through the native host,
saves plans beneath the workspace, displays exact operation counts and digest,
and requires explicit digest approval before apply. Browser requests cannot
choose an executable, working directory, plan path or shell command. Live watch
deploys are now host-supervised asynchronous operations with opaque IDs, real
phase projection, bounded redacted output, status lookup, and capability-scoped
cancellation. The deployment dock renders only those phases and retained causal
events; the removed timer and percentage demonstration is no longer presented
as evidence.

The completion gate is `zig build self-host-gate`. The live gate is
`packages/ziac/scripts/qualify-ziac-cloud.sh`; it cannot be marked passed until
run against the intended GCP project, Cockroach cluster, DNS zone and detailed
billing export.

## M53-M54: Official GCP Research And Realtime Agent Loop

Status: Complete at the credential-free local product gate.

`ziac init` now scaffolds one consistent `gcp-developer-research` skill and a
read-only `gcp-developer-researcher` for Codex, Claude Code, and Gemini. Project
and root-safe harness configuration targets Google's official Developer
Knowledge MCP endpoint with `search_documents` and `get_documents` only. The
API key is referenced through `DEVELOPERKNOWLEDGE_API_KEY` and never generated,
persisted, logged, or embedded. The research protocol ranks exact references,
guides, release notes, and concepts; reports Ziac implications and confidence;
and labels inference. Public Preview availability is explicit.

The local agent loop now has one truthful path from save to canvas and deploy:
declared-input revision detection, affected-project compilation, monotonic
project patches, stale snapshot recovery, saved-plan approval, asynchronous
watch execution, compact status polling, causal event rendering, and scoped
cancellation. Deterministic tests cover scaffold consistency, root safety,
patch replacement/removal/staleness, browser validation, real child-process
supervision, and source revision changes. Live GCP behavior remains governed by
the authenticated M39 qualification rather than inferred from local proof.

## M55: Relocatable Agent Development Kit

Status: Complete at the credential-free install gate.

The installed Ziac prefix now carries the CLI, MCP server, dashboard host and
assets, required package sources, protobuf and provider contracts, examples,
scripts, and the complete Ziac documentation tree. Generated skills resolve the
Ziac dependency from `build.zig.zon` and use that relocatable package directory
as their local implementation knowledge root. They never depend on the original
source checkout or an author-specific path.

Local documentation defines the behavior shipped in the installed Ziac version.
The GCP researcher compares that baseline with current official Developer
Knowledge before recommending provider changes. API keys, ADC, cloud authority,
and paid-service entitlements remain operator-owned inputs and are not bundled
or persisted by the installer.

## M56-M81+: Comprehensive GCP Provider Coverage

Status: In progress. The authoritative architecture and giant execution roadmap
are:

- `docs/superpowers/specs/2026-07-13-ziac-gcp-provider-coverage-design.md`
- `docs/superpowers/plans/2026-07-13-ziac-gcp-provider-coverage.md`

Ziac's provider boundary is now broad practical Google Cloud coverage, not only
Cloud Run and global load balancing. The programme combines generated Google
resource primitives, hardened Ziac resources and opinionated architecture
components. Every resource carries a machine-readable support stage and
capability record, and managed support remains distinct from authenticated live
qualification.

M56-M62 is the application-platform tranche: provider catalog and generation
spine, general Cloud Storage, Pub/Sub, Cloud Tasks, Eventarc, Cloud Run jobs and
worker pools, general IAM semantics, and one integrated authenticated gate.
M63-M80 then cover data services, compute, networking, GKE, operations, delivery,
security, governance and organization resources. M81+ continues stable analytics,
integration and AI resource expansion from pinned Google contracts and measured
user demand.

The definition of done includes typed declarations, full lifecycle and import,
AIP-aware drift, IAM/preflight, estate mapping, canvas semantics, honest cost,
agent documentation and authenticated disposable-project evidence. A serializer
or observed Cloud Asset kind alone does not count as provider coverage.

M56 is complete. The installed `ziac provider resources` command introduced the
versioned managed catalog and visible planned surface as deterministic JSON or
Markdown. After M61 it reports 62 managed types, with service filtering,
bidirectional dispatcher parity, pinned proto/Discovery provenance and semantic
upgrade-diff artifacts. Generated skills point agents at the same installed
reference.

M57 is locally complete and awaiting only authenticated disposable-project
qualification. General buckets now include typed multi-rule lifecycle, CORS,
retention, soft delete, CMEK, metageneration-safe updates, dual-form import and
explicit guarded cleanup. Exact conditional IAM preserves unrelated policy.
Generation-pinned immutable objects, estate identity, storage inspector facts,
explicit capacity/operation/egress estimates and `AssetBucket`, `UploadBucket`
and `StaticAssetBucket` components are covered by deterministic provider tests.
The installed current-state reference is `docs/gcp-provider-coverage.md`.

M58 is locally complete and awaiting authenticated publish/delivery/retry and
cleanup qualification. Topics, schemas, subscriptions, snapshots and exact
conditional topic/subscription IAM now have full deterministic lifecycle and
import coverage. `gcp.run.ServiceIamMember` adds resource-scoped, etag-safe
Cloud Run IAM. `ZigSubscriber` compiles a dedicated OIDC identity, source and
dead-letter topics, push subscription, exact Run invoker access, Pub/Sub
service-agent forwarding access and explicit publisher members into one graph.
Permission synthesis, Cloud Asset identity, event edges, inspector metadata,
official icons and configuration-based cost assumptions are synchronized. See
`docs/gcp-pubsub.md` for the contract and its custom-audience limitation.

M59 is locally complete and awaiting authenticated enqueue, event delivery and
cleanup qualification. Cloud Tasks queues now cover dispatch, retry, routing,
logging and queue-level OIDC/OAuth identity with exact etag-safe IAM. Eventarc
triggers cover filters, channels, service identity, transport ownership and all
supported writable destination families through resumable long-running
operations. Remote responses are normalized for drift, including output-backed
transport topics. `ZigTaskWorker` and `EventPipeline`, graph-derived act-as and
product permissions, Cloud Asset identity, canvas metadata, deterministic
delivery decisions and explicit Tasks/Eventarc cost assumptions pass the local
gate. See `docs/gcp-tasks-eventarc.md`.

M60 is locally complete and awaiting authenticated migration Job, parallel Job,
scheduled OAuth invocation, cancellation and Worker Pool rollout qualification.
Jobs and Worker Pools now use typed multi-container declarations, normalized
CRUD/import, resumable Cloud Run long-running operations, etag concurrency,
governed execution receipts and dedicated high-level components. Exact Run,
Scheduler and act-as preflight, Cloud Asset identity, distinct canvas groups and
explicit compute-duration estimates are synchronized. Executions and revisions
remain observed children rather than managed resources. See
`docs/gcp-cloud-run-workloads.md`.

The M60 local Testing v2 gate is complete with 564 discovered/executed tests,
563 passed, one credential-gated skip, and zero failures, pending tests, leaks
or logged errors. Dashboard tests, typecheck, production build and the Testing
v2 migration guard also pass.

M61 is locally complete and awaiting authenticated project, folder and
organization qualification. Project, folder and organization
member/binding/policy families, service-account IAM, custom roles and Workload
Identity Federation pools and OIDC providers now have typed declarations,
normalized import and conflict-safe lifecycles. Member, binding and policy
ownership cannot overlap in one graph. Conditional policy uses version 3 and
bounded etag retries; unrelated concurrent edits survive deterministic mutation
tests. Soft-deleted roles and federation resources recover through Google's
native undelete flow before reconciliation.

Permission intelligence separates deployer and runtime authority with resource
and operation provenance, emits custom-role proposals and calls native
`testIamPermissions` endpoints. Cloud Asset discovery maps IAM identities to the
same managed physical IDs. The workbench renders ownership, conditions, blast
radius and permission-bearing IAM edges. See `docs/gcp-iam.md`.

The M61 local Testing v2 gate is complete with 585 discovered and executed
tests, 584 passed, one credential-gated skip, and zero failures, pending tests,
leaks or logged errors. The provider catalog reports 62 managed resources.

M62 is locally complete and awaiting the disposable-project service exercise.
`ziac.gcp.ApplicationPlatform` now composes a private Cloud Run API, upload
bucket, Pub/Sub push/dead-letter path, Cloud Tasks queue, Eventarc trigger,
scheduled Job, Worker Pool and dedicated identities into one deterministic
graph. A valid application binding fixture proves the compile-time boundary.
The integrated lifecycle test applies the graph, imports every resource into an
empty second state, refreshes to a no-op plan and destroys under explicit
authority while retained resources remain present at the provider boundary.

Visual artifacts attach configuration-estimate provenance and IAM permission
edges without implying billing-export data. The local qualification receipt is
always unauthenticated. `scripts/qualify-application-platform.sh` separately
requires ADC, an immutable image and a project ending in `-ziac-disposable`, and
otherwise emits a structured skip. See `docs/gcp-application-platform.md`.

The M62 local Testing v2 gate is complete with 588 discovered and executed
tests, 587 passed, one credential-gated skip, and zero failures, pending tests,
leaks or logged errors. All public examples compile, including the integrated
application-platform example.

M63 is locally complete and awaiting authenticated BigQuery qualification.
Thirteen managed resource types now cover datasets, tables, views, routines,
connections, reservations, capacity commitments, assignments and scoped IAM.
The handwritten adapter uses method-correct BigQuery v2 PATCH/PUT operations,
`If-Match` preconditions, Connection/Reservation field masks, normalized import,
remote semantic drift detection, retained data defaults and explicit destructive
authority. Capacity commitments remain protected, retained and opt-in.

`ziac.gcp.AnalyticsWarehouse` composes a governed dataset with tables, views,
routines and least-privilege readers/writers. API and permission synthesis,
Cloud Asset identity, observed/managed reconciliation, canvas metadata, IAM
edge semantics and explicit query/storage/slot estimates are synchronized. The
local qualification applies the graph, imports it into an empty state, refreshes
to no-op and performs retention-aware cleanup. `scripts/qualify-bigquery.sh`
requires ADC and a project ending in `-ziac-disposable`, rejects commitment
purchases and emits exit 77 when credentials are absent. See
`docs/gcp-bigquery.md`.

The M63 local Testing v2 gate is complete with 602 discovered and executed
tests, 601 passed, one credential-gated skip, and zero failures, pending tests,
leaks or logged errors. The provider catalog reports 75 managed resources and
the public analytics-warehouse example compiles.

M64 is locally complete and awaiting authenticated Firestore qualification.
Five managed resource types cover Database, Index, Field, BackupSchedule and
database IAM. The handwritten Firestore Admin v1 adapter persists and resumes
long-running operations, preserves server-assigned index and schedule names,
uses database etags for compare-and-swap mutation, reverts field overrides
without deleting document data and normalizes remote output-only state before
drift comparison. Databases are protected and retained by default.

`ziac.gcp.DocumentStore` composes a database with typed indexes, TTL and index
field overrides, one daily and one weekly backup schedule, and exact
reader/writer IAM. API and permission synthesis, Cloud Asset database identity,
canvas topology and IAM edges, and explicit document operation, storage and
backup cost assumptions are synchronized. The local qualification applies the
graph, imports it into an empty second state, refreshes to no-op and performs
retention-aware cleanup. `scripts/qualify-firestore.sh` requires ADC and a
project ending in `-ziac-disposable`; otherwise it emits a structured exit-77
skip. See `docs/gcp-firestore.md`.

The M64 local Testing v2 gate is complete with 615 discovered and executed
tests, 614 passed, one credential-gated skip, and zero failures, pending tests,
leaks or logged errors. The provider catalog reports 80 managed resources and
the public document-store example compiles.

M65 is locally complete and awaiting authenticated Cloud SQL qualification.
Five managed resource types cover PostgreSQL primary instances, read replicas,
databases, built-in and IAM users, and client certificates. The handwritten
Cloud SQL Admin v1 adapter checkpoints Operations, resumes interrupted work,
uses `settingsVersion` for compare-and-swap updates, canonicalizes flags and
authorized networks, rejects unsupported private-IP removal and persists
passwords and one-time private keys only through secret-safe boundaries.

`ziac.gcp.ManagedPostgres` composes a protected primary, databases, users,
replicas, exact login/client IAM and an optional Secret Manager-backed client
certificate. Private Services Access remains explicit: the component refuses a
private primary without a declared connectivity dependency and never creates a
hidden VPC or peering mutation. API/permission synthesis, Cloud Asset instance
identity, canvas topology and IAM edges, and explicit compute/storage/backup/
egress estimates are synchronized. `scripts/qualify-cloud-sql.sh` requires ADC,
Cloud SQL Auth Proxy, PostgreSQL client tools and a project ending in
`-ziac-disposable`; otherwise it emits a structured exit-77 skip. See
`docs/gcp-cloud-sql.md`.

The M65 local Testing v2 gate is complete with 631 discovered and executed
tests, 630 passed, one credential-gated skip, and zero failures, pending tests,
leaks or logged errors. The provider catalog reports 85 managed resources and
the public managed-postgres example compiles.

M66 is locally complete and awaiting authenticated Spanner and Memorystore data
path qualification. Eleven managed resource types cover Spanner instances,
databases, backups, backup schedules and additive instance/database IAM;
classic Redis, Redis Cluster and ACL policies; and explicit Compute global
private-service ranges plus Service Networking connections.

`ziac.gcp.PrivateServiceAccess` owns the visible peering boundary,
`ziac.gcp.SpannerDatabase` composes retained data, backups and exact runtime
access, and tagged `ziac.gcp.MemorystoreCache` keeps classic Redis and Cluster
topologies disjoint. The lifecycle adapters resume Google LROs, normalize
remote defaults, enforce immutable and destructive boundaries, and persist
one-time Redis AUTH only into a declared Secret Manager version.

Permission synthesis distinguishes Compute global-address authority, Spanner's
two-permission backup creation and conditional Secret Manager writes. Cloud
Asset adoption maps only Google-supported identities; unsupported Spanner
backup schedules and Redis ACL policies remain generic observed assets. Canvas
metadata and explicit Spanner compute/storage/backup and Memorystore
capacity/egress estimates are synchronized. The installed example and
`scripts/qualify-data-services.sh` document the VPC-connected remote proof. See
`docs/gcp-spanner-memorystore.md`.

The M66 local Testing v2 gate is complete with 656 discovered and executed
tests, 655 passed, one credential-gated skip, and zero failures, pending tests,
leaks or logged errors. The release gate completed 131/131 steps, the provider
catalog reports 96 managed resources and the public data-services example
compiles.

M67 is locally complete and awaiting authenticated Workflows, API Gateway,
Identity Platform and Parameter Manager qualification. Eighteen managed
resource types cover Workflows, API/config/gateway and scoped IAM, the protected
Identity project singleton, tenants, project/tenant OIDC and SAML, tenant IAM,
and Parameter Manager parameters/templates with immutable versions.

`ziac.gcp.WorkflowProgram`, `ziac.gcp.ManagedApiGateway`, tagged
`ziac.gcp.IdentityRealm` and tagged `ziac.gcp.ParameterBundle` provide the
opinionated layer. Hardened adapters resume long-running operations, preserve
etags and immutable identities, reject singleton deletion, resolve secrets only
inside mutation scopes and verify declared SHA-256 values before sending API
documents or parameter payloads.

Permission synthesis derives all four APIs, exact deployer methods and separate
Workflows/Parameter Manager runtime access. Cloud Asset adoption maps only
Google-supported types; Parameter Manager templates remain generic observed
assets. Canvas metadata, IAM edges and explicit catalog-backed Workflows step,
API Gateway call and Identity MAU estimates are synchronized. The local receipt
proves apply/import/refresh/no-op/retention-aware cleanup. The fail-closed
`scripts/qualify-application-services.sh` requires ADC, explicit probe names
and a project ending in `-ziac-disposable`. See
`docs/gcp-application-services.md`.

The M67 local Testing v2 gate is complete with 671 discovered and executed
tests, 670 passed, one credential-gated skip, and zero failures, pending tests,
leaks or logged errors. The release gate completed 134/134 steps, the provider
catalog reports 114 managed resources and the public application-services
example compiles through the relocatable install gate.

M68 is locally complete and awaiting authenticated Compute Engine
qualification. Nine managed types cover zonal and regional persistent disks,
images, instances, immutable instance templates, zonal and regional managed
instance groups, and zonal and regional autoscalers. The handwritten adapter
checkpoints global, regional and zonal operations, grows disks through native
resize, uses current fingerprints for managed-group patches, normalizes remote
label edits, and treats images, instances and templates conservatively as
replacement resources.

Startup scripts cross a typed secret boundary: only a reference and SHA-256
remain in desired state, the payload is resolved and verified only for a
mutation, and the transient request body is zeroed. Instance deletion
protection is explicitly cleared before an authorized delete. `VirtualMachine`
and tagged `ManagedInstanceFleet` compose the opinionated layer without hidden
disk deletion or mixed regional/zonal identities.

Permission synthesis, supported Cloud Asset identities, observed/managed
reconciliation, canvas workload metadata, and explicit CPU, memory,
accelerator, disk and image configuration estimates are synchronized. The
installed example and `scripts/qualify-compute-workloads.sh` document the
remote proof boundary. See `docs/gcp-compute-workloads.md`.

The M68 local Testing v2 gate is complete with 688 discovered and executed
tests, 687 passed, one credential-gated skip, and zero failures, pending tests,
leaks or logged errors. The full release gate, public examples, Testing v2
migration guard and root TypeScript checks pass. The provider catalog reports
123 managed resources.
