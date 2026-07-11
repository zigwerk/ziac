# Ziac Planar Topology Traces Implementation Plan

Date: 2026-07-11

Design:
`docs/superpowers/specs/2026-07-11-ziac-planar-topology-traces-design.md`

Status: complete

## Task 1: Route Contracts

1. Add failing tests for deterministic planar route points.
2. Prove every segment is X- or Z-axis aligned at one Y coordinate.
3. Add renderer contracts that remove curved volumetric route primitives.

## Task 2: Route Planner

1. Derive source and target edge ports from node dimensions.
2. Add short leads and deterministic midpoint channels.
3. Assign pastel semantic route colors.

## Task 3: Flat Rendering

1. Render paths with Three.js wide-line geometry and translucent materials.
2. Add flat planar arrowheads for directional route kinds.
3. Convert IAM badges from sprites to canvas-aligned planes.

## Task 4: Verification

1. Verify Architecture, Network, VPC, and Dependencies modes in the browser.
2. Verify selected-resource emphasis, permission labels, and responsive framing.
3. Run the full Workbench test, typecheck, and production build gate.
4. Update visual documentation and design QA evidence.

## Completion

- Added model-owned source/target edge ports, short leads, midpoint channels,
  and deterministic orthogonal route points.
- Replaced vivid route colors with semantic pastel traffic, connectivity,
  output, access, and neutral dependency tones.
- Replaced Catmull-Rom tubes and cone arrowheads with translucent Three.js
  `Line2` traces and planar triangle arrowheads.
- Converted permission sprites into flat canvas-aligned decals.
- Stabilized top-down projection by disabling OrbitControls updates in 2D and
  refitting on every projection switch.
- Browser QA passed across every topology mode, the permission fixture, and a
  narrow responsive viewport with no new console warnings or errors.
- 138 Workbench tests and 1,121 expectations pass; Workbench TypeScript and the
  Vite production build pass.
