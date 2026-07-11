# Ziac Provider-Native Canvas Implementation Plan

Date: 2026-07-11

Design:
`docs/superpowers/specs/2026-07-11-ziac-provider-native-canvas-design.md`

Status: complete

## Task 1: Provider Asset Catalogue

1. Extract the official Google Cloud Cloud Run, Cloud Storage, networking,
   security/identity, database, and serverless PNGs into Workbench assets.
2. Add a pure type-to-icon catalogue with deterministic family labels.
3. Test exact core-product mappings and official category fallbacks.

## Task 2: Grouped Scene Contracts

1. Add failing model tests for resource groups and exact membership.
2. Add mixed Cloud Run and Cloud Storage fixtures in one region.
3. Prove group zones, nodes, and planes are bounded and non-overlapping.
4. Keep the existing 12-region scale contract green.

## Task 3: Permission Contract

1. Extend the visual parser with optional validated access and permission
   metadata.
2. Add a same-region Cloud Run-to-bucket read/write edge fixture.
3. Derive local permission routes with access labels and exact permissions.
4. Preserve backward compatibility for existing artifacts.

## Task 4: 3D Rendering

1. Correct slab decal orientation at the default camera.
2. Increase resource-face type hierarchy.
3. Render official icons on resource top faces.
4. Render group zones and labels on each slab.
5. Render labelled low-lift permission routes within slabs.

## Task 5: Verification And Documentation

1. Run focused and complete Workbench tests, typecheck, and production build.
2. Verify desktop/mobile canvas framing and icon/decal loading in the in-app
   browser.
3. Exercise resource, slab, and permission-route hover/selection behavior.
4. Update the Workbench guide, roadmap, and design QA evidence.

## Completion

- 135 Workbench tests and 974 expectations pass.
- Workbench TypeScript and the Vite production build pass.
- All seven provider PNGs return HTTP 200 from the running Workbench.
- Default and permission samples were browser-verified at desktop and narrow
  responsive viewports; the latter has zero horizontal page overflow.
- The permission fixture visibly renders official icons, family zones,
  `READ / WRITE` and `WRITE` routes, upright slab text, and larger face copy.
- The captured WebGL crop is nonblank with Y 51-255 and mean 236.799.
