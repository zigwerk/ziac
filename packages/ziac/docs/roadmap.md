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

M18 user-project compilation is complete locally. `ziac init` generates an
external Zig 0.16 project with a real `gcp.global.ZigService`, Testing v2,
project-owned agent skills, and a fixed program compiler. `ziac check`, plan,
fake apply, and no-op replay consume the integrity-bound `ziac.program.v1`
artifact through the installed CLI; built-in stacks are no longer selected when
a project compiler is declared.

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

M22 Estate Pro is complete at the credential-free implementation gate. The server-side authorization
kernel now hashes bearer assertions, enforces Google-subject ownership and Pro
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

M23 cost intelligence is in active implementation. The shared cost contract now
distinguishes configuration estimates, projected month-end cost and actual
billed cost at the type level. Estimates require explicit SKU, region, unit and
usage assumptions; actuals include exported credits; projections can derive only
from actual billing data; and missing usage returns unavailable rather than a
fabricated range. Catalog pagination, BigQuery ingestion, visual-artifact
projection and replacement of dashboard fixture guesses remain open.

No milestone is described as externally qualified until its authenticated live
gate has produced a complete redacted evidence bundle. Credential-free code
completion and external qualification remain separate roadmap states.
