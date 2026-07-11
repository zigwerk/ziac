# Ziac Scalable 3D Canvas Design

Date: 2026-07-11

Status: implemented and verified

## Problem

The first Three.js canvas establishes the right workspace and topology modes,
but resource identity is still rendered as screen-space CSS2D labels. Labels
appear to hover above objects, slabs do not carry their own scope identity,
resource blocks intersect their slabs, and the fixed plane arrangement will not
remain legible as regions and resources grow.

## Object Identity

Every resource block owns its visible identity. A high-resolution canvas
texture is mapped to the camera-facing front surface and contains:

- friendly service or resource type;
- logical resource name;
- canonical resource ID, wrapped across bounded lines;
- semantic provider/operation accent.

Text is part of the 3D object and therefore pans, zooms, occludes, and scales
with the scene. CSS2D resource and plane labels are removed. The accessible
resource index remains available outside WebGL.

## Slab Identity

Each raised slab receives a top-surface decal texture. Regional slabs show the
GCP region and the compiled VPC/subnet scope. Global, data, project, and local
slabs show their canonical scope name and purpose. Slab text follows the same
isometric perspective as the slab.

## Grounding

Scene geometry uses shared dimensions. The plane top surface is derived from
the slab thickness and each node center is derived from plane top plus exactly
half the resource height. Resource blocks neither intersect nor float above
their owning slab. Routes originate from the top-center connection port of each
block.

## Hover Intelligence

Ray casting includes resource blocks and slabs. Hovering either surface opens a
compact pointer-following tooltip.

Resource tooltips show:

- complete canonical ID, logical name, and provider type;
- provider, scope/region, operation, and health;
- bounded monthly expense forecast;
- observed or explicitly unavailable uptime;
- dependency/connection counts.

Slab tooltips show scope identity, VPC detail, resource count, aggregate monthly
forecast, and aggregate health/uptime. Forecast values are deterministic
presentation estimates until billing telemetry is attached and are labelled as
estimates rather than observed cost.

## Capacity-Aware Layout

Plane dimensions are calculated from their resource count, node footprint,
padding, and gaps. Nodes use a deterministic row/column layout and remain within
their plane bounds without overlap.

Region planes use a deterministic multi-row grid whose column count grows with
region count. Global planes are placed above the region grid; multi-region data,
project, and local planes are packed below it. Bounding dimensions are computed
from placed planes and drive orthographic camera fitting at every resize.

The layout must remain finite and non-overlapping for at least:

- 12 regions;
- 40 resources in one scope;
- 150 visible resources overall;
- desktop and narrow mobile canvas aspect ratios.

## Acceptance Criteria

- no CSS2D label renderer remains in the Ziac canvas;
- resource ID, name, and type are visible on a 3D face texture;
- region/VPC identity is visible on the slab texture;
- node bottoms align to slab tops within a small epsilon;
- resource and slab hover tooltips expose forecast, uptime, health, and scope;
- expanded-topology tests prove bounded, unique, non-overlapping layout;
- Workbench tests, typecheck, build, desktop/mobile browser QA, hover
  interaction, canvas pixels, and console checks pass.

## Implementation Evidence

- deterministic tests cover 12 regions, 48 regional resources, slab and node
  non-overlap, exact grounding, face identity, aggregate telemetry, and narrow
  viewport fitting;
- intrinsic `CanvasTexture` faces and slab decals replace the screen-space
  label renderer entirely;
- live browser checks exercised resource and region-slab ray casting and
  verified tooltip contents, viewport-bounded placement, and no page overflow;
- the renderer dynamically sizes its slab grid and orthographic fit from the
  current filtered resource graph rather than a fixed demonstration topology.
