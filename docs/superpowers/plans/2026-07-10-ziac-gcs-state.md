# Ziac GCS State Backend Implementation Plan

**Goal:** Add generation-locked GCS remote state and expiring writer leases
while preserving the existing state format and executor checkpoint behavior.

**Design:** `docs/superpowers/specs/2026-07-10-ziac-gcs-state-design.md`

## Task 1: Backend Contracts And Fake Store

- Add `packages/ziac/src/state_backend.zig`.
- Define object read/write/delete contracts with explicit preconditions.
- Add a deterministic in-memory generation store.
- Add red tests for create-zero, update-N, delete-N, and writer conflicts.
- Export shared local state serialization and lock parsing helpers.

## Task 2: Remote State And Lease Semantics

- Implement the remote adapter and generation cache.
- Add resource/output save and load methods.
- Add lock v2 expiry while preserving lock v1 reads.
- Implement acquire, inspect, renew, release, stale takeover, and force unlock.
- Add migration with lineage/serial and secret-reference assertions.

## Task 3: GCS Object Store

- Add `packages/ziac/src/gcp/gcs_state.zig` and export it.
- Implement metadata plus generation-pinned media reads.
- Implement conditional media uploads and conditional deletes.
- Map GCP errors without exposing response bodies.
- Add scripted transport tests for exact endpoints and preconditions.

## Task 4: Checkpoint And CLI Integration

- Generalize checkpoint resources from local state to `state_backend.Store`.
- Switch `cli.Env.state` to the backend facade.
- Keep local state as the default adapter.
- Select GCS from `ZIAC_STATE_BUCKET` and optional `ZIAC_STATE_PREFIX`.
- Resolve ADC for remote-state-only commands.
- Add CLI and main integration tests.

## Task 5: Documentation And Gates

- Add remote state setup, IAM, migration, conflict, and recovery docs.
- Update architecture, README, roadmap, and the E2E plan evidence.
- Run Ziac tests/examples/build, repository check, zigeffect std/PostgreSQL,
  local verified-TLS Cockroach, tool hygiene, and diff checks.
- Commit as `Add GCS remote state locking`.

