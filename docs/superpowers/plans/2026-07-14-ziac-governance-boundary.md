# M79 Governance Boundary Implementation Plan

Design: `docs/superpowers/specs/2026-07-14-ziac-governance-boundary-design.md`

## 1. Typed Declarations

- [x] Add failing tests for Organization Policy and custom constraints.
- [x] Add failing tests for tag keys, values, bindings and holds.
- [x] Add failing tests for access policies, levels, perimeters and user access
      bindings.
- [x] Validate CEL presence, rule exclusivity, canonical names, service names,
      CIDRs, principals, regions, bridge restrictions and removal intent.
- [x] Add `GovernedProjectBoundary` with collision-free graph composition.

## 2. Hardened Providers

- [x] Add Org Policy v2 CRUD/import with spec etags and exact overwrite.
- [x] Add Resource Manager v3 tag CRUD/import with resumable operations.
- [x] Add Access Context Manager v1 CRUD/import with operation resume and exact
      update masks.
- [x] Prove dry-run/enforced drift, server-assigned identities, immutable
      replacement and governed deletion.

## 3. Product Integration

- [x] Add Org Policy and Access Context Manager client endpoints.
- [x] Pin Discovery contracts and update catalog/dispatcher parity to 196.
- [x] Add exact API/IAM synthesis, Cloud Asset identity, canvas governance
      semantics and honest cost provenance.
- [x] Add local qualification receipt and deterministic product tests.

## 4. Distribution And Evidence

- [x] Add public component example, installed documentation and fail-closed
      authenticated runner.
- [x] Update provider coverage and giant roadmap evidence.
- [x] Run package tests, examples, release gate, migration guard and root
      TypeScript gate; inspect the complete Testing v2 receipt.
