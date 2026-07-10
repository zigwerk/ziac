# Ziac

Ziac is a comptime-checked Infrastructure-as-Code engine for Zig backends,
powered by zigeffect and the zigeffect standard library.

The first product target is an AWSx-style high-level GCP component for globally
routed Cloud Run deployments of Zig HTTP services with CockroachDB data
bindings.

```sh
cd packages/ziac
zig build test
```

## Local CLI

```sh
cd packages/ziac
zig build
zig-out/bin/ziac plan --stack hello-global --stage dev
zig-out/bin/ziac deploy --stack hello-global --stage dev
zig-out/bin/ziac outputs --stack hello-global --stage dev
zig-out/bin/ziac state --stack hello-global --stage dev
zig-out/bin/ziac destroy --stack hello-global --stage dev
```

The local CLI currently uses the fixture `hello-global` stack, deterministic
JSON files under `.ziac/state/<stack>/<stage>/`, and a fake provider. Secret
outputs are persisted and printed as `[REDACTED]`.

## GCP Provider Foundation

The current GCP support is plan-only. `hello-global` now models an Artifact
Registry Docker repository and Cloud Run service, then runs through the local
planner, JSON state store, and fake provider.

Live Google API calls, Cloud Run deployment, load balancers, and CockroachDB
resources are intentionally deferred until the typed provider model is stable.

## Delivery Status

Ziac is currently a tested planning foundation, not yet a live deployment tool.
The end-to-end delivery sequence starts by retaining complete desired resource
inputs and upgrading the provider/state lifecycle before adding authenticated
Google and CockroachDB API operations.

See `docs/roadmap.md` for the acceptance-gated milestones. The authoritative
design and task-level plan live at the repository root under
`docs/superpowers/specs/2026-07-10-ziac-e2e-delivery-design.md` and
`docs/superpowers/plans/2026-07-10-ziac-e2e-delivery.md`.
