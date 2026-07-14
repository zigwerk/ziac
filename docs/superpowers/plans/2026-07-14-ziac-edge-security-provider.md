# Ziac M70 Edge Security Provider Plan

Date: 2026-07-14
Design: `docs/superpowers/specs/2026-07-14-ziac-edge-security-provider-design.md`
Status: locally complete; authenticated qualification pending

## Contract And Tests

- [x] Add failing declaration and validation tests for all eight resources.
- [x] Add failing Compute fingerprint, replacement and canonical import tests.
- [x] Add failing Certificate Manager LRO and AIP identity tests.

## Typed Primitives

- [x] Implement backend bucket, Cloud Armor and SSL policy declarations.
- [x] Implement managed certificate, DNS authorization, map and entry.
- [x] Implement certificate-map-aware HTTPS proxy.
- [x] Register client API, catalog, exports and provenance.

## Hardened Provider

- [x] Add Compute CRUD, compare-and-swap updates and operation resume.
- [x] Add Certificate Manager CRUD, LRO checkpoint/resume and import.
- [x] Normalize output-only defaults and enforce replacement boundaries.
- [x] Wire all resources through the shared live provider.

## Components And Product Surface

- [x] Add `ProtectedCdnBucket` and `ManagedCertificateMap`.
- [x] Add exact API and permission synthesis.
- [x] Add Cloud Asset ownership reconciliation.
- [x] Add canvas cache, Armor, TLS, DNS and certificate metadata.
- [x] Add explicit CDN, Armor and certificate cost estimates.

## Distribution And Qualification

- [x] Add example, installed documentation and local receipt.
- [x] Add fail-closed authenticated qualification runner.
- [x] Run Testing v2, examples, migration, typecheck and release gates.
- [x] Record evidence, update roadmaps and commit M70.

## Evidence

- `zig build test`: 717 discovered and executed; 716 passed; one
  credential-gated skip; zero failures, pending tests, leaks or logged errors.
- `zig build examples`: passed, including the secure-edge example and fresh
  single-project and monorepo scaffold checks.
- `packages/zigeffect/scripts/check_testing_v2_migration.sh`: passed for eight
  build files and three generated templates.
- `bun run typecheck`: passed across the root, dashboard and both Solid sites.
- `zig build release-gate`: passed, including formatting, static secret checks,
  dashboard build, examples, install/scaffold checks and the non-root arm64
  ZigService container probe.
- `scripts/qualify-edge-security.sh`: fail-closed remote runner is installed;
  missing credentials produce the documented structured exit-77 skip. A pass
  still requires active certificate issuance, proxy attachment, a CDN cache hit
  and an observed Cloud Armor denial in a disposable GCP project.
