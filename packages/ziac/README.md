# Ziac

Ziac is a comptime-checked Infrastructure-as-Code engine for Zig backends,
powered by zigeffect and the zigeffect standard library.

The first product target is an AWSx-style high-level GCP component for globally
routed Cloud Run deployments of Zig HTTP services with CockroachDB data
bindings.

```sh
cd packages/ziac
zig build test
zig build examples
zig build container-e2e-all
```

`container-e2e-all` generates the same pinned container recipe used by
`gcp.global.ZigService`, builds it for amd64 and arm64 with Zig 0.15.2, and
probes the sample backend as a distroless nonroot container.

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

Select generation-locked GCS state through ADC and migrate an existing local
stack without deleting its local recovery copy:

```sh
export ZIAC_STATE_BUCKET=my-ziac-state
export ZIAC_STATE_PREFIX=ziac/state # optional
zig-out/bin/ziac state-migrate --stack hello-global --stage dev
zig-out/bin/ziac plan --stack hello-global --stage dev
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

The local CLI defaults to the fixture `hello-global` stack, deterministic JSON
files under `.ziac/state/<stack>/<stage>/`, and a fake provider. Explicit live
selection uses the native providers described below. Secret outputs are
persisted and printed as `[REDACTED]`.

## GCP Provider Foundation

`hello-global` still defaults to the fake provider for deterministic local
work. The package also includes a native live Google
provider for Service Usage, IAM, Artifact Registry, Secret Manager, and Cloud
Run v2. It can enable and disable project APIs, manage service accounts with
drift-aware updates and import, mutate IAM members while preserving policy
etags, conditional bindings, and unrelated fields, manage Docker repositories
with normalized labels and operation polling, create secret versions from
ephemeral source references without retaining plaintext, and deploy
drift-aware Cloud Run services from complete canonical runtime specifications.

The raw global load-balancer surface is implemented, including managed
certificates, explicit certificate readiness polling, an optional HTTP-to-HTTPS
redirect, Cloud DNS record sets in an existing zone, and VPC-bound private
managed zones. The high-level
`gcp.global.ContainerService` now assembles those resources with regional Cloud
Run services and typed allocated-IP wiring. It can append a base graph and map a
different typed Direct VPC subnet to each region. The authenticated two-region
acceptance gate remains pending external configuration.

`cockroach.private_service_connect.PrivateServiceConnect` composes a protected
or adopted GCP Cockroach Standard/Advanced cluster with a global-routing VPC,
one PSC endpoint and accepted Cockroach connection per region, private DNS, and
the regional Cloud Run bindings. Every cross-provider value remains a typed
output reference and the graph contains no public Cockroach allowlist.

`gcp.global.ZigService(App, Bindings, Providers)` adds deterministic Zig source
archiving, a generated and digest-pinned nonroot container recipe, protected GCS
build storage, regional Cloud Build, an immutable Artifact Registry image, and
typed image and environment wiring into `ContainerService`. It creates separate
least-privilege build and runtime service accounts and Secret Manager accessor
IAM for each referenced secret. Applications provide source and typed bindings;
they do not provide a Dockerfile or raw load-balancer resources.

## Delivery Status

Ziac is currently a tested Engine V2 and native-provider implementation with
authenticated cloud acceptance still gated on external disposable accounts.
It retains canonical desired inputs, refreshes through an explicit provider
lifecycle, persists versioned physical state, and executes stable dependency
levels with bounded parallelism, retry, deadlines, cancellation, and redacted
causal facts. Atomic checkpoint/resume, writer locking, refresh, import, unlock,
stable JSON command receipts, and lineage/serial/graph plan preconditions are
implemented. Engine V2 is complete. Typed public/secret provider outputs and
dependency derivation are implemented. App `Env` field names, optionality, value
types, secrecy, and regional scope now validate at comptime; provider-set
contracts now canonically constrain typed namespaces and runtime registries.
The build also compiles valid contract fixtures and proves all nine invalid
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
secret, decodes cluster and regional connection topology plus SQL users through
typed schemas, and performs bounded `Retry-After`-aware pagination. Transport
and Authentication M3 is complete. Existing CockroachDB clusters can now be
adopted as retained, read-only resources with deterministic topology drift and
missing-cluster refresh behavior. `cockroach.ConnectionSecret` adds a
secret-first graph for cryptographically generated `verify-full` connection
URIs and idempotent SQL-user create/reset/delete behavior. State retains only
the typed Secret Manager version reference, and a failed user write converges
from that persisted version on retry.
`cockroach.public_egress.PublicStaticEgress` now creates a custom VPC plus one
subnet, router, Premium static address, manual NAT, and SQL-only Cockroach `/32`
allowlist per Cloud Run region. Direct VPC consumes typed network outputs, and
the NAT lifecycle preserves unrelated router configuration during updates and
destroy.
`cockroach.application_database.ApplicationDatabase` now composes the existing
cluster, generated application secret and SQL user, protected database, exact
grants, and immutable ordered migrations. SQLSTATE-aware `psql` and native
`pg.zig` executors are implemented; the native pool requires verified TLS,
rotates idle generations, and passes a reproducible secure CockroachDB container
gate. Provider state and diagnostics retain only typed secret references and
SQLSTATE categories.
`cockroach.cluster.Cluster` now provisions protected GCP Basic, Standard, and
Advanced clusters, polls long-running readiness, updates supported capacity and
topology in place, starts serverless clusters with an empty IP allowlist, and
requires a separate unprotect deploy plus `destroy --confirm` before deletion.
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
with restricted direct ingress, optional DNS and HTTP redirect, regional Direct
VPC selection, base-graph composition, and production warm-instance/probe
validation. Cockroach and GCP PSC resources now pass full scripted lifecycle
tests, including endpoint acceptance and private DNS publication.
GCS remote state uses generation-pinned reads, generation-zero creates,
exact-generation updates/deletes, expiring owner leases, per-checkpoint renewal,
and lineage-preserving local migration. Missing remote ADC fails closed instead
of falling back to local files.

See `docs/authentication.md`, `docs/google-client.md`, and
`docs/cockroach-client.md` for the live client contracts and
`docs/cockroach-existing-cluster.md` for retained cluster adoption. See
`docs/cockroach-cluster.md` for managed cluster plans, scaling, readiness, and
the protected destroy workflow. See
`docs/cockroach-connection-secret.md` for SQL-user and Secret Manager wiring.
See `docs/public-static-egress.md` for the initial public Cockroach connectivity
topology and its production safety policy.
See `docs/private-service-connect.md` for the private multi-region Cockroach
topology, Cloud Run composition, lifecycle, and operations.
See `docs/cockroach-sql.md` for application database composition, SQL resource
lifecycles, migration semantics, and native execution.
See `docs/secret-manager.md` for the secret payload boundary, and
`docs/cloud-run.md` for the Cloud Run request and lifecycle contract. See
`docs/live-gcp.md` for CLI selection and disposable-project safeguards, and
`docs/compute-load-balancer.md` for the raw load-balancer resources. See
`docs/cloud-dns.md` for existing-zone DNS ownership and import. See
`docs/container-service.md` for the high-level global component. See
`docs/zig-service.md` for source-to-image deployment and typed app bindings. See
`docs/remote-state.md` for GCS bootstrap, IAM, migration, conflicts, and
recovery. See
`docs/roadmap.md` for the acceptance-gated milestones. The authoritative
design and task-level plan live at the repository root under
`docs/superpowers/specs/2026-07-10-ziac-e2e-delivery-design.md` and
`docs/superpowers/plans/2026-07-10-ziac-e2e-delivery.md`.
