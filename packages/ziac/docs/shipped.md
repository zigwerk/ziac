# Ziac Shipped Capability Ledger

This is the canonical record of Ziac work shipped through M83. The current
forward plan lives in [`roadmap.md`](roadmap.md).

- **Ledger date:** 2026-07-15
- **Integrated revision:** `9c21d9c8`
- **Provider catalog:** 253 managed GCP resource types
- **Deterministic package gate:** 974 discovered and executed, 973 passed, one
  credential-gated skip, zero failures, pending tests, leaks or logged errors

## Evidence Vocabulary

- **Shipped** means the implementation is merged to `main` and covered by its
  deterministic package or product gates.
- **Shipped, qualification required** means the implementation, safety guards
  and fail-closed runner are shipped, but authenticated external evidence has
  not yet been produced.
- **Qualified** is reserved for a complete redacted receipt from the declared
  real-cloud environment.

Credential-free evidence is never presented as authenticated cloud proof.

## Milestone Ledger

| Milestones | Status | Delivered outcome |
| --- | --- | --- |
| M0-M3 | Shipped | Engine, state, planner, provider lifecycle, CLI, comptime contracts, HTTP transport and authentication kernels |
| M4-M9 | Shipped, qualification required | GCP primitives, global Cloud Run, CockroachDB, Zig source deployment, operations, Google RPC and GCP intelligence |
| M10 | Shipped | Local visual infrastructure Workbench, 3D topology canvas and global map |
| M11-M15 | Shipped | Agent authority, local hot reload, causal logs, immutable watch deploy and governed agent tools |
| M16-M17 | Shipped, qualification required | Ephemeral-environment and existing-estate vertical slices; hosted paid-user qualification remains |
| M18-M25 | Shipped at the local product gate | Installable client, standalone dashboard, MCP, real plan/apply/watch bridge, Estate Pro and cost kernels |
| M26-M40 | Shipped at the credential-free self-host gate | Local-first SaaS architecture and typed Ziac Cloud bootstrap/control-plane/data/billing projects |
| M41-M46 | Shipped | Monorepo discovery, one merged canvas, graph-safe slices and incremental workspace patches |
| M47-M55 | Shipped at the credential-free gate | Real dashboard operations, self-host gate, official GCP research agent and relocatable agent development kit |
| M56-M83 | Shipped, qualification required | Three-layer practical GCP provider coverage with 253 managed resource types |

## Engine And Language Contracts

The following foundations are shipped:

- canonical resource values, stable input hashes and deterministic graph IDs;
- typed desired, observed and persisted state with physical IDs and outputs;
- refresh-aware create, update, replacement, delete, import and no-op planning;
- dependency-ordered bounded execution and reverse dependency destruction;
- atomic local state, GCS remote state, generation locking, writer leases,
  checkpoints, interruption resume and explicit unlock;
- immutable saved plans, graph and operation digests, destructive approval and
  secret-reference-only persistence;
- typed public and secret outputs with automatic dependency derivation;
- canonical ZigEffect service tags, layers, one managed runtime per process,
  requirements-typed command effects, durable NenDB causal recording, and
  compile-time requirement/wiring diagnostics;
- typed provider failures, long-running operations, retries, cancellation,
  deadlines, idempotency and redacted receipts; and
- bounded `ziac.provider.rpc.v1` subprocess isolation with exact identity,
  capability, request-ID, state-reference, error and diagnostic transfer.

Primary references:

- [`architecture.md`](architecture.md)
- [`remote-state.md`](remote-state.md)
- [`saved-plans.md`](saved-plans.md)
- [`authentication.md`](authentication.md)
- [`provider-rpc.md`](provider-rpc.md)

## Global Zig Application Platform

Ziac ships the complete typed topology for globally routed Zig backends:

- deterministic Zig source archives and immutable OCI images;
- Cloud Build and Artifact Registry source-to-image delivery;
- Cloud Run services, jobs and worker pools;
- native Cloud Run multi-region selection or controlled regional fleets;
- serverless NEGs, backend services, URL maps, HTTPS proxies, forwarding rules,
  managed certificates and Cloud DNS;
- guarded canary rollout, revision readiness, traffic promotion, rollback and
  interrupted-operation recovery;
- direct VPC egress, static NAT, private DNS and Private Service Connect; and
- high-level `ContainerService`, `ZigService`, workload and application-platform
  components.

The generated Zig 0.16 musl runtime has passed amd64 and arm64 non-root
container startup and liveness checks. Real multi-region failover and the full
source-to-Cloud-Run acceptance journey remain in the qualification ledger.

Primary references:

- [`zig-service.md`](zig-service.md)
- [`container-service.md`](container-service.md)
- [`cloud-run.md`](cloud-run.md)
- [`rollouts-recovery.md`](rollouts-recovery.md)
- [`gcp-application-platform.md`](gcp-application-platform.md)

## CockroachDB Platform

The CockroachDB provider and application data layer ship:

- existing and Ziac-provisioned Basic, Standard and Advanced clusters;
- topology, locality, connection and retained-ownership state;
- SQL users, databases, exact grants and immutable ordered migrations;
- native verified-TLS pooled SQL with transaction retries;
- Secret Manager connection bindings without plaintext in state;
- public static-egress and multi-region Private Service Connect topologies; and
- high-level application database composition.

Scripted provider, composition and disposable local Cockroach gates pass.
Authenticated Cockroach Cloud creation, PSC acceptance and regional Cloud Run
data-path evidence remain qualification work.

Primary references:

- [`cockroach-cluster.md`](cockroach-cluster.md)
- [`cockroach-sql.md`](cockroach-sql.md)
- [`private-service-connect.md`](private-service-connect.md)
- [`cockroach-connection-secret.md`](cockroach-connection-secret.md)

## Agent-First Development Platform

The local developer and agent loop ships:

- installable `ziac` CLI, dashboard host, MCP server and package sources;
- `ziac init` for standalone and monorepo infrastructure projects;
- generated Codex, Claude Code and Gemini skills and harness configuration;
- the read-only official GCP Developer Knowledge researcher;
- provider creator, maintainer and independent qualifier agents with shared
  first-party and third-party RPC development skills;
- MCP initialization, tool discovery, bounded stdio, capability envelopes and
  fixed-argv process authority;
- manifest-owned local build, process, readiness and proxy supervision;
- `ziac dev` hot reload with prior-generation preservation;
- `deploy --watch` with immutable digests, no-traffic readiness and exact
  revision promotion;
- bounded redacted causal logs, diagnosis, proposals, replay, verification and
  handoff artifacts; and
- deterministic infrastructure fault scenarios and exact-plan approval.

Primary references:

- [`agent-development.md`](agent-development.md)
- [`agent-development-kit.md`](agent-development-kit.md)
- [`provider-development-kit.md`](provider-development-kit.md)
- [`gcp-developer-research.md`](gcp-developer-research.md)
- [`rapid-development.md`](rapid-development.md)

## Local Visual Workbench

The local dashboard ships as a real developer tool rather than a fixture-only
console:

- native host bindings for project and workspace artifacts;
- fixed-argv plan, apply, watch, status and cancellation operations;
- one merged monorepo canvas with project, dependency and connected slices;
- incremental affected-project compilation and monotonic workspace patches;
- a scalable orthographic Three.js topology with provider resource blocks,
  account/VPC/region slabs and flat semantic dependency traces;
- a monochrome global map for front doors, Cloud Run and Cockroach localities;
- synchronized architecture, network, VPC, dependency, estate and ownership
  filters;
- managed, referenced and observed ownership boundaries; and
- compact causal operations, resource inspection and deployment views.

Primary reference: [`visual-workbench.md`](visual-workbench.md).

## Estate Pro And Cost Kernels

The local-first paid-product foundations are shipped, but the commercial
service is not yet production-qualified:

- installed-app Google PKCE and OIDC verification contracts;
- account, session, entitlement, connection and append-only audit models;
- Cloud KMS credential-vault boundary and Cockroach persistence schema;
- bounded Cloud Asset Inventory discovery and read-only graph generation;
- explicit managed, referenced, observed and adoption-candidate states;
- configuration estimates, projected month-end cost and actual billed cost as
  separate types;
- Cloud Billing catalog pagination and tier preservation;
- BigQuery detailed-export queries, exact integer-micro parsing and attribution
  coverage; and
- dashboard treatment that reports unavailable cost instead of fabricating a
  value.

The hosted callback, billing lifecycle, signed feature leases, scheduled scans,
customer reports and first paid-user receipt are forward work.

Primary reference: [`estate-control-plane.md`](estate-control-plane.md).

## Ziac Cloud Self-Host Foundation

`ziac init --preset ziac-cloud` ships a typed four-project workspace:

1. bootstrap APIs, state, KMS, Artifact Registry and deployer IAM;
2. Cockroach data, grants, secrets and migrations;
3. the globally routed control-plane service; and
4. the private billing worker with Scheduler OIDC.

The installed self-host gate compiles every project, merges the workspace
canvas, builds hosted Linux images and resolves immutable image digests. The
authenticated production deployment is M85.

## Three-Layer GCP Provider

The provider catalog contains 253 managed resource types across three layers:

1. pinned protobuf and Discovery contracts provide broad low-level surface;
2. handwritten providers harden lifecycle, import, masks, etags, LROs,
   replacements, IAM, safety and cleanup; and
3. opinionated components compile common platform architectures.

Shipped families include:

- projects, service usage, organization policy, tags and access boundaries;
- IAM, service accounts, workload identity and resource-scoped policies;
- Cloud Storage, Secret Manager, KMS, Private CA and Security Command Center;
- Cloud Run, Compute Engine, load balancing, DNS, VPC, NAT, PSC and connectivity;
- GKE and container platform resources;
- Artifact Registry, Cloud Build and Cloud Deploy;
- Cloud SQL, Firestore, Spanner and Memorystore;
- Pub/Sub, Cloud Tasks, Eventarc, Workflows and connectors;
- BigQuery, Dataproc, Dataform and data pipelines;
- Logging, Monitoring and operational resources; and
- stable Vertex AI datasets, models, endpoints, vector search, feature platform,
  Tensorboard and metadata resources.

Every catalog entry exposes support stage, capability, API, permission,
contract provenance, estate identity and visual metadata. Cost information is
explicitly estimated, measured or unavailable.

Primary reference: [`gcp-provider-coverage.md`](gcp-provider-coverage.md).

## Qualification Debt Carried Into M84

The following are not claimed as qualified:

| Boundary | Shipped evidence | Missing evidence |
| --- | --- | --- |
| Core GCP lifecycle | Scripted transports, deterministic providers, fail-closed runners | Authenticated create/update/import/no-op/delete receipts |
| Global Cloud Run | Graph, provider, readiness and rollback tests | Real TLS, regional failover/failback and cleanup |
| CockroachDB | Scripted Cloud API and local TLS SQL | Cloud cluster, PSC, regional read/write and retention receipt |
| Ziac Cloud | Four-project self-host gate | Bootstrap-to-remote-state production deployment and health receipt |
| Estate Pro | Auth, vault, CAI and billing kernels | Paid-user OAuth, project connection, scan, billing and revoke receipt |
| External client | Installed-prefix isolated acceptance | Published install from a clean external repository and global deployment |

These gates are the first milestone in the current
[`roadmap.md`](roadmap.md), not unfinished M0-M83 implementation tasks.

## Historical Records

Dated designs and plans under `docs/superpowers/` preserve decisions, TDD
sequence and milestone-specific evidence. Their original checkboxes are
historical execution notes and are not current status sources. This ledger and
the current roadmap are authoritative.

Key programme records:

- `docs/superpowers/plans/2026-07-10-ziac-e2e-delivery.md`
- `docs/superpowers/plans/2026-07-12-ziac-product-completion.md`
- `docs/superpowers/plans/2026-07-12-ziac-local-first-saas-self-hosting.md`
- `docs/superpowers/plans/2026-07-12-ziac-monorepo-workspace-dashboard.md`
- `docs/superpowers/plans/2026-07-12-ziac-cloud-bootstrap-completion.md`
- `docs/superpowers/plans/2026-07-13-ziac-gcp-provider-coverage.md`
