# M78 Organization and Project Foundation Implementation Plan

Design: `docs/superpowers/specs/2026-07-14-ziac-organization-foundation-design.md`

## 1. Typed declarations

- [x] Add failing declaration tests for folders, projects, liens, billing and
      service identities.
- [x] Validate canonical parents, project IDs, billing accounts, services,
      restrictions and destructive policies.
- [x] Add `ProjectFoundation` with explicit hierarchy and dependency wiring.

## 2. Hardened provider

- [x] Add failing lifecycle tests for server-assigned identity and resumable
      Resource Manager operations.
- [x] Prove exact etag masks, native moves, billing updates, service identity
      generation and retained cleanup.
- [x] Implement import and normalized drift for all five resources.

## 3. Product integration

- [x] Update catalog and dispatcher parity to 186 managed resources.
- [x] Pin Discovery provenance and synthesize exact API/IAM requirements.
- [x] Add official estate identity, canvas hierarchy edges and honest costs.
- [x] Add local qualification and deterministic product tests.

## 4. Distribution and evidence

- [x] Add public example, installed docs and fail-closed remote runner.
- [x] Update coverage and roadmap evidence.
- [x] Run package tests, examples, release gate, migration guard and root
      TypeScript gate; inspect the complete Testing v2 receipt.
