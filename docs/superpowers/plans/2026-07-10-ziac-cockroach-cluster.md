# Cockroach Cloud Cluster Implementation Plan

**Goal:** Deliver a protected, mutable GCP Cockroach Cloud cluster resource for
Basic, Standard, and Advanced plans.

**Status:** Completed on 2026-07-10. Authenticated disposable-cloud execution
remains in the M6 live gate because no Cockroach Cloud credentials are present
in this workspace.

## Task 1: Resource Contract And Validation

- Add failing tests for all plan builders, normalized region order, typed
  outputs, default protection, and invalid plan-specific configurations.
- Implement `src/cockroach/cluster.zig` and focused validation helpers.
- Export the resource from `src/cockroach/root.zig`.
- Verify focused builder and full Ziac tests.

## Task 2: Cloud API Models And Requests

- Add failing client tests for exact create, update, delete, and extended cluster
  decode behavior.
- Extend the decoded cluster model with deletion protection and managed sizing
  configuration.
- Add structured request types and serializers for Basic, Standard, and
  Advanced create/update bodies.
- Add client create/update/delete methods and preserve retry/error behavior.
- Verify client tests and JSON fixtures.

## Task 3: Mutable Live Provider

- Add failing lifecycle tests for read, create, polling, diff, update, import,
  and delete.
- Route `cockroach.Cluster` through the live provider.
- Normalize remote clusters into managed observed inputs and typed outputs.
- Implement replacement/update classification and readiness polling.
- Implement idempotent import and delete behavior.
- Verify focused provider and planner tests.

## Task 4: Destructive Confirmation

- Add failing executor and CLI tests for confirmation propagation.
- Add destructive confirmation to `OperationContext` and `ExecuteOptions`.
- Add `destroy --confirm` and pass it only to destroy execution.
- Require declaration unprotection, remote unprotection, and confirmation in
  the cluster delete path.
- Verify the two-deploy destroy workflow and existing CLI compatibility.

## Task 5: Documentation And Gate

- Add the managed-cluster guide and examples for all plans.
- Update the E2E roadmap evidence and Cockroach provider index.
- Run Zig formatting, Ziac tests, examples, package build, zigeffect standard
  and PostgreSQL tests, tool hygiene, and the local TLS Cockroach gate.
- Commit as `Add protected CockroachDB Cloud clusters` only after all checks
  pass.
