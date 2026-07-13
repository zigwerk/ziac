# Ziac M65 Cloud SQL Provider Plan

Date: 2026-07-13
Status: in progress

## 1. Contract And Typed Resources

- [x] Pin and validate the Cloud SQL Admin v1 Discovery contract.
- [x] Add failing Instance and ReadReplica declaration/validation tests.
- [x] Add failing Database, User and ClientCertificate tests.
- [x] Implement typed outputs, secret references and graph dependencies.

## 2. Hardened Lifecycle

- [x] Add normalized read/create/update/delete/import for all five types.
- [x] Add resumable SQL Operations polling and final-read convergence.
- [x] Add settings-version concurrency and immutable/private-IP guards.
- [x] Redact user passwords and persist certificate private keys only through
  Secret Manager.

## 3. Product Intelligence

- [x] Register catalog/live-dispatch parity and pinned provenance.
- [x] Add API, deployer and runtime permission synthesis.
- [x] Add supported Cloud Asset identity and observed/managed reconciliation.
- [x] Add SQL canvas metadata, relationship edges and explicit cost estimates.

## 4. High-Level Component

- [x] Add `ManagedPostgres` primary, replica, database and user composition.
- [x] Add exact IAM login/client grants and optional certificate secret.
- [x] Prove deterministic graph identity and typed output wiring.
- [x] Prove private connectivity is explicit and never synthesized invisibly.

## 5. Qualification And Documentation

- [x] Add fake-provider apply/import/refresh/no-op/protection/cleanup receipt.
- [x] Add fail-closed authenticated disposable-project runner.
- [x] Add installed docs and a compiled consumer example.
- [x] Run Testing v2, examples, dashboard, catalog, typecheck and migration
  gates.

Gate: application teams can provision a production-shaped PostgreSQL data plane
without raw request JSON, hidden network mutations or plaintext secrets in
state.

Status: locally complete. Authenticated qualification remains external and is
not claimed until `scripts/qualify-cloud-sql.sh` emits a passed disposable-
project receipt.
