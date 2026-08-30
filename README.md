<p align="center">
  <img src="docs/assets/zigwerk-mark.png" width="96" alt="Zigwerk">
</p>

# Ziac

Ziac is an agent-first infrastructure compiler written in Zig and built on
ZigEffect. It specialises in Google Cloud, global Zig backends, compile-time
application/infrastructure validation, causal plans and a local visual
workbench.

## Repository

- [`packages/ziac`](packages/ziac): engine, CLI, GCP provider, CockroachDB
  integration and local dashboard
- [`packages/ziac-gcpx`](packages/ziac-gcpx): opinionated high-level GCP
  components
- [`packages/ziac-templates`](packages/ziac-templates): curated components,
  providers and deployable project templates
- [`apps/ziac-site`](apps/ziac-site): product and documentation website

Ziac's provider model has three layers: broad low-level GCP resources, hardened
lifecycle adapters and opinionated components. Templates remain inspectable
source projects and never masquerade as provider resources.

## Start Here

Ziac currently targets Zig 0.16.0.

The repository pins the ZigEffect v0.1.0 runtime, standard library, Postgres
adapter, and v0.5.0 CLI from the immutable Zigwerk release. A Ziac install
therefore produces both `bin/ziac` and the matching `bin/zigeffect`; generated
agent workflows never depend on a neighbouring ZigEffect checkout.

```sh
bun install
bun run test:ziac
bun run check:frontend
```

For a local CLI distribution:

```sh
cd packages/ziac
zig build install
./zig-out/bin/ziac help
./zig-out/bin/zigeffect --version
```

Read the [CLI and architecture guide](packages/ziac/README.md), the
[provider coverage](packages/ziac/docs/gcp-provider-coverage.md), and
[`CONTRIBUTING.md`](CONTRIBUTING.md).

## Status

Ziac is pre-1.0. Its deterministic local engine and broad provider catalog are
implemented; stable publication still requires the authenticated qualification
and release evidence listed in the roadmap. Cost estimates and observed estate
data are labelled separately from authoritative billing data.

## Licence

Apache-2.0. Ziac is a [Zigwerk](https://github.com/zigwerk) project and is
independent of Google, Cockroach Labs and the Zig Software Foundation.
