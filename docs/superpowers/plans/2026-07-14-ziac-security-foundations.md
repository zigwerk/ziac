# M80 Security Foundations Implementation Plan

Design: `docs/superpowers/specs/2026-07-14-ziac-security-foundations-design.md`

## 1. Typed Declarations

- [x] Add failing tests for SCC source, notification, mute, export and value
      configuration declarations.
- [x] Add failing tests for Binary Authorization policy, attestor and additive
      IAM declarations.
- [x] Add failing tests for CA pool, authority, template, certificate and IAM
      declarations.
- [x] Validate hierarchy/location names, filters, admission rules, public keys,
      X.509 identity, algorithms, lifetimes and retained lifecycle boundaries.

## 2. Hardened Providers

- [x] Add SCC v2 CRUD/import, batch-create and permanent-source semantics.
- [x] Add Binary Authorization singleton policy, attestor and conflict-safe IAM
      lifecycle.
- [x] Add Private CA resumable CRUD/import with immutable replacement and
      retained certificate behavior.
- [x] Prove current etags, exact update masks, server outputs, operation resume
      and rejection of implicit revocation or destructive CA transitions.

## 3. Opinionated Components And Actions

- [x] Add `SecurityFindingPipeline`.
- [x] Add `TrustedArtifactPolicy`.
- [x] Add `PrivateCertificateAuthority`.
- [x] Add target-bound CA state and certificate revocation action contracts.

## 4. Product Integration

- [x] Add endpoints, pinned contracts and catalog/dispatcher parity at 210.
- [x] Add exact API/IAM synthesis, Cloud Asset identity, canvas security
      semantics and honest cost provenance.
- [x] Add deterministic qualification receipt and lifecycle product tests.

## 5. Distribution And Evidence

- [x] Add public examples, installed documentation and fail-closed authenticated
      runner.
- [x] Update provider coverage and giant roadmap evidence.
- [x] Run package tests, examples, release gate, migration guard and root
      TypeScript gate; inspect the complete Testing v2 receipt.
