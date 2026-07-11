# Ziac Cloud Estate Hierarchy Implementation Plan

Date: 2026-07-11

Design:
`docs/superpowers/specs/2026-07-11-ziac-cloud-estate-hierarchy-design.md`

Status: complete

## Task 1: Hierarchy Contracts

1. Add failing tests for GCP account, VPC, and external-account boundaries.
2. Prove containment, exclusion, and non-overlap invariants.
3. Add Cockroach locality tests for exact declared regions and primary role.
4. Keep the existing 12-region and mixed-family scale contracts green.

## Task 2: Estate Layout

1. Separate project and external planes into deterministic rows.
2. Derive tight VPC, account, and external-account bounds from placed planes.
3. Include moat extents in scene camera bounds.
4. Derive provider/resource counts and tooltip intelligence per boundary.

## Task 3: Cockroach Localities

1. Read declared regions and optional primary region from canonical resources.
2. Pack locality zones inside the Cockroach account without duplicating nodes.
3. Link each locality to its canonical cluster ID.

## Task 4: 3D Rendering

1. Render recessed account and network moats below child slabs.
2. Render upright account/VPC/provider labels and distinct borders.
3. Render Cockroach regional locality zones and primary/replica labels.
4. Include moats and localities in ray-cast hover intelligence.

## Task 5: Verification And Documentation

1. Run focused and full Workbench tests, typecheck, and production build.
2. Verify hierarchy, hover behavior, desktop/mobile framing, and pixels in the
   in-app browser.
3. Update the roadmap, Workbench guide, and design QA evidence.

## Completion

- Added GCP account, nested global VPC, and provider-neutral external-account
  scene contracts with deterministic non-overlap and containment.
- Added Cockroach Cloud locality projections for all declared regions while
  retaining one canonical cluster resource.
- Rendered recessed hoverable moats, provider account labels, and
  primary/replica locality zones beneath existing resource slabs.
- Corrected top-down camera orientation and made fitting projection-aware down
  to a bounded mobile overview zoom.
- Browser QA passed at desktop and narrow responsive viewports with zero page
  overflow and no new console warnings or errors.
- 137 Workbench tests and 1,010 expectations pass; Workbench TypeScript and the
  Vite production build pass.
