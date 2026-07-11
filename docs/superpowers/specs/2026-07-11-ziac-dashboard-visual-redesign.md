# Ziac Dashboard Visual Redesign

Date: 2026-07-11

Status: implemented and verified

Visual references:

- Concept 3 is the source of truth for the canvas, topology depth, rails, and
  event timeline.
- Concepts 2 and 3 are the source of truth for panel density, navigation,
  investigation, and operational views.
- The existing `ziac.visual.v1` artifact remains the only source of
  infrastructure truth.

## Product Intent

Ziac should feel like a compact GCP operations console whose primary surface is
an explorable infrastructure model. The canvas must make global routing,
regional Cloud Run services, network boundaries, and CockroachDB locality
understandable before the operator reads a table. Panels should help an agent or
human inspect, deploy, and debug without displacing the topology.

## Desktop Composition

The desktop workspace uses four persistent horizontal bands:

1. A 48px global bar with product identity, stack/stage context, command search,
   graph identity, agent state, plan state, deploy action, and profile.
2. A 42px context bar with Canvas, Global Map, and Operations views; topology
   modes; filters; and live-state context.
3. A fluid work area with a 56px icon rail, an optional 208px resource
   navigator, the main visual surface, and a 304px inspector.
4. A 132px operational dock with Deployments, Live logs, and Agent runs tabs.

The canvas owns the majority of the viewport. Navigation and inspector panels
use 1px dividers instead of floating cards. Compact controls use 4-6px radii.

## Three-Dimensional Canvas

The topology view is an orthographic Three.js scene with:

- a pale isometric square grid;
- raised global, regional, VPC, subnet, and data planes;
- rounded, beveled resource blocks with provider/service accent bands;
- orthogonal or gently curved routes with directional arrowheads;
- distinct traffic, private connectivity, replication, IAM, output, and
  dependency treatments;
- hover and selected states resolved through ray casting;
- pan, orbit, zoom, fit, 2D/3D, layers, and grid controls;
- synchronized selection with the navigator, inspector, map, and event dock.

Architecture mode shows the complete compiled graph. Network mode emphasizes
traffic and connectivity. VPC mode emphasizes regional boundaries and private
paths. Dependencies mode emphasizes output, IAM, and dependency wiring.

The renderer is presentation-only. It never mutates resource identity, graph
digest, layout-independent state, or deployment source.

## Resource Representation

Resources are grouped by scope and region. The renderer recognizes Cloud Run,
global HTTPS load balancing, DNS/TLS, VPC/network resources, Artifact Registry,
Secret Manager, service accounts, and CockroachDB resources. Unknown resource
types receive a neutral block while preserving their real label and type.

Colors are semantic accents rather than provider-wide fills:

- blue: public traffic and selected GCP compute/network resources;
- green: healthy state and successful traffic;
- amber: plan/build/reconciliation;
- red: unhealthy, destructive, or failed state;
- violet: CockroachDB replication only;
- neutral gray: dependency, IAM, unchanged resources, and inactive map data.

## Global Map

The global map uses a modern monochrome basemap. Land, water, borders, labels,
and controls remain neutral. Color is reserved for selected routes, health,
warnings, plan operations, and active deployment regions. Region markers and
route arcs preserve the same selection model as the canvas and inspector.

## Operational Panels

The inspector provides Overview, Traffic, Revisions, and YAML tabs. Overview
shows identity, health, scope, operation, lifecycle, dependencies, consumers,
and safe inputs. Traffic derives related routes. Revisions and YAML use bounded
artifact data and clearly label unavailable live data.

The bottom dock provides Deployments, Live logs, and Agent runs. It reuses the
existing bounded Workbench session and log evidence. The deploy action is a
read-only prototype state until an explicit mutation contract is added to the
host bridge.

## Responsive Behavior

At widths below 980px, the resource navigator is hidden and the inspector
becomes a compact lower sheet. The canvas remains interactive and fills the
available width. At mobile widths, the global bar keeps stack context, view
switching, and plan state; secondary labels collapse; the operational dock
becomes a horizontally scrollable evidence strip without page-level horizontal
overflow.

## Acceptance Criteria

- the topology is rendered by Three.js and remains nonblank at desktop and
  mobile canvas sizes;
- all primary view, mode, selection, inspector-tab, dock-tab, and deploy-state
  interactions work;
- the map is visually monochrome until semantic state requires color;
- the current Ziac sample remains fully navigable and its artifact parser is
  unchanged;
- focused tests, typecheck, production build, desktop/mobile screenshots,
  canvas pixel checks, and design QA pass.
