# Ziac Standalone Dashboard Design

## Goal

Ziac and ZigEffect own completely independent dashboard applications. The Ziac
dashboard must not be a sample mode, route, source module, public fixture, or
stylesheet section inside the ZigEffect Workbench.

## Ownership boundary

The Ziac dashboard lives under `packages/ziac/dashboard/` and owns:

- its HTML and Vite entry points;
- its SolidJS application root;
- Ziac artifact parsing and view models;
- topology, map, resource icon, and dashboard components;
- Ziac host-bridge functions and development samples;
- all dashboard CSS, tests, typechecking, and production build output.

The ZigEffect Workbench remains under `packages/zigeffect/workbench/` and owns
only ZigEffect causal, development, safety, testing, and agent views. Neither
dashboard imports source files, fixtures, entry points, or styles from the
other.

## Runtime contract

The standalone Ziac dashboard opens at `/`. In browser-only development it
loads the representative global sample by default. Optional Ziac-owned sample
variants use `?sample=estate` and `?sample=permissions`.

When hosted by a native Ziac shell, the browser bridge uses Ziac-namespaced
functions:

- `ziac_load_artifact`;
- `ziac_load_session`;
- `ziac_load_log_snapshot`;
- `ziac_scan_estate`;
- `ziac_request_estate_access`.

The dashboard accepts only `ziac.visual.v1` artifacts. It does not understand
or fall back to ZigEffect causal artifact schemas.

## Styling contract

The Ziac dashboard imports one Ziac-owned stylesheet. Global reset rules are
limited to the standalone document and component rules are Ziac-prefixed. The
Ziac style stack is never concatenated with ZigEffect's stylesheet. The root
must fill the viewport, the command deck must remain a grid, and the topology
stage must have a non-zero bounded rendering area.

## Commands and verification

Root commands are:

- `bun run ziac:dashboard:dev -- --port 5178`;
- `bun run ziac:dashboard:test`;
- `bun run ziac:dashboard:typecheck`;
- `bun run ziac:dashboard:build`.

Verification includes focused model/UI tests, a boundary test that rejects
cross-dashboard imports, typechecking, a production Vite build, and browser
inspection of the standalone route.
