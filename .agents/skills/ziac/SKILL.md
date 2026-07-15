---
name: ziac
description: Build, validate, visualize, test, and deploy Ziac and ZigEffect infrastructure across a standalone project or monorepo workspace. Use for Zig application Env bindings, GCP or Cockroach resources, plans, local development, dashboard investigation, provider diagnostics, project decomposition, and capability-gated infrastructure changes.
---

# Ziac Development

Treat every `ziac.project.json` as an independently deployable unit of executable intent. A repository may contain one project or many nested projects. Before changing infrastructure, discover all project manifests from the Git root, select the smallest project that owns the capability, and read its requirements, acceptance checks, environments, adaptations, scenarios, authority policy, `ziac.stack.zig`, and application `Env` declaration.

## Bundled knowledge

Resolve `.dependencies.ziac.path` from the owning project's `build.zig.zon`. That relocatable directory is the installed Ziac knowledge root; it must not be replaced with a source-checkout or machine-specific path. Read its `README.md`, `docs/agent-development-kit.md`, and `docs/gcp-provider-coverage.md` first, then load only the provider or workflow document relevant to the task. Run `ziac provider resources --json` for the exact managed and planned surface shipped by the installed CLI. Use local docs for the behavior and pinned contracts shipped with this CLI. Delegate current Google Cloud facts to `gcp-developer-researcher` before relying on them.

## Development loop

1. From the workspace root, identify the owning project. Run project commands from that project root or select it explicitly with `--project` where supported.
2. Run `ziac check --stack global-api --stage dev --json` in the owning project.
3. Run `zig build test --summary failures` and inspect the Testing v2 receipt under `.zigeffect/tests/suites/`.
4. Make the smallest typed change through public Ziac APIs. Keep application requirements, resource bindings, provider availability, scope, and outputs comptime-valid.
5. Run `ziac plan --stack global-api --stage dev --json`. Diagnose structured plan and causal evidence instead of parsing terminal scrollback.
6. Open `ziac dashboard` from the repository root to inspect the merged canvas. Filter to the changed project, its dependencies, or its consumers while retaining workspace context.
7. Apply only an integrity-checked saved plan under an explicit capability envelope. Never expand apply, delete, secret, live-network, project, stage, region, or cost authority implicitly.

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