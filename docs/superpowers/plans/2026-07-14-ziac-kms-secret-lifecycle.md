# M77 KMS and Secret Lifecycle Implementation Plan

Design: `docs/superpowers/specs/2026-07-14-ziac-kms-secret-lifecycle-design.md`

## 1. Typed declarations

- [x] Add failing tests for CryptoKey templates/rotation and version state.
- [x] Add failing tests for KMS conditional IAM declarations.
- [x] Add failing tests for Secret replication, rotation and safe version policy.
- [x] Implement declarations and validation while preserving old call sites.

## 2. Hardened providers and actions

- [x] Add failing KMS provider tests for remote drift, exact masks and retained versions.
- [x] Add failing Secret provider tests for immutable replication, exact masks, etags and disable cleanup.
- [x] Add failing governed-action tests for KMS destroy/restore and secret destruction.
- [x] Implement provider normalization, CRUD/import and action receipts.
- [x] Reuse conditional IAM policy mutation with KMS and Secret Manager endpoints.

## 3. Product intelligence

- [x] Update catalog and dispatcher parity to 181 resources.
- [x] Add pinned Discovery provenance, APIs and exact permissions.
- [x] Add supported estate identities, canvas security edges and honest costs.
- [x] Add deterministic product integration and local qualification tests.

## 4. Distribution and evidence

- [x] Add installed documentation, public example and fail-closed qualification script.
- [x] Update coverage reference and giant roadmap with evidence.
- [x] Run focused tests, all examples, package test, install gate, release gate,
      Testing v2 migration guard and root TypeScript check.
- [x] Inspect the Testing v2 suite receipt for complete equal execution, zero
      pending tests, failures, leaks and logged errors.
