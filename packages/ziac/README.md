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
