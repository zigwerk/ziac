# Ziac Visual Infrastructure Workbench Implementation Plan

Date: 2026-07-11

Design:
`docs/superpowers/specs/2026-07-11-ziac-visual-infrastructure-workbench-design.md`

Status: completed on 2026-07-11.

Each behavior task starts with the narrowest failing test. Runtime capability
belongs in `packages/ziac/src` or the existing Workbench; no reporting tool is
added under `packages/zigeffect/tools`.

## Task 1: Versioned Zig Visual Artifact

1. Add failing tests for deterministic ResourceGraph and Plan serialization.
2. Add failing tests for secret redaction, graph digests, scope/region
   inference, plan operations, dependency edges, and malformed targets.
3. Implement `packages/ziac/src/visual_artifact.zig` and export it publicly.
4. Add a CLI-independent global-container fixture generator for UI samples.
5. Run focused Zig tests and the complete Ziac test gate.

## Task 2: Workbench Schema Routing And Model

1. Add failing TypeScript tests for `ziac.visual.v1` parsing, validation,
   unknown regions, redaction rejection, filters, summaries, and routes.
2. Implement a standalone Ziac visual artifact parser and derived view model.
3. Route Workbench tabs and top-level rendering by artifact schema without
   changing causal artifact behavior.
4. Add a representative checked-in Ziac sample artifact.
5. Run focused Workbench tests and typecheck.

## Task 3: Interactive Topology Canvas

1. Add failing adapter and UI semantic tests for nodes, combos, edges, plan
   states, filters, selection, legend, and inspector content.
2. Implement Ziac G6 nodes and deterministic topology layout.
3. Implement shared search, provider, region, operation, and health filters.
4. Implement synchronized resource selection and the resource inspector.
5. Add responsive and accessible non-canvas fallbacks.

## Task 4: Global Infrastructure Map

1. Add MapLibre GL JS and deck.gl dependencies.
2. Add failing tests for region coordinates, global front-door handling,
   planned/inferred/observed routes, map layers, and unknown regions.
3. Implement a lazy MapLibre map with deck.gl icon, scatter, and arc overlays.
4. Implement synchronized selection, filters, route provenance, legend, and
   accessible topology table.
5. Ensure map dependencies do not enter the causal Workbench initial chunk.

## Task 5: Product Polish And Documentation

1. Add restrained Ziac visual language using official GCP icon assets where
   licensing and packaging permit, with local provider fallbacks.
2. Add loading, empty, malformed, unsupported, and unmapped-region states.
3. Document artifact generation, truth modes, safety boundary, controls, and
   future live telemetry integration.
4. Update Ziac vision and roadmap with the completed visual milestone.

## Task 6: Verification

Run:

```sh
bun run zigeffect:workbench:test
bun run zigeffect:workbench:typecheck
bun run zigeffect:workbench:build
bun run ziac:test
bun run ziac:examples
(cd packages/ziac && zig build)
bash packages/zigeffect/tools/check_tool_hygiene.sh
git diff --check
```

Start the Workbench dev server and verify Topology and Global Map with browser
screenshots at desktop and mobile widths. Confirm the map canvas has nonblank
pixels, resources remain selectable, text does not overlap, and the causal
sample still renders.

## Completion Evidence

- The generated three-region Ziac fixture is semantically identical to the
  checked-in Workbench sample after canonical JSON sorting.
- All 119 Workbench tests pass, including parser, redaction, topology, map,
  selection, filtering, unknown-region, bridge, and causal regression coverage.
- Workbench typecheck and production build pass; map dependencies remain in a
  lazy Ziac-only chunk.
- All Ziac tests, examples, package build, and Zig formatting pass.
- The repository-wide `bun run check` passes 413 tests with 11 existing
  credential/live-database skips and no failures, followed by the Workbench
  suite with no failures.
- Browser verification at 1440x900 and 390x844 proved both views nonblank,
  synchronized region selection, provider filtering, no horizontal overflow,
  and no new warning or error logs. The mobile map crop recorded RGB standard
  deviations above 33 and entropy 4.156.
- Tool hygiene and `git diff --check` pass.
