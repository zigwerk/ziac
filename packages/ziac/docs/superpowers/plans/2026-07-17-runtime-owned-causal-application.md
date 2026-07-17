# Runtime-owned causal Ziac application implementation plan

## Baseline

- Source revision: `git:94c8eb1b1332342353dee0bfe869176b6cde2ff8` with a clean
  Ziac package at context capture.
- Manifest digest: `sha256:0134a2a9523c391a0104ffcd145980360220440a239d9c1a5b68708ad2bc4bfe`.
- Graph cursor: 6761.
- `ziac check --stack global-api --stage dev --json`: valid, two resources and
  one dependency.
- Compatibility: upgrade required because the local project metadata reports
  template 13 while the ZigEffect distribution is template 15.
- Expected before/action/after path: named `ziac.application` effect -> plan
  semantic fact -> per-resource operation -> provider call -> optional
  retry/LRO -> successful state commit -> checked runtime shutdown.

## Work items

1. Add source-policy tests that reject manual causal APIs in Ziac application
   roots and generated projects. Add an acceptance assertion for every edge in
   the successful semantic path.
2. Enrich ZigEffect's recording-only `CausalRecorder` with captured runtime
   lineage so framework adapters can retain causal context without receiving a
   store or live effect context.
3. Add the internal Ziac `runtime_events` semantic adapter and export only its
   stable fact model needed by framework tests.
4. Add `Application.Config`, `Application.layer`, `Application.program` and
   `Application.run`; migrate the canonical composition acceptance test.
5. Remove `causal_store` from `ExecuteOptions`. Thread the Ziac recorder through
   the internal observed executor path, provider `OperationContext`, retry/LRO
   handling and post-checkpoint state commits.
6. Replace workflow store plumbing with an effectful adapter while retaining a
   pure deterministic execution entry point. Migrate the CLI watch composition.
7. Remove duplicated lifecycle recording from provider, MCP, dashboard, worker,
   control-plane and CLI entry points; use named child effects for request/job
   boundaries.
8. Rewrite the built-in scaffold and registry templates to contain only
   application composition and tests. Advance compatibility metadata to the
   current distribution version.
9. Update Ziac architecture, workflow, provider and agent-development docs and
   repository-owned skills where the developer loop changes.
10. Run affected scenarios, `zig build unit-test` in Debug and ReleaseSafe,
    provider RPC tests, scaffold generation checks, Testing v2 migration checks,
    project agent gates and causal graph path queries. Inspect suite and handoff
    receipts before declaring completion.

## Constraints

- Do not modify ZGraphy or parser work owned by other agents.
- Do not add causal tools; runtime capability belongs under `src/`.
- Preserve pure compiler, graph, statechart transition and provider business
  functions for deterministic testing.
- Test harnesses may inject causal stores; production application APIs may not.
