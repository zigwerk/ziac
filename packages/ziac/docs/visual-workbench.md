# Visual Infrastructure Workbench

Ziac emits a deterministic, redacted `ziac.visual.v1` artifact that its
standalone dashboard renders as three synchronized infrastructure views:

- **Canvas** shows the compiled resource graph, regional and global groups,
  plan operations, output wiring, request traffic, connectivity, rollout
  dependencies, and lifecycle policy.
- **Global Map** plots Cloud Run and CockroachDB locality in real GCP regions,
  keeps the global external load balancer outside geographic space, and draws
  routes with explicit provenance.
- **Operations** keeps agent state, causal logs, deployment progress, and
  bounded evidence available without leaving the infrastructure context.

The Workbench is read-only. It cannot change Zig source, Ziac state, saved
plans, or provider resources.

## Artifact Contract

`visual_artifact.serializeAlloc` accepts a `ResourceGraph`, an optional `Plan`,
and stack target metadata. It emits:

- stack, stage, state serial, desired graph digest, and truth mode;
- sorted resources with provider, type, logical identity, scope, regions,
  operation, health, ownership, optional discovery provenance, lifecycle,
  reasons, and safe display inputs;
- sorted dependency, output, traffic, IAM, and connectivity edges;
- global-front-door routes with `planned`, `inferred`, or `observed`
  provenance;
- bounded observation and diagnostic extension points.

Secret references and secret-like input fields are replaced by
`{"$secret":"redacted"}` before serialization. The TypeScript parser rejects
unsupported versions, malformed digests, duplicate identities, dangling
edges, collection-count mismatches, and unredacted secret-shaped fields.
Older artifacts default resources to `managed`. Observed and referenced
resources require bounded Cloud Asset Inventory project, observation-time, and
source-name provenance.

Presentation layout is not part of the artifact or graph digest. Panning,
zooming, filtering, selection, and future saved layout preferences cannot alter
deployment identity.

## Generate And Open

The representative fixture is generated from a real three-region
`ContainerService` plus a three-region CockroachDB cluster:

```sh
cd packages/ziac
zig build visual-sample > /tmp/ziac-global.visual.json
cd ../..
bun run ziac:dashboard:dev -- --port 5178
```

The generic API for an application-owned graph is:

```zig
var artifact = try ziac.visual_artifact.serializeAlloc(allocator, &graph, &plan, .{
    .stack = "api",
    .stage = "prod",
    .created_at_millis = now,
});
defer artifact.deinit();
```

For frontend development:

```sh
bun run ziac:dashboard:dev -- --port 5178
```

Open `http://127.0.0.1:5178/` for the generated checked-in sample. Open
`http://127.0.0.1:5178/?sample=estate` for the connected Pro estate
sample with managed and existing GCP infrastructure.

## Truth And Routing

The header always states the current truth mode:

- `desired`: compiled graph without a plan;
- `plan`: compiled graph annotated with plan operations;
- `live`: provider-observed state when live observations are attached;
- `traffic`: measured routing when telemetry is attached.

The current global-container artifact marks routes as `inferred`. They
represent the configured global external Application Load Balancer and
regional serverless NEG topology, not a claim that one request was observed on
that path. Future probe or Cloud Monitoring ingestion must use `observed` and
carry its evidence identity.

Unknown GCP regions remain in the artifact, filters, warnings, and accessible
region list. They are labelled `unmapped` until the pinned coordinate catalogue
is updated.

## Interaction Model

Search and provider, region, operation, and health filters apply to every view.
Selection is shared between the graph, map, resource index, dependency links,
and inspector. The inspector exposes safe inputs, operation, health, scope,
dependencies, consumers, and lifecycle flags.

The Estate scope control filters the same model into `Ziac`, `Existing`, and
`Combined` views. Existing includes observed and referenced resources, swaps
the deploy command for a read-only refresh scan, collapses rollout controls,
and exposes Cloud Asset Inventory provenance in the inspector. Combined keeps
cross-ownership edges visible. The scope fails closed unless the Workbench
session proves Google identity, Pro entitlement, and a connected GCP project.

The canvas uses an orthographic Three.js scene with deterministic raised
global, regional, VPC, project, and CockroachDB planes; beveled resource
blocks; semantic routes; ray-cast selection; shadows; fit, pan/orbit, zoom,
grid, layers, and 2D/3D controls. Every resource maps type, logical name, and
canonical ID onto its front face. Every slab maps region and VPC/scope identity
onto its top surface, so scene identity follows perspective and zoom rather
than hovering in a screen-space label layer.

Resource relationships use model-owned planar topology traces rather than
elevated 3D arcs. Each trace exits a resource edge, follows short leads and
right-angle midpoint channels at one slab-surface height, and approaches the
target edge without leaving the canvas plane. Traffic, private connectivity,
output wiring, and IAM use translucent pastel semantic colors with flat
arrowheads; dependencies use a slightly stronger neutral dashed trace. Selected
relationships gain width and opacity without changing meaning. IAM badges are
flat slab decals on the route, not camera-facing labels.

Hovering a resource exposes health, operation, scope, connection count,
estimated monthly expense, and observed or unavailable uptime. Hovering empty
slab space exposes the equivalent aggregate for that region or scope. Expense
values are deterministic capacity estimates until the Zig host attaches
billing telemetry; the UI never presents them as observed spend.

The canvas also encodes cloud-estate ownership beneath those slabs. A labelled
GCP account moat contains global edge, project, and regional GCP scopes. A
nested global VPC moat contains regional GCP slabs only, keeping global load
balancing and project resources inside the account but outside the network.
Third-party providers occupy peer external-account moats beyond GCP ownership.
Cockroach Cloud renders one canonical cluster slab plus declared regional
locality projections in its own account block; locality tiles identify the
primary or replica role without inventing additional resources. Account,
network, and locality surfaces expose the same bounded operational hover data
as slabs, and camera fitting includes every ownership moat. Boundary labels
occupy model-owned front gutters whose complete footprint is reserved before
child slabs are placed. The GCP account, global VPC, and external account
contracts therefore remain readable without overlapping regional, project, or
locality surfaces as the estate grows.

Plane dimensions derive from visible resource counts and shared geometry.
Resources are packed without overlap, node bottoms align exactly to slab tops,
regions flow into deterministic rows, and camera bounds are recomputed after
mode, filter, or viewport changes. The checked layout contract covers at least
12 regions, 40 resources per scope, and 150 visible resources. Architecture
presents the high-level service topology, Network and VPC emphasize
connectivity, and Dependencies expands the complete provider graph.

The 2D control uses a true top-down camera with upright world orientation;
isometric and top-down fitting use separate padding rules. Narrow viewports may
fit down to a context-first overview while retaining explicit zoom controls for
resource inspection.

Within each slab, resources are first grouped by provider product family and
then packed into a bounded family zone. Cloud Run services, Cloud Storage
buckets, networking primitives, security resources, and database resources
remain visually contiguous as counts grow. GCP blocks use the current official
Google Cloud product or category artwork on their top faces; unknown GCP types
fall back to an official category icon, while non-GCP providers never receive a
Google product mark.

IAM edges may carry optional `access` (`read`, `write`, `read_write`, `invoke`,
or `admin`) and a bounded `permissions` list. Same-slab access renders as a
low-lift local route with an access badge such as `READ / WRITE`; cross-slab
access remains a normal topology route. Ordinary dependencies are never
presented as permissions. Open `?sample=permissions` to exercise the
grouped Cloud Run-to-Cloud Storage permission fixture.

The surrounding command deck uses a 40px global command bar, 34px context mode
strip, 38px icon rail, optional resource navigator, tabbed inspector, and a
108px deployment/log/agent dock. Agent operations share one horizontal command
strip for state, objective, session, next action, and evidence completeness.
The causal timeline uses stable sequence, source, message, evidence, and icon
action columns rather than loose cards or repeated text buttons. These surfaces
remain read-only projections of the artifact and bounded Workbench session.

The world view uses a monochrome CARTO Positron MapLibre basemap with deck.gl
arcs, regional markers, inferred ingress points, and a keyboard-accessible
region strip. Neutral geography and inactive routes leave color available for
selection, health, warnings, and active plan operations.

## Future Live Data

The browser must never receive Google or Cockroach credentials. Refresh,
service health, Cloud Run revision readiness, long-running operation progress,
request IDs, metrics, and probes belong in the Zig host. The host may publish a
new bounded artifact through the existing bridge or live attachment; both views
then update from the same parsed model.

The connected development fixture demonstrates the browser contract only. A
production estate scan still requires the server-side Google identity callback,
subscription lookup, customer GCP authorization or Workload Identity
Federation, Cloud Asset Inventory pagination, and provider-specific resource
hydration.
