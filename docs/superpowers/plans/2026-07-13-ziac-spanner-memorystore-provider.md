# Ziac Spanner, Memorystore, And Private Connectivity Plan

Date: 2026-07-13
Design: `docs/superpowers/specs/2026-07-13-ziac-spanner-memorystore-provider-design.md`

## Contract And Tests

- [x] Pin Spanner, Redis, and Service Networking GA Discovery contracts.
- [x] Add failing declaration tests for all eleven resources.
- [x] Add failing lifecycle tests for CRUD, import, LRO resume and drift.
- [ ] Add product tests for components, IAM, estate, visual and cost behavior.

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

- [ ] Add `PrivateServiceAccess` with explicit shared-network ownership.
- [ ] Add `SpannerDatabase` with backups and least-privilege IAM.
- [ ] Add tagged `MemorystoreCache` classic and cluster composition.
- [ ] Add API/permission synthesis and runtime role mappings.
- [ ] Add Cloud Asset identity and ownership reconciliation.
- [ ] Add canvas topology, network, data, backup, ACL and IAM metadata.
- [ ] Add explicit configuration-estimate cost models.

## Distribution And Qualification

- [ ] Add public examples and agent documentation.
- [ ] Add fail-closed authenticated qualification script and receipt schema.
- [ ] Compile installed-package examples under Testing v2.
- [ ] Run formatting, migration guard, root typecheck and package release gate.
- [ ] Record exact receipt counts and update both roadmaps.
- [ ] Commit M66 as one independently reviewable milestone.
