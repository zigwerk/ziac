# Ziac M62 Application Platform Gate Plan

Date: 2026-07-13
Status: in progress

## 1. Integrated Component

- [x] Add failing tests for the complete application-platform graph.
- [x] Add stable naming, typed args and typed outputs.
- [x] Compose Cloud Run, Storage, Pub/Sub, Tasks, Eventarc, scheduled Job and
  Worker Pool through existing components.
- [x] Validate acyclicity, deterministic graph identity and IAM authority.

## 2. Compile-Time And Permission Proof

- [x] Add a valid app `Env` and binding fixture for integrated outputs.
- [x] Preserve missing, extra, secrecy and scope compile-fail coverage.
- [x] Synthesize exact product APIs and deployer/runtime permissions.
- [x] Generate a least-privilege deployer custom-role proposal.

## 3. State And Lifecycle Proof

- [x] Apply through a deterministic provider and persist complete state.
- [x] Import the graph into a second state and require a no-op plan.
- [x] Prove dependency-ordered bounded cleanup and retained-resource survival.
- [x] Prove interrupted LRO recovery through the existing product suites.

## 4. Visual And Cost Proof

- [x] Render every product family in one visual artifact.
- [x] Include IAM access/permission semantics and managed ownership.
- [x] Include configuration-estimate provenance without calling it billed cost.
- [x] Reject secret material in the artifact and receipt.

## 5. Qualification Harness

- [x] Emit a versioned redacted local qualification receipt.
- [x] Add a fail-closed authenticated disposable-project script.
- [ ] Exercise upload, Pub/Sub, Tasks, Eventarc, Job, Worker Pool, import/no-op
  and cleanup when external credentials are available.
- [x] Record a skipped authenticated receipt when configuration is absent.

## 6. Documentation And Gates

- [x] Document component usage and evidence boundaries.
- [x] Update the comprehensive roadmap.
- [x] Run Testing v2, dashboard, typecheck, catalog and migration gates.
- [x] Inspect receipts for complete execution, no pending tests, leaks or logged
  errors.

Gate: the first application-platform tranche composes and recovers as one graph,
and authenticated service delivery remains explicitly separate from local proof.
