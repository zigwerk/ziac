# Ziac Release Gate Implementation Plan

Date: 2026-07-10

## 1. Contract Tests

- Add a strict release-manifest test and import it into the package suite.
- Assert required live scenarios, unique IDs, non-empty environment contracts,
  safety constraints, and evidence fields.
- Run the test first and retain the expected missing-manifest failure.

## 2. Release Assets

- Add `packages/ziac/release/live-tests.json` without environment values.
- Add `packages/ziac/scripts/release-checks.sh` for required-file and secret
  checks.
- Add `release-gate` to `packages/ziac/build.zig`, composed from the existing
  test, example, executable, compile-fail, and container steps.

## 3. Complete Example

- Add `examples/production_global_service.zig`.
- Compose application SQL resources, PSC, regional Direct VPC, source image
  build, typed secret binding, global routing, DNS, and canary rollout.
- Test graph acyclicity, private topology, Cloud Run regions, and secret output
  wiring.

## 4. Public Documentation

- Rewrite the README around local quickstart, production composition, deploy,
  update, rollback, and destroy.
- Add a release and live-verification runbook.
- Cross-link architecture, state, security/auth, CI, provider, rollout, and
  Cockroach documents.
- Update roadmap and end-to-end delivery evidence.

## 5. Verification

- Run the new manifest test red then green.
- Run `zig build release-gate --summary all`.
- Run repository Bun, zigeffect standard library, Postgres, tool hygiene, and
  Cockroach verified-TLS gates.
- Run the gate again from a clean detached worktree and record external live
  prerequisites that remain unset.
- Commit the release milestone only after diff, credential, and generated-file
  checks pass.

Status: complete for the credential-free scope. Commit `3759c0fc` passed the
release gate from a detached clean worktree with 54/54 steps and 351/352 tests;
the remaining skip is authenticated Cockroach Cloud acceptance. Repository,
zigeffect, tool-hygiene, and local CockroachDB verified-TLS gates also passed.
