# Ziac M75 Build And Artifact Delivery Provider Plan

Date: 2026-07-14
Design: `docs/superpowers/specs/2026-07-14-ziac-build-delivery-provider-design.md`
Status: locally complete; authenticated disposable-project qualification pending

## Contract And Tests

- [x] Add failing declaration tests for all six new resource types.
- [x] Add failing trigger locality and event-union validation tests.
- [x] Add failing worker-pool immutable-network and etag tests.
- [x] Add failing connection secret-hygiene and installation-state tests.
- [x] Add failing Artifact cleanup, CMEK and redirection-transition tests.

## Typed Primitives

- [x] Implement modern SCM connections and linked repositories.
- [x] Implement typed repository-event triggers.
- [x] Implement VPC-peered and PSC private worker pools.
- [x] Generalize standard Artifact Registry repositories and cleanup policies.
- [x] Implement retained project settings and regional VPCSC config.
- [x] Register Cloud Build v1/v2 and Artifact Registry provenance.

## Hardened Provider

- [x] Add CRUD/import for the four Cloud Build resources.
- [x] Checkpoint and resume worker-pool, connection and repository operations.
- [x] Apply exact masks and current etags.
- [x] Resolve connection credentials only in mutation scope.
- [x] Extend Artifact Repository and implement both singleton adapters.
- [x] Wire every type through the shared live provider.

## Component And Product Surface

- [x] Add `ZigBuildPipeline` with source, trigger, private pool and artifacts.
- [x] Add exact API and permission synthesis.
- [x] Add supported Cloud Asset ownership reconciliation.
- [x] Add build and artifact canvas metadata and topology edges.
- [x] Add explicit build-minute, disk, storage, transfer and scan estimates.

## Distribution And Qualification

- [x] Add public example and installed documentation.
- [x] Add local apply/import/refresh/no-op/cleanup receipt.
- [x] Add fail-closed authenticated SCM/build qualification runner.
- [x] Run Testing v2, examples, migration, typecheck and non-container release checks.
- [x] Record evidence and update roadmaps. Commit M75 as the milestone checkpoint.

## Evidence

The local Testing v2 package gate discovers and executes 806 tests: 805 pass,
one credential-gated test skips, and none fail or remain pending. It reports no
leaks or logged errors. The public example gate and its dedicated receipt pass,
the provider catalog contains 173 managed resources, and the installed package
contains the new docs, example and qualification runner.

`zig fmt --check`, the Testing v2 migration guard, root TypeScript matrix,
`git diff --check`, installation and the complete release gate pass. The latter
includes static secret checks and the Linux arm64 non-root ZigService container
probe.

Authenticated qualification remains external and fail-closed. With no
credentials or disposable project, `scripts/qualify-build-delivery.sh` returns
exit 77 and an unauthenticated structured skip. It cannot claim success until a
real source trigger produces a successful build, second-state import is no-op
and cleanup completes.
