# Ziac Cloud Run Workloads Implementation Plan

## Contract And Declarations

- [x] Add pinned Jobs, Executions and WorkerPools RPC descriptors and path tests.
- [x] Add typed shared containers, Job and WorkerPool declarations.
- [x] Add task, retry, VPC, secret volume, service identity, CMEK and GPU tests.
- [x] Add WorkerPool scaling, revision and instance split tests.

## Lifecycle And Actions

- [x] Add Job normalized CRUD/import and resumable LRO tests.
- [x] Add WorkerPool normalized CRUD/import and resumable LRO tests.
- [x] Add capability-gated run, inspect and cancel action receipts.
- [x] Prove cancellation, timeout, etag conflict and failed execution behavior.

## Components And Scheduler

- [x] Add explicit OAuth Google API targets to Cloud Scheduler.
- [x] Add `ZigJob`, `ScheduledZigJob` and `ZigWorkerPool` graph tests.
- [x] Synthesize exact Run, Scheduler, IAM and act-as permissions.

## Product Completion

- [x] Add provider catalog and dispatcher parity.
- [x] Add Cloud Asset Inventory identity for managed workloads.
- [x] Add workload visual metadata and action receipt status/log URI projection.
- [x] Add vCPU, memory, GPU and duration cost assumptions.
- [x] Add installed documentation and generated-agent references.
- [x] Run Testing v2, dashboard tests and provider-catalog verification.
- [ ] Commit the credential-free M60 milestone.
- [ ] Run authenticated disposable-project qualification when credentials exist.

Local completion keeps authenticated qualification open deliberately. Cloud
Asset Inventory discovers immutable Executions as observations, but they are not
promoted to managed resources or parent-Job drift.

Local evidence: `zig build test -Doptimize=Debug --summary failures` produced a
complete Testing v2 receipt with 564 discovered/executed, 563 passed, one
credential-gated skip, and zero failures, pending tests, leaks or logged errors.
The standalone dashboard has 54 passing tests, clean typecheck and production
build. The Testing v2 migration guard passed, and `ziac provider resources
--service cloud-run --json` reports the five synchronized managed Cloud Run
resource types and capability flags.
