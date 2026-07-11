# Ziac Visual Infrastructure Workbench Design

Date: 2026-07-11
Status: delivered

## Objective

Deliver a first-class visual control surface for Ziac with two synchronized
projections of the same infrastructure truth:

1. a Cloudcraft-style topology canvas for resources, dependencies, traffic,
   output wiring, rollout order, and lifecycle state; and
2. a world map for global Cloud Run regions, Google global load-balancing,
   CockroachDB locality, health, and observed or inferred request routing.

The visual tooling is read-only in this milestone. It explains and inspects the
compiled graph, plan, and state; it never mutates source or cloud resources.

## Product Contract

The UI has four explicit truth modes:

- `desired`: the compiled ResourceGraph;
- `plan`: desired topology annotated with create, update, replace, delete, and
  unchanged operations;
- `live`: provider-observed readiness and drift when observations are present;
- `traffic`: planned, inferred, or observed routes with provenance.

The initial artifact contains desired and plan truth. Live and traffic fields
are versioned now and remain optional so later provider refresh and telemetry
can arrive without changing the rendering contract.

## Visual Artifact

Ziac owns `ziac.visual.v1`. The deterministic JSON artifact contains:

- target metadata: stack, stage, creation time, graph digest, state serial;
- resources with stable IDs, provider, type, logical ID, scope, region,
  lifecycle, safe display inputs, plan operation, health, and source metadata;
- typed edges for dependency, output wiring, traffic, IAM, and connectivity;
- optional global routes, observations, diagnostics, and causal evidence;
- a region catalogue containing only regions used by the graph.

The exporter must redact secret references and credential-bearing values. It
does not serialize arbitrary provider state or secret outputs. Presentation
layout is deliberately excluded from the artifact digest and deployment state.

## Topology Canvas

The existing SolidJS Workbench and G6 adapter remain the UI foundation. Ziac
artifacts receive dedicated `Topology` and `Global Map` tabs while causal
artifacts keep their current tabs and behavior.

The topology canvas provides:

- deterministic default layout grouped by global, regional, GCP, CockroachDB,
  and local scopes;
- official product icon or a restrained provider glyph for every node;
- semantic node states for planned operations and health;
- distinguishable dependency, traffic, output, IAM, and connectivity edges;
- pan, zoom, fit, node selection, search, provider/region/operation filters,
  semantic zoom, a legend, and a resource inspector;
- synchronized selection with the global map.

User layout overrides are browser presentation state keyed by artifact graph
digest. They never modify the Ziac graph, plan, state, or source.

## Global Map

MapLibre GL JS renders the world map and deck.gl renders resource symbols and
great-circle routes. The map provides:

- geographic markers for Cloud Run, serverless NEGs, CockroachDB regions, and
  regional networking;
- a non-geographic global front-door representation for the anycast load
  balancer rather than inventing a fake region;
- request-route arcs whose provenance is always visible as `planned`,
  `inferred`, or `observed`;
- health, plan operation, deployment revision, and database locality overlays;
- synchronized selection, filtering, and inspection with the canvas;
- a table fallback containing the same topology for accessibility and tests.

The checked-in GCP region catalogue is explicit and bounded. Unknown regions
remain visible in the UI with an `unmapped` warning rather than being silently
dropped.

## Browser And Credential Boundary

The browser never receives Google or Cockroach credentials and never calls
provider APIs directly. The Zig process builds the graph, plan, refresh state,
and future telemetry, then sends a bounded redacted artifact through the
existing WebUI or live-attach boundary.

The parser rejects unsupported schemas, malformed identities, duplicate
resources, dangling edges, invalid coordinates, and secret-looking payloads.
Unknown optional fields are tolerated for forward-compatible additive changes.

## Integration Architecture

The existing Workbench loader remains the sole artifact ingress. A schema
router identifies causal versus Ziac visual artifacts. Ziac parsing and view
model derivation live in a separate module so causal parsing does not acquire
provider-specific branches.

The topology and map components are lazy-loaded. MapLibre and deck.gl are not
part of the causal Workbench's initial JavaScript path. Both surfaces consume a
shared Solid selection and filter state owned by the Ziac workspace.

## Acceptance

- Zig serializes a deterministic, redacted `ziac.visual.v1` artifact from a
  ResourceGraph and Plan.
- The global-container stack fixture exposes Cloud Run regions, serverless
  NEGs, global backend, URL map, proxies, forwarding rules, DNS, and CockroachDB
  locality where present.
- The Workbench routes Ziac artifacts to dedicated Topology and Global Map
  views without regressing causal artifacts.
- Canvas selection, map selection, filters, search, inspector, legend, and
  responsive layouts work at desktop and mobile sizes.
- Unit tests cover serialization, redaction, parsing, view-model derivation,
  routes, unknown regions, artifact routing, and UI semantics.
- Typecheck, Workbench tests/build, Ziac tests/examples/build, tool hygiene,
  and visual browser verification pass.

## Deferred Work

- browser-initiated provider mutations;
- drag-to-generate Zig source patches;
- remote collaborative layout storage;
- billing estimates and full Cloud Monitoring ingestion;
- arbitrary third-party cloud providers.
