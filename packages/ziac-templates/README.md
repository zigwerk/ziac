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
- `event-driven-zig`: a Zig worker foundation with a governed asset bucket and
  Pub/Sub topic.

The CLI copies source and replaces only documented text tokens. Registry
manifests and templates do not contain or run installation hooks.
