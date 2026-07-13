# Ziac M64 Firestore Provider Plan

Date: 2026-07-13
Status: locally complete; authenticated qualification pending

## 1. Typed Resource Layer

- [x] Add failing declaration and graph tests.
- [x] Add Database, Index, Field and BackupSchedule resources.
- [x] Add database IAM member and ownership validation.
- [x] Validate immutable database modes, index shapes, TTL and recurrence.

## 2. Lifecycle Layer

- [x] Add normalized CRUD/import and server-assigned identity handling.
- [x] Add LRO checkpoint/resume for Database, Index and Field mutations.
- [x] Add etag-safe database mutation and IAM compare-and-swap.
- [x] Guard database deletion and implement field override reversion.

## 3. Provider Intelligence

- [x] Register coverage and live-provider dispatch parity.
- [x] Add exact API and deployer/runtime permission synthesis.
- [x] Add Cloud Asset identity and observed/managed reconciliation.
- [x] Add canvas metadata, IAM edge semantics and cost provenance.

## 4. High-Level Component

- [x] Add `DocumentStore` typed args and outputs.
- [x] Compose indexes, field overrides, backups, readers and writers.
- [x] Prove deterministic identity and least-privilege output wiring.
- [x] Keep generated backups and document data outside desired state.

## 5. Qualification And Documentation

- [x] Add apply/import/refresh/no-op/revert/cleanup proof.
- [x] Add fail-closed disposable-project qualification runner.
- [x] Add public docs and a compiling example.
- [x] Run Testing v2, dashboard, typecheck, catalog and migration gates.

Gate: an application team can provision a protected Firestore data plane with
query indexes, TTL, backups and exact runtime access without raw request JSON or
credential material in state.
