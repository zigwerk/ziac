# Ziac Vision

Ziac is a comptime-checked Infrastructure-as-Code engine for Zig backends,
powered by zigeffect and the zigeffect standard library.

The first product promise is simple: deploy a Zig HTTP service globally on
Google Cloud Run behind a global HTTPS load balancer without hand-assembling the
cloud resource graph.

Ziac follows an AWSx-style product model: high-level components first, raw
resources second. The first high-level components are:

- `ziac.gcp.global.ContainerService`
- `ziac.gcp.global.ZigService`

CockroachDB is the first data provider. Ziac should make database connection
secrets, TLS certificates, and app environment contracts part of the same
comptime-validated graph as the GCP service.
