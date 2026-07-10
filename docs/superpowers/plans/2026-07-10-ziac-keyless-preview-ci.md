# Ziac Keyless Preview CI Implementation Plan

Date: 2026-07-10

Design:
`docs/superpowers/specs/2026-07-10-ziac-keyless-preview-ci-design.md`

## Task 1: Preview Identity And Names

Tests first:

- deterministic repository-bound preview stages;
- exact grammar and invalid input rejection;
- bounded resource scoping with stable truncation hash;
- preview domain derivation;
- production cleanup rejection.

Implementation:

- add `src/ci.zig` and public export;
- add preview stage, classification, name, domain, and cleanup helpers.

## Task 2: Stage-Aware Built-In Stacks

Tests first:

- two PR stages produce distinct Artifact Registry, Cloud Run, and global
  component resource IDs;
- preview domain is stage-prefixed;
- non-preview fixture IDs remain byte-compatible.

Implementation:

- scope built-in repository/service/component names only for preview stages;
- pass stage into global stack construction;
- retain existing persistent-stage identities.

## Task 3: CLI Helpers And Cleanup Guard

Tests first:

- `preview-stage` human and JSON output;
- malformed change/repository input fails with usage diagnostics;
- `destroy --preview-cleanup` rejects production before lock/provider access;
- canonical preview cleanup still requires executor confirmation.

Implementation:

- add `preview-stage --repository --change [--json]`;
- add `--preview-cleanup` to destroy;
- validate cleanup before stack construction.

## Task 4: GitHub WIF Contract

Tests first:

- GitHub external-account fixture resolves through ADC;
- subject token loads from file;
- STS and service-account impersonation complete through scripted transport;
- fixture and diagnostics contain no private key or subject token.

Implementation:

- add GitHub Actions external-account fixture;
- reuse native external-account token source without new credential modes.

## Task 5: Workflow And Documentation

- add an inert copyable workflow template under `packages/ziac/examples`;
- add static policy tests for WIF, same-repository gating, GCS state, saved
  plans, protected environments, and preview cleanup;
- document Google setup, GitHub variables/environments, plan/deploy/cleanup,
  permissions, and trust restrictions;
- update README, architecture, roadmap, and M8 evidence.

## Gate

```sh
cd packages/ziac && zig fmt --check build.zig src test examples
cd packages/ziac && zig build test --summary all
cd packages/ziac && zig build examples --summary all
cd packages/ziac && zig build
bun run check
bun run zigeffect:std:test
bun run zigeffect:postgres:test
bun run zigeffect:postgres:cockroach-live-test
packages/zigeffect/tools/check_tool_hygiene.sh
git diff --check
```

Commit: `Add keyless Ziac CI deployments`
