# Ziac M73 Monitoring Provider Plan

Date: 2026-07-14
Design: `docs/superpowers/specs/2026-07-14-ziac-monitoring-provider-design.md`
Status: implementation in progress

## Contract And Tests

- [x] Add failing declaration and validation tests for all six resources.
- [x] Add failing secret-redaction and masked-label normalization tests.
- [x] Add failing synchronous CRUD, canonical import and server-ID tests.
- [x] Add failing dashboard etag and bounded conflict-retry tests.
- [x] Add failing SLO indicator and period validation tests.

## Typed Primitives

- [x] Implement typed alert conditions, strategies and channel wiring.
- [x] Implement HTTP/TCP uptime checks with secret-safe authentication.
- [x] Implement notification channels with split public/secret labels.
- [x] Implement typed mosaic dashboards and common widgets.
- [x] Implement Monitoring services and SLOs.
- [x] Register v3/v1 endpoints, catalog, exports and provenance.

## Hardened Provider

- [x] Add synchronous CRUD/import for all six resource types.
- [x] Preserve server-generated physical IDs across state and import.
- [x] Resolve secrets only inside mutation scope and normalize masked fields.
- [x] Add exact update masks and dashboard etag conflict recovery.
- [x] Normalize output-only mutation, validity and verification fields.
- [x] Wire all resources through the shared live provider.

## Component And Product Surface

- [x] Add `ServiceObservability` with service, SLO, probe, alerts and dashboard.
- [x] Add exact API and permission synthesis.
- [x] Add supported Cloud Asset ownership reconciliation.
- [x] Add monitoring canvas metadata and topology edges.
- [x] Add explicit uptime and alert configuration estimates.

## Distribution And Qualification

- [x] Add public example and installed documentation.
- [x] Add local apply/import/refresh/no-op/cleanup receipt.
- [x] Add fail-closed authenticated qualification runner.
- [x] Run Testing v2, examples, migration, typecheck and credential-free release checks.
- [x] Record evidence and update roadmaps for M73.

## Evidence

M73 is locally complete with 162 managed GCP types. The Testing v2 receipt is
complete with 775 discovered and executed tests, 774 passed, one
credential-gated skip, and zero failures, pending tests, leaks or logged
errors. Public examples, fresh installation, monorepo scaffolding, dashboard
production build, Testing v2 migration, root TypeScript, formatting and static
secret checks pass.

The aggregate container release step remains externally blocked because the
local Docker engine is unavailable. Authenticated Monitoring qualification is
also intentionally external: `scripts/qualify-monitoring.sh` exits with a
structured skip unless ADC, an explicitly disposable project and the exact
qualification graph are supplied.
