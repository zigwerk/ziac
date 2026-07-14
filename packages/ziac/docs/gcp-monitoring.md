# GCP Monitoring

Ziac M73 manages Cloud Monitoring alerts, uptime checks, notification channels,
dashboards, services and service-level objectives through typed declarations,
a synchronous lifecycle adapter and an opinionated observability component.

## Managed Resources

- `gcp.monitoring.AlertPolicy`
- `gcp.monitoring.UptimeCheck`
- `gcp.monitoring.NotificationChannel`
- `gcp.monitoring.Dashboard`
- `gcp.monitoring.Service`
- `gcp.monitoring.ServiceLevelObjective`

The contracts are pinned to the Monitoring v3 and dashboard v1 Discovery
documents. Server-generated policy, channel, uptime and dashboard IDs are kept
as physical state. Services and SLOs retain caller-selected IDs. Updates use
exact masks; dashboard updates carry the latest etag and retry bounded
precondition conflicts.

Notification channel secret labels and uptime credentials are references, not
plain strings. The provider resolves them only inside a mutation request and
never writes resolved bytes into desired inputs, observed inputs, outputs,
diagnostics or qualification receipts.

## Service Observability

`ziac.gcp.ServiceObservability` compiles one Monitoring service, availability
SLO, optional latency SLO, public endpoint probe, endpoint-failure policy and
mosaic dashboard. Notification channels remain explicit resources or outputs.
The graph records service-to-SLO, probe target, policy evaluation, notification
and dashboard-visualisation relationships so agents and the local canvas can
explain why each object exists.

The first component alert is deliberately endpoint scoped. It filters the
uptime metric by the validated endpoint host rather than aggregating all checks
in a project. More specialized burn-rate policies can be built directly from
the typed alert and SLO primitives.

## Estate And Canvas

Cloud Asset Inventory officially exposes these adoptable types:

- `monitoring.googleapis.com/AlertPolicy`
- `monitoring.googleapis.com/Dashboard`
- `monitoring.googleapis.com/NotificationChannel`
- `monitoring.googleapis.com/UptimeCheckConfig`

Monitoring services and SLOs are managed and rendered when present in a Ziac
graph, but are not claimed as Cloud Asset discoveries. The canvas includes
resource role, policy severity, probe timing, SLO goal and dashboard/widget
counts without rendering secret channel labels or request credentials.

## Permissions And Costs

Permission synthesis emits the exact `monitoring.alertPolicies.*`,
`monitoring.uptimeCheckConfigs.*`, `monitoring.notificationChannels.*`,
`monitoring.dashboards.*`, `monitoring.services.*` and `monitoring.slos.*`
lifecycle permissions used by the graph.

Configuration estimates model billable uptime-check executions after an
explicit free allotment and alert-policy metric-reference months. Dashboard,
channel, service and SLO objects do not receive invented object fees. Query
volume and actual contract pricing require telemetry or Cloud Billing export;
all local figures remain configuration estimates.

## Qualification

`scripts/qualify-monitoring.sh` is the authenticated boundary. It requires ADC,
an explicitly disposable project, a customer-owned qualification stack and
the exact graph resource IDs to inspect. It applies the saved plan, reads every
remote Monitoring object, probes the public endpoint, imports a second state,
requires a refreshed no-op plan and cleans up before emitting
`authenticated=true`.

Without that environment it exits `77` with a structured skip. Deterministic
tests prove lifecycle and local evidence without claiming remote alert firing,
notification delivery or SLO time-series evidence.

Primary Google references:

- https://cloud.google.com/monitoring/api/ref_v3/rest
- https://cloud.google.com/monitoring/api/ref_v3/rest/v1/projects.dashboards
- https://cloud.google.com/monitoring/api/resources
- https://cloud.google.com/monitoring/pricing
