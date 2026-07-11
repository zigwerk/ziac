# Ziac Compact Operations Implementation Plan

Date: 2026-07-11

Design:
`docs/superpowers/specs/2026-07-11-ziac-compact-operations-design.md`

Status: complete

## Task 1: Density Contracts

1. Add failing source/style tests for compact shell dimensions.
2. Add structural contracts for the agent strip, event toolbar, icon action,
   and deployment stepper.
3. Preserve existing navigation, dock tabs, selection, and deployment behavior.

## Task 2: Compact Shell

1. Reduce global and context bar height and control dimensions.
2. Reduce icon rail width, tool rows, and counter footprint.
3. Recalculate desktop and mobile main-grid columns.

## Task 3: Operations Workspace

1. Replace the agent sidebar and metric bands with one operational control
   strip.
2. Convert the causal timeline into a dense scroll-owned table.
3. Replace repeated text actions with a tooltip-labelled icon command.

## Task 4: Deployment Dock

1. Reduce total dock and tab height.
2. Tighten deployment summary and progress hierarchy.
3. Polish the connected rollout phase stepper.

## Task 5: Verification

1. Compare before and after captures at the same desktop state.
2. Verify Canvas, Operations, dock tabs, selection, and deploy feedback.
3. Verify mobile stacking and page overflow.
4. Run the complete Workbench test, typecheck, and production-build gate.
5. Update design QA evidence and complete this plan.

## Completion

- Reduced the global bar to 40px, context strip to 34px, and tool rail to 38px
  through shared workspace geometry variables.
- Replaced the agent sidebar and oversized evidence bands with one horizontal
  command strip containing state, objective, session, next action, and evidence
  completeness.
- Converted the causal timeline into a dense scroll-owned event table with
  stable columns and tooltip-labelled icon actions.
- Reduced the operational dock to 108px and tightened its tabs, deployment
  status, validation badge, progress bar, and connected rollout stepper.
- Restored explicit accessible names to icon-only mobile view controls and
  removed a stale responsive selector that displaced event actions.
- Browser QA passed on desktop and narrow responsive viewports with zero page
  overflow and no new console warnings or errors.
- 137 Workbench tests and 1,027 expectations pass; Workbench TypeScript and the
  Vite production build pass.
