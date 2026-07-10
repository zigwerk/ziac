# Ziac CockroachDB SQL Resources Design

Date: 2026-07-10

Status: validated for Task 6.4 implementation.

## Goal

Add the SQL half of the CockroachDB provider: protected database creation,
least-privilege grants, immutable ordered migrations, Cockroach transaction
retry behavior, and a production Zig PostgreSQL/TLS pool suitable for Cloud Run.

The resource graph must retain only Secret Manager references. Connection URI
plaintext exists only in an owned, zeroed buffer while a provider operation is
executing.

## Boundaries

Ziac owns:

- declarative `Database`, `Grants`, and `Migration` resources;
- identifier, privilege, ordering, and immutability validation;
- read-before-write provider lifecycles;
- migration serialization and reconciliation policy;
- SQLSTATE `40001` retry and `40003` stop-for-reconciliation behavior;
- mapping SQL diagnostics into Ziac provider errors.

`zigeffect-postgres` owns:

- local `psql` execution for development and contract tests;
- the production native driver adapter;
- verified TLS connection setup;
- bounded connection pooling, health validation, lifetime rotation, and jitter;
- SQLSTATE-preserving diagnostics.

The production adapter will use a pinned revision of
[`karlseguin/pg.zig`](https://github.com/karlseguin/pg.zig). The selected
revision targets Zig 0.16 and already provides the PostgreSQL wire protocol,
SCRAM authentication, OpenSSL-backed `verify_full` TLS, connection pooling,
keepalive, prepared statements, and detailed PostgreSQL errors. Ziac wraps this
surface behind its own narrow executor contract instead of exposing the driver
through resource APIs.

## SQL Executor Contract

`cockroach.sql.Executor` is an injectable vtable with `query` and `execute`
operations. Each call receives an ephemeral connection URI, SQL text, operation
context, and mutable diagnostic record.

Results own rows with named nullable text cells. This deliberately small model
is sufficient for catalog and `SHOW` queries and keeps Ziac independent from
driver-specific OIDs.

Diagnostics retain a five-byte SQLSTATE, an outcome classification, and a
redacted category. They never retain SQL, bind values, connection URIs, or
server messages that may contain application data.

Outcome classes are:

- `definite`: the server confirms success or rejection;
- `ambiguous`: commit or statement completion may have happened;
- `connection`: no definite server result was received.

## Secrets

All three SQL resources accept
`SecretOutput(value.SecretReference)` as `connection_secret`. The live provider
resolves that output through the configured `SecretSource`, uses the payload for
one executor call or retry loop, then securely zeroes and frees it.

Provider inputs and outputs contain only the secret/output reference. SQL
receipts contain resource identity, migration checksums, attempt counts, and
SQLSTATE categories, never plaintext SQL or connection data.

## Identifiers And SQL Generation

Resource names, database names, schemas, roles, and migration table names are
validated as non-empty PostgreSQL identifiers without NUL bytes. Generated SQL
always quotes identifiers by doubling embedded double quotes. Values such as
migration IDs and checksums use single-quoted literals with doubled quotes.

Privileges are closed enums, not arbitrary SQL fragments.

## Database Resource

`cockroach.Database` inputs are cluster ID, database name, connection secret,
and protection policy. It is protected by default.

Read queries `pg_database`. Create first reads and issues `CREATE DATABASE` only
when absent. Delete issues `DROP DATABASE` only after the engine's lifecycle
protection has been explicitly removed. Import validates
`clusters/<cluster>/databases/<database>` and reads the database.

Database identity changes replace the resource; protection is planner state and
not part of provider drift.

## Grants Resource

`cockroach.Grants` manages an exact declared set of direct privileges for one
grantee on one database. Initial privileges are the database-level Cockroach
set `ALL`, `CONNECT`, `CREATE`, and `DROP`.

Read uses `SHOW GRANTS ON DATABASE ... FOR ...`. Create and update calculate
missing and excess direct grants, then issue deterministic `GRANT` and `REVOKE`
statements. Unrelated grantees are untouched. Delete revokes only the managed
privileges. Cluster, database, and grantee changes replace the resource;
privilege changes update in place.

Table/schema/default privileges can be added as a compatible extension after
the end-to-end app proves which ownership model it needs. Migrations initially
run as the application owner, so that user owns newly created objects.

## Migration Resource And Set

`cockroach.Migration` is immutable and identified by cluster, database, and
migration ID. Inputs contain SQL, a SHA-256 checksum, the migration table name,
the connection secret, and an optional typed output from the previous migration.
The previous output derives an ordering dependency automatically.

`cockroach.Migrations` builds a deterministic chain from an ordered migration
slice and rejects empty, duplicate, or out-of-order IDs. It returns the final
applied migration output for downstream service dependencies.

Read checks the history row:

- no row means absent;
- matching checksum means present;
- a different checksum is a conflict requiring a new migration ID.

Apply sends one batched transaction containing:

1. migration history and singleton lock table creation;
2. singleton lock-row upsert;
3. `SELECT ... FOR UPDATE` on that row;
4. a checksum guard;
5. the migration SQL;
6. history insertion;
7. commit.

The row lock serializes concurrent migration executors. The history primary key
and checksum guard make retries and interrupted applies convergent. Migration
delete detaches state and never runs down SQL.

## Retry And Ambiguity

The SQL operation runner uses bounded exponential backoff with injectable clock
and jitter.

- SQLSTATE `40001` retries the entire idempotent read-before-write or migration
  transaction up to the configured maximum.
- SQLSTATE `40003` never retries automatically. The provider returns a conflict,
  requiring refresh to reconcile the migration history or grant catalog.
- A connection failure before a definite result is transient for reads. Writes
  stop for read-before-write reconciliation unless the executor can prove the
  server rejected the operation.
- Cancellation and deadlines are checked before every attempt and sleep.

## Native Pool

`zigeffect-postgres.NativePool` wraps `pg.Pool` with Ziac-oriented options:

- bounded size and checkout timeout;
- `verify_full` required by default;
- startup connection validation;
- `SELECT 1` validation before reuse after an idle threshold;
- maximum connection lifetime with per-connection jitter;
- TCP keepalive enabled;
- redacted metrics and diagnostics.

The adapter converts native result rows into the executor row model and copies
SQLSTATE before releasing a connection. It never logs PostgreSQL error messages
or connection URIs.

## Acceptance

- Scripted executor lifecycles pass for all three resources.
- Identifier quoting and privilege rendering have exhaustive table tests.
- Migration order, checksum conflict, `40001`, `40003`, interruption, and
  concurrent serialization are deterministic.
- Local `psql` adapter contract tests pass without a running database.
- Native adapter and pool tests pass against a disposable local CockroachDB
  when configured and otherwise skip explicitly.
- Ziac state, receipts, diagnostics, and test snapshots contain no connection
  URI or migration-secret sentinel.
