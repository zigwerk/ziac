# Ziac Scalable 3D Canvas Implementation Plan

Date: 2026-07-11

Design:
`docs/superpowers/specs/2026-07-11-ziac-scalable-3d-canvas-design.md`

Status: complete

## Task 1: Scene Contracts

1. Add failing tests for node/slab dimensions, grounded Y positions, tooltip
   metadata, forecast ranges, and face identity.
2. Add an expanded fixture with many regions and resources.
3. Prove planes and nodes have unique non-overlapping placements and finite
   camera bounds.
4. Update renderer contract tests to require `CanvasTexture` and prohibit
   `CSS2DRenderer`.

## Task 2: Capacity-Aware Scene Model

1. Calculate plane dimensions from resource count and fixed object footprint.
2. Place arbitrary region counts in a deterministic multi-row grid.
3. Pack global and non-regional scopes above and below the regional grid.
4. Derive grounded node positions, route ports, tooltip metadata, and aggregate
   slab intelligence.

## Task 3: Intrinsic 3D Identity

1. Remove CSS2D labels and renderer lifecycle.
2. Generate high-resolution resource-face textures containing type, name, and
   ID.
3. Generate top-surface slab decals containing region and VPC/scope identity.
4. Dispose textures and materials correctly during mode/filter changes.

## Task 4: Hover Intelligence

1. Include node and slab meshes in ray casting.
2. Add pointer-following tooltip state with viewport-safe positioning.
3. Render resource and slab forecast, uptime, health, scope, and count details.
4. Preserve node click selection and pan/orbit behavior.

## Task 5: Verification

1. Run focused and complete Workbench tests, typecheck, build, and diff checks.
2. Verify object faces, slab decals, grounding, tooltips, selection, and modes
   in the in-app browser.
3. Verify desktop/mobile and expanded topology framing with canvas pixel and
   console checks.
4. Update the roadmap, Workbench guide, and design QA history.

## Completion

- Tasks 1-4 are covered by the focused `ziacTopologyScene` contract suite.
- Task 5 includes Workbench tests, TypeScript typecheck, production build,
  desktop/mobile browser renders, resource/slab hover checks, and console
  inspection.
- Final evidence: 128 Workbench tests and 938 expectations passed; TypeScript
  and the Vite production build passed; the captured WebGL crop was nonblank.
- The live scene now derives all capacity, identity, grounding, and telemetry
  presentation from `ziac.visual.v1`; no demonstration-only layout coordinates
  or detached labels remain.
