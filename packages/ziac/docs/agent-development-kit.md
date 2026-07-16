# Ziac Agent Development Kit

The Ziac installation prefix is the client-side development kit used by humans
and agent harnesses. It is relocatable and does not require the original Ziac
source checkout.

## Installed Payload

- `bin/ziac`: project initialization, compilation, planning, deployment, local
  development, estate discovery, logs, and agent workflows.
- `bin/ziac-mcp`: project-local structured tools for graph inspection,
  simulation, proposals, and declared verification.
- `bin/ziac-dashboard-host`: the local dashboard, workspace compiler, project
  patch stream, deploy supervision, logs, status, and cancellation.
- `share/ziac`: Ziac package sources, docs, examples, provider contracts,
  protobuf snapshots, migrations, scripts, and dashboard assets.
- `share/zigeffect*`: the ZigEffect packages required to compile generated Ziac
  projects and run Testing v2.

`ziac init` resolves this prefix from the installed executable and writes
relative Ziac, ZigEffect, and ZigEffect standard-library dependencies into
`build.zig.zon`. Agents use the Ziac dependency path as the local knowledge
root for the exact CLI version installed by the user.

Each generated application also contains `zigeffect.project.json` and tracked
compatibility metadata. Its Zig entry point declares typed services and a root
layer, constructs one managed runtime, and runs requests or jobs as child
effects. The runtime automatically records structural and semantic events into
the embedded NenDB graph. Tests use Testing v2 with the same causal store and
map assertion-local event IDs to durable graph IDs before handoff.

Event-driven projects additionally generate a typed finite statechart and a
durable `EventWorkflow` service. The process opens one crash-safe journal, the
root layer provides it, activities isolate external work, and replay never
repeats a completed activity. Machine definitions and portable projections are
registered under `.zigeffect/statecharts`; live workflow and transition facts
remain queryable in the same NenDB graph. See
[`statecharts-and-workflows.md`](statecharts-and-workflows.md).

## Generated Agent Surfaces

Every initialized workspace receives matching Ziac, GCP research and provider
ecosystem skills for Codex, Claude Code, and Gemini. The generated specialist
team contains a read-only `gcp-developer-researcher`, a test-first
`ziac-provider-creator`, an upgrade-focused `ziac-provider-maintainer` and an
independent `ziac-provider-qualifier`, plus harness-native MCP configuration.
The local Ziac MCP server is scoped to the initialized project. Root monorepo
configuration never selects an arbitrary child project.

Local docs answer what this Ziac version implements. The GCP researcher answers
what Google currently documents, ranks official sources, identifies drift from
the shipped baseline, and returns implications for Ziac. Missing or
credential-gated evidence remains visible rather than being guessed.

Before editing a generated project, agents run the ZigEffect compatibility,
manifest, agent-status, and test-list checks, then `ziac check`. They inspect
`zigeffect graph status --json` and `zigeffect graph since <event-id> --json`
before and after the change so planning and debugging use application evidence
rather than terminal inference.

For stateful control-flow changes, agents also run `zigeffect statechart list
--json` and inspect the affected definition before editing. They keep decisions
pure, add I/O only as idempotent workflow activities, prove replay with a stable
execution key, and compare workflow plus statechart causal records after the
test.

## Operator-Owned Inputs

The kit never generates or stores credentials. Users provide:

- `DEVELOPERKNOWLEDGE_API_KEY` for the Public Preview Google Developer Knowledge
  MCP service;
- Application Default Credentials for authenticated GCP operations;
- Cockroach Cloud credentials only when managing Cockroach resources;
- explicit apply, delete, live-network, project, stage, region, and cost
  authority through Ziac's capability contracts.

A project can compile, test, plan with the deterministic provider, and open the
local dashboard without cloud credentials. Authenticated research and cloud
qualification are separate, explicit gates.

Provider creator and maintainer agents may edit local source but receive no
implicit cloud apply, publication or trust-label authority. The qualifier may
write build artifacts and evidence but must not repair the candidate it is
qualifying. See [`provider-development-kit.md`](provider-development-kit.md).
