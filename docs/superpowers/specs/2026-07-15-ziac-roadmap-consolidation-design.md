# Ziac Roadmap Consolidation Design

**Status:** Approved for documentation implementation on 2026-07-15.

## Problem

Ziac's package roadmap currently mixes four different kinds of information:

1. shipped implementation history;
2. credential-free implementation evidence;
3. authenticated qualification debt; and
4. future product work.

That makes a completed capability look unfinished when its external
qualification has not run, and it makes the next product priorities difficult
to find. Dated implementation plans also retain historical unchecked task
boxes, so they cannot remain the source of current delivery status.

## Decision

Ziac will have two canonical status documents:

- `packages/ziac/docs/shipped.md` is the consolidated delivery ledger for
  M0-M83. It records what is in `master`, the evidence level reached, and the
  qualification boundary that remains.
- `packages/ziac/docs/roadmap.md` is the only forward roadmap. It begins at M84
  and contains no historical implementation narrative.

Dated files under `docs/superpowers/specs/` and
`docs/superpowers/plans/` remain design and execution evidence. They are not
current status authorities. The consolidation implementation plan and shipped
ledger explicitly say so, avoiding a large mechanical rewrite of historical
TDD steps.

## Status Vocabulary

- **Shipped:** merged to `master` and covered by deterministic package or
  product gates.
- **Shipped, qualification required:** implementation, safety guards and
  fail-closed runner are shipped, but authenticated external evidence has not
  been produced.
- **Planned:** accepted forward work with an explicit acceptance gate.
- **Superseded:** a historical plan whose status is now represented by the
  shipped ledger or current roadmap.

`Shipped` never means that an authenticated cloud claim was proven when only a
local or scripted provider gate ran.

## Shipped Ledger Shape

The ledger groups M0-M83 by durable product capability instead of repeating
every dated implementation task:

- engine, state, planning and comptime contracts;
- GCP and Cockroach provider runtime;
- global Zig application platform;
- agent-first local development and MCP;
- visual workbench and monorepo workspace;
- Estate Pro and cost-intelligence kernels;
- self-host bootstrap;
- broad three-layer GCP coverage; and
- distribution, documentation and release evidence.

Every group includes its current evidence class. A separate qualification-debt
table carries live work into M84 without relabelling shipped code as pending.

## Forward Roadmap Shape

The fresh roadmap contains:

- M84 authenticated GCP qualification gauntlet;
- M85 Ziac Cloud self-host production deployment;
- M86 golden external developer journey;
- M87 provider and state reliability campaign;
- M88 paid Estate Pro and cost-intelligence product;
- M89 automated Google contract and provider evolution; and
- M90 private-beta evidence and release.

The sequencing deliberately pauses speculative resource-count expansion.
Provider breadth continues only for a demonstrated blocker or through the
governed automation delivered by M89.

## Acceptance

The consolidation is complete when:

1. the shipped ledger accurately records M0-M83 and the 253-resource catalog;
2. the package roadmap contains only current and future work;
3. every forward milestone has deliverables, dependencies, evidence and a
   binary exit gate;
4. local implementation and authenticated qualification are never conflated;
5. historical plans are explicitly designated non-authoritative for status;
6. all local Markdown links resolve; and
7. package tests and repository whitespace checks remain green.
