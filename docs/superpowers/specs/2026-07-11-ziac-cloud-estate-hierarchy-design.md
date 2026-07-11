# Ziac Cloud Estate Hierarchy Design

Date: 2026-07-11

Status: implemented and browser verified

## Problem

The canvas currently places GCP and third-party slabs on one undifferentiated
surface. It does not communicate the account boundary, which regional resources
share a VPC, or that CockroachDB is a peer cloud estate with its own deployment
localities rather than a GCP-native regional resource.

## Estate Hierarchy

The scene adds provider-neutral hierarchical boundaries:

1. a **GCP account** moat contains global edge, project, and regional GCP slabs;
2. a nested **global VPC** moat contains every GCP regional slab and no global
   edge or project-only slab;
3. each third-party provider receives a peer **external account** moat outside
   the GCP account;
4. a Cockroach Cloud account contains the Cockroach cluster slab plus locality
   zones derived from the cluster's declared regions.

Boundaries are scene-model data, not renderer guesses. Future providers can add
accounts and nested networks without changing the 3D primitive contract.

## Spatial Rules

GCP is laid out first: global services above the regional grid, project services
below it, and the VPC tightly wraps the regional grid. The GCP account wraps the
union of these slabs with a larger labelled moat.

Third-party accounts are placed after the complete GCP estate with a stable
inter-estate gap. Their axis-aligned account bounds must not overlap GCP account
bounds. Camera bounds include account moats so fit and responsive behavior
cannot clip ownership context.

The VPC is nested inside the GCP account and must contain all regional slabs.
Global load-balancing and project slabs remain inside GCP but outside the VPC.

## Cockroach Localities

A Cockroach cluster remains one canonical resource. The canvas does not invent
one resource per region. Instead, it derives locality zones from the resource's
`regions` array and marks the configured `primary_region` when available.

Locality zones are packed inside the Cockroach account block, identify their
region and primary/replica role, and reference the canonical cluster resource.
They are topology projections only and never enter resource counts, plans, or
selection identity.

## Rendering

Account moats are thin recessed 3D plates beneath their child slabs with strong
outer borders and upright surface labels. The VPC moat uses a distinct nested
border and restrained green-blue tint. External account moats use provider
accent only at their border and label, preserving the neutral dashboard shell.

Hovering a moat exposes provider, account/network kind, contained resource
count, scope, health, and forecast. Cockroach locality zones expose region,
primary/replica role, and canonical cluster IDs.

## Acceptance Criteria

- the GCP account boundary contains every GCP plane;
- the global VPC contains every regional GCP plane and excludes global/project
  slabs;
- external account bounds do not overlap the GCP account;
- the Cockroach account contains its canonical slab and exactly the declared
  locality regions;
- the primary Cockroach region is marked without duplicating the cluster node;
- boundaries and localities remain finite and non-overlapping at 12 regions;
- camera bounds include all moats;
- account, VPC, external account, and locality hover intelligence works;
- Workbench tests, typecheck, build, desktop/mobile browser QA, canvas pixels,
  and console checks pass.

## Verification Evidence

- Scene contracts prove nested GCP account and global VPC ownership, peer
  external-account separation, exact Cockroach regions, primary locality, and
  canonical resource identity without duplicated nodes.
- Desktop isometric and top-down captures show the complete estate inside
  projection-aware camera bounds.
- The narrow responsive capture has no horizontal page overflow and retains
  the complete GCP and Cockroach estate context at the minimum overview zoom.
- Boundary hover exposed account scope, provider, health, operation, resource
  count, estimated monthly cost, and canonical ID in the live Workbench.
- The full Workbench gate passed 137 tests and 1,010 expectations; TypeScript
  and the Vite production build passed.
