# Agent-First Development

Ziac owns the infrastructure control loop. Agents, CLIs, MCP clients and the
Workbench consume the same versioned kernel artifacts:

```text
intent -> compile -> preflight -> simulate -> approve -> deploy
       -> observe -> diagnose -> repair -> verify -> handoff
```

The agent model is replaceable. Ambient credentials, terminal access and an MCP
connection do not grant infrastructure authority.

## Project Contract

`ziac.project.json` declares source roots, components, requirements, fixed-argv
acceptance checks, environment allowlists, resource adaptations, deterministic scenarios
and conservative default permissions. Parsing rejects path escape, duplicate or
dangling IDs, missing required scenario coverage, invalid budgets and default
delete authority.

The representative contract is
`test/fixtures/agent/ziac.project.json`. Applications keep credentials, secret
values and credential-bearing URLs out of this file.

## Agent Commands

Agent commands emit JSON by default:

```sh
ziac agent orient --stack hello-global --stage dev_sean \
  --objective "verify the global API"
ziac agent status --stack hello-global --stage dev_sean
ziac agent next --stack hello-global --stage dev_sean
ziac agent query --stack hello-global --stage dev_sean \
  --resource gcp.run.Service.europe-west1.api
ziac agent explain --stack hello-global --stage dev_sean \
  --event orientation-complete
ziac agent handoff --stack hello-global --stage dev_sean
```

Sessions are atomically persisted beneath `.ziac/agent/<stack>/<stage>/`.
Invalid transitions and duplicate event IDs leave the last durable state
unchanged.

## Development Loops

Ziac distinguishes three loops:

| Loop | Command | Mutation model |
| --- | --- | --- |
| Local hybrid | `ziac dev` | Explicit local/proxy/mock/skip/remote-only adaptations |
| Personal cloud | `ziac deploy --watch` | Immutable OCI digests, no-traffic revisions, readiness then development traffic |
| Governed | `ziac deploy --plan` | Saved digest, capability, budget and approval gates |

The hybrid runtime classifies changes, selects the affected dependency graph,
supersedes stale candidates, promotes only ready process generations, drains
the previous generation and preserves the healthy process on build, spawn,
probe or promotion failure. `ziac dev --watch` runs the manifest-owned native
watcher and proxy; `ziac dev` without `--watch` compiles and reports the explicit
hybrid plan with zero provider mutations.

The OCI planner produces a deterministic OCI application layer, canonical
config and manifest, and an immutable image reference over a pinned base.
Registry adapters ask for blob existence and upload only missing content. The
watch controller coalesces saves and refuses production, destructive changes,
mutable tags and capability mismatches.

## Logs And Diagnosis

`ziac.log.v1` is bounded, ordered, deduplicated and redacted. Eviction,
suppression and truncation remain visible evidence.

```sh
ziac logs --stack hello-global --stage dev_sean --resource service-api
ziac tail --stack hello-global --stage dev_sean --severity warn
ziac log-explain --stack hello-global --stage dev_sean --event condition-failed
```

Cloud Logging starts with deterministic `entries.list` pages and page tokens.
Experimental protobuf-over-HTTP and streaming `entries.tail` are never selected
implicitly. The Workbench Operations view presents the same agent state, causal
events, drop counters and resource identities.

Diagnosis correlates request, revision, deployment digest, `App.Env`, binding,
secret version, runtime identity, IAM, network path and Cockroach locality. A
repair proposal is immutable and non-authorizing. Verification closes only
when permission, binding, network and database checks all pass.

## MCP

Run `ziac mcp serve --project ziac.project.json --stack global-api --stage dev`
to start the newline-delimited stdio server. Scaffolded projects include
`.mcp.json`, `.codex/config.toml`, and `.gemini/settings.json` launch contracts.

The MCP registry advertises only production-backed simulation, proposal and
verification tools. Simulation is read authority, proposal is plan authority,
and verification has its own process authority. Verification executes the exact
manifest argv without a shell and rejects absolute executables, shell
interpreters, parent traversal, oversized arguments and legacy command strings.
Receipts include command and manifest digests. Adding plan/apply tools requires
connecting their saved-plan kernel first; they are not advertised speculatively.

## Ephemeral Environments

Preview leases derive repository-bound `pr-*` stages, WIF subjects, isolated
state prefixes and resource/cost budgets. Expiry denies mutation immediately.
Cleanup accepts only preview stages, is idempotent, and retains redacted
evidence.

## Qualification

Deterministic package and Workbench suites cover the kernels above. Live Google
Cloud, Artifact Registry, Cloud Logging streaming, Cloud Run traffic,
CockroachDB and latency qualification require disposable credentials and remain
separate release evidence. `roadmap.md` lists the exact open authenticated
qualification rather than inferring completion from simulation.
