# Ziac

## Install And Start A Project

Build and install the CLI, dashboard host, MCP server, control-plane executable,
the Zig package sources, dashboard assets, provider documentation, and agent
research protocols into one relocatable prefix:

```sh
cd packages/ziac
zig build --prefix "$HOME/.local"
export PATH="$HOME/.local/bin:$PATH"
```

Create a fresh Git project and initialize it in place:

```sh
mkdir global-api
cd global-api
git init
ziac init
zig build test
ziac check --stack global-api --stage dev --json
ziac plan --stack global-api --stage dev --json
ziac dashboard --stack global-api --stage dev
```

Bare `ziac init` derives a lowercase hyphenated project name from the current
directory. `ziac init <name>` still creates a named child directory. `--ziac-path` is an
explicit development override; normal installed use resolves the package from
the installation prefix and does not depend on the Ziac source checkout.
In an interactive terminal, `ziac init` first shows the inferred project,
workspace, template, dashboard target, and agent harness setup for confirmation.
Use `--yes` for deterministic scripts and CI.

The generated skills resolve the installed Ziac package through
`build.zig.zon`, so Codex, Claude Code, and Gemini can read the exact provider
and workflow documentation shipped with that CLI version. Current Google Cloud
claims are researched through the official Developer Knowledge connection; the
local docs remain the implementation baseline rather than a substitute for
current upstream documentation.

## Monorepo Workspaces

A Git repository is a Ziac workspace and may contain any number of independently
deployable Ziac projects. Initialize projects in the directories that own their
infrastructure:

```sh
mkdir -p ziac-cloud/platform ziac-cloud/services/payments/infra
cd ziac-cloud
git init
(cd platform && ziac init platform --dir .)
(cd services/payments/infra && ziac init payments --dir .)
ziac dashboard
```

The first initialization installs matching Ziac and GCP developer-research
skills plus a read-only `gcp-developer-researcher` agent for Codex, Claude Code,
and Gemini at the Git root. Set `DEVELOPERKNOWLEDGE_API_KEY` to enable its
official Google Developer Knowledge MCP connection. Later projects synchronize
the same workspace-aware skills. Each project retains its own compiler, state,
locks, authority and CI boundary.

`ziac dashboard` discovers every nested `ziac.project.json`, ignores generated
and dependency trees, compiles each program from its own project directory, and
opens one local dashboard with a merged canvas. The WebUI project menu supports
multi-selection, selected-only rendering, dependency context, and dependency
plus consumer slices. Provider, region, operation, health and estate filters
compose with the project slice.

New projects declare their default dashboard stack and stage in
`ziac.project.json`. Root launches use those per-project targets, while focused
launches can select one project:

```sh
ziac dashboard --project payments
ziac dashboard --artifact-only --out artifacts/workspace.json
```

The native host hashes each project's declared inputs. A changed revision runs
the affected-project compiler through fixed argv, then broadcasts a monotonic
project-slice patch to the WebUI. Stale patches trigger one snapshot reload;
failed recompilation leaves the previous complete canvas available rather than
exposing a partial graph.

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

Google provider modernization is implemented for Cloud Run: a locked Google
descriptor set drives semantic snapshots and upgrade diffs; AIP behavior drives
field masks, etags, drift, and readiness; automatic topology selects native
multi-region Cloud Run or a controlled regional fleet; graph-derived RPC/IAM
requirements drive preflight. Production calls use supported REST transcoding,
and gRPC remains fail-closed until an HTTP/2 adapter passes every qualification
and parity gate.

The visual infrastructure Workbench is implemented. Versioned project and
workspace artifacts drive a synchronized topology canvas and world map for
global Cloud Run, load-balancer routing, plan operations, CockroachDB locality,
and filtered multi-project monorepo slices.

The agent-first kernel now includes a strict project contract, capability and
budget envelopes, durable sessions, hybrid development planning, supervised
reload decisions, bounded causal logs, deterministic OCI/watch deployment,
replayable infrastructure scenarios, governed MCP tools, ephemeral leases and
Cloud Run-to-Cockroach diagnosis. The Workbench Operations view presents the
same session and evidence model. Dashboard watch deploys are host-supervised,
status-addressable and cancellable without granting arbitrary process
authority. Native long-running dev/proxy wiring and live cloud adapters remain
explicitly tracked in `docs/roadmap.md`.

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
zig build proto-snapshot > proto/cloud-run-v2.contract.json
```

Generate the representative visual topology and run the standalone Ziac
dashboard:

```sh
zig build visual-sample > /tmp/ziac-global.visual.json
cd ../..
bun run ziac:dashboard:dev -- --port 5178
```

Open `http://127.0.0.1:5178/`. The dashboard is owned entirely by Ziac; it is
not a sample route inside the ZigEffect Workbench.

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
- `docs/google-rpc.md`: protobuf contracts, transport policy, and GCP specialization
- `docs/gcp-specialization.md`: architecture compiler, AIP planning, IAM/preflight, and qualification
- `docs/visual-workbench.md`: topology canvas, global map, artifact contract, and safety
- `docs/agent-development.md`: agent sessions, hybrid dev, logs, MCP, watch deploy, and leases
- `docs/remote-state.md`: GCS state, locking, migration, and recovery
- `docs/saved-plans.md`: immutable plans and destructive approval
- `docs/keyless-ci.md`: preview stages and GitHub Actions
- `docs/rollouts-recovery.md`: canary progression, rollback, and incidents
- `docs/live-gcp.md`: provider selection and disposable-project safeguards
- `docs/roadmap.md`: acceptance-gated delivery status
