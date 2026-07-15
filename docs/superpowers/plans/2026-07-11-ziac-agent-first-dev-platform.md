# Ziac Agent-First Development Platform Implementation Plan

**Canonical status:** Shipped for the local agent platform. Authenticated
closed-loop and paid-estate qualification moved to M84 and M88 in
`packages/ziac/docs/roadmap.md`.

Date: 2026-07-11
Design: `docs/superpowers/specs/2026-07-11-ziac-agent-first-dev-platform-design.md`

## M11: Agent Contract And Authority

- [x] Add strict `ziac.project.v1` parsing and validation.
- [x] Add requirements, acceptance checks, environments and adaptation rules.
- [x] Add capability envelopes and autonomy budget evaluation.
- [x] Add durable agent session states and validated transitions.
- [x] Add status, next, graph query, event explain and handoff artifacts.
- [x] Add `ziac agent` JSON CLI surface and representative project fixture.
- [x] Add invalid contract, capability, transition and redaction tests.

Gate: an agent or human can orient to the fixture project, receive one bounded
next action, query the global API graph, and produce a truthful handoff without
reading terminal prose.

## M12: Dev Runtime And Hybrid Resources

- [x] Add `.dev` phase and typed resource adaptation decisions.
- [x] Add source/config/image/topology/destructive change classification.
- [x] Add affected-subgraph computation and stale-work convergence.
- [x] Add supervised process generations and atomic proxy promotion model.
- [x] Add readiness, drain, rollback and cancellation behavior.
- [x] Add local public/secret binding resolution with strict redaction.
- [x] Add native watcher/process/probe adapters and `ziac dev`.
- [x] Add local Cockroach strategy and remote-only PSC/VPC evidence.

Gate: an executable fixture serves through a stable local proxy, promotes a new
healthy binary after a source change, and retains the old binary when build or
readiness fails.

## M13: Unified Causal Logs

- [x] Add `ziac.log.v1` event, field, source and identity schemas.
- [x] Add bounded ordered store, deduplication, truncation and drop evidence.
- [x] Add secret-shaped field and message redaction.
- [x] Add compiler, process, proxy, provider, health and agent ingestion.
- [x] Add Cloud Logging request/response normalization and cursor polling.
- [x] Add `tail`, `logs` and `explain` filters and JSONL output.
- [x] Add live Workbench session feed, timeline and investigation panels.

Gate: one local reload and one scripted Cloud Run failure appear in order in
CLI and Workbench, share causal IDs, redact sentinels, and expose dropped or
suppressed evidence.

## M14: Fast OCI And Watch Deploy

- [x] Add deterministic OCI layer/config/manifest planning.
- [x] Add registry blob existence and upload provider contracts.
- [x] Add content-addressed local cache and base-manifest lock.
- [x] Add watch-deploy coalescing, cancellation and newest-digest convergence.
- [x] Add development-stage and capability guardrails.
- [x] Add no-traffic/tagged revision, readiness and traffic progression model.
- [x] Add `deploy --watch` JSON event stream and timing receipts.

Gate: a scripted registry proves unchanged blobs are not uploaded, two rapid
saves deploy only the newest digest, and production or destructive changes are
rejected without exact authority.

## M15: Governed Agent Tools And Scenarios

- [x] Add deterministic infrastructure scenario definitions and replay tokens.
- [x] Implement region, quota, IAM, etag, interruption, LRO, gateway, secret,
  reload and rollback scenarios.
- [x] Add saved repair proposal artifacts and requirement verification.
- [x] Add MCP request/response schemas and read-only tool registry.
- [x] Add proposal, verification, exact-plan apply and handoff tools.
- [x] Add generated Codex/Claude skill guidance from the same registry.
- [x] Add capability tests proving MCP cannot expand authority.

Gate: MCP and CLI produce byte-equivalent kernel artifacts; simulation is
replayable; proposal cannot apply; exact-plan apply remains capability-gated.

## M16: Ephemeral Environments And Closed Loop

- [x] Add TTL lease, heartbeat, expiry and cleanup state.
- [x] Add repository-bound stage, WIF, GCS state and budget projection.
- [x] Add automatic idempotent cleanup and retained redacted evidence.
- [x] Implement Cloud Run-to-Cockroach missing-IAM diagnosis fixture.
- [x] Link application Env, binding, secret, IAM, network and database evidence.
- [x] Add repair proposal, simulation, verification and handoff acceptance.
- [x] Complete architecture, operations, CLI, MCP and Workbench documentation.
- [x] Run package, examples, compile-fail, Workbench, repository, hygiene,
  container and release gates plus every available authenticated check.

Gate: the broken binding is diagnosed and repaired through structured evidence;
an expired preview cannot mutate; cleanup converges; all deterministic gates
pass and unavailable live qualification is explicit.
