# GCP Logging

Ziac M74 manages Cloud Logging storage, access views, project routes,
exclusions and log-based metrics as one compiled graph. It combines broad
typed declarations with a handwritten lifecycle adapter for the settings that
are irreversible or server-generated.

## Managed Resources

- `gcp.logging.Bucket`
- `gcp.logging.View`
- `gcp.logging.Sink`
- `gcp.logging.Exclusion`
- `gcp.logging.Metric`

The wire contract is pinned to Logging v2 Discovery revision `20260706`.
Bucket creation and update use resumable asynchronous operations. Views, sinks,
project exclusions and metrics use their native synchronous methods. Imports
accept only the canonical physical identity implied by the typed declaration.

Bucket location and ID are immutable. Analytics and lock settings can move only
from disabled to enabled. A locked bucket cannot change retention, and an
enabled CMEK configuration cannot be removed. Metric kind, value type, label
keys and label types are immutable schema. Those constraints are checked before
the provider sends a mutation.

## Application Log Platform

`ziac.gcp.ApplicationLogPlatform` composes a durable bucket, restricted views,
a project sink into that bucket, inline route exclusions, independent project
exclusions and counter or distribution log metrics. Bucket, view, route and
metric references remain typed outputs, so the graph records why each object
depends on the bucket.

The sink requests a unique writer identity and publishes it as an output.
Destinations outside the same project remain explicit low-level declarations;
callers must grant the returned identity the exact destination permission.
Ziac does not hide cross-project authority behind the component.

## Estate And Canvas

Cloud Asset Inventory officially exposes:

- `logging.googleapis.com/LogBucket`
- `logging.googleapis.com/LogView`
- `logging.googleapis.com/LogMetric`
- `logging.googleapis.com/LogSink`

Project exclusions are managed and rendered but are not claimed as Cloud Asset
discoveries. Logging assets can be delayed in Cloud Asset Inventory, so a scan
records observation time rather than presenting discovery as immediate state.
The local canvas identifies buckets, views, routes, exclusions and metrics and
uses `log_view`, `log_route` and `log_metric` dependency edges.

## Permissions And Costs

Permission synthesis emits exact `logging.buckets.*`, `logging.views.*`,
`logging.sinks.*`, `logging.exclusions.*` and `logging.logMetrics.*` lifecycle
permissions. It enables only `logging.googleapis.com` for this graph.

Configuration estimates keep four billable dimensions separate:

- normal log ingestion after an explicit free allotment;
- vended network-log ingestion with no assumed free allotment;
- retained GiB-months beyond the included retention period;
- user-defined log metric bytes billed through Cloud Monitoring.

Routes, views, exclusions, Log Analytics and API calls do not receive invented
object fees. Actual usage, credits and negotiated pricing require Cloud Billing
export and remain distinct from configuration estimates.

## Qualification

`scripts/qualify-logging.sh` is the authenticated boundary. It requires ADC, an
explicitly disposable project, a customer-owned stack and all managed resource
IDs. It applies the saved plan, reads every remote object, writes a unique log
entry, proves the sink routed it into the managed bucket, imports a second
state, requires a refreshed no-op plan and cleans up.

Without that environment it exits `77` with a structured skip. Local tests and
receipts never claim authenticated routing, retention elapsed time or Billing
export evidence.

Primary Google references:

- https://cloud.google.com/logging/docs/routing/overview
- https://cloud.google.com/logging/docs/buckets
- https://cloud.google.com/logging/docs/logs-based-metrics
- https://cloud.google.com/logging/pricing
- https://cloud.google.com/asset-inventory/docs/asset-types
