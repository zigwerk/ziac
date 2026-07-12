# Ziac Monorepo Workspace Dashboard Design

## Status

Validated from the product discussion on 2026-07-12. This design replaces the
assumption that the current directory is the complete Ziac estate.

## Product Contract

A Ziac workspace is a Git or explicitly configured root containing one or more
independently deployable Ziac projects. A standalone project is a workspace of
one. The workspace has one local dashboard process and one merged canvas.

Each nested project keeps its own compiler, `.ziac` state, locks, stages,
authority, CI and remote-state namespace. The workspace owns discovery,
federated visualization, filter state and local graph refresh only.

## Discovery

`ziac dashboard` resolves the workspace root, then recursively discovers
`ziac.project.json` files while excluding generated, dependency, fixture and VCS trees.
An optional `ziac.workspace.json` may constrain project includes later, but it
is not required for the initial monorepo experience.

Project identity comes from the project manifest, never from its current path.
Duplicate project identities fail closed. Discovery ordering is deterministic.

Each project may declare a visualization target:

```json
"dashboard": { "stack": "global-api", "stage": "dev" }
```

The CLI `--stack` and `--stage` flags override these defaults for focused
launches. Existing generated projects retain the `global-api/dev` fallback.

## Federated Artifact

The root CLI compiles each project in that project's working directory and
wraps the resulting `ziac.visual.v1` payloads in
`ziac.workspace-visual.v1`. The wrapper contains bounded project metadata and
redacted child artifacts; it does not contain credentials, state secrets or
source text.

The dashboard namespaces logical graph identities as
`<project-id>::<resource-id>`. The original provider resource ID remains
available for inspection. This prevents accidental collisions while preserving
project ownership. A later cloud-identity reconciliation layer may identify
shared observed resources, but two managed claims must surface as a conflict
rather than silently deduplicate.

## Canvas Slices

The WebUI always receives the complete local workspace graph and renders a
selected slice. Its project menu supports multi-selection and these scopes:

- selected projects only;
- selected projects plus transitive dependencies;
- selected projects plus dependencies and consumers.

Provider, region, operation, health, ownership and text filters compose with
the project slice. Edges and routes may never dangle after filtering. Resources
included as context retain their owning-project metadata.

The merged physical topology remains primary: GCP accounts, VPCs, regions and
third-party boundaries are not duplicated merely because multiple Ziac
projects use them. Project is an ownership/filter dimension, not a fake cloud
containment layer.

## Local Refresh

One dashboard host serves the workspace artifact. The host exposes the existing
bounded bridge, and the frontend polls it without creating per-project servers.
The workspace artifact is written atomically so readers see either the previous
complete graph or the next complete graph. Incremental compilation and
filesystem-triggered patches can optimize this contract without changing it.

## Agent Skills

The first `ziac init` in a repository installs the shared Codex, Claude and
Gemini Ziac skills at the workspace root. Subsequent project initialization is
idempotent. The skill requires agents to discover the workspace, select the
smallest owning project, preserve independent deployment boundaries, use
explicit cross-project contracts, and validate both the changed project and
the merged workspace graph.

## Completion Evidence

- nested projects are discovered deterministically and unsafe trees are ignored;
- duplicate project IDs and malformed manifests fail closed;
- project compilers execute from their own roots;
- a root dashboard artifact contains every valid nested project;
- resource, edge and route identities are collision-safe;
- project multi-select and dependency slices remain internally consistent;
- a single-project checkout remains supported;
- generated skills describe monolith-to-multi-project evolution;
- installed CLI E2E proves a fresh monorepo with two projects and one dashboard.
