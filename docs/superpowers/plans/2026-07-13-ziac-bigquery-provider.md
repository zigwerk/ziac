# Ziac M63 BigQuery Provider Plan

Date: 2026-07-13
Status: locally complete; authenticated qualification pending external credentials

## 1. Typed Resource Layer

- [x] Add failing declaration and graph tests.
- [x] Add Dataset, Table, View and Routine resources.
- [x] Add Connection, Reservation, Commitment and Assignment resources.
- [x] Add additive scoped IAM resources and overlap validation.

## 2. Lifecycle Layer

- [x] Add BigQuery v2 normalized CRUD/import.
- [x] Add Connection and Reservation v1 CRUD/import with field masks.
- [x] Add etag-safe IAM mutation with bounded conflict retries.
- [x] Guard non-empty dataset deletion and expensive commitment deletion.

## 3. Provider Intelligence

- [x] Register coverage and live-provider dispatch parity.
- [x] Add exact API and deployer/runtime permission synthesis.
- [x] Add Cloud Asset identity mappings and observed/managed reconciliation.
- [x] Add visual groups, dependency semantics and cost provenance.

## 4. High-Level Component

- [x] Add `AnalyticsWarehouse` typed args and outputs.
- [x] Compose tables, views, routines, readers and writers from one dataset.
- [x] Keep connections and reservations explicit and commitments opt-in.
- [x] Prove deterministic graph identity and least-privilege output wiring.

## 5. Qualification And Documentation

- [x] Add full fake-provider apply/import/refresh/no-op/cleanup proof.
- [x] Add fail-closed disposable-project qualification runner.
- [x] Document resource and component usage plus credential exclusions.
- [x] Run Testing v2, dashboard, typecheck, catalog and migration gates.

Gate: a platform engineer can provision a useful BigQuery warehouse and its
workload capacity without raw JSON, hidden IAM ownership or credential material
in Ziac state.

Local evidence: 602 tests discovered and executed, 601 passed, one existing
credential-gated skip, and zero failures, pending tests, leaks or logged errors.
The authenticated runner remains deliberately unclaimed until it emits a passed
receipt from a disposable Google Cloud project.
