# Ziac CockroachDB SQL Resources Implementation Plan

Date: 2026-07-10

Design: `docs/superpowers/specs/2026-07-10-ziac-cockroach-sql-design.md`

Status: completed on 2026-07-10.

## Task 1: Executor And SQL Safety

1. Add failing tests for owned query results, SQLSTATE diagnostics, identifier
   quoting, literal quoting, privilege sorting, and secret zeroing.
2. Add `cockroach/sql.zig` with the executor vtable and deterministic SQL
   helpers.
3. Add a scripted executor with operation recording for provider tests.
4. Verify `bun run ziac:test` and commit the executor contract with resources.

## Task 2: Database And Grants

1. Add builders and graph tests for typed secret references and automatic
   dependencies.
2. Add scripted read/create/update/delete/import lifecycle tests.
3. Implement exact database existence and direct database-grant reconciliation.
4. Prove protected database defaults and scoped revocation.

## Task 3: Ordered Migrations

1. Add builder tests for checksums, duplicate IDs, order, and typed chaining.
2. Add provider tests for absent/applied/checksum-conflict reads.
3. Add transaction rendering and scripted apply tests.
4. Add `40001` bounded retry, `40003` reconciliation stop, cancellation, and
   concurrent lock-order tests.
5. Make migration delete detach-only.

## Task 4: Local Psql Adapter

1. Add SQLSTATE-aware `psql` invocation and stderr parsing to
   `zigeffect-postgres`.
2. Add a Ziac executor adapter that maps rows and diagnostics.
3. Keep URI/SQL plaintext out of diagnostics and receipts.
4. Verify `bun run zigeffect:postgres:test` and `bun run ziac:test`.

## Task 5: Native Driver And Pool

1. Pin `pg.zig` revision `c9213c2a0f9942e76ad856efbd2e5847f153b55e`.
2. Wrap native query/execute and copy SQLSTATE before releasing results.
3. Require `verify_full`, keepalive, bounded pool size, and checkout timeout.
4. Add validation, maximum lifetime, and injectable jitter policy.
5. Add deterministic wrapper tests plus a credential-gated local CockroachDB
   integration test.

## Task 6: Integration And Documentation

1. Export all public resources and adapters.
2. Add a SQL resource example graph.
3. Update the M6 roadmap, README, SQL operations, migration, and security docs.
4. Run Ziac, zigeffect-std, zigeffect-postgres, examples, build, format, secret
   scan, and diff checks.
5. Commit `Add CockroachDB SQL resources and migrations`.

## Completion Evidence

- Database, grants, and migration scripted lifecycles pass read, diff, create,
  update, delete, refresh, and import contracts as applicable.
- `40001`, `40003`, checksum conflicts, ordered chaining, and actual concurrent
  caller serialization are deterministic tests.
- `ApplicationDatabase` builds the administrator bootstrap and application
  migration graph with typed dependency edges.
- Both `psql` and native adapters preserve SQLSTATE without retaining server
  messages, SQL output, or connection URIs in diagnostics.
- `bun run zigeffect:postgres:cockroach-live-test` passes against a disposable
  secure CockroachDB v26.2.3 container over `sslmode=verify-full`.
