# Ziac M74 Cloud Logging Provider Plan

Date: 2026-07-14
Design: `docs/superpowers/specs/2026-07-14-ziac-logging-provider-design.md`
Status: locally complete; authenticated disposable-project qualification pending

## Contract And Tests

- [x] Add failing declaration and validation tests for all five resources.
- [x] Add failing one-way bucket and immutable metric-schema tests.
- [x] Add failing CRUD, canonical import and operation-resume tests.
- [x] Add failing sink writer-identity and exact update-mask tests.
- [x] Add failing filter, label-cardinality and histogram validation tests.

## Typed Primitives

- [x] Implement buckets with retention, lock, analytics, CMEK and indexes.
- [x] Implement views with output-backed bucket identity.
- [x] Implement sinks with typed destinations, exclusions and writer output.
- [x] Implement independent project exclusions.
- [x] Implement counter and distribution log metrics.
- [x] Register Logging v2 endpoint, catalog, exports and provenance.

## Hardened Provider

- [x] Add CRUD/import for all five resource types.
- [x] Checkpoint and resume asynchronous bucket operations.
- [x] Enforce bucket and metric one-way/immutable transitions.
- [x] Normalize output-only fields and exact masks.
- [x] Preserve generated sink writer identity as an output.
- [x] Wire all resources through the shared live provider.

## Component And Product Surface

- [x] Add `ApplicationLogPlatform` with bucket, views, route, exclusions and metrics.
- [x] Add exact API and permission synthesis.
- [x] Add supported Cloud Asset ownership reconciliation.
- [x] Add Logging canvas metadata and topology edges.
- [x] Add explicit ingestion, retention and metric estimates.

## Distribution And Qualification

- [x] Add public example and installed documentation.
- [x] Add local apply/import/refresh/no-op/cleanup receipt.
- [x] Add fail-closed authenticated qualification runner.
- [x] Run Testing v2, examples, migration, typecheck and release checks.
- [x] Record evidence and update roadmaps. Commit M74 as the milestone checkpoint.

## Evidence

The local Testing v2 package gate discovers and executes 790 tests: 789 pass,
one credential-gated test skips, and none fail or remain pending. It reports no
leaks or logged errors. The public example gate passes and the provider catalog
contains 167 managed resources. `zig fmt --check`, the Testing v2 migration
guard, the root TypeScript matrix, `git diff --check` and the static release and
secret gate all pass.

Authenticated qualification remains an external, fail-closed boundary. The
runner cannot report success without a disposable Google Cloud project and
credentials; without them it emits a structured skip receipt.
