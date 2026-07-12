# Ziac Monorepo Workspace Dashboard Implementation Plan

## Objective

Deliver one local Ziac dashboard per repository/workspace root that discovers,
compiles, merges and filters every nested independently deployable Ziac project.

## M41: Workspace Kernel

- Add deterministic bounded project discovery.
- Exclude `.git`, `.ziac`, `.zig-cache`, `zig-cache`, `zig-out`,
  `node_modules` and vendor/cache trees.
- Parse stable project IDs and optional dashboard targets.
- Reject duplicate IDs and unsafe paths.
- Add project-root execution to the native program runner.

## M42: Federated Visual Contract

- Define and serialize `ziac.workspace-visual.v1`.
- Preserve child `ziac.visual.v1` artifacts as bounded JSON values.
- Include workspace and project metadata without source or secrets.
- Emit a deterministic root artifact under `.ziac/dashboard/workspace/`.
- Keep single-project artifacts parseable by the dashboard.

## M43: Root Dashboard Command

- Make `ziac dashboard` discover nested projects from the selected root.
- Compile each project's declared visualization target in its own directory.
- Launch one dashboard host with the federated artifact.
- Add artifact-only receipts containing project and resource totals.
- Add fixed root/project selection flags suitable for CI and agents.

## M44: Merged WebUI Canvas

- Parse workspace artifacts and namespace graph identities.
- Derive a single merged visual model and physical topology.
- Add compact project multi-select controls.
- Add selected-only, dependencies and dependency-plus-consumer slices.
- Preserve all existing provider, region, operation, health and estate filters.
- Display owning project in navigation and resource inspection.

## M45: Scaffold And Agent Contract

- Add dashboard defaults to new project manifests.
- Teach generated skills to discover and reason about all workspace projects.
- Install/synchronize harness skills at the repository root.
- Document monorepo initialization, project-scoped CI and dashboard usage.

## M46: Qualification

- Add Zig unit coverage for discovery, target parsing and federation.
- Add Bun coverage for parsing, namespacing and dependency slices.
- Extend installed-client E2E with two nested projects and one root artifact.
- Run Testing v2 receipt validation, dashboard typecheck/tests/build, package
  tests, release gate and browser screenshots at desktop and mobile sizes.
