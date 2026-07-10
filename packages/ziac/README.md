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
zig-out/bin/ziac refresh --stack hello-global --stage dev
zig-out/bin/ziac import --stack hello-global --stage dev \
  --resource gcp.run.Service.europe-west1.api \
  --id projects/example/locations/europe-west1/services/api
zig-out/bin/ziac unlock --stack hello-global --stage dev \
  --lineage hello-global/dev
zig-out/bin/ziac destroy --stack hello-global --stage dev
```

Add `--json` to any command for the stable `ziac.command.v1` receipt. Commands
that write resource state acquire an exclusive stack/stage lock; `unlock`
requires the recorded lineage unless `--force` is supplied explicitly.

The local CLI currently uses the fixture `hello-global` stack, deterministic
JSON files under `.ziac/state/<stack>/<stage>/`, and a fake provider. Secret
outputs are persisted and printed as `[REDACTED]`.

## GCP Provider Foundation

The current GCP support is provider-simulated. `hello-global` models an Artifact
Registry Docker repository and Cloud Run service, then runs through the local
planner, dependency-ordered zigeffect executor, JSON state store, and fake remote
provider.

Live Google API calls, Cloud Run deployment, load balancers, and CockroachDB
resources are intentionally deferred until the typed provider model is stable.

## Delivery Status

Ziac is currently a tested Engine V2 foundation, not yet a live deployment tool.
It retains canonical desired inputs, refreshes through an explicit provider
lifecycle, persists versioned physical state, and executes stable dependency
levels with bounded parallelism, retry, deadlines, cancellation, and redacted
causal facts. Atomic checkpoint/resume, writer locking, refresh, import, unlock,
stable JSON command receipts, and lineage/serial/graph plan preconditions are
implemented. Engine V2 is complete. Typed public/secret provider outputs and
dependency derivation are implemented. App `Env` field names, optionality, value
types, secrecy, and regional scope now validate at comptime; provider-set
contracts and compile-fail fixtures are next.

See `docs/roadmap.md` for the acceptance-gated milestones. The authoritative
design and task-level plan live at the repository root under
`docs/superpowers/specs/2026-07-10-ziac-e2e-delivery-design.md` and
`docs/superpowers/plans/2026-07-10-ziac-e2e-delivery.md`.
