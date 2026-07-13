# Ziac Realtime Dashboard And GCP Research Design

Date: 2026-07-13
Status: accepted for implementation

## Objective

Make the local Ziac workbench a truthful realtime surface for agent-driven infrastructure work and give every scaffolded project a specialist, delegateable source of current Google Cloud documentation.

This slice removes two remaining demonstrations from the bootstrap path:

1. dashboard deploys become host-owned asynchronous operations with status and cancellation;
2. workspace topology changes stream as revisioned project patches instead of browser-driven full refresh polling.

It also adds a read-only GCP Developer Researcher to Codex, Claude Code, and Gemini scaffolds. The researcher uses Google's Developer Knowledge API through its official remote MCP server and never stores an API key in generated source.

## Principles

- Local first: compilation, operation supervision, logs, and topology state remain on the developer machine.
- Truthful UI: progress is derived from process state and emitted Ziac events; no invented percentages or phases.
- Bounded authority: only operations started by the dashboard host can be inspected or cancelled through the bridge.
- Revision safety: a patch applies only to the exact base revision it names. A mismatch triggers a snapshot reload.
- Project granularity: one changed Ziac subproject replaces one project slice in the merged workspace artifact.
- Official research: Google claims come from `developers.google.com` or `docs.cloud.google.com`, with API reference and release notes ranked above secondary guides.
- Secret discipline: generated configuration references `DEVELOPERKNOWLEDGE_API_KEY`; it never contains a credential.

## Async Operation Contract

The dashboard bridge gains `watch`, `operation_status`, and `operation_cancel` endpoints. Starting an apply/watch operation returns immediately with a `ziac.dashboard-operation.v1` projection:

- `operation_id`: host-generated, process-scoped identifier;
- `kind`: `apply` or `watch`;
- `phase`: `queued`, `running`, `cancelling`, `cancelled`, `succeeded`, or `failed`;
- `started_at_millis` and optional `finished_at_millis`;
- target project, stack, and stage;
- optional exit code, saved-plan digest, receipt, and bounded diagnostic text.

The host stores a bounded in-memory operation registry and writes stdout/stderr under `.ziac/dashboard/operations/`. A waiter thread owns the spawned child process. Cancellation addresses only a known operation ID and sends a termination signal; it cannot execute arbitrary commands or target an external PID. Final status is derived from process termination and, where available, a parsed Ziac command receipt.

The frontend begins a `watch` operation after saved-plan approval, polls only that operation's compact status while it is active, displays its real phase and emitted events, and exposes cancel while cancellable. Operation polling stops at a terminal phase.

## Workspace Patch Contract

Workspace artifacts gain a deterministic `revision` digest. The host maintains the last published workspace snapshot and observes project source roots in a native host thread. When the workspace compiler produces a new artifact, the host computes `ziac.workspace-patch.v1`:

- `base_revision` and `revision`;
- `changed_projects`, each containing the complete replacement project artifact;
- `removed_project_ids`;
- workspace metadata needed by the merged model.

The initial transport may replace whole project slices; resource-level patches are deliberately deferred. This keeps the merge deterministic and avoids partially updating project ownership or cross-project edges.

The host dispatches a browser custom event when WebUI supports host-to-page JavaScript execution. The bridge validates and applies the patch to the current raw artifact. If the base revision is stale, malformed, or absent, it requests one full snapshot. The browser no longer drives a periodic full-artifact refresh. A bounded host-side scan remains the cross-platform filesystem compatibility mechanism; future OS-native watcher adapters may replace it without changing the patch protocol.

## GCP Developer Researcher

`ziac init` emits the same research skill for all harnesses and a harness-native specialist agent:

- `.agents/skills/gcp-developer-research/SKILL.md`
- `.claude/skills/gcp-developer-research/SKILL.md`
- `.gemini/skills/gcp-developer-research/SKILL.md`
- `.codex/agents/gcp-developer-researcher.toml`
- `.claude/agents/gcp-developer-researcher.md`
- `.gemini/agents/gcp-developer-researcher.md`

Project MCP configuration exposes Google's official endpoint at `https://developerknowledge.googleapis.com/mcp` with only `search_documents` and `get_documents`. Authentication comes from `DEVELOPERKNOWLEDGE_API_KEY`, documented in `.env.example`. The generated Ziac skill tells implementation agents to delegate current or uncertain GCP API, quota, region, pricing, IAM, and availability questions to the researcher.

The researcher protocol is:

1. scope product, API/version, region, date sensitivity, and constraint;
2. search with a focused query;
3. rank exact API/reference, product guide, release note, then concept material;
4. fetch only the most relevant parent documents;
5. reconcile stale or contradictory guidance using update dates and release notes;
6. return `Finding`, `Recommended Ziac implication`, `Constraints`, `Sources`, and `Confidence`;
7. cite official URLs and label inference;
8. never mutate GCP, request secrets, or invent unsupported capabilities.

The Developer Knowledge service is Public Preview, so the scaffold documents a graceful fallback to official web documentation when the MCP server or credential is unavailable.

## Monorepo Behavior

`ziac init --preset self-host` and other root-level workspace setup copy the research skill, specialist agents, `.env.example`, and Google-only MCP configuration to the Git root. Root configuration must not point the Ziac MCP server at an arbitrary child project. Each child project retains its own Ziac MCP entry and can be used independently in CI.

## Installed Agent Development Kit

The installed prefix is a closed client development kit rather than a thin CLI
shim. Alongside the `ziac`, `ziac-mcp`, and `ziac-dashboard-host` executables it
contains the dashboard assets, Ziac and required ZigEffect package sources,
provider contracts, protobuf snapshots, examples, scripts, and the complete
Ziac documentation tree under `share/ziac`.

Generated skills resolve the Ziac dependency path declared by `build.zig.zon`
and use that relocatable directory as their local knowledge root. Local Ziac
documentation describes the shipped implementation and pinned contracts;
Google Developer Knowledge remains authoritative for current GCP API,
availability, IAM, quota, and lifecycle claims. No agent instruction may depend
on the original Ziac source checkout or an author-specific absolute path.

## Security And Privacy

- No API key appears in rendered files, logs, operation receipts, patches, or dashboard sessions.
- The researcher is read-only and cannot call mutating GCP tools.
- Operation output is bounded and passes existing redaction before reaching the browser.
- Patch payloads contain the same secret-free visual artifact contract as snapshots.
- Cancellation is capability-scoped to a host-generated operation ID.

## Acceptance

- Scaffold tests prove all three harnesses receive consistent research instructions, agents, and env-backed MCP configuration.
- A clean scaffold works without a configured key; research becomes available once the environment variable is set.
- An installed-prefix E2E proves the documentation, dashboard, package sources,
  binaries, skills, and agents are available without the source checkout.
- Operation tests prove immediate start, running/terminal status, cancellation, unknown-ID rejection, and bounded output.
- Workspace tests prove deterministic revisions, changed/removed project patches, and stale-base rejection.
- Frontend tests prove patch validation/application and operation lifecycle handling without fake progress.
- Package-native Zig tests, dashboard tests/typecheck/build, scaffold E2E, Testing v2 receipts, and migration hygiene pass.
