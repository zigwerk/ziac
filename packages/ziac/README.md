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

Select the native provider explicitly for authenticated calls:

```sh
export ZIAC_LIVE_PROJECT=my-project
export ZIAC_LIVE_IMAGE=europe-west1-docker.pkg.dev/my-project/repository/api@sha256:digest
zig-out/bin/ziac deploy --stack hello-global --stage dev \
  --provider gcp --allow-live
```

Credential-gated smoke runs add `--live-test` and require a project ID ending
in `-ziac-disposable`.

For the two-region component stack, also set `ZIAC_LIVE_REGIONS`,
`ZIAC_LIVE_DOMAIN`, and optional `ZIAC_LIVE_DNS_ZONE`, then select
`--stack global-container`.

Add `--json` to any command for the stable `ziac.command.v1` receipt. Commands
that write resource state acquire an exclusive stack/stage lock; `unlock`
requires the recorded lineage unless `--force` is supplied explicitly.

The local CLI currently uses the fixture `hello-global` stack, deterministic
JSON files under `.ziac/state/<stack>/<stage>/`, and a fake provider. Secret
outputs are persisted and printed as `[REDACTED]`.

## GCP Provider Foundation

`hello-global` still defaults to the fake provider while the live CLI safety
gate is under construction. The package now also includes a native live Google
provider for Service Usage, IAM, Artifact Registry, Secret Manager, and Cloud
Run v2. It can enable and disable project APIs, manage service accounts with
drift-aware updates and import, mutate IAM members while preserving policy
etags, conditional bindings, and unrelated fields, manage Docker repositories
with normalized labels and operation polling, create secret versions from
ephemeral source references without retaining plaintext, and deploy
drift-aware Cloud Run services from complete canonical runtime specifications.

The raw global load-balancer surface is implemented, including managed
certificates, explicit certificate readiness polling, an optional HTTP-to-HTTPS
redirect, and Cloud DNS record sets in an existing zone. The high-level
`gcp.global.ContainerService` now assembles those resources with regional Cloud
Run services and typed allocated-IP wiring. The authenticated two-region
acceptance gate and CockroachDB resources remain on the acceptance-gated
roadmap.

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
contracts now canonically constrain typed namespaces and runtime registries.
The build also compiles valid contract fixtures and proves all eight invalid
fixtures fail for their intended stable `ZIAC` diagnostic. Comptime Contracts M2
is complete. The production HTTP contract and native Google ADC layer are also
implemented: authorized-user refresh, native RS256 service-account assertions,
file/URL Workload Identity Federation, optional service-account impersonation,
metadata tokens, secure refresh caching, and `ziac auth doctor` all pass
deterministic tests without invoking `gcloud`. The authenticated Google JSON
client and generic/Compute operation poller are implemented with injectable API
roots, provider error mapping, request-ID diagnostics, cancellation, deadlines,
and `Retry-After` handling.
The CockroachDB Cloud client pins `Cc-Version: 2024-09-16`, keeps API keys
secret, decodes clusters and SQL users through typed schemas, and performs
bounded `Retry-After`-aware pagination. Transport and Authentication M3 is
complete.
The first Live GCP Primitives slice is implemented behind the provider
interface: typed project-service, service-account, and project-member resources
pass full scripted read/diff/create/update/delete/import lifecycles. Service
Usage long-running operations and IAM etag conflict retries are covered. The
credential-gated disposable-project smoke test remains part of the M4 gate.
Artifact Registry create/read/update/delete/import and exact-match conflict
adoption are also implemented; repository location and format changes classify
as replacement while labels update in place.
Secret metadata, append-only versions, and accessor IAM lifecycles are
implemented. State contains only typed secret references, and tracked physical
IDs let refresh address Google-assigned version numbers safely.
Cloud Run v2 create/read/update/delete/import is implemented with live URI and
revision outputs. Create and update operation handles checkpoint before polling
and can resume through normal provider reads after interruption.
Compute global addresses, regional serverless NEGs, backend services, URL maps,
HTTPS proxies, and global forwarding rules now pass scripted lifecycle and
fingerprint-conflict tests.
Managed SSL certificates expose provisioning readiness without holding create
operations open. Redirect URL maps and HTTP proxies pass the same lifecycle
contract. Cloud DNS record sets pass create/read/update/delete/import tests with
stable project/zone/name/type identity.
`gcp.global.ContainerService` builds a deterministic, dependency-complete graph
with restricted direct ingress, optional DNS and HTTP redirect, and production
warm-instance/probe validation.

See `docs/authentication.md`, `docs/google-client.md`, and
`docs/cockroach-client.md` for the live client contracts. See
`docs/secret-manager.md` for the secret payload boundary, and
`docs/cloud-run.md` for the Cloud Run request and lifecycle contract. See
`docs/live-gcp.md` for CLI selection and disposable-project safeguards, and
`docs/compute-load-balancer.md` for the raw load-balancer resources. See
`docs/cloud-dns.md` for existing-zone DNS ownership and import. See
`docs/container-service.md` for the high-level global component. See
`docs/roadmap.md` for the acceptance-gated milestones. The authoritative
design and task-level plan live at the repository root under
`docs/superpowers/specs/2026-07-10-ziac-e2e-delivery-design.md` and
`docs/superpowers/plans/2026-07-10-ziac-e2e-delivery.md`.
