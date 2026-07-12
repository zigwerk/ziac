# Ziac Local-First SaaS And Self-Hosting Implementation Programme

Date: 2026-07-12
Design: `docs/superpowers/specs/2026-07-12-ziac-local-first-saas-self-hosting-design.md`

## Delivery Rules

- Every milestone begins with deterministic failing acceptance coverage.
- Live provider evidence never substitutes for deterministic contracts, and
  deterministic fixtures never substitute for required live evidence.
- Customer source, secrets, refresh tokens, authorization headers, and raw billing
  exports never enter browser artifacts or causal logs.
- The self-host project consumes only public Ziac APIs.
- A milestone is complete only when its listed gate passes and the roadmap links
  the durable evidence.

## Programme

### M26: Production blocker closure

- Correct Cloud KMS request/response CRC32C handling.
- Create accounts before foreign-keyed credential persistence.
- Make callback recovery and audit outcomes explicit.
- Add bounded OAuth challenge cleanup and abuse controls.
- Gate: a first-time identity completes callback persistence against real
  Cockroach and KMS-compatible contracts without plaintext retention.

### M27: Customer GCP connection lifecycle

- Add create, list, preflight, resolve, rotate, and revoke operations.
- Decrypt credentials only inside a scoped worker operation.
- Exchange refresh tokens for short-lived access tokens.
- Verify project identity, Cloud Asset permission, service usage, and billing
  project before marking a connection ready.
- Gate: a newly connected disposable project can be scanned without local ADC.

### M28: Subscription and signed feature leases

- Add replay-safe billing webhook ingestion and entitlement history.
- Add audited operator grants for support and development.
- Issue device-bound, short-lived signed feature leases with offline grace.
- Enforce subscription and quotas on every hosted operation.
- Gate: renewal, cancellation, expiry, replay, clock skew, and revoked-device
  scenarios fail or succeed deterministically and agree with the billing provider.

### M29: Realtime local graph runtime

- Watch manifest-owned roots and compile affected programs.
- Preserve last-known-good state on compiler failure.
- Publish revisioned program, plan, visual, log, estate, and cost digests.
- Push or long-poll only changed artifacts into the WebUI.
- Preserve canvas interaction state across revisions.
- Gate: one file save changes the canvas in under 250 ms after compiler completion,
  with no provider calls and no full-page reload.

### M30: Dashboard operation bridge

- Replace timer-based deploy simulation with plan/save/apply/watch APIs.
- Bind operation status, cancellation, approval, and exact-plan identity.
- Stream compile, plan, build, revision, traffic, log, and diagnosis events.
- Protect loopback APIs with origin and session checks.
- Gate: the local dashboard drives a fake provider apply and a guarded live watch
  deployment through the same CLI kernel.

### M31: Estate snapshot service

- Add tenant-scoped scheduled scan jobs and immutable snapshots.
- Support project, folder, and organization scopes with explicit permissions.
- Add topology diffs, ownership projection, retention, and deletion.
- Merge hosted observations with local desired and managed graphs.
- Gate: scheduled and manual scans converge to the same redacted graph and never
  authorize mutation of observed resources.

### M32: Honest cost intelligence

- Implement Cloud Billing Catalog and contract Pricing adapters.
- Correct unit conversion, tiering, currencies, effective times, and regions.
- Ingest detailed BigQuery billing exports asynchronously.
- Attribute covered spend and retain explicit unattributed totals.
- Remove hard-coded live cost and operational metrics from the dashboard.
- Gate: estimates, projections, actuals, credits, and coverage gaps reconcile
  against a disposable billing export without relabelling one another.

### M33: Customer account portal

- Build organization, team, device, subscription, connection, retention, and
  security management.
- Keep the canvas local; provide commands and deep links back to the local host.
- Add session revocation and data export/deletion.
- Gate: a customer can administer the paid lifecycle without maintainer help.

### M34: Internal admin console

- Deploy separately with workforce identity and role separation.
- Expose bounded customer, entitlement, webhook, job, connection, audit, and
  support views without credential material.
- Require reasoned, audited, expiring elevation for support actions.
- Gate: customer sessions cannot reach admin APIs and all operator writes appear
  in immutable audit evidence.

### M35: Self-host bootstrap

- Add the typed `self-host` Ziac project and stack catalogue.
- Define the minimum manual bootstrap and immediate state adoption.
- Protect state, KMS, WIF, DNS, and data resources from accidental deletion.
- Gate: a clean checkout compiles every self-host stack and produces a reviewed
  bootstrap plan with no fixture registry.

### M36: Self-host control plane and workers

- Deploy the API, OAuth callback, scan, billing, reports, and cleanup workers.
- Provision queues, service identities, KMS access, secrets, and Cockroach data.
- Use immutable Zig images and guarded global Cloud Run traffic promotion.
- Gate: Ziac updates its own control plane through a saved Ziac plan.

### M37: Team and organization product

- Add memberships, roles, invitations, shared connections, project policies,
  quotas, and retained team evidence.
- Keep local mutation authority device- and environment-specific.
- Gate: membership changes immediately affect hosted access without silently
  expanding local provider authority.

### M38: Reports, alerts, and import conversion

- Add cost, change, waste, topology, and security reports.
- Add scheduled alerts with causal links to the responsible graph changes.
- Generate approximate Ziac code and zero-change adoption candidates.
- Gate: imported code cannot claim ownership until a no-change plan is proved.

### M39: Unified authenticated qualification

- Run sign-in, subscription, connection, scan, cost, local edit, canvas refresh,
  global deploy, Cockroach read/write, failover, rollback, no-op, revoke, and
  cleanup in one disposable environment.
- Capture redacted Testing v2, provider, dashboard, billing, and audit evidence.
- Gate: the complete paid journey passes from a clean checkout in one run.

### M40: Private beta release

- Publish installers, schema versions, migrations, security model, operator
  runbooks, pricing, limits, support boundaries, and incident procedures.
- Replace the fake beta form with durable consented signup.
- Audit every marketing claim against qualified evidence.
- Gate: a new external user completes the journey without fixtures or maintainer
  intervention.

## Immediate Execution Slice

This branch begins M26, establishes the M27 connection persistence contract,
adds the M29 local revision contract, and creates the first M35 self-host project.
All later milestones remain explicitly open until their gates pass.
