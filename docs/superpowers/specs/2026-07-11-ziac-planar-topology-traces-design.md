# Ziac Planar Topology Traces Design

Date: 2026-07-11

Status: implemented and browser verified

## Problem

The topology currently renders dependencies as elevated Catmull-Rom tubes with
3D cone arrowheads. The arcs compete with resource blocks, obscure labels, and
suggest physical transport pipes rather than logical infrastructure wiring.

## Design Direction

Connections become planar topology traces that sit just above the slab
surfaces. They use orthogonal X/Z paths with short node leads and deterministic
right-angle bends. A trace never rises into an arc, and every segment remains
parallel to a canvas axis so it reads as routed diagram wiring that follows the
slab geometry.

## Semantic Styling

Traces are soft, semi-transparent, and pastel by default:

- public traffic uses muted sky blue;
- private connectivity uses cool gray-blue;
- output wiring uses soft amber;
- IAM/access uses muted green;
- ordinary dependencies use pale neutral gray and a dashed pattern.

Selection increases opacity and width without changing hue. Flat arrowheads
appear for directional traffic, output, connectivity, and IAM traces.
Dependency traces remain softer and do not receive a dominant arrowhead.

## Route Planning

Each route model owns its deterministic planar path. The path:

1. starts at the source block edge facing the target;
2. follows a short lead away from the source;
3. uses a midpoint channel with right-angle bends;
4. approaches the target through a matching lead;
5. ends at the target block edge;
6. keeps every point at one surface height.

The renderer consumes these points directly and never invents topology layout.
Same-slab IAM traces keep their permission badge, but the badge becomes a flat
canvas-aligned decal rather than a camera-facing sprite.

## Acceptance Criteria

- every route path is planar and contains axis-aligned segments only;
- no Catmull-Rom curve, tube, cone, or lifted midpoint remains;
- lines use flat wide-line geometry with semantic pastel colors and opacity;
- selected lines remain clearly distinguishable;
- directional routes use flat arrowheads;
- permission labels lie flat on the same path plane;
- Canvas and all topology modes remain nonblank and readable at desktop/mobile;
- Workbench tests, TypeScript, and production build pass.

## Verification Evidence

- Model tests prove every route stays at one Y coordinate and every segment is
  aligned to either the X or Z canvas axis.
- Architecture, Network, VPC, and Dependencies were rendered in the in-app
  browser with flat lines; top-down and isometric projection switching remained
  stable and refitted immediately.
- The permission fixture rendered its IAM line and label flat inside the
  regional slab.
- The narrow responsive render retained full topology context with zero
  page-level horizontal overflow.
- The full Workbench gate passed 138 tests and 1,121 expectations; TypeScript
  and the Vite production build passed.
