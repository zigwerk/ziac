# Ziac Existing Estate Visualization Implementation Plan

Date: 2026-07-11

Design:
`docs/superpowers/specs/2026-07-11-ziac-existing-estate-visualization-design.md`

Status: complete for the Workbench vertical slice

## Tasks

1. Extend the Ziac manifest with the required estate-visualization intent and
   deterministic acceptance scenario.
2. Add failing parser and filtering tests for managed, observed, referenced,
   and combined estate scopes.
3. Add failing Workbench session tests for fail-closed Google identity, Pro
   entitlement, and GCP connection state.
4. Add failing UI/source tests for the compact estate scope control, observed
   resource identity, and read-only inspector treatment.
5. Implement the backward-compatible visual artifact and estate-access
   contracts.
6. Add a connected, redacted existing-estate development fixture and bridge
   route.
7. Implement synchronized Ziac, Existing, and Combined canvas/map/resource
   filtering.
8. Add observed ownership treatment to Three.js resource faces, tooltips, and
   the resource inspector.
9. Browser-verify the connected sample and locked default state at desktop and
   narrow widths.
10. Update public vision/roadmap documentation and run the complete Workbench
    and relevant Ziac verification gates.

## Completion

- Tasks 1-10 are complete for the redacted artifact, access projection,
  connected sample, canvas experience, and browser workflow.
- Live Google identity, billing entitlement, GCP authorization, and Cloud Asset
  Inventory provider execution remain provider roadmap work and are not claimed
  by this slice.
- 145 Workbench tests and 1,176 expectations pass; TypeScript, production build,
  JSON validation, and whitespace validation pass.
- Ziac `zig build test` exits successfully but produces no Testing v2 suite
  receipt in this worktree, so receipt qualification remains incomplete.
