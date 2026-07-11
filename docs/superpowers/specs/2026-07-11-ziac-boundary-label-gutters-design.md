# Ziac Boundary Label Gutters Design

Date: 2026-07-11

Status: implemented and browser verified

## Problem

Boundary labels are positioned by the renderer inside fixed moat padding. The
global VPC label is 0.82 world units deep while its Z padding is only 0.78, so
the label footprint extends beneath the nearest regional slab and overlaps its
surface text.

## Design

Every account and network boundary owns a model-level label footprint with a
world position and stable dimensions. The enclosing boundary reserves enough
front gutter depth for the complete label plus an inner gap from child slabs.
The renderer consumes this footprint rather than recomputing placement.

The GCP account, global VPC, and external Cockroach account all use the same
contract. Their label footprint must be contained by its boundary and must not
intersect any contained slab or Cockroach locality projection.

## Acceptance Criteria

- boundary labels have model-owned position and size;
- every label footprint is contained by its account/network moat;
- no label footprint intersects a contained plane or locality;
- global VPC and external-account gutters reserve at least the label depth;
- desktop isometric and top-down screenshots contain no slab/moat text overlap;
- Workbench tests, TypeScript, and production build pass.

## Delivery Evidence

- `ZiacSceneBoundary.surface` owns the world-space label footprint.
- Network and external-account front gutters reserve the label depth plus an
  inner gap from child surfaces.
- The scene contract checks containment and non-overlap for every boundary,
  contained slab, and Cockroach locality.
- Desktop isometric and top-down captures are recorded at
  `/tmp/ziac-boundary-label-gutter-3d.png` and
  `/tmp/ziac-boundary-label-gutter-2d.png`.
- 139 Workbench tests and 1,138 expectations pass; TypeScript, the production
  Vite build, and `git diff --check` pass.
