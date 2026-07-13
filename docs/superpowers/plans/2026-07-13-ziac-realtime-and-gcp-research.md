# Ziac Realtime Dashboard And GCP Research Implementation Plan

Date: 2026-07-13

## 1. Lock The Scaffold Contract

- Add failing Zig scaffold assertions for the shared GCP research skill, three harness-native agents, `.env.example`, official MCP endpoint, allowed tools, read-only protocol, source ranking, and absence of embedded credentials.
- Extend scaffold E2E assertions for both a standalone project and the monorepo root.
- Implement project and root renderers, preserving child-specific Ziac MCP configuration and root-safe Google-only configuration.
- Update generated Ziac skills and initialization output to teach agents when to delegate research.

## 2. Lock Workspace Revision And Patch Semantics

- Add failing workspace tests for deterministic revision digests, changed project replacement, removed projects, no-op patches, and stale-base rejection.
- Add `revision` to merged workspace artifacts.
- Implement a secret-free `ziac.workspace-patch.v1` builder and parser/application helper.
- Preserve stable project ordering and cross-project topology derivation after patch application.

## 3. Add Browser Patch Transport

- Add failing TypeScript tests for schema validation, project replacement/removal, stale revision fallback, and subscription cleanup.
- Implement bridge snapshot state plus `ziac-workspace-patch` event subscription.
- Replace `App.tsx` full-payload interval polling with event-driven updates and a bounded reconnect/snapshot fallback.
- Add a host-side workspace observer that publishes patches through WebUI host-to-page execution.

## 4. Add Host-Owned Async Operations

- Add failing Zig tests for lifecycle transitions, cancellation ownership, terminal receipts, and bounded diagnostics.
- Implement the operation registry, process spawning, log files, waiter threads, status projection, and cancellation.
- Bind watch/status/cancel in the WebUI host while retaining synchronous plan generation.
- Add failing TypeScript lifecycle tests, then wire saved-plan approval to watch start, real status, terminal refresh, and cancel.
- Remove invented deployment percentages and hard-coded progress claims.

## 5. Document And Roadmap

- Document the local realtime protocol, operation authority, researcher workflow, API-key setup, and Public Preview fallback.
- Update the Ziac roadmap with delivered evidence and clearly separate later OS-specific watcher optimization from the completed patch protocol.

## 6. Verify

- Run focused Zig tests first, then the full package-native `zig build test` gate.
- Inspect Testing v2 receipts for complete discovered/executed counts, zero pending tests, leaks, and logged errors.
- Run the dashboard test, typecheck, and production build commands.
- Run scaffold E2E and `packages/zigeffect/scripts/check_testing_v2_migration.sh` when scaffold/build templates change.
- Report any credential-gated live Developer Knowledge check separately; configuration and contract tests remain deterministic without a key.

## 7. Close The Installed Knowledge Bundle

- Add failing installed-prefix assertions for the Ziac documentation tree and
  built dashboard assets.
- Install `packages/ziac/docs` with the relocatable client distribution.
- Teach the Ziac and GCP research skills to resolve local package knowledge
  through the generated project's `build.zig.zon` dependency path.
- Document which capabilities are bundled and which credentials remain
  operator-owned.
- Re-run scaffold E2E, package-native tests, the self-host gate, and Testing v2
  migration hygiene.
