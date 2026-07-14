# Ziac M76 Cloud Deploy Provider Plan

Date: 2026-07-14
Design: `docs/superpowers/specs/2026-07-14-ziac-cloud-deploy-provider-design.md`
Status: locally complete; authenticated qualification pending external authority

## Contract And Tests

- [x] Add failing declarations for pipeline, target, custom type, automation and policy.
- [x] Add failing stage, target-union, canary and execution-usage validation tests.
- [x] Add failing automation rule and rollout-policy safety tests.
- [x] Add failing CRUD, exact-mask, etag, LRO resume, import and drift tests.
- [x] Add failing governed release and rollout action tests.

## Typed Primitives

- [x] Implement serial delivery pipelines with standard and canary strategies.
- [x] Implement Cloud Run, GKE, Anthos, multi and custom targets.
- [x] Implement custom target types and execution environments.
- [x] Implement all stable automation rules.
- [x] Implement rollout-restriction deploy policies.
- [x] Pin Cloud Deploy v1 Discovery provenance.

## Hardened Provider

- [x] Add CRUD/import for all five managed resources.
- [x] Checkpoint and resume Cloud Deploy operations.
- [x] Apply exact changed-field masks, current etags and request IDs.
- [x] Normalize output-only state and orderless rule sets.
- [x] Enforce replacement and retained safety boundaries.
- [x] Wire Cloud Deploy through the shared live provider and client endpoint.

## Governed Actions And Component

- [x] Add capability-digested release, promote, approve, advance, rollback,
  cancel and abandon actions with causal receipts.
- [x] Add `GlobalCloudRunDelivery` with regional targets, progression,
  automation and policy.
- [x] Add exact deployer/runtime permission synthesis.
- [x] Add managed and observed Cloud Asset reconciliation.
- [x] Add delivery canvas metadata and topology edges.
- [x] Add explicit pipeline and underlying-service cost estimates.

## Distribution And Qualification

- [x] Add a public example and installed documentation.
- [x] Add local apply/import/refresh/no-op/cleanup and governed-action receipts.
- [x] Add a fail-closed authenticated release/rollout qualification runner.
- [x] Run Testing v2, examples, migration, typecheck and release gates.
- [x] Record evidence and update roadmaps; commit is the final action.

## Evidence

`zig build test` produced a complete Testing v2 receipt with 821 discovered and
executed tests, 820 passed, one credential-gated skip, zero failures, zero
pending tests, zero leaks and zero logged errors. `zig build examples`, installed
distribution checks, the Testing v2 migration guard, root `bun run typecheck`
and `zig build release-gate` pass. The release gate includes static/secret checks
and a Linux arm64 non-root ZigService container probe.

The unauthenticated qualification receipt proves apply, import, refreshed no-op
and cleanup. Governed action tests prove exact payload-bound digests and redacted
release/rollout/recovery receipts. `scripts/qualify-cloud-deploy.sh` returns a
structured exit-77 skip without explicit disposable-project credentials and is
the only boundary permitted to claim authenticated release and rollout proof.
