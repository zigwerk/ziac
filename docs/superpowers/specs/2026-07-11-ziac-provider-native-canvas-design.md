# Ziac Provider-Native Canvas Design

Date: 2026-07-11

Status: implemented; final verification complete

## Problem

The intrinsic-label canvas still reads as generic geometry. Slab decals are
rotated away from the default camera, resource-face copy is undersized, mixed
resource types are packed without visible grouping, and permission semantics
are absent from the local topology even when the compiled graph knows that one
resource can read, write, invoke, or administer another.

## Provider Artwork

Ziac checks in the current official Google Cloud product and category PNGs from
the Google Cloud icon library. A provider-owned icon catalogue maps resource
types to Cloud Run, Cloud Storage, networking, security/identity, database, or
serverless artwork. Each GCP resource renders its catalogue icon on the top face
of its 3D block. Unknown GCP types use an official category icon rather than a
fabricated glyph. Non-GCP resources use their provider catalogue or a neutral
provider-owned fallback and are never misrepresented as a Google product.

The icon catalogue is data, independent from layout and rendering. Adding a GCP
resource type does not require changing scene geometry.

## Resource Identity

The front face keeps all three required identity levels: friendly resource
type, logical name, and canonical ID. Type and name receive materially larger
type sizes. Canonical IDs wrap to two bounded monospace lines and remain fully
available in the hover inspector. Textures stay high resolution and scale with
the object.

## Slab And Group Orientation

Slab decals are authored in the same local direction as the default camera, so
region and VPC text reads upright without texture rotation workarounds.

Each slab contains deterministic resource-family groups. A group owns a
bounded top-surface zone, label, provider icon identity, resource count, and
node IDs. Cloud Run services are packed together, buckets together, networking
primitives together, and so on. Groups use stable type-family keys so the same
artifact produces the same placement across runs.

Plane dimensions derive from the packed group grid, and each group derives from
its own node grid. Groups, nodes, and planes must remain non-overlapping for
large fixtures.

## Permission Wiring

`ziac.visual.v1` accepts optional access metadata on an IAM edge:

- `access`: `read`, `write`, `read_write`, `invoke`, or `admin`;
- `permissions`: a bounded, sorted list of provider permission names.

The fields are optional and backward compatible. Ziac does not invent access
from an ordinary dependency. When an IAM/access edge connects resources on the
same slab, the scene draws a low local route inside that slab, labels it with
the access mode, and includes the exact permissions in its hover/accessible
metadata. Cross-slab IAM edges remain normal topology routes.

## Acceptance Criteria

- default-perspective slab text is upright;
- every GCP node has an official top-face icon selected by the catalogue;
- type, name, and ID use a visibly stronger face hierarchy;
- every node belongs to exactly one deterministic resource-family group;
- same-family nodes remain contiguous and inside their group zone;
- group zones and nodes remain non-overlapping under expanded fixtures;
- same-slab IAM edges render as labelled local permission routes;
- the parser validates access modes and bounded permission arrays;
- Workbench tests, typecheck, build, browser hover, desktop/mobile framing,
  official icon loading, canvas pixels, and console checks pass.

## Implementation Evidence

- the checked-in catalogue records the official Google Cloud source archives
  and maps core and category artwork independently from scene geometry;
- a seven-resource permission fixture renders five Cloud Run services and two
  buckets as separate product groups inside one regional slab;
- declared `read_write` and `write` IAM edges render as low local routes with
  visible access badges while preserving their exact permission arrays;
- the original 12-region expanded fixture remains finite and non-overlapping;
- the default sample and dedicated permission sample were browser-verified at
  desktop and narrow responsive viewports with no page overflow.
