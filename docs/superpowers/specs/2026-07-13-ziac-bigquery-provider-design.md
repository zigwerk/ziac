# Ziac M63 BigQuery Provider Design

Date: 2026-07-13
Status: accepted implementation direction

## Purpose

M63 makes BigQuery usable from all three Ziac provider layers. Broad typed
primitives expose the stable Google resource model. Hardened adapters own
read/normalize/diff/create/update/import/delete and IAM concurrency. An
opinionated warehouse component assembles common analytics infrastructure while
returning ordinary typed outputs.

## Low-Level Resources

The public resource set is:

- `gcp.bigquery.Dataset`;
- `gcp.bigquery.Table` and `gcp.bigquery.View`;
- `gcp.bigquery.Routine`;
- `gcp.bigquery.Connection`;
- `gcp.bigquery.Reservation`, `CapacityCommitment` and
  `ReservationAssignment`;
- additive Dataset, Table, Routine, Connection and Reservation IAM members.

Dataset location and IDs are immutable. Tables expose nested schemas, time
partitioning, clustering, CMEK and partition-filter policy. Views use GoogleSQL
by default and cannot also declare a physical schema. Routines cover SQL scalar,
table-valued and procedure definitions. Connections initially cover
credential-free Cloud Resource and Cloud Spanner configurations; secret
credential mutation is deliberately excluded from desired state. Reservations
model baseline and autoscale bounds, while commitments and assignments remain
separate resources because they have different cost and deletion authority.

## Hardened Lifecycle

BigQuery v2 resources use their documented REST endpoints. Dataset and table
updates use PATCH with `If-Match`; routine updates use PUT with `If-Match`.
Proto-style update masks are not sent to these BigQuery v2 methods.
Deletion defaults to retained; deleting a non-empty dataset requires explicit
`delete_contents_on_destroy`. Table/view/routine imports accept canonical
`projects/<project>/datasets/<dataset>/<kind>/<id>` names and familiar
`project:dataset.table` forms where unambiguous.

Connection and Reservation APIs use v1 gRPC-transcoded paths and exact update
masks. Additive IAM members use policy version 3, etags and bounded
compare-and-swap retries, preserving unrelated principals and bindings.

## High-Level Component

`ziac.gcp.AnalyticsWarehouse` creates one regional dataset, typed tables,
GoogleSQL views and routines, plus exact dataset readers and writers. Optional
Cloud Resource connection and reservation capacity remain explicit arguments.
The component never purchases a commitment implicitly. It returns dataset,
table, view, routine, connection and reservation outputs keyed by stable graph
identity.

## Product Integration

Permission synthesis includes BigQuery, Connection and Reservation APIs and
separates runtime data access from deployer control-plane access. Cloud Asset
Inventory mappings normalize Dataset, Table, Routine and Reservation names.
The visual artifact groups warehouse resources, draws dataset containment and
IAM edges, and labels all prices as configuration estimates unless billing
export provenance is attached. Cost assumptions cover active/long-term storage,
analysis bytes and reserved slots without inventing usage.

## Qualification Boundary

Deterministic tests prove declarations, provider requests, normalization,
etag conflicts, import/no-op, IAM preservation, estate identity and component
composition. An authenticated disposable-project runner separately exercises a
queryable table/view/routine, connection identity and reservation lifecycle.
Local transport fixtures never count as live BigQuery proof.

## Contract Sources

The implementation follows the official BigQuery v2 REST resource contracts,
BigQuery Connection v1 and BigQuery Reservation v1. The provider catalog records
the exact Discovery endpoints and review date so generated semantic diffs can
surface future field or method changes.
