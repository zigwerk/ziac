# Ziac Roadmap Consolidation Implementation Plan

Design: `docs/superpowers/specs/2026-07-15-ziac-roadmap-consolidation-design.md`

**Status:** Shipped on 2026-07-15.

## 1. Audit

- [x] Inventory the package roadmap and Ziac dated plans.
- [x] Compare roadmap claims with the current provider catalog, documentation,
  release gates and Testing v2 receipt.
- [x] Separate shipped implementation from authenticated qualification debt.

## 2. Consolidate Shipped Work

- [x] Add `packages/ziac/docs/shipped.md` as the canonical M0-M83 delivery
  ledger.
- [x] Mark every implemented product area as shipped.
- [x] Record external qualification separately and without overstating proof.
- [x] Link the detailed provider, architecture, Workbench, agent, state,
  Cockroach and release references.

## 3. Replace The Forward Roadmap

- [x] Replace the mixed historical roadmap with M84-M90 only.
- [x] Define dependencies, deliverables, evidence artifacts and exit gates for
  every milestone.
- [x] Add a beta definition of done and explicit non-goals.
- [x] Point readers to the shipped ledger for completed work.

## 4. Retire Competing Status Sources

- [x] Mark the original vision roadmap design as superseded.
- [x] Mark foundational historical plans as shipped execution records even
  where their original task checkboxes were never maintained.
- [x] Update stale active plan statuses whose local implementation is complete.
- [x] Make the new consolidation plan the status authority for this docs change.

## 5. Verify

- [x] Check Markdown links and status vocabulary consistency.
- [x] Run `git diff --check`.
- [x] Run the Ziac package test gate and inspect its Testing v2 receipt.
- [x] Record completion evidence and mark this plan shipped.

## Completion Evidence

- All relative Markdown links in the canonical roadmap, shipped ledger, design
  and implementation plan resolve.
- `git diff --check` passes.
- `zig build test` completed through the Testing v2 server runner with schema 2,
  complete status, 959 discovered and executed, 958 passed, one declared
  credential-gated skip, zero failures, pending tests, leaks or logged errors.
- `packages/ziac/docs/shipped.md` is the canonical M0-M83 delivery ledger and
  `packages/ziac/docs/roadmap.md` is the sole M84-M90 forward roadmap.
- Historical unchecked tasks now either carry an explicit shipped historical
  banner or represent authenticated work deliberately carried into M84.
