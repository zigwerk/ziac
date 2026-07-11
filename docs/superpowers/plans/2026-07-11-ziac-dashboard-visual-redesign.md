# Ziac Dashboard Visual Redesign Implementation Plan

Date: 2026-07-11

Design:
`docs/superpowers/specs/2026-07-11-ziac-dashboard-visual-redesign.md`

Status: completed on 2026-07-11

Completion evidence:

- Architecture renders eight high-level resources while Dependencies preserves
  all 17 compiled resources; Network and VPC expose their dedicated detail.
- The Workbench passes 126 tests, strict TypeScript checking, production build,
  and `git diff --check`.
- Browser QA verified Canvas, Global Map, Operations, topology modes, inspector
  tabs, deploy feedback, live logs, synchronized selection, and responsive
  layout with no new warnings or errors.
- Desktop WebGL capture is nonblank with luminance 22-255 and entropy 2.75;
  mobile capture has no page overflow or fully offscreen topology labels.

## Task 1: Behavioral Contracts

1. Add failing Workbench UI tests for the compact global/context bars,
   topology modes, navigator, inspector tabs, operational dock, and deploy
   state.
2. Add failing adapter tests for the Three.js scene contract and removal of G6
   from the Ziac topology path.
3. Add failing map tests for a monochrome basemap and semantic-only overlay
   colors.

## Task 2: Three.js Topology Scene

1. Add Three.js and its type definitions to the Bun workspace.
2. Implement deterministic scene layout from `FilteredZiacVisualModel`.
3. Render grid, raised topology planes, beveled resources, routes, labels,
   lights, and semantic states.
4. Implement selection, hover, pan/orbit/zoom, fit, projection, layers, and grid
   controls with cleanup and resize handling.
5. Keep the accessible resource index synchronized as the non-canvas fallback.

## Task 3: Compact Workbench Shell

1. Recompose the Ziac Workbench into compact global and context bars, icon rail,
   resource navigator, main scene, inspector, and operational dock.
2. Implement Canvas, Global Map, and Operations views and Architecture,
   Network, VPC, and Dependencies modes.
3. Implement inspector and dock tabs, command search, filters, and read-only
   deploy feedback.
4. Add responsive layouts for desktop, tablet, and mobile.

## Task 4: Monochrome Global Map

1. Replace the colorful demonstration style with a monochrome basemap.
2. Neutralize inactive arcs and markers.
3. Reserve GCP/status colors for selection, health, warnings, and active plan
   operations.
4. Restyle map controls, labels, provenance, and region navigation to match the
   compact shell.

## Task 5: Verification And Documentation

1. Run focused Workbench tests, typecheck, and production build.
2. Verify desktop and mobile rendering and primary interactions in the user's
   in-app browser.
3. Check nonblank WebGL canvas pixels and browser console output.
4. Compare the same viewport against concepts 2 and 3, record findings in
   `design-qa.md`, fix P0-P2 issues, and repeat until it passes.
5. Update the visual Workbench guide and Ziac roadmap with the completed
   dashboard milestone.
