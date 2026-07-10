# Ziac

Ziac is a comptime-checked Infrastructure-as-Code engine for globally deployed
Zig services on Google Cloud, powered by zigeffect. It combines an Engine V2
resource lifecycle with high-level GCP and CockroachDB components.

The defining contract is static: an application `Env` struct, typed resource
outputs, provider availability, secrecy, scope, and dependency wiring must agree
before provider code can run.

## Status

The credential-free release gate is implemented. Native GCP and CockroachDB
providers have deterministic lifecycle and failure tests, the complete
production graph compiles, and local CockroachDB transport passes verified TLS.
Authenticated GCP and Cockroach Cloud acceptance remains an explicit external
gate until disposable account configuration is supplied.

## Quickstart

From this package directory:

```sh
zig build release-gate --summary all
```

The gate checks formatting, all unit and compile-fail contracts, provider
lifecycles, interruption and state migration behavior, examples, the CLI,
secret leakage, and a native source-built Zig container. Docker is required for
the container probe.

For a faster edit loop:

```sh
zig build test
zig build examples
zig build
```

The complete source, CockroachDB, PSC, Secret Manager, Direct VPC, Cloud Run,
global load balancer, DNS, and canary composition is in
`examples/production_global_service.zig`. Its executable path is build-cache
specific; `zig build examples` is the supported graph proof.

## Local Engine

The CLI defaults to a deterministic fake provider and local state under
`.ziac/state/<stack>/<stage>/`:

```sh
zig build
zig-out/bin/ziac plan --stack hello-global --stage dev
zig-out/bin/ziac deploy --stack hello-global --stage dev
zig-out/bin/ziac outputs --stack hello-global --stage dev
zig-out/bin/ziac refresh --stack hello-global --stage dev
zig-out/bin/ziac state --stack hello-global --stage dev
zig-out/bin/ziac destroy --stack hello-global --stage dev --confirm
```

Commands that mutate state take an exclusive writer lock. State and command
receipts persist secret references or `[REDACTED]`, never secret plaintext.

## Production GCP

Ziac uses native Application Default Credentials; it does not invoke `gcloud`.
Use user ADC locally or Workload Identity Federation in CI. Select GCS state
before the first production plan:

```sh
export ZIAC_STATE_BUCKET=my-ziac-state
export ZIAC_STATE_PREFIX=ziac/state
export ZIAC_LIVE_PROJECT=my-project
export ZIAC_LIVE_IMAGE=europe-west1-docker.pkg.dev/my-project/apps/api@sha256:<64-hex-digest>
export ZIAC_LIVE_REGIONS=europe-west1,us-central1
export ZIAC_LIVE_DOMAIN=api.example.com
export ZIAC_LIVE_DNS_ZONE=example-com

zig-out/bin/ziac auth doctor
zig-out/bin/ziac plan --stack global-container --stage prod \
  --provider gcp --allow-live \
  --out artifacts/global-container-prod.plan.json
zig-out/bin/ziac deploy --stack global-container --stage prod \
  --provider gcp --allow-live \
  --plan artifacts/global-container-prod.plan.json
```

If a saved plan contains deletion or replacement, pass the exact digest printed
by `plan` through `--approve`. Lifecycle protection still requires a separate
unprotecting deploy and cannot be bypassed by approval.

The built-in global stack deploys the primary region first, waits for Cloud Run
revision readiness, and only then releases the remaining regions. It restricts
direct Cloud Run ingress and routes HTTPS through a Premium global external
Application Load Balancer.

## CockroachDB

The complete example adopts an existing Standard or Advanced Cockroach cluster,
creates the application database/user/grants/migrations, stores the generated
`verify-full` connection URI in Secret Manager, provisions PSC and private DNS
in each region, and binds the secret output into `App.Env.database_url`.

Managed Basic, Standard, and Advanced cluster resources are also available.
Managed clusters and databases are protected by default; deletion requires a
separate unprotect deploy followed by an explicitly confirmed destroy.

For local verified-TLS transport evidence:

```sh
cd ../..
bun run zigeffect:postgres:cockroach-live-test
```

## Recovery

Cloud Run state retains the current and previous immutable image digest. A
guarded rollback uses the same provider, lock, checkpoint, and remote-state
path as deploy:

```sh
zig-out/bin/ziac rollback --stack global-container --stage prod \
  --provider gcp --allow-live --confirm
```

After interruption, rerun the same deploy. Ziac resumes provider operation
handles from state. For drift, run `refresh`, review a new saved plan, and
deploy. Do not force-unlock an active writer.

## CI And Release

`examples/github-actions/ziac-preview.yml` is the keyless GitHub Actions
template. It derives repository-bound preview stages, uses GCS state and saved
plans, gates apply and cleanup through environments, and never needs a Google
service-account key.

Authenticated release tests are declared without values in
`release/live-tests.json`. Run `bash scripts/live-global-gate.sh` only against a
project ending in `-ziac-disposable`; the script validates two regions, global
HTTPS, denied direct ingress, regional failure/recovery, final no-op planning,
secret absence, and cleanup.

See `docs/release.md` for the clean-checkout release procedure and evidence
policy.

## Documentation

- `docs/architecture.md`: engine, graph, provider, output, and source-build model
- `docs/zig-service.md`: source-to-image component and app binding contract
- `docs/container-service.md`: global Cloud Run and load-balancer component
- `docs/private-service-connect.md`: private CockroachDB regional topology
- `docs/cockroach-sql.md`: database, grants, migrations, and native TLS
- `docs/authentication.md`: native ADC and Workload Identity Federation
- `docs/remote-state.md`: GCS state, locking, migration, and recovery
- `docs/saved-plans.md`: immutable plans and destructive approval
- `docs/keyless-ci.md`: preview stages and GitHub Actions
- `docs/rollouts-recovery.md`: canary progression, rollback, and incidents
- `docs/live-gcp.md`: provider selection and disposable-project safeguards
- `docs/roadmap.md`: acceptance-gated delivery status
