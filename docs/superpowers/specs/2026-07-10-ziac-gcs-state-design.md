# Ziac GCS State Backend Design

**Date:** 2026-07-10

**Status:** validated for implementation by the accepted Ziac E2E design and
M8 roadmap.

## Objective

Add a production remote-state backend without changing Ziac's state model,
deterministic JSON format, plan preconditions, or checkpoint-after-mutation
semantics. GCS is the first remote implementation. Concurrent or stale writers
must fail closed rather than overwrite state.

## Existing Invariants

- `InMemoryStateStore` owns all records and increments a monotonic serial.
- `local_state` serializes versioned state deterministically and validates
  stack, stage, lineage, and format migrations on load.
- The executor checkpoints after every completed or failed provider mutation.
- Parallel executor batches serialize checkpoint calls through a spin lock.
- Secret state contains typed references, never provider payload plaintext.
- Local lock release verifies owner; forced unlock verifies lineage unless
  explicitly overridden.

These semantics remain shared by local and remote state.

## Backend Facade

`state_backend.Store` is the CLI and checkpoint-facing type-erased facade. It
provides the same resource, output, and writer-lock operations currently used
from `local_state.Store`. A `state_backend.Local` adapter delegates to the
existing implementation. A `state_backend.Remote` adapter uses an `ObjectStore`
and the same exported serializers and parsers from `local_state`.

`ObjectStore` has only three mutations:

- `get(key) -> { bytes, generation }`;
- `put(key, bytes, absent | generation(N)) -> generation(N+1)`;
- `delete(key, generation(N))`.

There is no unconditional remote write or delete. The fake object store assigns
monotonic generations and enforces the same preconditions as GCS.

## Resource Checkpoints

`Remote` caches the generation observed for each object key. Loading resources
records generation N. Every later checkpoint serializes a fresh consistent
snapshot and writes with `ifGenerationMatch=N`; success replaces the cached
generation, while a precondition failure becomes `StateConflict`. An empty
remote load records the `absent` precondition, so the first save uses
`ifGenerationMatch=0`.

Saving derived outputs first observes their current generation when necessary,
then uses the same compare-and-swap rule. Outputs remain redacted by the shared
serializer.

## GCS Protocol

`gcp.gcs_state.ObjectStore` uses the authenticated Google client and a borrowed
operation context.

Read is a pinned two-request operation:

1. GET object metadata and parse the decimal `generation`.
2. GET object bytes with `alt=media&generation=N`.

This prevents metadata from describing one revision while bytes come from a
later revision. Upload uses the JSON API media endpoint with
`ifGenerationMatch=0` for absence or `ifGenerationMatch=N` for replacement.
The upload response supplies the new generation. Delete always includes
`ifGenerationMatch=N`. HTTP 404 maps to `NotFound`; HTTP 409/412 maps to
`Conflict`; auth, quota, retry, cancellation, and deadline errors remain
distinct backend failures.

Object keys default to `ziac/state/<stack>/<stage>/...` under a configurable,
validated prefix. Bucket and key segments are percent encoded only at the HTTP
boundary.

## Writer Leases

Remote lock objects use lock format v2 and include:

- lineage;
- owner ID;
- command;
- acquisition time;
- expiry time.

Acquisition uploads with the `absent` precondition. On conflict, the current
lock is read. An unexpired lock returns `LockConflict`; an expired lock is
deleted at its exact generation and acquisition is retried once. Renewal
verifies ownership and replaces the exact observed generation with an extended
expiry. Release and force-unlock delete only the generation that was inspected.

Local lock v1 remains readable. Local locks may omit expiry and retain the
existing stale-duration calculation. Remote locks always carry expiry.

## Migration

`migrateLocalToBackend` loads the released local format, verifies the target is
absent, writes resources through compare-and-swap, migrates redacted outputs
when present, and reloads the target. It verifies that lineage and serial are
unchanged. It never deletes the local state; rollback is selecting the local
backend again.

## CLI Selection

Local state remains the default. Setting `ZIAC_STATE_BUCKET` selects GCS and
requires ADC even for plan-only commands. `ZIAC_STATE_PREFIX` optionally
changes the validated object prefix. The same selected backend handles plan,
deploy, refresh, import, outputs, state, destroy, unlock, and checkpoints.

No service-account key file is required. ADC and WIF use the existing native
authentication path.

## Failure Semantics

- A state generation mismatch is never retried as an unconditional write.
- A lock generation mismatch never deletes or replaces the competing lock.
- Failed uploads leave the previous generation readable.
- Invalid state JSON, future versions, or lineage mismatch fail before plan or
  provider access.
- Backend error messages and JSON receipts never include object bytes, access
  tokens, secret reference payloads, or authorization headers.

## Verification

- Fake object-store generation-zero create, generation update, and concurrent
  conflict tests.
- Lease owner, expiry, renewal, stale takeover, and exact-generation release.
- Scripted GCS metadata/media read, create, update, conflict, and delete URLs.
- Local-to-remote migration with unchanged lineage, serial, typed secret
  references, and redacted outputs.
- Existing local state, lock, checkpoint, recovery, CLI, and provider suites.

