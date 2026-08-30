# Ziac Repository Guidance

Treat every `ziac.project.json` as an independently deployable unit and every
colocated `zigeffect.project.json` as its executable application and evidence
intent.

## Engineering Loop

1. Read the owning project's manifests, stack, public package exports and
   relevant provider documentation.
2. Write a design under `docs/superpowers/specs/` and a plan under
   `docs/superpowers/plans/` for multi-step work.
3. Add a failing deterministic Testing v2 scenario before changing behaviour.
4. Preserve the provider boundary: resources perform cloud CRUD, components
   compile typed graphs, and templates produce inspectable source projects.
5. Keep observed, referenced and Ziac-managed resources distinct. Never place
   secret values in plans, state, logs, receipts, MCP data or dashboard assets.
6. Run affected checks and inspect complete Testing v2 receipts before claiming
   success.

Use `.agents/skills/ziac/SKILL.md` for the development loop and the provider
creator, maintainer, qualifier and GCP researcher skills for their named roles.

## Commands

- Engine: `cd packages/ziac && zig build test`
- GCPx: `cd packages/ziac-gcpx && zig build test`
- Frontends: `bun run check:frontend`
- Release: `cd packages/ziac && zig build release-gate`

Authenticated apply, delete, project, billing and live-network actions require
an explicit capability envelope. Missing or credential-gated evidence is not a
pass.

