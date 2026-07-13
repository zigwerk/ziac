# Ziac M64 Firestore Provider Design

Date: 2026-07-13
Status: accepted implementation direction

## Purpose

M64 makes Firestore useful through the same three provider layers as BigQuery:
typed low-level resources, hardened lifecycle adapters and one opinionated
application data component. The implementation follows the Firestore Admin v1
contract pinned by Ziac's googleapis revision.

## Low-Level Resources

The managed set is:

- `gcp.firestore.Database`;
- `gcp.firestore.Index` for composite and vector indexes;
- `gcp.firestore.Field` for single-field index and TTL overrides;
- `gcp.firestore.BackupSchedule`;
- additive `gcp.firestore.DatabaseIamMember`.

Backups, operations and deleted-database tombstones are observed children. They
are not desired resources. MongoDB-compatible search indexes remain explicit
future work; M64 accepts Firestore Native and Datastore index modes plus flat
vector indexes without inventing unsupported abstractions.

Database location, edition, CMEK and realtime mode are immutable. Type changes
are replacements because Google's conditional empty-database mutation cannot be
proven safely from an infrastructure plan. Delete protection and PITR are
mutable. Databases retain by default and destructive deletion requires both
disabled delete protection and explicit destructive authority.

Indexes have server-assigned physical IDs, so create records the operation and
resolved index name. Updates replace. Field resources PATCH explicit index and
TTL masks; deletion means reverting the override to its ancestor configuration,
not deleting application documents. Backup schedules have server-assigned IDs,
daily or weekly recurrence, a bounded retention duration and ordinary update
masks.

## Hardened Lifecycle

Database, Index and Field mutations may return long-running operations. The
adapter stores operation handles and resumes through the existing provider
operation protocol. Database update and delete carry the observed etag.
Canonical imports accept full `projects/...` names; database shorthand is
accepted only when unambiguous. Server defaults and output-only fields never
cause drift.

Database IAM uses version-3 policy reads and etag compare-and-swap writes.
Additive members preserve unrelated principals and reject overlapping graph
ownership through the shared IAM validator.

## High-Level Component

`ziac.gcp.DocumentStore` creates one database, any declared indexes and field
overrides, optional daily or weekly backup schedules and exact database readers
and writers. It returns typed database, index, field and schedule names. The
component enables delete protection and retention by default and never creates
credentials or document data.

## Product Integration

Permission synthesis separates Firestore Admin deployer authority from runtime
document access. Cloud Asset discovery normalizes supported Database and Index
identities. The canvas groups database, index, field, schedule and IAM nodes and
labels runtime read/write edges. Cost assumptions expose document reads, writes,
deletes, stored GiB-month and backup GiB-month as configuration estimates only.

## Qualification Boundary

Local tests prove declarations, exact requests, LRO checkpointing, import/no-op,
field reversion, IAM preservation, estate identity, deterministic composition
and retention-aware cleanup. The authenticated runner requires a disposable
project, writes and reads a sentinel document through the public Firestore API,
checks index/TTL/backup state, imports into a second state and verifies retained
data after destroy. Local fixtures never count as authenticated proof.

## Contract Sources

- pinned `google/firestore/admin/v1/firestore_admin.proto`;
- pinned Database, Index, Field and Schedule resource protos;
- Firestore Admin v1 REST and Cloud Asset supported-type documentation.
