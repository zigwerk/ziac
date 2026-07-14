# Ziac M74 Cloud Logging Provider Design

Date: 2026-07-14
Status: approved for implementation by the provider-coverage roadmap
Roadmap: `docs/superpowers/plans/2026-07-13-ziac-gcp-provider-coverage.md`

## Objective

Make log storage, routing, access slices, cost controls and derived operational
signals part of the compiled infrastructure graph. M74 follows Ziac's three
provider layers:

1. typed Logging v2 declarations;
2. handwritten lifecycle adapters for one-way settings, generated identities,
   operations, import and drift;
3. opinionated log-platform components that retain routing and cost intent.

M74 adds five managed resource types:

- `gcp.logging.Bucket`
- `gcp.logging.View`
- `gcp.logging.Sink`
- `gcp.logging.Exclusion`
- `gcp.logging.Metric`

## Contract Source

The provider pins Cloud Logging v2 Discovery revision `20260706` with SHA-256
`7b9427e591ffd255ad8579a471200f9045cf5b72446f5dfa7fc648e761dc5e7d`.
Contract upgrades require the shared deterministic semantic diff.

## Typed Declarations

`Bucket` owns a caller-selected location and bucket ID, retention, description,
analytics enablement, optional CMEK output, restricted fields and custom index
configuration. `locked` is explicit and protected because it permanently
freezes retention and restricts deletion. Analytics can transition only from
disabled to enabled. Location and ID are immutable.

`View` belongs to a typed bucket output and models the restricted Logging view
filter grammar as an explicit string. Ziac validates a non-empty conjunction
and leaves complete query-language validation to Google.

`Sink` owns a project-level route with typed destination kind, filter,
description, disabled state, optional BigQuery partitioning and inline sink
exclusions. Creation requests a unique writer identity by default. The
provider returns that identity as an output so destination IAM can be wired
without hard-coding Google's service agent.

`Exclusion` models a project-wide exclusion independently from a sink. It is a
cost and volume policy, not a data-deletion primitive, and cannot affect the
`_Required` sink.

`Metric` supports counter and distribution log metrics, immutable metric kind
and value type, typed label descriptors/extractors, optional owning bucket and
linear, exponential or explicit histogram boundaries. Label key and value type
are immutable once created. High-cardinality extractors remain visible to the
agent and canvas; Ziac never silently manufactures labels.

## Lifecycle And Drift

Sink, view, exclusion and metric CRUD are synchronous. Bucket create and
updates use the async Logging methods and checkpoint Google operations through
the generic operation contract. Canonical imports use complete project names;
Cloud Asset names have the `//logging.googleapis.com/` authority removed.

The provider compares only declared mutable fields and ignores timestamps,
writer identity, lifecycle state and other output-only fields. Exact update
masks are mandatory. Bucket reads surface `DELETE_REQUESTED`, `UPDATING`,
`CREATING` and `FAILED` rather than treating them as ready. An existing deleted
bucket may be recovered by a future explicit undelete action, never as an
implicit import or create side effect.

Bucket location, sink parent/name, view parent/name and metric identity changes
replace. Bucket lock and analytics are one-way. Metric kind, value type and
existing label key/type changes replace; ordinary descriptions, filters,
extractors and disabled state update in place.

## Opinionated Components

`ApplicationLogPlatform` composes a protected regional or global bucket, one or
more views, a same-project sink into that bucket, optional project exclusions
and counter/distribution metrics. Same-project bucket sinks require no writer
IAM. Cross-project or external destinations remain low-level primitives so the
caller must wire the generated writer identity to exact destination access.

The component emits bucket-storage, view-access, routing, exclusion-policy and
metric-derivation graph relationships. It does not hide `_Default` mutations,
organization aggregation, intercepting sinks or destination IAM.

## Product Integration

Permission synthesis emits exact `logging.buckets.*`, `logging.views.*`,
`logging.sinks.*`, `logging.exclusions.*` and `logging.logMetrics.*` lifecycle
permissions. Cloud Asset Inventory supports LogBucket, LogView, LogMetric and
LogSink. Project exclusions remain Ziac-managed but are not claimed as assets.

Canvas details include location, retention, lock, analytics, destination kind,
disabled state, view/route filters, metric value type and label/index counts.
Raw filter text is bounded and rendered only in the inspector, not on 3D faces.

Cost modelling separates billable log ingestion after the 50 GiB monthly free
allotment, vended network-log ingestion, retention GiB-months beyond 30 days
and custom metric bytes. Routing, API calls, views and Log Analytics receive no
invented charges. Actual costs still require Cloud Billing export.

## Qualification

Deterministic tests prove create/update/import/no-op/delete, one-way settings,
operation resume, destination wiring and secret-free artifacts. The
authenticated runner requires a disposable project, writes uniquely identified
probe entries, confirms the sink route and view visibility, confirms a derived
metric descriptor, imports a second state and cleans up. It exits with a
structured skip when that environment is absent.

Primary references:

- https://cloud.google.com/logging/docs/reference/v2/rest
- https://cloud.google.com/logging/docs/routing/overview
- https://cloud.google.com/logging/docs/buckets
- https://cloud.google.com/logging/docs/logs-views
- https://cloud.google.com/logging/docs/logs-based-metrics
- https://cloud.google.com/products/observability/pricing
- https://cloud.google.com/asset-inventory/docs/asset-types
