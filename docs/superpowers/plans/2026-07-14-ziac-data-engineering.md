# M81 Data Engineering And Orchestration Implementation Plan

Design: `docs/superpowers/specs/2026-07-14-ziac-data-engineering-design.md`

## 1. Typed Declarations

- [x] Add failing tests for recurring Data Pipelines and template workloads.
- [x] Add failing tests for Dataproc clusters, autoscaling, workflow DAGs and
      additive resource IAM.
- [x] Add failing tests for Dataform repositories, workspaces, release/workflow
      configs and additive IAM.
- [x] Validate names, locations, cron/time zones, network and service identity,
      DAG topology, Secret Manager references and immutable boundaries.

## 2. Hardened Providers

- [x] Add Data Pipelines exact-mask CRUD/import without implicit run or stop.
- [x] Add resumable Dataproc cluster lifecycle plus version-safe policy/template
      and conflict-safe IAM lifecycle.
- [x] Add Dataform CRUD/import with server-output normalization, exact masks and
      conflict-safe IAM.
- [x] Prove operation resume, request IDs, versions/etags, replacements and
      retained cleanup.

## 3. Components And Governed Actions

- [x] Add `ScheduledDataflowPipeline`, `DataprocWorkflowPlatform` and
      `DataformReleasePipeline`.
- [x] Add target-bound Data Pipeline run/stop, Dataflow Flex launch, Dataproc
      cluster/workflow and Dataform compilation/invocation actions.

## 4. Product Integration

- [x] Add four endpoints, pinned contracts and catalog/dispatcher parity at 223.
- [x] Add exact API/IAM synthesis, supported Cloud Asset identity, canvas data
      semantics and honest cost provenance.
- [x] Add deterministic qualification receipt and lifecycle product tests.

## 5. Distribution And Evidence

- [x] Add public examples, installed documentation and fail-closed authenticated
      runner.
- [x] Update provider coverage and giant roadmap evidence.
- [x] Run package tests, examples, release gate, migration guard and root
      TypeScript gate; inspect the complete Testing v2 receipt.

Credential-free evidence: `zig build release-gate`, the Testing v2 migration
guard and `bun run typecheck` pass. The package receipt is complete with 919
discovered/executed tests, 918 passed, one credential-gated skip, and zero
failures, pending tests, logged errors or leaks. The installed data-engineering
example receipt is complete at 1/1 passed.
