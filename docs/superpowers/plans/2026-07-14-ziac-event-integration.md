# M82 Event Integration Implementation Plan

Design: `docs/superpowers/specs/2026-07-14-ziac-event-integration-design.md`

## 1. Typed Declarations

- [x] Add failing tests for Eventarc Advanced buses, pipelines, enrollments,
      Google API sources and additive resource IAM.
- [x] Add failing tests for connector connections, PSC endpoint attachments,
      event subscriptions, managed zones, regional settings and additive IAM.
- [x] Validate locality, CEL, destination, connector version, node bounds,
      network placement and Secret Manager reference-only credential contracts.

## 2. Hardened Providers

- [x] Add Eventarc Advanced LRO CRUD/import with exact masks and etags.
- [x] Add Connectors resumable CRUD/import, update-only regional settings and
      conflict-safe IAM.
- [x] Prove operation resume, request IDs, replacement boundaries, redaction,
      retained cleanup and import/no-op normalization.

## 3. Components And Governed Actions

- [x] Add `AdvancedEventRoute`, `PrivateConnector` and
      `ConnectorEventBridge`.
- [x] Add target-bound publish, eventing repair, subscription retry and schema
      refresh actions without admitting them to normal reconciliation.

## 4. Product Integration

- [x] Add the Connectors endpoint, two pinned contracts and catalog/dispatcher
      parity at 237.
- [x] Add exact API/IAM synthesis, Cloud Asset identities, canvas event/network
      semantics and assumption-backed cost estimates.
- [x] Add deterministic qualification receipt and lifecycle product tests.

## 5. Distribution And Evidence

- [x] Add public example, installed documentation and fail-closed authenticated
      runner.
- [x] Update provider coverage and giant roadmap evidence.
- [x] Run package tests, examples, release gate, migration guard and root
      TypeScript gate; inspect complete Testing v2 receipts.
