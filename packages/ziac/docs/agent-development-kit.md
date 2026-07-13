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

`ziac init` resolves this prefix from the installed executable and writes a
relative Ziac dependency into `build.zig.zon`. Agents use that dependency path
as the local knowledge root for the exact CLI version installed by the user.

## Generated Agent Surfaces

Every initialized workspace receives matching Ziac and GCP research skills for
Codex, Claude Code, and Gemini, plus a read-only
`gcp-developer-researcher` agent and harness-native MCP configuration. The local
Ziac MCP server is scoped to the initialized project. Root monorepo
configuration never selects an arbitrary child project.

Local docs answer what this Ziac version implements. The GCP researcher answers
what Google currently documents, ranks official sources, identifies drift from
the shipped baseline, and returns implications for Ziac. Missing or
credential-gated evidence remains visible rather than being guessed.

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
