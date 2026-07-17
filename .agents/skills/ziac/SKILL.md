---
name: ziac
description: Build, validate, visualize, test, and deploy effectful Ziac infrastructure across a standalone project or monorepo workspace. Use for typed ZigEffect services and layers, GCP or Cockroach resources, plans, causal debugging, local development, dashboard investigation, provider diagnostics, project decomposition, and capability-gated infrastructure changes.
---

# Ziac Development

Treat every `ziac.project.json` as an independently deployable unit of infrastructure intent and every colocated `zigeffect.project.json` as its executable application and evidence intent. A repository may contain one project or many nested projects. Before changing infrastructure, discover both manifest kinds from the Git root, select the smallest project that owns the capability, and read its requirements, acceptance checks, environments, adaptations, scenarios, authority policy, `ziac.stack.zig`, application services, root layer, and managed-runtime entry point.

## Bundled knowledge

Resolve `.dependencies.ziac.path` from the owning project's `build.zig.zon`. That relocatable directory is the installed Ziac knowledge root; it must not be replaced with a source-checkout or machine-specific path. Read its `README.md`, `docs/agent-development-kit.md`, and `docs/gcp-provider-coverage.md` first, then load only the provider or workflow document relevant to the task. For provider ecosystem work, also read `docs/provider-development-kit.md` and delegate to the creator, maintainer or independent qualifier role. Run `ziac provider resources --json` for the exact managed and planned surface shipped by the installed CLI. Use local docs for the behavior and pinned contracts shipped with this CLI. Delegate current Google Cloud facts to `gcp-developer-researcher` before relying on them.

## Ecosystem layers

- **Resources** are one-to-one GCP API objects implemented by the trusted provider. Use them when exact Google lifecycle control matters. Only provider code may perform cloud CRUD.
- **Components** are typed graph compilers from `ziac-gcpx`. They expand into declared resources and stamp every emitted node with package, version, instance, and source-digest provenance.
- **Templates** are deployable source projects. Inspect the generated Zig before planning or applying; templates never execute install hooks.
- Run `ziac registry search <query> --kind component --json` or `--kind template` before designing a new abstraction. Run `ziac package verify <package-dir>` before trusting a local or downloaded package.
- Prefer raw resources for uncommon topology, components for repeated governed topology, and templates for complete starting products. Never describe a component or template as a provider resource.
- Delegate new provider resources or RPC processes to `ziac-provider-creator`, upstream compatibility and migrations to `ziac-provider-maintainer`, and immutable-candidate evidence to `ziac-provider-qualifier`. The qualifier must not repair the candidate it is evaluating.

## Development loop

1. From the workspace root, identify the owning project. Run project commands from that project root or select it explicitly with `--project` where supported.
2. Call the read-only MCP `ziac_context` tool first. With the CLI, run
   `zigeffect agent context --task <id-or-summary> --budget 65536 --json`.
   Retain source/manifest identity, graph cursor, authority, omissions, affected
   scenarios, and proof references; state the causal counterfactual.
3. Run `ziac check --stack global-api --stage dev --json` in the owning project.
4. Add or update a deterministic Testing v2 scenario before behavior. Use `TestContext`, stable assertion IDs, test-only controlled causal-store injection, `noFindings`/`noPendingFibers`, and `mapCausalEventIds`.
   Mount controlled acceptance runtimes at the owning project or component root
   and prove a mapped assertion ID through the project-mounted graph.
5. Make the smallest typed change through public Ziac APIs and `zigeffect_std`. Compose canonical applications with `Ziac.Application.layer` and `Ziac.Application.run`. Keep pure resource/component graph compilers pure; place state, provider, process, network, clock, and filesystem boundaries behind services and scoped layers. One executable owns one managed runtime, and each request/job/command is a child effect. Application and provider code must not create a causal store or call low-level causal APIs; runtime and Ziac adapters automatically emit plan, resource, provider, retry/LRO, workflow, drift, and state semantics.
6. Run the affected requirement scenario and full package gate. Require stable
   evidence under `.zigeffect/tests/process-receipts/` and
   `.zigeffect/handoffs/tests/`; `.zigeffect/tests/raw-receipts/` is diagnostic.
7. Compare the NenDB delta and prove exact relationships with
   `zigeffect graph path <from> <to> --json` before accepting the plan.
8. Open `ziac dashboard` from the repository root to inspect the merged canvas. Filter to the changed project, its dependencies, or its consumers while retaining workspace context.
9. Apply only an integrity-checked saved plan under an explicit capability envelope. Never expand apply, delete, secret, live-network, project, stage, region, or cost authority implicitly.

For coordinated work, obey the work packet, allowed/excluded paths,
dependencies, verification commands, graph baseline, lease, and fencing token.
Re-query `ziac_context` or `agent context` before integration. Reject stale or
conflicting proof and hand off exact receipt/proof paths and causal IDs.

## Durable control flow

- Use a typed finite statechart when a process has long-lived branching, retry, cancellation, approval, or recovery states that agents must inspect. Statechart context contains bounded values only; actions update context and emit typed commands without I/O.
- Execute emitted commands as idempotent `WorkflowContext.activity` operations behind services from the root layer. Derive keys from immutable execution identity, use bounded codecs and typed failures, and keep the caller responsible for the journal lifetime. Use `zstd.Workflow.execution` for automatic journal and statechart recording; do not pass a causal store into the workflow.
- Production roots use a crash-safe `FileJournalStore`; deterministic unit tests may use `InMemoryJournalStore`, but acceptance must prove replay or reopen without repeating completed external work.
- Register definitions with `zstd.Statechart.registerDefinitionAtomic`. Inspect `zigeffect statechart list --json`, the affected machine, and NenDB workflow/statechart events before and after a change.

## Infrastructure rules

- Keep `observed`, `referenced`, and Ziac-managed resources distinct. Observed estate resources are read-only until a zero-change adoption plan is proved.
- Bind secrets by provider reference. Never request, print, persist, or place secret values in source, plans, state, logs, receipts, MCP arguments, or dashboard artifacts.
- Prefer the GCP and Cockroach high-level components already exported by Ziac. Preserve provider resource names, output wiring, lifecycle protection, and regional locality.
- Use immutable images, readiness before traffic, and causal rollback evidence for Cloud Run changes.
- Keep agent proposals non-mutating. Verification may run only manifest-declared fixed argv checks with process authority.
- Preserve project independence. Do not make an implicit cross-project dependency, edit a neighbouring project, or combine state merely because projects share a repository.
- Use explicit typed outputs and inputs for cross-project wiring. Validate the changed project and then the merged workspace graph. Treat duplicate ownership of one managed cloud resource as a conflict.
- Assume a project may later split. Keep feature boundaries, state ownership, provider authority, and CI targets clear enough to move without rewriting unrelated infrastructure.
- Delegate current or uncertain GCP API, IAM, quota, pricing, region, availability, and product-lifecycle claims to the `gcp-developer-researcher` before changing provider behavior. Require official sources and distinguish documented facts from inference.

## Agent interface

Use the project-local Ziac MCP server for simulation, proposals, and declared verification. Query the graph and receipts before inferring state. If required evidence is missing, incomplete, stale, truncated, or credential-gated, report that limitation rather than claiming success.
