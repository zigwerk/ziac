# Ziac Statechart and Durable Workflow Implementation Plan

**Design:** `docs/superpowers/specs/2026-07-16-ziac-statechart-workflow-integration-design.md`

1. Add `ziac-durable-workflow-control` to `packages/ziac/zigeffect.project.json`
   with a required rollout statechart/workflow scenario.
2. Add a deterministic acceptance test that expects statechart decisions,
   workflow activity events, terminal state, replay without repeated provider
   calls, no findings, and no pending fibers. Confirm it fails first.
3. Refactor `watch_deploy.zig` around a typed ZigEffect statechart. Preserve the
   existing authority validation and receipt schema.
4. Execute statechart commands as idempotent `WorkflowContext` activities with
   bounded codecs and stable keys. Append idempotent workflow lifecycle events.
5. Record every statechart decision through the caller's runtime causal store.
6. Open one crash-safe CLI workflow journal and pass it plus the runtime-owned
   causal store to watch deployment. Do not create a nested runtime.
7. Export the machine definition and workflow metadata for inspection/tests.
8. Add a preserving statechart catalog registration API and generate native,
   XState, Mermaid, and DOT projections.
9. Upgrade the event-driven project template with a workflow service, typed
   statechart, durable production journal, replay scenario, and causal evidence.
10. Update Ziac architecture, agent workflow, roadmap, and scaffold guidance.
11. Run affected scenario selection, the new requirement scenario, package
   Debug/ReleaseSafe tests, Testing v2 receipt checks, graph queries, project
   safety, architecture, migration, hygiene, and diff gates.
