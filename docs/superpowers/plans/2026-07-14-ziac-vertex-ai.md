# M83 Vertex AI Platform Implementation Plan

Design: `docs/superpowers/specs/2026-07-14-ziac-vertex-ai-design.md`

## 1. Typed Stable Resources

- [x] Add failing tests for dataset, model, endpoint, index, index endpoint,
      feature, online-store, feature-view, tensorboard and metadata declarations.
- [x] Add additive IAM declarations for every stable v1 resource with a native
      IAM surface.
- [x] Validate locality, immutable schemas/artifacts/network placement, bounded
      JSON, labels, references and secret-free inputs.

## 2. Hardened Lifecycle

- [x] Add regional Vertex endpoint selection and pin discovery revision
      `20260704` with its verified SHA-256.
- [x] Add resumable CRUD/import with exact masks, etags, normalized output and
      immutable replacement boundaries.
- [x] Add policy-v3 additive IAM and dispatcher/catalog parity at 253.

## 3. Components And Actions

- [x] Add `OnlinePredictionPlatform`, `VectorSearchPlatform` and
      `FeaturePlatform`.
- [x] Add governed model/index deployment, pipeline run/cancel and feature-view
      sync actions without admitting them to ordinary reconciliation.

## 4. Product Integration

- [x] Add exact API/IAM synthesis and honest Cloud Asset availability.
- [x] Add Vertex canvas semantics and assumption-backed cost estimates.
- [x] Add deterministic qualification receipts and lifecycle product tests.

## 5. Distribution And Evidence

- [x] Add public example, installed documentation and fail-closed authenticated
      runner.
- [x] Update provider coverage and giant roadmap evidence.
- [x] Run package tests, examples, release gate, migration guard, dashboard
      tests and root TypeScript gate; inspect complete Testing v2 receipts.
