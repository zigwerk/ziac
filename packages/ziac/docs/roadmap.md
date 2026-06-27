# Ziac Roadmap

## Phase 1: Foundation

- Package scaffold.
- Core graph, outputs, state, planner, provider lifecycle, fake apply engine.

## Phase 2: Local State And CLI

- Local JSON state store.
- `ziac plan`, `ziac deploy`, `ziac destroy`, `ziac outputs`.

## Phase 3: GCP Provider

- GCP provider config.
- Artifact Registry.
- Existing-image Cloud Run service.

## Phase 4: Global GCP Components

- `ziac.gcp.global.ContainerService`.
- Global HTTPS load balancer.
- Multi-region Cloud Run routing.

## Phase 5: Zig Service Preset

- `ziac.gcp.global.ZigService`.
- Zig source to image to global service.
- Comptime environment validation.

## Phase 6: CockroachDB Data Components

- CockroachDB provider config.
- Existing cluster references.
- Database and user resources where safe.
- Connection URL and TLS certificate secret bindings.
- GCP service env validation against CockroachDB outputs.
- Migration hook planning.
