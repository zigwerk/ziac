# Ziac Local-First SaaS And Self-Hosting Design

Date: 2026-07-12
Status: validated through product discussion

## Thesis

Ziac is not a browser cloud console. Its primary product is a local infrastructure
development environment whose 3D model is continuously compiled from the user's
working tree, agent activity, saved plans, observed provider state, and causal
runtime evidence.

The paid product is a hosted intelligence and trust plane. It supplies durable
Google connections, scheduled estate discovery, cost ingestion, history, team
access, reports, and signed entitlements to the local workbench. It does not take
ownership of source code, local agent sessions, or unapplied plans.

Ziac must deploy this hosted plane with Ziac itself. After a deliberately small
manual bootstrap, the control plane, workers, web surfaces, data plane, security
resources, and observability are represented by typed Ziac projects and updated
through the same plan, authority, causal evidence, and dashboard path offered to
customers.

## Product Planes

### Local developer plane

The local plane owns:

- application and infrastructure source;
- comptime App.Env, binding, provider, scope, and output validation;
- incremental program compilation and semantic graph diffs;
- local desired state, saved plans, approvals, and apply authority;
- agent and MCP sessions;
- local and provider causal logs;
- the interactive 3D canvas and global map;
- local hot reload and guarded cloud watch deploys.

The default product command becomes `ziac dev`, which can launch the application
runtime, MCP server, graph watcher, and dashboard together. `ziac dashboard`
remains available for a visualization-only session.

### Hosted intelligence plane

The hosted plane owns:

- accounts, organizations, memberships, and devices;
- subscription and entitlement truth;
- encrypted Google OAuth refresh credentials;
- connected projects, folders, and organizations;
- scheduled Cloud Asset Inventory scans;
- Cloud Billing Catalog, Pricing API, and BigQuery export ingestion;
- immutable estate snapshots, topology diffs, reports, and retention;
- team-visible redacted evidence;
- signed, short-lived feature leases for local clients;
- operational audit, quotas, abuse controls, and support tooling.

The hosted plane never returns Google refresh credentials, KMS metadata, raw
authorization headers, or secret values to the browser or local dashboard.

### Hosted web surfaces

The public SolidStart site remains a separately deployable marketing surface.
A small customer account portal handles billing, members, Google connections,
devices, and security. It links back to `ziac dashboard`; it does not duplicate
the infrastructure canvas. A separately deployed internal admin console handles
entitlements, failed jobs, webhook health, connection revocation, audit review,
and support actions under stronger workforce identity and authorization.

## Realtime Local Model

Every source save produces a bounded local pipeline:

1. Hash only manifest-owned source roots.
2. Compile `ziac.program.v1` through the project's fixed argv compiler.
3. Preserve the last valid graph if compilation fails.
4. Produce a semantic graph diff and `ziac.plan.v1` preview.
5. Atomically publish a new `ziac.visual.v1` artifact and revision envelope.
6. Notify the local WebUI and update proposed objects without resetting camera,
   selection, filters, or investigation state.
7. Attach diagnostics to resources, bindings, and source references.
8. After explicit authority, stream provider operations back into the same model.

The revision envelope records content digests for program, plan, visual artifact,
session, logs, costs, and observed estate. Consumers fetch only changed artifacts.
Malformed, oversized, secret-bearing, incomplete, or out-of-order revisions fail
closed while the last complete revision remains visible.

## Paid Feature Boundary

Paid UI visibility is driven by a signed, short-lived capability lease containing
tenant, device, feature, quota, retention, and expiry claims. The local Zig host
verifies the signature and the hosted API independently enforces every request.
Local flags are presentation, not the security or payment boundary.

Defensible paid capabilities depend on hosted work: managed Google access,
scheduled scans, actual billing ingestion, history, reports, teams, organization
scope, and retained evidence. Core local compilation, plan rendering, and a manual
ADC-backed scan remain useful without a subscription.

## Google Connection Model

1. `ziac login` opens the hosted identity flow and returns a one-time local
   exchange code to a loopback callback.
2. The local client exchanges it for a Ziac device session stored in the OS
   credential store.
3. Connecting GCP uses the hosted Google OAuth callback with offline access.
4. The control plane verifies OIDC, creates the account before credential
   persistence, encrypts the refresh token with request and response CRC32C
   verification, and stores ciphertext only.
5. A connection is created only after project identity and the minimum Cloud
   Asset permission are preflighted with a short-lived access token.
6. Workers decrypt only inside the trusted service boundary, refresh short-lived
   access tokens, scan, redact, persist snapshots, and erase plaintext.
7. Revocation immediately disables future jobs and destroys or invalidates the
   stored credential.

## Cost Truth Model

Every displayed amount is one of:

- `configuration_estimate`: explicit usage assumptions matched to catalog or
  contract prices;
- `projected_month_end`: partial billing-export spend with projection method and
  observation window;
- `actual_billed`: detailed billing-export rows including credits.

The UI must carry origin, currency, confidence, observation time, pricing source,
credits, and coverage gaps. Type-based placeholder ranges and sample telemetry
are permitted only in explicitly selected samples and are never loaded by a live
host.

## Self-Hosting Topology

The initial Ziac-owned production project is split into protected stacks:

- `ziac-bootstrap`: state bucket, KMS root, deployer identity, WIF, and protected
  project services;
- `ziac-control-plane`: global Cloud Run API and Google OAuth callback;
- `ziac-workers`: scan, billing, report, and cleanup workers plus task queues;
- `ziac-data`: Cockroach databases/users, encrypted object storage, and retention;
- `ziac-web`: account portal and internal admin deployments;
- `ziac-observability`: logs, metrics, SLOs, budgets, alerts, and audit sinks.

Bootstrap is the only exceptional path. It must be a bounded, reviewable command
that creates the minimum trust root and immediately imports it into protected
Ziac state. All later changes use ordinary saved plans and provider execution.

## Security Invariants

- Local HTTP binds to loopback, uses an unguessable session secret, validates
  origin, and never exposes mutation APIs to arbitrary browser origins.
- OAuth challenges are rate-limited, expiring, one-use, and garbage-collected.
- Account creation precedes foreign-keyed credential persistence.
- KMS request and response CRC32C integrity is verified.
- Entitlements are updated only by authenticated, replay-safe billing events or
  audited operator actions.
- Connection creation verifies ownership and live provider permission.
- Scheduled jobs are tenant-scoped, idempotent, bounded, retryable, and auditable.
- Customer artifacts are encrypted, redacted, versioned, and retention-limited.
- Admin access is separate from customer sessions and requires workforce RBAC.
- Feature leases cannot expand provider mutation authority.

## Completion Definition

The programme is complete only when a new paid user can install Ziac, sign in,
connect a disposable GCP project, watch a local canvas populate, edit a Ziac
project and see the desired graph update in realtime, approve and deploy a global
Cloud Run service, connect billing export, receive honest cost data, and revoke
the connection. The same release must deploy the Ziac hosted plane from its own
typed self-host project and pass cleanup, rollback, failover, secret scanning,
and causal evidence gates.
