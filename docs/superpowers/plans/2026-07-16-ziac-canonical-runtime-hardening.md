# Ziac Canonical Runtime Hardening Plan

1. Capture the current Ziac package, provider catalog, project-check failure,
   Testing v2 receipt, daemon roots, and scaffold/template contracts.
2. Add failing architecture and acceptance tests for canonical process runtime
   ownership, external service topology, root project compilation, generated
   manifests, and durable causal assertion mapping.
3. Add any minimal canonical ZigEffect runtime primitive required for bounded
   structured execution, with core tests before Ziac consumes it.
4. Implement Ziac process-runtime and control-plane service layers; migrate the
   CLI and executor without changing pure planner/provider contracts.
5. Move MCP, dashboard, provider, estate, and billing roots onto one runtime per
   process and child effects per unit of work.
6. Make the Ziac root manifest executable and add its ZigEffect development
   manifest.
7. Upgrade the base scaffold and registry templates to canonical application
   roots and Testing v2 causal evidence; keep gcpx pure.
8. Exercise one freshly scaffolded base project and every registry template
   through build, test, project check, plan, receipt, and graph-query workflows.
9. Run full Ziac, gcpx, template, dashboard, provider RPC, ReleaseSafe,
   architecture, Testing v2 migration, documentation, and diff-integrity gates.
