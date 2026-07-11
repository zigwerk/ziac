# Ziac Vision

Ziac is a comptime-checked Infrastructure-as-Code engine for Zig backends,
powered by zigeffect and the zigeffect standard library.

The first product promise is simple: deploy a Zig HTTP service globally on
Google Cloud Run behind a global HTTPS load balancer without hand-assembling the
cloud resource graph.

The first paid product wedge begins one step earlier: connect an existing GCP
project, render its observed estate in the same 3D canvas, and keep that estate
visibly separate from resources owned by Ziac. Users receive value before
adopting a new IaC engine, while Ziac becomes the safe path from observation to
generated code and eventually a proved zero-change adoption.

Ziac follows an AWSx-style product model: high-level components first, raw
resources second. The first high-level components are:

- `ziac.gcp.global.ContainerService`
- `ziac.gcp.global.ZigService`

CockroachDB is the first data provider. Ziac should make database connection
secrets, TLS certificates, and app environment contracts part of the same
comptime-validated graph as the GCP service.

The graph must also be understandable without reading a plan file. Ziac's
visual Workbench is an executable projection of the same typed graph rather
than separately maintained documentation. Its topology canvas explains output
wiring and lifecycle decisions; its world map explains global ingress, regional
Cloud Run placement, CockroachDB locality, health, and routing provenance.

This is a GCP-specialized advantage over generic diagram tools: a comptime
binding error, immutable-field replacement, unavailable provider method,
regional locality defect, or failed long-running operation can be attached to
the exact visual resource and edge that produced it before or during provider
execution.

Estate discovery is read-only by default. Google identity establishes the Ziac
user, a separate subscription fact establishes Pro access, and a distinct
least-privilege GCP connection authorizes inventory reads. OAuth credentials
remain in the Zig host; the Workbench receives only redacted resource
observations and entitlement state.
