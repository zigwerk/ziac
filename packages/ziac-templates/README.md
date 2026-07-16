# Ziac Templates

The registry catalogues providers, components, and editable source templates.
Each package declares its compatibility and immutable manifest digest. A
registry listing is never executable authority: provider installation must pin
an artifact digest and the runtime must complete a `ziac.provider.rpc.v1`
identity handshake before resource operations are available.

Providers:

- `ziac-provider/gcp`: the official bundled Google Cloud provider.
- `ziac-provider/cockroach`: the verified CockroachDB Cloud and SQL provider.

Templates remain source projects, not hidden provider resources:

- `global-zig-api`: a source-built Zig API across Cloud Run regions behind one
  global HTTPS endpoint.
- `hermes-desktop`: a low-cost Hermes Agent backend on Compute Engine for a
  desktop client.
- `event-driven-zig`: a Zig worker foundation with a governed asset bucket,
  Pub/Sub topic, typed finite-state control, durable activity replay, and
  Testing v2 causal evidence.

The CLI copies source and replaces only documented text tokens. Registry
manifests and templates do not contain or run installation hooks.

Application templates ship as canonical ZigEffect applications: each has
colocated Ziac and ZigEffect manifests, tracked compatibility metadata, direct
runtime dependencies, typed services/layers, one managed runtime, automatic
embedded NenDB recording, and Testing v2 causal acceptance evidence. The
Hermes infrastructure-only template remains a pure graph compiler and uses
Testing v2 without inventing an unnecessary process runtime.
