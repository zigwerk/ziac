# CockroachDB SQL Resources

Ziac manages CockroachDB databases, exact database grants, and immutable ordered
migrations through the normal provider lifecycle. SQL connection plaintext is
resolved from Secret Manager only while an operation is running; desired inputs,
state, outputs, diagnostics, and receipts contain typed secret references.

## ApplicationDatabase

`cockroach.application_database.ApplicationDatabase` is the high-level starting
point for an application database on an existing CockroachDB Cloud cluster. It
owns:

1. the retained existing-cluster reference;
2. generated application connection secret and SQL user;
3. a protected database;
4. exact grants for the application user;
5. an ordered migration chain.

Database bootstrap uses a pre-existing administrator connection stored as a
numeric GCP Secret Manager version. The generated application connection targets
the new database, so Ziac does not use it until the user, database, and grants are
ready. The first migration depends on all three; later migrations depend on the
previous typed `applied_id` output.

```zig
var data = try ziac.cockroach.application_database.ApplicationDatabase.build(
    allocator,
    .{ .project_id = "example-project", .primary_region = "europe-west1" },
    .{},
    .{
        .name = "production",
        .cluster_id = "cluster-id",
        .plan = .standard,
        .regions = &.{ "europe-west1", "us-central1" },
        .database = "app",
        .username = "app_user",
        .secret_id = "app-database-url",
        .admin_connection = .{
            .provider = "gcp-secret-manager",
            .resource = "projects/example-project/secrets/cockroach-admin-url",
            .version = "1",
        },
        .migrations = &.{.{
            .id = "001_init",
            .sql = "CREATE TABLE accounts (id UUID PRIMARY KEY)",
        }},
    },
);
defer data.deinit();
```

The complete buildable example is
`examples/cockroach_application_database.zig`. An empty migration list is valid,
which permits database and credential bootstrap before a schema is declared.

## Resource Lifecycles

`cockroach.Database` reads `pg_database` before create or delete, is protected by
default, and supports refresh and import. Database identity changes replace it.

`cockroach.Grants` reads direct database privileges and reconciles the exact
closed-enum set `ALL`, `CONNECT`, `CREATE`, and `DROP`. It never changes another
grantee. Privilege changes update in place; database or grantee changes replace.

`cockroach.Migration` stores a SHA-256 checksum and never executes down SQL on
destroy. Apply creates the history and singleton lock tables, locks one row with
`FOR UPDATE`, checks history, executes the migration, and inserts its checksum in
one transaction. Duplicate or reordered IDs fail before provider execution.

SQLSTATE `40001` retries the complete idempotent operation with bounded backoff.
SQLSTATE `40003` is ambiguous and stops with `Conflict`; refresh must reconcile
history before another mutation. Provider-level serialization protects callers
in one process, while the Cockroach row lock protects separate processes.

## Execution Adapters

`cockroach.psql_executor.PsqlExecutor` is the local adapter. It launches `psql`
with a secret-free argv, supplies the URI only through the short-lived child
environment, captures only SQLSTATE and outcome, and zeroes command output.

`cockroach.native_executor.NativeExecutor` is the production adapter. It lazily
resolves one secret, owns a bounded native `pg.zig` pool, requires
`sslmode=verify-full`, validates idle generations, uses the driver's TCP
keepalive defaults, and replaces an expired idle pool generation only after the
new generation connects. Password rotation replaces the pool when no operation
is active. Retained URI buffers are runtime-only; the wrapper URI and the
driver's duplicated reconnect password are securely zeroed on teardown.
The driver uses a zeroing allocator so failed initialization and all pool arena
or connection-buffer frees receive the same treatment.

```zig
var native = ziac.cockroach.native_executor.NativeExecutor.init(
    allocator,
    io,
    .{ .size = 5, .checkout_timeout_millis = 5_000 },
);
defer native.deinit();
cockroach_live.sql_executor = native.executor();
```

`pg.zig` is pinned in `zigeffect-postgres/build.zig.zon`; native TLS builds require
OpenSSL headers and libraries.

## Verification

```sh
bun run ziac:test
bun run ziac:examples
bun run zigeffect:postgres:test
bun run zigeffect:postgres:cockroach-live-test
```

The live local gate creates a secure disposable CockroachDB v26.2.3 container,
generates a private CA, authenticates password users over verified TLS, runs a
native type-conversion query, then creates and removes a database, exact grants,
and a migration through the Ziac provider lifecycle. It always removes the
container and certificates.
