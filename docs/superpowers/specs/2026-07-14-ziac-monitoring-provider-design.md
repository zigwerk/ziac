# Ziac M73 Monitoring Provider Design

Date: 2026-07-14
Status: approved for implementation by the provider-coverage roadmap
Roadmap: `docs/superpowers/plans/2026-07-13-ziac-gcp-provider-coverage.md`

## Objective

Make production observability part of the compiled infrastructure graph rather
than a dashboard assembled after deployment. M73 applies Ziac's three layers:

1. typed declarations for stable Cloud Monitoring contracts;
2. handwritten lifecycle adapters for drift, import, secret handling and
   optimistic concurrency;
3. an opinionated service-observability component that wires SLOs, probes,
   alerts and dashboards around an application.

M73 adds six managed resource types:

- `gcp.monitoring.AlertPolicy`
- `gcp.monitoring.UptimeCheck`
- `gcp.monitoring.NotificationChannel`
- `gcp.monitoring.Dashboard`
- `gcp.monitoring.Service`
- `gcp.monitoring.ServiceLevelObjective`

## Contract Sources

The provider pins both Google Discovery contracts used by Monitoring:

| API | Revision | SHA-256 |
| --- | --- | --- |
| Monitoring v3 | `20260705` | `9419509a1ced59a7bda62d54135551cbf0f9c68dce0de8185a6d1a10beb85394` |
| Monitoring v1 dashboards | `20260705` | `e75eaa5aaaea322cdf03d2970edcb37cf4b1a832c50fcc4a450da5778c73d5c5` |

The v3 contract owns alert policies, channels, checks, services and SLOs. The
dashboard API remains v1. Contract upgrades require a semantic provenance diff.

## Typed Declarations

`AlertPolicy` models threshold, absence, PromQL and log-match conditions,
combiners, severity, documentation, notification strategy, explicit channel
outputs and user labels. Threshold conditions model comparison, duration,
alignment, reduction and trigger policy. Every condition has a stable local ID
so reordering does not silently change the intended alert.

`UptimeCheck` models HTTP or TCP probes against a typed monitored resource,
period, timeout, checker type, selected regions, response status and content
matchers. HTTP headers and basic-auth passwords can be secret references. Secret
values are resolved only while building a mutation request and never enter
desired state, observed state, plans, logs or receipts.

`NotificationChannel` separates ordinary labels from secret labels for webhook,
Slack and third-party credentials. Verification remains a separate authorized
operation and is not faked by create. Remote masked secret labels retain their
desired secret references during normalization.

`Dashboard` starts with the common mosaic layout and typed text, XY chart,
scorecard, logs, alert-chart and incident-list widgets. Queries and widget
relationships stay structured rather than accepting an opaque dashboard JSON
blob. The provider carries the current dashboard etag on update.

`Service` supports custom, basic, Cloud Run and GKE workload identities.
`ServiceLevelObjective` supports basic availability/latency, request-ratio,
distribution-cut and windows-based indicators with either rolling or calendar
periods. Service and SLO IDs are caller-selected and therefore canonical.

## Lifecycle And Drift

Monitoring mutations are synchronous REST operations. Alert policies, channels,
checks and dashboards receive server-generated physical IDs; create responses
must be checkpointed into state before any follow-up read. Services and SLOs use
caller-selected IDs on create. Imports require complete canonical names.

All resources normalize only declared mutable fields and Google defaults.
Identity changes replace; other semantic changes patch with exact update masks.
Dashboard updates use the latest remote etag and retry bounded `409`/`412`
conflicts after a fresh read. Notification channels and uptime checks preserve
secret references while comparing public remote state. Deletes treat `404` as
success. Channel force-deletion is explicit.

## Opinionated Component

`ServiceObservability` composes a Monitoring service, availability SLO,
optional latency SLO, public uptime check, host-scoped endpoint alert policy and
an operator dashboard. It accepts notification-channel outputs, an endpoint
and a typed Cloud Run, GKE, basic or custom service identity. The component does
not create paging destinations or grant notification access implicitly.

The component emits visible graph edges for service-to-SLO ownership, endpoint
probing, probe-policy evaluation, policy notification and dashboard
visualization. It is suitable for one regional service or one logical global
service spanning several Cloud Run regions. Burn-rate policies remain explicit
typed primitives until Ziac can compile a verified Google query for each SLI
kind rather than guessing at a universal metric selector.

## Product Integration

Permission synthesis emits exact `monitoring.alertPolicies.*`,
`monitoring.uptimeCheckConfigs.*`, `monitoring.notificationChannels.*`,
`monitoring.dashboards.*`, `monitoring.services.*` and `monitoring.slos.*`
permissions. Channel verification permissions are emitted only for an explicit
verification operation, not ordinary provisioning.

Cloud Asset Inventory supports `monitoring.googleapis.com/AlertPolicy`,
`monitoring.googleapis.com/Dashboard`,
`monitoring.googleapis.com/NotificationChannel` and
`monitoring.googleapis.com/UptimeCheckConfig`. Monitoring services and SLOs
remain API-observed and cannot be adopted from an invented Asset type.

The cost model exposes uptime executions per selected checker region, alert
metric references and query points separately. It records Google's free
allotments and the `2026-08-01` alert-policy pricing effective date as
assumptions. Dashboard, channel, service and SLO objects have no fabricated
resource fee. Billing export remains authoritative.

## Qualification

Local deterministic qualification proves create, read, normalized no-op,
secret redaction, etag retry, second-state import and cleanup. The authenticated
runner requires ADC, a billing-enabled disposable project, an externally
reachable probe target and a customer-controlled notification destination. It
must observe successful uptime checks, an enabled policy, a readable dashboard,
an SLO with healthy data, import no-op and complete cleanup before emitting
authenticated evidence.

## Non-Goals

- Metric descriptors, log-based metrics or log storage; M74 owns Logging.
- Managed Service for Prometheus collectors or Kubernetes custom resources.
- Notification-channel verification secrets in source or state.
- Every dashboard widget in the first hardened slice; unsupported widgets are
  visible coverage exclusions, not opaque JSON escape hatches.
- Claiming configuration estimates as actual billed cost.
