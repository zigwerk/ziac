# GCP BigQuery

M63 provides BigQuery through Ziac's three provider layers: typed low-level
resources, hardened lifecycle adapters and the opinionated
`ziac.gcp.AnalyticsWarehouse` component.

## Analytics Warehouse

```zig
var warehouse = try ziac.gcp.AnalyticsWarehouse.build(allocator, provider, .{
    .name = "product-analytics",
    .dataset_id = "product_analytics",
    .location = "EU",
    .tables = &.{.{
        .table_id = "events",
        .schema = &.{
            .{ .name = "event_id", .field_type = .string, .mode = .required },
            .{ .name = "occurred_at", .field_type = .timestamp, .mode = .required },
        },
        .time_partitioning = .{ .field = "occurred_at" },
        .require_partition_filter = true,
    }},
    .readers = &.{"group:analytics@example.com"},
    .writers = &.{"serviceAccount:ingest@project.iam.gserviceaccount.com"},
});
defer warehouse.deinit();
```

The component creates one dataset, any declared tables, views and routines, and
additive dataset IAM members. It exposes typed dataset and table names for
application binding. It never creates a connection, reservation or capacity
commitment implicitly.

## Low-Level Resources

- `Dataset`, `Table`, `View` and `Routine` use BigQuery v2.
- `Connection` uses BigQuery Connection v1.
- `Reservation`, `CapacityCommitment` and `ReservationAssignment` use BigQuery
  Reservation v1.
- Dataset, Table, Routine, Connection and Reservation IAM members preserve
  unrelated policy bindings through etag-based compare-and-swap.

Datasets, tables, views and routines retain data by default. Dataset deletion
with contents requires `delete_contents_on_destroy = true` and explicit
destructive confirmation. Capacity commitments are protected and retained;
Ziac never purchases or deletes one as a side effect of another resource.

BigQuery v2 dataset and table updates use `PATCH` with `If-Match`; routine
updates use `PUT` with `If-Match`. Connection and Reservation updates use their
documented field masks. Imports normalize familiar BigQuery IDs to canonical
`projects/...` identities.

## Intelligence And Canvas

Permission synthesis enables only the BigQuery APIs present in the graph and
separates deployer control-plane permissions from runtime data permissions.
Dataset readers yield `bigquery.tables.getData`; writers yield
`bigquery.tables.updateData`.

Cloud Asset discovery maps datasets, tables, routines and reservations to the
same canonical identities as managed resources. The visual artifact includes
warehouse kind, location, schema size, partition controls, capacity, IAM access
and configuration-estimate cost provenance. A Cloud Asset table cannot safely
be inferred to be a Ziac `View`, so observed tables remain typed as `Table`.

`bigqueryConfigurationEstimate` keeps query TiB, stored GiB-month and reserved
slot-hours explicit. It is not actual billed cost. Billing-export evidence must
use the separate billing origin and must never be inferred from configuration.

## Qualification

The local gate proves deterministic graph identity, full fake-provider apply,
second-state import, refreshed no-op and retention-aware cleanup. Its receipt is
always `authenticated: false`.

`scripts/qualify-bigquery.sh` is the authenticated boundary. It requires ADC,
a project ending in `-ziac-disposable`, an end-user Ziac workspace and explicit
probe SQL. It rejects plans containing capacity commitments, exercises the
deployed dataset/table/view/routine, imports all resources into a second state,
proves a no-op plan and verifies retained data after destroy. Missing credentials
or configuration emits a structured skip with exit code 77.

Contract references:

- [BigQuery v2 REST](https://cloud.google.com/bigquery/docs/reference/rest/v2)
- [BigQuery Connection v1 REST](https://cloud.google.com/bigquery/docs/reference/bigqueryconnection/rest)
- [BigQuery Reservation v1 REST](https://cloud.google.com/bigquery/docs/reference/bigqueryreservation/rest)
- [Cloud Asset supported types](https://cloud.google.com/asset-inventory/docs/supported-asset-types)
