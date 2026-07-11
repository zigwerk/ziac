# Ziac Compact Operations Design

Date: 2026-07-11

Status: implemented and browser verified

## Problem

The dashboard shell consumes too much vertical and horizontal space for an
operations console. The global bar, context bar, and icon rail each repeat
generous control spacing, reducing the canvas area. The Operations view then
switches to a different visual language: a large agent card, oversized metric
bands, loose log rows, text-heavy action buttons, and a sparse deployment dock.

## Design Direction

The dashboard remains a quiet GCP-console and Cloudcraft hybrid. This pass
increases information density without changing routes, data, selection, or
deployment behavior.

The global bar becomes a 40px command bar. Product identity, stack, search,
plan state, deploy, notifications, and account remain present, but controls use
26-28px heights and smaller gaps. The context bar becomes a 34px mode strip,
and the icon rail becomes 38px wide with 42px tool targets and compact counters.

## Agent Control Strip

Agent state becomes a horizontal control strip rather than a dominant sidebar.
It contains:

- state, objective, and session identity as the primary cluster;
- the next action as a bounded handoff field;
- retained, dropped, and suppressed evidence as compact inline metrics.

The strip uses one shared baseline, subtle dividers, and semantic status color.
It must read as part of the same operational dashboard, not as a nested card.

## Causal Timeline

The timeline becomes a dense operational log table with a fixed toolbar and
stable columns for sequence, source/severity/region, message and evidence IDs,
and resource action. Rows use 44-52px minimum height, severity is expressed by
a narrow left rule and text tone, and resource inspection uses a familiar icon
button with a tooltip rather than repeated prose buttons.

Long messages and IDs remain readable through wrapping or truncation without
moving the row columns. The event list owns scrolling while its toolbar remains
visible.

## Deployment Dock

The dock becomes a 108px operational rail with a 30px tab bar. The deployment
summary is a compact status block with validation and progress on one line.
The four rollout phases use an evenly spaced connected stepper with tighter
time, phase, and evidence hierarchy. Empty white space is removed while the
deploying transition and the existing tabs continue to work.

## Responsive Behavior

At narrow desktop widths the search and state clusters collapse before primary
commands. At mobile widths the 38px rail remains stable, the context modes can
scroll, the agent strip stacks into bounded rows, and the event table reduces
to sequence plus content while keeping the icon action. No page-level
horizontal overflow is permitted.

## Acceptance Criteria

- global bar height is 40px and context bar height is 34px;
- icon rail width is 38px with no content overlap;
- all existing shell commands and view/mode interactions remain available;
- Agent Session, evidence completeness, and next action share one compact strip;
- the timeline has stable log-table columns and icon-only resource actions;
- deployment tabs and rollout stepper remain functional in a 108px dock;
- Operations and Canvas are browser-verified at desktop and mobile widths;
- Workbench tests, TypeScript, and production build pass.

## Verification Evidence

- Desktop before/after captures were compared at the same Operations state.
- Canvas retained its complete topology and gained additional working area from
  the thinner global, context, rail, and dock chrome.
- Log inspection still selects the related resource and synchronizes the
  inspector; dock deployments, live logs, agent runs, and deploy progress still
  work.
- The narrow responsive capture has no page-level horizontal overflow, keeps
  every view button accessible by name, and pins event actions to a stable
  fourth grid column.
- The full Workbench gate passed 137 tests and 1,027 expectations; TypeScript
  and the Vite production build passed.
