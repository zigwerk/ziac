# Ziac Spanner, Memorystore, And Private Connectivity Plan

Date: 2026-07-13
Design: `docs/superpowers/specs/2026-07-13-ziac-spanner-memorystore-provider-design.md`

## Contract And Tests

- [x] Pin Spanner, Redis, and Service Networking GA Discovery contracts.
- [x] Add failing declaration tests for all eleven resources.
- [x] Add failing lifecycle tests for CRUD, import, LRO resume and drift.
- [x] Add product tests for components, IAM, estate, visual and cost behavior.

## Typed Primitives

- [x] Implement Spanner instance, database, backup and backup schedule.
- [x] Implement additive Spanner instance/database IAM members.
- [x] Implement classic Redis instance, Redis Cluster and ACL policy.
- [x] Implement private service range and Service Networking connection.
- [x] Export the new modules through the public `ziac.gcp` facade.

## Hardened Providers

- [x] Add Spanner CRUD/import, DDL, IAM and resumable operation handling.
- [x] Add Redis classic/cluster/ACL CRUD/import and operation handling.
- [x] Add private service range and connection CRUD/import/patch handling.
- [x] Normalize maps, DDL, Google defaults, status and output-only fields.
- [x] Enforce replacement and protected data deletion boundaries.
- [x] Wire all managed types through live-provider dispatch.

## Components And Product Surface

- [x] Add `PrivateServiceAccess` with explicit shared-network ownership.
- [x] Add `SpannerDatabase` with backups and least-privilege IAM.
- [x] Add tagged `MemorystoreCache` classic and cluster composition.
- [x] Add API/permission synthesis and runtime role mappings.
- [x] Add Cloud Asset identity and ownership reconciliation.
- [x] Add canvas topology, network, data, backup, ACL and IAM metadata.
- [x] Add explicit configuration-estimate cost models.

## Distribution And Qualification

- [x] Add public examples and agent documentation.
- [x] Add fail-closed authenticated qualification script and receipt schema.
- [x] Compile installed-package examples under Testing v2.
- [x] Run formatting, migration guard, root typecheck and package release gate.
- [x] Record exact receipt counts and update both roadmaps.
- [x] Commit M66 as one independently reviewable milestone.

## Completion Evidence

- Testing v2: 656 discovered and executed, 655 passed, one credential-gated
  skip, zero failures, pending tests, leaks or logged errors.
- Release gate: 131/131 steps succeeded; 668/669 tests passed with one skip.
- Dashboard: TypeScript passed and 55 tests passed.
- Repository TypeScript and Testing v2 migration guard passed.
- Provider catalog: 96 managed resource types.
- Authenticated proof remains external until
  `scripts/qualify-data-services.sh` emits a passing disposable-project
  receipt from a VPC-connected runner.
