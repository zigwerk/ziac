# GCP Firestore

M64 provides Firestore through Ziac's three provider layers: typed low-level
resources, hardened lifecycle adapters and the opinionated
`ziac.gcp.DocumentStore` component.

## Document Store

```zig
var store = try ziac.gcp.DocumentStore.build(allocator, provider, .{
    .name = "documents",
    .database_id = "documents",
    .location = "eur3",
    .point_in_time_recovery = true,
    .delete_protection = true,
    .indexes = &.{.{
        .name = "matches-by-status",
        .collection_group = "matches",
        .fields = &.{
            .{ .field_path = "status", .mode = .ascending },
            .{ .field_path = "played_at", .mode = .descending },
        },
    }},
    .fields = &.{.{
        .collection_group = "sessions",
        .field_path = "expires_at",
        .ttl_enabled = true,
    }},
    .backup_schedules = &.{.{
        .name = "daily",
        .recurrence = .daily,
        .retention_seconds = 8 * 7 * 24 * 60 * 60,
    }},
    .readers = &.{"group:analytics@example.com"},
    .writers = &.{"serviceAccount:api@project.iam.gserviceaccount.com"},
});
defer store.deinit();
```

The component creates one database, composite indexes, field overrides, up to
one daily and one weekly backup schedule, and additive database IAM members. It
exposes typed names for application binding. Duplicate backup recurrences and
invalid Firestore database, field, vector and retention settings fail before a
plan is produced.

## Lifecycle Semantics

- `Database` supports create, read, update, import and delete through Firestore
  Admin v1. Updates and deletes use the remote etag as a compare-and-swap
  precondition. Databases are protected and retained by default.
- `Index` is replace-only. The provider persists the server-assigned index name
  and resumes long-running operations after interruption.
- `Field` updates index and TTL configuration with a field mask. Removing it
  restores default field configuration instead of deleting the field's data.
- `BackupSchedule` supports synchronous CRUD. Names assigned by Google are
  retained in state; retention is bounded to Firestore's fourteen-week limit.
- `DatabaseIamMember` preserves unrelated bindings using policy etags.

The provider normalizes remote output-only and ordering differences before
drift comparison. Imports accept canonical `projects/...` names and Cloud Asset
`//firestore.googleapis.com/...` names.

## Intelligence, Estate And Cost

Permission synthesis enables `firestore.googleapis.com` and derives exact
deployer permissions from the graph. Runtime reader and writer roles produce
`datastore.entities.get` and `datastore.entities.create` respectively.

Cloud Asset Inventory currently maps Firestore databases to the same canonical
identity as managed resources. It does not advertise indexes, fields or backup
schedules as observed resources because those types are not present in Cloud
Asset Inventory's supported-type contract.

The visual artifact includes database mode and location, index shape, field TTL
state, backup recurrence and datastore IAM access. `firestoreConfigurationEstimate`
keeps document operations, stored GiB-month and backup GiB-month assumptions
explicit. It is a configuration estimate, never actual billed cost.

## Qualification

The local qualification gate proves deterministic graph identity, full
fake-provider apply, second-state import, refreshed no-op and retention-aware
cleanup. Its receipt is always `authenticated: false`.

`scripts/qualify-firestore.sh` is the authenticated boundary. It requires ADC,
an end-user workspace and a project ending in `-ziac-disposable`. It deploys the
stack, probes the database, indexes, fields and backup schedules through the
Firestore Admin API, imports all resources into a second state, proves a no-op
plan and verifies the retained database after destroy. The dedicated
qualification stack must set lifecycle `protect = false` while retaining the
database; the runner fails closed if any protected resource reaches cleanup.
Missing credentials or configuration emits a structured skip with exit code 77.

Contract references:

- [Firestore Admin v1 REST](https://cloud.google.com/firestore/docs/reference/rest/v1/projects.databases)
- [Manage indexes](https://cloud.google.com/firestore/docs/query-data/indexing)
- [Scheduled backups](https://cloud.google.com/firestore/docs/backups)
- [Cloud Asset supported types](https://cloud.google.com/asset-inventory/docs/supported-asset-types)
