# Ziac M72 Container Platform Plan

Date: 2026-07-14
Design: `docs/superpowers/specs/2026-07-14-ziac-container-platform-design.md`
Status: locally complete; authenticated disposable-project qualification pending

## Contract And Tests

- [x] Add failing declarations and validation tests for all seven resources.
- [x] Add failing GKE operation, update-selection and canonical import tests.
- [x] Add failing Fleet and Functions LRO and field-mask tests.
- [x] Add failing Function IAM policy-preservation tests.
- [x] Add failing immutable Batch lifecycle and cancellation-boundary tests.

## Typed Primitives

- [x] Implement GKE Cluster and NodePool declarations.
- [x] Implement Fleet and Membership declarations.
- [x] Implement Functions v2 and additive Function IAM declarations.
- [x] Implement immutable Batch Job declarations.
- [x] Register four API endpoints, coverage, exports and provenance.

## Hardened Provider

- [x] Add Container CRUD/import and native operation resume.
- [x] Add semantic cluster and node-pool update selection.
- [x] Add Fleet and Membership CRUD/import with generic LROs.
- [x] Add Functions CRUD/import plus etag-safe IAM mutation.
- [x] Add synchronous Batch create/read and LRO delete/cancel handling.
- [x] Normalize output-only defaults and wire the shared live provider.

## Components And Product Surface

- [x] Add `GkePlatform` with Standard/Autopilot and Fleet modes.
- [x] Compile Workload Identity into exact service-account IAM.
- [x] Add `ZigFunction` and `ZigBatchJob`.
- [x] Add exact API and permission synthesis.
- [x] Add supported Cloud Asset ownership reconciliation.
- [x] Add canvas metadata, topology edges and explicit cost estimates.

## Distribution And Qualification

- [x] Add public example and installed documentation.
- [x] Add local apply/import/refresh/no-op/cleanup receipt.
- [x] Add fail-closed authenticated qualification runner.
- [x] Run Testing v2, examples, migration, typecheck and release gates.
- [x] Record evidence, update roadmaps and commit M72.

## Evidence

The Testing v2 package gate is complete with 759 discovered and executed tests,
758 passed, one credential-gated skip, and zero failures, pending tests, leaks
or logged errors. The dedicated container-platform example also passes its
Testing v2 receipt with one discovered and executed test. The catalog contains
156 managed resource types.

The installed scaffold test includes the container-platform documentation and
executable qualification runner. All public examples, the Testing v2 migration
guard, root TypeScript gate, formatting, shell syntax and static secret checks
pass. The qualification runner fails closed with a structured exit-77 skip
when ADC, tools or disposable-project configuration are absent. The aggregate
release item remains open because the local Docker daemon is unavailable; no
container or authenticated cloud result is claimed.
